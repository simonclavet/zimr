//! tools/gen_shader_externs.zig - codegen library for the per-shader
//! The binding model this codegen implements (VS uniforms=group 0,
//! samplers=group 1, FS uniforms=group 2) is documented centrally in
//! src/zimr.zig (section 3) - the single source of truth for the wgpu stack.
//!
//! `*_extern.zig` files referenced by shader bodies.
//!
//! Phase 2 of `src/notes/typesafe_zig_shaders.md`.  Phase 1 hand-wrote
//! the extern decls in each `_vs.zig` / `_fs.zig` body, duplicating
//! the iface schema.  Phase 2 derives them from the iface struct via
//! comptime reflection.
//!
//! This file is a LIBRARY - `pub fn emit(comptime IfaceMod: type,
//! writer: anytype) !void` does the reflection.  The actual exe per
//! shader is a tiny generated bootstrap built by `build.zig`:
//!
//!     // generated bootstrap.zig (one per shader)
//!     const iface = @import("iface");
//!     const gen = @import("gen");
//!     pub fn main(init: std.process.Init) !void {
//!         // ... emit gen.emit(iface, writer) to argv[1] ...
//!     }
//!
//! Each bootstrap exe gets the relevant iface wired as its own named
//! module dep, so each one sees exactly ONE iface - no shared-file
//! conflict between ifaces (which doomed earlier aggregator attempts).
//! This pattern scales naturally to external zimr users: their
//! `addShader(body, .{ .iface = LazyPath })` call from their own
//! build.zig invokes the same bootstrap-per-shader pipeline with
//! their iface module wired in.

const std = @import("std");
const shader_iface = @import("shader_interface");
const wgsl_reflect = @import("wgsl_reflect");
const allocPrint = std.fmt.allocPrint;

/// The `.decoration` half of every descriptor-bound `@extern` this file emits,
/// as a `print` format fragment - takes the set, then the binding. One spelling
/// for the Ubo, loose uniforms, textures and samplers, so they cannot drift.
const descriptor_decoration_fmt = ".decoration = .{{ .descriptor = .{{ .set = {d}, .binding = {d} }} }}";
const eql = std.mem.eql;

/// Map a `shader_interface.ElemKind` (used in VS Attributes) to its
/// Zig representation.  All vec kinds resolve to the matching
/// `zm.VecN` alias from `src/shadermath.zig`.
/// Map a `shader_interface.ElemKind` (used in VS Attributes) to its
/// Zig representation.  Emitted as inline types so the generated
/// extern file has no module imports.
fn zigTypeForElem(comptime elem: anytype) []const u8 {
    return switch (elem) {
        .vec2 => "@Vector(2, f32)",
        .vec3 => "@Vector(3, f32)",
        .vec4 => "@Vector(4, f32)",
        .ivec4 => "@Vector(4, i32)",
        .uvec4 => "@Vector(4, u32)",
    };
}

/// Map a Zig type (used for Inputs/Outputs/Uniforms fields) to the
/// extern decl's type string.  The schema uses `@Vector(N, f32)`
/// explicitly for vector semantics (so the generated extern keeps
/// vector semantics and the shader body can do arithmetic) and
/// `[N]X` for arrays (so runtime indexing works, since Zig doesn't
/// permit runtime indexing into `@Vector`).
///
/// Special case: matrices come through as `[16]f32` in the schema
/// for readability - flat 16 floats - and get emitted as the
/// `[4]@Vector(4, f32)` shape that the SPIR-V backend expects for
/// column-major matrices.
///
/// Array types are unrolled at comptime: `[N]@Vector(3, f32)`
/// becomes `[N]@Vector(3, f32)`, `[N]f32` stays as `[N]f32`, etc.
/// PBR-style light arrays (`[MAX_DIRECTIONAL_LIGHTS]@Vector(3, f32)`
/// or `[MAX_POINT_LIGHTS]f32`) are the motivating case.
fn zigTypeForType(comptime T: type) []const u8 {
    return switch (T) {
        f32 => "f32",
        i32 => "i32",
        u32 => "u32",
        // Matrices: flat 16 floats in source schema -> 4xvec4 in the
        // generated extern (matches how SPIR-V sees a column-major
        // matrix).
        [16]f32 => "[4]@Vector(4, f32)",
        else => switch (@typeInfo(T)) {
            // Vector types pass through with their existing shape.
            // Schemas use `@Vector(N, f32)` for fields meant to be
            // vec-arithmetic-capable in the shader body.
            .vector => |info| comptime blk: {
                break :blk std.fmt.comptimePrint(
                    "@Vector({d}, {s})",
                    .{ info.len, @typeName(info.child) },
                );
            },
            // Outer arrays: `[N]Inner` where Inner has its own emit
            // rule.  Runtime indexing into the resulting extern works
            // because the outer is still an array, not a vector.
            //   [MAX_DIRECTIONAL_LIGHTS]@Vector(3, f32) -> "[N]@Vector(3, f32)"
            //   [MAX_POINT_LIGHTS]f32                   -> "[N]f32"
            .array => |info| comptime blk: {
                const inner: []const u8 = zigTypeForType(info.child);
                break :blk std.fmt.comptimePrint("[{d}]{s}", .{ info.len, inner });
            },
            else => @compileError(
                "unsupported schema field type: " ++ @typeName(T) ++
                    " — add a case to zigTypeForType in gen_shader_externs.zig",
            ),
        },
    };
}

/// Inspect the iface struct and emit the matching extern declarations.
///
/// VS schemas declare `Attributes` (input vertex attribs with explicit
/// locations); FS schemas declare `Inputs` (interpolated varyings,
/// locations assigned by declaration order, matching the VS's
/// `Outputs`).  Both stages may declare `Uniforms`, `Outputs`, and
/// (FS only) `Samplers`.  Missing decls are skipped - this is what
/// lets the same `emit` work for both stages.
///
/// Emitted code is self-contained: no `@import` of `shadermath` etc.
/// Vec types come through as `@Vector(N, f32)`; matrices as
/// `[4]@Vector(4, f32)`.  The shader body - which imports
/// `shadermath` for math helpers - sees the externs through the
/// generated module's `pub` decls and treats them as the right types.
/// This keeps the `*_extern` module a pure leaf (no module deps),
/// which simplifies build.zig wiring.
pub fn emit(comptime IfaceMod: type, writer: anytype) !void {
    // Guard against silent typos: the iface schema convention recognizes
    // only the names listed below.  If a schema declares e.g. `Sampler`
    // (missing s) or `Uniform` instead of `Uniforms`, the codegen would
    // silently skip the section and the resulting shader would link
    // without those resources.  Reject at compile time with a message
    // pointing at the typo.
    //
    // `Ubo` is recognized; `Ubos` is not (singular form on purpose -
    // there's exactly one UBO per shader for now).  Sub-types referenced
    // by the recognized decls (e.g. a `Helper` type used inside `Ubo`'s
    // fields) are decl in the iface module too - they're ignored here
    // because Zig's `@hasDecl` includes them, and there's no way to
    // distinguish "schema-section name" from "helper type name" by
    // shape alone.  The convention: schema-section names are
    // capitalized singular nouns from a fixed set.
    comptime {
        const recognized = [_][]const u8{
            "Attributes", "Inputs",   "Outputs",
            "Uniforms",   "Samplers", "Ubo",
            "Storage",    "Builtins",
        };
        const close_misses = [_]struct { wrong: []const u8, right: []const u8 }{
            .{ .wrong = "Attribute", .right = "Attributes" },
            .{ .wrong = "Input", .right = "Inputs" },
            .{ .wrong = "Output", .right = "Outputs" },
            .{ .wrong = "Uniform", .right = "Uniforms" },
            .{ .wrong = "Sampler", .right = "Samplers" },
            .{ .wrong = "UBO", .right = "Ubo" },
            .{ .wrong = "Ubos", .right = "Ubo" },
            .{ .wrong = "Storages", .right = "Storage" },
            .{ .wrong = "StorageBuf", .right = "Storage" },
            .{ .wrong = "Builtin", .right = "Builtins" },
            .{ .wrong = "Builtln", .right = "Builtins" },
        };
        // Walk every pub decl on the iface; flag any close-miss against
        // the recognized list.  Decls whose names don't resemble any
        // schema section (e.g. user-defined `Helper`, `MAX_LIGHTS`)
        // are left alone - they may legitimately be local constants
        // or helper types referenced by the schema.
        for (close_misses) |miss| {
            if (@hasDecl(IfaceMod, miss.wrong)) {
                var unrecognized: bool = true;
                for (recognized) |ok| {
                    if (eql(u8, miss.wrong, ok)) {
                        unrecognized = false;
                        break;
                    }
                }
                if (unrecognized) {
                    @compileError(
                        "Iface declares '" ++ miss.wrong ++ "' — did you mean '" ++
                            miss.right ++
                            "'?  Recognized schema sections: Attributes, " ++
                            "Inputs, Outputs, Uniforms, Samplers, Ubo, " ++
                            "Storage, Builtins.",
                    );
                }
            }
        }
    }

    // ---- Inter-stage varying count guard ------------------------------------
    // WebGPU guarantees only 16 inter-stage shader variables (the `@location`
    // slots a VS `Outputs` / FS `Inputs` struct consumes, one per field). A
    // schema that forwards more would pass codegen and fail at *pipeline
    // creation* on the device - a driver error far from the schema. Catch it
    // here with a clear comptime error naming the offending stage instead.
    comptime {
        const max_inter_stage: u32 = 16;
        if (@hasDecl(IfaceMod, "Outputs")) {
            var n: u32 = 0;
            for (@typeInfo(IfaceMod.Outputs).@"struct".field_names) |fname| {
                // `frag_depth` is a builtin output, not a located varying.
                if (!eql(u8, fname, "frag_depth")) {
                    n += 1;
                }
            }
            if (n > max_inter_stage) {
                @compileError(std.fmt.comptimePrint(
                    "Schema `Outputs` forwards {d} varyings, but WebGPU guarantees only " ++
                        "16 inter-stage locations. Pack fields into fewer vec4s, or move " ++
                        "constants into the Ubo.",
                    .{n},
                ));
            }
        }
        if (@hasDecl(IfaceMod, "Inputs")) {
            const n: u32 = @typeInfo(IfaceMod.Inputs).@"struct".field_names.len;
            if (n > max_inter_stage) {
                @compileError(std.fmt.comptimePrint(
                    "Schema `Inputs` reads {d} varyings, but WebGPU guarantees only " ++
                        "16 inter-stage locations. Pack fields into fewer vec4s, or move " ++
                        "constants into the Ubo.",
                    .{n},
                ));
            }
        }
    }

    try writer.writeAll(
        \\// AUTO-GENERATED by tools/gen_shader_externs.zig — do not edit.
        \\// Edit the matching `*_io.zig` schema instead.
        \\//
        \\// The shader body imports this as `@import("io")` (the codegen
        \\// output's named module).  Every external resource the shader
        \\// touches — vertex attributes, varyings, uniforms, samplers,
        \\// stage outputs — lives in this namespace.  Call `io.setup()`
        \\// once at the top of `main` to install all the required
        \\// `OpDecorate` calls; then the shader body just reads/writes
        \\// the named decls.
        \\//
        \\// NATIVE-COMPATIBLE LAYOUT: every SPIR-V-only declaration
        \\// (externs with `addrspace`, `std.gpu` re-exports, the
        \\// `setup()` body that takes addresses of those externs,
        \\// and the top-level sampler accessor functions whose
        \\// bodies sample externs) lives inside the `_Spirv`
        \\// namespace, wrapped in `if (_is_spirv) struct { ... } else
        \\// struct {};`.  Zig 0.16 lazy-evaluates the comptime-dead
        \\// branch, so on native targets the SPIR-V-only body is
        \\// never type-checked; the emitted file compiles cleanly
        \\// for any target.
        \\//
        \\// Shader bodies that use only `IoT(Ubo)`, `Out`, and
        \\// `installSpirvEntry` (the standard new API) are
        \\// native-importable for free.  The CPU dispatcher in
        \\// `raster_shader.zig` can call `shaderMain(io)` directly per
        \\// pixel; the `installSpirvEntry` call site is a no-op on
        \\// non-SPIR-V targets.
        \\
        \\const std = @import("std");
        \\const _builtin = @import("builtin");
        \\const _is_spirv = _builtin.target.cpu.arch.isSpirV();
        \\
        \\// ---- _Spirv namespace: all SPIR-V-only declarations.
        \\// On native targets, this whole struct body is comptime-dead;
        \\// Zig 0.16 doesn't type-check the `if (_is_spirv) struct { ... }`
        \\// branch when the condition is false.
        \\const _Spirv = if (_is_spirv) struct {
        \\
        \\// zm — for storageBuffer() / sampler helpers used by emitted decls.
        \\const _sb = @import("shader_builtins");
        \\
        \\// ---- Built-in GPU values, re-exported for symmetry --------
        \\// These come from Zig's `std.spirv` namespace.  SPIR-V-only —
        \\// `std.spirv.position_out` references a `.output` addrspace
        \\// type and isn't representable on native targets.
        \\pub const position_out = std.spirv.position_out;
        \\pub const vertex_index = std.spirv.vertex_index;
        \\pub const instance_index = std.spirv.instance_index;
        \\
        \\
    );

    // ==== HOW EVERY DECL BELOW GETS ITS DECORATION ====================
    //
    // Every stage-interface variable is a FILE-SCOPE `@extern` that carries its
    // own decoration - `.location` for varyings and attributes, `.descriptor`
    // for uniforms, textures and samplers. The binding is part of the
    // declaration, so a variable simply cannot exist without one.
    //
    // It used to be two steps: a bare `extern const x: T addrspace(...)`, then
    // an inline-asm `OpDecorate %x Location N` inside the entry function. Zig
    // 0.17.0-dev.2307's rewritten SPIR-V linker links each declaration on its
    // own and only copies a decoration whose target was defined in the SAME
    // unit - an asm decoration aimed at a global from inside a function is
    // collected and silently dropped. Every shader came out at @group(0) with
    // no locations and the device rejected every pipeline. `ExternOptions.
    // decoration` is the language's own spelling of this, and it is what the
    // compiler's behavior tests use. See src/notes/spirv_2307_decorations_plan.md.
    //
    // Consequence for readers of this file: each of these is a POINTER, so the
    // entry wrapper reads `x.*` and writes `x.* = v`. Struct fields auto-deref
    // (`u.step` works as-is).

    // ---- VS Attributes: location explicit on each Attr type
    if (@hasDecl(IfaceMod, "Attributes")) {
        try writer.writeAll("// Vertex attributes (locations from Attr type).\n");
        const T = IfaceMod.Attributes;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const AttrT: type = field_type;
            const elem = @field(AttrT, "element");
            const loc = @field(AttrT, "location");
            try writer.print(
                "pub const {s} = @extern(*addrspace(.input) const {s}, " ++
                    ".{{ .name = \"{s}\", .decoration = .{{ .location = {d} }} }});\n",
                .{ field_name, zigTypeForElem(elem), field_name, loc },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- FS Inputs (interp from VS): location by declaration order
    if (@hasDecl(IfaceMod, "Inputs")) {
        try writer.writeAll("// Interpolated inputs from vertex (location = field index).\n");
        const T = IfaceMod.Inputs;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
            try writer.print(
                "pub const {s} = @extern(*addrspace(.input) const {s}, " ++
                    ".{{ .name = \"{s}\", .decoration = .{{ .location = {d} }} }});\n",
                .{ field_name, zigTypeForType(field_type), field_name, i },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- VS Outputs / FS Outputs: location by declaration order.
    // The field name `frag_depth` is a BUILTIN, not a located output:
    // the extern is emitted with that exact name (the SPIR-V backend
    // name-magics it to the FragDepth builtin, same mechanism as
    // `position`) and it neither gets a Location decoration nor
    // consumes a location index - color outputs after it keep their
    // slots.
    if (@hasDecl(IfaceMod, "Outputs")) {
        try writer.writeAll("// Stage outputs (location = field index; frag_depth = builtin).\n");
        const T = IfaceMod.Outputs;
        const info = @typeInfo(T).@"struct";
        comptime var out_loc: u32 = 0;
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const is_frag_depth: bool = comptime std.mem.eql(u8, field_name, "frag_depth");
            if (is_frag_depth) {
                // No decoration at all - the backend maps this exact extern name to
                // the FragDepth builtin, exactly like std.spirv's "position".
                try writer.print(
                    "pub const {s} = @extern(*addrspace(.output) {s}, .{{ .name = \"{s}\" }});\n",
                    .{ field_name, zigTypeForType(field_type), field_name },
                );
            } else {
                try writer.print(
                    "pub const {s} = @extern(*addrspace(.output) {s}, " ++
                        ".{{ .name = \"{s}\", .decoration = .{{ .location = {d} }} }});\n",
                    .{ field_name, zigTypeForType(field_type), field_name, out_loc },
                );
                out_loc += 1;
            }
        }
        try writer.writeAll("\n");
    }

    // ---- Uniforms: loose, .constant storage class, no location
    // Each loose uniform is its own one-field uniform BLOCK: the compiler
    // insists a `.uniform` extern points at a struct (a bare vec4 or array is
    // rejected), and the old `.constant` spelling is now reserved for opaque
    // image/sampler handles. `extern struct { value: T }` has exactly T's bytes,
    // so the host's buffers bind unchanged - WGSL just sees
    // `var<uniform> col_diffuse: S { field_0: vec4<f32> }` instead of a bare vec4.
    //
    // Group: the SAME authority the Ubo uses (VS -> 0, FS -> 2, or a schema's
    // `ubo_group`). Bindings count 0, 1, 2... in declaration order.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        try writer.writeAll("// Uniforms (loose; each one a one-field uniform block).\n");
        const uniform_set: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        const T = IfaceMod.Uniforms;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, 0..) |field_name, field_type, binding| {
            try writer.print(
                "pub const _{s}_block = @extern(*addrspace(.uniform) const extern struct {{ value: {s} }}, " ++
                    ".{{ .name = \"{s}\", " ++ descriptor_decoration_fmt ++ " }});\n",
                .{ field_name, zigTypeForType(field_type), field_name, uniform_set, binding },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- Samplers: each schema field becomes TWO real opaque handles - a
    //               texture at (group, N) and its sampler at (group, N+1).
    //               That pairing is the host's convention (shader_runtime.zig
    //               expands a `.sampler_2d` into exactly those two entries), and
    //               the slots come from `solveSamplerSlots`, the same solver the
    //               host layout calls, so the two sides cannot disagree.
    //
    //               The texture's extern name is the field name and the
    //               sampler's is `<name>_sampler` - the WGSL globals come out as
    //               `texture0` / `texture0_sampler`, same as before. The Zig decls
    //               are `_tex_<name>` / `_smp_<name>` so they never collide with
    //               the `io.<name>(uv)` accessor methods.
    //
    //               These used to be a `u32` placeholder that zspv rewrote into a
    //               real texture + sampler after compilation. The compiler now
    //               declares opaque image and sampler types itself (`@SpirvType`)
    //               and refuses anything else in the `.constant` address space,
    //               so the placeholder and the rewrite are both obsolete.
    if (@hasDecl(IfaceMod, "Samplers")) {
        try writer.writeAll(
            "// Samplers - a real texture at (group, N) + its sampler at (group, N+1).\n" ++
                "// The shader body samples through `io.<name>(uv)` / `io.<name>Level(uv, lod)`.\n",
        );
        const T = IfaceMod.Samplers;
        const info = @typeInfo(T).@"struct";
        const slots = shader_iface.solveSamplerSlots(IfaceMod.Samplers);
        inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
            // Sanity-check: the field type must be a Sampler2D-shaped
            // marker (has both `slot` AND `sampler_config` decls).
            // Anything else is a schema error - most commonly:
            //   - Typo'd marker: `Sample2D` instead of `Sampler2D`
            //   - Old DSL shape: `Sampler2D(.X)` without the `.{}` config arg
            //     (the marker is back-compat for the test path but won't
            //     produce a `sampler_config` decl)
            //   - Custom struct accidentally placed inside `Samplers`
            //     (move it elsewhere in the schema or make it a const decl)
            if (!@hasDecl(field_type, "slot") or
                !@hasDecl(field_type, "sampler_config"))
            {
                @compileError(
                    "Samplers field '" ++ field_name ++ "' has type `" ++
                        @typeName(field_type) ++ "` which is not a " ++
                        "`Sampler2D(tag, config)` marker.  Either:\n" ++
                        "  - The field type is wrong (typo? `Sample2D` " ++
                        "instead of `Sampler2D`?)\n" ++
                        "  - The marker is missing the config arg " ++
                        "(`Sampler2D(.X, .{})` not `Sampler2D(.X)`)\n" ++
                        "  - The field doesn't belong in `Samplers` " ++
                        "(move custom structs out of the schema sections)",
                );
            }
            const group: u32 = slots[i].group;
            const texture_binding: u32 = slots[i].binding;
            const sampler_binding: u32 = texture_binding + 1;
            try writer.print(
                "pub const _tex_{s} = @extern(_sb.Texture2DPtr(), " ++
                    ".{{ .name = \"{s}\", " ++ descriptor_decoration_fmt ++ " }});\n",
                .{ field_name, field_name, group, texture_binding },
            );
            try writer.print(
                "pub const _smp_{s} = @extern(_sb.SamplerPtr(), " ++
                    ".{{ .name = \"{s}_sampler\", " ++ descriptor_decoration_fmt ++ " }});\n",
                .{ field_name, field_name, group, sampler_binding },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- Ubo: single uniform buffer block at binding 0 of the stage's
    //          uniform group.  See header comment for the design.
    //
    // Split between layers: the `Ubo` STRUCT TYPE def lives at
    // MODULE level (it's a pure type, target-independent, must be
    // visible to consumer code that does `shader_externs.Ubo`).
    // The decorated `u` `@extern` lives INSIDE `_Spirv` (only valid
    // on SPIR-V targets); only the entry-point Wrapper reads it.
    //
    // Ubo is emitted as a duplicate `extern struct` definition rather
    // than aliasing iface.Ubo.  Rationale: io.zig must NOT import
    // iface, because otherwise the iface file ends up claimed by both
    // the 'iface' module (io's dep) AND the consumer's root module
    // (which typically imports iface relatively for `LoadedShader(
    // iface)`), violating Zig 0.16's one-file-per-module rule.
    //
    // The shader source closes the type-identity loop by re-exporting
    // its own `pub const Ubo = iface_mod.Ubo;` and using IoT(iface.Ubo)
    // for `Io`, so example/host code always sees a single Ubo type.
    // See `examples/mandelbrot_fs.zig` for the canonical pattern.
    if (@hasDecl(IfaceMod, "Ubo")) {
        // Build-time gate: reject a UBO whose WGSL uniform (std140) layout Tint/
        // Dawn would refuse (e.g. `[N]f32` -> `array<f32,N>` stride 4). Fails here
        // with a precise message instead of shipping bad WGSL to the device.
        shader_iface.assertValidUniform(IfaceMod.Ubo);
        // The SPIR-V-side wire mirror.  Zig 0.17.0-dev.1245 bans `@Vector`
        // fields in extern structs on CPU targets, so the module-level `Ubo`
        // below is a PLAIN struct; the uniform pointee needs the guaranteed
        // C/extern layout, which is still legal on the SPIR-V target where
        // vectors have a defined representation.  `UboWire` lives inside
        // `_Spirv` so CPU targets never resolve its layout.  Field names and
        // types match `Ubo` exactly - the entry wrapper copies field-by-field
        // (see the `.u = .{ ... }` construction below), and the host computes
        // the identical offsets via `shader_interface.wireOffsetOf`.
        try writer.writeAll("pub const UboWire = extern struct {\n");
        const wire_info = @typeInfo(IfaceMod.Ubo).@"struct";
        inline for (wire_info.field_names, wire_info.field_types) |field_name, field_type| {
            try writer.print(
                "    {s}: {s},\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
        try writer.writeAll("};\n");
        // Always binding 0 of its group; the group comes from the one shared
        // authority, so a schema's `ubo_group` override reaches the WGSL and the
        // host layout together.
        const ubo_set: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        try writer.print(
            "pub const u = @extern(*addrspace(.uniform) const UboWire, " ++
                ".{{ .name = \"u\", " ++ descriptor_decoration_fmt ++ " }});\n",
            .{ ubo_set, 0 },
        );
        try writer.writeAll("\n");
    }

    // ---- Storage: read-only / read-write SSBOs, bound in the stage's
    //               uniform group at bindings AFTER the Ubo.  Each field
    //               emits a `storageBuffer(Elem, name, group, binding)`
    //               extern; the IoT() wrapper adds an `io.<name>(i)`
    //               accessor (parallel to the sampler `io.<name>(uv)`).
    if (@hasDecl(IfaceMod, "Storage")) {
        try writer.writeAll(
            "// Storage buffers (runtime arrays; bound after the Ubo in-group).\n",
        );
        const T = IfaceMod.Storage;
        const info = @typeInfo(T).@"struct";
        // Placement via the ONE shared authority (same function the host layout
        // solver calls), so the emitted @group/@binding can't drift from it.
        const slots = shader_iface.solveStorageSlots(IfaceMod);
        inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
            if (!@hasDecl(field_type, "element") or !@hasDecl(field_type, "access")) {
                @compileError(
                    "Storage field '" ++ field_name ++ "' is not a " ++
                        "`StorageBuf(Elem, .read|.read_write)` marker.",
                );
            }
            const Elem: type = @field(field_type, "element");
            try writer.print(
                "pub const {s} = _sb.storageBuffer({s}, \"{s}\", {d}, {d});\n",
                .{ field_name, zigTypeForType(Elem), field_name, slots[i].group, slots[i].binding },
            );
            try writer.print("pub const _storage_elem_{s} = {s};\n", .{ field_name, zigTypeForType(Elem) });
        }
        try writer.writeAll("\n");
    }

    // ---- Builtins: SPIR-V builtin inputs (no descriptor binding).  These
    //               are magic extern values (`std.spirv.vertex_index` etc.),
    //               NOT comptime constants - so we can't `const`-alias them.
    //               The accessor method reads `std.spirv.<name>` directly; we
    //               only need to validate the schema here.
    if (@hasDecl(IfaceMod, "Builtins")) {
        const T = IfaceMod.Builtins;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_types) |field_type| {
            if (!@hasDecl(field_type, "builtin")) {
                @compileError("Builtins field is not a `Builtin(.vertex_index|.instance_index)` marker.");
            }
        }
    }
    // No `setup()` and no top-level sampler accessors any more: every decoration
    // now lives on its `@extern` declaration above, and shaders sample through
    // the `IoT` methods below. Nothing in the tree called either.

    // ---- Close _Spirv namespace.  Everything above this point is
    //      SPIR-V-only: the decorated `@extern` decls.  Below this point
    //      lives at module scope and must compile on both targets.
    try writer.writeAll("} else struct {};\n\n");

    // ---- Module-level Ubo type ----------------------------------
    // Pure struct type - target-independent.  Consumers do
    // `shader_externs.Ubo` to get the type for `IoT(Ubo)` or for
    // their own typed UBO buffers.  PLAIN struct (Zig 1245 bans
    // vector fields in extern structs on CPU targets); the GPU wire
    // layout lives in `_Spirv.UboWire` above plus the host-side
    // `shader_interface.wireOf`/`wireSizeOf` serializer.
    if (@hasDecl(IfaceMod, "Ubo")) {
        const UboT = IfaceMod.Ubo;
        try writer.writeAll("pub const Ubo = struct {\n");
        const info = @typeInfo(UboT).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "    {s}: {s},\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
        try writer.writeAll("};\n\n");
    }

    // ---- New API: Io / Out / installSpirvEntry ===================
    //
    // The shape that the software-shader plan (see
    // src/notes/software_shaders.md) requires: a pure-logic body of
    // signature `pub fn main(io: Io) Out`, with the SPIR-V entry
    // point bound by `comptime { _ = installSpirvEntry(main); }`
    // at the bottom of the shader source.  Same iface schema drives
    // both the new API and the existing extern-based API; both are
    // emitted side-by-side from S1 through S5 of that plan.  After
    // S5 the old emission drops.
    //
    // The new API is emitted UNCONDITIONALLY - every shader that
    // wants to use it can adopt the new shape independently.  Shaders
    // not yet migrated keep using the old `extern var out_color`
    // module-scope decl + `setup()` pattern, and the new emissions
    // sit unused (zero output-size cost because Zig elides unused
    // pub decls in the SPIR-V backend's dead-strip pass).
    //
    // Io is a plain struct with one field per Inputs entry plus a
    // `u: Ubo` field if the iface declares Ubo.  CPU and SPIR-V
    // builds see the same struct shape; the SPIR-V build's wrapper
    // populates Io from module-scope externs, while the CPU build's
    // caller fills the fields directly.
    //
    // Out is a plain struct with one field per Outputs entry.
    // Same on both targets.
    //
    // installSpirvEntry(comptime body) emits a `noinline export fn
    // entry() callconv(.spirv_fragment) void` wrapper that:
    //   - Calls the OpDecorate asm for every input/output/ubo
    //     (replicating what `setup()` does on the old path).
    //   - Reads externs into a local Io.
    //   - Calls `body(io)` and gets the returned Out.
    //   - Writes Out's fields back to the extern outputs.
    // On CPU targets (when `builtin.target.cpu.arch.isSpirV()` is
    // false), installSpirvEntry is a no-op - the caller just runs
    // `main(io)` directly per pixel.

    // Emit `pub fn IoT(comptime UboType: type) type { return struct { ... } }`.
    //
    // KEY DESIGN: Io is a function-returning-a-type rather than a
    // direct struct.  This avoids io.zig needing to `@import("iface")`
    // - which would put the iface file in BOTH the 'iface' module
    // (as io's dep) AND the example's 'root' module (which often
    // imports iface relatively for `LoadedShader(iface)`).  Zig 0.16
    // forbids one file being claimed by two modules.
    //
    // The shader source closes the loop by instantiating:
    //   const iface_mod = @import("mandelbrot_fs_io.zig");
    //   pub const Io = io_mod.IoT(iface_mod.Ubo);
    // - relative imports of the iface from the shader source AND the
    // example's CPU code share the SAME module (root), so the file-
    // in-two-modules rule isn't triggered.
    //
    // The shader source also re-exports `pub const Io`, `Out`, `Ubo`
    // so the example accesses everything through `@import("foo_fs.
    // zig")` without having to construct the IoT instantiation itself.
    try writer.writeAll(
        \\// ---- New API: IoT / Out / installSpirvEntry ---------------
        \\// See `src/notes/software_shaders.md` for the design.  These
        \\// emissions sit alongside the legacy externs above; shaders
        \\// using the new `pub fn shaderMain(io: Io) Out` shape close
        \\// the loop by instantiating `IoT(iface.Ubo)` and re-exporting
        \\// as `Io`.
        \\//
        \\// IoT is a function-returning-a-type because io.zig must NOT
        \\// import the iface module — see codegen comments for why.
        \\//
        \\// Sampler accessor methods (texture0, texture1, ...) have
        \\// target-conditional bodies: on SPIR-V they call the extern
        \\// image-sample op; on CPU they read from `_<name>: TextureRef`
        \\// fields (one per sampler, populated by the caller before
        \\// dispatch).  TextureRef is a tiny pointer-and-dims struct
        \\// defined below; v1 assumes RGBA8 layout.
        \\//
        \\// TextureRef is defined HERE (in the codegen output) rather
        \\// than importing raster.  raster is 7000+ lines including system
        \\// allocators that don't compile on spirv32-vulkan, so
        \\// importing it would break the GPU compile.  The caller
        \\// (dispatcher) constructs TextureRefs from raster.Texture
        \\// bytes itself.
        \\pub const TextureRef = struct {
        \\    pixels: []const u8,
        \\    width: u32,
        \\    height: u32,
        \\    /// True when the GPU side of this binding uses an `*_srgb` texture
        \\    /// view: the sampler then converts RGB sRGB→linear at sample time
        \\    /// (alpha stays linear), matching the hardware's behavior so the
        \\    /// same shader body sees the same values on both targets.
        \\    srgb: bool = false,
        \\    /// Selects bilinear (true, the default — matches a `linear` GPU
        \\    /// sampler) vs nearest filtering.  The dispatcher leaves this at
        \\    /// the default unless the bound sampler is configured `nearest`.
        \\    linear: bool = true,
        \\};
        \\
        \\// 256-entry sRGB→linear table, built at comptime (the exact IEC
        \\// 61966-2-1 curve the GPU applies when sampling an `*_srgb` view).
        \\const _srgb_to_linear: [256]f32 = blk: {
        \\    @setEvalBranchQuota(20000);
        \\    var t: [256]f32 = undefined;
        \\    for (&t, 0..) |*v, i| {
        \\        const c: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        \\        v.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
        \\    }
        \\    break :blk t;
        \\};
        \\
        \\// Single RGBA8 texel fetch at integer (x, y), sRGB-aware.  When
        \\// `tex.srgb` is set the RGB channels are converted sRGB→linear via
        \\// the exact IEC curve the GPU applies to an `*_srgb` view; alpha
        \\// stays linear.  No bounds work — callers pass in-range coords.
        \\fn _texelRgba8(tex: TextureRef, x: u32, y: u32) @Vector(4, f32) {
        \\    @setRuntimeSafety(false);
        \\    const idx: usize = (@as(usize, y) * @as(usize, tex.width) + @as(usize, x)) * 4;
        \\    if (tex.srgb) {
        \\        return .{
        \\            _srgb_to_linear[tex.pixels[idx]],
        \\            _srgb_to_linear[tex.pixels[idx + 1]],
        \\            _srgb_to_linear[tex.pixels[idx + 2]],
        \\            @as(f32, @floatFromInt(tex.pixels[idx + 3])) / 255.0,
        \\        };
        \\    }
        \\    return .{
        \\        @as(f32, @floatFromInt(tex.pixels[idx])) / 255.0,
        \\        @as(f32, @floatFromInt(tex.pixels[idx + 1])) / 255.0,
        \\        @as(f32, @floatFromInt(tex.pixels[idx + 2])) / 255.0,
        \\        @as(f32, @floatFromInt(tex.pixels[idx + 3])) / 255.0,
        \\    };
        \\}
        \\
        \\// Sample a texture at `uv` with repeat wrap, matching the engine's
        \\// default GPU sampler `address_mode = .repeat` (glTF UVs may tile —
        \\// e.g. the DamagedHelmet's V runs [1, 2]).  `tex.linear` picks
        \\// bilinear (the default, matching a `linear` GPU sampler) vs nearest.
        \\// sRGB→linear runs per texel BEFORE the bilinear blend, exactly as
        \\// the hardware filters (convert at fetch, then lerp in linear space).
        \\// Locals are `uu`/`vv` (not `u`/`v`): `u` collides with the module-
        \\// level UBO extern `pub extern const u: Ubo` emitted above.
        \\fn sampleTextureRgba8(tex: TextureRef, uv: @Vector(2, f32)) @Vector(4, f32) {
        \\    @setRuntimeSafety(false);
        \\    const w_i: i32 = @intCast(tex.width);
        \\    const h_i: i32 = @intCast(tex.height);
        \\    const w_f: f32 = @as(f32, @floatFromInt(tex.width));
        \\    const h_f: f32 = @as(f32, @floatFromInt(tex.height));
        \\    var uu: f32 = uv[0] - @floor(uv[0]);
        \\    var vv: f32 = uv[1] - @floor(uv[1]);
        \\    if (uu < 0) uu = 0;
        \\    if (uu >= 1) uu = 0;
        \\    if (vv < 0) vv = 0;
        \\    if (vv >= 1) vv = 0;
        \\    if (!tex.linear) {
        \\        var x: i32 = @floor(uu * w_f);
        \\        var y: i32 = @floor(vv * h_f);
        \\        if (x >= w_i) x = w_i - 1;
        \\        if (y >= h_i) y = h_i - 1;
        \\        return _texelRgba8(tex, @intCast(x), @intCast(y));
        \\    }
        \\    // Bilinear: the -0.5 half-texel offset puts an integer uv*size on
        \\    // a texel centre; floor gives the lower-left texel and the fracs
        \\    // are the blend weights.  All four texel coords are repeat-wrapped
        \\    // with @mod (positive divisor: @mod(-1, w) = w-1, @mod(w, w) = 0).
        \\    const fx: f32 = uu * w_f - 0.5;
        \\    const fy: f32 = vv * h_f - 0.5;
        \\    const x0i: i32 = @floor(fx);
        \\    const y0i: i32 = @floor(fy);
        \\    const tx: f32 = fx - @as(f32, @floatFromInt(x0i));
        \\    const ty: f32 = fy - @as(f32, @floatFromInt(y0i));
        \\    const x0: u32 = @intCast(@mod(x0i, w_i));
        \\    const y0: u32 = @intCast(@mod(y0i, h_i));
        \\    const x1: u32 = @intCast(@mod(x0i + 1, w_i));
        \\    const y1: u32 = @intCast(@mod(y0i + 1, h_i));
        \\    const c00: @Vector(4, f32) = _texelRgba8(tex, x0, y0);
        \\    const c10: @Vector(4, f32) = _texelRgba8(tex, x1, y0);
        \\    const c01: @Vector(4, f32) = _texelRgba8(tex, x0, y1);
        \\    const c11: @Vector(4, f32) = _texelRgba8(tex, x1, y1);
        \\    const txv: @Vector(4, f32) = @splat(tx);
        \\    const tyv: @Vector(4, f32) = @splat(ty);
        \\    const top: @Vector(4, f32) = c00 + (c10 - c00) * txv;
        \\    const bot: @Vector(4, f32) = c01 + (c11 - c01) * txv;
        \\    return top + (bot - top) * tyv;
        \\}
        \\
        \\pub fn IoT(comptime UboType: type) type {
        \\    return struct {
        \\
    );
    if (@hasDecl(IfaceMod, "Inputs")) {
        const info = @typeInfo(IfaceMod.Inputs).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "        {s}: {s},\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
    }
    // For VS shaders, vertex attributes ARE the inputs.
    if (@hasDecl(IfaceMod, "Attributes")) {
        const info = @typeInfo(IfaceMod.Attributes).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const AttrT: type = field_type;
            const elem = @field(AttrT, "element");
            try writer.print(
                "        {s}: {s},\n",
                .{ field_name, zigTypeForElem(elem) },
            );
        }
    }
    // Loose Uniforms - engine-managed + custom scalars.  These are
    // distinct from Ubo (a single uniform block).  In the GLSL output
    // they become individual `uniform` decls; in Io they become
    // top-level fields.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        const info = @typeInfo(IfaceMod.Uniforms).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "        {s}: {s},\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Ubo")) {
        try writer.writeAll("        u: UboType,\n");
    }
    // CPU-only sampler bindings: one TextureRef field per sampler.
    // On SPIR-V target the field is `void` (the sampler comes from a
    // binding decl, not from Io).  The accessor method below
    // dispatches per-target.
    //
    // Field name is `_<sampler_name>` (leading underscore) so the
    // bare name stays reserved for the accessor method.  Caller code
    // does `io._texture0 = .{ .pixels = ..., .width = ..., .height = ...};`
    // before dispatch.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const info = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "        _{s}: if (_builtin.target.cpu.arch.isSpirV()) void else TextureRef,\n",
                .{field_name},
            );
        }
    }
    // CPU-only storage-buffer bindings: one slice field per Storage member.
    // On SPIR-V the field is `void` (the buffer comes from a binding decl);
    // on CPU it's a `[]const Elem` slice the dispatcher would fill.
    if (@hasDecl(IfaceMod, "Storage")) {
        const info = @typeInfo(IfaceMod.Storage).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const Elem: type = @field(field_type, "element");
            try writer.print(
                "        _{s}: if (_builtin.target.cpu.arch.isSpirV()) void else []const {s},\n",
                .{ field_name, zigTypeForType(Elem) },
            );
        }
    }
    try writer.writeAll("\n");
    // ---- Declarations (must come AFTER all fields per Zig's
    // container layout rule).
    if (!@hasDecl(IfaceMod, "Ubo")) {
        // No Ubo - UboType param is unused.  Emit a comptime discard
        // so Zig doesn't flag the param.  When Ubo IS present, the
        // `u: UboType` field above is the usage; emitting `_ = UboType`
        // anyway would trip the "pointless discard of function
        // parameter" check.
        try writer.writeAll(
            "        comptime {\n" ++
                "            _ = UboType;\n" ++
                "        }\n",
        );
    }
    // Sampler accessor methods - `pub fn texture0(self, uv) Vec`.
    // Body is target-conditional via `comptime` if so the unused
    // branch doesn't have to compile.  SPIR-V calls the extern sample
    // op; CPU does a nearest-neighbor lookup against `self._<name>`.
    //
    // No `_ = self;` in the SPIR-V branch - `self` IS used after the
    // if (in the CPU return), and Zig considers that a use regardless
    // of comptime-dead status, so an explicit discard trips the
    // "pointless discard of function parameter" check.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const info = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (info.field_names) |field_name| {
            // SPIR-V: `sampleLod` is `inline`, so OpSampledImage + the implicit-LOD
            // sample land right here, reading the two global handles directly -
            // spv2wgsl turns that into `textureSample(texture0, texture0_sampler, uv)`.
            try writer.print(
                "        pub fn {s}(self: @This(), uv: @Vector(2, f32)) @Vector(4, f32) {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return zm_mod.sampleLod(_Spirv._tex_{s}, _Spirv._smp_{s}, uv);\n" ++
                    "            }}\n" ++
                    "            return sampleTextureRgba8(self._{s}, uv);\n" ++
                    "        }}\n",
                .{ field_name, field_name, field_name, field_name },
            );
            // Explicit-LOD twin - legal in a VERTEX shader (no derivatives).
            // CPU path ignores `lod` and samples the base level.
            try writer.print(
                "        pub fn {s}Level(self: @This(), uv: @Vector(2, f32), lod: f32) @Vector(4, f32) {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return zm_mod.sampleLevel(_Spirv._tex_{s}, _Spirv._smp_{s}, uv, lod);\n" ++
                    "            }}\n" ++
                    "            return sampleTextureRgba8(self._{s}, uv);\n" ++
                    "        }}\n",
                .{ field_name, field_name, field_name, field_name },
            );
        }
    }
    // Storage-buffer accessor methods - `pub fn positions(self, i) Elem`.
    // On SPIR-V, `ssboLoad` the extern buffer; on CPU, index the
    // host-supplied slice field `_<name>`. (CPU path only needed if a
    // storage-fed shader is ever run through the software rasterizer; for
    // now the SPIR-V branch is what matters and the CPU branch reads the
    // slice the dispatcher would set.)
    if (@hasDecl(IfaceMod, "Storage")) {
        const info = @typeInfo(IfaceMod.Storage).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const Elem: type = @field(field_type, "element");
            const elem_name = zigTypeForType(Elem);
            try writer.print(
                "        pub fn {s}(self: @This(), i: u32) {s} {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return zm_ssboLoad({s}, _Spirv.{s}, i);\n" ++
                    "            }}\n" ++
                    "            return self._{s}[i];\n" ++
                    "        }}\n",
                .{ field_name, elem_name, elem_name, field_name, field_name },
            );
        }
    }
    // Builtin accessor methods - `pub fn vertex_index(self) u32`.
    // SPIR-V-only values; the CPU branch returns 0 (dispatcher drives
    // per-vertex/instance iteration itself, so the body's builtin reads
    // aren't used on CPU).
    if (@hasDecl(IfaceMod, "Builtins")) {
        const info = @typeInfo(IfaceMod.Builtins).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            const kind: shader_iface.BuiltinKind = @field(field_type, "builtin");
            const spirv_name: []const u8 = switch (kind) {
                .vertex_index => "vertex_index",
                .instance_index => "instance_index",
            };
            try writer.print(
                "        pub fn {s}(self: @This()) u32 {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return std.spirv.{s};\n" ++
                    "            }}\n" ++
                    "            _ = self;\n" ++
                    "            return 0;\n" ++
                    "        }}\n",
                .{ field_name, spirv_name },
            );
        }
    }
    try writer.writeAll("    };\n}\n\n");

    // Emit `pub const Out = struct { ... }`.
    //
    // For VS shaders (detected by `@hasDecl("Attributes")` - vertex
    // shaders consume vertex attributes, FS consume varying inputs),
    // automatically emit a `position: @Vector(4, f32)` field.  This
    // is the clip-space output position the rasterizer needs.
    //
    // On SPIR-V the codegen wires `out.position` -> `position_out.*`
    // (std.gpu's special-cased clip-space output).  On CPU the
    // dispatcher reads `out.position` directly to drive triangle
    // setup.  Single source of truth; the shader source writes one
    // field and both targets DTRT.
    try writer.writeAll("pub const Out = struct {\n");
    if (@hasDecl(IfaceMod, "Attributes")) {
        try writer.writeAll("    position: @Vector(4, f32),\n");
    }
    if (@hasDecl(IfaceMod, "Outputs")) {
        const info = @typeInfo(IfaceMod.Outputs).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "    {s}: {s},\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
    }
    try writer.writeAll("};\n\n");

    // Emit `pub fn installSpirvEntry`.  On SPIR-V target it materializes
    // the entry-point wrapper; on CPU target it's a no-op.  Body uses a
    // comptime check via `@import("builtin")` so the SPIR-V backend
    // only sees the SPIR-V branch (and vice versa).
    //
    // The function takes the body fn as an anytype: caller passes
    // `pub fn shaderMain(io: Foo) Bar` and the wrapper infers Io / Out
    // from the function's signature.  This keeps io.zig free of any
    // mention of the iface module - Io and Out are owned by the
    // shader source's IoT(iface.Ubo) instantiation.
    try writer.writeAll(
        \\// installSpirvEntry: comptime-emit the SPIR-V `entry` wrapper.
        \\// Pattern verified in session 13's design experiment:
        \\//   pub fn shaderMain(io: Io) Out { ... return out; }
        \\//   comptime { _ = installSpirvEntry(shaderMain); }
        \\// On SPIR-V targets this materializes an `export fn entry`
        \\// that reads externs into the body's Io type, calls the body,
        \\// writes the returned Out back to extern outputs.  On CPU
        \\// targets it's a no-op (the dispatcher in `src/raster_shader.zig`
        \\// calls the body directly per pixel).
        \\//
        \\// `body` is anytype so the io module doesn't need to name the
        \\// concrete Io / Out types — those live in the shader source.
        \\pub fn installSpirvEntry(comptime body: anytype) void {
        \\    if (!_builtin.target.cpu.arch.isSpirV()) return;
        \\    const _FnInfo = @typeInfo(@TypeOf(body)).@"fn";
        \\    const _IoT = _FnInfo.param_types[0].?;
        \\    const _OutT = _FnInfo.return_type.?;
        \\    const Wrapper = struct {
        \\
    );
    // Stage-specific callconv: VS gets `.spirv_vertex`, FS gets
    // `.spirv_fragment`.  Detection mirrors the Out emit: presence
    // of an Attributes decl = VS schema.
    if (@hasDecl(IfaceMod, "Attributes")) {
        try writer.writeAll(
            "        export fn entry() callconv(.spirv_vertex) void {\n",
        );
    } else {
        try writer.writeAll(
            "        export fn entry() callconv(.{ .spirv_fragment = .{} }) void {\n",
        );
    }
    try writer.writeAll("            @setRuntimeSafety(false);\n");
    // No decoration calls here: every `_Spirv` variable read below was declared
    // as an `@extern` with its decoration attached (the "HOW EVERY DECL BELOW GETS
    // ITS DECORATION" block). They are pointers, hence the `.*` on each read.
    // Build the Io struct from externs.
    try writer.writeAll("            const io: _IoT = .{\n");
    if (@hasDecl(IfaceMod, "Inputs")) {
        const info = @typeInfo(IfaceMod.Inputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv.{s}.*,\n",
                .{ field_name, field_name },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Attributes")) {
        const info = @typeInfo(IfaceMod.Attributes).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv.{s}.*,\n",
                .{ field_name, field_name },
            );
        }
    }
    // Loose Uniforms: each becomes an Io field, read out of its one-field
    // uniform block (`_<name>_block.value`). The Uniforms field type may carry a
    // default (e.g. `col_diffuse: Vec = .{1,1,1,1}`) - that only matters on the
    // CPU side; on the GPU the value always comes from the bound buffer.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        const info = @typeInfo(IfaceMod.Uniforms).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv._{s}_block.value,\n",
                .{ field_name, field_name },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Ubo")) {
        // Construct the Ubo field-by-field rather than `.u = u`.  The
        // io-side `u: Ubo` extern is io's own duplicate Ubo type;
        // body's _IoT.u expects the iface's Ubo type (passed in to
        // IoT).  Those two extern structs are layout-identical but
        // nominally distinct - Zig rejects whole-struct assignment.
        // Field-by-field via an anonymous-struct literal coerces to
        // the target's Ubo type with no copy at the SPIR-V level
        // (spirv-opt folds the constructor).
        try writer.writeAll("                .u = .{\n");
        const ubo_info = @typeInfo(IfaceMod.Ubo).@"struct";
        inline for (ubo_info.field_names) |field_name| {
            try writer.print(
                "                    .{s} = _Spirv.u.{s},\n",
                .{ field_name, field_name },
            );
        }
        try writer.writeAll("                },\n");
    }
    // Sampler bindings: on SPIR-V the field type is `void` so we
    // assign the empty void value.  The accessor methods' SPIR-V
    // branch ignores `self`, so this field is never read in practice.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const info = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                ._{s} = {{}},\n",
                .{field_name},
            );
        }
    }
    // Storage bindings: same as samplers - SPIR-V field type is `void`,
    // assign the empty value; the accessor's SPIR-V branch reaches into
    // `_Spirv.<name>` directly and never reads this field.
    if (@hasDecl(IfaceMod, "Storage")) {
        const info = @typeInfo(IfaceMod.Storage).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                ._{s} = {{}},\n",
                .{field_name},
            );
        }
    }
    try writer.writeAll(
        \\            };
        \\            const out: _OutT = body(io);
        \\
    );
    // Write Out fields back to extern outputs.  When Outputs is
    // empty (e.g. shadow_vs has `pub const Outputs = struct {}`)
    // AND this is not a VS (no Attributes -> no auto-emitted
    // `position` field), discard `out` to silence the unused-local
    // check.
    const has_outputs = @hasDecl(IfaceMod, "Outputs") and
        @typeInfo(IfaceMod.Outputs).@"struct".field_names.len > 0;
    const is_vs = @hasDecl(IfaceMod, "Attributes");
    if (has_outputs) {
        const info = @typeInfo(IfaceMod.Outputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "            _Spirv.{s}.* = out.{s};\n",
                .{ field_name, field_name },
            );
        }
    }
    // For VS shaders, wire out.position -> std.gpu's position_out.*
    // (the special-cased clip-space output the SPIR-V backend
    // recognizes).  This decoupling - VS source writes a regular
    // struct field, codegen handles the SPIR-V binding - keeps the
    // shader body free of the `position_out.* = ...` magic and lets
    // the same field flow naturally to the CPU rasterizer.
    //
    // `position_out` has type `*addrspace(.output) @Vector(4, f32)`
    // (see `std/gpu.zig`).  Address-space-typed pointers don't cast
    // to plain pointers, so we just use the std.gpu decl directly
    // - no intermediate local variable needed.  Access via _Spirv
    // (the namespace wrapping all SPIR-V-only decls).
    if (is_vs) {
        try writer.writeAll(
            "            _Spirv.position_out.* = out.position;\n",
        );
    } else if (!has_outputs) {
        try writer.writeAll("            _ = out;\n");
    }
    try writer.writeAll(
        \\        }
        \\    };
        \\    _ = Wrapper;
        \\}
        \\
        \\
    );

    // The installSpirvEntry body references `_builtin` - we add the
    // import below alongside the shadermath forwarding decls.

    // ---- Forwarding decls to keep the generated file dep-free ----
    // The IoT accessors reach the GPU helpers through `zm_mod` -
    // `sampleLod` / `sampleLevel` for textures and `ssboLoad` for
    // storage buffers. `_builtin` is declared in the prologue (so
    // `_is_spirv` can reference it for the `_Spirv` wrap), but this
    // import lives at the bottom so the file's top reads as a
    // "what's in here" inventory.
    const needs_shadermath = @hasDecl(IfaceMod, "Attributes") or
        @hasDecl(IfaceMod, "Inputs") or
        @hasDecl(IfaceMod, "Outputs") or
        @hasDecl(IfaceMod, "Ubo") or
        @hasDecl(IfaceMod, "Storage") or
        @hasDecl(IfaceMod, "Samplers");
    if (needs_shadermath) {
        try writer.writeAll(
            \\// ---- Imports (kept at the bottom so the top of the file
            \\//             reads as a stage-interface inventory) -------
            \\const zm_mod = @import("shader_builtins");
            \\const zm_ssboLoad = zm_mod.ssboLoad;
            \\
        );
    }
}

// ==== BUILD-TIME CHECK: the WGSL a shader became vs. the slots its schema promised ====
//
// `emit` decides where every resource lives - its (group, binding) and its name - and
// writes that decision onto each `@extern`. After the shader goes through the compiler,
// the SPIR-V linker and spv2wgsl, `checkWgsl` reads the resulting WGSL's own
// `@group/@binding` declarations back and demands they are exactly those decisions.
//
// Why a second check when spv2wgsl already refuses undecorated variables: that one catches
// a decoration that went MISSING. This one catches a decoration that is PRESENT BUT WRONG -
// a linker that renumbers, a transpiler that reorders, a generator edit that drifts from
// the host's rule. Either way the result is Dawn rejecting the pipeline on a device, which
// is exactly what Zig 0.17.0-dev.2307 did to every graphics shader in the tree.
//
// The expected cells come from the SAME functions `emit` uses, which are also the ones the
// host's layout solver calls (`uniformGroupForSchema`, `solveSamplerSlots`,
// `solveStorageSlots`), plus the loose-`Uniforms` rule (the uniform group, bindings 0, 1,
// 2... in declaration order) that the host builds by hand for the four shaders that use it.
//
// Direction: every WGSL binding must be an expected cell, of the right kind, with the right
// name, and no cell may hold two. An expected cell the WGSL does NOT declare is fine - the
// compiler drops a resource the shader never reads, and WebGPU allows a layout to offer more
// than a pipeline uses.

const WgslKind = wgsl_reflect.WgslBinding.Kind;

const ExpectedCell = struct {
    group: u32,
    binding: u32,
    kind: WgslKind,
    name: []const u8,
};

fn expectedCellCount(comptime IfaceMod: type) usize {
    comptime var count: usize = 0;
    if (@hasDecl(IfaceMod, "Ubo")) {
        count += 1;
    }
    if (@hasDecl(IfaceMod, "Uniforms")) {
        count += @typeInfo(IfaceMod.Uniforms).@"struct".field_names.len;
    }
    if (@hasDecl(IfaceMod, "Storage")) {
        count += @typeInfo(IfaceMod.Storage).@"struct".field_names.len;
    }
    if (@hasDecl(IfaceMod, "Samplers")) {
        count += 2 * @typeInfo(IfaceMod.Samplers).@"struct".field_names.len; // texture + sampler
    }
    return count;
}

/// Every (group, binding, kind, name) cell `emit` puts on this schema's `@extern`s.
fn expectedCells(comptime IfaceMod: type) [expectedCellCount(IfaceMod)]ExpectedCell {
    return comptime blk: {
        var cells: [expectedCellCount(IfaceMod)]ExpectedCell = undefined;
        var next: usize = 0;
        const uniform_group: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        if (@hasDecl(IfaceMod, "Ubo")) {
            cells[next] = .{ .group = uniform_group, .binding = 0, .kind = .uniform, .name = "u" };
            next += 1;
        }
        if (@hasDecl(IfaceMod, "Uniforms")) {
            for (@typeInfo(IfaceMod.Uniforms).@"struct".field_names, 0..) |field_name, binding| {
                cells[next] = .{ .group = uniform_group, .binding = binding, .kind = .uniform, .name = field_name };
                next += 1;
            }
        }
        if (@hasDecl(IfaceMod, "Storage")) {
            const storage_slots = shader_iface.solveStorageSlots(IfaceMod);
            for (@typeInfo(IfaceMod.Storage).@"struct".field_names, storage_slots) |field_name, slot| {
                cells[next] = .{ .group = slot.group, .binding = slot.binding, .kind = .storage, .name = field_name };
                next += 1;
            }
        }
        if (@hasDecl(IfaceMod, "Samplers")) {
            const sampler_slots = shader_iface.solveSamplerSlots(IfaceMod.Samplers);
            for (@typeInfo(IfaceMod.Samplers).@"struct".field_names, sampler_slots) |field_name, slot| {
                cells[next] = .{ .group = slot.group, .binding = slot.binding, .kind = .texture, .name = field_name };
                cells[next + 1] = .{
                    .group = slot.group,
                    .binding = slot.binding + 1,
                    .kind = .sampler,
                    .name = field_name ++ "_sampler",
                };
                next += 2;
            }
        }
        break :blk cells;
    };
}

/// Check the WGSL `IfaceMod`'s shader became against the slots `emit` promised. Returns null
/// when it matches, otherwise a description of the FIRST disagreement (owned by `gpa`).
pub fn checkWgsl(
    comptime IfaceMod: type,
    gpa: std.mem.Allocator,
    wgsl: []const u8,
) !?[]u8 {
    const expected = comptime expectedCells(IfaceMod);
    const actual: []wgsl_reflect.WgslBinding = try wgsl_reflect.reflectWgslBindings(gpa, wgsl);
    defer wgsl_reflect.freeWgslBindings(gpa, actual);

    for (actual, 0..) |found, i| {
        // Two WGSL resources on one slot: the exact shape of the 2307 failure.
        for (actual[0..i]) |earlier| {
            const same_cell: bool = earlier.group == found.group and earlier.binding == found.binding;
            if (same_cell) {
                return try allocPrint(
                    gpa,
                    "@group({d}) @binding({d}) holds both '{s}' and '{s}' - one slot, two resources",
                    .{ found.group, found.binding, earlier.name, found.name },
                );
            }
        }
        var match: ?ExpectedCell = null;
        for (expected) |cell| {
            if (cell.group == found.group and cell.binding == found.binding) {
                match = cell;
                break;
            }
        }
        const cell: ExpectedCell = match orelse {
            return try allocPrint(
                gpa,
                "'{s}' ({s}) is at @group({d}) @binding({d}), where the schema puts nothing",
                .{ found.name, found.kindLabel(), found.group, found.binding },
            );
        };
        const kind_matches: bool = cell.kind == found.kind;
        const name_matches: bool = std.mem.eql(u8, cell.name, found.name);
        if (!kind_matches or !name_matches) {
            return try allocPrint(
                gpa,
                "@group({d}) @binding({d}) should be '{s}' ({s}) but the WGSL declares '{s}' ({s}) there",
                .{ found.group, found.binding, cell.name, @tagName(cell.kind), found.name, found.kindLabel() },
            );
        }
    }
    return null;
}

// ---- Unit tests
// These verify the emit logic against fixture ifaces inline.  Run
// via `zig build test`.  Real round-trip verification (generated
// extern file -> spirv compile -> identical GLSL) belongs in the main
// build's smoke pass once the build.zig wiring lands.

const ElemKindForTest = enum { vec2, vec3, vec4, ivec4, uvec4 };

/// Test-only Attr stub.  Mirrors `shader_interface.Attr(elem, loc)`'s
/// public shape (`element`, `location`) without depending on the real
/// type - so this test file is self-contained.
fn FakeAttr(comptime elem_kind: ElemKindForTest, comptime loc: u32) type {
    return struct {
        pub const element: ElemKindForTest = elem_kind;
        pub const location: u32 = loc;
    };
}

test "emit handles VS schema (attrs + outputs + uniforms)" {
    const t: type = std.testing;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();

    const Iface = struct {
        pub const Attributes = struct {
            pos: FakeAttr(.vec3, 0),
            uv: FakeAttr(.vec2, 1),
        };
        pub const Outputs = struct {
            frag_uv: [2]f32,
        };
        pub const Uniforms = struct {
            mvp: [16]f32 = @splat(0),
        };
    };

    try emit(Iface, &aw.writer);
    const out: []const u8 = aw.written();

    // Attributes: the Attr type's own location rides on the declaration.
    try t.expect(std.mem.indexOf(u8, out, "pub const pos = @extern(*addrspace(.input) const @Vector(3, f32), " ++
        ".{ .name = \"pos\", .decoration = .{ .location = 0 } });") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const uv = @extern(*addrspace(.input) const @Vector(2, f32), " ++
        ".{ .name = \"uv\", .decoration = .{ .location = 1 } });") != null);
    // Outputs: writable pointer, location by declaration order.
    try t.expect(std.mem.indexOf(u8, out, "pub const frag_uv = @extern(*addrspace(.output) [2]f32, " ++
        ".{ .name = \"frag_uv\", .decoration = .{ .location = 0 } });") != null);
    // A VS loose uniform: one-field block in group 0, binding 0.
    try t.expect(std.mem.indexOf(u8, out, "pub const _mvp_block = @extern(*addrspace(.uniform) const extern struct " ++
        "{ value: [4]@Vector(4, f32) }, .{ .name = \"mvp\", .decoration = .{ .descriptor = " ++
        ".{ .set = 0, .binding = 0 } } });") != null);
    // Nothing is decorated through asm any more.
    try t.expect(std.mem.indexOf(u8, out, "zm_location") == null);
    try t.expect(std.mem.indexOf(u8, out, "zm_binding") == null);
}

test "emit handles FS schema (inputs + samplers + uniforms + outputs)" {
    const t: type = std.testing;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();

    const Iface = struct {
        pub const Inputs = struct {
            frag_uv: [2]f32,
            frag_normal: [3]f32,
        };
        pub const Samplers = struct {
            albedo: shader_iface.Sampler2D(.albedo, .{}),
            normal_map: shader_iface.Sampler2D(.normal, .{}),
        };
        pub const Uniforms = struct {
            col: [4]f32 = .{ 1, 1, 1, 1 },
        };
        pub const Outputs = struct {
            out_color: [4]f32,
        };
    };

    try emit(Iface, &aw.writer);
    const out: []const u8 = aw.written();

    // Inputs: sequential locations, carried on the declaration.
    try t.expect(std.mem.indexOf(u8, out, "pub const frag_uv = @extern(*addrspace(.input) const [2]f32, " ++
        ".{ .name = \"frag_uv\", .decoration = .{ .location = 0 } });") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const frag_normal = @extern(*addrspace(.input) const [3]f32, " ++
        ".{ .name = \"frag_normal\", .decoration = .{ .location = 1 } });") != null);
    // Samplers: a REAL texture at (group, N) and its sampler at (group, N+1),
    // with the slots from the same solver the host layout uses.
    const slots = comptime shader_iface.solveSamplerSlots(Iface.Samplers);
    inline for (.{ "albedo", "normal_map" }, 0..) |name, i| {
        const texture_decl: []const u8 = std.fmt.comptimePrint(
            "pub const _tex_{s} = @extern(_sb.Texture2DPtr(), .{{ .name = \"{s}\", .decoration = " ++
                ".{{ .descriptor = .{{ .set = {d}, .binding = {d} }} }} }});",
            .{ name, name, slots[i].group, slots[i].binding },
        );
        const sampler_decl: []const u8 = std.fmt.comptimePrint(
            "pub const _smp_{s} = @extern(_sb.SamplerPtr(), .{{ .name = \"{s}_sampler\", .decoration = " ++
                ".{{ .descriptor = .{{ .set = {d}, .binding = {d} }} }} }});",
            .{ name, name, slots[i].group, slots[i].binding + 1 },
        );
        try t.expect(std.mem.indexOf(u8, out, texture_decl) != null);
        try t.expect(std.mem.indexOf(u8, out, sampler_decl) != null);
    }
    // The u32 placeholder is gone for good.
    try t.expect(std.mem.indexOf(u8, out, "_sampler2d") == null);
    // An FS loose uniform: one-field block in group 2.
    try t.expect(std.mem.indexOf(u8, out, "pub const _col_block = @extern(*addrspace(.uniform) const extern struct " ++
        "{ value: [4]f32 }, .{ .name = \"col\", .decoration = .{ .descriptor = " ++
        ".{ .set = 2, .binding = 0 } } });") != null);
    // Outputs: writable pointer.
    try t.expect(std.mem.indexOf(u8, out, "pub const out_color = @extern(*addrspace(.output) [4]f32, " ++
        ".{ .name = \"out_color\", .decoration = .{ .location = 0 } });") != null);
    // No Attributes block emitted (FS has no @hasDecl(_, "Attributes")).
    try t.expect(std.mem.indexOf(u8, out, "// Vertex attributes") == null);
}

test "checkWgsl: ssao_blur's WGSL as 2307 produced it is refused, the fixed one accepted" {
    const t: type = std.testing;
    // Mirrors src/shaders/ssao_blur_fs_io.zig: an FS Ubo plus three free samplers.
    const Iface = struct {
        pub const Inputs = struct {
            frag_uv: [2]f32,
        };
        pub const Samplers = struct {
            src: shader_iface.Sampler2D(.albedo, .{}),
            g_world_pos: shader_iface.Sampler2D(.normal, .{}),
            g_world_normal: shader_iface.Sampler2D(.emission, .{}),
        };
        pub const Ubo = struct {
            step: [4]f32,
        };
        pub const Outputs = struct {
            blurred: [4]f32,
        };
    };
    // The binding header ssao_blur_fs really had on 2307, decorations dropped: everything
    // in group 0, the Ubo and `src` sharing one slot.
    const broken_2307: []const u8 =
        \\@group(0) @binding(0) var<uniform> u: S36;
        \\@group(0) @binding(0) var src: texture_2d<f32>;
        \\@group(0) @binding(3) var src_sampler: sampler;
        \\@group(0) @binding(1) var g_world_pos: texture_2d<f32>;
        \\@group(0) @binding(4) var g_world_pos_sampler: sampler;
        \\@group(0) @binding(2) var g_world_normal: texture_2d<f32>;
        \\@group(0) @binding(5) var g_world_normal_sampler: sampler;
        \\
    ;
    const problem: ?[]u8 = try checkWgsl(Iface, t.allocator, broken_2307);
    try t.expect(problem != null);
    defer if (problem) |p| t.allocator.free(p);
    // The FIRST thing wrong is the UBO: the schema puts it at group 2.
    try t.expect(std.mem.indexOf(u8, problem.?, "@group(0) @binding(0)") != null);

    // The same shader as the current generator emits it.
    const fixed: []const u8 =
        \\@group(2) @binding(0) var<uniform> u: S12;
        \\@group(1) @binding(2) var g_world_pos: texture_2d<f32>;
        \\@group(1) @binding(3) var g_world_pos_sampler: sampler;
        \\@group(1) @binding(0) var src: texture_2d<f32>;
        \\@group(1) @binding(1) var src_sampler: sampler;
        \\@group(1) @binding(4) var g_world_normal: texture_2d<f32>;
        \\@group(1) @binding(5) var g_world_normal_sampler: sampler;
        \\
    ;
    try t.expect(try checkWgsl(Iface, t.allocator, fixed) == null);

    // Right slots, wrong names: a texture and sampler pair swapped between two fields.
    const swapped: []const u8 =
        \\@group(2) @binding(0) var<uniform> u: S12;
        \\@group(1) @binding(0) var g_world_pos: texture_2d<f32>;
        \\@group(1) @binding(2) var src: texture_2d<f32>;
        \\
    ;
    const swap_problem: ?[]u8 = try checkWgsl(Iface, t.allocator, swapped);
    try t.expect(swap_problem != null);
    t.allocator.free(swap_problem.?);
}

test "checkWgsl: loose Uniforms are expected at the uniform group, bindings in order" {
    const t: type = std.testing;
    // Mirrors lambert's VS: two loose uniforms, which the host binds at group 0, 0 and 1.
    const Iface = struct {
        pub const Attributes = struct {
            vertex_position: FakeAttr(.vec3, 0),
        };
        pub const Uniforms = struct {
            mvp: [16]f32 = @splat(0),
            mat_model: [16]f32 = @splat(0),
        };
        pub const Outputs = struct {
            frag_normal: [3]f32,
        };
    };
    const good: []const u8 =
        \\@group(0) @binding(0) var<uniform> mvp: S1;
        \\@group(0) @binding(1) var<uniform> mat_model: S2;
        \\
    ;
    try t.expect(try checkWgsl(Iface, t.allocator, good) == null);
    const reordered: []const u8 =
        \\@group(0) @binding(0) var<uniform> mat_model: S2;
        \\@group(0) @binding(1) var<uniform> mvp: S1;
        \\
    ;
    const problem: ?[]u8 = try checkWgsl(Iface, t.allocator, reordered);
    try t.expect(problem != null);
    t.allocator.free(problem.?);
}

test "emit rejects unsupported types with a clear compileError" {
    // Compile-time-only check - exercising this requires `@compileError`,
    // which we can't test at runtime.  Documented here as an
    // intentional invariant: `zigTypeForType(f64)` etc. fail the
    // build with a message naming the offending type.
    // The acceptance test is: try to use `f64` in a schema and confirm
    // the build fails with the expected message.
}
