//! lint:alias shader_introspect
// src/shader_introspect.zig - comptime schema introspection.
// WebGPU architecture is documented centrally in src/zimr.zig
// (the module-level `//!` doc) — read that before changing wgpu code.
//
//
// Zimr's unfair advantage (D14).  Zig comptime lets us walk a
// shader's schema (`_fs_io.zig` module) at compile time and:
//
//   1. Validate UBO struct layouts against WGSL uniform alignment
//      rules.  Catches std140-style mistakes (vec3 at non-16-aligned
//      offset, struct size not a multiple of 16) BEFORE the program
//      runs.
//
//   2. Generate bind group layout entries automatically.  The schema
//      declares "this shader has a Ubo and three samplers"; we walk
//      it and emit the right `entries: []const BindGroupLayoutEntry`
//      array at comptime.  Zero runtime cost.
//
//   3. Sanity-check the schema against the transpiler's WGSL output
//      (when the transpiler arrives — see `shader_compile.zig`).
//      If the schema says `time: f32` and the WGSL says `time: i32`,
//      that's caught at compile time.
//
// Neither Mach nor raygpu can do this — they're written in C / C99.
// We are the only library where the GPU↔CPU contract is type-checked
// at the source level.
//
// All functions here are `comptime` only.  No runtime helpers.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const std = @import("std");
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const wgpu = @import("wgpu.zig");

// ============================================================================
// SECTION 1 — UBO layout validation
// ============================================================================
//
// WGSL uniform buffers follow a layout similar to GLSL std140:
//   - `f32` / `i32` / `u32`: 4-byte aligned, 4 bytes.
//   - `vec2`: 8-byte aligned, 8 bytes.
//   - `vec3`: 16-byte aligned, 12 bytes (1 dword padding implicit).
//   - `vec4`: 16-byte aligned, 16 bytes.
//   - `mat4x4`: 16-byte aligned, 64 bytes.
//   - struct: aligned to its largest member's alignment, padded to
//     a 16-byte multiple at the end.
//   - array: stride is each element's size rounded up to 16-byte
//     multiple for `array<f32>` style (NOT for storage buffers).

fn comptimeIntStr(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

fn isAlignedField(comptime T: type) bool {
    // True for types whose own alignment guarantees they don't straddle.
    const info = @typeInfo(T);
    return switch (info) {
        .array => |a| a.len == 4 or a.len >= 16, // vec4 or mat4x4 etc.
        .@"struct" => true, // inner struct has its own alignment
        else => false,
    };
}

/// Validate a struct type intended as a UBO.  Fires `@compileError`
/// with a specific, actionable message on failure.  Call from inside
/// a `comptime { ... }` block at the file that defines the UBO struct.
///
/// What we check:
///   - Total size is a multiple of 16 bytes (WGSL uniform requirement)
///   - Each vec3 field starts at a 16-byte-aligned offset
///   - Each field's size doesn't straddle a 16-byte boundary
///     (with the exception of arrays + matrices which have their own
///     internal alignment)
pub fn validateUboLayoutComptime(comptime T: type) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("UBO type `" ++ @typeName(T) ++
                "` must be a struct, got " ++ @tagName(info));
        }
        // Zig 1245 bans vector fields in extern structs on CPU targets, so
        // schema Ubos are PLAIN structs whose GPU bytes come from the wire
        // serializer.  An extern struct here would layout-error the moment a
        // host constructs a value of it — reject it with the reason.
        if (info.@"struct".layout == .@"extern") {
            @compileError("UBO type `" ++ @typeName(T) ++
                "` must be a plain `struct` (extern structs can no longer " ++
                "carry @Vector fields on CPU targets; the GPU byte layout " ++
                "comes from shader_interface's wire serializer).");
        }

        // wireSizeOf/wireAlignOf reject unsupported field types (vec3, non-4-
        // byte scalars, nested structs) with their own actionable messages, so
        // merely computing the size validates every field.
        const size = shader.wireSizeOf(T);
        if (size % 16 != 0) {
            @compileError("UBO type `" ++ @typeName(T) ++
                "` has wire size " ++ comptimeIntStr(size) ++
                " which is not a multiple of 16 bytes (WGSL uniform " ++
                "requirement).  Add padding fields to reach a 16-byte multiple.");
        }

        for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
            const off: usize = shader.wireOffsetOf(T, field_name);
            const fsize: usize = shader.wireFieldSize(field_type);

            // A field must not straddle a 16-byte boundary unless it is
            // itself 16-aligned (vec4, mat4, vec runs) — the std140 rule the
            // engine's uniform blocks follow.
            const start_bucket: usize = off / 16;
            const end_bucket: usize = (off + fsize - 1) / 16;
            if (start_bucket != end_bucket and fsize <= 16) {
                if (!isAlignedField(field_type)) {
                    @compileError("UBO field `" ++ field_name ++ "` of `" ++
                        @typeName(T) ++ "` straddles a 16-byte boundary " ++
                        "(wire offset " ++ comptimeIntStr(off) ++ ", size " ++
                        comptimeIntStr(fsize) ++ ").  Reorder or pad to align.");
                }
            }
        }
    }
}

/// Assert that a vertex shader's `Outputs` (the varyings it emits) match a
/// fragment shader's `Inputs` (the varyings it reads) field-for-field — same
/// names, same types, same declaration order. Both stages assign WGSL
/// `@location` indices by field index (see tools/gen_shader_externs.zig), so an
/// equal field list guarantees matching locations and a valid VS→FS link;
/// drift produces a pipeline that the GPU silently rejects at draw time (the
/// turn-N6 mandelbrot bug: an FS `Inputs.frag_color` the VS never output).
///
/// Call at comptime from loadShader when the caller passes a VS schema. A
/// missing `Outputs` (e.g. a VS that emits no varyings) is allowed only if the
/// FS declares no `Inputs`; otherwise it's a mismatch.
///
/// `VsSchema` is the vertex io schema (must declare `Outputs` if it emits
/// varyings); `FsSchema` is the fragment io schema (must declare `Inputs` if it
/// reads varyings).
pub fn assertVaryingsMatch(comptime VsSchema: type, comptime FsSchema: type) void {
    // Zig 0.17: `return` can't escape a `comptime { }` block, so the body is
    // no longer wrapped — both params are comptime, and every caller invokes
    // this in a comptime context, so the analysis still happens at comptime.
    {
        const vs_has = @hasDecl(VsSchema, "Outputs");
        const fs_has = @hasDecl(FsSchema, "Inputs");

        // Neither side has varyings → trivially fine (e.g. a fullscreen pass
        // whose VS emits only the built-in clip position and whose FS reads no
        // interpolated inputs).
        if (!vs_has and !fs_has) {
            return;
        }
        if (vs_has != fs_has) {
            @compileError("VS↔FS varying mismatch: " ++
                (if (vs_has)
                    "VS `" ++ @typeName(VsSchema) ++ "` declares `Outputs` but FS `" ++
                        @typeName(FsSchema) ++ "` declares no `Inputs`."
                else
                    "FS `" ++ @typeName(FsSchema) ++ "` declares `Inputs` but VS `" ++
                        @typeName(VsSchema) ++ "` declares no `Outputs`.") ++
                " VS.Outputs and FS.Inputs must match field-for-field.");
        }

        const vs_names = @typeInfo(VsSchema.Outputs).@"struct".field_names;
        const vs_types = @typeInfo(VsSchema.Outputs).@"struct".field_types;
        const fs_names = @typeInfo(FsSchema.Inputs).@"struct".field_names;
        const fs_types = @typeInfo(FsSchema.Inputs).@"struct".field_types;

        if (vs_names.len != fs_names.len) {
            @compileError("VS↔FS varying mismatch: VS `" ++ @typeName(VsSchema) ++
                "` outputs " ++ comptimeIntStr(vs_names.len) ++ " varying(s) but FS `" ++
                @typeName(FsSchema) ++ "` reads " ++ comptimeIntStr(fs_names.len) ++
                ". VS.Outputs and FS.Inputs must match field-for-field (name, type, order).");
        }

        inline for (vs_names, vs_types, fs_names, fs_types, 0..) |vf_name, vf_type, ff_name, ff_type, i| {
            if (comptime !eql(u8, vf_name, ff_name)) {
                @compileError("VS↔FS varying mismatch at location " ++ comptimeIntStr(i) ++
                    ": VS `" ++ @typeName(VsSchema) ++ "` outputs '" ++ vf_name ++
                    "' but FS `" ++ @typeName(FsSchema) ++ "` reads '" ++ ff_name ++
                    "'. Field names + order ARE the @location assignment, so they must match.");
            }
            if (comptime vf_type != ff_type) {
                @compileError("VS↔FS varying type mismatch for '" ++ vf_name ++
                    "' at location " ++ comptimeIntStr(i) ++ ": VS outputs `" ++
                    @typeName(vf_type) ++ "` but FS reads `" ++ @typeName(ff_type) ++ "`.");
            }
        }
    }
}

// ============================================================================
// SECTION 2 — bind group layout auto-generation
// ============================================================================

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: wgpu.ShaderStage,
    /// Tagged-union resource type.  Stored as a tag + inline data so
    /// the entire entry list can be a comptime-known `[]const` slice.
    resource: ResourceLayout,

    pub const ResourceLayout = union(enum) {
        uniform_buffer: struct { min_size: u64 = 0 },
        storage_buffer: struct { read_only: bool = false, min_size: u64 = 0 },
        sampler: struct { filtering: bool = true },
        texture: struct {
            sample_type: SampleType = .float,
            view_dimension: ViewDimension = .d2,
            multisampled: bool = false,
        },
        storage_texture: struct {
            access: StorageTextureAccess = .write_only,
            format: wgpu.TextureFormat,
            view_dimension: ViewDimension = .d2,
        },
    };

    pub const SampleType = enum(u32) { float, unfilterable_float, depth, sint, uint };
    pub const ViewDimension = enum(u32) { d1, d2, d2_array, cube, cube_array, d3 };
    pub const StorageTextureAccess = enum(u32) { write_only, read_only, read_write };
};

/// Walk a schema type (`_fs_io.zig` module) and produce the bind
/// group layout entries it implies.  Convention:
///
///   - Binding 0 (Group 1): the `Ubo` struct, as a uniform buffer
///     visible to vertex + fragment.
///   - Bindings 1+: each field of `Samplers`, allocated as (texture,
///     sampler) pairs starting at binding 1.
///   - Group 3 (compute only): each field of `Storage`, as a storage
///     buffer.
///
/// Returns a comptime-known `[]const BindGroupLayoutEntry` slice.
/// The whole array is built at comptime; runtime cost is zero.
pub fn autoMaterialBindGroupLayout(comptime ShaderIo: type) []const BindGroupLayoutEntry {
    comptime {
        var entries: []const BindGroupLayoutEntry = &.{};

        // Binding 0: Ubo (if present)
        if (@hasDecl(ShaderIo, "Ubo")) {
            const UboT = ShaderIo.Ubo;
            entries = entries ++ &[_]BindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = .{ .vertex = true, .fragment = true },
                .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(UboT) } },
            }};
        }

        // Bindings 1+: each field of Samplers, as (texture, sampler) pairs
        if (@hasDecl(ShaderIo, "Samplers")) {
            const SamplersT = ShaderIo.Samplers;
            const sinfo = @typeInfo(SamplersT);
            if (sinfo == .@"struct") {
                var idx: u32 = 1;
                for (sinfo.@"struct".field_names) |_| {
                    entries = entries ++ &[_]BindGroupLayoutEntry{
                        .{
                            .binding = idx,
                            .visibility = .{ .fragment = true },
                            .resource = .{ .texture = .{} },
                        },
                        .{
                            .binding = idx + 1,
                            .visibility = .{ .fragment = true },
                            .resource = .{ .sampler = .{} },
                        },
                    };
                    idx += 2;
                }
            }
        }

        return entries;
    }
}

fn isReadOnlyStorageField(comptime T: type) bool {
    // Schema convention: storage buffer fields are wrapped in
    // `shader.StorageBuf(T, .read)` or `shader.StorageBuf(T,
    // .read_write)`.  We pattern-match on a `.access` decl.
    if (!@hasDecl(T, "access")) {
        return false;
    }
    return T.access == .read;
}

/// Compute storage-buffer bind group layout (Group 3).  Each field of
/// the `Storage` struct becomes a storage buffer at sequential bindings.
pub fn autoStorageBindGroupLayout(comptime ShaderIo: type) []const BindGroupLayoutEntry {
    comptime {
        if (!@hasDecl(ShaderIo, "Storage")) {
            return &.{};
        }
        var entries: []const BindGroupLayoutEntry = &.{};
        const StorageT = ShaderIo.Storage;
        const sinfo = @typeInfo(StorageT);
        if (sinfo != .@"struct") {
            return &.{};
        }
        var idx: u32 = 0;
        for (sinfo.@"struct".field_types) |field_type| {
            const access_read_only: bool = isReadOnlyStorageField(field_type);
            entries = entries ++ &[_]BindGroupLayoutEntry{.{
                .binding = idx,
                .visibility = .{ .vertex = true, .fragment = true, .compute = true },
                .resource = .{ .storage_buffer = .{ .read_only = access_read_only } },
            }};
            idx += 1;
        }
        return entries;
    }
}

// ============================================================================
// SECTION 3 — layout solver (turn 1 of finishing_new_gpu_foundations.md)
// ============================================================================
//
// `solveLayout(SchemaT)` is a comptime function that walks a shader's
// resources struct, reads each field's DSL marker config, and
// produces a stable `ResolvedLayout` — the canonical
// `(group, binding)` assignment for every resource the shader uses.
//
// Rules (per the plan, §C of turn 1):
//
//   1. Pinned fields (`.pinned = .{group,binding}`) claim their
//      cell first.  Solver never overrides them.
//   2. Shared fields (`.shared = ...`) are pinned via a named
//      external location — same mechanism, different intent.
//   3. Free fields (`.{}`) partition by kind:
//        - UBO → group 0
//        - Sampler2D / texture → group 1
//        - Storage buffer (read-write) → group 2
//   4. Within a group, free fields take bindings in DECLARATION
//      ORDER, skipping cells claimed by pinned fields.  A pinned
//      field at (1, 5) makes free samplers take 0,1,2,3,4,6.
//   5. Result is sorted by (group, binding) for stable emission.
//
// Stability: appending a new free field at the END never renumbers
// existing fields.  Inserting in the middle can — and the comptime
// dup-binding check catches collisions before the SPIR-V is built.
//
// The solver runs ONCE per schema, at comptime.  Result is a
// `pub const layout` consumed by codegen + the host-side
// `Resources(Schema)` type.

pub const FieldKind = enum { ubo, sampler_2d, storage_buffer };

/// One resolved binding's worth of information.  The solver produces
/// `[]const ResolvedField` — one entry per resource (sampler, UBO,
/// storage buffer) in the schema.  Iteration order is
/// declaration-order, NOT (group, binding)-sorted; iteration order
/// has to match the user's struct so `Resources.init(.{...})` can
/// thread arguments by name.
pub const ResolvedField = struct {
    /// Field name in the source struct (e.g. "texture0", "view_proj").
    /// Sentinel-terminated so it can be used directly as a
    /// `std.builtin.Type.StructField.name` in `@Struct` calls.
    name: [:0]const u8,
    /// What kind of resource this is.  Drives the codegen path and
    /// the bind-group-layout-entry shape.
    kind: FieldKind,
    /// Final (group, binding) assignment — what lands on the
    /// SPIR-V variable as `OpDecorate DescriptorSet` / `Binding`,
    /// and what shows up in the WGSL as `@group(N) @binding(M)`.
    group: u32,
    binding: u32,
    /// Where the location came from.  `.solver_default` = free
    /// field, picked by the solver; `.pinned` = user wrote
    /// `.pinned`; `.shared` = user wrote `.shared`.  Useful for
    /// error messages and the dup-binding check's wording.
    origin: Origin,
    /// Shader stages a sampler binding is visible to (samplers only; UBO and
    /// storage keep their own all-stage visibility). Default fragment-only.
    stages: shader.Stages = .{ .fragment = true },
    /// For `.storage_buffer` fields: whether the buffer is bound read-only
    /// (`var<storage, read>`) vs read-write. Ignored for other kinds.
    read_only: bool = true,

    pub const Origin = enum { solver_default, pinned, shared };
};

pub const ResolvedLayout = struct {
    fields: []const ResolvedField,
    /// Bitmask: bit N set iff group N has at least one resource.
    /// Capped at 4 (WebGPU minimum guaranteed groups).
    groups_used: u8,
};

/// Read a Sampler2D field's marker config and return the resolved
/// override (if any).  Returns `null` when the marker has `.{}`
/// defaults — solver picks the cell.
fn readSamplerOverride(comptime SamplerT: type) ?struct { group: u32, binding: u32, origin: ResolvedField.Origin } {
    if (!@hasDecl(SamplerT, "sampler_config")) {
        return null;
    }
    const cfg = SamplerT.sampler_config;
    if (cfg.pinned) |p| {
        return .{ .group = p.group, .binding = p.binding, .origin = .pinned };
    }
    if (cfg.shared) |s| {
        return .{ .group = s.group, .binding = s.binding, .origin = .shared };
    }
    return null;
}

/// True if the schema declares `Samplers` with at least one field that has no
/// `.pinned`/`.shared` override — i.e. a sampler that would take the default
/// group. Used by the up-front contention diagnostic in `solveLayout`.
fn hasUnpinnedSampler(comptime SchemaT: type) bool {
    if (!@hasDecl(SchemaT, "Samplers")) {
        return false;
    }
    for (@typeInfo(SchemaT.Samplers).@"struct".field_types) |field_type| {
        if (readSamplerOverride(field_type) == null) {
            return true;
        }
    }
    return false;
}

/// Comptime layout solver.  Reads `SchemaT.Samplers` (and in future
/// `SchemaT.Ubo`, `SchemaT.Storage`), partitions free vs pinned
/// fields, assigns `(group, binding)` cells.
///
/// Returns a `ResolvedLayout` with one entry per resource, ordered
/// by declaration order in the source struct.
///
/// **Comptime dup-binding check.**  After every assignment, scans
/// for any other field already at the same `(group, binding)`.
/// Collision triggers `@compileError` with both field names — the
/// schema can't ship with a colliding layout.
pub fn solveLayout(comptime SchemaT: type) ResolvedLayout {
    comptime {
        var fields: []const ResolvedField = &.{};
        var groups_used: u8 = 0;

        // Pass 1: classify each resource.  For each kind, track
        // which (group, binding) cells are already claimed by
        // pinned/shared fields so the solver can skip them.

        // Per-group claimed-bindings bitmasks.  Bit N set = binding
        // N in this group is taken (by a pinned/shared field).
        // 64 bits is plenty — WebGPU minimum is 8 bindings per group.
        var claimed_in_group: [4]u64 = .{ 0, 0, 0, 0 };

        // ---- Up-front group-contention diagnostic ----------------------------
        // The per-section claiming below catches (group, binding) collisions,
        // but by whichever section claims last — so the error names a symptom.
        // This block runs FIRST and names the actual cause for the one
        // non-obvious case: a schema that pins its UBO (via `ubo_group`) into a
        // group already spoken for by the default sampler or storage placement.
        // No shader combines these today; this makes the first that does get a
        // precise message instead of a confusing one.
        if (@hasDecl(SchemaT, "Ubo") and @hasDecl(SchemaT, "ubo_group")) {
            const ug: u32 = shader.uniformGroupForSchema(SchemaT);
            // Unpinned samplers default to `shader.sampler_group`.
            if (ug == shader.sampler_group and hasUnpinnedSampler(SchemaT)) {
                @compileError(std.fmt.comptimePrint(
                    "Schema pins its `Ubo` to group {d} (`ubo_group`), but that is also " ++
                        "the default group for unpinned samplers. Pin the conflicting " ++
                        "sampler(s) elsewhere with `.pinned`, or choose a different `ubo_group`.",
                    .{ug},
                ));
            }
            // Storage binds in the UBO's group, right after the UBO. If
            // unpinned samplers ALSO default into that group, all three
            // contend. (Storage-vs-UBO alone is fine — storage starts at
            // binding 1.) Flag the sampler overlap specifically.
            if (@hasDecl(SchemaT, "Storage") and ug == shader.sampler_group and hasUnpinnedSampler(SchemaT)) {
                @compileError(std.fmt.comptimePrint(
                    "Schema puts a `Ubo` (pinned to group {d}), `Storage`, AND unpinned " ++
                        "samplers all in group {d}. Pin the samplers elsewhere, or move the " ++
                        "UBO+storage with a different `ubo_group`.",
                    .{ ug, ug },
                ));
            }
        }

        // ---- Samplers ----
        if (@hasDecl(SchemaT, "Samplers")) {
            const SamplersT = SchemaT.Samplers;
            const sinfo = @typeInfo(SamplersT);
            if (sinfo == .@"struct") {
                // Validation pass: bounds + pinned/shared collisions. (The
                // actual (group, binding) assignment is delegated to the shared
                // authority below.)
                for (sinfo.@"struct".field_names, sinfo.@"struct".field_types) |field_name, field_type| {
                    if (readSamplerOverride(field_type)) |o| {
                        if (o.group >= 4) {
                            @compileError(
                                "Sampler field `" ++ field_name ++ "` " ++
                                    "pinned to group " ++ comptimeIntStr(o.group) ++
                                    " — WebGPU guarantees only 4 groups.  " ++
                                    "Use groups 0-3.",
                            );
                        }
                        if (o.binding >= 64) {
                            @compileError(
                                "Sampler field `" ++ field_name ++ "` " ++
                                    "pinned to binding " ++ comptimeIntStr(o.binding) ++
                                    " — solver tracks bindings 0-63 only.",
                            );
                        }
                        const bit: u64 = @as(u64, 1) << @intCast(o.binding);
                        if (claimed_in_group[o.group] & bit != 0) {
                            @compileError(
                                "Sampler field `" ++ field_name ++ "` " ++
                                    "collides with another field at @group(" ++
                                    comptimeIntStr(o.group) ++ ") @binding(" ++
                                    comptimeIntStr(o.binding) ++ ").  " ++
                                    "Each (group, binding) cell can hold only one resource.",
                            );
                        }
                        claimed_in_group[o.group] |= bit;
                        groups_used |= @as(u8, 1) << @intCast(o.group);
                    }
                }

                // Assignment: delegate to the ONE shared solver in
                // shader_interface — the SAME function the SPIR-V binding codegen
                // (tools/gen_shader_externs.zig) calls — so the host layout and
                // the emitted WGSL @group/@binding can never drift. Each slot is
                // a texture+sampler PAIR: mark BOTH binding and binding+1 claimed
                // so the later Ubo/Storage sections see the full occupancy.
                const slots = shader.solveSamplerSlots(SamplersT);
                for (sinfo.@"struct".field_names, 0..) |field_name, i| {
                    const slot: shader.SamplerSlot = slots[i];
                    fields = fields ++ &[_]ResolvedField{.{
                        .name = field_name,
                        .kind = .sampler_2d,
                        .group = slot.group,
                        .binding = slot.binding,
                        .origin = switch (slot.origin) {
                            .solver_default => .solver_default,
                            .pinned => .pinned,
                            .shared => .shared,
                        },
                        .stages = slot.stages,
                    }};
                    claimed_in_group[slot.group] |= @as(u64, 1) << @intCast(slot.binding);
                    claimed_in_group[slot.group] |= @as(u64, 1) << @intCast(slot.binding + 1);
                    groups_used |= @as(u8, 1) << @intCast(slot.group);
                }
            }
        }

        // ---- Ubo ----
        // The UBO's group is STAGE-DEPENDENT, matching the codegen
        // (tools/gen_shader_externs.zig, documented at its top): a VS
        // schema (declares `Attributes`) emits its uniform at @group(0);
        // an FS schema (declares `Inputs`) emits it at @group(2) — group
        // 1 is reserved for the material samplers. A lone Ubo schema with
        // neither marker defaults to group 0. This MUST agree with the
        // emitted WGSL or the pipeline layout mismatches and the GPU
        // rejects the pipeline at creation. A UBO can be pinned to a
        // non-default group with `pub const ubo_group = N` on the schema.
        if (@hasDecl(SchemaT, "Ubo")) {
            // Group from the SINGLE SOURCE OF TRUTH shared with the codegen
            // (shader_interface.uniformGroupForSchema) so the host bind groups
            // can never disagree with the emitted WGSL @group decorations.
            const g: u32 = shader.uniformGroupForSchema(SchemaT);
            const b: u32 = 0;
            if (claimed_in_group[g] & (@as(u64, 1) << @intCast(b)) != 0) {
                @compileError(
                    "Schema's `Ubo` at @group(" ++ comptimeIntStr(g) ++
                        ") @binding(0) collides with another resource " ++
                        "(usually a sampler that defaults to this group).  " ++
                        "Pin the conflicting sampler elsewhere, or move the " ++
                        "UBO with `pub const ubo_group = N` on the schema.",
                );
            }
            claimed_in_group[g] |= @as(u64, 1) << @intCast(b);
            groups_used |= @as(u8, 1) << @intCast(g);
            fields = fields ++ &[_]ResolvedField{.{
                .name = "_ubo", // synthetic; Resources init handles it specially
                .kind = .ubo,
                .group = g,
                .binding = b,
                .origin = .solver_default,
            }};
        }

        // ---- Storage ----
        // Storage buffers: placement delegated to the ONE shared authority in
        // shader_interface — the SAME function the SPIR-V codegen calls — so
        // the host layout and the emitted WGSL @group/@binding can't drift.
        // (They bind in the stage's uniform group, at bindings after the Ubo.)
        if (@hasDecl(SchemaT, "Storage")) {
            const StorageT = SchemaT.Storage;
            const sinfo = @typeInfo(StorageT);
            if (sinfo == .@"struct") {
                const slots = shader.solveStorageSlots(SchemaT);
                for (sinfo.@"struct".field_names, sinfo.@"struct".field_types, 0..) |field_name, field_type, i| {
                    const slot: shader.StorageSlot = slots[i];
                    if (claimed_in_group[slot.group] & (@as(u64, 1) << @intCast(slot.binding)) != 0) {
                        @compileError(
                            "Schema's `Storage." ++ field_name ++ "` at @group(" ++
                                comptimeIntStr(slot.group) ++ ") @binding(" ++ comptimeIntStr(slot.binding) ++
                                ") collides with another resource.",
                        );
                    }
                    claimed_in_group[slot.group] |= @as(u64, 1) << @intCast(slot.binding);
                    groups_used |= @as(u8, 1) << @intCast(slot.group);
                    fields = fields ++ &[_]ResolvedField{.{
                        .name = field_name,
                        .kind = .storage_buffer,
                        .group = slot.group,
                        .binding = slot.binding,
                        .origin = .solver_default,
                        .read_only = isReadOnlyStorageField(field_type),
                    }};
                }
            }
        }

        return .{ .fields = fields, .groups_used = groups_used };
    }
}

/// A disagreement between the host bind-group layout and the shader's WGSL,
/// found by `layoutWgslMismatch`. `expected` is what the host layout provides
/// at this cell; `found` is what the WGSL actually declares there.
pub const LayoutWgslMismatch = struct {
    group: u32,
    binding: u32,
    /// The WGSL var name at the offending cell (or "" for a host cell the WGSL
    /// never declares).
    name: []const u8,
    /// Human labels, e.g. "texture" / "sampler" / "uniform" / "storage" /
    /// "<nothing>".
    expected: []const u8,
    found: []const u8,
};

fn kindLabelWgsl(k: WgslBinding.Kind) []const u8 {
    return switch (k) {
        .uniform => "uniform",
        .storage => "storage",
        .sampler => "sampler",
        .texture => "texture",
        .storage_texture => "storage-texture",
        .unknown => "unknown",
    };
}

/// Independent host<->WGSL binding cross-check for the RENDER path (the compute
/// path has its own in `compute_host.zig`). Reflects the WGSL's actual
/// `@group/@binding` declarations and compares them, cell by cell, against the
/// bind-group layout `solveLayout(SchemaT)` produces. Returns the FIRST cell
/// where the WGSL declares a resource whose type the host layout doesn't
/// provide there (a texture where the host has a sampler, a binding the host
/// never lays out, etc.), or null when every WGSL binding is covered.
///
/// This is exactly the drift that otherwise surfaces only on-device as Dawn's
/// opaque "Binding type in the shader (sampler) doesn't match the type in the
/// layout (texture)" at pipeline creation — the 6-texture PBR bug. Calling this
/// at pipeline-init time (or in a test with the embedded WGSL) turns that into a
/// named cell. It only checks WGSL⊆host: a host entry the WGSL doesn't use is
/// allowed (WebGPU permits over-provisioned layouts, and Tint may drop unused
/// bindings). Caller owns nothing; the function frees its own scratch.
pub fn layoutWgslMismatch(
    gpa: std.mem.Allocator,
    comptime SchemaT: type,
    wgsl: []const u8,
) !?LayoutWgslMismatch {
    // Build the expected (group, binding) -> label map from the host layout.
    // Each sampler occupies TWO cells: a texture at N and a sampler at N+1.
    const Cell = struct { group: u32, binding: u32, label: []const u8 };
    const layout = comptime solveLayout(SchemaT);
    comptime var expected_len: usize = 0;
    inline for (layout.fields) |f| {
        expected_len += if (f.kind == .sampler_2d) 2 else 1;
    }
    var expected: [expected_len]Cell = undefined;
    var e: usize = 0;
    inline for (layout.fields) |f| {
        switch (f.kind) {
            .ubo => {
                expected[e] = .{ .group = f.group, .binding = f.binding, .label = "uniform" };
                e += 1;
            },
            .storage_buffer => {
                expected[e] = .{ .group = f.group, .binding = f.binding, .label = "storage" };
                e += 1;
            },
            .sampler_2d => {
                expected[e] = .{ .group = f.group, .binding = f.binding, .label = "texture" };
                expected[e + 1] = .{ .group = f.group, .binding = f.binding + 1, .label = "sampler" };
                e += 2;
            },
        }
    }

    const actual: []WgslBinding = try reflectWgslBindings(gpa, wgsl);
    defer freeWgslBindings(gpa, actual);

    for (actual) |a| {
        const found: []const u8 = kindLabelWgsl(a.kind);
        var host_label: []const u8 = "<nothing>";
        var ok: bool = false;
        for (expected) |c| {
            if (c.group == a.group and c.binding == a.binding) {
                host_label = c.label;
                ok = eql(u8, c.label, found);
                break;
            }
        }
        if (!ok) {
            return .{
                .group = a.group,
                .binding = a.binding,
                .name = a.name,
                .expected = host_label,
                .found = found,
            };
        }
    }
    return null;
}

/// Verify the schema's UBO field names + types match what the WGSL
/// transpiler emitted.  Currently a no-op stub — wired up once
/// `shader_compile.zig` has reflection data from the transpiler.  For the
/// binding-location cross-check that IS implemented, see `layoutWgslMismatch`.
pub fn validateSchemaMatchesWgsl(
    comptime ShaderIo: type,
    comptime wgsl_meta: anytype,
) void {
    _ = ShaderIo;
    _ = wgsl_meta;
    // TODO: when shader_compile.zig's transpiler returns reflection
    // metadata, walk both sides and emit @compileError on any mismatch.
}

// ============================================================================
// SECTION 4 — WGSL binding reflection (the "shader inspection" surface)
// ============================================================================
// A small, pure-Zig scanner that pulls resource bindings out of WGSL source:
// every `@group(N) @binding(M) var ...` global declaration, classified by
// address space / type. Apps writing custom-pipeline WGSL can dump exactly
// what bind-group layout their shader expects. The strings are owned (duped
// into the passed allocator); free with `freeWgslBindings`.

pub const WgslBinding = struct {
    group: u32,
    binding: u32,
    name: []const u8,
    kind: Kind,
    detail: []const u8,

    pub const Kind = enum { uniform, storage, sampler, texture, storage_texture, unknown };

    pub fn kindLabel(self: WgslBinding) []const u8 {
        return switch (self.kind) {
            .uniform => "uniform",
            .storage => "storage",
            .sampler => "sampler",
            .texture => "texture",
            .storage_texture => "storage_texture",
            .unknown => "unknown",
        };
    }
};

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Read the unsigned integer inside the first `attr(...)` occurrence, e.g.
/// `parenU32(chunk, "@group")` on `@group(2)` returns 2.
fn parenU32(chunk: []const u8, attr: []const u8) ?u32 {
    const at: usize = std.mem.indexOf(u8, chunk, attr) orelse return null;
    var i: usize = at + attr.len;
    while (i < chunk.len and (chunk[i] == ' ' or chunk[i] == '\t' or chunk[i] == '(')) : (i += 1) {}
    const start: usize = i;
    while (i < chunk.len and chunk[i] >= '0' and chunk[i] <= '9') : (i += 1) {}
    if (i == start) {
        return null;
    }
    return std.fmt.parseInt(u32, chunk[start..i], 10) catch null;
}

/// Find `word` as a standalone token (identifier boundaries on both sides).
fn indexOfWord(haystack: []const u8, word: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, word)) |at| {
        const before_ok: bool = at == 0 or !isIdentChar(haystack[at - 1]);
        const after: usize = at + word.len;
        const after_ok: bool = after >= haystack.len or !isIdentChar(haystack[after]);
        if (before_ok and after_ok) {
            return at;
        }
        from = at + 1;
    }
    return null;
}

/// Copy `wgsl` into `dst` with `//` line comments and `/* */` block comments
/// replaced by spaces (lengths preserved isn't required; we just drop them).
/// Returns the cleaned length written.
fn stripComments(dst: []u8, wgsl: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < wgsl.len) {
        if (i + 1 < wgsl.len and wgsl[i] == '/' and wgsl[i + 1] == '/') {
            while (i < wgsl.len and wgsl[i] != '\n') : (i += 1) {}
        } else if (i + 1 < wgsl.len and wgsl[i] == '/' and wgsl[i + 1] == '*') {
            i += 2;
            while (i + 1 < wgsl.len and !(wgsl[i] == '*' and wgsl[i + 1] == '/')) : (i += 1) {}
            i += 2;
        } else {
            dst[w] = wgsl[i];
            w += 1;
            i += 1;
        }
    }
    return w;
}

/// Reflect every `@group(N) @binding(M) var ...` declaration out of WGSL.
/// Caller owns the result; free with `freeWgslBindings`.
pub fn reflectWgslBindings(gpa: std.mem.Allocator, wgsl: []const u8) ![]WgslBinding {
    const clean: []u8 = try gpa.alloc(u8, wgsl.len);
    defer gpa.free(clean);
    const clean_len: usize = stripComments(clean, wgsl);
    const src: []const u8 = clean[0..clean_len];

    var out: std.ArrayList(WgslBinding) = .empty;
    errdefer {
        for (out.items) |b| {
            gpa.free(b.name);
            gpa.free(b.detail);
        }
        out.deinit(gpa);
    }

    var stmts = std.mem.splitScalar(u8, src, ';');
    while (stmts.next()) |chunk| {
        if (std.mem.indexOf(u8, chunk, "@group") == null) {
            continue;
        }
        const var_at: usize = indexOfWord(chunk, "var") orelse continue;
        const group: u32 = parenU32(chunk, "@group") orelse continue;
        const binding: u32 = parenU32(chunk, "@binding") orelse continue;

        var p: usize = var_at + 3;
        var addr: []const u8 = "";
        while (p < chunk.len and (chunk[p] == ' ' or chunk[p] == '\t')) : (p += 1) {}
        if (p < chunk.len and chunk[p] == '<') {
            const close: usize = std.mem.indexOfScalarPos(u8, chunk, p, '>') orelse continue;
            addr = std.mem.trim(u8, chunk[p + 1 .. close], " \t\r\n");
            p = close + 1;
        }
        const colon: usize = std.mem.indexOfScalarPos(u8, chunk, p, ':') orelse continue;
        const name: []const u8 = std.mem.trim(u8, chunk[p..colon], " \t\r\n");
        const type_str: []const u8 = std.mem.trim(u8, chunk[colon + 1 ..], " \t\r\n");

        var kind: WgslBinding.Kind = .unknown;
        var detail: []const u8 = type_str;
        if (std.mem.startsWith(u8, addr, "uniform")) {
            kind = .uniform;
            detail = type_str;
        } else if (std.mem.startsWith(u8, addr, "storage")) {
            kind = .storage;
            detail = addr;
        } else if (std.mem.startsWith(u8, type_str, "sampler")) {
            kind = .sampler;
        } else if (std.mem.startsWith(u8, type_str, "texture_storage")) {
            kind = .storage_texture;
        } else if (std.mem.startsWith(u8, type_str, "texture")) {
            kind = .texture;
        }

        try out.append(gpa, .{
            .group = group,
            .binding = binding,
            .name = try gpa.dupe(u8, name),
            .kind = kind,
            .detail = try gpa.dupe(u8, detail),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeWgslBindings(gpa: std.mem.Allocator, bindings: []const WgslBinding) void {
    for (bindings) |b| {
        gpa.free(b.name);
        gpa.free(b.detail);
    }
    gpa.free(bindings);
}

// ============================================================================
// Tests
// ============================================================================

test "validateUboLayoutComptime accepts a sane UBO" {
    const Sane = struct {
        time: f32,
        screen_w: f32,
        screen_h: f32,
        _pad: f32 = 0,
    };
    comptime validateUboLayoutComptime(Sane);
}

test "autoMaterialBindGroupLayout emits expected entries for Ubo-only schema" {
    const Schema = struct {
        pub const Ubo = struct {
            time: f32,
            screen_w: f32,
            screen_h: f32,
            _pad: f32 = 0,
        };
    };
    const entries = comptime autoMaterialBindGroupLayout(Schema);
    try expectEqual(@as(usize, 1), entries.len);
    try expectEqual(@as(u32, 0), entries[0].binding);
    try expect(entries[0].visibility.vertex);
    try expect(entries[0].visibility.fragment);
    switch (entries[0].resource) {
        .uniform_buffer => |ub| {
            try expectEqual(@as(u64, 16), ub.min_size);
        },
        else => return error.TestExpectedUniformBuffer,
    }
}

test "autoMaterialBindGroupLayout emits texture+sampler pair per Samplers field" {
    const Schema = struct {
        pub const Ubo = struct { time: f32, _pad: [3]f32 = .{ 0, 0, 0 } };
        pub const Samplers = struct {
            albedo: u8,
            normal: u8,
        };
    };
    const entries = comptime autoMaterialBindGroupLayout(Schema);
    // 1 ubo + 2 samplers × (tex + sampler) = 5 entries
    try expectEqual(@as(usize, 5), entries.len);
    try expectEqual(@as(u32, 1), entries[1].binding);
    try expectEqual(@as(u32, 2), entries[2].binding);
    try expectEqual(@as(u32, 3), entries[3].binding);
    try expectEqual(@as(u32, 4), entries[4].binding);
}

test "autoStorageBindGroupLayout emits storage buffer per Storage field" {
    const StorageBuf = struct {
        pub const access: enum { read, read_write } = .read_write;
    };
    const Schema = struct {
        pub const Storage = struct {
            positions: StorageBuf,
            velocities: StorageBuf,
            densities: StorageBuf,
        };
    };
    const entries = comptime autoStorageBindGroupLayout(Schema);
    try expectEqual(@as(usize, 3), entries.len);
    for (entries, 0..) |e, i| {
        try expectEqual(@as(u32, @intCast(i)), e.binding);
        switch (e.resource) {
            .storage_buffer => |sb| try expect(!sb.read_only),
            else => return error.TestExpectedStorageBuffer,
        }
    }
}

test "schema with neither Ubo nor Samplers yields empty layout" {
    const Empty = struct {};
    const entries = comptime autoMaterialBindGroupLayout(Empty);
    try expectEqual(@as(usize, 0), entries.len);
}

// ---- solveLayout tests (turn 1 of finishing_new_gpu_foundations.md) ----

const shader = @import("shader_interface");

test "solveLayout empty schema produces empty layout" {
    const Empty = struct {};
    const layout = comptime solveLayout(Empty);
    try expectEqual(@as(usize, 0), layout.fields.len);
    try expectEqual(@as(u8, 0), layout.groups_used);
}

test "solveLayout single sampler — default group/binding" {
    const S = struct {
        pub const Samplers = struct {
            texture0: shader.Sampler2D(.albedo, .{}),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(usize, 1), layout.fields.len);

    const f: ResolvedField = layout.fields[0];
    try expectEqualStrings("texture0", f.name);
    try expectEqual(FieldKind.sampler_2d, f.kind);
    try expectEqual(@as(u32, 1), f.group); // sampler default
    try expectEqual(@as(u32, 0), f.binding);
    try expectEqual(ResolvedField.Origin.solver_default, f.origin);

    // Group 1 used
    try expectEqual(@as(u8, 0b0010), layout.groups_used);
}

test "solveLayout multiple samplers — each reserves a texture+sampler pair" {
    const S = struct {
        pub const Samplers = struct {
            albedo: shader.Sampler2D(.albedo, .{}),
            normal: shader.Sampler2D(.normal, .{}),
            metallic: shader.Sampler2D(.metalness, .{}),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(usize, 3), layout.fields.len);

    // Each Sampler2D takes TWO bindings (texture at N, synthesized sampler at
    // N+1), so the texture bindings step by 2: 0, 2, 4. Without this the paired
    // samplers (1, 3, 5) would collide with the next texture — the multi-texture
    // PBR bug Dawn rejects.
    try expectEqual(@as(u32, 0), layout.fields[0].binding);
    try expectEqual(@as(u32, 2), layout.fields[1].binding);
    try expectEqual(@as(u32, 4), layout.fields[2].binding);
    for (layout.fields) |f| {
        try expectEqual(@as(u32, 1), f.group);
        try expectEqual(ResolvedField.Origin.solver_default, f.origin);
    }
}

test "solveLayout pinned sampler is respected" {
    const S = struct {
        pub const Samplers = struct {
            shadow_map: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 3, .binding = 5 } }),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(u32, 3), layout.fields[0].group);
    try expectEqual(@as(u32, 5), layout.fields[0].binding);
    try expectEqual(ResolvedField.Origin.pinned, layout.fields[0].origin);
}

test "solveLayout shared sampler is respected" {
    const shadow_loc: shader.SharedLocation = comptime shader.shared(.{ .group = 3, .binding = 0 });
    const S = struct {
        pub const Samplers = struct {
            shadow_map: shader.Sampler2D(.cubemap, .{ .shared = shadow_loc.loc }),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(u32, 3), layout.fields[0].group);
    try expectEqual(@as(u32, 0), layout.fields[0].binding);
    try expectEqual(ResolvedField.Origin.shared, layout.fields[0].origin);
}

test "solveLayout pinned + free skip claimed cells" {
    // shadow_map pins (1, 0) and (as a Sampler2D) also occupies its paired
    // sampler cell (1, 1). Each free sampler reserves a texture+sampler pair,
    // so albedo lands at (1, 2)+(1, 3) and normal at (1, 4)+(1, 5).
    const S = struct {
        pub const Samplers = struct {
            shadow_map: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 1, .binding = 0 } }),
            albedo: shader.Sampler2D(.albedo, .{}),
            normal: shader.Sampler2D(.normal, .{}),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(usize, 3), layout.fields.len);
    // shadow_map: pinned at (1, 0)
    try expectEqual(@as(u32, 1), layout.fields[0].group);
    try expectEqual(@as(u32, 0), layout.fields[0].binding);
    try expectEqual(ResolvedField.Origin.pinned, layout.fields[0].origin);
    // albedo: 0 and its sampler 1 are taken by the pin → texture (1, 2)
    try expectEqual(@as(u32, 1), layout.fields[1].group);
    try expectEqual(@as(u32, 2), layout.fields[1].binding);
    // normal: next pair → texture (1, 4)
    try expectEqual(@as(u32, 1), layout.fields[2].group);
    try expectEqual(@as(u32, 4), layout.fields[2].binding);
}

test "solveLayout pinned in middle slot — free pairs fill around it" {
    // pin at (1, 2), which also reserves its sampler cell (1, 3). Each free
    // sampler reserves a texture+sampler pair: free_a → (1, 0)+(1, 1); free_b
    // can't use 2 or 3 so → (1, 4)+(1, 5); free_c → (1, 6)+(1, 7).
    const S = struct {
        pub const Samplers = struct {
            free_a: shader.Sampler2D(.albedo, .{}),
            free_b: shader.Sampler2D(.normal, .{}),
            pinned_mid: shader.Sampler2D(.metalness, .{ .pinned = .{ .group = 1, .binding = 2 } }),
            free_c: shader.Sampler2D(.occlusion, .{}),
        };
    };
    const layout = comptime solveLayout(S);
    try expectEqual(@as(usize, 4), layout.fields.len);
    // free_a: texture (1, 0), sampler (1, 1)
    try expectEqual(@as(u32, 0), layout.fields[0].binding);
    // free_b: 2 (pin) and 3 (pin's sampler) taken, so the pair goes to (1, 4)
    try expectEqual(@as(u32, 4), layout.fields[1].binding);
    // pinned_mid: (1, 2) by config
    try expectEqual(@as(u32, 2), layout.fields[2].binding);
    try expectEqual(ResolvedField.Origin.pinned, layout.fields[2].origin);
    // free_c: next pair → (1, 6), sampler (1, 7)
    try expectEqual(@as(u32, 6), layout.fields[3].binding);
}

test "solveLayout groups_used bitmask reflects every used group" {
    const S = struct {
        pub const Samplers = struct {
            a: shader.Sampler2D(.albedo, .{}),
            b: shader.Sampler2D(.normal, .{ .pinned = .{ .group = 3, .binding = 0 } }),
        };
    };
    const layout = comptime solveLayout(S);
    // Groups 1 (default sampler) + 3 (pinned).
    try expectEqual(@as(u8, 0b1010), layout.groups_used);
}

test "assertVaryingsMatch: matching VS.Outputs / FS.Inputs compiles" {
    const Vs = struct {
        pub const Outputs = struct {
            frag_tex_coord: Vec2,
            frag_normal: Vec3,
        };
    };
    const Fs = struct {
        pub const Inputs = struct {
            frag_tex_coord: Vec2,
            frag_normal: Vec3,
        };
    };
    // If the fields drifted (name/type/order/count) this would be a
    // @compileError and the test file would not build — so reaching here is
    // the assertion.
    assertVaryingsMatch(Vs, Fs);
}

test "assertVaryingsMatch: both stages varying-free compiles" {
    const Vs = struct {}; // fullscreen VS: only the built-in clip position
    const Fs = struct {}; // FS reads no interpolated inputs
    assertVaryingsMatch(Vs, Fs);
}

test "reflectWgslBindings: classifies uniform/storage/texture/sampler" {
    const wgsl: []const u8 =
        \\// a comment with @group(9) @binding(9) var fake: u32; that must be ignored
        \\@group(0) @binding(0) var<uniform> light: Light;
        \\@group(0) @binding(1) var<storage, read> instances: array<Instance>;
        \\@group(1) @binding(0) var tex: texture_2d<f32>;
        \\@group(1) @binding(1) var samp: sampler;
        \\@group(2) @binding(0) var img: texture_storage_2d<rgba8unorm, write>;
        \\var<private> not_a_binding: f32;
    ;
    const bindings: []WgslBinding = try reflectWgslBindings(std.testing.allocator, wgsl);
    defer freeWgslBindings(std.testing.allocator, bindings);

    try expectEqual(@as(usize, 5), bindings.len);

    try expectEqual(@as(u32, 0), bindings[0].group);
    try expectEqual(@as(u32, 0), bindings[0].binding);
    try expectEqualStrings("light", bindings[0].name);
    try expectEqual(WgslBinding.Kind.uniform, bindings[0].kind);

    try expectEqualStrings("instances", bindings[1].name);
    try expectEqual(WgslBinding.Kind.storage, bindings[1].kind);
    try expectEqualStrings("storage, read", bindings[1].detail);

    try expectEqual(WgslBinding.Kind.texture, bindings[2].kind);
    try expectEqual(WgslBinding.Kind.sampler, bindings[3].kind);
    try expectEqual(WgslBinding.Kind.storage_texture, bindings[4].kind);
}

test "reflectWgslBindings: empty when no bindings" {
    const wgsl: []const u8 =
        \\@vertex fn vs_main() -> @builtin(position) vec4<f32> {
        \\  return vec4<f32>(0.0);
        \\}
    ;
    const bindings: []WgslBinding = try reflectWgslBindings(std.testing.allocator, wgsl);
    defer freeWgslBindings(std.testing.allocator, bindings);
    try expectEqual(@as(usize, 0), bindings.len);
}

// A two-sampler FS schema: samplers default to group 1, interleaved as
// texture@0/sampler@1, texture@2/sampler@3 (the same pairing solveSamplerSlots
// gives the WGSL codegen).
const TwoSamplerFs = struct {
    pub const Inputs = struct {};
    pub const Samplers = struct {
        albedo: shader.Sampler2D(.albedo, .{}),
        normal: shader.Sampler2D(.normal, .{}),
    };
};

test "layoutWgslMismatch: interleaved WGSL matches the host layout" {
    // The correct, schema-derived WGSL: each texture at 2i, its sampler at 2i+1.
    const wgsl: []const u8 =
        \\@group(1) @binding(0) var albedo: texture_2d<f32>;
        \\@group(1) @binding(1) var albedo_s: sampler;
        \\@group(1) @binding(2) var normal: texture_2d<f32>;
        \\@group(1) @binding(3) var normal_s: sampler;
    ;
    const m = try layoutWgslMismatch(std.testing.allocator, TwoSamplerFs, wgsl);
    try expect(m == null);
}

test "layoutWgslMismatch: catches the block-scheme drift (device bug #3 shape)" {
    // The stale BLOCK layout that shipped in helmet_sw: textures packed @0,1,
    // samplers @2,3. Against the interleaved host layout, @group(1)@binding(1)
    // is a texture in the WGSL but a sampler in the host layout — exactly what
    // Dawn rejected. The cross-check must catch it HERE, at test time, and name
    // the cell + both types.
    const wgsl: []const u8 =
        \\@group(1) @binding(0) var albedo: texture_2d<f32>;
        \\@group(1) @binding(1) var normal: texture_2d<f32>;
        \\@group(1) @binding(2) var albedo_s: sampler;
        \\@group(1) @binding(3) var normal_s: sampler;
    ;
    const m = try layoutWgslMismatch(std.testing.allocator, TwoSamplerFs, wgsl);
    try expect(m != null);
    try expectEqual(@as(u32, 1), m.?.group);
    try expectEqual(@as(u32, 1), m.?.binding);
    try expectEqualStrings("sampler", m.?.expected);
    try expectEqualStrings("texture", m.?.found);
}

test "layoutWgslMismatch: catches a binding the host never lays out" {
    // A WGSL that samples a texture at a group the schema doesn't use at all.
    const wgsl: []const u8 =
        \\@group(1) @binding(0) var albedo: texture_2d<f32>;
        \\@group(1) @binding(1) var albedo_s: sampler;
        \\@group(3) @binding(7) var rogue: texture_2d<f32>;
    ;
    const m = try layoutWgslMismatch(std.testing.allocator, TwoSamplerFs, wgsl);
    try expect(m != null);
    try expectEqual(@as(u32, 3), m.?.group);
    try expectEqual(@as(u32, 7), m.?.binding);
    try expectEqualStrings("<nothing>", m.?.expected);
}
