//! lint:alias shader_codegen
//! src/shader_codegen.zig - public build-time API for zimr.
//!
//! This module is the API surface Phase 3 of the typed-shader plan
//! (`src/notes/typesafe_zig_shaders.md`) exposes to downstream
//! projects.  Two kinds of consumer:
//!
//!   1. zimr's own `build.zig` - imports this file as a relative
//!      `@import("src/shader_codegen.zig")`.  Internal use; the path
//!      defaults all resolve correctly because the build root IS
//!      zimr's root.
//!
//!   2. External projects depending on zimr via `build.zig.zon` -
//!      add zimr as a build dep, then in their own build.zig do
//!      `const zimr_build = @import("zimr_build");`.  Zig's build
//!      runner resolves the named module through `b.addModule(...)`
//!      in zimr's build.zig.  The consumer's call to
//!      `ShaderPipeline.init(b, zimr_dep, shader_interface_mod)`
//!      hands the pipeline a `*std.Build.Dependency` so it can find
//!      the prebuilt SPIR-V / zspv / zglsl tool binaries inside the
//!      zimr dep's vendored paths.
//!
//! Current limitations (Phase 3a, this session):
//!   - Only Linux x86_64 is supported for external consumers.  The
//!     SPIR-V tools (spirv-opt / spirv-val / spirv-cross) and the
//!     zspv / zglsl text rewriters are built by zimr's own
//!     `tools/build.zig` subbuild from the zimr-vendored sources;
//!     consumers' builds depend transitively on the subbuild.
//!   - Cross-platform vendored prebuilts (Phase 3b) need to land
//!     before consumers on macOS / Windows can use this.
//!
//! See the file-level docstring of `tools/gen_shader_externs.zig`
//! for how the bootstrap-per-shader Phase 2 codegen weaves into
//! every `ShaderPipeline.addShader` call.

const std = @import("std");

// Local aliases for the std.Build types this file works with so the
// type annotations at every `const x: T = b.addX(...)` site stay
// short.  Without these, rule 2 (untyped-local) on every build-helper
// line would push the type names ~40 chars right of where they
// belong and double the line wrap rate.
const Build = std.Build;
const Module = std.Build.Module;
const Run = std.Build.Step.Run;
const Compile = std.Build.Step.Compile;
const WriteFile = std.Build.Step.WriteFile;
const LazyPath = std.Build.LazyPath;

// ============================================================================
// Zig-shader pipeline helpers (S1.2 of the Zig-shader-pipeline arc).
// ============================================================================
// Author shaders as `_fs.zig` / `_vs.zig`, compile them through
// SPIR-V to GLSL ES 3.0, and expose the result as an anonymous
// import for `@embedFile` at the call site.
//
//   examples/foo_fs.zig
//       |  zig build-obj -target spirv32-vulkan ...
//       v
//   foo.fs.spv
//       |  spirv-opt -O --skip-validation
//       v
//   foo.fs.opt.spv
//       |  spirv-val   (build-time safety net)
//       |
//       |  spirv-cross --version 300 --es
//       v
//   foo_fs.glsl
//
// Usage from inside `pub fn build`:
//
//     // hoisted ShaderPipeline (one per build, shared by all addShader calls)
//     var sp = ShaderPipeline.init(b, &tools_subbuild.step);
//
//     // simple form: returns LazyPath to the generated .glsl
//     const glsl_path = sp.addShader(b.path("examples/foo_fs.zig"));
//
//     // common form: compiles + wires as @embedFile-able import
//     sp.addShaderImport(exe_mod, b.path("examples/foo_fs.zig"), "foo_fs.glsl");
//
// And then in your example source:
//
//     const fs = @embedFile("foo_fs.glsl");
//
// See `src/notes/zig-shader-tutorial.md` for usage examples and
// the locked design decisions; `src/notes/zig-shader-pipeline-plan.md`
// for the multi-step rollout plan.

/// Pipeline context.  Stores the shared subbuild dependency and the
/// known paths to the three vendored tool binaries (built once by
/// `tools/build.zig`).  Construct once at the top of `pub fn build`,
/// pass around to every `addShader` / `addShaderImport` call.
pub const ShaderPipeline = struct {
    b: *std.Build,
    tools_dep: ?*std.Build.Step = null,
    /// `zspv` - SPIR-V binary rewriter.  Operates on the raw .spv
    /// from `zig build-obj`: replaces placeholder sampler uniforms
    /// with real OpTypeSampledImage, replaces `zsample2d` calls
    /// with OpImageSampleImplicitLod, strips the helper definition.
    /// See `tools/zspv.zig` and `tools/zspv_rewrite.zig`.  Always
    /// runs in the pipeline - it's a no-op for shaders without
    /// samplers (discovery returns empty).
    zspv_path: []const u8 = "tools/zig-out/bin/zspv",
    /// `spv2wgsl` - pure-Zig SPIR-V -> WGSL translator.  Operates on
    /// the post-spirv-opt `shader.opt.spv`: emits a WGSL artifact
    /// parallel to spirv-cross's GLSL.  Foundation of the wgpu
    /// migration's Rule 2 (no Naga / Tint in the shipped wasm; our
    /// own Zig translates SPIR-V at build time).  See `tools/spv2wgsl.zig`
    /// for the CLI wrapper, `src/spv2wgsl.zig` for the library,
    /// `src/notes/webgpu-migration-plan.md` for the migration plan.
    /// Only invoked when `addShaderWgsl` is called (or when
    /// `addShader` is called with `opts.emit_wgsl = true`).
    spv2wgsl_path: []const u8 = "tools/zig-out/bin/spv2wgsl",
    /// Which CFG walker `spv2wgsl` uses to reconstruct control flow:
    /// "ir" (the structured-IR path, `ir_build.zig` -> `ir_emit.zig`,
    /// with per-function fallback to legacy on unsupported shapes) or
    /// "legacy" (the original recursive walker).  Passed through as the
    /// CLI's leading `--walker=` flag.  Default "ir" - the IR path is
    /// proven on the whole corpus + in-browser (cardioid renders) and is
    /// naga-clean on the typed-harness shaders.  Set from the `-Dwalker=`
    /// build option; `-Dwalker=legacy` is the escape hatch (F5 deletes
    /// the legacy walker).
    wgsl_walker: []const u8 = "ir",
    /// Pure-Zig tool ARTIFACTS, built by the MAIN build (not the
    /// nested `tools/build.zig`).  When set, the pipeline invokes the
    /// tool via `addArtifactArg` instead of the `*_path` string, which
    /// makes the tool a real dependency edge in the build graph: edit
    /// the tool's source -> it rebuilds -> its emitted-binary hash
    /// changes -> every downstream shader Run re-fires automatically.
    /// This closes the stale-WGSL hole that the nested-build +
    /// `addFileInput(path)` approach left open (a nested `zig build`
    /// is a cache boundary the outer build can't see across, so the
    /// path could be hashed before the sub-build rewrote it).  Null ->
    /// fall back to the `*_path` + tools_dep behavior (the C++ SPIR-V
    /// tools always use that; they're genuinely external).
    spv2wgsl_exe: ?*std.Build.Step.Compile = null,
    zspv_exe: ?*std.Build.Step.Compile = null,
    /// `shader_interface` named module - wired into per-shader IO
    /// modules so IO files' `@import("shader_interface")` resolves.
    /// Only used by `addShader` when `opts.shader_io != null` (typed-
    /// shader codegen).
    shader_interface_mod: *std.Build.Module,

    /// `math` named module - the unified math.zig library.  Wired
    /// into the shader compile so shader bodies can `@import("zm")`
    /// and use the full Mat/Vec/Quat algebra (mulMat, mulMatVec,
    /// mulMatPoint, quatToMat, ...) and the GLSL-style helpers
    /// (vec2/vec3/vec4, clamp01, mix, fract, smoothstep, dot,
    /// length, normalize, sw) directly.  Stage 5 of math-unification
    /// migrated all shaders from the (now-deleted) `shadermath`
    /// module to `math`; Stage 10 deleted shadermath outright.
    zimrmath_mod: *std.Build.Module,

    pub fn init(
        b: *std.Build,
        tools_dep: ?*std.Build.Step,
        shader_interface_mod: *std.Build.Module,
        zimrmath_mod: *std.Build.Module,
    ) ShaderPipeline {
        return .{
            .b = b,
            .tools_dep = tools_dep,
            .shader_interface_mod = shader_interface_mod,
            .zimrmath_mod = zimrmath_mod,
        };
    }

    /// Options controlling how `addShader` runs the pipeline stages.
    ///
    /// * `shader_io` - when provided, the typed-shader codegen runs
    ///   before the SPIR-V compile: a bootstrap exe (built per shader)
    ///   reads the shader_io's schema via comptime reflection and
    ///   emits a matching `<basename>_externs.zig` file.  The shader
    ///   body then `@import`s the generated externs.  Pass the
    ///   shader_io file's `LazyPath` (typically
    ///   `b.path("path/to/foo_fs_io.zig")`).
    /// * `shader_basename` - names the codegen-emitted externs module
    ///   so multiple shaders in one wasm don't collide.  The shader
    ///   source must `@import("<basename>_externs")` to match.
    pub const ShaderOpts = struct {
        shader_io: ?std.Build.LazyPath = null,
        /// File basename (no extension) used to name the codegen-
        /// emitted externs module.  When supplied, the externs module
        /// is named `<basename>_externs` rather than the default
        /// `shader_externs`; this lets multiple shaders in the same
        /// consumer wasm coexist without colliding on a single
        /// symbol.  The shader source must use the matching
        /// `@import("<basename>_externs")`.
        shader_basename: ?[]const u8 = null,
        /// When true, also produce a `.wgsl` artifact via spv2wgsl
        /// alongside the `.glsl` artifact.  Used by the wgpu migration
        /// - engine shaders and any consumer that wants WebGPU support
        /// opts in.  Default off so the GLSL-only path costs nothing
        /// extra during the side-by-side transition.  See
        /// `src/notes/webgpu-migration-plan.md` section 3 Phase B.
        emit_wgsl: bool = false,
        /// When `emit_wgsl` is on, run spv2wgsl in --strict mode.  Any
        /// `// ERROR:` marker in the WGSL output (e.g. combined-sampler
        /// shaders that WGSL can't express) fails the build.  Engine
        /// shaders should always pass --strict; example shaders may
        /// opt out during exploration.
        wgsl_strict: bool = true,
    };

    /// Run all pipeline stages on `source` and return the LazyPath of
    /// the generated `.glsl`.  Caller decides what to do with the
    /// result (typically `addShaderImport` wires it into an
    /// executable's import table; see below).
    ///
    /// The pipeline:
    ///   0. (optional, when `opts.shader_io != null`) Bootstrap codegen
    ///      exe -> `<basename>_extern.zig`.  Passed to the spirv
    ///      compile as `-Mio=...`; shader body `@import("io")`s it.
    ///   1. `zig build-obj` -> raw SPIR-V (with `zsample2d` helper if
    ///      the shader uses samplers, with `Target_Cpu` dead-struct
    ///      regardless).
    ///   2. `zspv --rewrite-samplers` -> SPIR-V binary surgery:
    ///      placeholder `_sampler2d` uniforms become real
    ///      OpTypeSampledImage; `OpFunctionCall %zsample2d` becomes
    ///      `OpImageSampleImplicitLod`; the helper function body is
    ///      stripped.  No-op for shaders without samplers.
    ///   3. `spirv-opt -O --remove-duplicates --trim-capabilities
    ///      --skip-validation` -> full optimization.  --skip-validation
    ///      because Target_Cpu lingers until later passes strip it.
    ///      --remove-duplicates dedupes the OpTypeFloat that zspv
    ///      always allocates fresh.  --trim-capabilities drops
    ///      capability declarations that became unused.
    ///   4. `spirv-val` -> safety net.  Catches malformed shaders
    ///      before they hit WebGL.
    ///   5. `spirv-cross --version 300 --es` -> GLSL ES 3.0.
    ///   6. `zglsl` -> textual GLSL cleanups: rewrite `uniform vec4
    ///      NAME[4];` to `uniform mat4 NAME;` (Zig has no @Matrix
    ///      builtin); strip the GL_EXT_int8 extension block + rewrite
    ///      `uint8_t` -> `uint` (Zig represents bool as u8 in SPIR-V).
    ///
    /// Every stage's output is inspectable in `.zig-cache/o/<hash>/`.
    /// Result of `addShaderEx` - both the final GLSL (for `@embedFile`)
    /// AND the generated `io.zig` module path (for CPU-side imports).
    ///
    /// The GPU pipeline uses `glsl` only.  The CPU dispatcher pattern
    /// (see `src/notes/software_shaders.md`) uses BOTH:
    ///   - `glsl` to feed the GPU half.
    ///   - `io` to feed the CPU half - the importing module wires it
    ///     as `--dep io` so the shader source's `@import("io")` works
    ///     on the CPU target too.
    ///
    /// Result of `addShaderEx` - both the final GLSL (for `@embedFile`)
    /// AND the generated externs module path (for CPU-side imports).
    ///
    /// The GPU pipeline uses `glsl` only.  The CPU dispatcher pattern
    /// (see `src/notes/software_shaders.md`) uses BOTH:
    ///   - `glsl` to feed the GPU half.
    ///   - `externs` to feed the CPU half - the importing module
    ///     wires it as `--dep <basename>_externs` so the shader
    ///     source's `@import("<basename>_externs")` works on the
    ///     CPU target too.
    ///
    /// `externs` is null when no shader_io was provided (the pre-
    /// typed-shader path; no codegen ran).
    pub const ShaderOutput = struct {
        externs: ?std.Build.LazyPath,
        /// Pre-translated WGSL.  Present when `opts.emit_wgsl == true`,
        /// null otherwise.  Consumers `@embedFile` this to bake the
        /// WGSL into the wasm for the wgpu backend.  See
        /// `src/notes/webgpu-migration-plan.md` section 3 Phase B.
        wgsl: ?std.Build.LazyPath = null,
    };

    /// Same as `addShader` but returns the codegen-generated `io.zig`
    /// path alongside the GLSL.  Use this when an example wants to
    /// import the shader source directly (`@import("foo_fs.zig")`)
    /// and call `shader.shaderMain(io)` on the CPU - that import
    /// transitively does `@import("io")`, so the example's exe_mod
    /// needs the same io.zig wired as a dep.
    ///
    /// Implemented as a thin wrapper to keep `addShader`'s contract
    /// (returns `LazyPath`) backward-compatible for the many call
    /// sites that only need the GLSL.
    pub fn addShaderEx(
        self: *const ShaderPipeline,
        source: std.Build.LazyPath,
        opts: ShaderOpts,
    ) ShaderOutput {
        return self.addShaderInternal(source, opts);
    }

    /// Convenience shortcut for the wgpu path: compile + translate to
    /// WGSL, return only the `.wgsl` path.  Equivalent to calling
    /// `addShaderEx` with `opts.emit_wgsl = true` and reading `.wgsl`
    /// off the result.  Always opts in to strict mode (no
    /// `// ERROR:` markers tolerated); flip `opts.wgsl_strict = false`
    /// on the caller side if exploring.
    ///
    /// See `src/notes/webgpu-migration-plan.md` section 3 Phase B for context.
    pub fn addShaderWgsl(
        self: *const ShaderPipeline,
        source: std.Build.LazyPath,
        opts: ShaderOpts,
    ) std.Build.LazyPath {
        var wgsl_opts: ShaderOpts = opts;
        wgsl_opts.emit_wgsl = true;
        const out: ShaderOutput = self.addShaderInternal(source, wgsl_opts);
        return out.wgsl orelse unreachable; // we set emit_wgsl just above
    }

    fn addShaderInternal(
        self: *const ShaderPipeline,
        source: std.Build.LazyPath,
        opts: ShaderOpts,
    ) ShaderOutput {
        const b: *Build = self.b;
        // The externs module is named after the shader file basename
        // so multiple shaders in the same consumer wasm don't collide.
        // E.g. for `cube_split_vs.zig` the module is
        // `cube_split_vs_externs`; the shader source does
        // `const shader_externs = @import("cube_split_vs_externs");`.
        // When no name is supplied via opts.shader_basename, fall
        // back to `shader_externs`.
        const externs_module_name: []const u8 = if (opts.shader_basename) |bn|
            b.fmt("{s}_externs", .{bn})
        else
            "shader_externs";

        // ---- Stage 0 (optional): typed-shader codegen.
        // When the caller passes `opts.shader_io`, build a tiny host
        // bootstrap exe that imports BOTH the shader_io module and
        // the gen library, calls `gen.emit(shader_io, writer)` at
        // runtime, and writes the resulting `*_externs.zig` to a
        // captured output path.  Each shader gets its own bootstrap
        // exe with only its own shader_io wired - so each exe's
        // module tree contains only ONE shader_io, sidestepping
        // Zig's "file in two modules" rule.
        //
        // External users of zimr hit this exact same path from their
        // own build.zig: `pipeline.addShader(body, .{ .shader_io = ... })`
        // is the public API.
        const externs_module: ?std.Build.LazyPath = if (opts.shader_io) |shader_io_path| blk: {
            // The bootstrap source is the same for every shader; only
            // the shader_io module wired in differs.  Stored once as
            // a generated source file in the build cache via addWriteFiles.
            const bootstrap_wf: *WriteFile = b.addWriteFiles();
            const bootstrap_path: LazyPath = bootstrap_wf.add("gen_externs_bootstrap.zig",
                \\const std = @import("std");
                \\const shader_io = @import("shader_io");
                \\const gen = @import("gen");
                \\
                \\pub fn main(init: std.process.Init) !void {
                \\    const gpa = init.gpa;
                \\    const io = init.io;
                \\
                \\    var args_list: std.ArrayList([]u8) = .empty;
                \\    defer {
                \\        for (args_list.items) |a| gpa.free(a);
                \\        args_list.deinit(gpa);
                \\    }
                \\    var arg_it: std.process.Args.Iterator =
                \\        try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
                \\    defer arg_it.deinit();
                \\    while (arg_it.next()) |arg| {
                \\        try args_list.append(gpa, try gpa.dupe(u8, arg));
                \\    }
                \\    if (args_list.items.len < 2) {
                \\        std.debug.print("usage: <output_path>\n", .{});
                \\        std.process.exit(2);
                \\    }
                \\    const out_path = args_list.items[1];
                \\
                \\    var aw: std.Io.Writer.Allocating = .init(gpa);
                \\    defer aw.deinit();
                \\    try gen.emit(shader_io, &aw.writer);
                \\
                \\    try std.Io.Dir.cwd().writeFile(io, .{
                \\        .sub_path = out_path,
                \\        .data = aw.written(),
                \\    });
                \\}
                \\
            );

            // Per-shader shader_io module - single shader_io in its
            // tree, no shared-file conflicts with sibling shaders.
            // Needs `shader_interface` for schema helpers (Sampler2D,
            // Attr, ...) and `zm` for type aliases (Vec2, Vec3, Vec,
            // Complex, ...) so shader_io files can read naturally.
            // Both unused-imports are elided by Zig, so shader_io
            // files that don't reference them pay zero cost.
            const shader_io_mod: *Module = b.createModule(.{
                .root_source_file = shader_io_path,
                .target = b.graph.host,
            });
            shader_io_mod.addImport("shader_interface", self.shader_interface_mod);
            shader_io_mod.addImport("zm", self.zimrmath_mod);

            // Shared gen library module.
            const gen_mod: *Module = b.createModule(.{
                .root_source_file = b.path("tools/gen_shader_externs.zig"),
                .target = b.graph.host,
            });
            // The codegen shares the binding-group RULE with the runtime layout
            // solver via shader_interface (uniformGroupForSchema / sampler_group),
            // so the emitted WGSL @group decorations can never drift from the
            // host bind groups. shader_interface is dependency-free (std only).
            gen_mod.addImport("shader_interface", self.shader_interface_mod);

            const bootstrap_exe: *Compile = b.addExecutable(.{
                .name = "gen_externs",
                .root_module = b.createModule(.{
                    .root_source_file = bootstrap_path,
                    .target = b.graph.host,
                    // Debug + strip, NOT Release*: this exe is compiled ONCE PER
                    // SHADER (~45 of them) and each one RUNS FOR 1ms. Release*
                    // routes through LLVM and spends ~17s optimizing std per
                    // shader -> ~13 MINUTES of a cold build, to make a 1ms
                    // program 0ms faster. Debug uses the self-hosted x86 backend:
                    // 0.46s per shader (38x faster), a SMALLER binary once
                    // stripped (3.2 MB vs 3.8), byte-identical generated externs,
                    // and strictly stronger safety checks. Match the optimize
                    // mode to the tool's real runtime, not to a blanket policy.
                    .optimize = .Debug,
                    .strip = true,
                }),
            });
            bootstrap_exe.root_module.addImport("shader_io", shader_io_mod);
            bootstrap_exe.root_module.addImport("gen", gen_mod);

            const gen_run: *Run = b.addRunArtifact(bootstrap_exe);
            const externs_path: LazyPath = gen_run.addOutputFileArg("externs.zig");
            break :blk externs_path;
        } else null;

        // ---- Stage 1: `zig build-obj -target spirv32-vulkan ...`
        // The shader source `@import("shadermath")`s - we provide
        // it via `--dep shadermath` + `-Mshadermath=src/shadermath.zig`.
        // `-fno-llvm -fno-lld` is mandatory: LLVM segfaults on the
        // spirv target.  `-O ReleaseFast` strips runtime safety
        // checks that don't translate to GLSL.
        const compile: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-obj",
            "-target",
            "spirv32-vulkan",
            "-mcpu",
            "vulkan_v1_2",
            "-fno-llvm",
            "-fno-lld",
            "-O",
            "ReleaseFast",
            "-ofmt=spirv",
        });
        const raw_spv: LazyPath = compile.addPrefixedOutputFileArg("-femit-bin=", "shader.spv");
        // `zm` - the unified math module (math.zig, SPIR-V-portable
        // as of Stage 3 of math-unification).  Every shader does
        // `@import("zm")` for Vec/Mat/Quat algebra AND for the
        // SPIR-V decorators (`location`, `binding`, `zsample2d`)
        // which were moved into math.zig at the end of Stage 5.
        // No more `--dep shadermath` needed - math.zig is the single
        // import for everything shader-side.
        compile.addArg("--dep");
        compile.addArg("zm");
        // Shader intrinsics (decorators, texture/sampler types, sampling +
        // storage) live in `shader_builtins`, split out of zm so host edits to
        // them don't rebuild everything. The shader body and the generated
        // externs both `@import("shader_builtins")`.
        compile.addArg("--dep");
        compile.addArg("shader_builtins");
        // Codegen-produced externs module: shader body sees it as
        // `@import("<externs_module_name>")` - by default
        // `shader_externs`, but shader_basename-bearing callers use
        // `<basename>_externs` so multiple shaders coexist in one
        // wasm.  When codegen emits a `setup()` function or sampler
        // accessor methods, the generated file itself
        // `@import("zm")` to call `zm.location` / `zm.binding` /
        // `zm.zsample2d` - so externs needs zm as ITS dep too (added
        // below in the externs-dep block).
        if (externs_module) |_| {
            compile.addArg("--dep");
            compile.addArg(externs_module_name);
        }
        compile.addPrefixedFileArg("-Mroot=", source);
        compile.addPrefixedFileArg("-Mzm=", b.path("src/zimrmath.zig"));
        // Declare the shader_builtins module (it `@import("zm")` for Vec/Vec2).
        compile.addArg("--dep");
        compile.addArg("zm");
        compile.addPrefixedFileArg("-Mshader_builtins=", b.path("src/shader_builtins.zig"));
        if (externs_module) |path| {
            // externs' own dep table - must precede the `-M<name>=`
            // that closes the module declaration (per `zig build-exe`'s
            // `--dep`/`-M` interaction).
            //
            // `zm` - codegen emits `zm_location` / `zm_binding` /
            // `zm_zsample2d` calls in setup() and sampler accessors,
            // forwarded from `@import("zm")` (Stage 5 of math-
            // unification moved the decorators from shadermath into
            // math.zig - externs.zig no longer needs shadermath as a dep).
            //
            // No shader_io dep - externs.zig is deliberately
            // shader_io-free (see `tools/gen_shader_externs.zig` for
            // the rationale: avoids file-in-two-modules conflicts
            // when consumers also import the shader_io relatively).
            compile.addArg("--dep");
            compile.addArg("zm");
            // externs also `@import("shader_builtins")` for the sampling /
            // storage / decorator intrinsics it forwards.
            compile.addArg("--dep");
            compile.addArg("shader_builtins");
            compile.addPrefixedFileArg(
                b.fmt("-M{s}=", .{externs_module_name}),
                path,
            );
        }

        // ---- Stage 2: spirv-opt.  Two recipes depending on opts.
        // Standard path: `spirv-opt -O --skip-validation`.  The `-O`
        // recipe strips the Zig stdlib's dead `Target_Cpu` struct
        // (which would otherwise force GL_EXT_shader_explicit_arithmetic_types_int8
        // into the GLSL output - WebGL2 doesn't support that ext).
        // --skip-validation is required because Target_Cpu lingers
        // until -O's later passes strip it.
        //
        // Sampler path (opts.has_samplers = true): same dead-strip
        // goals but WITHOUT `--inline-entry-points-exhaustive`,
        // which would eat the `noinline` __sample2d helper.  Manual
        // pass list excludes inlining.  Don't add --strip-debug -
        // the post-process needs identifier names to match against.
        // Stage 2a (only for sampler shaders): `zspv --rewrite-samplers`.
        // The S1.4.5b-followup tool we built in `tools/zspv.zig`.
        // Operates on the SPIR-V binary directly to replace placeholder
        // `uniform uint X_sampler2d` variables with real
        // `OpTypeSampledImage` samplers, replace `OpFunctionCall` to
        // the `zsample2d` helper with `OpImageSampleImplicitLod`, and
        // strip the helper function definition.  After this, the
        // SPIR-V has no `zsample2d` left to preserve, so we can run
        // full `spirv-opt -O` (with inlining) - which produces ~34%
        // smaller SPIR-V than the previous limited-pass-list approach.
        //
        // Non-sampler shaders skip this stage; they go straight from
        // the raw .spv to spirv-opt.
        // Stage 2a: `zspv --rewrite-samplers` (S1.4.5b followup) or
        // `zspv --rewrite-samplers-wgsl` (Phase A2 of wgpu migration).
        // Operates on the SPIR-V binary directly: replaces placeholder
        // `extern const X_sampler2d: u32` variables with real samplers.
        //
        // Two output shapes from the same input:
        //
        //   --rewrite-samplers (default): combined OpTypeSampledImage
        //     variable + direct OpImageSampleImplicitLod.  This is what
        //     spirv-cross likes; produces clean `uniform sampler2D X`
        //     in GLSL.
        //
        //   --rewrite-samplers-wgsl: separate texture + sampler
        //     variables at adjacent bindings, OpSampledImage combine
        //     site at each sample location.  This is the only shape
        //     that survives WGSL translation.  spirv-cross handles
        //     this shape too (it merges them back when targeting GLSL),
        //     so opting into wgsl ALSO produces working GLSL.
        //
        // Opt into the WGSL shape when emit_wgsl is on so both
        // artifacts come from the same SPIR-V.  This is the path the
        // engine will be on after Phase F (GL deletion); for now
        // shaders without emit_wgsl keep the combined shape for
        // byte-identical GLSL output.
        //
        // Runs unconditionally: it's a no-op for shaders without
        // samplers (discovery returns empty).  See `tools/zspv.zig`
        // and `tools/zspv_rewrite.zig`.
        //
        // Sampler group/binding now comes from the SHADER SOURCE via
        // `zm.binding(&texture_sampler2d, group, binding)` calls
        // emitted by `tools/gen_shader_externs.zig` for every sampler
        // field in a schema's `Samplers` struct.  The rewriter's
        // discover pass captures those existing decorations into
        // `SamplerEntry.existing_set` / `existing_binding`, and the
        // rewrite phase honors them - so the build pipeline no longer
        // needs to override.  See
        // `src/notes/finishing_new_gpu_foundations.md` turn 1.
        const zspv_flag: []const u8 = if (opts.emit_wgsl)
            "--rewrite-samplers-wgsl"
        else
            "--rewrite-samplers";
        // Prefer the main-build ARTIFACT (a real graph edge - see the
        // `zspv_exe` field doc).  Fall back to the path + tools_dep +
        // addFileInput shape when no artifact was wired.
        const zspv: *Run = if (self.zspv_exe) |exe| blk: {
            const r: *Run = b.addRunArtifact(exe);
            // `addRunArtifact` makes the Run depend on BUILDING the exe,
            // but does NOT fingerprint the built binary into the Run's
            // cache key - so an exe rebuild alone won't re-fire the Run.
            // Content-track the emitted binary to close that gap.
            r.addFileInput(exe.getEmittedBin());
            r.addArg(zspv_flag);
            break :blk r;
        } else blk: {
            const r: *Run = b.addSystemCommand(&.{ self.zspv_path, zspv_flag });
            if (self.tools_dep) |d| {
                r.step.dependOn(d);
            }
            // Content-track the binary so a tools/ rebuild invalidates
            // the cache.  (Weaker than the artifact path - a nested
            // sub-build can be hashed before it rewrites the binary -
            // but correct for the external tools.)
            r.addFileInput(b.path(self.zspv_path));
            break :blk r;
        };
        zspv.addFileArg(raw_spv);
        const rewritten_spv: LazyPath = zspv.addOutputFileArg("shader.rewritten.spv");

        // ---- Stage 6 (optional): `spv2wgsl` -> WGSL.
        // Parallel branch off `rewritten_spv` (the pure-Zig zspv
        // output, pre-spirv-opt - see section 2.2).  Runs ONLY when
        // `opts.emit_wgsl == true` - the
        // GLSL-only path costs nothing extra during the side-by-side
        // transition.  See `src/notes/webgpu-migration-plan.md` section 3
        // Phase B for the rollout plan and `tools/spv2wgsl.zig` for
        // the CLI driver.
        //
        // Strict mode (`opts.wgsl_strict`, default true): the tool
        // exits non-zero if the WGSL contains any `// ERROR:` marker
        // (e.g. a combined-sampler shader that WGSL can't express).
        // Engine shaders should always pass strict; example shaders
        // may opt out during exploration.
        const wgsl_path: ?LazyPath = if (opts.emit_wgsl) blk: {
            // Prefer the main-build ARTIFACT (real graph edge: editing
            // src/spv2wgsl.zig rebuilds the exe -> its hash changes ->
            // this Run re-fires -> WGSL re-translates, no manual cache
            // clear).  Fall back to path + tools_dep + addFileInput.
            const w: *Run = if (self.spv2wgsl_exe) |exe| awblk: {
                const r: *Run = b.addRunArtifact(exe);
                // Content-track the emitted binary (addRunArtifact alone
                // doesn't fingerprint it into the Run cache key).
                r.addFileInput(exe.getEmittedBin());
                break :awblk r;
            } else wblk: {
                const r: *Run = b.addSystemCommand(&.{self.spv2wgsl_path});
                if (self.tools_dep) |d| {
                    r.step.dependOn(d);
                }
                r.addFileInput(b.path(self.spv2wgsl_path));
                break :wblk r;
            };
            // section 2.2 (finishing_webgpu.md): the WGSL path feeds the
            // pure-Zig `zspv` output (rewritten_spv) straight into
            // spv2wgsl - NO spirv-opt, NO spirv-val.  spv2wgsl is
            // hardened to consume raw, unoptimized Zig SPIR-V (turn 855:
            // all live shaders naga-valid pre-opt), so the WGSL shipping
            // path needs zero C++ SPIR-V tools.  The GLSL path above
            // still uses opt_spv + val - it's the dying GL-only branch.
            // Leading flag: select the CFG walker (must come before
            // --strict / the positional input, per the CLI parser).
            w.addArg(b.fmt("--walker={s}", .{self.wgsl_walker}));
            if (opts.wgsl_strict) {
                w.addArg("--strict");
            }
            w.addFileArg(rewritten_spv);
            break :blk w.addOutputFileArg("shader.wgsl");
        } else null;

        return .{
            .externs = externs_module,
            .wgsl = wgsl_path,
        };
    }

    /// Compile a SELF-CONTAINED compute shader (`.zig` with its own Buffers/
    /// Params + a `callconv(.{ .spirv_kernel = ... })` entry, no `_io`/externs)
    /// straight to WGSL. Two stages only: `zig build-obj -target spirv32` ->
    /// `spv2wgsl`. The `@workgroup_size` is read from the SPIR-V `LocalSize`
    /// (the kernel's `config.workgroup`), so no flag is passed. Skips the
    /// sampler-rewrite + externs-gen that the fragment/vertex `addShader` path
    /// needs. Returns the WGSL LazyPath.
    pub fn addCompute(
        self: *ShaderPipeline,
        source: LazyPath,
        entry: ?[]const u8,
        /// Give the kernel `zn`, so it can call the host function rather than transcribe it.
        /// Opt-in: Zig rejects `--dep` for a module the file does not import.
        wants_zimrnum: bool,
    ) LazyPath {
        const b: *Build = self.b;
        // Stage 1: Zig -> SPIR-V (same flags as the fragment path).
        const compile: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-obj",
            "-target",
            "spirv32-vulkan",
            "-mcpu",
            "vulkan_v1_2",
            "-fno-llvm",
            "-fno-lld",
            "-O",
            "ReleaseFast",
            "-ofmt=spirv",
        });
        const raw_spv: LazyPath = compile.addPrefixedOutputFileArg("-femit-bin=", "compute.spv");
        compile.addArg("--dep");
        compile.addArg("zm");
        compile.addArg("--dep");
        compile.addArg("kompute");
        if (wants_zimrnum) {
            // ROOT'S dependency list. Zig's `--dep` flags attach to the NEXT `-M`, so declaring
            // `-Mzn=` further down gives the module a name without making it visible to the
            // kernel - and the compiler says `module "zn" declared but not used`, which reads
            // like the file failed to import it when in fact the file's own dep list was short.
            compile.addArg("--dep");
            compile.addArg("zn");
        }
        compile.addPrefixedFileArg("-Mroot=", source);
        compile.addPrefixedFileArg("-Mzm=", b.path("src/zimrmath.zig"));
        // kompute re-exports zm (as `k.math`), so the kompute module needs zm too.
        compile.addArg("--dep");
        compile.addArg("zm");
        compile.addPrefixedFileArg("-Mkompute=", b.path("src/kompute.zig"));
        if (wants_zimrnum) {
            // THE KERNEL CALLS THE HOST FUNCTION INSTEAD OF RESTATING IT
            //
            // zimrnum compiles to SPIR-V - checked directly with `build-obj -ofmt=spirv` before
            // this was wired - so a kernel can import it and call the same code the CPU runs.
            // That removes the transcription, which has produced two bugs no unit test could
            // see: a buffer overrun in `mesh_grid` and a wrong divisor in `slice_columns`.
            compile.addArg("--dep");
            compile.addArg("zm");
            compile.addArg("--dep");
            compile.addArg("kompute");
            compile.addPrefixedFileArg("-Mzn=", b.path("src/zimrnum.zig"));
        }

        // Stage 2: SPIR-V -> WGSL. @workgroup_size comes from the SPIR-V LocalSize.
        const w: *Run = if (self.spv2wgsl_exe) |exe| awblk: {
            const r: *Run = b.addRunArtifact(exe);
            r.addFileInput(exe.getEmittedBin());
            break :awblk r;
        } else wblk: {
            const r: *Run = b.addSystemCommand(&.{self.spv2wgsl_path});
            if (self.tools_dep) |d| {
                r.step.dependOn(d);
            }
            r.addFileInput(b.path(self.spv2wgsl_path));
            break :wblk r;
        };
        w.addArg(b.fmt("--walker={s}", .{self.wgsl_walker}));
        if (entry) |e| {
            w.addArg(b.fmt("--entry={s}", .{e}));
        }
        w.addFileArg(raw_spv);
        const wgsl: LazyPath = w.addOutputFileArg("compute.wgsl");
        return wgsl;
    }

    /// `addCompute` + wire the WGSL into `mod` as `import_name` (@embedFile-able).
    pub fn addComputeImport(
        self: *ShaderPipeline,
        mod: *Module,
        source: LazyPath,
        import_name: []const u8,
    ) void {
        const wgsl_path: LazyPath = self.addCompute(source, null, false);
        mod.addAnonymousImport(import_name, .{ .root_source_file = wgsl_path });
    }

    /// Multi-kernel variant (t1178): translate `source` once per entry name
    /// (spv2wgsl --entry) and import each standalone WGSL module as
    /// `<entry>_wgsl`. The host hands the pairs to `Compute.initGpu`.
    pub fn addComputeKernelImports(
        self: *ShaderPipeline,
        mod: *Module,
        source: LazyPath,
        entries: []const []const u8,
        wants_zimrnum: bool,
    ) void {
        for (entries) |entry| {
            const wgsl_path: LazyPath = self.addCompute(source, entry, wants_zimrnum);
            mod.addAnonymousImport(
                self.b.fmt("{s}_wgsl", .{entry}),
                .{ .root_source_file = wgsl_path },
            );
        }
    }
};
