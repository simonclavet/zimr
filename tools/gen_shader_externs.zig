//! tools/gen_shader_externs.zig — codegen library for the per-shader
//! The binding model this codegen implements (VS uniforms=group 0,
//! samplers=group 1, FS uniforms=group 2) is documented centrally in
//! src/zimr.zig (§3) — the single source of truth for the wgpu stack.
//!
//! `*_extern.zig` files referenced by shader bodies.
//!
//! Phase 2 of `src/notes/typesafe_zig_shaders.md`.  Phase 1 hand-wrote
//! the extern decls in each `_vs.zig` / `_fs.zig` body, duplicating
//! the iface schema.  Phase 2 derives them from the iface struct via
//! comptime reflection.
//!
//! This file is a LIBRARY — `pub fn emit(comptime IfaceMod: type,
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
//! module dep, so each one sees exactly ONE iface — no shared-file
//! conflict between ifaces (which doomed earlier aggregator attempts).
//! This pattern scales naturally to external zimr users: their
//! `addShader(body, .{ .iface = LazyPath })` call from their own
//! build.zig invokes the same bootstrap-per-shader pipeline with
//! their iface module wired in.

const std = @import("std");
const shader_iface = @import("shader_interface");
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
/// for readability — flat 16 floats — and get emitted as the
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
        // Matrices: flat 16 floats in source schema → 4×vec4 in the
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
            //   [MAX_DIRECTIONAL_LIGHTS]@Vector(3, f32) → "[N]@Vector(3, f32)"
            //   [MAX_POINT_LIGHTS]f32                   → "[N]f32"
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
/// (FS only) `Samplers`.  Missing decls are skipped — this is what
/// lets the same `emit` work for both stages.
///
/// Emitted code is self-contained: no `@import` of `shadermath` etc.
/// Vec types come through as `@Vector(N, f32)`; matrices as
/// `[4]@Vector(4, f32)`.  The shader body — which imports
/// `shadermath` for math helpers — sees the externs through the
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
    // `Ubo` is recognized; `Ubos` is not (singular form on purpose —
    // there's exactly one UBO per shader for now).  Sub-types referenced
    // by the recognized decls (e.g. a `Helper` type used inside `Ubo`'s
    // fields) are decl in the iface module too — they're ignored here
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
        // are left alone — they may legitimately be local constants
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
    // creation* on the device — a driver error far from the schema. Catch it
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
                "pub extern const {s}: {s} addrspace(.input);\n",
                .{ field_name, zigTypeForElem(elem) },
            );
            try writer.print(
                "pub const _location_{s}: u32 = {d};\n",
                .{ field_name, loc },
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
                "pub extern const {s}: {s} addrspace(.input);\n",
                .{ field_name, zigTypeForType(field_type) },
            );
            try writer.print(
                "pub const _location_{s}: u32 = {d};\n",
                .{ field_name, i },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- VS Outputs / FS Outputs: location by declaration order.
    // The field name `frag_depth` is a BUILTIN, not a located output:
    // the extern is emitted with that exact name (the SPIR-V backend
    // name-magics it to the FragDepth builtin, same mechanism as
    // `position`) and it neither gets a Location decoration nor
    // consumes a location index — color outputs after it keep their
    // slots.
    if (@hasDecl(IfaceMod, "Outputs")) {
        try writer.writeAll("// Stage outputs (location = field index; frag_depth = builtin).\n");
        const T = IfaceMod.Outputs;
        const info = @typeInfo(T).@"struct";
        comptime var out_loc: u32 = 0;
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "pub extern var {s}: {s} addrspace(.output);\n",
                .{ field_name, zigTypeForType(field_type) },
            );
            if (comptime !std.mem.eql(u8, field_name, "frag_depth")) {
                try writer.print(
                    "pub const _location_{s}: u32 = {d};\n",
                    .{ field_name, out_loc },
                );
                out_loc += 1;
            }
        }
        try writer.writeAll("\n");
    }

    // ---- Uniforms: loose, .constant storage class, no location
    if (@hasDecl(IfaceMod, "Uniforms")) {
        try writer.writeAll("// Uniforms (loose, .constant storage class).\n");
        const T = IfaceMod.Uniforms;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            try writer.print(
                "pub extern const {s}: {s} addrspace(.constant);\n",
                .{ field_name, zigTypeForType(field_type) },
            );
        }
        try writer.writeAll("\n");
    }

    // ---- Samplers: `<name>_sampler2d: u32 addrspace(.constant)` plus
    //               a `<name>(uv)` accessor method that wraps the
    //               zsample2d call.  Shader body calls `io.albedo(uv)`
    //               instead of `zm.zsample2d(io.albedo_sampler2d, uv)`.
    if (@hasDecl(IfaceMod, "Samplers")) {
        try writer.writeAll(
            "// Samplers — `_sampler2d` suffix stripped by zspv at SPIR-V level.\n" ++
                "// Each sampler gets a companion accessor function `<name>(uv)`\n" ++
                "// so the shader body can call `io.<name>(uv)` instead of\n" ++
                "// hand-writing `zsample2d(<name>_sampler2d, uv)`.\n",
        );
        const T = IfaceMod.Samplers;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            // Sanity-check: the field type must be a Sampler2D-shaped
            // marker (has both `slot` AND `sampler_config` decls).
            // Anything else is a schema error — most commonly:
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
            try writer.print(
                "pub extern const {s}_sampler2d: u32 addrspace(.constant);\n",
                .{field_name},
            );
        }
        try writer.writeAll("\n");
    }

    // ---- Ubo: single uniform buffer block at descriptor set 0,
    //          binding 0.  See header comment for the design.
    //
    // Split between layers: the `Ubo` STRUCT TYPE def lives at
    // MODULE level (it's a pure type, target-independent, must be
    // visible to consumer code that does `shader_externs.Ubo`).
    // The `extern const u: Ubo addrspace(.uniform)` extern decl
    // lives INSIDE `_Spirv` (only valid on SPIR-V targets).  The
    // `_binding_u: u32` const stays inside `_Spirv` too — only the
    // entry-point Wrapper needs to reference it, and that access
    // is already `_Spirv._binding_u`.
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
        // Dawn would refuse (e.g. `[N]f32` → `array<f32,N>` stride 4). Fails here
        // with a precise message instead of shipping bad WGSL to the device.
        shader_iface.assertValidUniform(IfaceMod.Ubo);
        // The SPIR-V-side wire mirror.  Zig 0.17.0-dev.1245 bans `@Vector`
        // fields in extern structs on CPU targets, so the module-level `Ubo`
        // below is a PLAIN struct; the uniform pointee needs the guaranteed
        // C/extern layout, which is still legal on the SPIR-V target where
        // vectors have a defined representation.  `UboWire` lives inside
        // `_Spirv` so CPU targets never resolve its layout.  Field names and
        // types match `Ubo` exactly — the entry wrapper copies field-by-field
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
        try writer.writeAll("pub extern const u: UboWire addrspace(.uniform);\n");
        try writer.writeAll("pub const _binding_u: u32 = 0;\n");
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
    //               NOT comptime constants — so we can't `const`-alias them.
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
    //               shader body invokes at the top of main.  Replaces
    //               the hand-written `zm.location(&io.x, io._location_x)`
    //               and `zm.binding(&io.u, 0, io._binding_u)` calls
    //               that used to live in every shader body — the
    //               codegen knows every needed decoration already.
    //               `noinline` so spirv-opt keeps the call shape stable
    //               (decorations attach to the variables, not the call).
    //
    // The function is unconditionally emitted (no `@hasDecl` guards).
    // A schema with no Inputs/Outputs/Samplers/Ubo produces a
    // setup() with zero bodies — still callable, still no-op.  The
    // empty case matters for probe shaders and depth-only passes.
    try writer.writeAll(
        \\// ---- setup() ----------------------------------------------
        \\//
        \\// Install all the SPIR-V `OpDecorate` calls this shader needs.
        \\// Call once at the top of `main` BEFORE touching any of the
        \\// extern decls above.  Replaces the boilerplate that used to
        \\// open every shader body:
        \\//
        \\//     zm.location(&io.frag_tex_coord, io._location_frag_tex_coord);
        \\//     zm.location(&io.out_color, io._location_out_color);
        \\//     zm.binding(&io.u, 0, io._binding_u);
        \\//
        \\// `noinline` keeps spirv-opt from folding the call into main
        \\// — the asm decorations attach to the referenced variables,
        \\// not to the call site, so call elision is safe but the
        \\// stable function boundary helps when reading optimized SPIR-V.
        \\pub noinline fn setup() void {
        \\    @setRuntimeSafety(false);
        \\
    );

    // Vertex attributes → location.
    if (@hasDecl(IfaceMod, "Attributes")) {
        const info = @typeInfo(IfaceMod.Attributes).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "    zm_location(&{s}, _location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    // FS inputs → location.
    if (@hasDecl(IfaceMod, "Inputs")) {
        const info = @typeInfo(IfaceMod.Inputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "    zm_location(&{s}, _location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    // Stage outputs → location (frag_depth is a builtin: no location).
    if (@hasDecl(IfaceMod, "Outputs")) {
        const info = @typeInfo(IfaceMod.Outputs).@"struct";
        inline for (info.field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "frag_depth")) {
                continue;
            }
            try writer.print(
                "    zm_location(&{s}, _location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    // UBO → descriptor set + binding.
    if (@hasDecl(IfaceMod, "Ubo")) {
        // Stage-segregated, same scheme as loose Uniforms below: a VS
        // Ubo block lands in descriptor set 0, an FS Ubo block in set 2.
        // A two-stage pipeline that uses a Ubo block in BOTH stages then
        // never collides at (group,binding).  Stage is detected
        // structurally — a VS schema declares `Attributes`.
        // Group from the SINGLE SOURCE OF TRUTH shared with the runtime layout
        // solver (shader_introspect.solveLayout via the same function), so the
        // emitted @group can never drift from the host bind groups.
        const ubo_set: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        try writer.print("    zm_binding(&u, {d}, _binding_u);\n", .{ubo_set});
    }
    // Loose `Uniforms` → descriptor set + binding, SEGREGATED BY STAGE.
    //
    // The VS and FS are translated to WGSL as SEPARATE modules, each
    // numbering its uniforms from binding 0.  Without explicit
    // decorations they COLLIDE when linked into one pipeline — e.g.
    // lambert's VS `mat_model` and FS `col_diffuse` both land at
    // group(0)/binding(1), which WebGPU rejects (one resource per
    // (group,binding) across stages).  The GL path never hit this
    // (GL binds uniforms by name); WebGPU surfaced it.
    //
    // Fix: give each STAGE its own descriptor set so the two uniform
    // spaces are physically disjoint and can never collide, for any
    // shader.  Stage is detected structurally — a VS schema declares
    // `Attributes`, an FS schema declares `Inputs` (verified across
    // every engine shader).  Convention:
    //   - VS `Uniforms`  → set 0  (the vertex-stage uniform group)
    //   - samplers       → set 1  (already, via the Samplers solver)
    //   - FS `Uniforms`  → set 2  (the fragment-stage uniform group)
    // Bindings run 0,1,2,… within each set in declaration order, which
    // the host mirrors when building the per-group bind-group layout.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        const uniform_set: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        const uinfo = @typeInfo(IfaceMod.Uniforms).@"struct";
        var ubind: u32 = 0;
        inline for (uinfo.field_names) |field_name| {
            try writer.print(
                "    zm_binding(&{s}, {d}, {d});\n",
                .{ field_name, uniform_set, ubind },
            );
            ubind += 1;
        }
    }
    // Sampler descriptor set + binding.  Reads each sampler field's
    // `sampler_config` from its marker type (set by the user via the
    // DSL).  When no override is set, falls back to "lowest unclaimed
    // binding in group 1" — same algorithm as
    // `shader_introspect.solveLayout`, inlined here because the
    // codegen library has no host-side imports.  See
    // `src/notes/finishing_new_gpu_foundations.md` turn 1 §C.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const sinfo = @typeInfo(IfaceMod.Samplers).@"struct";
        // Pass 0: verify every field is a recognized sampler marker.
        // Without this, a typo like `texture0: Sample2D(.albedo, .{})`
        // (missing the `r`) would silently produce a non-marker type
        // with no `sampler_config` decl — and `@field` would
        // @compileError with an obscure message far from the user's
        // typo.  Catch it loudly here with the field name + offending
        // type spelled out.
        inline for (sinfo.field_names, sinfo.field_types) |field_name, field_type| {
            if (!@hasDecl(field_type, "sampler_config")) {
                @compileError(
                    "Schema's `Samplers` struct contains field `" ++ field_name ++
                        "` of type `" ++ @typeName(field_type) ++ "` which is not " ++
                        "a recognized sampler marker.  Use `shader.Sampler2D(.<tag>, " ++
                        "<config>)` or `shader.Sampler2D_atSlot(<slot>, <config>)`.  " ++
                        "Auxiliary types in `Samplers` are not supported — put them " ++
                        "in a separate decl if you need them in host code.",
                );
            }
        }
        // Pass 1: collect (group, binding) cells claimed by pinned/shared.
        // Emit a `zm_binding` decoration per sampler. The (group, binding)
        // assignment is delegated to the ONE shared authority in
        // shader_interface — the SAME function shader_introspect.solveLayout
        // (host bind-group layout) calls — so the emitted WGSL and the host
        // layout can never drift. Each Sampler2D is a texture at N + a paired
        // sampler at N+1 (zspv_rewrite synthesizes the sampler half).
        const slots = shader_iface.solveSamplerSlots(IfaceMod.Samplers);
        inline for (sinfo.field_names, 0..) |field_name, i| {
            try writer.print(
                "    zm_binding(&{s}_sampler2d, {d}, {d});\n",
                .{ field_name, slots[i].group, slots[i].binding },
            );
        }
    }
    try writer.writeAll("}\n\n");

    // ---- Sampler accessor methods --------------------------------
    // Per-sampler `pub fn <name>(uv: Vec2) Vec` that wraps the
    // `zsample2d` call.  Lets the shader body call `io.albedo(uv)`
    // directly instead of passing the placeholder sampler u32 to
    // `zm.zsample2d`.  Reads as "fetch from albedo at uv".  noinline
    // for the same reason as setup().
    if (@hasDecl(IfaceMod, "Samplers")) {
        const info = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                \\pub noinline fn {s}(uv: @Vector(2, f32)) @Vector(4, f32) {{
                \\    return zm_zsample2d({s}_sampler2d, uv);
                \\}}
                \\
                \\
            ,
                .{ field_name, field_name },
            );
            try writer.print(
                \\pub noinline fn {s}Level(uv: @Vector(2, f32), lod: f32) @Vector(4, f32) {{
                \\    return zm_zsample2d_level({s}_sampler2d, uv, lod);
                \\}}
                \\
                \\
            ,
                .{ field_name, field_name },
            );
        }
    }

    // ---- Close _Spirv namespace.  Everything above this point is
    //      SPIR-V-only: extern decls + setup() + top-level sampler
    //      accessors.  Below this point lives at module scope and
    //      must compile on both targets.
    try writer.writeAll("} else struct {};\n\n");

    // ---- Module-level Ubo type ----------------------------------
    // Pure struct type — target-independent.  Consumers do
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
    // The new API is emitted UNCONDITIONALLY — every shader that
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
    // false), installSpirvEntry is a no-op — the caller just runs
    // `main(io)` directly per pixel.

    // Emit `pub fn IoT(comptime UboType: type) type { return struct { ... } }`.
    //
    // KEY DESIGN: Io is a function-returning-a-type rather than a
    // direct struct.  This avoids io.zig needing to `@import("iface")`
    // — which would put the iface file in BOTH the 'iface' module
    // (as io's dep) AND the example's 'root' module (which often
    // imports iface relatively for `LoadedShader(iface)`).  Zig 0.16
    // forbids one file being claimed by two modules.
    //
    // The shader source closes the loop by instantiating:
    //   const iface_mod = @import("mandelbrot_fs_io.zig");
    //   pub const Io = io_mod.IoT(iface_mod.Ubo);
    // — relative imports of the iface from the shader source AND the
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
    // Loose Uniforms — engine-managed + custom scalars.  These are
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
        // No Ubo — UboType param is unused.  Emit a comptime discard
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
    // Sampler accessor methods — `pub fn texture0(self, uv) Vec`.
    // Body is target-conditional via `comptime` if so the unused
    // branch doesn't have to compile.  SPIR-V calls the extern sample
    // op; CPU does a nearest-neighbor lookup against `self._<name>`.
    //
    // No `_ = self;` in the SPIR-V branch — `self` IS used after the
    // if (in the CPU return), and Zig considers that a use regardless
    // of comptime-dead status, so an explicit discard trips the
    // "pointless discard of function parameter" check.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const info = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "        pub fn {s}(self: @This(), uv: @Vector(2, f32)) @Vector(4, f32) {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return zm_zsample2d(_Spirv.{s}_sampler2d, uv);\n" ++
                    "            }}\n" ++
                    "            return sampleTextureRgba8(self._{s}, uv);\n" ++
                    "        }}\n",
                .{ field_name, field_name, field_name },
            );
            // Explicit-LOD twin — legal in a VERTEX shader (no derivatives).
            // CPU path ignores `lod` and samples the base level.
            try writer.print(
                "        pub fn {s}Level(self: @This(), uv: @Vector(2, f32), lod: f32) @Vector(4, f32) {{\n" ++
                    "            if (comptime _builtin.target.cpu.arch.isSpirV()) {{\n" ++
                    "                return zm_zsample2d_level(_Spirv.{s}_sampler2d, uv, lod);\n" ++
                    "            }}\n" ++
                    "            return sampleTextureRgba8(self._{s}, uv);\n" ++
                    "        }}\n",
                .{ field_name, field_name, field_name },
            );
        }
    }
    // Storage-buffer accessor methods — `pub fn positions(self, i) Elem`.
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
    // Builtin accessor methods — `pub fn vertex_index(self) u32`.
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
    // For VS shaders (detected by `@hasDecl("Attributes")` — vertex
    // shaders consume vertex attributes, FS consume varying inputs),
    // automatically emit a `position: @Vector(4, f32)` field.  This
    // is the clip-space output position the rasterizer needs.
    //
    // On SPIR-V the codegen wires `out.position` → `position_out.*`
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
    // mention of the iface module — Io and Out are owned by the
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
    // OpDecorate calls for inputs.
    if (@hasDecl(IfaceMod, "Inputs")) {
        const info = @typeInfo(IfaceMod.Inputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "            zm_location(&_Spirv.{s}, _Spirv._location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Attributes")) {
        const info = @typeInfo(IfaceMod.Attributes).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "            zm_location(&_Spirv.{s}, _Spirv._location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    // OpDecorate calls for outputs (frag_depth is a builtin: no location).
    if (@hasDecl(IfaceMod, "Outputs")) {
        const info = @typeInfo(IfaceMod.Outputs).@"struct";
        inline for (info.field_names) |field_name| {
            if (comptime std.mem.eql(u8, field_name, "frag_depth")) {
                continue;
            }
            try writer.print(
                "            zm_location(&_Spirv.{s}, _Spirv._location_{s});\n",
                .{ field_name, field_name },
            );
        }
    }
    // OpDecorate calls for the Ubo block, SEGREGATED BY STAGE exactly
    // like the loose Uniforms below (VS Ubo → set 0, FS Ubo → set 2;
    // samplers own set 1).  This is the path installSpirvEntry actually
    // emits, so the descriptor set MUST be decided here to reach the
    // SPIR-V — setup() is the legacy hand-call API.
    if (@hasDecl(IfaceMod, "Ubo")) {
        // Group via the SINGLE SOURCE OF TRUTH (honors a schema's `ubo_group`
        // override, e.g. the decal FS pinning its projector UBO to group 1) so
        // this — the path installSpirvEntry actually emits — can never drift
        // from setup()/solveLayout.
        const ubo_set_e: u32 = shader_iface.uniformGroupForSchema(IfaceMod);
        try writer.print("            zm_binding(&_Spirv.u, {d}, _Spirv._binding_u);\n", .{ubo_set_e});
    }
    // OpDecorate calls for loose `Uniforms`, SEGREGATED BY STAGE so the
    // VS and FS uniform spaces never collide when linked into one
    // WebGPU pipeline.  VS schemas declare `Attributes`, FS schemas
    // declare `Inputs`; VS uniforms → set 0, FS uniforms → set 2
    // (samplers own set 1).  See the matching block in setup() for the
    // full rationale — this is the path `installSpirvEntry` actually
    // emits (setup() is the legacy hand-call API), so the decoration
    // MUST be here to reach the SPIR-V.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        const is_vs_e: bool = @hasDecl(IfaceMod, "Attributes");
        const uniform_set_e: u32 = if (is_vs_e) 0 else 2;
        const uinfo_e = @typeInfo(IfaceMod.Uniforms).@"struct";
        comptime var ubind_e: u32 = 0;
        inline for (uinfo_e.field_names) |field_name| {
            try writer.print(
                "            zm_binding(&_Spirv.{s}, {d}, {d});\n",
                .{ field_name, uniform_set_e, ubind_e },
            );
            ubind_e += 1;
        }
    }
    // OpDecorate calls for samplers.
    //
    // Reads each sampler field's `sampler_config` from its marker
    // type.  Pinned/shared use override; free fields take the
    // lowest unclaimed slot in group 1 (same algorithm as
    // `shader_introspect.solveLayout`).  See
    // `src/notes/finishing_new_gpu_foundations.md` turn 1.
    //
    // The same field-type check from setup()'s emission also runs
    // here — defensive duplication so a refactor that breaks the
    // setup() path still catches malformed Samplers schemas.
    if (@hasDecl(IfaceMod, "Samplers")) {
        const sinfo = @typeInfo(IfaceMod.Samplers).@"struct";
        inline for (sinfo.field_names, sinfo.field_types) |field_name, field_type| {
            if (!@hasDecl(field_type, "sampler_config")) {
                @compileError(
                    "Schema's `Samplers` struct contains field `" ++ field_name ++
                        "` of type `" ++ @typeName(field_type) ++ "` which is not " ++
                        "a recognized sampler marker.  Use `shader.Sampler2D(.<tag>, " ++
                        "<config>)` or `shader.Sampler2D_atSlot(<slot>, <config>)`.",
                );
            }
        }
        // Same shared authority as the module-level branch and
        // shader_introspect.solveLayout — one solver, zero drift.
        const slots_e = shader_iface.solveSamplerSlots(IfaceMod.Samplers);
        inline for (sinfo.field_names, 0..) |field_name, i| {
            try writer.print(
                "            zm_binding(&_Spirv.{s}_sampler2d, {d}, {d});\n",
                .{ field_name, slots_e[i].group, slots_e[i].binding },
            );
        }
    }
    // Build the Io struct from externs.
    try writer.writeAll("            const io: _IoT = .{\n");
    if (@hasDecl(IfaceMod, "Inputs")) {
        const info = @typeInfo(IfaceMod.Inputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv.{s},\n",
                .{ field_name, field_name },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Attributes")) {
        const info = @typeInfo(IfaceMod.Attributes).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv.{s},\n",
                .{ field_name, field_name },
            );
        }
    }
    // Loose Uniforms: each becomes an Io field.  Read from the
    // module-level extern decls (declared above in the legacy
    // section).  The Uniforms field type may include defaults (e.g.
    // `col_diffuse: Vec = .{1,1,1,1}`); the read is just `= name`.
    if (@hasDecl(IfaceMod, "Uniforms")) {
        const info = @typeInfo(IfaceMod.Uniforms).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "                .{s} = _Spirv.{s},\n",
                .{ field_name, field_name },
            );
        }
    }
    if (@hasDecl(IfaceMod, "Ubo")) {
        // Construct the Ubo field-by-field rather than `.u = u`.  The
        // io-side `u: Ubo` extern is io's own duplicate Ubo type;
        // body's _IoT.u expects the iface's Ubo type (passed in to
        // IoT).  Those two extern structs are layout-identical but
        // nominally distinct — Zig rejects whole-struct assignment.
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
    // Storage bindings: same as samplers — SPIR-V field type is `void`,
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
    // AND this is not a VS (no Attributes → no auto-emitted
    // `position` field), discard `out` to silence the unused-local
    // check.
    const has_outputs = @hasDecl(IfaceMod, "Outputs") and
        @typeInfo(IfaceMod.Outputs).@"struct".field_names.len > 0;
    const is_vs = @hasDecl(IfaceMod, "Attributes");
    if (has_outputs) {
        const info = @typeInfo(IfaceMod.Outputs).@"struct";
        inline for (info.field_names) |field_name| {
            try writer.print(
                "            _Spirv.{s} = out.{s};\n",
                .{ field_name, field_name },
            );
        }
    }
    // For VS shaders, wire out.position → std.gpu's position_out.*
    // (the special-cased clip-space output the SPIR-V backend
    // recognizes).  This decoupling — VS source writes a regular
    // struct field, codegen handles the SPIR-V binding — keeps the
    // shader body free of the `position_out.* = ...` magic and lets
    // the same field flow naturally to the CPU rasterizer.
    //
    // `position_out` has type `*addrspace(.output) @Vector(4, f32)`
    // (see `std/gpu.zig`).  Address-space-typed pointers don't cast
    // to plain pointers, so we just use the std.gpu decl directly
    // — no intermediate local variable needed.  Access via _Spirv
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

    // The installSpirvEntry body references `_builtin` — we add the
    // import below alongside the shadermath forwarding decls.

    // ---- Forwarding decls to keep the generated file dep-free ----
    // The setup() body and sampler accessors reference `zm_location`,
    // `zm_binding`, `zm_zsample2d` — we forward those to `zm` (the
    // unified math module) via @import inline.  `_builtin` is now
    // declared in the prologue (so `_is_spirv` can reference it for
    // the `_Spirv` wrap), but `zm_*` forwarding still lives at the
    // bottom so the file's top reads as a "what's in here" inventory.
    //
    // Stage 5 of math-unification: changed from `shadermath` to `zm`.
    // math.zig absorbed the SPIR-V decorators (`location`, `binding`,
    // `zsample2d`) so shaders need only one import.
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
            \\const zm_location = zm_mod.location;
            \\const zm_binding = zm_mod.binding;
            \\const zm_zsample2d = zm_mod.zsample2d;
            \\const zm_zsample2d_level = zm_mod.zsample2d_level;
            \\const zm_ssboLoad = zm_mod.ssboLoad;
            \\
        );
    }
}

// ---- Unit tests
// These verify the emit logic against fixture ifaces inline.  Run
// via `zig build test`.  Real round-trip verification (generated
// extern file → spirv compile → identical GLSL) belongs in the main
// build's smoke pass once the build.zig wiring lands.

const ElemKindForTest = enum { vec2, vec3, vec4, ivec4, uvec4 };

/// Test-only Attr stub.  Mirrors `shader_interface.Attr(elem, loc)`'s
/// public shape (`element`, `location`) without depending on the real
/// type — so this test file is self-contained.
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

    try t.expect(std.mem.indexOf(u8, out, "pub extern const pos: @Vector(3, f32) addrspace(.input)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const _location_pos: u32 = 0") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub extern const uv: @Vector(2, f32) addrspace(.input)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const _location_uv: u32 = 1") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub extern var frag_uv: @Vector(2, f32) addrspace(.output)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const _location_frag_uv: u32 = 0") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub extern const mvp: [4]@Vector(4, f32) addrspace(.constant)") != null);
    // No .input on a uniform.
    try t.expect(std.mem.indexOf(u8, out, "mvp: [4]@Vector(4, f32) addrspace(.input)") == null);
}

/// Test-only Sampler2D stub.  Mirrors `shader_interface.Sampler2D(.X)`'s
/// public shape (`slot`) without depending on the real type.
const FakeSampler = struct {
    pub const slot: u32 = 0;
};

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
            albedo: FakeSampler,
            normal_map: FakeSampler,
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

    // Inputs: sequential locations.
    try t.expect(std.mem.indexOf(u8, out, "pub extern const frag_uv: @Vector(2, f32) addrspace(.input)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const _location_frag_uv: u32 = 0") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub extern const frag_normal: @Vector(3, f32) addrspace(.input)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub const _location_frag_normal: u32 = 1") != null);
    // Samplers: `_sampler2d` suffix, u32, .constant.
    try t.expect(std.mem.indexOf(u8, out, "pub extern const albedo_sampler2d: u32 addrspace(.constant)") != null);
    try t.expect(std.mem.indexOf(u8, out, "pub extern const normal_map_sampler2d: u32 addrspace(.constant)") != null);
    // Uniforms.
    try t.expect(std.mem.indexOf(u8, out, "pub extern const col: @Vector(4, f32) addrspace(.constant)") != null);
    // Outputs: extern VAR (writeable), not const.
    try t.expect(std.mem.indexOf(u8, out, "pub extern var out_color: @Vector(4, f32) addrspace(.output)") != null);
    // No Attributes block emitted (FS has no @hasDecl(_, "Attributes")).
    try t.expect(std.mem.indexOf(u8, out, "// Vertex attributes") == null);
}

test "emit rejects unsupported types with a clear compileError" {
    // Compile-time-only check — exercising this requires `@compileError`,
    // which we can't test at runtime.  Documented here as an
    // intentional invariant: `zigTypeForType(f64)` etc. fail the
    // build with a message naming the offending type.
    // The acceptance test is: try to use `f64` in a schema and confirm
    // the build fails with the expected message.
}
