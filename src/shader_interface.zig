//! SHADER-SAFE - this file may be @imported by shader sources
//! (compiled through the SPIR-V pipeline) and by comptime executors.
//! Lint enforces the tier: no allocators, no runtime std, no externs,
//! no bridge imports outside `test` blocks. `zm` is allowed: it is
//! self-contained (build_options baked in; its host-only std.log branch
//! is comptime-dead on the SPIR-V target) and every consumer already
//! wires it alongside shader_interface, so importing it here gives the
//! Vec/Vec2/Vec3 aliases without breaking the shader-safe tier.
//!
//! src/shader_interface.zig - schema wrapper types for typed shaders.
//!
//! This module declares the small set of generic wrapper types that
//! shader interface files (`*_io.zig`) use to describe a shader's
//! external boundary: which samplers it has and at which slots they
//! bind, which vertex attributes it consumes and at which locations,
//! and how to compose common uniform sets across shaders.
//!
//! Wrapper types here are PURE METADATA carriers - they're parameterized
//! over comptime values (slot numbers, element kinds, location indices)
//! and store those values as `pub const` declarations on the returned
//! type.  Engine code introspects these constants via `@field(T, "slot")`
//! etc. to drive auto-binding without runtime cost.
//!
//! Three responsibilities:
//!   1. `Sampler2D(MaterialMapIndex)` / `Sampler2D.atSlot(N)` - tag a
//!      sampler with the texture-unit slot it should bind to.
//!   2. `Attr(ElemKind, location)` - declare vertex-attribute element
//!      type + GLSL `layout(location = N)` annotation.
//!   3. `merge(.{ A, B, C })` - comptime struct-merge for composing
//!      common uniform sets (Lighting, Fog, Shadow, ...) into a single
//!      `Uniforms` struct per shader.
//!
//! Everything is comptime.  At runtime these types have zero size and
//! their existence is purely a compile-time contract.  The codegen
//! step (Phase 2) reads these declarations to emit `extern const` GLSL
//! bindings; the runtime layer (`shader_runtime.zig`) reads them to
//! drive auto-binding.

const std = @import("std");
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Material-map slot indices.  These define the conventional slot
/// numbers used by the typed shader pipeline's `Sampler2D(.X)` markers
/// AND by `Material.maps[N]` on the engine side.  Same enum used in
/// both worlds keeps shader-side declarations and host-side material
/// assignment in sync - a `Sampler2D(.albedo)` in a shader iface and
/// a `material.maps[.albedo].texture = ...` on the host both refer to
/// slot 0.
///
/// Defined here (in the typed-shader interface module) because it's
/// fundamentally a shader-binding concept - the slot enum is part of
/// how a shader declares what textures it needs.  `src/types.zig`
/// re-exports it from here for engine-side users (`Material`, etc.)
/// so existing call sites can keep using `MaterialMapIndex`.
///
/// Defining it here instead of in `types.zig` lets the shader-interface
/// module be self-contained - its module tree is just this single file,
/// so it can be wired as a named module dep on per-shader codegen
/// bootstrap exes without dragging `types.zig` into a second module
/// tree (which would error: "file in two modules").
pub const MaterialMapIndex = enum(i32) {
    albedo = 0,
    metalness,
    normal,
    roughness,
    occlusion,
    emission,
    height,
    cubemap,
    irradiance,
    prefilter,
    brdf,
    // raylib aliases.
    pub const diffuse: MaterialMapIndex = .albedo;
    pub const specular: MaterialMapIndex = .metalness;
};

// ===========================================================================
// BINDING-GROUP RULE - single source of truth (shared by codegen + solver)
// ===========================================================================
//
// The @group a shader's resources bind to is decided in TWO places that MUST
// agree, or the GPU rejects the pipeline at creation ("Invalid RenderPipeline
// due to a previous error" - the zimr324 bug):
//   - `tools/gen_shader_externs.zig` sets the WGSL `@group(N)` decorations.
//   - `shader_introspect.solveLayout` builds the matching host bind groups.
// Both call the functions below so they can NEVER drift. The stage is detected
// STRUCTURALLY: a VS schema declares `Attributes`; everything else (an FS schema
// with `Inputs`, or a lone uniform schema) is treated as fragment-stage.

/// The `@group` a uniform block (`Ubo` / `Uniforms`) binds to, by stage:
///   - VS schema (declares `Attributes`)           -> group 0
///   - FS schema (declares `Inputs`, no Attributes) -> group 2
///   - neither (a MERGED material schema whose UBO is VS-stage, e.g. the 2D
///     shapes `EngineSchema`)                        -> group 0
/// Group 1 is reserved for material samplers (`sampler_group`), so a two-stage
/// pipeline's VS and FS uniforms never collide. The codegen only ever processes
/// pure VS/FS io files (so it never hits the final case); only `solveLayout`
/// sees merged schemas - both stay correct from this one rule.
pub fn uniformGroupForSchema(comptime SchemaT: type) u32 {
    // Explicit override: a schema may pin its uniform block to a specific group
    // by declaring `pub const ubo_group: u32 = N`. Used by shaders whose UBO
    // doesn't follow the stage-default scheme - e.g. the decal FS, whose
    // projector UBO sits at group 1 (with the decal texture pinned to group 2).
    // Because BOTH the codegen and `solveLayout` read the group through this one
    // function, an override keeps the emitted @group and the host layout in
    // lockstep automatically.
    if (@hasDecl(SchemaT, "ubo_group")) {
        if (SchemaT.ubo_group >= 4) {
            @compileError(
                "Schema's `ubo_group` must be 0..3 (WebGPU's guaranteed bind-group " ++
                    "count); got a larger value. Pick a group in range.",
            );
        }
        return SchemaT.ubo_group;
    }
    if (@hasDecl(SchemaT, "Attributes")) {
        return 0; // vertex stage
    }
    if (@hasDecl(SchemaT, "Inputs")) {
        return 2; // fragment stage
    }
    return 0; // merged/ambiguous schema -> treat the UBO as vertex-stage
}

/// The default `@group` for material samplers/textures. Reserved engine-wide
/// (the 2D shapes batch binds its atlas here too - see
/// `gpu_iface.batch_reserved_group`). Overridable per-field via a `Sampler2D`
/// `.pinned`/`.shared` config.
pub const sampler_group: u32 = 1;

/// Discriminator for sampler binding source.  `.material_map` means
/// "this sampler reads from `material.maps[slot].texture`" via
/// `drawMesh`'s auto-binding loop.  `.explicit` means "the engine
/// binds slot N specifically (e.g., shadow map, render target)".
pub const SamplerKind = enum { material_map, explicit };

/// Explicit `(group, binding)` pair.  Common to all resource
/// configs.  Bare `BindingLocation` constructible as
/// `.{ .group = N, .binding = M }`.
pub const BindingLocation = struct {
    group: u32,
    binding: u32,
};

/// Configuration for a sampler binding's location in the bind-group
/// layout.  Passed as the second argument to `Sampler2D(tag, config)`.
///
/// All fields optional; `.{}` accepts every default and lets the
/// layout solver decide (UBO -> group 0, sampler -> group 1, dense
/// in declaration order within each group).  See
/// `src/notes/finishing_new_gpu_foundations.md` turn 1 for the
/// rules.
///
/// Override the defaults for cross-shader binding agreement.
/// `.shared(SharedLocation)` pins to an externally-declared
/// location; `.pinned(...)` pins to a per-shader-explicit
/// `(group, binding)` cell.  These two are semantically distinct
/// even though the mechanism is the same: `.shared` signals
/// "this resource is used by multiple shader programs and must
/// land at this fixed location," while `.pinned` signals "I want
/// THIS shader's resource at this specific cell."
/// Which shader stages may sample a texture binding. Default fragment-only;
/// set `.vertex = true` for vertex-shader texture fetch (pair with the
/// derivative-free `sampleLevel` builtin, which lowers to `textureSampleLevel`).
pub const Stages = struct { vertex: bool = false, fragment: bool = true };

pub const SamplerConfig = struct {
    /// Explicit `(group, binding)` pin.  When set, the solver
    /// respects it; everything else falls into the free pool.
    /// Use `null` for solver-assigned location.
    pinned: ?BindingLocation = null,

    /// Same mechanism as `pinned` but distinct in intent:
    /// signals cross-shader coupling via a named
    /// `SharedLocation` value declared once in a shared module.
    /// Both `pinned` and `shared` can't be set on the same field
    /// (comptime check).
    shared: ?BindingLocation = null,

    /// Stages allowed to sample this texture. Default fragment-only; opt into
    /// `.{ .vertex = true }` (or both stages) for vertex-shader sampling.
    stages: Stages = .{ .fragment = true },
};

/// Cross-shader binding anchor.  Declared once in a shared module,
/// referenced by every shader that participates in the coupling.
/// Type-system enforces consistency: rename the shared declaration,
/// every consumer breaks at compile time until updated.
///
/// Wrapped struct (rather than a plain alias for `BindingLocation`)
/// so calls like `.shared(loc)` versus `.pinned(.{...})` carry
/// distinct intent in the schema.
pub const SharedLocation = struct {
    loc: BindingLocation,
};

/// Constructor for the shared-location case.  Pattern:
/// ```
/// pub const engine_locations = struct {
///     pub const shadow_map = zimr.shader.shared(.{ .group = 3, .binding = 0 });
/// };
/// // In a shader schema:
/// shadow_map: zimr.shader.Sampler2D(.shadow_map, .{ .shared = engine_locations.shadow_map.loc }),
/// ```
pub fn shared(loc: BindingLocation) SharedLocation {
    return .{ .loc = loc };
}

/// Returns a marker type for a 2D texture sampler bound to the given
/// material-map slot.  Use as a FIELD TYPE in a shader's `Samplers`
/// struct, never as a value:
///
/// ```zig
/// pub const Samplers = struct {
///     base_color: zimr.shader.Sampler2D(.albedo, .{}),
///     metallic_roughness: zimr.shader.Sampler2D(.metalness, .{}),
/// };
/// ```
///
/// The returned type carries the slot number AND the layout config
/// as comptime constants.  Engine `loadShader` walks the schema's
/// `Samplers` struct, reads `@field(SamplerT, "config")` to get the
/// `(group, binding)` hints, and emits matching decorations on the
/// SPIR-V side (via `zm_binding`).
///
/// `config` is `SamplerConfig`; `.{}` accepts every default.  The
/// empty struct literal IS the marker - it tells readers "there's
/// configuration here, it's just defaulted" rather than letting them
/// forget the marker exists.  Matches `std.ArrayList(T).initCapacity`
/// style where the config arg is required-but-defaulted.
///
/// For samplers not tied to a `MaterialMapIndex` (e.g. shadow maps,
/// secondary render targets), use `Sampler2D_atSlot(N, .{})` instead.
pub fn Sampler2D(comptime tag: MaterialMapIndex, comptime config: SamplerConfig) type {
    // Comptime check: can't have both .pinned and .shared.
    if (config.pinned != null and config.shared != null) {
        @compileError(
            "Sampler2D(." ++ @tagName(tag) ++ ", ...): " ++
                "`.pinned` and `.shared` are mutually exclusive — " ++
                "`.pinned` for per-shader explicit cells, `.shared` for " ++
                "cross-shader coupling.  Pick one.",
        );
    }
    return struct {
        pub const slot: u32 = @backingInt(tag);
        pub const kind: SamplerKind = .material_map;
        pub const map_index: MaterialMapIndex = tag;
        pub const sampler_config: SamplerConfig = config;
    };
}

/// Marker type for a sampler bound to an explicit texture-unit slot,
/// not a material-map index.  Used for samplers that the engine binds
/// outside the material-map loop (shadow maps live at slot 8 by
/// convention, render-target inputs typically at slot 10+, etc.).
pub fn Sampler2D_atSlot(comptime n: u32, comptime config: SamplerConfig) type {
    if (config.pinned != null and config.shared != null) {
        @compileError("Sampler2D_atSlot: .pinned and .shared are mutually exclusive.");
    }
    return struct {
        pub const slot: u32 = n;
        pub const kind: SamplerKind = .explicit;
        pub const sampler_config: SamplerConfig = config;
    };
}

/// Future: `SamplerCube`, `Sampler3D`, `Sampler2DArray`.  Same pattern.

// ===========================================================================
// RESOURCE BINDING PLACEMENT - THE single source of truth
// ===========================================================================
//
// `uniformGroupForSchema` (above), `solveSamplerSlots`, and `solveStorageSlots`
// are the ONLY place resource `(group, binding)` locations are decided. Both
// consumers call them:
//   - the host bind-group layout: `shader_introspect.solveLayout`, and
//   - the SPIR-V binding codegen: `tools/gen_shader_externs.zig`
//     (which emits the `@group/@binding` decorations the shipping WGSL carries).
// Because both sides run the SAME computation, the shader's declared bindings
// and the host layout are identical by construction and cannot drift.
//
// This replaced three hand-kept copies of the sampler solver that had to stay
// byte-identical and didn't - the drift produced two on-device Dawn failures (a
// binding collision and a texture/sampler type mismatch) that nothing but a
// phone could catch. shader_interface is the right home: it carries no host
// (wgpu) dependency, so the codegen tier can import it (importing
// shader_introspect would drag in wgpu.zig). For an independent, test-time
// verification that the two sides agree, see
// `shader_introspect.layoutWgslMismatch`.

/// Where a sampler's (group, binding) came from. Mirrors
/// `shader_introspect.ResolvedField.Origin` (kept in sync by value).
pub const SamplerSlotOrigin = enum { solver_default, pinned, shared };

/// The resolved location of one `Samplers` field. A Sampler2D occupies TWO
/// WebGPU bindings: the texture at `binding` and its paired sampler at
/// `binding + 1`.
pub const SamplerSlot = struct {
    group: u32,
    /// Texture binding; the paired sampler sits at `binding + 1`.
    binding: u32,
    origin: SamplerSlotOrigin,
    stages: Stages = .{ .fragment = true },
};

/// Field count of a `Samplers` struct - the length of `solveSamplerSlots`'s
/// return array.
pub fn samplerFieldCount(comptime SamplersT: type) usize {
    return @typeInfo(SamplersT).@"struct".field_types.len;
}

/// THE single authority for assigning `(group, binding)` to each field of a
/// `Samplers` struct, in declaration order. Both the host bind-group-layout
/// solver (`shader_introspect.solveLayout`) and the SPIR-V binding codegen
/// (`tools/gen_shader_externs.zig`) call this, so the emitted WGSL
/// `@group/@binding` decorations and the host layout are derived from ONE
/// place and can never disagree. (Before this, three hand-kept copies of the
/// algorithm drifted, producing two on-device Dawn failures: a binding
/// collision and a texture/sampler type mismatch.)
///
/// Each `Sampler2D` takes TWO bindings - texture at N, paired sampler at N+1
/// (zspv_rewrite synthesizes the sampler half there; the host mirrors it). A
/// free (unpinned/unshared) sampler takes the lowest N in `sampler_group`
/// where BOTH N and N+1 are unclaimed, then advances by 2. Without reserving
/// N+1, the next texture would land on the previous sampler's slot - the
/// multi-texture PBR collision. Pinned/shared fields keep their explicit cell.
pub fn solveSamplerSlots(comptime SamplersT: type) [samplerFieldCount(SamplersT)]SamplerSlot {
    return comptime blk: {
        const sinfo = @typeInfo(SamplersT).@"struct";
        var slots: [sinfo.field_types.len]SamplerSlot = undefined;

        // Pass 1: claim pinned/shared cells (per-group 64-bit bitmask; WebGPU
        // guarantees 4 groups, and the solver tracks bindings 0-63). A pinned
        // sampler occupies BOTH its texture cell (binding) AND its paired
        // sampler cell (binding+1), so claim both - otherwise a free sampler
        // could land on a pinned sampler's +1 slot.
        var claimed: [4]u64 = .{ 0, 0, 0, 0 };
        for (sinfo.field_names, sinfo.field_types) |field_name, field_type| {
            if (!@hasDecl(field_type, "sampler_config")) {
                @compileError("`Samplers` field `" ++ field_name ++ "` of type `" ++
                    @typeName(field_type) ++ "` is not a sampler marker " ++
                    "(`Sampler2D(.<tag>, <config>)` / `Sampler2D_atSlot(...)`).");
            }
            const cfg: SamplerConfig = @field(field_type, "sampler_config");
            if (cfg.pinned) |p| {
                claimed[p.group] |= @as(u64, 1) << @intCast(p.binding);
                claimed[p.group] |= @as(u64, 1) << @intCast(p.binding + 1);
            }
            if (cfg.shared) |s| {
                claimed[s.group] |= @as(u64, 1) << @intCast(s.binding);
                claimed[s.group] |= @as(u64, 1) << @intCast(s.binding + 1);
            }
        }

        // Pass 2: assign each field in declaration order.
        var next_free: u32 = 0;
        for (sinfo.field_types, 0..) |field_type, i| {
            const cfg: SamplerConfig = @field(field_type, "sampler_config");
            if (cfg.pinned) |p| {
                slots[i] = .{ .group = p.group, .binding = p.binding, .origin = .pinned, .stages = cfg.stages };
                continue;
            }
            if (cfg.shared) |s| {
                slots[i] = .{ .group = s.group, .binding = s.binding, .origin = .shared, .stages = cfg.stages };
                continue;
            }
            const g: u32 = sampler_group;
            var b: u32 = next_free;
            while ((claimed[g] & (@as(u64, 1) << @intCast(b)) != 0) or
                (claimed[g] & (@as(u64, 1) << @intCast(b + 1)) != 0))
            {
                b += 1;
            }
            claimed[g] |= @as(u64, 1) << @intCast(b);
            claimed[g] |= @as(u64, 1) << @intCast(b + 1);
            next_free = b + 2;
            slots[i] = .{ .group = g, .binding = b, .origin = .solver_default, .stages = cfg.stages };
        }
        break :blk slots;
    };
}

/// The resolved location of one `Storage` field.
pub const StorageSlot = struct { group: u32, binding: u32 };

/// Field count of a schema's `Storage` struct (0 if it declares none) - the
/// length of `solveStorageSlots`'s return array.
pub fn storageFieldCount(comptime SchemaT: type) usize {
    if (!@hasDecl(SchemaT, "Storage")) {
        return 0;
    }
    return @typeInfo(SchemaT.Storage).@"struct".field_types.len;
}

/// THE single authority for assigning `(group, binding)` to each `Storage`
/// field, in declaration order. Both the host bind-group-layout solver
/// (`shader_introspect.solveLayout`) and the SPIR-V binding codegen
/// (`tools/gen_shader_externs.zig`) call this, so the emitted WGSL and the host
/// layout are derived from ONE place and can't drift.
///
/// Storage buffers bind in the stage's uniform group (`uniformGroupForSchema`),
/// at bindings AFTER the Ubo: base `1` when the schema has a `Ubo` (which takes
/// binding 0), else base `0`, then sequential.
pub fn solveStorageSlots(comptime SchemaT: type) [storageFieldCount(SchemaT)]StorageSlot {
    return comptime blk: {
        if (!@hasDecl(SchemaT, "Storage")) {
            break :blk .{};
        }
        const info = @typeInfo(SchemaT.Storage).@"struct";
        const group: u32 = uniformGroupForSchema(SchemaT);
        const base: u32 = if (@hasDecl(SchemaT, "Ubo")) 1 else 0;
        var slots: [info.field_types.len]StorageSlot = undefined;
        for (0..info.field_types.len) |i| {
            slots[i] = .{ .group = group, .binding = base + @as(u32, @intCast(i)) };
        }
        break :blk slots;
    };
}

// ===========================================================================
// STORAGE BUFFERS - read-only / read-write SSBO schema markers
// ===========================================================================

/// Access mode for a storage-buffer binding.  `.read` emits
/// `var<storage, read>` (the common case: a vertex/fragment stage reading
/// data a compute pass produced - e.g. instanced particle positions);
/// `.read_write` emits `var<storage, read_write>` (compute stages that
/// mutate the buffer).
pub const StorageAccess = enum { read, read_write };

/// Returns a marker type for a storage-buffer binding of element type
/// `Elem` (the buffer is a runtime array of `Elem`).  Use as a FIELD TYPE
/// in a shader's `Storage` struct, never as a value:
///
/// ```zig
/// pub const Storage = struct {
///     positions: zimr.shader.StorageBuf(Vec2, .read),
///     density:   zimr.shader.StorageBuf(Vec2, .read),
/// };
/// ```
///
/// The codegen emits, per field: the `storageBuffer(Elem, name, group,
/// binding)` extern + a `<name>(i)` accessor so the body reads
/// `io.positions(i)` instead of hand-writing
/// `ssboLoad(Vec2, positions, i)`.  Storage buffers bind in the SAME
/// group as the stage's uniform block, at bindings AFTER the UBO
/// (group 0 binding 1, 2, ... for a VS with a UBO at binding 0) - so the
/// generated layout matches the conventional hand-wired one.  `Resources`
/// reads this struct to auto-generate the matching bind-group layout
/// entries (`autoStorageBindGroupLayout`).
pub fn StorageBuf(comptime Elem: type, comptime access_mode: StorageAccess) type {
    return struct {
        pub const element: type = Elem;
        pub const access: StorageAccess = access_mode;
    };
}

// ===========================================================================
// BUILTINS - SPIR-V builtin inputs as first-class schema members
// ===========================================================================

/// The set of SPIR-V builtin inputs a shader can request by name in a
/// `Builtins` schema section.  These carry NO descriptor binding (they're
/// pipeline builtins, not resources) - declaring them just lets the body
/// read `io.vertex_index` / `io.instance_index` as typed fields instead of
/// reaching for `shader_externs.vertex_index` as a side-channel.
pub const BuiltinKind = enum { vertex_index, instance_index };

/// Marker for a builtin input field.  Use in a `Builtins` struct:
///
/// ```zig
/// pub const Builtins = struct {
///     vi: zimr.shader.Builtin(.vertex_index),
///     ii: zimr.shader.Builtin(.instance_index),
/// };
/// ```
pub fn Builtin(comptime kind: BuiltinKind) type {
    return struct {
        pub const builtin: BuiltinKind = kind;
    };
}

// ===========================================================================
// ATTRIBUTE TYPES (Q6)
// ===========================================================================

/// GLSL element type of a vertex attribute.  This determines the
/// `glVertexAttribPointer` call shape (component count + base type)
/// and the emitted GLSL declaration (`vec2`, `vec3`, `ivec4`, etc.).
///
/// Float vectors are by far the most common; integer attributes are
/// included for skinning (bone IDs as `uvec4`) and similar.
pub const ElemKind = enum {
    vec2, // 2 x f32
    vec3, // 3 x f32
    vec4, // 4 x f32
    ivec4, // 4 x i32
    uvec4, // 4 x u32
};

/// Returns a marker type describing a vertex attribute: its GLSL
/// element type and its `layout(location = N)` annotation.
///
/// ```zig
/// pub const Attributes = struct {
///     vertex_position: zimr.shader.Attr(.vec3, 0),
///     vertex_tex_coord: zimr.shader.Attr(.vec2, 1),
///     vertex_normal: zimr.shader.Attr(.vec3, 2),
///     vertex_tangent: zimr.shader.Attr(.vec4, 4),
/// };
/// ```
///
/// Schemas describe BINDINGS, not engine policy.  Whether the engine
/// auto-generates missing tangents is a separate concern handled in
/// `mesh_prep.zig` by field-name convention - see plan.md section "Engine
/// policy: schema-driven auto-fulfillment of missing mesh attributes".
pub fn Attr(comptime elem: ElemKind, comptime loc: u32) type {
    return struct {
        pub const element: ElemKind = elem;
        pub const location: u32 = loc;
    };
}

// ===========================================================================
// STRUCT MERGE (Q7) - comptime composition for common uniform sets
// ===========================================================================

/// Comptime helper that takes a tuple of struct types and produces a
/// new struct type with all their fields combined.  Default values
/// from the source structs flow through.  Field-name collisions
/// across source structs are a compile error.
///
/// Used to compose common uniform sets into per-shader `Uniforms`
/// structs without re-declaring shared fields in every shader:
///
/// ```zig
/// const lighting = @import("../common/lighting.zig");
/// const fog = @import("../common/fog.zig");
///
/// pub const Uniforms = zimr.shader.merge(.{
///     lighting.Lighting,
///     fog.Fog,
///     struct {
///         metallic_factor: f32 = 1.0,
///         roughness_factor: f32 = 1.0,
///     },
/// });
/// ```
///
/// Implementation: walk each source struct's fields, collect them
/// into a single flat list, check for name collisions, build a new
/// struct via `@Struct` (Zig 0.16's type-construction builtin).
pub fn merge(comptime structs: anytype) type {
    return comptime blk: {
        // Pass 1: count total fields and validate every source is a struct.
        var total: usize = 0;
        for (structs) |T| {
            const info = @typeInfo(T);
            if (info != .@"struct") {
                @compileError("merge: argument is not a struct type: " ++ @typeName(T));
            }
            total += info.@"struct".field_names.len;
        }

        // Pass 2: collect fields, checking for name collisions as we go.
        var names: [total][:0]const u8 = undefined;
        var field_types: [total]type = undefined;
        var attrs: [total]std.builtin.Type.Struct.FieldAttributes = undefined;
        var idx: usize = 0;

        for (structs) |T| {
            const si = @typeInfo(T).@"struct";
            // Zig 0.17.0-dev.1245: struct typeInfo is parallel arrays only
            // (`.fields` is gone); `field_attrs` already carries comptime-ness,
            // alignment, and default_value_ptr in exactly the shape @Struct
            // takes, so attributes pass straight through the merge.
            for (si.field_names, si.field_types, si.field_attrs) |f_name, f_type, f_attrs| {
                // Collision check against already-collected names.
                for (names[0..idx]) |existing| {
                    if (std.mem.eql(u8, existing, f_name)) {
                        @compileError(
                            "merge: field name collision: '" ++ f_name ++
                                "' appears in multiple source structs",
                        );
                    }
                }
                names[idx] = f_name;
                field_types[idx] = f_type;
                attrs[idx] = f_attrs;
                idx += 1;
            }
        }

        break :blk @Struct(.auto, null, &names, &field_types, &attrs);
    };
}

// ===========================================================================
// RESERVED UNIFORM NAMES (Q4, Q5)
// ===========================================================================

/// Reserved uniform names - engine-managed.  The engine populates
/// these uniforms automatically before every draw call.  Caller code
/// writing to a reserved name via `bind(Iface, sh).set(.X, ...)`
/// triggers a debug-build warning; the engine value overwrites it
/// regardless.  See plan.md section "Reserved uniform names" for the full
/// rationale and per-name semantics.
///
/// To opt out of engine management for a particular slot, give your
/// uniform a non-reserved name.  A shadow pass that wants its own
/// MVP names it `light_space_mvp`, not `mvp`.
pub const reserved_names = [_][]const u8{
    "mvp",
    "mat_model",
    "mat_view",
    "mat_projection",
    "mat_normal",
    "col_diffuse",
    "bone_matrices",
    "light_space_matrix",
};

/// Comptime check: is the given name in the reserved set?
pub fn isReservedName(comptime name: []const u8) bool {
    inline for (reserved_names) |r| {
        if (comptime std.mem.eql(u8, r, name)) {
            return true;
        }
    }
    return false;
}

// ===========================================================================
// SECTION - UBO wire layout (the GPU byte layout for plain-struct schemas)
// ===========================================================================
//
// Zig 0.17.0-dev.1245 disallows `@Vector` fields in `extern struct`s on CPU
// targets ("vectors have no guaranteed in-memory representation"), so schema
// `Ubo` types are now PLAIN structs: `Vec` math stays ergonomic for shader
// bodies and the CPU rasterizer, and the type is legal on every target. A
// plain struct has no guaranteed layout, so the bytes that reach the GPU are
// produced by the explicit serializer below instead of `std.mem.asBytes` on
// the whole struct.
//
// The layout these functions compute is the C/extern layout that the SPIR-V
// backend assigns to the generated `extern struct` mirror (the mirror is
// emitted by tools/gen_shader_externs.zig on the SPIR-V target, where vector
// fields remain legal) - the same offsets spv2wgsl carries into the WGSL
// struct. For the field types allowed here that layout is also WGSL-uniform
// legal, so host bytes, SPIR-V offsets, and WGSL agree by construction.
//
// Allowed field types (compile error otherwise - extend deliberately, and
// only after confirming the SPIR-V-side layout of the new shape):
//   f32 / i32 / u32           -> size 4,  align 4
//   @Vector(2, f32)           -> size 8,  align 8
//   @Vector(4, f32)           -> size 16, align 16
//   [N]scalar                 -> stride 4 (C rule)
//   [N]@Vector(2|4, f32)      -> stride 8|16 (mat4 as [4]Vec, vec runs)
//
// `@Vector(3, f32)` is deliberately rejected: C gives it size 16 while
// std140 gives 12, so a vec3 field is a layout trap - schemas pad to Vec.

/// C-layout alignment of a UBO field type. `@compileError`s on any type
/// outside the allowed set above.
pub fn wireAlignOf(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .float, .int => blk: {
            if (@sizeOf(T) != 4) {
                @compileError("UBO wire layout: scalar field must be 4 bytes " ++
                    "(f32/i32/u32), got " ++ @typeName(T));
            }
            break :blk 4;
        },
        .vector => |v| blk: {
            if (v.child != f32 or (v.len != 2 and v.len != 4)) {
                @compileError("UBO wire layout: vector field must be " ++
                    "@Vector(2, f32) or @Vector(4, f32), got " ++ @typeName(T) ++
                    " (vec3 is a C-vs-std140 layout trap — pad to Vec)");
            }
            break :blk 4 * v.len;
        },
        .array => |a| wireAlignOf(a.child),
        else => @compileError("UBO wire layout: unsupported field type " ++
            @typeName(T) ++ " — allowed: f32/i32/u32, @Vector(2|4, f32), " ++
            "and arrays of those"),
    };
}

/// C-layout size of a UBO field type. For the allowed set, element size is
/// always a multiple of element alignment, so array stride == element size.
pub fn wireFieldSize(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .float, .int => 4,
        .vector => |v| 4 * v.len,
        .array => |a| a.len * wireFieldSize(a.child),
        else => wireAlignOf(T), // unreachable: wireAlignOf compile-errors first
    };
}

fn wireAlignUp(comptime n: comptime_int, comptime a: comptime_int) comptime_int {
    return @divTrunc(n + a - 1, a) * a;
}

/// Byte offset of `field_name` within the wire (GPU) layout of struct `T`.
pub fn wireOffsetOf(comptime T: type, comptime field_name: []const u8) comptime_int {
    const info = @typeInfo(T).@"struct";
    comptime var off: comptime_int = 0;
    inline for (info.field_names, info.field_types) |name, FieldT| {
        off = wireAlignUp(off, wireAlignOf(FieldT));
        if (comptime std.mem.eql(u8, name, field_name)) {
            return off;
        }
        off += wireFieldSize(FieldT);
    }
    @compileError("wireOffsetOf: no field '" ++ field_name ++ "' in " ++ @typeName(T));
}

/// Total wire (GPU) size of struct `T`: C rule - the end offset rounded up
/// to the struct's alignment (its largest field alignment).
pub fn wireSizeOf(comptime T: type) comptime_int {
    const info = @typeInfo(T).@"struct";
    comptime var off: comptime_int = 0;
    comptime var max_align: comptime_int = 1;
    inline for (info.field_names, info.field_types) |name, FieldT| {
        _ = name;
        const a: comptime_int = wireAlignOf(FieldT);
        if (a > max_align) {
            max_align = a;
        }
        off = wireAlignUp(off, a) + wireFieldSize(FieldT);
    }
    if (off == 0) {
        @compileError("wireSizeOf: UBO struct " ++ @typeName(T) ++ " has no fields");
    }
    return wireAlignUp(off, max_align);
}

// ---------------------------------------------------------------------------
// WGSL uniform-block (std140) layout validation. A port of the rule naga
// (valid/type.rs) and Tint/Dawn enforce: in the `uniform` address space, array
// element stride must be a multiple of 16, so a `[N]f32`/`[N]@Vector(2,f32)`
// field (stride 4/8) is REJECTED - "array stride N not a multiple of 16".
// Before this, such a UBO shipped WGSL the browser refused; now it's a compile
// error at the schema (see `assertValidUniform`, called from gen_shader_externs).
//
// It REUSES `wireAlignOf`/`wireFieldSize` above - the wire (CPU) layout and the
// base WGSL layout agree byte-for-byte on the allowed field set, so there is a
// single layout source of truth. (vec3 is already rejected by `wireAlignOf`.)
// ---------------------------------------------------------------------------

/// The WGSL uniform violation in a single UBO field type, or null if legal.
fn uniformFieldError(comptime FieldT: type) ?[]const u8 {
    return comptime switch (@typeInfo(FieldT)) {
        .array => |a| blk: {
            if (uniformFieldError(a.child)) |e| {
                break :blk e;
            }
            if (wireAlignOf(a.child) < 16) {
                break :blk std.fmt.comptimePrint(
                    "uniform (std140) array `{s}`: element stride {d} is not a multiple of the " ++
                        "required alignment 16 — use `[N]@Vector(4, f32)` (stride 16) or promote " ++
                        "a small array to a vector",
                    .{ @typeName(FieldT), wireFieldSize(a.child) },
                );
            }
            break :blk null;
        },
        // Scalars and vec2/vec4 are uniform-legal; vec3 and odd scalars are
        // already rejected by `wireAlignOf`/`wireFieldSize`.
        else => null,
    };
}

/// Compile-error if `T` (a UBO schema struct) is not a legal WGSL `uniform`
/// block. Call from the schema/codegen path so a bad UBO fails the build with a
/// precise message instead of shipping WGSL Tint/Dawn rejects.
pub fn assertValidUniform(comptime T: type) void {
    comptime {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |name, FieldT| {
            if (uniformFieldError(FieldT)) |msg| {
                @compileError("Invalid uniform block layout for " ++ @typeName(T) ++
                    " field '" ++ name ++ "': " ++ msg);
            }
        }
    }
}

test "assertValidUniform: [N]f32/[N]vec2 rejected, vec fields accepted" {
    // The pre-fix points_vs layout - array<f32,N> in a uniform block is illegal.
    try expect(uniformFieldError([2]f32) != null);
    try expect(uniformFieldError([4]f32) != null);
    try expect(std.mem.indexOf(u8, uniformFieldError([2]f32).?, "16") != null);
    // [N]vec2 illegal (stride 8), [N]vec4 legal (stride 16).
    try expect(uniformFieldError([4]Vec2) != null);
    try expect(uniformFieldError([4]Vec) == null);
    // The fixed points_vs field set is all legal.
    try expect(uniformFieldError(Vec2) == null);
    try expect(uniformFieldError(Vec) == null);
    try expect(uniformFieldError(f32) == null);
}

/// Serialize one field value into `out` (which must start AT the field's
/// wire offset). Vectors are coerced to arrays before the byte copy so the
/// element order is defined; scalar arrays copy directly (array layout is
/// guaranteed contiguous).
fn writeWireField(comptime FieldT: type, ptr: *const FieldT, out: []u8) void {
    switch (@typeInfo(FieldT)) {
        .float, .int => {
            @memcpy(out[0..4], std.mem.asBytes(ptr));
        },
        .vector => |v| {
            const arr: [v.len]v.child = ptr.*;
            @memcpy(out[0 .. 4 * v.len], std.mem.asBytes(&arr));
        },
        .array => |a| {
            switch (@typeInfo(a.child)) {
                .vector => {
                    const stride: comptime_int = comptime wireFieldSize(a.child);
                    inline for (0..a.len) |i| {
                        writeWireField(a.child, &ptr.*[i], out[i * stride ..]);
                    }
                },
                else => {
                    @memcpy(out[0..comptime wireFieldSize(FieldT)], std.mem.asBytes(ptr));
                },
            }
        },
        else => comptime unreachable, // wireAlignOf compile-errors first
    }
}

/// Serialize a whole UBO value into `out` using the wire layout. `out` must
/// be at least `wireSizeOf(T)` bytes; padding bytes are zeroed so uploads
/// are deterministic.
pub fn writeWire(comptime T: type, value: *const T, out: []u8) void {
    const size: comptime_int = comptime wireSizeOf(T);
    // A short buffer is a caller bug; runtime callers all pass `[wireSizeOf(T)]u8`.
    zm.assert(out.len >= size, @src());
    @memset(out[0..size], 0);
    const info = @typeInfo(T).@"struct";
    comptime var off: comptime_int = 0;
    inline for (info.field_names, info.field_types) |name, FieldT| {
        off = comptime wireAlignUp(off, wireAlignOf(FieldT));
        writeWireField(FieldT, &@field(value.*, name), out[off..]);
        off += comptime wireFieldSize(FieldT);
    }
}

/// Serialize a UBO value and return the wire bytes by value - the one-liner
/// shape every `queueWriteBuffer` call site wants:
///
///     const bytes: [shader.wireSizeOf(Ubo)]u8 = shader.wireOf(Ubo, &value);
///     wgpu.queueWriteBuffer(queue, buf, 0, &bytes);
pub fn wireOf(comptime T: type, value: *const T) [wireSizeOf(T)]u8 {
    var buf: [wireSizeOf(T)]u8 = undefined;
    writeWire(T, value, &buf);
    return buf;
}

// ===========================================================================
// TESTS
// ===========================================================================

test "wire layout: offsets, size, and serialized bytes match the C/extern rules" {
    // A deliberately gnarly plain-struct UBO: mat4, vec4, vec2, then a lone
    // scalar that forces tail padding up to the 16-byte struct alignment.
    const U = struct {
        m: [4]Vec,
        c: Vec,
        p: Vec2,
        s: f32,
    };
    try expectEqual(0, wireOffsetOf(U, "m"));
    try expectEqual(64, wireOffsetOf(U, "c"));
    try expectEqual(80, wireOffsetOf(U, "p"));
    try expectEqual(88, wireOffsetOf(U, "s"));
    // end = 92, rounded up to align 16 => 96.
    try expectEqual(96, wireSizeOf(U));

    const value: U = .{
        .m = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 5, 6, 7, 1 } },
        .c = .{ 0.25, 0.5, 0.75, 1.0 },
        .p = .{ 2.0, 3.0 },
        .s = 9.0,
    };
    const bytes: [wireSizeOf(U)]u8 = wireOf(U, &value);
    const f: [24]f32 = @bitCast(bytes);
    try expectEqual(@as(f32, 1), f[0]); // m[0].x
    try expectEqual(@as(f32, 5), f[12]); // m[3].x
    try expectEqual(@as(f32, 0.25), f[16]); // c.x
    try expectEqual(@as(f32, 3.0), f[21]); // p.y
    try expectEqual(@as(f32, 9.0), f[22]); // s
    try expectEqual(@as(f32, 0), f[23]); // tail padding zeroed
}

test "Sampler2D carries slot at type level" {
    const T = Sampler2D(.albedo, .{});
    try expectEqual(@as(u32, 0), T.slot);
    try expectEqual(SamplerKind.material_map, T.kind);
    try expectEqual(MaterialMapIndex.albedo, T.map_index);
    // Default config: no pin, no shared - solver assigns location.
    try expect(T.sampler_config.pinned == null);
    try expect(T.sampler_config.shared == null);

    const M = Sampler2D(.metalness, .{});
    try expectEqual(@as(u32, 1), M.slot);
}

test "Sampler2D_atSlot for explicit-slot samplers" {
    const Shadow = Sampler2D_atSlot(8, .{});
    try expectEqual(@as(u32, 8), Shadow.slot);
    try expectEqual(SamplerKind.explicit, Shadow.kind);
}

test "Sampler2D config carries pinned location" {
    const T = Sampler2D(.albedo, .{ .pinned = .{ .group = 1, .binding = 3 } });
    try expectEqual(@as(u32, 1), T.sampler_config.pinned.?.group);
    try expectEqual(@as(u32, 3), T.sampler_config.pinned.?.binding);
    try expect(T.sampler_config.shared == null);
}

test "Sampler2D config carries shared location" {
    const shadow_map_loc: SharedLocation = comptime shared(.{ .group = 3, .binding = 0 });
    const T = Sampler2D(.cubemap, .{ .shared = shadow_map_loc.loc });
    try expectEqual(@as(u32, 3), T.sampler_config.shared.?.group);
    try expectEqual(@as(u32, 0), T.sampler_config.shared.?.binding);
    try expect(T.sampler_config.pinned == null);
}

test "shared() constructs SharedLocation" {
    const loc: SharedLocation = shared(.{ .group = 2, .binding = 5 });
    try expectEqual(@as(u32, 2), loc.loc.group);
    try expectEqual(@as(u32, 5), loc.loc.binding);
}

test "Attr carries element kind and location" {
    const Pos = Attr(.vec3, 0);
    try expectEqual(ElemKind.vec3, Pos.element);
    try expectEqual(@as(u32, 0), Pos.location);

    const Tan = Attr(.vec4, 4);
    try expectEqual(ElemKind.vec4, Tan.element);
    try expectEqual(@as(u32, 4), Tan.location);
}

test "merge combines two structs with defaults preserved" {
    const A = struct {
        x: f32 = 1.0,
        y: i32 = 7,
    };
    const B = struct {
        z: f32 = 3.14,
    };
    const M: type = merge(.{ A, B });

    var m: M = .{};
    try expectEqual(@as(f32, 1.0), m.x);
    try expectEqual(@as(i32, 7), m.y);
    try expectEqual(@as(f32, 3.14), m.z);

    // Override one and verify it sticks
    m.y = 42;
    try expectEqual(@as(i32, 42), m.y);
}

test "merge with a single struct is the identity" {
    const A = struct { a: f32 = 1.0, b: i32 = 2 };
    const M: type = merge(.{A});
    const m: M = .{};
    try expectEqual(@as(f32, 1.0), m.a);
    try expectEqual(@as(i32, 2), m.b);
}

test "merge preserves field types exactly" {
    const A = struct {
        v: [3]f32 = .{ 0, 0, 0 },
        flag: i32 = 0,
    };
    const M: type = merge(.{A});
    const si = @typeInfo(M).@"struct";
    try expectEqual(@as(usize, 2), si.field_names.len);
    try expectEqual([3]f32, si.field_types[0]);
    try expectEqual(i32, si.field_types[1]);
}

test "isReservedName detects reserved engine uniforms" {
    try expect(isReservedName("mvp"));
    try expect(isReservedName("mat_model"));
    try expect(isReservedName("col_diffuse"));
    try expect(!isReservedName("metallic_factor"));
    try expect(!isReservedName("custom_uniform"));
}

test "uniformGroupForSchema: VS->0, FS->2, merged-material->0" {
    // A VS schema (declares Attributes) - vertex-stage UBO at group 0.
    const VsLike = struct {
        pub const Attributes = struct {};
        pub const Ubo = struct {};
    };
    // An FS schema (declares Inputs, no Attributes) - fragment-stage UBO at 2.
    const FsLike = struct {
        pub const Inputs = struct {};
        pub const Ubo = struct {};
    };
    // A MERGED material schema (no Attributes/Inputs) - its UBO is vertex-stage
    // and MUST land at group 0. This is the 2D shapes `EngineSchema` shape;
    // if this returns 2, renderer_2d's bg_layouts[0] is invalid and the whole
    // "shapes" pipeline dies (the zimr328 regression).
    const Merged = struct {
        pub const Ubo = struct {};
        pub const Samplers = struct {};
    };
    try expectEqual(@as(u32, 0), uniformGroupForSchema(VsLike));
    try expectEqual(@as(u32, 2), uniformGroupForSchema(FsLike));
    try expectEqual(@as(u32, 0), uniformGroupForSchema(Merged));
    try expectEqual(@as(u32, 1), sampler_group);
}

test "wire layout: offsets + size match the compiler's own extern layout" {
    // The plain-struct schema shape (depth_vs_io's Ubo): a mat4, a vec4,
    // then a scalar row. The reference is a REAL extern struct with legal
    // (array) fields carrying the same alignments - the compiler's own
    // extern layout is the ground truth the wire functions must replicate.
    const Schema = struct {
        mvp: [4]Vec,
        params: Vec,
        mode: i32,
        pad0: i32,
        pad1: i32,
        pad2: i32,
    };
    const Ref = extern struct {
        mvp: [4][4]f32 align(16),
        params: [4]f32 align(16),
        mode: i32,
        pad0: i32,
        pad1: i32,
        pad2: i32,
    };
    try expectEqual(@offsetOf(Ref, "mvp"), wireOffsetOf(Schema, "mvp"));
    try expectEqual(@offsetOf(Ref, "params"), wireOffsetOf(Schema, "params"));
    try expectEqual(@offsetOf(Ref, "mode"), wireOffsetOf(Schema, "mode"));
    try expectEqual(@offsetOf(Ref, "pad2"), wireOffsetOf(Schema, "pad2"));
    try expectEqual(@sizeOf(Ref), wireSizeOf(Schema));
    try expectEqual(96, wireSizeOf(Schema));
}

test "wire layout: vec2 + scalar mix" {
    const Schema = struct {
        p: Vec2,
        q: f32,
        r: f32,
        v: Vec,
    };
    const Ref = extern struct {
        p: [2]f32 align(8),
        q: f32,
        r: f32,
        v: [4]f32 align(16),
    };
    try expectEqual(@offsetOf(Ref, "p"), wireOffsetOf(Schema, "p"));
    try expectEqual(@offsetOf(Ref, "q"), wireOffsetOf(Schema, "q"));
    try expectEqual(@offsetOf(Ref, "r"), wireOffsetOf(Schema, "r"));
    try expectEqual(@offsetOf(Ref, "v"), wireOffsetOf(Schema, "v"));
    try expectEqual(@sizeOf(Ref), wireSizeOf(Schema));
}

test "writeWire serializes fields at their wire offsets" {
    const Schema = struct {
        v: Vec,
        m: [2]Vec,
        s: f32,
        pad: [3]f32,
    };
    const value: Schema = .{
        .v = .{ 1, 2, 3, 4 },
        .m = .{ .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 } },
        .s = 13,
        .pad = .{ 0, 0, 0 },
    };
    var buf: [wireSizeOf(Schema)]u8 = undefined;
    writeWire(Schema, &value, &buf);
    try expectEqual(@as(usize, 64), buf.len);
    const floats: [16]f32 = @bitCast(buf);
    // v at offset 0, m at 16, s at 48, pad zeroed after.
    try expectEqual(@as(f32, 1), floats[0]);
    try expectEqual(@as(f32, 4), floats[3]);
    try expectEqual(@as(f32, 5), floats[4]);
    try expectEqual(@as(f32, 12), floats[11]);
    try expectEqual(@as(f32, 13), floats[12]);
    try expectEqual(@as(f32, 0), floats[15]);
}

test "solveSamplerSlots: free samplers pair by two (texture N, sampler N+1)" {
    const S = struct {
        albedo: Sampler2D(.albedo, .{}),
        metallic: Sampler2D(.metalness, .{}),
        normal: Sampler2D(.normal, .{}),
    };
    const slots = comptime solveSamplerSlots(S);
    try expectEqual(@as(usize, 3), slots.len);
    // Texture bindings step by 2 so each paired sampler (N+1) is free.
    try expectEqual(@as(u32, 0), slots[0].binding);
    try expectEqual(@as(u32, 2), slots[1].binding);
    try expectEqual(@as(u32, 4), slots[2].binding);
    for (slots) |s| {
        try expectEqual(sampler_group, s.group);
        try expectEqual(SamplerSlotOrigin.solver_default, s.origin);
    }
}

test "solveSamplerSlots: sampler stage visibility (default fragment, opt-in vertex)" {
    const S = struct {
        // Default: fragment-only (the historical behaviour).
        albedo: Sampler2D(.albedo, .{}),
        // Vertex-only: a height map read in the VERTEX stage for displacement.
        height: Sampler2D(.normal, .{ .stages = .{ .vertex = true, .fragment = false } }),
        // Both stages (fragment defaults true, so `.vertex = true` opts vertex in).
        shared_map: Sampler2D(.metalness, .{ .stages = .{ .vertex = true } }),
    };
    const slots = comptime solveSamplerSlots(S);
    // default -> fragment-only
    try expectEqual(false, slots[0].stages.vertex);
    try expectEqual(true, slots[0].stages.fragment);
    // vertex-only
    try expectEqual(true, slots[1].stages.vertex);
    try expectEqual(false, slots[1].stages.fragment);
    // both stages
    try expectEqual(true, slots[2].stages.vertex);
    try expectEqual(true, slots[2].stages.fragment);
}

test "solveSamplerSlots: pinned cells are kept and free pairs fill around them" {
    const S = struct {
        // pinned at (1,2): its sampler half conceptually at 3.
        pinned_mid: Sampler2D(.metalness, .{ .pinned = .{ .group = 1, .binding = 2 } }),
        free_a: Sampler2D(.albedo, .{}),
        free_b: Sampler2D(.normal, .{}),
    };
    const slots = comptime solveSamplerSlots(S);
    // pinned keeps (1,2)
    try expectEqual(@as(u32, 2), slots[0].binding);
    try expectEqual(SamplerSlotOrigin.pinned, slots[0].origin);
    // free_a: lowest N with N and N+1 free -> (1,0)
    try expectEqual(@as(u32, 0), slots[1].binding);
    // free_b: pinned claims 2 AND its sampler half 3, so the next free pair
    // starts at 4 -> (1,4).
    try expectEqual(@as(u32, 4), slots[2].binding);
}
