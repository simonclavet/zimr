// build.zig - zimr (pure-Zig raylib 6.0 port for wasm + WebGL2)
// Target: wasm32-wasi.  WASI gives us a real Zig stdlib (allocator,
// std.fs, std.time, std.log) without dragging in emscripten or libc.
// Browsers don't run WASI natively; we provide a tiny JS shim for the
// few WASI calls we use (fd_write, clock_time_get, random_get,
// proc_exit, args_*, environ_*, fd_close), plus our own custom
// `webgl` / `dom` import modules for canvas, WebGL2, and event input.
// Build steps:
//   zig build                       -- runtime + docs only (no example wasms).
//                                      Pass -Dfocus=<list> to also install
//                                      specific example wasms.
//   zig build all-examples          -- builds every example wasm into zig-out/web/
//   zig build serve                 -- builds all-examples, then serves
//                                      zig-out/web/ via the pure-Zig server
//                                      (tools/serve.zig).  Full gallery.
//   zig build serve-only            -- starts the dev server without rebuilding
//                                      examples.  Used by the VS Code background
//                                      task; HMR + run-<name> handle per-example
//                                      builds on demand.
//   zig build run-<name>            -- builds just that example, serves, opens
//                                      the browser (wgpu example pages).
//   zig build smoke-test            -- runs Bun-based wasm smoke tests
//   zig build test                  -- runs the host-target unit tests + every
//                                      example's typecheck (cheap, all of them)
// Source-of-truth for the port: the raylib 6.0 C source lives under
// raylib_src/ in this repo.  We are NOT tracking upstream raylib past
// 6.0 - every Zig function corresponds to a function in that snapshot
// and behavioural parity is verified against it.

const std = @import("std");
const ArrayList = std.ArrayList;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

// Local aliases for the std.Build types this file works with.  See
// `src/shader_codegen.zig` for the rationale — rule 2 (untyped-local)
// requires a type annotation on every `b.addX(...)` const, and the
// full `*std.Build.Step.Run` etc. spellings would dwarf the actual
// content.
const Module = std.Build.Module;
const Step = std.Build.Step;
const Run = std.Build.Step.Run;
const Compile = std.Build.Step.Compile;
const InstallArtifact = std.Build.Step.InstallArtifact;
const InstallDir = std.Build.Step.InstallDir;
const InstallFile = std.Build.Step.InstallFile;
const Options = std.Build.Step.Options;
const LazyPath = std.Build.LazyPath;
const ResolvedTarget = std.Build.ResolvedTarget;
const builtin = @import("builtin");

// Pure-CPU modules that have host-runnable unit tests.  Anything that
// touches WebGL or browser globals is excluded.
// One test executable, rooted at the aggregator.  Each per-module
// `*_test.zig` file lives in `src/tests/` and is pulled in by
// `src/tests.zig`.  Single root keeps test files inside one module
// boundary so they can reach sibling modules via `@import("../X.zig")`
// - Zig 0.16 forbids `..` traversal across module roots, so the
// per-file addTest pattern would force every test to live at
// `src/X_test.zig` next to `src/X.zig`.  This is the cleaner of the
// two paths.
const test_files = [_][]const u8{
    "src/tests.zig",
};

/// Editor-config manifest for the WebGPU demos (the wgpu migration).
/// Each entry is a `wgpu-<name>` build step whose demo installs to
/// `zig-out/web/<name>/` and serves at `http://localhost:8080/<name>/`.
/// `tools/gen_vscode.zig` (run via `zig build gen-vscode`) turns each into:
/// a `zig build <name>` build task, a `zig build <name>-standalone` task,
/// and a Chrome debug config — so the dev-server HMR loop rebuilds + reloads
/// them exactly like the GL examples.  Add a row when you wire a new servable
/// wgpu demo (a `b.step("wgpu-…")` with its own `.custom` install dir), then
/// run `zig build gen-vscode`.  (The legacy `wgpu-bringup` scaffold installs
/// to `zig-out/wgpu/`, not `zig-out/wgpu-bringup/`, so it's intentionally
/// omitted — it predates the per-demo dir convention.)
pub const example_steps = [_][]const u8{
    "3d-probe",                 "audio-basic",           "audio-stream-synth",            "ball-physics",
    "basic",                    "billboards",            "textures-background-scrolling", "bouncing-ball",
    "box-collisions",           "bridge-classic-probe",  "bridge-slice",                  "camera2d",
    "circle-sector-drawing",    "clock-of-clocks",       "collision-area",                "color-wheel",
    "colors-palette",           "composer-drum",         "comptime-julia",                "comptime-mandelbrot",
    "compute-particles",        "compute-smoke",         "cube-demo",                     "cube-sidebyside",
    "cube3d",                   "cubicmap",              "damaged-helmet",                "dashed-line",
    "digital-clock",            "double-pendulum",       "dynamic-mesh",                  "depth-cue",
    "depth-rendering",          "easings-ball",          "easings-box",                   "easings-rectangles",
    "easings-testbed",          "ecs-boids",             "ecs-solar-system",              "ellipse-collision",
    "first-person-camera",      "fluid-gpu",             "fluid-sort",                    "following-eyes",
    "forward-kinematics",       "fractal-tree",          "gallery",                       "gallery-all",
    "gestures-demo",            "gestures-testbed",      "gltf-simple",                   "gltf-textured",
    "hello-world",              "heightmap",             "helmet-sw",                     "decal-sw",
    "hilbert-curve",            "image-editor",          "imgui-phone-demo",              "input-keys",
    "input-mouse",              "input-mouse-wheel",     "input-multitouch",              "input-virtual-controls",
    "instancing",               "julia",                 "julia-gallery",                 "keys",
    "lambert-demo",             "launcher",              "life",                          "lines-bezier",
    "lines-drawing",            "logo-raylib",           "logo-raylib-anim",              "mandel-julia",
    "mandel-sidebyside",        "math-angle-rotation",   "math-sine-cosine",              "models3d",
    "music-streaming",          "obj-bunny",             "obj-simple",                    "particles",
    "pbr-demo",                 "penrose-tile",          "physics-sidebyside",            "pie-chart",
    "pipeline-array",           "pipeline-basic",        "pipeline-bloom",                "pipeline-constants",
    "pipeline-instancing",      "pipeline-mipmap",       "pipeline-msaa",                 "pipeline-postprocess",
    "pipeline-rendertarget",    "pipeline-sampler",      "pipeline-settings",             "pipeline-storage",
    "pipeline-uniforms",        "plot-demo",             "point-rendering",               "plot3d-demo",
    "plot3d-gallery",           "png-demo",              "procgen-noise",                 "raytracer",
    "rectangle-advanced",       "rectangle-scaling",     "recursive-hud",                 "render-texture",
    "ring-drawing",             "rounded-rectangle",     "rt-shader",                     "rt-sidebyside",
    "shader-inspection",        "shadowmap",             "shadow-sidebyside",             "shapes-demo",
    "shapes-showcase",          "shared-smoke",          "sidebyside",                    "simple-particles",
    "deferred-render",          "depth-writing",         "fog-rendering",                 "hybrid-render",
    "shadowmap-sw",             "skinned-mesh",          "skybox",                        "sph-fluid-2d",
    "splines-drawing",          "split-screen",          "starfield",                     "starfield-effect",
    "text-field",               "text-layout",           "text-on-texture",               "texture-readback",
    "textured-cube",            "textured-curve",        "tile-smoke",                    "touch-paint",
    "trails",                   "triangle-gradient",     "triangle-strip",                "ui-animation-gallery",
    "ui-canvas-demo",           "ui-clipper",            "ui-code-editor",                "ui-color-picker",
    "ui-combo-custom",          "ui-custom-rendering",   "ui-custom-widget",              "ui-data-grid-phone",
    "ui-demo",                  "ui-dev-tools",          "ui-dock-basic",                 "ui-dock-persistence",
    "ui-dock-simple",           "ui-drag-drop-demo",     "ui-drag-drop-flags-tour",       "ui-drag-drop-source",
    "ui-drawlists",             "ui-full-showcase",      "ui-imgui-extras",               "ui-input-callbacks",
    "ui-input-flags-zoo-phone", "ui-input-query-demo",   "ui-kanban-board",               "ui-log-skeleton",
    "ui-log-viewer",            "ui-mini-plot-smoke",    "ui-minimal-button",             "ui-minimal-one-context",
    "ui-mouse-drag",            "ui-multiselect-finder", "ui-notes-phone",                "ui-panes",
    "ui-persistence",           "ui-phone-gestures",     "ui-plot",                       "ui-plotting-basic",
    "ui-polish",                "ui-pomodoro-phone",     "ui-primitives-zoo-phone",       "ui-shortcuts",
    "ui-smoke-button",          "ui-tabbar-tour",        "ui-tables-basic",               "ui-tables-demo",
    "ui-tables-scroll",         "ui-widgets-data-types", "ui-window-menubar",             "vao-multibuffer",
    "vector-angle",             "wireframe",             "writing-anim",                  "zimrphysics-demo",
    "zimrphysics2d-demo",
};

/// Explicit catalog of every example shader that goes through the
/// typed-iface codegen pipeline.  One row per shader.  The pre-2026-
/// 05-27 build did sibling-file auto-discovery (look for
/// `examples/<name>_io.zig` next to `examples/<name>_fs.zig`) and
/// switched between three modes (typed-external, typed-inline,
/// legacy-hand-written) based on filename suffixes and file
/// existence.  That implicit graph was fragile: a misspelled iface
/// file silently dropped a shader to legacy mode.
///
/// The new table makes every shader's iface placement explicit:
///   - `iface = null`        → iface declared inline at the top of
///                              the shader source file (default — the
///                              common case).
///   - `iface = "<basename>"` → iface lives in `examples/<basename>.zig`,
///                              shared by multiple shaders (varyings
///                              between VS and FS; the same iface
///                              imported by several CPU examples).
///
/// Adding a new shader is one row; misspell anything and you get a
/// build error pointing at the spec, not silent legacy-mode drift.
/// Adding a new shader is one row; misspell anything and you get a
/// build error pointing at the spec, not silent drift.
/// One engine shader (VS/FS) and its emitted artifacts, accumulated in the
/// build's `engine_shaders` list and consumed by both wgpu demos and the
/// native software-render examples.
const EngineShader = struct {
    path: std.Build.LazyPath,
    name: []const u8,
    /// Pre-translated WGSL output, if `emit_wgsl = true` was used
    /// at emission time.  Lets late-binding consumers (wgpu_bringup
    /// and similar) wire engine WGSL into their modules via
    /// `addAnonymousImport` after-the-fact.  Null for engine
    /// shaders that opted out of WGSL emission.
    wgsl_path: ?std.Build.LazyPath = null,
    wgsl_name: ?[]const u8 = null,
    /// The codegen-emitted `*_externs.zig` LazyPath.  Native
    /// build targets that want to import the shader source
    /// directly (`@import("default_shapes_vs.zig")` → which in
    /// turn `@import`s the externs module) need this wired as
    /// `--dep <sh_name>_externs`.  Null when codegen didn't run
    /// (legacy pre-typed-shader path).  After the native-import
    /// codegen surgery the file compiles cleanly on both targets,
    /// so the same LazyPath works for SPIR-V and native consumers.
    externs_path: ?std.Build.LazyPath = null,
    /// The shader's Zig source path (`src/shaders/<name>.zig`).
    /// Needed by native targets that want to import the shader
    /// source as a module.
    source_path: ?std.Build.LazyPath = null,
    /// The shader's basename (`<name>`, no extension), used as
    /// the module-import name for the shader's own source.
    sh_name: ?[]const u8 = null,
};

pub fn build(b: *std.Build) void {
    // Pre-flight: bail out if the local .zig-cache has bloated past
    // the soft cap.  The cache is content-addressed and Zig never
    // garbage-collects it, so builds can quietly grow to tens of
    // gigabytes over time and fail with cryptic "No space left on
    // device" errors mid-link.  Catching it here is the friendly
    // path - the message tells the user what to do.
    checkDiskSpace(b);

    // ---- Wasm target (the real one)
    // `simd128` is enabled so the rasterizer kernels' `@Vector(4, f32)`
    // paths compile to wasm `f32x4.*` instructions instead of scalar
    // emulation.  All current browsers (Chrome 91+, Firefox 89+,
    // Safari 16.4+) support wasm SIMD; this hasn't been an
    // experimental target since 2022.  If we ever need to support
    // an older runtime we'd add a build option to fall back to
    // scalar - but the rasterizer's perf depends on this and the
    // browsers we target all have it.
    const wasm_target: ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .abi = .none,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });

    // ---- The one build knob: `-Dmode=...`
    // Three explicit modes, no default.  Every caller of `zig build`
    // (vscode tasks, dev server HMR, release.bat, scripts) MUST pass
    // one.  Missing -> build aborts with a clear error.  Rationale:
    // implicit-default ReleaseSmall once shipped when callers thought
    // they were debugging (broken VS Code breakpoints, hard to spot).
    // Explicit is cheaper than confused.
    //   debug                       - optimize=Debug,        all asserts always on
    //   release                     - optimize=ReleaseSmall, ONLY zimr's `utils.zig`
    //                                                        macros fire (Zig stdlib
    //                                                        safety still stripped)
    //   ship                        - optimize=ReleaseSmall, no asserts, no profiler
    // The default `release` keeps zimr's asserts on purpose: in
    // ReleaseSmall, Zig's built-in runtime safety (`std.debug.assert`,
    // integer overflow, unreachable, etc.) is stripped no matter what we
    // do.  The only asserts that survive under `release` are the ones zimr
    // declares via `src/utils.zig` - those are re-enabled at compile time
    // via the `assert_log` build option.  `ship` is the
    // variant that strips those too.
    // Mapping rationale:
    //   - `debug`: dev / breakpoints / DWARF.  Used by all VS Code
    //     tasks.  Bigger wasm (~1.5 MB) but full source-level
    //     debugging and ALL asserts (Zig's + zimr's).
    //   - `release`: production ship + zimr asserts still fire.  Used by
    //     `release.bat` so the prebuilt artifact uploaded to Pages still
    //     trips our own assert macros.
    //   - `ship`: true zero-overhead ship (no asserts, profiler stripped).
    //     The lean build users get.
    // Smoke artifacts piggyback on the same mode - there's no separate
    // `-Dsmoke-optimize` knob anymore.  Smoke runs at whatever mode
    // the rest of the build is at; in practice that's always `debug`
    // because smoke is a dev tool.
    const BuildMode = enum {
        debug,
        release,
        ship,
    };

    // -Dmode defaults to `debug` when omitted.  Real callers (VS Code
    // tasks, release.bat) all pass -Dmode
    // explicitly; the default is for `zig build test` and hand-typing
    // during development.  No warning — debug is the right default for
    // unconfigured invocations; production callers know to pass the
    // release modes.
    const mode: BuildMode = b.option(
        BuildMode,
        "mode",
        "debug | release | ship (default: debug)",
    ) orelse .debug;
    const optimize: std.builtin.OptimizeMode = switch (mode) {
        .debug => .Debug,
        .release, .ship => .ReleaseSmall,
    };

    // The deprecated WebGL/GLSL path is UNPLUGGED from the build: its ~80
    // examples, the `-Dgl` flag, the GL-only native fractal steps, and the
    // zglsl tool were removed. The example files remain on disk for porting to
    // wgpu; they are simply not built. wgpu is the only buildable target.
    // (GL-retirement P3: the GL `zimr` / `zimr_mod_smoke` wasm modules are
    // gone — the docs lib was their last consumer and now documents
    // zimr.  src/zimr.zig itself is deleted in P5.)

    // Umbrella module for the WebGPU stack — re-exports every public
    // type / namespace from `src/zimr.zig`.  Created here (NOT
    // down where the wgpu_bringup exe lives) so the engine-shader
    // auto-discovery loop below can attach WGSL anonymous imports to it.
    // Without this early creation, `Renderer2D`'s
    // `@embedFile("default_shapes_vs.wgsl")` (and the FS twin) fail
    // with FileNotFound because the import name isn't registered on
    // the module that ends up consuming them.
    const zimr_mod: *Module = b.addModule("zimr", .{
        .root_source_file = b.path("src/zimr.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = false,
    });

    // `shader_interface` is the typed-shader public API surface
    // (`Sampler2D`, `Attr`, `merge`, ...).  Registered as a named
    // module so iface files (`src/shaders/*_io.zig`) can
    // `@import("shader_interface")` from anywhere — same iface
    // file works inside the wgpu module, inside the codegen bootstrap
    // exes (Phase 2 of the typed-shader plan), and inside external
    // projects building against zimr.  Without this, iface files
    // would need `@import("../shader_interface.zig")` which
    // escapes the module path when an iface file is loaded as
    // the root of its own module (codegen case).
    //
    // No target set — the same module is imported by wasm exe
    // modules (zimr, smoke), by the host test module, and (in
    // Phase 2 wiring) by per-shader codegen bootstrap exes.  Zig
    // resolves target lazily through the consumer.
    const shader_interface_mod: *Module = b.addModule("shader_interface", .{
        .root_source_file = b.path("src/shader_interface.zig"),
    });
    // zm import is added just below, once zimrmath_mod is declared. zm is fully
    // self-contained (build_options baked in via addOptions; its host-only
    // std.log branch is comptime-dead on the SPIR-V target), so giving
    // shader_interface the Vec/Vec2/Vec3 aliases keeps it shader-safe and
    // removes the need for raw @Vector + `lint:off prefer-vec`.
    zimr_mod.addImport("shader_interface", shader_interface_mod);

    // math: the unified math.zig library.  Declared as a named module
    // here (not just down with the other shader-pipeline modules) so
    // modules can wire it as a dep — `src/zimr.zig` does
    // `pub const math = @import("math")` to re-export it on the flat
    // `z.*` surface.  Same module is also imported by every example's
    // exe_mod (transitively through iface files) and by every shader's
    // SPIR-V compile.
    //
    // Stage 5 of math-unification: ALL math.zig imports use the module
    // form `@import("math")` (not the path form `@import("math.zig")`)
    // so the same file isn't claimed by two different modules.  29 CPU
    // files were migrated in the Stage 5 sed sweep; doc files in
    // src/notes/ keep the path form because they're not compiled.
    const zimrmath_mod: *Module = b.addModule("zimrmath", .{
        .root_source_file = b.path("src/zimrmath.zig"),
        // No `.target` — math.zig is imported by modules with various
        // targets (wasm32-wasi for exes, native for host tests).  When
        // the module has no target, consumers resolve it lazily through
        // their own target.  Hardcoding wasm_target here causes a Zig
        // 0.16 compiler segfault when the native test compile pulls
        // math in transitively.
    });

    // THE ONE `kompute` MODULE. Every GPU-compute example imports THIS — it is not built per
    // example, and that is the whole point.
    //
    // `wireComputeKernels` used to call `b.createModule(root = src/kompute.zig)` afresh for each
    // example. One compute example per page, and that was invisible. Put TWO on the same page —
    // which is exactly what the launcher is — and Zig sees two distinct modules with the same
    // root file, renames the second to `kompute0`, and then the kernel source that imports
    // "kompute" straddles both:
    //
    //     escape_kernel.zig: error: file exists in modules 'kompute' and 'kompute0'
    //
    // It looked like a four_ways bug. It was not. The launcher happened to contain exactly ONE
    // compute example (fluid_sort), so ANY second one would have broken it — four_ways was
    // simply the first to try. Sharing one module fixes the class, not the instance.
    const kompute_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/kompute.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    kompute_mod.addImport("zm", zimrmath_mod);
    // shader_builtins.zig — the SPIR-V shader DSL (decorators, texture/sampler
    // types, sampling + storage intrinsics), split out of zimrmath so editing a
    // shader intrinsic no longer invalidates the whole host cache. Like zm it
    // has no fixed target (resolved lazily by each consumer); it imports zm for
    // Vec/Vec2/float.
    const shader_builtins_mod: *Module = b.addModule("shader_builtins", .{
        .root_source_file = b.path("src/shader_builtins.zig"),
    });
    shader_builtins_mod.addImport("zm", zimrmath_mod);
    // codecs (re-exported from zimr) uses @import("zm"); wire it so the
    // wgpu demos can call gltf.parse / meshesFromGltf / jpeg.decode.
    zimr_mod.addImport("zm", zimrmath_mod);

    // Now that zimrmath_mod exists, give shader_interface the zm alias (see the
    // note at its declaration above). Every context that pulls shader_interface
    // already has zm wired alongside it, so this introduces no new graph edges
    // for consumers — it just lets shader_interface use Vec/Vec2/Vec3.
    shader_interface_mod.addImport("zm", zimrmath_mod);

    // ---- Public build-time API for downstream projects.
    // The `zimr_build` module exposes `ShaderPipeline` so external
    // build.zig files can compile typed Zig shaders without
    // duplicating the pipeline logic.  See `src/shader_codegen.zig` for
    // the API surface and current limitations (Linux x86_64 only as
    // of Phase 3a).  Internal zimr code accesses the same types via
    // a relative `@import("src/shader_codegen.zig")` further down in
    // this file.
    _ = b.addModule("zimr_build", .{
        .root_source_file = b.path("src/shader_codegen.zig"),
    });

    // ---- Build options exposed to source as `@import("build_options")`
    // `assert_log`: when true, `src/utils.zig` macros stay live and
    // log their failures even after Zig stdlib's runtime safety is
    // stripped at ReleaseSmall.  Derived from `-Dmode=` - not its
    // own knob.  Both `debug` and `release` set
    // this to true; `ship` turns it off.
    const assert_log: bool = switch (mode) {
        .debug, .release => true,
        .ship => false,
    };

    // `profile_enabled`: the integrated profiler (src/profiler.zig) is
    // compiled in and always-recording for every non-shipping mode, and
    // stripped to nothing in `ship`.  Same derive-from-mode pattern as
    // assert_log — profiler gating is `mode != .ship`.
    const profile_enabled: bool = switch (mode) {
        .debug, .release => true,
        .ship => false,
    };

    const build_opts: *Options = b.addOptions();
    build_opts.addOption(bool, "assert_log", assert_log);
    build_opts.addOption(bool, "profile_enabled", profile_enabled);
    // ui.zig's renderer backend: false = rlgl (GL), true = WgpuGl. The GL build
    // (host tests) uses false; the wgpu modules get a clone with true
    // (build_opts_wgpu, below), so the SAME ui.zig compiles for both backends.
    build_opts.addOption(bool, "ui_backend_wgpu", false);

    // Options for the WebGPU modules: same as build_opts but ui_backend_wgpu=true.
    const build_opts_wgpu: *Options = b.addOptions();
    build_opts_wgpu.addOption(bool, "assert_log", assert_log);
    build_opts_wgpu.addOption(bool, "profile_enabled", profile_enabled);
    build_opts_wgpu.addOption(bool, "ui_backend_wgpu", true);
    zimr_mod.addOptions("build_options", build_opts_wgpu);

    // zimrmath.zig's assert family reads `build_options.assert_log` on its
    // host (CPU) branch. `@import("build_options")` inside zimrmath.zig
    // resolves within THIS module, so adding it here makes it available to
    // every host consumer of `zm` at once (mesh_bake, the 3D examples,
    // kompute, ...) — no per-consumer addOptions needed. The SPIR-V compile
    // uses a separate `-Mzm=` module instance with no build_options, but its
    // CPU branch is comptime-dead (is_gpu), so it never references it.
    // zm gets its OWN options instance (a distinct generated file) so it never
    // collides with an importing module's build_options. When zm is pulled into a
    // module that already has a "build_options" (e.g. the GL test_mod, which also
    // uses build_opts), Zig dedup-renames zm's import to "build_options0" — and
    // that is only an error when both names root the SAME file. A dedicated file
    // sidesteps it (same situation the wgpu builds are already fine with, since
    // there zm's file differs from build_opts_wgpu). zm reads only `assert_log`.
    const build_opts_zm: *Options = b.addOptions();
    build_opts_zm.addOption(bool, "assert_log", assert_log);
    zimrmath_mod.addOptions("build_options", build_opts_zm);

    // Note on module structure: `ui.zig` and `ecs.zig` live as
    // FILES inside the zimr module, not as separate modules.
    // They're re-exported by zimr.zig as `pub const ui` and
    // `pub const ecs`, accessible to user code as `z.ui.X` and
    // `z.ecs.X`.  The reasons:
    //   - File-level imports within a single module can cycle.
    //     zimr.zig can use ui/ecs and ui/ecs can use zimr (via
    //     `@import("zimr.zig")`) freely; this is what enables
    //     "high-level zimr might use ecs" without architectural
    //     surgery.
    //   - Tests stay simple: the host test aggregator (tests.zig)
    //     just `_ = @import("ui.zig")` and discovers everything.
    //   - Lazy semantic analysis preserves opt-in: examples that
    //     never reach into `z.ecs` don't pull ecs into their wasm.

    const web_install: std.Build.InstallDir = .{ .custom = "web" };
    const smoke_install: std.Build.InstallDir = .{ .custom = "smoke/web" };

    // Smoke install step - parallel to `b.getInstallStep()` but for the
    // ReleaseSafe smoke build.  Wired up in the example loop below.
    const smoke_install_step: *Step = b.step(
        "smoke-install-safe",
        "Install smoke-mode wasm + assets to zig-out/smoke/web/",
    );

    // WebGPU smoke install: each live wgpu example installs a copy of its
    // wasm into zig-out/wgpu-smoke/web/, gated by -Dfocus (see
    // addWgpuSmoke).  `smoke-test` runs webtests/wgpu_smoke.ts over that
    // dir.  This is the live successor to the GL `smoke-install` above —
    // the GL example smoke was retired with the WebGL backend.
    const wgpu_smoke_install: *Step = b.step(
        "smoke-install",
        "Install live wgpu example wasms to zig-out/wgpu-smoke/web/ (focus-gated)",
    );

    // `-Dfocus=<list>` declared up here (not just before smoke-test
    // wiring like it used to be) because the install step ALSO consults
    // it now: focused builds skip non-matching examples entirely, which
    // makes the `<name>-standalone` steps cheap even after broad source
    // touches (drawing.zig, ui.zig - anything most examples import).  Without
    // this filter, `zig build install --release=small` rebuilds 100+
    // wasms on every cache invalidation; with it, only the matching
    // example(s) compile.
    // For incremental work, pass `-Dfocus=<list>` to filter:
    //     zig build install -Dfocus=ui_log_viewer     # build one wasm
    //     zig build smoke-test -Dfocus=ui_tables_demo,ui_drag_drop_demo
    //     zig build smoke-test -Dfocus=ui_tables_*    # prefix glob
    // The `*` suffix is a literal char in the pattern; entries with
    // it are matched as prefixes.  Plain entries match exactly.
    // Convention: use -Dfocus during normal per-turn iteration on
    // a specific arc, and re-run unfocused at arc close / every
    // few turns to catch broader regressions.
    const smoke_focus: []const u8 = b.option(
        []const u8,
        "focus",
        "Comma-separated example names or prefix globs (ending in '*') to " ++
            "build/smoke-test/typecheck.  Special value 'tier-a' = " ++
            "wgpu_bringup,cube3d,compute_smoke,shapes_showcase,ui_color_picker," ++
            "mandel_sidebyside,ui_dock_simple,ecs_solar_system " ++
            "(the per-turn smoke set).  Default: all.",
    ) orelse "";

    // Selects the CFG walker `spv2wgsl` uses to reconstruct control
    // flow when emitting WGSL: "ir" (the structured-IR path, now the
    // default — proven on the corpus + in-browser, naga-clean on the
    // typed-harness shaders) or "legacy" (the original recursive walker,
    // kept one cycle as an escape hatch, scheduled for deletion in F5).
    // Threaded into the shader pipeline's spv2wgsl invocation as the
    // leading `--walker=` flag.  `-Dwalker=legacy` falls back to the old
    // path if the IR walker ever misbehaves on a new shader.
    const wgsl_walker: []const u8 = b.option(
        []const u8,
        "walker",
        "spv2wgsl CFG walker for WGSL emission: 'ir' (default) or 'legacy'.",
    ) orelse "ir";

    // `zig build test` is the single inner-loop step.  It runs host
    // unit tests AND typechecks every example (via `addObject` deps
    // added in the example loop below).  Examples target wasm so they
    // can't be folded into `b.addTest`; instead each gets an
    // `addObject` step wired to `test_step`, so a syntax/type error
    // in any example surfaces here.  ~7s warm - replaces what used
    // to be a separate `zig build check` step.  The actual host-test
    // wiring (the `addTest` + `addRunArtifact` loop) lives further
    // down where it has access to the test file list.
    const test_step: *Step = b.step("test", "Host unit tests + build-check tier-A examples");
    // (Was a custom makeFn that printed "all tests passed".  The
    // configurer/maker split removed user makeFn closures; the maker's
    // Build Summary already prints per-step success, so the printer is
    // gone.  See src/notes/zig17_migration.md B2.)

    // `zig build all-examples` aggregates every per-example install.
    // Default `zig build` (b.getInstallStep()) builds runtime + docs only;
    // example wasms ride along only when -Dfocus matches.  Anything that
    // truly needs every wasm (serve, dist, the gallery picker) declares
    // a dependency on this step.  We attach b.getInstallStep() as a
    // child so the static bundle, zimr.js, and docs come along too.
    const all_examples_step: *Step = b.step(
        "all-examples",
        "Build every example wasm into zig-out/web/",
    );
    all_examples_step.dependOn(b.getInstallStep());

    // ---- Shader pipeline.  Declared early because the examples loop below
    // uses `shader_pipeline.addShaderImport` for examples that have a
    // `<name>_fs.zig` sibling. The pipeline is now pure Zig (zspv + spv2wgsl
    // artifacts, built above) — the old `tools/build.zig` sub-build that built
    // the C++ SPIR-V tools (spirv-opt/val/cross) is gone, along with the GLSL
    // path that used them. WGSL is the only target and never touches C++.
    // Walk src/, examples/, tests/ for shader source files.  Picks
    // up new ones automatically as the codebase grows.  Filter is
    // strict — only `_vs.zig` and `_fs.zig` basenames, so false
    // positives are near-zero.  ZLS shadow modules so the editor can
    // resolve `@import("zm")` inside any shader source — build
    // behaviour is unchanged (these shadows aren't depended on by any
    // exe).  Stage 10 of math-unification deleted the old
    // `shadermath` module; `zm` (the unified math.zig) is the only
    // math import shader sources ever need now.
    // ---- Pure-Zig shader tools, built by the MAIN build as artifacts.
    // Invoking these via `addArtifactArg` (see ShaderPipeline) makes
    // each a real dependency edge: edit the tool's source → it
    // rebuilds → its emitted-binary hash changes → every downstream
    // shader Run re-fires → WGSL/GLSL re-translates automatically.
    // This closes the stale-output hole that the nested `tools/
    // build.zig` + `addFileInput(path)` shape left open — a nested
    // `zig build` is a cache boundary the outer build can't see
    // across, so the path could be hashed before the sub-build
    // rewrote it.  (The C++ SPIR-V tools stay in tools/ behind the
    // path + tools_subbuild shape; they're genuinely external.)
    const host_target: ResolvedTarget = b.graph.host;
    // Host-side tool executables (pure-Zig, built by the main build as named
    // artifacts; an external consumer can `dep.artifact("c2js")` etc.). Grouped
    // into buildTools, which returns the set; destructured back to the local
    // names the rest of build() already uses.
    const tools: Tools = buildTools(b, host_target, zimrmath_mod);
    const spv2wgsl_tool_exe: *Compile = tools.spv2wgsl;
    const spv2wgsl_check_exe: *Compile = tools.spv2wgsl_check;
    const zspv_tool_exe: *Compile = tools.zspv;
    const lint_zimr_exe: *Compile = tools.lint;
    const c2js_exe: *Compile = tools.c2js;
    const serve_exe: *Compile = tools.serve;
    const cheatsheet_exe: *Compile = tools.cheatsheet;
    const buildaux_exe: *Compile = tools.buildaux;
    const mesh_bake_exe: *Compile = tools.mesh_bake;
    const highlight_exe: *Compile = tools.highlight;

    // native_plot_png: a small, native, pure-Zig program that renders a
    // publication-quality plot straight to `plot.png` via `zimr.Canvas`
    // (supersampled-AA `imageDraw*` + truetype text + zimr's own PNG codec).
    // No GPU, no wasm, no third party. `zig build native-plot-png`.
    //
    // It gets its OWN host-target `zimr` module instance (disjoint compile
    // graph, same as the mesh_bake codecs module above). This matters: the
    // wasm `zimr_mod` carries generated-shader build deps, but the CPU PNG
    // path needs none of them, so a separate module keeps this a fast,
    // GPU-free native build.
    const zimr_native_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = host_target,
        .optimize = .Debug,
    });
    zimr_native_mod.addImport("zm", zimrmath_mod);
    zimr_native_mod.addImport("shader_interface", shader_interface_mod);
    zimr_native_mod.addOptions("build_options", build_opts_wgpu);
    const native_plot_png_exe: *Compile = b.addExecutable(.{
        .name = "native_plot_png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/native_plot_png/main.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    native_plot_png_exe.root_module.addImport("zimr", zimr_native_mod);
    native_plot_png_exe.root_module.addImport("zm", zimrmath_mod);
    const native_plot_png_run: *Run = b.addRunArtifact(native_plot_png_exe);
    const native_plot_png_step: *Step = b.step(
        "native-plot-png",
        "Render a publication-quality plot to plot.png (native, pure Zig)",
    );
    native_plot_png_step.dependOn(&native_plot_png_run.step);

    // shadowmap-sw-verify: the NATIVE gate for the shadow-map side-by-side's
    // comptime corner.  Compiling this exe bakes `scene.bakeCorner` at comptime
    // (the compile-time-budget gate); running it re-renders the same function
    // at runtime, byte-compares the two, sanity-checks the images, and dumps
    // corner_lit.png + corner_shadowmap.png for eyeball verification.  The
    // bunny proxy comes from mesh_bake's OBJ path (grid 10 ≈ 693 tris).
    const smsw_proxy_bake: *Run = b.addRunArtifact(mesh_bake_exe);
    smsw_proxy_bake.addFileArg(b.path("examples/shadowmap/bunny.obj"));
    const smsw_proxy_zig: LazyPath = smsw_proxy_bake.addOutputFileArg("bunny_proxy.zig");
    smsw_proxy_bake.addArg("10"); // decimation grid
    smsw_proxy_bake.addArg("2"); // tex_edge (ignored on the OBJ path)
    const smsw_verify_exe: *Compile = b.addExecutable(.{
        .name = "shadowmap_sw_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/shadowmap_sw/native_verify.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
        // NOTE (resolved): Zig 0.17.0-dev.956–early-1245 had an LLVM-backend
        // SEGV (rc=139, no Zig panic) compiling this native exe in any optimized
        // mode; the workaround forced the self-hosted x86 backend. As of the
        // current 0.17.0-dev.1245 toolchain the regression is gone — BOTH
        // backends compile this module cleanly in ReleaseFast and the exe
        // verifies byte-identically (comptime bake vs runtime render, 0-byte
        // diff). So we drop the backend override and use the compiler default.
    });
    smsw_verify_exe.root_module.addImport("zimr", zimr_native_mod);
    smsw_verify_exe.root_module.addImport("zm", zimrmath_mod);
    smsw_verify_exe.root_module.addAnonymousImport("bunny_proxy", .{ .root_source_file = smsw_proxy_zig });
    const smsw_verify_run: *Run = b.addRunArtifact(smsw_verify_exe);
    const smsw_verify_step: *Step = b.step(
        "shadowmap-sw-verify",
        "Bake the shadowmap_sw comptime corner (budget gate), diff vs runtime, dump PNGs",
    );
    smsw_verify_step.dependOn(&smsw_verify_run.step);

    // cel-shading-verify: render the toon+ink look NATIVELY through the same
    // shaderMains the wasm app compiles to WGSL (two rasterizeToTarget draws:
    // hull back-faces then toon front-faces), dump cel_verify.png, assert the
    // paper/top-band/ink tonal populations all exist.
    const cel_proxy_bake: *Run = b.addRunArtifact(mesh_bake_exe);
    cel_proxy_bake.addFileArg(b.path("examples/shadowmap/bunny.obj"));
    const cel_proxy_zig: LazyPath = cel_proxy_bake.addOutputFileArg("bunny_proxy.zig");
    cel_proxy_bake.addArg("14"); // finer than the shadow corner — bands need surface
    cel_proxy_bake.addArg("2");
    const cel_verify_exe: *Compile = b.addExecutable(.{
        .name = "cel_shading_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cel_shading/native_verify.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    cel_verify_exe.root_module.addImport("zimr", zimr_native_mod);
    cel_verify_exe.root_module.addImport("zm", zimrmath_mod);
    cel_verify_exe.root_module.addAnonymousImport("bunny_proxy", .{ .root_source_file = cel_proxy_zig });
    const cel_verify_run: *Run = b.addRunArtifact(cel_verify_exe);
    const cel_verify_step: *Step = b.step(
        "cel-shading-verify",
        "Render the cel example's look natively via the shared shaderMains, dump cel_verify.png",
    );
    cel_verify_step.dependOn(&cel_verify_run.step);

    // shader-effects-verify: run all four 2D effect shaderMains natively over
    // a synthetic alpha test pattern, dump a contact sheet, assert each effect
    // visibly does its job (grade differs, waves displace, outline inks,
    // palette emits only table colors).
    const fx_verify_exe: *Compile = b.addExecutable(.{
        .name = "shader_effects_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/shader_effects/native_verify.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    fx_verify_exe.root_module.addImport("zimr", zimr_native_mod);
    fx_verify_exe.root_module.addImport("zm", zimrmath_mod);
    const fx_verify_run: *Run = b.addRunArtifact(fx_verify_exe);
    const fx_verify_step: *Step = b.step(
        "shader-effects-verify",
        "Run the 2D effect shaderMains natively over a test pattern, dump effects_verify.png",
    );
    fx_verify_step.dependOn(&fx_verify_run.step);

    // hybrid-render-verify: render the raymarched scene natively through the
    // real shaderMain, dump hybrid_verify.png, assert sky/floor/blob pixels.
    const hy_verify_exe: *Compile = b.addExecutable(.{
        .name = "hybrid_render_verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hybrid_render/native_verify.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    hy_verify_exe.root_module.addImport("zimr", zimr_native_mod);
    hy_verify_exe.root_module.addImport("zm", zimrmath_mod);
    const hy_verify_run: *Run = b.addRunArtifact(hy_verify_exe);
    const hy_verify_step: *Step = b.step(
        "hybrid-render-verify",
        "Render the hybrid example's raymarched scene natively, dump hybrid_verify.png",
    );
    hy_verify_step.dependOn(&hy_verify_run.step);

    // dag-png: render the src dependency graph to src/notes/dag.png, drawn by
    // zimr's OWN software rasterizer (Canvas).  Reuses the host
    // zimr module above; gets the shared import_graph via a sibling file
    // import inside tools/dag_png.zig.  `zig build dag-png`.
    const dag_png_exe: *Compile = b.addExecutable(.{
        .name = "dag_png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dag_png.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    dag_png_exe.root_module.addImport("zimr", zimr_native_mod);
    dag_png_exe.root_module.addImport("zm", zimrmath_mod);
    const dag_png_run: *Run = b.addRunArtifact(dag_png_exe);
    const dag_png_step: *Step = b.step(
        "dag-png",
        "Render the src dependency graph to src/notes/dag.png (native, zimr-drawn)",
    );
    dag_png_step.dependOn(&dag_png_run.step);

    var shader_pipeline = ShaderPipeline.init(
        b,
        null,
        shader_interface_mod,
        zimrmath_mod,
    );
    // Pure-Zig shader tools as real artifact edges (no sub-build, no C++).
    shader_pipeline.spv2wgsl_exe = spv2wgsl_tool_exe;
    shader_pipeline.zspv_exe = zspv_tool_exe;
    shader_pipeline.wgsl_walker = wgsl_walker;

    const zls_shader_paths: [][]const u8 = collectShaderFiles(b) catch &.{};
    for (zls_shader_paths) |path| {
        _ = b.addModule(b.fmt("shader_zls:{s}", .{path}), .{
            .root_source_file = b.path(path),
            .target = wasm_target,
            .imports = &.{
                .{
                    .name = "zm",
                    .module = zimrmath_mod,
                },
            },
        });
    }

    // Engine shaders.  Auto-discovered: every `_vs.zig` / `_fs.zig`
    // under `src/shaders/` gets compiled through the SPIR-V pipeline
    // and exposed as an `@embedFile`-able import named
    // `<basename>.glsl` on the host-test modules (the GL files compiled
    // there still embed them — placeholders; dies in P5).  The engine source
    // (`src/rlgl.zig`, `src/render.zig`) does `@embedFile("<name>.glsl")`
    // in place of inline-GLSL string constants.  Examples are free
    // to reuse the engine shaders via the same `@embedFile` form —
    // an example that wants the default VS just writes
    // `@embedFile("default_vs.glsl")`.  Unused imports cost nothing
    // (the bytes only enter the wasm via an explicit `@embedFile`).
    var engine_shaders: ArrayList(EngineShader) = .empty;
    // Old-style 3D-pipeline shaders that haven't migrated to the
    // IoT pattern yet.  They access `shader_externs.X` at module
    // scope and call `shader_externs.setup()` — both broken by
    // the native-import codegen surgery (externs moved into
    // `_Spirv` namespace).  Skipped from the build until migrated;
    // none are on the wgpu critical path (Renderer2D uses only
    // default_shapes_vs/fs which already use IoT).  Re-enable
    // by migrating to IoT or by prefixing extern accesses with
    // `shader_externs._Spirv.`.  Tracked: turn 4 of the gpu-foundations plan.
    // (GL-retirement P5: the old WebGL 3D shader sources — default/
    // shadow/skybox/unlit — are deleted; nothing embeds their .glsl
    // names anymore.  The gravestone below survives only because LIVE
    // shader entries still carry a `<name>.glsl` placeholder name that
    // consumer loops wire unconditionally; collapsing engine_shaders to
    // wgsl-primary naming is queued in P6.)
    const glsl_gravestone: LazyPath = b.path("src/shaders/_deleted_glsl_placeholder.glsl");
    for (zls_shader_paths) |path| {
        if (!startsWith(u8, path, "src/shaders/")) {
            continue;
        }
        if (startsWith(u8, path, "src/shaders/probes/")) {
            continue;
        }

        const base: []const u8 = std.fs.path.basename(path);
        const sh_name: []const u8 = base[0 .. base.len - ".zig".len];

        // Phase 2 typed-shader codegen: when a sibling `<base>_io.zig`
        // exists, hand it to addShader.  ShaderPipeline runs the
        // bootstrap-per-shader codegen to produce a generated
        // `*_extern.zig` and wires it into the spirv compile as
        // `--dep io`.  Shader bodies then `@import("io")` for their
        // extern decls instead of hand-writing them.  Missing iface
        // file → addShader skips Stage 0 entirely; pre-typed-shader
        // shaders keep working unchanged.
        const shader_io_rel_path: []const u8 = b.fmt("src/shaders/{s}_io.zig", .{sh_name});
        const shader_io_opt: ?std.Build.LazyPath = blk: {
            b.root.root_dir.handle.access(b.graph.io, shader_io_rel_path, .{}) catch break :blk null;
            break :blk b.path(shader_io_rel_path);
        };

        // Phase B2 of webgpu-migration-plan.md: emit `.wgsl` for every
        // engine shader, not just `default_shapes_*`.  Cost is one
        // spv2wgsl run per shader; cheap.  Each shader still goes
        // through the corpus regression so dirty translations are
        // caught at build time.  `wgsl_strict = true` below means
        // any `// ERROR:` marker (e.g. unhandled SPIR-V construct)
        // fails the build — opt-out per-shader via `wgsl_strict =
        // false` if a particular shader needs exploration time.
        const emit_wgsl: bool = true;

        const out: ShaderPipeline.ShaderOutput = shader_pipeline.addShaderEx(
            b.path(path),
            .{
                .shader_io = shader_io_opt,
                .shader_basename = sh_name,
                .emit_wgsl = emit_wgsl,
                // engine shaders MUST be `// ERROR:`-free
                .wgsl_strict = true,
            },
        );
        const import_name: []const u8 = b.fmt("{s}.glsl", .{sh_name});
        var captured_wgsl_path: ?std.Build.LazyPath = null;
        var captured_wgsl_name: ?[]const u8 = null;
        if (out.wgsl) |wgsl_path| {
            // Wire the same shader's .wgsl as a second anonymous
            // import; consumers `@embedFile("<name>.wgsl")` to bake
            // the WGSL into the wasm for the wgpu backend.  See
            // `src/notes/webgpu-migration-plan.md` §3 Phase C.
            //
            // zimr_mod consumes these via
            // `@embedFile("default_shapes_vs.wgsl")` (Renderer2D).
            const wgsl_import_name: []const u8 = b.fmt("{s}.wgsl", .{sh_name});
            zimr_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = wgsl_path });
            captured_wgsl_path = wgsl_path;
            captured_wgsl_name = wgsl_import_name;
        }
        // The pbr AND default_shapes shader SOURCES are part of the
        // zimr module (re-exported as `z.pbr_shaders.vs` / `.fs`
        // and `z.default_shapes.vs` / `.fs`) so the software half of
        // side-by-sides runs the same `shaderMain` the GPU pipeline
        // compiled to WGSL above.  Their named-module dep — the
        // generated `<name>_externs` (IoT/Out/installSpirvEntry) — gets
        // wired here.  Lazy analysis means examples that never touch
        // those re-exports pay nothing.  No `.target` on the externs
        // module: like shader_interface it resolves through the consumer
        // (wasm app vs host test).
        // Every generated `<name>_externs` module is wired into BOTH zimr
        // modules (wasm + native) unconditionally: lazy analysis means a
        // shader nobody re-exports or calls costs nothing, and this removes
        // the old hand-maintained name list that had to chase zimr.zig's
        // re-exports (pbr_shaders, default_shapes, shadow_shaders, ...).
        // Externs modules are target-agnostic (no `.target`): like
        // shader_interface they resolve through the consumer.
        if (out.externs) |externs_path| {
            const externs_mod: *Module = b.createModule(.{
                .root_source_file = externs_path,
            });
            externs_mod.addImport("zm", zimrmath_mod);
            externs_mod.addImport("shader_builtins", shader_builtins_mod);
            zimr_mod.addImport(b.fmt("{s}_externs", .{sh_name}), externs_mod);
            zimr_native_mod.addImport(b.fmt("{s}_externs", .{sh_name}), externs_mod);
        }
        engine_shaders.append(b.allocator, .{
            .path = glsl_gravestone,
            .name = import_name,
            .wgsl_path = captured_wgsl_path,
            .wgsl_name = captured_wgsl_name,
            .externs_path = out.externs,
            .source_path = b.path(path),
            .sh_name = sh_name,
        }) catch {};
    }

    // Explicit registration block for sampler-probe shaders.  Lives
    // under `src/shaders/probes/`; skipped by the auto-discovery loop
    // above because we want them findable as a group.  Same pipeline
    // as everything else now.
    const sampler_probes = [_][]const u8{
        "src/shaders/probes/sampler_test_fs.zig",
    };
    for (sampler_probes) |path| {
        const base: []const u8 = std.fs.path.basename(path);
        const sh_name: []const u8 = base[0 .. base.len - ".zig".len];
        const import_name: []const u8 = b.fmt("{s}.glsl", .{sh_name});
        engine_shaders.append(b.allocator, .{
            .path = glsl_gravestone,
            .name = import_name,
        }) catch {};
    }

    // ========================================================================
    // PHASE SPLIT — everything above is what a CONSUMER needs: the exposed
    // modules (zimr/zimrmath/shader_interface/zimr_build), the pure-Zig tool
    // artifacts, the shader pipeline, and the engine-shader WGSL embedded into
    // `zimr_mod`. Everything BELOW is dev/demo machinery — the 137-example
    // gallery, bridge demos, smoke tests, the c2js corpus/diff gates, the
    // cheatsheet, dist, and serve. A project depending on zimr must not pay to
    // construct (or risk root-relative path failures from) any of it, so bail
    // out here when zimr is a dependency (`pkg_hash` is non-empty for deps,
    // empty for the root project).
    // ========================================================================
    if (b.pkg_hash.len != 0) {
        return;
    }

    // Build a map: example-name → list of shader file paths owned
    // by that example.  Done in one pass so longest-prefix-wins
    // disambiguates examples whose names share a prefix (e.g.
    // `shader` is a prefix of `shader_uniforms`; without this,
    // `shader_uniforms_fs.zig` would get picked up by the `shader`
    // example too).  Each shader is assigned to the example with
    // the LONGEST name that's a prefix-followed-by-underscore.
    //
    // Two file shapes recognized for a given example `<name>`:
    //   `examples/<name>_vs.zig`           single-shader VS
    //   `examples/<name>_fs.zig`           single-shader FS
    //   `examples/<name>_<purpose>_vs.zig` multi-shader VS variant
    //   `examples/<name>_<purpose>_fs.zig` multi-shader FS variant
    //
    // The `<purpose>` segment lets one example carry multiple
    // typed shader programs (e.g. a model FS + a skybox FS) without
    // editing this build.zig — each compiled artifact is importable
    // from the example's CPU side as `@embedFile("<basename>.glsl")`.
    //
    // Sibling `<basename>_io.zig` files alongside the shader file
    // are auto-discovered and wired as `--dep io` so example-side
    // shaders can use the typed API end-to-end without build.zig
    // edits.

    // Copy static site content into zig-out/web.  (GL-retirement P5:
    // the GL gallery picker index.html + per-example host.html + the
    // WebGL runtime bundle are gone — the wgpu examples each carry
    // their own page, and standalones bake src/bridge.zig.)
    inline for (.{
        // index.html is the examples GALLERY landing page (manifest-driven:
        // module filter + name/function search, cards link to the streamed
        // per-example page at web/<name>/). Served at the root of zig-out/web.
        .{ "src/web/index.html", "index.html" },
        // readme.html is NOT here — it's piped through the `highlight` tool
        // just below (build-time Zig syntax highlighting) rather than copied
        // verbatim.
        // cheatsheet.html is regenerated at repo root by the pure-Zig
        // `zig build cheatsheet` step (tools/cheatsheet.zig, wired just
        // below). Pulled into the install pipeline so `zig build dist`
        // carries it into `prebuilt/` alongside readme.html.
        .{ "cheatsheet.html", "cheatsheet.html" },
        // manifest.json drives the gallery's filter/star/description UI.
        .{ "src/web/manifest.json", "manifest.json" },
        // Runtime assets fetched by examples via `f.loader.loadFileData`.
        .{ "assets/smiley.png", "assets/smiley.png" },
    }) |pair| {
        const inst: *InstallFile = b.addInstallFileWithDir(b.path(pair[0]), web_install, pair[1]);
        b.getInstallStep().dependOn(&inst.step);
        // Smoke needs the same static assets.
        const inst_smoke: *InstallFile = b.addInstallFileWithDir(b.path(pair[0]), smoke_install, pair[1]);
        smoke_install_step.dependOn(&inst_smoke.step);
    }

    // readme.html: the project landing page (README content in dark-brutalist
    // style; README.md just links here).  Piped through the `highlight` tool
    // (tools/highlight.zig) instead of copied verbatim, so every
    // <pre><code class="language-zig"> block is syntax-highlighted at build
    // time with std.zig.Tokenizer — the served page stays pure HTML+CSS, no
    // runtime JS.
    {
        const hl: *Run = b.addRunArtifact(highlight_exe);
        hl.setStdIn(.{ .lazy_path = b.path("src/web/readme.html") });
        const readme_out: LazyPath = hl.captureStdOut(.{});
        const readme_inst: *InstallFile = b.addInstallFileWithDir(readme_out, web_install, "readme.html");
        b.getInstallStep().dependOn(&readme_inst.step);
        const readme_smoke: *InstallFile = b.addInstallFileWithDir(readme_out, smoke_install, "readme.html");
        smoke_install_step.dependOn(&readme_smoke.step);
        // Standalone step so you can regenerate just the highlighted page
        // (zig build readme -> zig-out/web/readme.html) without triggering the
        // full install graph (shader pipeline, lint, every example).
        const readme_step: *Step = b.step("readme", "Generate zig-out/web/readme.html with Zig syntax highlighting");
        readme_step.dependOn(&readme_inst.step);
    }

    // Shared runtime JS: ONE web/zimr.js (the transpiled bridge) that every
    // served example page references via <script src="../zimr.js"> (--external-js
    // in bridgePage), so the ~500KB runtime is fetched + cached ONCE instead of
    // inlined into every page. Built exactly like bridgePage but WITHOUT --html
    // — bare JS to stdout. The standalone twin still inlines (file://-portable).
    {
        const to_c: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,       "build-obj",
            "-ofmt=c",             "-target",
            "wasm32-freestanding", "-OReleaseSmall",
        });
        to_c.addFileArg(b.path("src/bridge.zig"));
        const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
        const to_js: *Run = b.addRunArtifact(c2js_exe);
        to_js.setStdIn(.{ .lazy_path = bridge_c });
        const zimr_js: LazyPath = to_js.captureStdOut(.{});
        const zimr_js_install: *InstallFile = b.addInstallFileWithDir(zimr_js, web_install, "zimr.js");
        b.getInstallStep().dependOn(&zimr_js_install.step);
        const zimr_js_smoke: *InstallFile = b.addInstallFileWithDir(zimr_js, smoke_install, "zimr.js");
        smoke_install_step.dependOn(&zimr_js_smoke.step);
    }

    // ---- cheatsheet: regenerate cheatsheet.html from src/'s public API.
    // Pure Zig (tools/cheatsheet.zig): auto-discovers every src/*.zig, so new
    // modules need no edits here. Writes the file in-place at the repo root
    // (side-effecting), to be committed and then carried by `dist`.
    const cheatsheet_step: *Step = b.step(
        "cheatsheet",
        "Regenerate cheatsheet.html from src/ public API (pure Zig)",
    );
    const cheatsheet_run: *Run = b.addRunArtifact(cheatsheet_exe);
    cheatsheet_run.addArgs(&.{ "src", "cheatsheet.html" });
    cheatsheet_run.has_side_effects = true;
    cheatsheet_step.dependOn(&cheatsheet_run.step);

    // ---- WebGPU demo (Phase 1 of the wgpu migration; see notes/MIGRATION_PROGRESS.md).
    // Standalone target — does NOT touch the existing GL example flow
    // (per migration decision D8, side-by-side).  Builds the wgpu_bringup
    // wasm, bundles src/bridge.zig to wgpu_bringup.js, and installs an
    // index.html that loads them both.  Triggered ONLY by `zig build
    // wgpu-bringup`; never built as part of the default install or any
    // existing step, so the existing build is unaffected.
    //
    //   zig build wgpu-bringup
    //   zig build serve-only   (pure-Zig server, tools/serve.zig; or run the
    //                           serve exe with --root zig-out/wgpu)
    //   open http://localhost:8080/index.html
    const wgpu_install: std.Build.InstallDir = .{ .custom = "wgpu" };

    // `zimr_mod` was created earlier (top of configure) so
    // the engine-shader auto-discovery loop could attach WGSL
    // anonymous imports to it.  Just use it here.

    const wgpu_bringup_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/wgpu_bringup/wgpu_bringup.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = false,
    });
    wgpu_bringup_mod.addImport("zimr", zimr_mod);
    wgpu_bringup_mod.addImport("zm", zimrmath_mod);
    wgpu_bringup_mod.addImport("shader_interface", shader_interface_mod);

    // Wire ENGINE WGSL imports onto wgpu_bringup_mod so the demo can
    // `@embedFile("default_shapes_vs.wgsl")` and feed it as the VS
    // half of a `loadShader` call.  Same pattern as `zimr_mod`'s
    // wiring (line ~660 above), but late-bound — the engine-emission
    // loop ran much earlier and recorded paths on `engine_shaders`.
    for (engine_shaders.items) |s| {
        if (s.wgsl_path) |wgsl_path| {
            wgpu_bringup_mod.addAnonymousImport(s.wgsl_name.?, .{ .root_source_file = wgsl_path });
        }
    }

    // Wire EXAMPLE shader WGSL imports for shaders that the demo
    // wants to consume directly (e.g. `mandelbrot_fs.wgsl` for the
    // wgpu Mandelbrot pipeline that validates Phase D1 end-to-end).
    // Compiled explicitly below (NOT via the GL-gated `compiled_shaders`
    // map) so the demo also builds under -Dgl=false.
    {
        // mandelbrot_fs is @embedFile'd by the demo and must compile even under
        // -Dgl=false (compiled_shaders is gated with the GL examples), so build
        // it explicitly here — same approach as wgpu-mandelbrot-split below.
        const mandel_out: zimr_build.ShaderPipeline.ShaderOutput = shader_pipeline.addShaderEx(
            b.path("examples/mandelbrot_fs.zig"),
            .{
                .shader_io = b.path("examples/mandelbrot_fs_io.zig"),
                .shader_basename = "mandelbrot_fs",
                .emit_wgsl = true,
                .wgsl_strict = true,
            },
        );
        const mandel_wgsl: LazyPath = mandel_out.wgsl orelse {
            std.debug.panic("wgpu_bringup: mandelbrot_fs produced no WGSL", .{});
        };
        wgpu_bringup_mod.addAnonymousImport("mandelbrot_fs.wgsl", .{ .root_source_file = mandel_wgsl });

        // The three fractal io schemas the demo @imports by filename (for
        // loadShader's comptime VS-Outputs == FS-Inputs check). Plain Zig
        // schema files — wired as modules, not compiled as shaders.
        const fractal_io = [_][]const u8{
            "mandelbrot_fs_io",
            "julia_fs_io",
            "mandel_julia_fs_io",
        };
        for (fractal_io) |io_name| {
            wgpu_bringup_mod.addAnonymousImport(
                b.fmt("{s}.zig", .{io_name}),
                .{
                    .root_source_file = b.path(b.fmt("examples/{s}.zig", .{io_name})),
                    .imports = &.{
                        .{ .name = "zm", .module = zimrmath_mod },
                    },
                },
            );
        }
    }

    // Explicitly-registered wgpu_bringup shader pairs.  These shaders
    // are AUTHORED specifically for wgpu_bringup (not for any regular
    // example) so the auto-discovery loop above didn't pick them up.
    // The trivial VS+FS pair validates Phase D1 end-to-end with the
    // smallest possible loadShader consumer: no Ubo, no Samplers,
    // pass-through pose + UV gradient color.
    {
        const wgpu_bringup_pairs = [_]struct {
            sh_name: []const u8,
            source_path: []const u8,
            io_path: []const u8,
        }{
            .{
                .sh_name = "trivial_vs",
                .source_path = "examples/trivial_vs.zig",
                .io_path = "examples/trivial_vs_io.zig",
            },
            .{
                .sh_name = "trivial_fs",
                .source_path = "examples/trivial_fs.zig",
                .io_path = "examples/trivial_fs_io.zig",
            },
        };
        for (wgpu_bringup_pairs) |pair| {
            const sh_out: zimr_build.ShaderPipeline.ShaderOutput =
                shader_pipeline.addShaderEx(b.path(pair.source_path), .{
                    .shader_io = b.path(pair.io_path),
                    .shader_basename = pair.sh_name,
                    .emit_wgsl = true,
                    .wgsl_strict = true, // these are bedrock — no // ERROR: tolerated
                });
            // Wire the .wgsl as @embedFile-able from wgpu_bringup.zig.
            const wgsl_import_name: []const u8 = b.fmt("{s}.wgsl", .{pair.sh_name});
            if (sh_out.wgsl) |wgsl_lp| {
                wgpu_bringup_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = wgsl_lp });
            }
        }
    }

    const wgpu_bringup_exe: *Compile = b.addExecutable(.{
        .name = "wgpu_bringup",
        .root_module = wgpu_bringup_mod,
    });
    wgpu_bringup_exe.wasi_exec_model = .reactor;
    wgpu_bringup_exe.entry = .disabled;
    wgpu_bringup_exe.rdynamic = true;
    const wgpu_bringup_install: *InstallArtifact = b.addInstallArtifact(wgpu_bringup_exe, .{
        .dest_dir = .{ .override = wgpu_install },
    });
    addWgpuSmoke(b, c2js_exe, wgpu_smoke_install, smoke_focus, wgpu_bringup_exe, "wgpu_bringup");

    // Install the demo's index.html alongside the wasm + js.
    const wgpu_page: LazyPath = bridgePage(b, c2js_exe, wgpu_bringup_exe, "zimr - WebGPU - 2D demo", false, null);
    const wgpu_index_install: *InstallFile = b.addInstallFileWithDir(
        wgpu_page,
        wgpu_install,
        "index.html",
    );

    const wgpu_bringup_step: *Step = b.step(
        "wgpu-bringup",
        "Build the WebGPU demo to zig-out/wgpu/ (Phase 1 of the wgpu migration)",
    );
    wgpu_bringup_step.dependOn(&wgpu_bringup_install.step);
    wgpu_bringup_step.dependOn(&wgpu_index_install.step);

    // ---- bridge-hello: ZIG_BRIDGE_PLAN Phase 1 — the bridge monolith ----
    // src/bridge.zig → C (wasm32-freestanding) → tools c2js → one HTML page.
    // No wasm module, no hand-written JS/HTML anywhere in this chain.
    {
        const to_c: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,       "build-obj",
            "-ofmt=c",             "-target",
            "wasm32-freestanding", "-OReleaseSmall",
        });
        to_c.addFileArg(b.path("src/bridge.zig"));
        const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
        const to_html: *Run = b.addRunArtifact(c2js_exe);
        to_html.setStdIn(.{ .lazy_path = bridge_c });
        to_html.addArgs(&.{ "--html", "--title", "zimr bridge phase-1" });
        const hello_html: LazyPath = to_html.captureStdOut(.{});
        const inst: *std.Build.Step.InstallFile = b.addInstallFile(hello_html, "bridge-hello/bridge_hello.html");
        const step: *std.Build.Step = b.step("bridge-hello", "ZIG_BRIDGE Phase 1: the Zig bridge monolith as a page");
        step.dependOn(&inst.step);
    }

    // ---- bridge-slice: Phase 2 — the app owns the page (D9–D11) ----
    {
        const app_wasm: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,           "build-exe",
            "-target",                 "wasm32-freestanding",
            "-OReleaseSmall",          "-fno-entry",
            "--export=zimr_page_main", "--export=zimr_frame",
        });
        app_wasm.addFileArg(b.path("examples/bridge_slice/bridge_slice.zig"));
        const wasm_out: LazyPath = app_wasm.addPrefixedOutputFileArg("-femit-bin=", "bridge_slice.wasm");
        const to_c: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,       "build-obj",
            "-ofmt=c",             "-target",
            "wasm32-freestanding", "-OReleaseSmall",
        });
        to_c.addFileArg(b.path("src/bridge.zig"));
        const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
        const to_html: *Run = b.addRunArtifact(c2js_exe);
        to_html.addArgs(&.{
            "--html",
            "--title",
            "zimr — the app owns the page",
            "--wasm-embed",
        });
        to_html.addFileArg(wasm_out);
        to_html.setStdIn(.{ .lazy_path = bridge_c });
        const page: LazyPath = to_html.captureStdOut(.{});
        const inst: *std.Build.Step.InstallFile = b.addInstallFile(page, "bridge-slice/bridge_slice.html");
        const step: *std.Build.Step = b.step("bridge-slice", "ZIG_BRIDGE Phase 2: app-owned page, two live canvases");
        step.dependOn(&inst.step);
    }

    // ---- bridge-classic-probe: Phase 3a — the classic zimr contract ----
    {
        const app_wasm: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,        "build-exe",
            "-target",              "wasm32-wasi",
            "-mexec-model=reactor", "-OReleaseSmall",
            "--export=update",
        });
        app_wasm.addFileArg(b.path("examples/bridge_classic_probe/bridge_classic_probe.zig"));
        const wasm_out: LazyPath = app_wasm.addPrefixedOutputFileArg("-femit-bin=", "bridge_classic_probe.wasm");
        const to_c: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,       "build-obj",
            "-ofmt=c",             "-target",
            "wasm32-freestanding", "-OReleaseSmall",
        });
        to_c.addFileArg(b.path("src/bridge.zig"));
        const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
        const to_html: *Run = b.addRunArtifact(c2js_exe);
        to_html.addArgs(&.{
            "--html",
            "--title",
            "zimr classic probe",
            "--wasm-embed",
        });
        to_html.addFileArg(wasm_out);
        to_html.setStdIn(.{ .lazy_path = bridge_c });
        const page: LazyPath = to_html.captureStdOut(.{});
        const inst: *std.Build.Step.InstallFile =
            b.addInstallFile(page, "bridge-classic-probe/bridge_classic_probe.html");
        const step: *std.Build.Step =
            b.step("bridge-classic-probe", "ZIG_BRIDGE Phase 3a: classic zimr contract probe");
        step.dependOn(&inst.step);
    }

    // ---- wgpu-standalone: the 2D demo as a single self-contained HTML ----
    // Same one-call helper as the cube — a second consumer proving the
    // standalone generalizes across wgpu demos (any future demo is one call).
    _ = addWgpuStandalone(
        b,
        c2js_exe,
        wgpu_bringup_exe,
        "wgpu_bringup.html",
        "zimr · WebGPU · 2D demo",
        "standalone",
        "Build the 2D wgpu demo as a single self-contained HTML (no Python)",
        null,
    );

    // ---- wgpu-shapes: the first 2D drawing demo on WebGPU (N5a gate) ----
    // Drives the WgpuGl adapter (f.gl) via z.beginDrawing/drawRectangle/
    // drawCircle — the same free-function shape as a GL example. Proves WgpuGl
    // renders real 2D geometry on-screen (retires N4's "visual pending").
    // ---- wgpu example apps: one table, one builder ----------------------
    // Every servable wgpu demo is a row in `wgpu_apps`. `ctx.addApp` unifies
    // the old addWgpuApp / addWgpuShaderApp split: an empty `.shaders` is just
    // a no-op loop. Bespoke examples that need build-time wiring (asset baking,
    // engine-shader embeds) set a `.configure` hook instead of growing this
    // struct — see configureHelmetSw. Examples that own their GPU frame (cube,
    // lambert, pbr, gltf) don't fit the runner contract and stay manual above.
    // Pre-filter the engine shaders that emitted WGSL into (name, path) pairs so
    // the `wireEngineWgsl` configure helper can embed them. (engine_shaders is
    // fully populated by here — the own-frame demos above already read it.)
    var engine_wgsl_list: ArrayList(EngineWgsl) = .empty;
    for (engine_shaders.items) |s| {
        if (s.wgsl_path) |wgsl_path| {
            engine_wgsl_list.append(b.allocator, .{ .name = s.wgsl_name.?, .path = wgsl_path }) catch @panic("oom");
        }
    }
    // Shared modules so common source files (common.zig, the fonts/ogg, and any
    // shader used by multiple examples) live in exactly ONE module across the
    // build. A launcher that imports many example modules into one binary would
    // otherwise put the same source file in two modules (a hard error). The
    // shader cache is lazy: a shader's modules are built only when an app that
    // uses it is wired, so a standalone exe still compiles only its own shaders.
    const shared_common_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/example_common/example_common.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    shared_common_mod.addImport("zimr", zimr_mod);
    shared_common_mod.addImport("zm", zimrmath_mod);
    const shared_roboto_mod: *Module = b.createModule(.{
        .root_source_file = b.path("assets/RobotoMono-Regular.ttf"),
    });
    const shared_atkinson_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/assets/fonts/atkinson_mono.ttf"),
    });
    const shared_wav_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/assets/test_sine.wav"),
    });
    const shared_ogg_mod: *Module = b.createModule(.{
        .root_source_file = b.path("assets/sample.ogg"),
    });
    var shader_cache = std.StringHashMap(ShaderDep).init(b.allocator);

    const wgpu_app_ctx: AppContext = .{
        .b = b,
        .wgpu_smoke_install = wgpu_smoke_install,
        .smoke_focus = smoke_focus,
        .wasm_target = wasm_target,
        .optimize = optimize,
        .zimr_mod = zimr_mod,
        .zimrmath_mod = zimrmath_mod,
        .kompute_mod = kompute_mod,
        .shader_interface_mod = shader_interface_mod,
        .buildaux_exe = buildaux_exe,
        .c2js_exe = c2js_exe,
        .shader_pipeline = &shader_pipeline,
        .engine_wgsl = engine_wgsl_list.items,
        .mesh_bake_exe = mesh_bake_exe,
        .common_mod = shared_common_mod,
        .roboto_mod = shared_roboto_mod,
        .atkinson_mod = shared_atkinson_mod,
        .ogg_mod = shared_ogg_mod,
        .wav_mod = shared_wav_mod,
        .shader_cache = &shader_cache,
        .build_opts_wgpu = build_opts_wgpu,
        .build_opts_zm = build_opts_zm,
    };
    const wgpu_apps = [_]App{
        .{ .name = "ui_mini_plot_smoke", .title = "zimr - miniPlot smoke test" },
        .{ .name = "ui_kanban_board", .title = "Migrate auth to OAuth2" },
        .{ .name = "ui_drag_drop_demo", .title = "zimr - UI drag-drop demo" },
        .{ .name = "ui_tables_scroll", .title = "zimr - UI tables scroll" },
        .{ .name = "ui_polish", .title = "zimr - UI polish" },
        .{ .name = "keys", .title = "zimr - WebGPU - keys" },
        .{ .name = "input_multitouch", .title = "zimr - WebGPU - input multitouch" },
        .{ .name = "touch_paint", .title = "zimr - WebGPU - touch paint" },
        .{ .name = "input_virtual_controls", .title = "zimr - WebGPU - input virtual controls" },
        .{ .name = "ui_widgets_data_types", .title = "zimr - WebGPU - input data types" },
        .{ .name = "text_field", .title = "zimr - WebGPU - text field" },
        .{ .name = "ui_code_editor", .title = "zimr - WebGPU - code editor" },
        .{ .name = "ui_log_viewer", .title = "zimr - WebGPU - log viewer" },
        .{ .name = "ui_data_grid_phone", .title = "zimr - data grid phone" },
        .{ .name = "ui_imgui_extras", .title = "zimr - UI imgui extras" },
        .{ .name = "ui_input_callbacks", .title = "zimr - ui_input_callbacks (Phase A4)" },
        .{ .name = "ui_shortcuts", .title = "zimr - ui shortcuts (B2 capstone)" },
        .{ .name = "ui_mouse_drag", .title = "zimr - ui mouse drag (B1 capstone)" },
        .{ .name = "ui_custom_rendering", .title = "zimr - UI custom rendering" },
        .{ .name = "ui_plot", .title = "zimr - interactive plot" },
        .{ .name = "plot_demo", .title = "zimr - plot demo" },
        .{ .name = "plot3d_demo", .title = "zimr - 3D plot demo" },
        .{ .name = "plot3d_gallery", .title = "zimr - 3D plot gallery" },
        .{ .name = "ui_primitives_zoo_phone", .title = "zimr - primitives zoo (phone)" },
        .{ .name = "ui_persistence", .title = "zimr - UI persistence" },
        .{ .name = "ui_dev_tools", .title = "zimr - Devtools (P2.4)" },
        .{ .name = "ui_input_query_demo", .title = "zimr - input query" },
        .{ .name = "imgui_phone_demo", .title = "zimr - phone demo" },
        .{ .name = "ui_dock_basic", .title = "zimr - Docking demo" },
        .{ .name = "ui_dock_persistence", .title = "zimr - Docking persistence" },
        .{ .name = "ui_input_flags_zoo_phone", .title = "zimr - input flags zoo (phone)" },
        .{ .name = "ui_notes_phone", .title = "zimr - notes scratchpad (Q8)" },
        .{ .name = "ui_full_showcase", .title = "zimr - UI full showcase" },
        .{ .name = "comptime_julia", .title = "zimr - WebGPU - comptime Julia" },
        .{ .name = "julia_gallery", .title = "zimr - WebGPU - Julia gallery" },
        .{ .name = "double_pendulum", .title = "zimr - WebGPU - double pendulum" },
        .{ .name = "ecs_solar_system", .title = "zimr - WebGPU - ECS solar system" },
        .{ .name = "particles", .title = "zimr - WebGPU - particles + real ImGui" },
        .{ .name = "shapes_demo", .title = "zimr - WebGPU - 2D shapes (WgpuGl)" },
        .{ .name = "scissor_test", .title = "zimr - core - scissor test" },
        .{ .name = "random_values", .title = "zimr - core - generate random values" },
        .{ .name = "random_sequence", .title = "zimr - core - random sequence" },
        .{ .name = "delta_time", .title = "zimr - core - delta time" },
        .{ .name = "text_font_loading", .title = "zimr - text - font loading" },
        .{ .name = "undo_redo", .title = "zimr - core - undo / redo" },
        .{ .name = "smooth_pixelperfect", .title = "zimr - core - smooth pixel-perfect" },
        .{ .name = "viewport_scaling", .title = "zimr - core - viewport scaling (letterbox)" },
        .{ .name = "text_codepoints_loading", .title = "zimr - text - codepoints loading" },
        .{ .name = "text_font_filters", .title = "zimr - text - font filters" },
        .{ .name = "text_inline_styling", .title = "zimr - text - inline styling" },
        .{ .name = "text_unicode_ranges", .title = "zimr - text - unicode ranges" },
        .{ .name = "text_strings_management", .title = "zimr - text - strings management" },
        .{ .name = "shapes_procedural", .title = "zimr - shapes - procedural (trail + tree)" },
        .{ .name = "shapes_top_down_lights", .title = "zimr - shapes - top-down lights" },
        .{ .name = "audio_sound_lab", .title = "zimr - audio - sound lab" },
        .{ .name = "audio_spectrum_visualizer", .title = "zimr - audio - spectrum visualizer" },
        .{ .name = "audio_amp_envelope", .title = "zimr - audio - amp envelope" },
        .{ .name = "ui_animation_gallery", .title = "zimr - animation gallery" },
        .{ .name = "ui_canvas_demo", .title = "zimr - canvas demo" },
        .{ .name = "ui_clipper", .title = "zimr - ui_clipper (Phase A2: 100k-row virtualization)" },
        .{ .name = "ui_demo", .title = "zimr - WebGPU - UI demo (real ImGui)" },
        .{ .name = "ui_drawlists", .title = "zimr - WebGPU - UI drawlists" },
        .{ .name = "ui_minimal_one_context", .title = "zimr - WebGPU - minimal one-context" },
        .{ .name = "ui_smoke_button", .title = "zimr - WebGPU - UI smoke (button)" },
        .{ .name = "ui_tabbar_tour", .title = "zimr - WebGPU - UI TabBar tour" },
        .{ .name = "ui_tables_basic", .title = "zimr - WebGPU - UI tables basic" },
        .{ .name = "kaleidoscope", .title = "zimr - WebGPU - kaleidoscope" },
        .{ .name = "starfield", .title = "zimr - WebGPU - starfield" },
        .{ .name = "raytracer", .title = "zimr - ray tracer (CPU)" },
        .{ .name = "sidebyside", .title = "zimr - CPU | GPU side-by-side" },
        .{ .name = "julia", .title = "zimr - WebGPU - Julia set", .shaders = &.{ "julia_fs", "trivial_vs" } },
        .{
            .name = "mandel_julia",
            .title = "zimr - WebGPU - Mandelbrot/Julia morph",
            .shaders = &.{ "mandel_julia_fs", "trivial_vs" },
        },
        .{
            .name = "mandel_sidebyside",
            .title = "zimr - WebGPU - Mandelbrot CPU|GPU",
            .shaders = &.{ "mandelbrot_fs", "trivial_vs" },
        },
        .{
            .name = "rt_shader",
            .title = "zimr - WebGPU - raytracer (GPU shader)",
            .shaders = &.{ "rt_fs", "trivial_vs" },
        },
        .{
            .name = "rt_sidebyside",
            .title = "zimr - WebGPU - ray tracer CPU|GPU",
            .shaders = &.{ "rt_fs", "trivial_vs" },
        },
        .{
            .name = "cube_sidebyside",
            .title = "zimr - WebGPU - ray cube CPU|GPU|comptime",
            .shaders = &.{ "raycube_fs", "trivial_vs" },
        },
        .{
            .name = "shadow_sidebyside",
            .title = "zimr - WebGPU - ray shadows CPU|GPU|comptime",
            .shaders = &.{ "rayshadow_fs", "trivial_vs" },
        },
        .{ .name = "ui_drag_drop_source", .title = "zimr - UI drag-drop source" },
        .{ .name = "ui_log_skeleton", .title = "zimr - log_viewer skeleton" },
        .{ .name = "ui_tables_demo", .title = "zimr - UI tables demo" },
        .{ .name = "ui_drag_drop_flags_tour", .title = "zimr - DragDropFlags + ItemFlags tour" },
        .{ .name = "ui_multiselect_finder", .title = "zimr - multi-select finder" },
        .{ .name = "ui_dock_simple", .title = "zimr - WebGPU - docking" },
        .{ .name = "simple_particles", .title = "zimr - WebGPU - particles" },
        .{ .name = "math_sine_cosine", .title = "zimr - WebGPU - sine & cosine" },
        .{ .name = "lines_bezier", .title = "zimr - WebGPU - bezier" },
        .{ .name = "cube3d", .title = "zimr - WebGPU - 3D cube" },
        .{ .name = "voxel", .title = "zimr - WebGPU - basic voxel (tap to break)" },
        .{ .name = "waving_cubes", .title = "zimr - WebGPU - waving cubes" },
        .{ .name = "orthographic_projection", .title = "zimr - WebGPU - orthographic projection" },
        .{ .name = "camera_controls", .title = "zimr - WebGPU - camera controls" },
        .{ .name = "tesseract_view", .title = "zimr - WebGPU - tesseract view" },
        .{ .name = "directional_billboard", .title = "zimr - WebGPU - directional billboard" },
        .{ .name = "yaw_pitch_roll", .title = "zimr - WebGPU - yaw pitch roll" },
        .{ .name = "decals", .title = "zimr - WebGPU - decals" },
        .{ .name = "depth_cue", .title = "zimr - WebGPU - depth cue" },
        .{ .name = "models3d", .title = "zimr - WebGPU - 3D primitives" },
        .{ .name = "wireframe", .title = "zimr - WebGPU - wireframe" },
        .{ .name = "models_geometric_shapes", .title = "zimr - models - geometric shapes" },
        .{
            .name = "vertex_texture_test",
            .title = "zimr - shaders - vertex texture fetch",
            .shaders = &.{ "vertex_texture_test_vs", "vertex_texture_test_fs" },
        },
        .{
            .name = "shaders_vertex_displacement",
            .title = "zimr - shaders - vertex displacement",
            .shaders = &.{ "shaders_vertex_displacement_vs", "shaders_vertex_displacement_fs" },
        },
        .{ .name = "dynamic_mesh", .title = "zimr - WebGPU - dynamic mesh" },
        .{ .name = "zimrphysics_demo", .title = "zimr - WebGPU - zimrphysics demo" },
        .{ .name = "zimrphysics2d_demo", .title = "zimr - WebGPU - zimrphysics2d demo" },
        .{ .name = "physics_sidebyside", .title = "zimr - WebGPU - 2D | 3D physics side by side" },
        .{ .name = "instancing", .title = "zimr - WebGPU - instancing" },
        .{ .name = "gestures_demo", .title = "zimr - WebGPU - gestures" },
        .{ .name = "gestures_testbed", .title = "zimr - WebGPU - gestures testbed" },
        .{ .name = "png_demo", .title = "zimr - WebGPU - png demo" },
        // The jobs flagship: the same `codecs.png.encode`, on the main thread (233 ms of
        // frozen frame) and on a Web Worker (17 ms worst frame gap). One extra field on
        // the spec is the entire opt-in.
        .{
            .name = "worker_png",
            .title = "zimr - jobs - PNG encode on a worker",
            .job_kernels = true,
        },
        // THE FLAGSHIP. One 7-line Zig function on four machines: comptime, CPU main
        // thread, CPU worker, GPU. It is the only example that wants BOTH opt-ins at once —
        // `compute_kernels` gives it .cpu and .gpu, `job_kernels` gives it .worker — and
        // that is the point: the same module, `escape_kernel.zig`, feeds all three.
        // The first thing that uses the pool's PARALLELISM. `pump()` has always fed every
        // free worker off the queue; until `jobs.Group` there was no ergonomic way to hand it
        // more than one job, so nobody ever did.
        .{
            .name = "rt_workers",
            .title = "zimr - jobs - a path tracer across the worker pool",
            .job_kernels = true,
        },
        .{
            .name = "four_ways",
            .title = "zimr - one function, four machines",
            .compute_kernels = &.{.{ .basename = "escape_kernel", .entries = &.{"mandel"} }},
            .job_kernels = true,
        },
        .{ .name = "procgen_noise", .title = "zimr - WebGPU - procgen noise" },
        .{ .name = "image_editor", .title = "zimr - WebGPU - image editor" },
        .{ .name = "textured_curve", .title = "zimr - WebGPU - textured curve" },
        .{ .name = "basic", .title = "zimr - WebGPU - basic" },
        .{ .name = "ui_minimal_button", .title = "zimr - WebGPU - minimal button" },
        .{ .name = "ui_phone_gestures", .title = "zimr - WebGPU - phone gestures" },
        .{ .name = "text_layout", .title = "zimr - WebGPU - text layout" },
        .{ .name = "audio_basic", .title = "zimr - WebGPU - audio basic" },
        .{ .name = "composer_drum", .title = "zimr - WebGPU - composer drum" },
        .{ .name = "audio_stream_synth", .title = "zimr - WebGPU - audio stream synth" },
        .{ .name = "music_streaming", .title = "zimr - WebGPU - music streaming" },
        .{ .name = "ui_panes", .title = "zimr - WebGPU - panes" },
        .{ .name = "textured_cube", .title = "zimr - WebGPU - textured cube" },
        .{ .name = "billboards", .title = "zimr - WebGPU - billboards" },
        .{ .name = "text_on_texture", .title = "zimr - WebGPU - text on texture" },
        .{ .name = "skybox", .title = "zimr - WebGPU - skybox" },
        .{ .name = "split_screen", .title = "zimr - WebGPU - split screen: two cameras, one world" },
        .{ .name = "first_person_camera", .title = "zimr - WebGPU - first-person camera" },
        .{ .name = "texture_readback", .title = "zimr - WebGPU - texture readback (GPU to CPU to GPU)" },
        .{ .name = "skinned_mesh", .title = "zimr - WebGPU - skinned mesh (CPU skinning)" },
        .{ .name = "ui_color_picker", .title = "zimr - WebGPU - UI color picker" },
        .{ .name = "ui_custom_widget", .title = "zimr - WebGPU - UI custom widget" },
        .{ .name = "ui_plotting_basic", .title = "zimr - WebGPU - UI plotting" },
        .{ .name = "ui_combo_custom", .title = "zimr - WebGPU - UI combo" },
        .{ .name = "starfield_effect", .title = "zimr - WebGPU - starfield effect" },
        .{ .name = "gallery_all", .title = "zimr - WebGPU - multi-app gallery" },
        .{ .name = "ui_pomodoro_phone", .title = "zimr - WebGPU - Pomodoro (phone)" },
        .{ .name = "ui_window_menubar", .title = "zimr - WebGPU - per-window menu bar" },
        .{ .name = "gallery", .title = "zimr - WebGPU - gallery (4 sub-apps)" },
        .{ .name = "camera2d", .title = "zimr - WebGPU - camera2d" },
        .{ .name = "ecs_boids", .title = "zimr - WebGPU - ECS boids" },
        .{ .name = "render_texture", .title = "zimr - WebGPU - render texture" },
        .{ .name = "textures_background_scrolling", .title = "zimr - WebGPU - textures background scrolling" },
        .{ .name = "textures_sprite_animation", .title = "zimr - WebGPU - textures sprite animation" },
        .{ .name = "textures_image_rotate", .title = "zimr - WebGPU - textures image rotate" },
        .{ .name = "textures_image_channel", .title = "zimr - WebGPU - textures image channel" },
        .{ .name = "textures_sprite_stacking", .title = "zimr - WebGPU - textures sprite stacking" },
        .{ .name = "textures_tiled_drawing", .title = "zimr - WebGPU - textures tiled drawing" },
        .{ .name = "textures_raw_data", .title = "zimr - WebGPU - textures raw data" },
        .{ .name = "textures_polygon_drawing", .title = "zimr - WebGPU - textures polygon drawing" },
        .{ .name = "textures_screen_buffer", .title = "zimr - WebGPU - textures screen buffer" },
        .{ .name = "textures_fog_of_war", .title = "zimr - WebGPU - textures fog of war" },
        .{ .name = "textures_blend_modes", .title = "zimr - WebGPU - textures blend modes" },
        .{ .name = "textures_magnifying_glass", .title = "zimr - WebGPU - textures magnifying glass" },
        .{ .name = "textures_sprite_explosion", .title = "zimr - WebGPU - textures sprite explosion" },
        .{ .name = "textures_bunnymark", .title = "zimr - WebGPU - textures bunnymark" },
        .{ .name = "textures_sprite_button", .title = "zimr - WebGPU - textures sprite button" },
        .{ .name = "textures_mouse_painting", .title = "zimr - WebGPU - textures mouse painting" },
        .{ .name = "textures_npatch_drawing", .title = "zimr - WebGPU - textures N-patch drawing" },
        .{ .name = "textures_framebuffer_rendering", .title = "zimr - WebGPU - textures framebuffer rendering" },
        .{ .name = "draw2d_demo", .title = "zimr - draw2d immediate surface" },
        .{ .name = "textures_image_text", .title = "zimr - WebGPU - textures image text" },
        .{ .name = "trails", .title = "zimr - WebGPU - render texture trails" },
        .{ .name = "recursive_hud", .title = "zimr - WebGPU - recursive HUD" },
        .{ .name = "fractal_tree", .title = "zimr - WebGPU - fractal tree" },
        .{ .name = "math_angle_rotation", .title = "zimr - WebGPU - math angle rotation" },
        .{ .name = "triangle_gradient", .title = "zimr - WebGPU - triangle gradient" },
        .{
            .name = "pipeline_basic",

            .title = "zimr - WebGPU - pipeline basic",

            .shaders = &.{ "pipeline_basic_vs", "pipeline_basic_fs" },
        },
        .{
            .name = "pipeline_uniforms",
            .title = "zimr - WebGPU - pipeline uniforms",
            .shaders = &.{ "pipeline_uniforms_vs", "pipeline_uniforms_fs" },
        },
        .{
            .name = "vao_multibuffer",
            .title = "zimr - WebGPU - vao multibuffer",
            // Reuses the pipeline_uniforms shaders (same schema; this example's
            // lesson is the multi-buffer split, not the shader).
            .shaders = &.{ "pipeline_uniforms_vs", "pipeline_uniforms_fs" },
        },
        .{
            .name = "pipeline_instancing",
            .title = "zimr - WebGPU - pipeline instancing",
            .shaders = &.{ "instancing_vs", "pipeline_uniforms_fs" },
        },
        .{ .name = "pipeline_constants", .title = "zimr - WebGPU - pipeline constants" },
        .{
            .name = "pipeline_rendertarget",
            .title = "zimr - WebGPU - pipeline render target",
            // Reuses the pipeline_uniforms shaders (same transform shader; the
            // lesson is the offscreen render + composite, not the shader).
            .shaders = &.{ "pipeline_uniforms_vs", "pipeline_uniforms_fs" },
        },
        .{
            .name = "pipeline_postprocess",
            .title = "zimr - WebGPU - pipeline postprocess",
            // Scene reuses the pipeline_uniforms shaders; post = fullscreen
            // trivial VS + the new sampler FS (first texture through loadShaderVF).
            .shaders = &.{ "pipeline_uniforms_vs", "pipeline_uniforms_fs", "trivial_vs", "postprocess_post_fs" },
        },
        .{
            .name = "pipeline_bloom",
            .title = "zimr - WebGPU - pipeline bloom",
            .shaders = &.{
                "bloom_fullscreen_vs",
                "bloom_bright_fs",
                "bloom_blur_fs",
                "bloom_composite_fs",
            },
        },
        .{
            .name = "pipeline_settings",
            .title = "zimr - WebGPU - pipeline settings",
            // Bespoke VS + the shared pass-through FS from pipeline_uniforms.
            .shaders = &.{ "pipeline_settings_vs", "pipeline_uniforms_fs" },
        },
        .{ .name = "pipeline_storage", .title = "zimr - WebGPU - pipeline storage" },
        .{
            .name = "pipeline_msaa",
            .title = "zimr - WebGPU - pipeline MSAA",
            .shaders = &.{ "pipeline_msaa_vs", "pipeline_msaa_fs" },
        },
        .{ .name = "pipeline_sampler", .title = "zimr - WebGPU - pipeline sampler" },
        .{ .name = "pipeline_mipmap", .title = "zimr - WebGPU - pipeline mipmap" },
        .{ .name = "pipeline_array", .title = "zimr - WebGPU - pipeline array" },
        .{ .name = "forward_kinematics", .title = "zimr - WebGPU - forward kinematics" },
        .{ .name = "shader_inspection", .title = "zimr - WebGPU - shader inspection" },
        .{ .name = "rectangle_scaling", .title = "zimr - WebGPU - rectangle scaling" },
        .{ .name = "vector_angle", .title = "zimr - WebGPU - vector angle" },
        .{ .name = "lines_drawing", .title = "zimr - WebGPU - lines drawing" },
        .{ .name = "dashed_line", .title = "zimr - WebGPU - dashed line" },
        .{ .name = "ring_drawing", .title = "zimr - WebGPU - ring drawing" },
        .{ .name = "circle_sector_drawing", .title = "zimr - WebGPU - circle sector drawing" },
        .{ .name = "rounded_rectangle", .title = "zimr - WebGPU - rounded rectangle" },
        .{ .name = "pie_chart", .title = "zimr - WebGPU - pie chart" },
        .{ .name = "triangle_strip", .title = "zimr - WebGPU - triangle strip" },
        .{ .name = "rectangle_advanced", .title = "zimr - WebGPU - rectangle advanced" },
        .{ .name = "splines_drawing", .title = "zimr - WebGPU - splines drawing" },
        .{ .name = "following_eyes", .title = "zimr - WebGPU - following eyes" },
        .{ .name = "digital_clock", .title = "zimr - WebGPU - digital clock" },
        .{ .name = "clock_of_clocks", .title = "zimr - WebGPU - clock of clocks" },
        .{ .name = "penrose_tile", .title = "zimr - WebGPU - penrose tile" },
        .{ .name = "color_wheel", .title = "zimr - WebGPU - color wheel" },
        .{ .name = "logo_raylib", .title = "zimr - WebGPU - logo" },
        .{ .name = "logo_raylib_anim", .title = "zimr - WebGPU - logo anim" },
        .{ .name = "bullet_hell", .title = "zimr - WebGPU - bullet hell" },
        .{ .name = "cellular_automata", .title = "zimr - WebGPU - cellular automata" },
        .{ .name = "srcrec_dstrec", .title = "zimr - WebGPU - srcrec dstrec" },
        .{ .name = "writing_anim", .title = "zimr - WebGPU - writing anim" },
        .{ .name = "3d_probe", .title = "zimr - WebGPU - 3D probe" },
        .{ .name = "shapes_showcase", .title = "zimr - WebGPU - shapes showcase" },
        .{ .name = "hello_world", .title = "zimr - WebGPU - hello world" },
        .{ .name = "life", .title = "zimr - WebGPU - life" },
        .{ .name = "colors_palette", .title = "zimr - WebGPU - colors" },
        .{ .name = "easings_ball", .title = "zimr - WebGPU - easings" },
        .{ .name = "input_keys", .title = "zimr - WebGPU - input keys" },
        .{ .name = "input_mouse_wheel", .title = "zimr - WebGPU - mouse wheel" },
        .{ .name = "input_mouse", .title = "zimr - WebGPU - input mouse" },
        .{ .name = "easings_box", .title = "zimr - WebGPU - easings box" },
        .{ .name = "easings_rectangles", .title = "zimr - WebGPU - easings rects" },
        .{ .name = "collision_area", .title = "zimr - WebGPU - collision" },
        .{ .name = "ellipse_collision", .title = "zimr - WebGPU - ellipse collision" },
        .{ .name = "ball_physics", .title = "zimr - WebGPU - ball physics" },
        .{ .name = "easings_testbed", .title = "zimr - WebGPU - easings testbed" },
        .{ .name = "hilbert_curve", .title = "zimr - WebGPU - hilbert" },
        .{ .name = "sph_fluid_2d", .title = "zimr - WebGPU - SPH fluid 2D" },
        .{
            .name = "helmet_sw",
            .title = "zimr - WebGPU - one PBR shader: CPU | GPU",
            .configure = configureHelmetSw,
        },
        .{ .name = "decal_sw", .title = "zimr - WebGPU - one decal shader: CPU | GPU" },
        // Own-frame 3D demos: the example IS the exe and drives its own GPU
        // frame; `.own_frame` routes finishWgpuApp to root the exe at the demo
        // instead of the shared runner. Same declarative glue otherwise.
        .{
            .name = "cube_demo",
            .title = "zimr · WebGPU · 3D depth-tested cube",
            .own_frame = true,
            .shaders = &.{ "cube_split_vs", "cube_split_fs" },
        },
        .{
            .name = "lambert_demo",
            .title = "zimr · WebGPU · Lambert-lit cube",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        .{
            .name = "depth_rendering",
            .title = "zimr - WebGPU - depth rendering",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        .{
            .name = "shadowmap",
            .title = "zimr - WebGPU - shadow map",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "cel_shading",
            .title = "zimr - WebGPU - cel shading + inverted-hull ink",
            .configure = configureCelShading,
        },
        .{
            .name = "depth_writing",
            .title = "zimr - WebGPU - fragment depth writing",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "box_collisions",
            .title = "zimr - WebGPU - box collisions (drag the player)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "cubicmap",
            .title = "zimr - WebGPU - cubicmap maze",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "first_person_maze",
            .title = "zimr - WebGPU - first person maze",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "heightmap",
            .title = "zimr - WebGPU - heightmap terrain",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "point_rendering",
            .title = "zimr - WebGPU - point rendering (1k to 1M points)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "mesh_picking",
            .title = "zimr - WebGPU - mesh picking (tap to pick)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "fog_rendering",
            .title = "zimr - WebGPU - distance fog (shared gbuffer_vs)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "deferred_render",
            .title = "zimr - WebGPU - deferred rendering (MRT G-buffer)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "shader_effects",
            .title = "zimr - WebGPU - 2D shader effects gallery",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "shaders_shapes_textures",
            .title = "zimr - shaders - shapes + textures (BeginShaderMode)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "shaders_multi_texture",
            .title = "zimr - shaders - multi-texture (mask + divider)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "hybrid_render",
            .title = "zimr - WebGPU - hybrid raster + raymarch (shared depth)",
            .configure = wireEngineWgsl,
        },
        .{
            .name = "shadowmap_sw",
            .title = "zimr - WebGPU - one shadow shader: CPU | GPU | comptime",
            .configure = configureShadowmapSw,
        },
        .{
            .name = "pbr_demo",
            .title = "zimr · WebGPU · PBR-lit cube",
            .own_frame = true,
            .configure = configurePbr,
        },
        .{
            .name = "gltf_textured",
            .title = "zimr - WebGPU - textured glTF quad",
            .own_frame = true,
            .configure = configureGltfTextured,
        },
        .{
            .name = "gltf_simple",
            .title = "zimr - WebGPU - glTF simple",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        .{
            .name = "obj_simple",
            .title = "zimr - WebGPU - OBJ simple",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        .{
            .name = "obj_bunny",
            .title = "zimr - WebGPU - OBJ bunny",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        .{
            .name = "damaged_helmet",
            .title = "zimr - WebGPU - damaged helmet",
            .own_frame = true,
            .configure = wireEngineWgsl,
        },
        // Compute apps: regular examples that opt into GPU compute via
        // `.compute_kernels`. No separate list or builder — adding compute to any
        // example above is just adding this one field.
        .{
            .name = "compute_smoke",
            .title = "zimr - WebGPU - compute smoke",
            .compute_kernels = &.{.{ .basename = "double_it" }},
        },
        .{
            .name = "shared_smoke",
            .title = "zimr - WebGPU - shared memory smoke",
            .compute_kernels = &.{.{ .basename = "shared_rotate" }},
        },
        // Does the counting sort actually sort? Runs the SAME five kernels on the CPU (plain
        // Zig) and the GPU (SPIR-V -> WGSL) over 64 particles whose answer is known, and
        // checks every stage. A CPU/GPU disagreement convicts the toolchain; a matching
        // failure convicts the algorithm. Nothing else in the tree separates those.
        .{
            .name = "sort_smoke",
            .title = "zimr - WebGPU - counting sort smoke",
            .compute_kernels = &.{.{
                .basename = "sort_min",
                .entries = &.{
                    "clearGrid",    "countGrid",   "prefixSum",
                    "scatter",      "copyback",    "computeDensity",
                    "computeForce", "computeVisc", "applyMini",
                },
            }},
        },
        .{
            .name = "tile_smoke",
            .title = "zimr - WebGPU - tiling smoke",
            .compute_kernels = &.{.{
                .basename = "tile_gather",
                .entries = &.{ "tileClearGrid", "tileBuildGrid", "gatherTiled" },
            }},
        },
        .{
            .name = "compute_particles",
            .title = "zimr - WebGPU - compute particles",
            .compute_kernels = &.{.{ .basename = "particle_step" }},
        },
        .{
            .name = "fluid_gpu",
            .title = "zimr - WebGPU - 20k GPU fluid",
            .compute_kernels = &.{.{
                .basename = "fluid_kernels",
                .entries = &.{
                    "clearGrid", "buildGrid", "gravityMouse",     "viscosity",
                    "predict",   "density",   "densityTiled",     "densityPig",
                    "force",     "forcePig",  "applyAndFinalize", "fallBounceLean",
                },
            }},
        },
        // The sorted twin: same fluid, neighbour grid built by a spatial counting
        // sort (clearGrid -> countGrid -> prefixSum -> scatter -> copyback) so
        // density/force/viscosity read cell-contiguous (coalesced) memory.
        .{
            .name = "fluid_sort",
            .title = "zimr - WebGPU - 20k GPU fluid (sorted)",
            .compute_kernels = &.{.{
                .basename = "sort_kernels",
                .entries = &.{
                    "paramEcho", "clearGrid", "countGrid",    "prefixSum",
                    "scatter",   "copyback",  "gravityMouse", "viscosity",
                    "predict",   "density",   "force",        "applyAndFinalize",
                },
            }},
        },
    };
    var app_mods = std.StringHashMap(*Module).init(b.allocator);
    for (wgpu_apps) |wgpu_app| {
        const m: *Module = wgpu_app_ctx.buildAppModule(wgpu_app);
        // `job_kernels` is the whole opt-in: the example's kernels.zig ALSO becomes a
        // separate, freestanding, zero-import wasm for the Web Workers, inlined into the
        // page beside the app's own. Nothing else about the example moves.
        const kernel_wasm: ?LazyPath = if (wgpu_app.job_kernels)
            buildJobKernels(b, wgpu_app.name, &.{}, optimize, build_opts_wgpu, build_opts_zm)
        else
            null;
        _ = finishWgpuApp(
            b,
            c2js_exe,
            wgpu_smoke_install,
            smoke_focus,
            wasm_target,
            optimize,
            zimr_mod,
            zimrmath_mod,
            shader_interface_mod,
            buildaux_exe,
            m,
            wgpu_app.name,
            wgpu_app.title,
            wgpu_app.own_frame,
            kernel_wasm,
        );
        app_mods.put(wgpu_app.name, m) catch @panic("oom");
    }

    // ---- wgpu-launcher: the flagship example switcher ----------------------
    // A fullscreen host that imports several example MODULES by name and ticks
    // one at a time (z.Launcher). Each module is self-contained (its shaders /
    // fonts / compute kernels are in its own import table), so the launcher just
    // aggregates their `app` AppSpecs. Adding an example = one name in flagships
    // (and the matching @import in examples/launcher). Built here, after the
    // compute apps, so fluid_sort is available in app_mods.
    {
        const launcher_mod: *Module = wgpu_app_ctx.buildUserModShared("launcher");

        // A REAL kernel wasm for the launcher, so `worker_png` encodes off-thread here just
        // as it does standalone. `examples/launcher/kernels.zig` owns the merged registry.
        //
        // `four_ways` IS on this page now, and the reason it could not be is worth keeping.
        //
        // It is the only example with BOTH `compute_kernels` and `job_kernels`, so it was easy
        // to blame the jobs wiring — and I did, twice. The real cause had nothing to do with
        // jobs: `wireComputeKernels` minted a FRESH `kompute` module per example. With one
        // compute example per page that is invisible. A launcher is BY DEFINITION many examples
        // on one page, so Zig saw two distinct modules rooted at the same `src/kompute.zig`,
        // renamed the second `kompute0`, and rejected the file for belonging to both. Its error
        // named `escape_kernel.zig` — the import that tripped over the clash, not the cause.
        //
        // The cap was silent, and it was ONE COMPUTE EXAMPLE PER PAGE. `AppContext` already
        // held a shared `kompute_mod`; the wiring simply never reached for it.
        const launcher_kernels: LazyPath = buildJobKernels(
            b,
            "launcher",
            &.{ "worker_png", "four_ways" },
            optimize,
            build_opts_wgpu,
            build_opts_zm,
        );

        const flagships = [_][]const u8{
            "helmet_sw",
            "shadowmap_sw",
            "decals",
            "deferred_render",
            "cel_shading",
            "fog_rendering",
            "hybrid_render",
            "textures_background_scrolling",
            "ui_full_showcase",
            "zimrphysics_demo",
            "zimrphysics2d_demo",
            "mandel_sidebyside",
            "rt_sidebyside",
            "plot_demo",
            "plot3d_demo",
            "sph_fluid_2d",
            "fluid_sort",
            "four_ways",
            "worker_png",
            "mandel_julia",
            "kaleidoscope",
            "waving_cubes",
            "starfield",
            "shader_effects",
            "gallery_all",
        };
        inline for (flagships) |fname| {
            launcher_mod.addImport("ex_" ++ fname, app_mods.get(fname).?);
        }
        _ = finishWgpuApp(
            b,
            c2js_exe,
            wgpu_smoke_install,
            smoke_focus,
            wasm_target,
            optimize,
            zimr_mod,
            zimrmath_mod,
            shader_interface_mod,
            buildaux_exe,
            launcher_mod,
            "launcher",
            "zimr - launcher",
            false,
            launcher_kernels,
        );
    }

    // stub WebGPU + WASI imports, runs `_initialize` + 60 frames of
    // `update`, verifies no traps and no missing imports.  Catches
    // function signature mismatches between Zig externs and the JS
    // bridge — the kind of bug that would otherwise only surface in
    // the browser, with a confusing "missing import" error.
    const wgpu_smoke_step: *Step = b.step(
        "smoke",
        "Smoke-test the WebGPU demo wasm in Bun (no real GPU needed)",
    );
    // ---- JS test runner: Node (not Bun) -----------------------------------
    // The wasm-execution test harnesses need a JS runtime only for
    // WebAssembly.instantiate + a host import shim; everything else they use
    // is node:fs/crypto/path. Node 22 provides all of it and strips TS types
    // inline, so Bun is not a test dependency. (A pure-Zig wasm runner would
    // mean embedding an interpreter — disproportionate; Node is the simplest
    // ubiquitous thing that runs wasm with JS host functions.)
    // DOGFOODED (Phase 5b): the smoke test LOGIC is webtests/wgpu_smoke.zig,
    // compiled to wasm32 and transpiled to JS by our OWN c2js, then run under
    // Node via webtests/runner.mjs (the only hand-written JS in the path —
    // it does nothing but WebAssembly.instantiate + fs). Byte-identical
    // output to the old .ts, which is now deleted.
    const smoke_logic_to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    smoke_logic_to_c.addFileArg(b.path("webtests/wgpu_smoke.zig"));
    const smoke_logic_c: LazyPath = smoke_logic_to_c.addPrefixedOutputFileArg("-femit-bin=", "wgpu_smoke.c");
    const smoke_logic_to_js: *Run = b.addRunArtifact(c2js_exe);
    smoke_logic_to_js.setStdIn(.{ .lazy_path = smoke_logic_c });
    const smoke_logic_js: LazyPath = smoke_logic_to_js.captureStdOut(.{});
    const wgpu_smoke_cmd: *Run = b.addSystemCommand(&.{ "node", "webtests/runner.mjs" });
    wgpu_smoke_cmd.addFileArg(smoke_logic_js);
    wgpu_smoke_cmd.addArgs(&.{ "--wasm=zig-out/wgpu/wgpu_bringup.wasm", "--frames=60" });
    wgpu_smoke_cmd.step.dependOn(&wgpu_bringup_install.step);
    wgpu_smoke_step.dependOn(&wgpu_smoke_cmd.step);

    // SPIR-V → WGSL transpiler wasm exposed for the corpus test.
    // Standalone wasm that JS can call repeatedly with different
    // SPIR-V inputs.  Used by `webtests/transpiler_corpus.zig` to
    // run the transpiler against every .rewritten.spv in the build cache
    // and report per-shader stats.
    const transpiler_wasm_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/spv2wgsl_wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = false,
    });
    const transpiler_wasm_exe: *Compile = b.addExecutable(.{
        .name = "spv2wgsl",
        .root_module = transpiler_wasm_mod,
    });
    transpiler_wasm_exe.wasi_exec_model = .reactor;
    transpiler_wasm_exe.entry = .disabled;
    transpiler_wasm_exe.rdynamic = true;
    const transpiler_wasm_install: *InstallArtifact = b.addInstallArtifact(transpiler_wasm_exe, .{
        .dest_dir = .{ .override = wgpu_install },
    });

    // The corpus test step: build the transpiler wasm, then run the test
    // LOGIC against every .rewritten.spv in .zig-cache/. Default mode: check
    // against the locked fixture at `tests/fixtures/wgsl_corpus.json` and
    // fail on any drift. See `src/notes/webgpu-migration-plan.md` §3
    // Phase A3 for the regression-corpus design.
    //
    // DOGFOODED (Phase 5c): the test logic is webtests/transpiler_corpus.zig,
    // compiled to wasm32 and transpiled to JS by our OWN c2js, run under Node
    // via webtests/runner.mjs (the only hand-written JS in the path; it does
    // WebAssembly.instantiate + fs + the host primitives the logic drives —
    // listFiles/md5File/fileSize/sutMemWrite/sutMemRead/sutCallPacked/writeFile).
    // The Zig logic does the MD5 of the WGSL itself (std.crypto.hash.Md5) and
    // the placeholder scan; output is byte-identical to the old .ts, now deleted.
    const corpus_logic_to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    corpus_logic_to_c.addFileArg(b.path("webtests/transpiler_corpus.zig"));
    const corpus_logic_c: LazyPath = corpus_logic_to_c.addPrefixedOutputFileArg(
        "-femit-bin=",
        "transpiler_corpus.c",
    );
    const corpus_logic_to_js: *Run = b.addRunArtifact(c2js_exe);
    corpus_logic_to_js.setStdIn(.{ .lazy_path = corpus_logic_c });
    const corpus_logic_js: LazyPath = corpus_logic_to_js.captureStdOut(.{});

    const transpiler_corpus_step: *Step = b.step(
        "corpus",
        "Run spv2wgsl against every .spv in .zig-cache and check fixture",
    );
    const transpiler_corpus_cmd: *Run = b.addSystemCommand(&.{ "node", "webtests/runner.mjs" });
    transpiler_corpus_cmd.addFileArg(corpus_logic_js);
    transpiler_corpus_cmd.step.dependOn(&transpiler_wasm_install.step);
    transpiler_corpus_step.dependOn(&transpiler_corpus_cmd.step);

    // ---- c2js-diff: the transpiler's differential regression gate -----
    // The original webzig transpiler shipped a 100-case differential
    // suite (intake/webzig-all/webzig/tests/cases/*.zig): each case
    // `export fn run_test() i32` returning 0. The gate compiles each case
    // to NATIVE (oracle) and runs it, then transpiles the SAME case
    // through OUR c2js -> JS and runs run_test() under Node, asserting
    // the JS result equals the native result AND that no /*TODO|/*?
    // unhandled-lowering marker reached the output. This is what proves
    // c2js transpiles ARBITRARY Zig correctly, not just zimr's linted
    // subset — which is exactly why these case files are NOT linted
    // (they live under intake/, outside the lint walk roots, and many
    // deliberately use non-house-style constructs to exercise lowerings).
    // The .zig differential script is Node-based on the JS side already;
    // wiring it as a build step (vs the manual /tmp clone used during the
    // bridge arc) gives c2js an automated regression gate. A pure-Zig
    // driver replacing the shell is Phase 5 follow-on work.
    const c2js_diff_step: *Step = b.step(
        "c2js-diff",
        "Differential-test c2js: 100 cases vs native oracle (transpiler regression gate)",
    );
    // sh -c so the shell expands cases/*.zig into the per-file args the
    // script's `for src in "$@"` loop expects (addSystemCommand does no
    // glob expansion). $ZIG and the c2js path are passed in; c2js is the
    // directly-built artifact, installed to a stable bin path the script
    // can reference (the old tools/ sub-build path is gone).
    const c2js_diff_install: *InstallArtifact = b.addInstallArtifact(c2js_exe, .{});
    // Default install prefix is `zig-out`; the script runs from the build
    // root, so the installed binary is at this stable relative path.
    const c2js_diff_bin: []const u8 = "zig-out/bin/c2js";
    const c2js_diff_cmd: *Run = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "exec sh tools/c2js_cases/differential.sh " ++
                "\"$ZIG\" \"{s}\" " ++
                "tools/c2js_cases/oracle_main.zig " ++
                ".zig-cache/c2js-diff tools/c2js_cases/cases/*.zig",
            .{c2js_diff_bin},
        ),
    });
    c2js_diff_cmd.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    c2js_diff_cmd.setEnvironmentVariable("ALLOW_SKIP", "interop");
    // KNOWN_FAIL: empty — all four cases that failed on the current Zig's C-backend
    // output (packed_bitcast, packed_struct_wide, arrays_of_structs,
    // odd_width_aggregate) have been fixed in c2js and now pass. The gate is a clean
    // regression gate: ANY failure is a real regression. If a future Zig C-backend
    // change breaks a case, add its name here (XFAIL, non-fatal) while c2js catches up.
    c2js_diff_cmd.setEnvironmentVariable("KNOWN_FAIL", "");
    c2js_diff_cmd.step.dependOn(&c2js_diff_install.step);
    c2js_diff_step.dependOn(&c2js_diff_cmd.step);

    // Refresh the fixture from the current transpiler output.  Run
    // after a deliberate transpiler change (e.g. a new opcode handler
    // or output reformatting); commit the resulting JSON in the same
    // patch as the change.  Without this step, `wgpu-corpus` would
    // permanently fail on legitimate transpiler improvements.
    const transpiler_corpus_refresh_step: *Step = b.step(
        "corpus-refresh",
        "Refresh tests/fixtures/wgsl_corpus.json from the current spv2wgsl output",
    );
    const transpiler_corpus_refresh_cmd: *Run = b.addSystemCommand(&.{ "node", "webtests/runner.mjs" });
    transpiler_corpus_refresh_cmd.addFileArg(corpus_logic_js);
    transpiler_corpus_refresh_cmd.addArgs(&.{"--refresh-fixture"});
    transpiler_corpus_refresh_cmd.step.dependOn(&transpiler_wasm_install.step);
    transpiler_corpus_refresh_step.dependOn(&transpiler_corpus_refresh_cmd.step);

    // native_target — used by both wgpu-diff (below) and the
    // per-file test loop later.  Declared here at first use; the
    // later for-loop reuses the same value.
    const native_target: ResolvedTarget = b.standardTargetOptions(.{});

    // ---- Differential validator (Phase 0 of spv2wgsl-rewrite-plan).
    // Pure-Zig corpus test that runs spv2wgsl over every shader in
    // `tests/fixtures/external/tint/*.spv` (181 fixtures extracted
    // from Dawn `main`) AND `.zig-cache/o/*/shader.rewritten.spv` (every
    // shader our build has produced), then for each output:
    //   - structurally validates the WGSL via `spv2wgsl/wgsl_check.zig`
    //   - scans for known-bug fingerprints (phi-overwrite-after-if,
    //     `__unresolved_N__`, `// ERROR:` markers)
    //   - tallies and asserts against the recorded baseline
    //
    // No JS, no Node, no npm.  Pure Zig — aligned with the "pure
    // Zig destination" arc of the project.
    //
    //   zig build wgpu-diff
    const transpiler_diff_step: *Step = b.step(
        "corpus-diff",
        "Run the spv2wgsl corpus test (pure Zig; no JS deps)",
    );
    {
        // Use src/tests.zig as the test root (same as `zig build test`)
        // so the corpus test's `@import("../spv2wgsl.zig")` resolves
        // through the existing module tree.  We then filter to just
        // the spv2wgsl corpus tests via --test-filter so the run is
        // fast (without it, this would run every host test in
        // tests.zig).
        const diff_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = native_target,
            .optimize = .Debug,
            .pic = true,
        });
        // Same wiring as the main test_step uses. This module reaches the
        // same host-test graph (tests.zig → render stack), so it needs the
        // identical shader wiring: .glsl placeholders (the real .glsl would
        // run the gated-off spirv-opt path), the .wgsl twins that
        // renderer_2d @embedFiles, the shapes externs modules, AND
        // build_options (ui.zig and the wgpu stack @import it). Previously
        // diff_mod wired only the .glsl names + zm + shader_interface and
        // so failed to compile (missing build_options + .wgsl embeds) —
        // wgpu-diff was silently broken. Mirror test_mod exactly.
        for (engine_shaders.items) |s| {
            const is_glsl: bool = endsWith(u8, s.name, ".glsl");
            const src: std.Build.LazyPath = if (is_glsl)
                b.path("src/shaders/_deleted_glsl_placeholder.glsl")
            else
                s.path;
            diff_mod.addAnonymousImport(s.name, .{ .root_source_file = src });
            if (s.wgsl_path) |wp| {
                diff_mod.addAnonymousImport(s.wgsl_name.?, .{ .root_source_file = wp });
            }
            if (s.sh_name) |sh_name| {
                // Wire every codegen'd externs module (not just the shapes
                // pair): this module is also rooted at src/tests.zig, so if
                // its test filters ever pull in zimr.zig's full shader
                // surface it needs the same externs the host-test module
                // does. Keeping both loops identical avoids re-introducing
                // the "no module named '<name>_externs'" break.
                if (s.externs_path) |externs_path| {
                    const externs_dep_name: []const u8 = b.fmt("{s}_externs", .{sh_name});
                    const externs_mod_d: *Module = b.createModule(.{
                        .root_source_file = externs_path,
                        .target = native_target,
                        .optimize = .ReleaseSafe,
                    });
                    externs_mod_d.addImport("zm", zimrmath_mod);
                    externs_mod_d.addImport("shader_builtins", shader_builtins_mod);
                    diff_mod.addImport(externs_dep_name, externs_mod_d);
                }
            }
        }
        diff_mod.addImport("zm", zimrmath_mod);
        diff_mod.addAnonymousImport("atomic_buildgrid_spv", .{
            .root_source_file = b.path("tests/fixtures/atomics/atomic_buildgrid.spv"),
        });
        diff_mod.addImport("shader_interface", shader_interface_mod);
        diff_mod.addOptions("build_options", build_opts);
        const t: *Compile = b.addTest(.{
            .root_module = diff_mod,
            .filters = &.{
                // Phase 0 — corpus runner + WGSL structural validator
                "spv2wgsl corpus",   "wgsl_check",     "scanBugs",
                // Phase 1.1 — module split scaffolds (types.zig has
                // real tests; block_table/walker/selection/loop/switch
                // are scaffolds whose `scaffold compiles` smoke runs
                // through these filters).
                "Op enum",           "StorageClass",   "BuiltIn",
                "scaffold compiles",
                // Phase 1.3 — BlockTable construction tests.
                "registerBlocks",
                // Phase 2 — walker scaffold + StopSet.
                "emitStopExit",
                "StopSet",           "emitBlock",      "emitBranch",
            },
        });
        const run: *Run = b.addRunArtifact(t);
        run.has_side_effects = true;
        transpiler_diff_step.dependOn(&run.step);
    }

    // ---- Smoke test: load each live wgpu example wasm in Bun and check
    // it boots + ticks frames without trapping (no real GPU needed — the
    // wgpu/dom/wasi imports are stubbed).  By default smoke-test runs the
    // whole wgpu gallery; -Dfocus=<names|prefix*> (or the `tier-a` magic
    // value) narrows it.  The old GL `smoke.ts` gallery was retired with
    // the WebGL backend — this is its wgpu successor.
    // DOGFOODED (Phase 5b): same Zig logic + runner.mjs as wgpu-smoke, in
    // directory mode over the wgpu gallery. Reuses the smoke_logic_js
    // LazyPath transpiled above (c2js output of webtests/wgpu_smoke.zig).
    const smoke_step: *Step = b.step("smoke-test", "Run wgpu wasm smoke tests (Zig logic via c2js + Node)");
    const smoke_cmd: *Run = b.addSystemCommand(&.{ "node", "webtests/runner.mjs" });
    smoke_cmd.addFileArg(smoke_logic_js);
    smoke_cmd.addArg("--web-dir=zig-out/wgpu-smoke/web");
    smoke_cmd.addArg("--frames=60");
    if (smoke_focus.len > 0) {
        // wgpu_smoke.ts doesn't know the `tier-a` magic value (only
        // matchesFocus does), so expand it to the literal wgpu example
        // basenames before passing.  Keep this list in sync with the
        // `tier_a_names` table in matchesFocus — both sides must agree so
        // the build-side install gate and the harness filter select the
        // same wasms.
        const expanded: []const u8 = if (eql(u8, smoke_focus, "tier-a"))
            "wgpu_bringup,cube3d,compute_smoke,shapes_showcase,ui_color_picker," ++
                "mandel_sidebyside,ui_dock_simple,ecs_solar_system"
        else
            smoke_focus;
        const focus_arg: []const u8 = b.fmt("--focus={s}", .{expanded});
        smoke_cmd.addArg(focus_arg);
    }
    // ---- verify-imports gate ------------------------------------------------
    // Every focused example wasm must import only host functions src/bridge.zig
    // actually provides.  The smoke's runner.mjs auto-stubs any missing import
    // (a Proxy), so it CANNOT catch a bridge gap that would LinkError in the
    // browser at WebAssembly.instantiate (`js_set_mouse_cursor` / `js_open_url`
    // shipped exactly this way).  This reads each installed wasm's import section
    // and diffs it against bridge.zig — pure Zig, no Node, no wasm execution.
    // Sits between install and smoke_cmd so a bridge gap fails the smoke.
    const verify_imports_exe: *Compile = b.addExecutable(.{
        .name = "verify_imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/verify_imports.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    const verify_imports_run: *Run = b.addRunArtifact(verify_imports_exe);
    verify_imports_run.addFileArg(b.path("src/bridge.zig"));
    verify_imports_run.addArg("zig-out/wgpu-smoke/web");
    verify_imports_run.step.dependOn(wgpu_smoke_install);
    const verify_imports_step: *Step = b.step(
        "verify-imports",
        "Assert every installed example wasm's host imports are provided by src/bridge.zig",
    );
    verify_imports_step.dependOn(&verify_imports_run.step);

    smoke_cmd.step.dependOn(&verify_imports_run.step);
    smoke_step.dependOn(&smoke_cmd.step);

    // ---- Tier A: the per-turn smoke set --------------------------------
    // Five canonical wgpu examples covering the cross-cutting surface:
    // wgpu_bringup (2D + UI/ImGui), cube3d (3D matrix stack + default
    // VS/FS), compute_smoke (GPU compute round-trip), wgpu_shapes_-
    // showcase (2D shape primitives), ui_color_picker (a UI widget).
    // Three ways to use it:
    //
    //   zig build test -Dfocus=tier-a       — typecheck only (~2s)
    //   zig build smoke-test -Dfocus=tier-a — Bun smoke for tier-a
    //                                          examples (~15s warm)
    //   zig build tier-a-check              — the combined audit
    //                                          (test + smoke + wgpu)
    //
    // `tier-a` is a magic focus value (see matchesFocus) expanding to
    // the five example names.  Full unfocused `zig build test` and
    // `zig build smoke-test` stay for arc-close / cross-cutting-
    // invariant changes; the norm is -Dfocus=tier-a per turn.
    //
    // `tier-a-check` is the canonical per-turn audit gate for arcs
    // that touch cross-cutting code (drawing, ui, math, shader pipe).
    // For wgpu-only arcs, `wgpu-check` is faster.
    // Structure-plan S0 (t1177): DAG-ness is a build gate.  A cycle in
    // src/*.zig fails the audit.  Ported from scripts/check_dag.py to
    // tools/dag_check.zig (t-now): tokenizer-based @import scan (no regex
    // false edges), Tarjan SCC, NO whitelist (the old ui<->zimr allowance
    // went stale), plus an auto-computed DAG layering print.
    const dag_check: *Run = b.addRunArtifact(tools.dag);
    dag_check.addArg("src");
    dag_check.step.name = "dag-check (src import graph is acyclic)";
    const dag_check_step: *Step = b.step("dag-check", "Verify src/*.zig import graph is a DAG");
    dag_check_step.dependOn(&dag_check.step);

    // gen-vscode: regenerate the editor debug/build configs from the
    // example_steps array (Zig port of scripts/build_launch_json.py).
    const gen_vscode_run: *Run = b.addRunArtifact(tools.gen_vscode);
    gen_vscode_run.step.name = "gen-vscode (.vscode/.zed configs from example_steps)";
    const gen_vscode_step: *Step = b.step("gen-vscode", "Regenerate .vscode/.zed debug+task configs");
    gen_vscode_step.dependOn(&gen_vscode_run.step);

    // files-md: regenerate src/notes/files.md, the per-file atlas (Zig port
    // of scripts/gen_files_md.py).
    const gen_files_md_run: *Run = b.addRunArtifact(tools.gen_files_md);
    gen_files_md_run.step.name = "files-md (regenerate src/notes/files.md atlas)";
    const gen_files_md_step: *Step = b.step("files-md", "Regenerate src/notes/files.md atlas");
    gen_files_md_step.dependOn(&gen_files_md_run.step);

    const tier_a_check_step: *Step = b.step(
        "tier-a-check",
        "The combined per-turn audit: test + smoke + wgpu-smoke, all focused on tier-a.",
    );
    // Layer 1: test step depends on the smoke install (which respects
    // -Dfocus internally) only when focus is non-empty.  We synthesize
    // an artifact-dependent step that always forces tier-a focus by
    // using a fresh Run that re-invokes the smoke harness directly,
    // sidestepping the smoke_install_step (which obeys the build
    // command's outer -Dfocus value, not ours).
    //
    // For simplicity: just wire to smoke_install_step + smoke_cmd
    // and require the user to also pass -Dfocus=tier-a.  A future
    // refinement could inject the focus at step-construction time
    // by parameterizing smoke_install_step, but keeping it simple
    // here makes the build graph readable.  The corresponding
    // recipe in `claude.md` instructs:
    //   zig build tier-a-check -Dfocus=tier-a
    tier_a_check_step.dependOn(&dag_check.step);
    tier_a_check_step.dependOn(test_step);
    tier_a_check_step.dependOn(&smoke_cmd.step);
    tier_a_check_step.dependOn(&wgpu_smoke_cmd.step);
    tier_a_check_step.dependOn(&transpiler_corpus_cmd.step);

    // ---- wgpu-check: the minimal wgpu-migration audit gate. ----------
    // Runs the test surface that matters for changes touching
    // `src/spv2wgsl.zig`, `src/wgpu.zig`, `tools/zspv_rewrite.zig`, the
    // engine shapes shader, or anything else in the wgpu plan.  Skips
    // the ~100-example gallery rebuild that `zig build test` triggers.
    //
    // Includes:
    //   - The host-side fixture WGSL check (compiles tests/fixture_fs.zig
    //     through Zig→SPIR-V→spv2wgsl, validates non-empty + clean) —
    //     same FixtureWgslCheck wired into `zig build test`, bundled
    //     here for convenience.  Wired further below where the fixture
    //     step itself is constructed (declaration ordering — both
    //     sides of the dependency can't be near each other).
    //   - The corpus regression check (51 shaders).
    //   - The wgpu_bringup build + Bun smoke (no real GPU needed).
    //
    // See `src/notes/webgpu-migration-plan.md` for the migration plan.
    // Per-turn default during the wgpu arc.
    const wgpu_check: *Step = b.step(
        "check",
        "Run the minimal wgpu-migration audit (fixture + corpus + wgpu_bringup smoke).",
    );
    wgpu_check.dependOn(&transpiler_corpus_cmd.step);
    wgpu_check.dependOn(&wgpu_smoke_cmd.step);
    // Binding/structural WGSL tripwire: run the validator over every shader in
    // the corpus. Depends on wgpu_smoke_cmd so the shaders are compiled into
    // .zig-cache first (the tool walks the cache, like transpiler_corpus does).
    // Fails the build on any duplicate @group@binding — the collision Dawn
    // rejects on-device that the mock smoke test can't see.
    const spv_bind_check_run: *Run = b.addRunArtifact(spv2wgsl_check_exe);
    spv_bind_check_run.addArg("our-corpus");
    spv_bind_check_run.has_side_effects = true; // reads .zig-cache; never cache the result
    spv_bind_check_run.step.dependOn(&wgpu_smoke_cmd.step);
    wgpu_check.dependOn(&spv_bind_check_run.step);
    // fixture_wgsl_check.step dependency wired further below at the
    // fixture's declaration site (line ~1641).

    // ---- Dev server: pure-Zig (tools/serve.zig), no shell required. --
    // Two flavors:
    //   `zig build serve`        -- builds every example first, then serves.
    //                               Terminal-friendly "give me the whole
    //                               gallery" entry point.
    //   `zig build serve-only`   -- just starts the server.  Static assets +
    //                               zimr.js + docs are still installed (via
    //                               b.getInstallStep()) so host.html loads;
    //                               example wasms come from the HMR loop
    //                               (focus-aware, see webtests/server.ts)
    //                               or from explicit `-Dfocus=<list>` /
    //                               `run-<name>` invocations.  This is what
    //                               the VS Code background task uses so
    //                               first F5 of a session doesn't pay for
    //                               150 wasms it doesn't need yet.
    const serve: *Step = b.step(
        "serve",
        "Build all examples, then serve zig-out/web/ on localhost:8080 (pure-Zig server)",
    );
    const serve_cmd: *Run = b.addRunArtifact(serve_exe);
    serve_cmd.addArgs(&.{ "--root", "zig-out/web" });
    serve_cmd.step.dependOn(all_examples_step);
    serve.dependOn(&serve_cmd.step);

    const serve_only: *Step = b.step(
        "serve-only",
        "Start the dev server without rebuilding examples (static + runtime only)",
    );
    const serve_only_cmd: *Run = b.addRunArtifact(serve_exe);
    serve_only_cmd.addArgs(&.{ "--root", "zig-out/web" });
    serve_only_cmd.step.dependOn(b.getInstallStep());
    serve_only.dependOn(&serve_only_cmd.step);

    // ---- Host-target unit tests for pure-CPU modules. ----------------
    // Pure CPU code (raymath, gestures, etc.) gets tested on the native
    // host so we get real ASAN and proper Zig test infrastructure.
    // Modules with browser dependencies are excluded.  `test_step`
    // itself was declared near the top so the example loop could
    // wire its typecheck objects to it.
    // (`native_target` was declared earlier alongside the wgpu-diff
    // step that also uses it.)
    for (test_files) |tf| {
        const test_mod: *Module = b.createModule(.{
            .root_source_file = b.path(tf),
            .target = native_target,
            .optimize = .Debug,
            .pic = true,
        });
        // render.zig does `@embedFile("shadow_vs.glsl")` and friends.
        // Engine shader imports get wired into
        // and every example's module above; the host test module needs
        // them too or any test reaching render.zig fails to compile.
        for (engine_shaders.items) |s| {
            // The GLSL path is dead. render.zig only needs these @embedFile-able to
            // COMPILE (host tests don't run GL), so wire a placeholder for the .glsl
            // imports — otherwise the host test demands the real .glsl, which runs the
            // gated-off spirv-opt/cross/zglsl pipeline and fails the gate.
            const is_glsl: bool = endsWith(u8, s.name, ".glsl");
            const src: std.Build.LazyPath = if (is_glsl)
                b.path("src/shaders/_deleted_glsl_placeholder.glsl")
            else
                s.path;
            test_mod.addAnonymousImport(s.name, .{ .root_source_file = src });
            // The WGSL twin too: the host-test graph reaches the wgpu render
            // stack now (leak_test → draw3d → renderer_2d, GL-retirement P5
            // + the refAllDecls policy), and renderer_2d @embedFiles
            // "default_shapes_vs.wgsl" & co.
            if (s.wgsl_path) |wp| {
                test_mod.addAnonymousImport(s.wgsl_name.?, .{ .root_source_file = wp });
            }
            // Codegen externs modules for the test graph. `src/tests.zig`
            // (via refAllDecls) reaches `src/zimr.zig`, which publicly
            // re-exports several engine shaders (depth_write_fs, fog_fs,
            // maze_fs, terrain_fs, points3d_vs, hybrid_raymarch_fs, the
            // default_shapes pair, ...). Each `<name>.zig` does
            // `@import("<name>_externs")`, so every shader with a codegen'd
            // externs module needs it wired here or the host-test binary
            // fails to compile with "no module named '<name>_externs'".
            // (Previously only the shapes pair was wired; the others were
            // added to zimr.zig's public surface later and silently broke
            // `zig build test`.)
            if (s.sh_name) |sh_name| {
                if (s.externs_path) |externs_path| {
                    const externs_dep_name: []const u8 = b.fmt("{s}_externs", .{sh_name});
                    const externs_mod_t: *Module = b.createModule(.{
                        .root_source_file = externs_path,
                        .target = native_target,
                        .optimize = .ReleaseSafe,
                    });
                    externs_mod_t.addImport("zm", zimrmath_mod);
                    externs_mod_t.addImport("shader_builtins", shader_builtins_mod);
                    test_mod.addImport(externs_dep_name, externs_mod_t);
                }
            }
        }
        // `shader_interface` named module so `tests.zig`'s aggregator
        // (and any iface file reached through it) resolves
        // `@import("shader_interface")`.
        test_mod.addImport("shader_interface", shader_interface_mod);
        // Same for `zm` — the unified math module.  src/*.zig files
        // do `const zm = @import("zm");` since Stage 5 of math-
        // unification migrated path imports of math.zig to module
        // imports.  Without this wire, every src/ test that reaches
        // a math-using file fails to compile.
        test_mod.addImport("zm", zimrmath_mod);
        test_mod.addAnonymousImport("atomic_buildgrid_spv", .{
            .root_source_file = b.path("tests/fixtures/atomics/atomic_buildgrid.spv"),
        });
        test_mod.addOptions("build_options", build_opts);
        const t: *Compile = b.addTest(.{ .root_module = test_mod });
        const run: *Run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    // Native/host examples: software renderer, PNG output — zimr without
    // the web/GPU/c2js stack. Grouped in their own function (leaf steps).
    buildNativeExamples(b, native_target, zimrmath_mod, shader_interface_mod, build_opts, engine_shaders);

    // `src/zimrmath.zig` is the hard fork of zig-gamedev's zmath (see
    // notes/zmath-adoption-plan.md). It carries zmath's own ~70 `test`
    // blocks. Z0 of the adoption arc wires them here as a standalone
    // gate so a regression in the vendored math is caught immediately,
    // independently of the rest of zimr.
    // It is NOT folded into the `tests.zig` aggregator above because
    // `math.zig` isn't part of zimr's module graph yet - Z3 moves the
    // boundary; until then it's a parallel library.
    // Run on any host:  `zig build math-test`
    // const math_test_step = b.step("math-test", "Run vendored zmath's own test suite");
    // {
    //     const mt = b.addTest(.{
    //         .name = "math-tests",
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path("src/zimrmath.zig"),
    //             .target = native_target,
    //             .optimize = .Debug,
    //             .pic = true,
    //         }),
    //     });
    //     const run = b.addRunArtifact(mt);
    //     math_test_step.dependOn(&run.step);
    // }

    // ---- Cross-compile tests for Windows targets
    // Compiles the test executable against x86_64-windows-msvc and
    // x86_64-windows-gnu without running them.  Catches platform-
    // conditional bugs that don't surface on Linux/macOS - the
    // canonical example being POSIX `clock_gettime` (an `extern "c"`
    // symbol that requires `link_libc`, which Windows tests don't get
    // by default).  See `hostMonotonicMs` in `src/runtime.zig` for the
    // gate that prevents that compile error.
    // Run on any host:  `zig build test-windows`
    // CI smoke for any code that calls a platform API conditionally.
    const test_windows_step: *Step = b.step(
        "test-windows",
        "Cross-compile host tests targeting Windows (compile-only)",
    );
    for ([_][]const u8{ "x86_64-windows-msvc", "x86_64-windows-gnu" }) |triple| {
        const win_target: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
        }) catch unreachable);
        for (test_files) |tf| {
            const t_mod: *Module = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = win_target,
                .optimize = .Debug,
                .pic = true,
            });
            t_mod.addImport("shader_interface", shader_interface_mod);
            const t: *Compile = b.addTest(.{ .root_module = t_mod });
            // Don't run - just compile.  The .exe wouldn't execute on
            // a non-Windows host without Wine, and the goal is to
            // catch compile errors anyway.
            test_windows_step.dependOn(&t.step);
        }
    }

    // ---- API documentation (zig's native autodoc).
    // Builds a no-op library from src/zimr.zig and harvests Zig's
    // generated HTML+JS doc bundle via `getEmittedDocs()`.  We don't
    // care about the resulting binary - `-femit-docs` is the actual
    // ask, and `getEmittedDocs()` enables it.
    // Target is wasm32-wasi (matches the real build target so all
    // `extern "webgl" fn` decls type-check) but the generated docs
    // are static HTML+JS, target-independent for the reader.
    // ---- API documentation (zig's native autodoc).
    // Builds a no-op library from src/zimr.zig and harvests Zig's
    // generated HTML+JS doc bundle via `getEmittedDocs()`.  We don't
    // care about the resulting binary - `-femit-docs` is the actual
    // ask, and `getEmittedDocs()` enables it.
    // Target is wasm32-wasi (matches the real build target so all
    // `extern "webgl" fn` decls type-check) but the generated docs
    // are static HTML+JS, target-independent for the reader.
    // **Why the lib is named `zimr` not `zimr-docs`** - the autodoc
    // packer at `/opt/zig/lib/docs/wasm/main.zig` decides which file
    // is the module's "root" by either:
    //   (a) the file is encountered FIRST in the tar (default fallback),
    //   (b) the file's basename is `root.zig`, OR
    //   (c) the file's basename matches the package name.
    // For our tree, files are tar'd in alphabetical-by-fs-walk order
    // - `raymath.zig` happens to come before `zimr.zig`, so under name
    // `zimr-docs` neither (b) nor (c) matched and raymath.zig won the
    // root spot via (a).  Naming the package `zimr` instead lets (c)
    // fire on `zimr/zimr.zig` and pin zimr.zig as the root, which is
    // what the user expects when they navigate the docs.
    // **Install location is zig-out/web/docs/**, not zig-out/docs/, so
    // the gallery's `./docs/` link works in the served tree without a
    // manual copy.  And `b.getInstallStep().dependOn(&install_docs.step)`
    // wires docs into the default `zig build` so users don't have to
    // run a second command before `zig build serve` - autodoc caches
    // when sources don't change, so the cost is near-zero on rebuilds.
    // Output: zig-out/web/docs/  (browse via `zig build serve`
    // gallery's "api docs" link).  The bundle uses fetch() for source
    // viewing, so it must be served over HTTP - opening index.html
    // via file:// works for navigation but the source-view panel
    // won't load.
    // GL-retirement P3: docs document the LIVE WebGPU API (zimr),
    // not the retired GL umbrella.
    const docs_lib: *Compile = b.addLibrary(.{
        .name = "zimr",
        .root_module = zimr_mod,
        // linkage: static - build-lib path produces an .a we throw away,
        // but the side-effect of compiling triggers the autodoc emission.
        .linkage = .static,
    });

    const install_docs: *InstallDir = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = web_install,
        .install_subdir = "docs",
    });
    // Pull docs into the default install - `zig build` produces a
    // complete site (examples + bundled runtime + API docs).
    b.getInstallStep().dependOn(&install_docs.step);

    const docs_step: *Step = b.step("docs", "Generate API documentation in zig-out/web/docs/");
    docs_step.dependOn(&install_docs.step);

    // ---- `zig build dist` -- mirror zig-out/web/ into prebuilt/.
    // `prebuilt/` is committed to the repo so visitors can clone and
    // run `serve.bat` without Zig/Bun, and Codeberg Pages can serve
    // the gallery straight from the repo.  Pair with `-Drelease=true`
    // for ReleaseSmall wasm; `release.bat` does that for you.
    const dist_step: *Step = b.step("dist", "Refresh prebuilt/ from zig-out/web/ for distribution");
    // Custom make step: pure-Zig recursive copy.  Avoids the cross-shell
    // quoting/exit-code mess of xcopy/cp wrappers - and works the same
    // on Windows, Linux, and macOS without a builtin.os.tag branch.
    // dist mirrors zig-out/web/ to prebuilt/ (committed; serves the published
    // Codeberg Pages gallery) via the buildaux CLI — the old custom makeFn Step
    // is gone in 0.17.  Depend on all_examples_step (not just
    // b.getInstallStep()) so the mirror always has every wasm.
    const dist_copy: *Run = b.addRunArtifact(buildaux_exe);
    dist_copy.addArg("dist-copy");
    dist_copy.step.dependOn(all_examples_step);
    dist_step.dependOn(&dist_copy.step);

    // ============================================================================
    // `zig build lint` - AST-based style linter.
    // ============================================================================
    // Encodes the mechanical rules from `src/notes/claude.md` as
    // checks runnable per-file or on the whole codebase.  Spec
    // in `src/notes/lint-zimr-plan.md`.
    // Default scan (no args): src/*.zig + examples/*.zig.
    // Specific files: `zig build lint -- src/foo.zig`.
    // Flags: `--quiet`, `--only=tag1,tag2`, `--skip=tag1`.
    // Mode: hard gate (turn 379).  `zig build lint` exits non-zero
    // on any issue; `zig build lint-check` chains fmt-check + lint
    // for use as a CI gate.
    //
    // The linter has its OWN `build.zig` under `tools/` (turn 380),
    // which ALSO builds spirv-opt / spirv-val / spirv-cross used by
    // the Zig-shader pipeline (S1.1+).  Reason for separate
    // tools/build.zig: cold-cache test verification (`rm -rf
    // .zig-cache && zig build test`) used to also blow away the
    // linter binary, forcing a 30s ReleaseFast rebuild on every cold
    // run.  By building these from a separate `tools/build.zig`, its
    // `tools/.zig-cache/` is independent and survives.  Cold build
    // ~14 min ONCE (the spirv tools dominate); subsequent builds
    // are ~0.04s warm (incremental cache hit).  See turn 380 notes
    // for the original lint context and changelog360-369.md S1.1
    // for the spirv tools addition.
    //
    // `tools_subbuild` + `shader_pipeline` are declared near the top
    // of `pub fn build` (above the examples loop), since the loop
    // uses them.  Here we just wire `lint_run` to depend on the
    // shared tools_subbuild + add the fixture smoke check.
    // Host-built tool path. Zig names executables `<name>.exe` on Windows, so
    // without the host exe suffix `zig build lint` / `lint-check` fails there
    // with "FileNotFound". (The lint binary is produced by the tools/ subbuild,
    // not a main-build Compile, so it can't be run via addRunArtifact — which
    // would handle the suffix for us — hence this explicit, suffix-aware path.)
    const lint_run: *Run = b.addRunArtifact(lint_zimr_exe);

    // Install-path twin of `lint_run`.  Default `zig build` lints via
    // THIS Run so the lint can be gated behind a green compile (wired at
    // the end of build()) without forcing the standalone `lint` /
    // `lint-check` steps — which share `lint_run` — to build the whole
    // project first.  Same file set; only the dependencies differ.
    const lint_run_install: *Run = b.addRunArtifact(lint_zimr_exe);

    // Smoke check: compile `tests/fixture_fs.zig` end-to-end and
    // assert the output begins with `#version 300 es`.  Wired into
    // the default `test` step; runs every time tests run.  The
    // file exercises a representative subset of the unified `zm`
    // module (Vec2/Vec3/Vec, swizzles, scalar + vector generics,
    // location decorator), so a regression in either zm or the
    // build pipeline trips this gate.
    //
    // Implementation note: pure-Zig step (no `sh -c`).  The previous
    // version called `sh -c "head -1 … | grep -q …"` which works in
    // git-bash / WSL but blows up in a plain Windows cmd.exe with
    // "failed to spawn sh: FileNotFound".  Same problem `distCopyMake`
    // above solves for the dist copy — we follow that pattern here.
    // (GLSL fixture-header check removed — the GLSL path is retiring; the WGSL
    // fixture check below is the live regression gate for the shader pipeline.)

    // Parallel WGSL fixture check.  Validates that the new
    // `addShaderWgsl` build step runs end-to-end (spv2wgsl tool
    // exists, accepts the opt'd SPIR-V, produces non-empty WGSL).
    // The fixture is the same `tests/fixture_fs.zig` as the GLSL
    // check — so we know one Zig source compiles to BOTH .glsl
    // (via spirv-cross) and .wgsl (via spv2wgsl).  See
    // `src/notes/webgpu-migration-plan.md` §3 Phase B.
    const fixture_wgsl: LazyPath = shader_pipeline.addShaderWgsl(
        b.path("tests/fixture_fs.zig"),
        .{},
    );
    const fixture_wgsl_check: *Run = b.addRunArtifact(buildaux_exe);
    fixture_wgsl_check.addArg("check-wgsl-clean");
    fixture_wgsl_check.addFileArg(fixture_wgsl);
    fixture_wgsl_check.expectExitCode(0);
    test_step.dependOn(&fixture_wgsl_check.step);
    // wgpu-check (declared earlier) also depends on this; wire here
    // because the step exists above and the check is constructed here.
    wgpu_check.dependOn(&fixture_wgsl_check.step);

    // (GLSL math-pipeline check removed — the GLSL path is retiring. zm is verified
    // through the WGSL/compute path (turn ~979) and host math tests instead.)
    // Default scan: every src/*.zig file.  To lint a specific subset,
    // pass `-Dlint-files=a.zig,b.zig` (a build option — observable by
    // the configurer).  The old `-- foo.zig` positional override is
    // gone: the configurer/maker split made passthru args unobservable
    // to build.zig, so file targeting moved to an option while flags
    // still flow through addPassthruArgs.  See zig17_migration.md B3.
    const lint_files_opt: ?[]const u8 = b.option(
        []const u8,
        "lint-files",
        "Comma-separated Zig files to lint instead of the default full-tree scan.",
    );
    // `-Dautofix` (default true): the LINT-FIRST GATE that precedes every compile
    // APPLIES the mechanical lint fixes (`--fix`) + `zig fmt` in place instead of
    // failing on them. Confidence comes from the linter's parse-guard (it never
    // writes a worse-parsing file) plus the fact that the very next step is the
    // compile, which catches any wrong deletion immediately. Set
    // `-Dautofix=false` for a strict, non-mutating check gate (CI, verification).
    const autofix: bool = b.option(
        bool,
        "autofix",
        "Auto-apply mechanical lint fixes + zig fmt before compiling (default true; false = strict check gate).",
    ) orelse true;
    const has_file_arg: bool = lint_files_opt != null;
    // Dependency-safe: this scan walks zimr's own tree via cwd-relative paths,
    // which only resolve when zimr is the ROOT project. When zimr is consumed as
    // a package (b.pkg_hash non-empty), cwd is the consumer's root, so skip it —
    // a consumer never lints zimr's sources, and the lint steps just stay empty.
    if (!has_file_arg and b.pkg_hash.len == 0) {
        const io: std.Io = b.graph.io;
        const cwd: std.Io.Dir = std.Io.Dir.cwd();
        // Scan RECURSIVELY: every *.zig under src/, examples/,
        // tools/, and webtests/, plus build.zig.  The walk descends into
        // subdirectories — this is deliberate.  An earlier
        // non-recursive `dir.iterate()` only saw top-level src/*.zig
        // and SILENTLY skipped subdir files (src/spv2wgsl/*.zig,
        // src/shaders/*.zig, …), letting hundreds of lint violations
        // accumulate there unseen.  Recursion closes that hole.
        //
        // tools/ was a SECOND blind spot: it holds first-class authored
        // code (the linter itself, the SPIR-V reader `zspv`, the
        // transpiler CLIs `spv2wgsl`/`spv2wgsl_check`, the extern-gen
        // and rewrite tools, and tools/build.zig) that was never linted
        // because the walk only covered src/ and examples/.  It is now
        // a scan root.
        //
        // Excluded subtrees (path-prefix match on the walk-relative
        // path): `notes/staging/` (vendored upstream code) and
        // `c2js_cases/` under tools/ (matched via `firstSegmentIs`, which
        // is separator-agnostic so it also holds on Windows) — the c2js
        // transpiler corpus is ARBITRARY Zig by design (not zimr's linted
        // subset), exactly
        // like the top-level `tests/` shader fixtures (which are already
        // excluded simply by not being a scan root). NOTE: `src/tests/`
        // IS now linted — the host unit-test suite is first-class zimr
        // code — so only the deliberately-foreign test CORPORA stay
        // ungated.
        //
        // Under tools/ specifically we must NOT descend into the
        // bundled toolchains / caches / prebuilt binaries — those are
        // thousands of third-party stdlib .zig files that are not ours
        // to style-gate (see `tools_skip_prefix` below).
        //
        // Finally, `deletion_skip` lists individual authored files that
        // are SCHEDULED FOR DELETION and therefore not worth linting or
        // "fixing" — per the fix-on-notice exception in claude.md, a
        // doomed subsystem should be deleted/migrated, not polished.
        // Currently: `tools/zglsl.zig`, the GLSL post-process tool of
        // the dying WebGL/GLSL path being replaced by the wgpu/WGSL
        // spv2wgsl pipeline.  Remove the entry when the file is gone.
        const tools_skip_prefix = [_][]const u8{
            "zig-x86_64-", // bundled Zig toolchain, any version/OS (linux/windows)
            "bun-linux-x64/",
            "spirv-prebuilt-linux-x86_64/",
            ".zig-cache/",
            "zig-out/",
        };
        const deletion_skip = [_][]const u8{
            // Host-only debug harness (bakeFontAtlas -> imageDrawTextWithFont ->
            // PNG, viewable in-sandbox for CPU text-path debugging). Not engine
            // code and never compiled into a build; opts out of the style gate.
            "src/test_font_render.zig",
            "src/canvas_render_test.zig",
        };
        // Runtime `for` (not `inline for`) so an absent root can `continue`
        // out of the error switch below — `continue` targeting an inline loop
        // from inside a runtime switch is a comptime-control-flow error. `root`
        // is only ever used at runtime here (eql / b.fmt), so nothing needs the
        // unroll.
        const scan_roots = [_][]const u8{ "src", "examples", "tools", "webtests", "scripts" };
        for (scan_roots) |root| {
            var dir: std.Io.Dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
                // A scan root that isn't present in this checkout (e.g.
                // `scripts/`, whose Python helpers were ported to `tools/`)
                // simply has nothing to lint — skip it rather than aborting
                // the whole configure.
                error.FileNotFound => continue,
                else => @panic("cannot open scan dir"),
            };
            defer dir.close(io);
            var walker: std.Io.Dir.Walker = dir.walk(b.allocator) catch @panic("walk init");
            defer walker.deinit();
            while (walker.next(io) catch @panic("dir walk")) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                if (!endsWith(u8, entry.basename, ".zig")) {
                    continue;
                }
                // entry.path is relative to `root` (e.g. "spv2wgsl/ir.zig").
                // (src/tests/ is intentionally NOT skipped — see the policy
                // note above; the top-level tests/ corpus is excluded by not
                // being a scan root.)
                if (std.mem.indexOf(u8, entry.path, "notes/staging/") != null) {
                    continue;
                }
                // Skip the bundled toolchains / caches under tools/.
                if (eql(u8, root, "tools")) {
                    // c2js transpiler corpus — arbitrary Zig by design, not
                    // zimr's linted subset. Checked separator-agnostically
                    // because `entry.path` uses `\` on Windows (see
                    // `firstSegmentIs`), where a `"c2js_cases/"` prefix misses.
                    if (firstSegmentIs(entry.path, "c2js_cases")) {
                        continue;
                    }
                    var skip: bool = false;
                    for (tools_skip_prefix) |pfx| {
                        if (startsWith(u8, entry.path, pfx)) {
                            skip = true;
                            break;
                        }
                    }
                    if (skip) {
                        continue;
                    }
                }
                const path: []const u8 = b.fmt("{s}/{s}", .{ root, entry.path });
                // Skip files scheduled for deletion (full-path match).
                var doomed: bool = false;
                for (deletion_skip) |d| {
                    if (eql(u8, path, d)) {
                        doomed = true;
                        break;
                    }
                }
                if (doomed) {
                    continue;
                }
                lint_run.addFileArg(b.path(path));
                lint_run_install.addFileArg(b.path(path));
            }
        }
        // Top-level build.zig is included.  It uses build-helper
        // aliases (Step, Module, etc.) at the top of the file to
        // keep the type annotations short — see the alias block
        // near the top of build.zig and src/shader_codegen.zig.
        lint_run.addFileArg(b.path("build.zig"));
        lint_run_install.addFileArg(b.path("build.zig"));
    }
    // Explicit file subset (from -Dlint-files) when the default scan
    // was skipped above.
    if (lint_files_opt) |csv| {
        var it = std.mem.tokenizeScalar(u8, csv, ',');
        while (it.next()) |f| {
            lint_run.addFileArg(b.path(f));
            lint_run_install.addFileArg(b.path(f));
        }
    }
    // Forward any remaining flags (--quiet, --only=, --skip=) to the
    // lint exe.  Passthru args are no longer observable by build.zig
    // (configurer/maker split), which is fine: only the exe parses them.
    lint_run.addPassthruArgs();
    lint_run_install.addPassthruArgs();
    // Autofix: the install-path lint Run (the one gating every compile) runs in
    // `--fix` mode so a default `zig build` repairs mechanical issues in place
    // rather than failing on them. The standalone `lint` / `lint-check` steps
    // keep using `lint_run` (check mode), so CI and explicit checks never mutate.
    if (autofix) {
        lint_run_install.addArg("--fix");
    }
    const lint_step: *Step = b.step("lint", "Run AST-based style linter on Zig sources");
    lint_step.dependOn(&lint_run.step);

    // ============================================================================
    // `zig build fmt` / `zig build lint-check`
    // ============================================================================
    // Convention (turn 343): the default `zig build` (== install) does
    // NOT auto-run style checks.  Iterative dev should be fast.  Two
    // separate commands cover the style surface:
    //
    //   `zig build fmt`         - APPLIES zig fmt.  Mutates files.
    //                             Convenience.  Never fails.
    //   `zig build lint-check`  - The composite style gate.  Runs
    //                             zig-fmt-check + lint together.
    //                             Fails if either does.  Use in CI,
    //                             audit scripts, pre-push hooks, etc.
    //
    // If you want to check ONLY formatting (no lint), use the zig CLI
    // directly: `zig fmt --check src/ examples/ build.zig tools/`.
    // Not exposed as a build step — `lint-check` is the canonical gate
    // and a one-purpose `fmt-check` step was redundant with it.
    //
    // Rationale (turn 342): putting fmt+lint on the install path made
    // every `zig build` run lint (~26s cold), and during multi-turn
    // cleanup with intentionally-dirty lint state, `zig build` became
    // unusable.  Explicit gate beats implicit gate.
    //
    // Note: we list `tools/` files individually instead of `"tools"`
    // because zig fmt would otherwise walk into the bundled stdlib
    // at `tools/zig-x86_64-linux-0.16.0/lib/std/`, adding ~0.6s of
    // pointless work per check.  Discovered turn 382.
    // NOTE(zig-0.17): run `zig fmt` via addSystemCommand instead of b.addFmt.
    // The dev.639 configurer segfaults while serializing a Fmt step's LazyPath
    // `paths` (minimal repro confirmed — file upstream for 0.17.1).  A system
    // command takes plain string args, sidestepping the broken path; the readme
    // already documents `zig fmt …` from the CLI as equivalent.  See
    // src/notes/zig17_migration.md B8.
    const fmt_apply: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "src",
        "examples",
        "build.zig",
        "tools/lint_zimr.zig",
    });
    const fmt_apply_step: *Step = b.step("fmt", "Apply zig fmt to src/, examples/, build.zig, tools/");
    fmt_apply_step.dependOn(&fmt_apply.step);

    // Internal fmt-check feeds `lint-check`; not registered as a top-level step.
    const fmt_check: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "src",
        "examples",
        "build.zig",
        "tools/lint_zimr.zig",
    });

    const lint_check_step: *Step = b.step("lint-check", "Style gate: zig fmt --check + zig build lint");
    lint_check_step.dependOn(&fmt_check.step);
    lint_check_step.dependOn(&lint_run.step);

    // Install-path twin of `fmt_check` (see `lint_run_install`): default
    // `zig build` fmt-checks via THIS Run so it can be gated behind a
    // green compile without dragging the shared `lint-check` step into a
    // full project build.
    const fmt_check_install: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "src",
        "examples",
        "build.zig",
        "tools/lint_zimr.zig",
    });

    // Gate-only fmt Run (distinct from the `zig build fmt` step's `fmt_apply`)
    // so wiring the lint→fmt ordering here doesn't change what `zig build fmt`
    // does. Under `-Dautofix` it depends on `lint_run_install` (the `--fix`
    // Run), serialising the two mutating steps — lint-fix first, then fmt tidies
    // the blank line a deletion can leave — ahead of every compile so they never
    // race on the same files.
    const fmt_apply_gate: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "src",
        "examples",
        "build.zig",
        "tools/lint_zimr.zig",
    });
    if (autofix) {
        fmt_apply_gate.step.dependOn(&lint_run_install.step);
    }

    // LINT-FIRST GATE.  Every Zig compile in the build depends on the style
    // checks, so `lint` + `zig fmt --check` must pass BEFORE anything is
    // compiled: a semantic compile error never surfaces until the tree is
    // lint-clean.  (Parse/AST errors DO still surface — from the linter and
    // fmt themselves, which need a parseable AST; that's intended and fine.)
    //
    // Cycle-free: the lint binary is produced by `tools_subbuild` (a Run /
    // nested build), NOT an in-graph Compile, so no Compile is upstream of
    // the lint Runs — gating Compiles behind them cannot form a loop.
    //
    // We walk every top-level step's transitive deps and gate each Compile
    // (`step.id == .compile`).  This covers bare `zig build` AND every
    // example / standalone step, not just the install path.  The standalone
    // `lint` / `lint-check` steps use the ungated `lint_run` / `fmt_check`,
    // so they stay fast and run on not-yet-compiling code.
    {
        var seen: std.AutoHashMapUnmanaged(*Step, void) = .empty;
        defer seen.deinit(b.allocator);
        var stack: ArrayList(*Step) = .empty;
        defer stack.deinit(b.allocator);
        for (b.top_level_steps.values()) |tls| {
            stack.append(b.allocator, &tls.step) catch @panic("oom");
        }
        while (stack.pop()) |s| {
            if (seen.contains(s)) {
                continue;
            }
            seen.put(b.allocator, s, {}) catch @panic("oom");
            for (s.dependencies.items) |dep| {
                stack.append(b.allocator, dep) catch @panic("oom");
            }
            // The lint tool is now an in-graph Compile (was a sub-build). Its
            // own compile is upstream of the lint Runs, so gating it behind them
            // would form a cycle — exclude it. Every other Compile is downstream
            // of lint and gates normally. Only gate when zimr is the ROOT project
            // — a consumer depending on zimr must not be forced through zimr's
            // dev-only lint/fmt checks (they scan root-relative paths like
            // `examples/` that don't exist in the dependency).
            if (b.pkg_hash.len == 0 and s.tag == .compile and s != &lint_zimr_exe.step) {
                if (autofix) {
                    // lint --fix → fmt → compile. `fmt_apply_gate` is ordered
                    // after the `--fix` Run, so the two mutating steps run in
                    // sequence (never racing) before this compile.
                    s.dependOn(&fmt_apply_gate.step);
                } else {
                    s.dependOn(&lint_run_install.step);
                    s.dependOn(&fmt_check_install.step);
                }
            }
            // `all-examples` must build the WHOLE gallery (its stated job —
            // serve / dist / a full-tree compile check all hang off it).
            // Nothing wired the per-example installs into it, so it silently
            // built only the runtime.  Pick up every wasm example's install
            // artifact here; the wasm32 filter keeps native build tools out.
            if (s.tag == .install_artifact) {
                const ia: *InstallArtifact = s.cast(InstallArtifact).?;
                if (ia.artifact.rootModuleTarget().cpu.arch == .wasm32) {
                    all_examples_step.dependOn(s);
                    // `zig build test` build-checks only the tier-A subset
                    // (varied feature coverage) to stay fast; the full sweep
                    // is `zig build test-all-examples`.
                    if (matchesFocus(ia.artifact.name, "tier-a")) {
                        test_step.dependOn(s);
                    }
                }
            }
            // The per-example served PAGES (web/<name>/index.html) are
            // install_file steps, not install_artifact, so the wasm-only pickup
            // above misses them — the gallery's clickable pages would never
            // build. Grab every install_file under web/<name>/ so `all-examples`
            // (and thus serve / dist) assembles the full clickable tree.
            if (s.tag == .install_file) {
                const inf: *InstallFile = s.cast(InstallFile).?;
                switch (inf.dir) {
                    .custom => |c| {
                        if (std.mem.startsWith(u8, c, "web/")) {
                            all_examples_step.dependOn(s);
                        }
                    },
                    else => {},
                }
            }
        }
    }
    // `zig build test-all-examples` = the full sweep: host unit tests PLUS
    // every example wasm. Plain `zig build test` only build-checks the tier-A
    // subset (see the tier-A wiring in the graph walk above), so the common
    // edit/test loop stays fast; this step is the exhaustive pre-merge check.
    const test_all_examples_step: *Step = b.step(
        "test-all-examples",
        "Host unit tests + build every example wasm (exhaustive)",
    );
    test_all_examples_step.dependOn(test_step);
    test_all_examples_step.dependOn(all_examples_step);

    // Bare `zig build` (install) is mostly a JS bundle + static files with no
    // Compile of its own, so depend on the gates directly too — otherwise a
    // compile-less install would skip the style check entirely.
    b.getInstallStep().dependOn(&fmt_check_install.step);
    b.getInstallStep().dependOn(&lint_run_install.step);
}

/// The host-side tool executables, built once and shared. Returned as a set
/// so build() can destructure them without threading eight separate values.
const Tools = struct {
    spv2wgsl: *Compile,
    spv2wgsl_check: *Compile,
    zspv: *Compile,
    lint: *Compile,
    c2js: *Compile,
    serve: *Compile,
    cheatsheet: *Compile,
    buildaux: *Compile,
    mesh_bake: *Compile,
    dag: *Compile,
    gen_vscode: *Compile,
    gen_files_md: *Compile,
    highlight: *Compile,
};

fn buildTools(b: *std.Build, host_target: ResolvedTarget, zimrmath_mod: *Module) Tools {
    const spv2wgsl_lib_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/spv2wgsl.zig"),
        .target = host_target,
        .optimize = .ReleaseSafe,
    });
    const spv2wgsl_tool_exe: *Compile = b.addExecutable(.{
        .name = "spv2wgsl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spv2wgsl.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    spv2wgsl_tool_exe.root_module.addImport("spv2wgsl", spv2wgsl_lib_mod);
    // The binding/structural WGSL validator — same spv2wgsl lib, run over the
    // corpus by `check` as a build-time tripwire (duplicate @group@binding etc.).
    const spv2wgsl_check_exe: *Compile = b.addExecutable(.{
        .name = "spv2wgsl_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spv2wgsl_check.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    spv2wgsl_check_exe.root_module.addImport("spv2wgsl", spv2wgsl_lib_mod);
    const zspv_tool_exe: *Compile = b.addExecutable(.{
        .name = "zspv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zspv.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    // The remaining tools, built DIRECTLY by the main build (pure Zig, like
    // spv2wgsl/zspv above) instead of the old `tools/build.zig` sub-build. That
    // sub-build was cwd-relative and wrote into a (read-only-as-a-dependency)
    // cache — incompatible with zimr being consumed as a package. Installed as
    // named artifacts so an external consumer can `dep.artifact("c2js")` etc.
    const lint_zimr_exe: *Compile = b.addExecutable(.{
        .name = "lint_zimr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lint_zimr.zig"),
            .target = host_target,
            // ReleaseSafe, NOT ReleaseFast: this dev Zig miscompiles lint_zimr
            // under ReleaseFast (SIGILL on every input). Debug + ReleaseSafe
            // both run clean; ReleaseSafe keeps it fast. Revisit on Zig upgrade.
            .optimize = .ReleaseSafe,
        }),
    });
    const c2js_exe: *Compile = b.addExecutable(.{
        .name = "c2js",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/c2js.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    // c2js CHECKS that a job-kernel wasm actually exports a kernel, so it has to ask about
    // the same export name `jobs.zig` produces. Give it the one file that defines them, so
    // the check cannot drift from the thing it checks.
    c2js_exe.root_module.addImport("jobs_abi", b.createModule(.{
        .root_source_file = b.path("src/jobs_abi.zig"),
        .target = host_target,
        .optimize = .ReleaseSafe,
    }));
    const serve_exe: *Compile = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    const cheatsheet_exe: *Compile = b.addExecutable(.{
        .name = "cheatsheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cheatsheet.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    // buildaux: build-time helper CLI (dist-copy, shader fixture checks, wgpu
    // standalone assembly).  Replaces the custom makeFn Step subclasses that
    // the 0.17 configurer/maker split removed.  See zig17_migration.md.
    const buildaux_exe: *Compile = b.addExecutable(.{
        .name = "buildaux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/buildaux.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });

    // mesh_bake: bake a DECIMATED glTF proxy (+ small base-color block) into
    // a generated `.zig` const — the comptime-corner geometry source for the
    // helmet side-by-side.  The compiler can't parse a GLB (allocator-based,
    // and 15k tris is far past any comptime budget), so this build step
    // pre-chews it: vertex-cluster decimation + box-filtered texture, emitted
    // as `pub const` arrays.  codecs gets its OWN host-side module instance:
    // this exe's compile graph is disjoint from the wasm graphs, so the
    // one-file-per-module rule is satisfied per-compilation.
    const mesh_bake_codecs_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/codecs.zig"),
    });
    mesh_bake_codecs_mod.addImport("zm", zimrmath_mod);
    const mesh_bake_exe: *Compile = b.addExecutable(.{
        .name = "mesh_bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mesh_bake.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    mesh_bake_exe.root_module.addImport("codecs", mesh_bake_codecs_mod);

    // dag_check: the file-level import-graph DAG gate (replaces the old
    // scripts/check_dag.py).  Tokenizer-based @import scan, Tarjan SCC, no
    // whitelist; also prints the auto-computed DAG layering.  std-only.
    const dag_check_exe: *Compile = b.addExecutable(.{
        .name = "dag_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dag_check.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });

    // gen_vscode: regenerate .vscode/.zed debug+task configs from the
    // example_steps array (replaces scripts/build_launch_json.py).  std-only.
    const gen_vscode_exe: *Compile = b.addExecutable(.{
        .name = "gen_vscode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_vscode.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    // gen_files_md: regenerate src/notes/files.md, the per-file atlas
    // (line/fn/test counts, deps, dependents, curated descriptions).
    // Replaces scripts/gen_files_md.py.  Pulls in tools/file_descriptions.zig
    // (the curated text) as a sibling file-import.  std-only.
    const gen_files_md_exe: *Compile = b.addExecutable(.{
        .name = "gen_files_md",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_files_md.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    // highlight: build-time Zig syntax highlighter for readme.html.  stdin ->
    // stdout filter; wraps <pre><code class="language-zig"> tokens in spans via
    // std.zig.Tokenizer so the served page needs no runtime JS.  std-only.
    const highlight_exe: *Compile = b.addExecutable(.{
        .name = "highlight",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/highlight.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    return .{
        .spv2wgsl = spv2wgsl_tool_exe,
        .spv2wgsl_check = spv2wgsl_check_exe,
        .zspv = zspv_tool_exe,
        .lint = lint_zimr_exe,
        .c2js = c2js_exe,
        .serve = serve_exe,
        .cheatsheet = cheatsheet_exe,
        .buildaux = buildaux_exe,
        .mesh_bake = mesh_bake_exe,
        .dag = dag_check_exe,
        .gen_vscode = gen_vscode_exe,
        .gen_files_md = gen_files_md_exe,
        .highlight = highlight_exe,
    };
}

/// Native/host examples: built for the host as ordinary executables that
/// render via the pure-Zig software renderer (raster) and write PNG files — no
/// WebGPU, no web, no c2js. The clean demonstration of zimr's CPU path. These
/// are leaf steps (nothing downstream depends on them), so they live together
/// here instead of interleaved with the wgpu build.
fn buildNativeExamples(
    b: *std.Build,
    native_target: ResolvedTarget,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
    build_opts: *Options,
    engine_shaders: ArrayList(EngineShader),
) void {
    // ---- `sw-mandelbrot` native demo (turn-3 SW dispatch headline) ---
    // Builds `examples/sw_mandelbrot.zig` as a native executable that
    // renders Mandelbrot through the typed-pipeline SW dispatch
    // architecture, then writes `mandelbrot.png` to the cwd.
    //
    // Demonstrates the turn-3 architecture end-to-end:
    //   - Inline VS+FS shader types using `pub fn shaderMain(io: Io) Out`
    //   - Custom pipeline struct with `pub const sw_dispatch = ...`
    //   - `SwBackend.setPipeline` records the comptime vtable on PassState
    //   - `ps.sw_dispatch.?.flush_batch` dispatches into a closure that
    //     calls `raster_shader.rasterizeTriangles` with `autoConnect`
    //
    // Needs a separate native module (the engine modules are wasm-
    // targeted for the in-browser engine; the demo runs on host).
    //
    // Run on any host:  `zig build sw-mandelbrot`
    const sw_mandelbrot_step: *Step = b.step(
        "sw-mandelbrot",
        "Build and run the Mandelbrot SW-renderer demo (writes mandelbrot.png)",
    );
    {
        // GL-retirement P2: this demo runs on the native SW bundle
        // (raster + raster_shader + codecs + math + typed-pipeline pieces)
        // instead of the GL `zimr` umbrella.
        const sw_bundle_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/sw_runtime.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .link_libc = false,
        });
        sw_bundle_mod.addImport("shader_interface", shader_interface_mod);
        sw_bundle_mod.addImport("zm", zimrmath_mod);
        sw_bundle_mod.addOptions("build_options", build_opts);

        const demo_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/sw_mandelbrot.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });
        demo_mod.addImport("sw_runtime", sw_bundle_mod);
        demo_mod.addImport("zm", zimrmath_mod);

        const demo_exe: *Compile = b.addExecutable(.{
            .name = "sw_mandelbrot",
            .root_module = demo_mod,
        });
        const install_demo: *InstallArtifact = b.addInstallArtifact(demo_exe, .{});
        const run_demo: *Run = b.addRunArtifact(demo_exe);
        run_demo.step.dependOn(&install_demo.step);
        sw_mandelbrot_step.dependOn(&run_demo.step);
    }

    // ---- examples/comptime_mandelbrot.zig: the Mandelbrot set evaluated
    // ---- by the Zig compiler itself.  No zimr dependency, no float math
    // ---- at runtime.  The pixel data lives in the binary's read-only
    // ---- data section; main() just prints it.
    //
    // Companion to sw_mandelbrot (above): SAME Mandelbrot kernel, but
    // executed at compile time via @setEvalBranchQuota + comptime call.
    // Compile time is in the order of ~5-15s depending on machine; runtime
    // is a const-string printf.  Together with sw_mandelbrot (native CPU)
    // and mandelbrot_split (WebGL2 GLSL + CPU dispatch) and the typed
    // shader pipeline (WGSL via SPIR-V), this proves the kernel runs in
    // FOUR distinct execution environments.
    //
    // Run on any host:  `zig build comptime-mandelbrot`
    const comptime_mandelbrot_step: *Step = b.step(
        "comptime-mandelbrot",
        "Build and run the compile-time Mandelbrot demo (no runtime math)",
    );
    {
        const ct_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/comptime_mandelbrot.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });

        const ct_exe: *Compile = b.addExecutable(.{
            .name = "comptime_mandelbrot",
            .root_module = ct_mod,
        });
        const install_ct: *InstallArtifact = b.addInstallArtifact(ct_exe, .{});
        const run_ct: *Run = b.addRunArtifact(ct_exe);
        run_ct.step.dependOn(&install_ct.step);
        comptime_mandelbrot_step.dependOn(&run_ct.step);
    }

    // ---- examples/sw_engine_shader.zig: prove the engine VS+FS
    // ---- pair runs natively.  Renders 3 triangles through
    // ---- default_shapes_vs + default_shapes_fs on the CPU, outputs
    // ---- sw_engine_shader.png.  THE proof that one Zig source IS
    // ---- the shader on both backends — the codegen-emitted
    // ---- `_Spirv` wrap (turn 4) makes the externs file compile on
    // ---- native targets while staying valid on SPIR-V.
    //
    // Run on any host:  `zig build sw-engine-shader`
    const sw_engine_shader_step: *Step = b.step(
        "sw-engine-shader",
        "Render through engine shaders on CPU; writes sw_engine_shader.png",
    );
    {
        // The example's own module.  Does NOT depend on the full
        // `zimr` umbrella — see comment in the example source for
        // why.  We wire only the leaf submodules it actually uses.
        const eng_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/sw_engine_shader.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });
        eng_mod.addImport("zm", zimrmath_mod);

        // Single bundle module for the entire native runtime
        // (raster + raster_shader + codecs).  They all transitively
        // import `types.zig`, so they MUST share one module to
        // satisfy Zig 0.16's one-file-per-module rule.
        const sw_runtime_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/sw_runtime.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
        });
        sw_runtime_mod.addImport("zm", zimrmath_mod);
        sw_runtime_mod.addImport("shader_interface", shader_interface_mod);
        sw_runtime_mod.addOptions("build_options", build_opts);
        eng_mod.addImport("sw_runtime", sw_runtime_mod);

        // The engine shapes shader pair lives INSIDE sw_runtime now
        // (GL-retirement P2): sw_runtime's graph grew renderer_2d.zig
        // via shader_runtime_wgpu, so a separate default_shapes_bundle
        // module would double-own that file.  Only the codegen externs
        // modules still need wiring — onto sw_runtime itself.
        for (engine_shaders.items) |s| {
            if (s.sh_name == null) {
                continue;
            }
            const sh_name: []const u8 = s.sh_name.?;
            const is_target = eql(u8, sh_name, "default_shapes_vs") or
                eql(u8, sh_name, "default_shapes_fs");
            if (!is_target) {
                continue;
            }
            if (s.externs_path) |externs_path| {
                const externs_dep_name: []const u8 = b.fmt("{s}_externs", .{sh_name});
                const externs_mod: *Module = b.createModule(.{
                    .root_source_file = externs_path,
                    .target = native_target,
                    .optimize = .ReleaseSafe,
                });
                externs_mod.addImport("zm", zimrmath_mod);
                sw_runtime_mod.addImport(externs_dep_name, externs_mod);
            }
        }

        const eng_exe: *Compile = b.addExecutable(.{
            .name = "sw_engine_shader",
            .root_module = eng_mod,
        });
        const install_eng: *InstallArtifact = b.addInstallArtifact(eng_exe, .{});
        const run_eng: *Run = b.addRunArtifact(eng_exe);
        run_eng.step.dependOn(&install_eng.step);
        sw_engine_shader_step.dependOn(&run_eng.step);
    }

    // ---- examples/julia_gallery.zig: four Julia sets in a 2x2 grid
    // ---- showing how tiny changes to `c` produce wildly different
    // ---- shapes (dragon / fern / starfish / spiral).  Single-PNG
    // ---- output.  Each cell is independent — trivially parallelizable.
    //
    // Run on any host:  `zig build julia-gallery`
    const julia_gallery_step: *Step = b.step(
        "julia-gallery-png",
        "Build and run the Julia gallery (writes julia_gallery.png)",
    );
    {
        // GL-retirement P2: this demo runs on the native SW bundle
        // (raster + raster_shader + codecs + math + typed-pipeline pieces)
        // instead of the GL `zimr` umbrella.
        const sw_bundle_mod_jg: *Module = b.createModule(.{
            .root_source_file = b.path("src/sw_runtime.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .link_libc = false,
        });
        sw_bundle_mod_jg.addImport("shader_interface", shader_interface_mod);
        sw_bundle_mod_jg.addImport("zm", zimrmath_mod);
        sw_bundle_mod_jg.addOptions("build_options", build_opts);

        const jg_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/julia_gallery.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });
        jg_mod.addImport("sw_runtime", sw_bundle_mod_jg);
        jg_mod.addImport("zm", zimrmath_mod);

        const jg_exe: *Compile = b.addExecutable(.{
            .name = "julia_gallery",
            .root_module = jg_mod,
        });
        const install_jg: *InstallArtifact = b.addInstallArtifact(jg_exe, .{});
        const run_jg: *Run = b.addRunArtifact(jg_exe);
        run_jg.step.dependOn(&install_jg.step);
        julia_gallery_step.dependOn(&run_jg.step);
    }

    // ---- CPU Julia set, writes a colored PNG.  Direct per-pixel
    // ---- compute (no rasterizer) — the simpler architecture for
    // ---- single-pixel-per-output workflows.
    //
    // Run on any host:  `zig build sw-julia`
    const sw_julia_step: *Step = b.step(
        "sw-julia",
        "Build and run the Julia SW-renderer demo (writes julia.png)",
    );
    {
        // GL-retirement P2: this demo runs on the native SW bundle
        // (raster + raster_shader + codecs + math + typed-pipeline pieces)
        // instead of the GL `zimr` umbrella.
        const sw_bundle_mod_julia: *Module = b.createModule(.{
            .root_source_file = b.path("src/sw_runtime.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .link_libc = false,
        });
        sw_bundle_mod_julia.addImport("shader_interface", shader_interface_mod);
        sw_bundle_mod_julia.addImport("zm", zimrmath_mod);
        sw_bundle_mod_julia.addOptions("build_options", build_opts);
        // Engine shaders need their @embedFile imports satisfied even
        // for unused-on-this-target paths.

        const julia_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/sw_julia.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });
        julia_mod.addImport("sw_runtime", sw_bundle_mod_julia);
        julia_mod.addImport("zm", zimrmath_mod);

        const julia_exe: *Compile = b.addExecutable(.{
            .name = "sw_julia",
            .root_module = julia_mod,
        });
        const install_julia: *InstallArtifact = b.addInstallArtifact(julia_exe, .{});
        const run_julia: *Run = b.addRunArtifact(julia_exe);
        run_julia.step.dependOn(&install_julia.step);
        sw_julia_step.dependOn(&run_julia.step);
    }

    // ---- Same compile-time evaluation pattern, different fractal
    // ---- (Julia set: z₀ is per-pixel, c is a fixed constant).
    // ---- Demonstrates the comptime pattern generalizes beyond one
    // ---- specific kernel.  No zimr dependency.
    //
    // Run on any host:  `zig build comptime-julia`
    const comptime_julia_step: *Step = b.step(
        "comptime-julia-png",
        "Build and run the compile-time Julia set demo",
    );
    {
        const cj_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/comptime_julia.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
            .pic = true,
        });

        const cj_exe: *Compile = b.addExecutable(.{
            .name = "comptime_julia",
            .root_module = cj_mod,
        });
        const install_cj: *InstallArtifact = b.addInstallArtifact(cj_exe, .{});
        const run_cj: *Run = b.addRunArtifact(cj_exe);
        run_cj.step.dependOn(&install_cj.step);
        comptime_julia_step.dependOn(&run_cj.step);
    }
}

/// Match an example name against a comma-separated focus list.
/// Empty list (`""`) matches everything - this is the default state
/// when no `-Dfocus` flag is passed.  Entries ending in `*` match as
/// prefixes; bare entries match exactly.  Mirrors the syntax that
/// `webtests/smoke.ts` uses for its `--focus` arg so a single
/// `-Dfocus=` invocation filters both the build artifacts AND the
/// smoke-test runs identically.
/// Examples:
///   matchesFocus("ui_log_viewer", "")                         → true
///   matchesFocus("ui_log_viewer", "ui_log_viewer")            → true
///   matchesFocus("ui_log_viewer", "ui_log_viewer,zimrphysics_*")  → true
///   matchesFocus("zimrphysics_demo", "ui_log_viewer,zimrphysics_*")   → true
///   matchesFocus("audio_basic", "ui_log_viewer,zimrphysics_*")    → false
///   matchesFocus("mandelbrot", "tier-a")                      → true
///   matchesFocus("audio_basic", "tier-a")                     → false
///
/// `tier-a` is a magic name expanding to a 10-example set chosen for
/// broad, varied feature coverage (2D/UI, 3D mesh+camera, GPU compute,
/// 2D shape primitives, ImGui widgets, CPU/GPU shader duality, docking,
/// ECS, the plot lib + heavy immediate-mode UI, and glTF model + PBR).
/// One example per cross-cutting surface so a broad breakage surfaces
/// fast without build-checking all ~135 examples.  Can be combined with
/// other entries: `-Dfocus=tier-a,ui_tables_*` typechecks the tier plus
/// the prefix.
/// True when `path`'s first directory segment equals `dir`, treating BOTH
/// `/` and `\` as separators. The dir Walker builds `entry.path` with the
/// platform separator (`\` on Windows), so a hard-coded `"dir/"` prefix
/// silently fails to match there — which let the c2js_cases lint corpus slip
/// back into the scan on Windows. This normalizes that one comparison.
fn firstSegmentIs(path: []const u8, dir: []const u8) bool {
    if (!startsWith(u8, path, dir)) {
        return false;
    }
    if (path.len == dir.len) {
        return true;
    }
    const c: u8 = path[dir.len];
    return c == '/' or c == '\\';
}

fn matchesFocus(example_name: []const u8, focus_list: []const u8) bool {
    if (focus_list.len == 0) {
        return true;
    }
    var it = std.mem.splitScalar(u8, focus_list, ',');
    while (it.next()) |entry| {
        if (entry.len == 0) {
            continue;
        }
        // Magic `tier-a` entry: expands to the canonical varied example
        // set used by both `zig build test` (example build-check) and the
        // per-turn smoke set. One example per cross-cutting surface so a
        // broad breakage surfaces fast without building all ~135 examples.
        if (eql(u8, entry, "tier-a")) {
            const tier_a_names: []const []const u8 = &.{
                "wgpu_bringup", // general 2D/UI API surface
                "cube3d", // 3D mesh + camera/matrix path
                "compute_smoke", // GPU compute round-trip
                "shapes_showcase", // 2D shape primitives
                "ui_color_picker", // ImGui-style widgets
                "mandel_sidebyside", // CPU/GPU fragment-shader duality
                "ui_dock_simple", // docking
                "ecs_solar_system", // ECS
                "plot_demo", // plotting lib + heavy immediate-mode UI
                "damaged_helmet", // glTF model load + PBR
                "launcher", // multi-app compose + lazy child init in frame 0
                // (the queue-timeline clobber class: two pbr3d model draws
                // sharing a UBO, and a lazily-init'd child seeding a UBO it
                // also writes in frame 0 — neither shows in a single-app smoke)
            };
            for (tier_a_names) |t| {
                if (eql(u8, example_name, t)) {
                    return true;
                }
            }
            continue;
        }
        // Prefix-glob form: trailing '*' means "match anything starting
        // with this prefix."  Drop the '*' and check startsWith.  No
        // other glob characters are supported - keeping the syntax
        // small avoids needing a full glob matcher in build.zig.
        if (entry.len > 1 and entry[entry.len - 1] == '*') {
            const prefix: []const u8 = entry[0 .. entry.len - 1];
            if (startsWith(u8, example_name, prefix)) {
                return true;
            }
        } else if (eql(u8, example_name, entry)) {
            return true;
        }
    }
    return false;
}

/// Install a built wgpu example's wasm into the shared smoke dir
/// (zig-out/wgpu-smoke/web/) and wire it onto `wgpu_smoke_install`, but
/// only when it passes -Dfocus.  `under` is the wasm basename (e.g.
/// "cube3d"); the smoke harness matches focus on that same name.
fn addWgpuSmoke(
    b: *std.Build,
    c2js_exe: *Compile,
    wgpu_smoke_install: *Step,
    smoke_focus: []const u8,
    exe: *Compile,
    under: []const u8,
) void {
    if (!matchesFocus(under, smoke_focus)) {
        return;
    }
    const smoke_art: *InstallArtifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "wgpu-smoke/web" } },
    });
    wgpu_smoke_install.dependOn(&smoke_art.step);

    // ---- ZIG_BRIDGE page (Phase 3e): the same wasm, embedded into a
    // single-file HTML whose entire runtime is the Zig bridge. Rides the
    // smoke-install step, so one command produces wasm AND page:
    //   zig build smoke-install -Dfocus=<name>
    //   -> zig-out/bridge-pages/<name>.html
    // The bridge.c Run is byte-identical across examples, so the build
    // cache collapses it to a single transpile per session.
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    to_c.addFileArg(b.path("src/bridge.zig"));
    const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
    const to_html: *Run = b.addRunArtifact(c2js_exe);
    to_html.addArgs(&.{
        "--html",
        "--title",
        b.fmt("zimr {s} (zig bridge)", .{under}),
        "--wasm-embed",
    });
    to_html.addFileArg(exe.getEmittedBin());
    to_html.setStdIn(.{ .lazy_path = bridge_c });
    const page: LazyPath = to_html.captureStdOut(.{});
    const page_inst: *InstallFile =
        b.addInstallFile(page, b.fmt("bridge-pages/{s}.html", .{under}));
    wgpu_smoke_install.dependOn(&page_inst.step);
}
// addWgpuStandalone — register a `zig build <step_name>` that assembles a
// single self-contained HTML for a wgpu demo via the buildaux CLI (the old
// custom-step `WgpuStandalone` is gone with the 0.17 configurer/maker split).
// Derives the bundled-JS path and output HTML path from out_dir/out_basename,
// depends on the wasm (the Compile's emitted binary) and the JS-bundle step,
// and returns the registered step.  See src/notes/zig17_migration.md B7.
/// The example as a module (descriptor-only), with the imports every example
/// needs (zimr, zm, shader_interface, example_common, fonts).
fn buildUserMod(
    b: *std.Build,
    wasm_target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zimr_mod: *Module,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
    name: []const u8,
) *Module {
    const under: []const u8 = name;
    const user_mod: *Module = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}/{s}.zig", .{ under, under })),
        .target = wasm_target,
        .optimize = optimize,
    });
    user_mod.addImport("zimr", zimr_mod);
    user_mod.addImport("zm", zimrmath_mod);
    user_mod.addImport("shader_interface", shader_interface_mod);
    const common_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/example_common/example_common.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    common_mod.addImport("zimr", zimr_mod);
    common_mod.addImport("zm", zimrmath_mod);
    user_mod.addImport("example_common", common_mod);
    user_mod.addAnonymousImport("roboto_mono_ttf", .{
        .root_source_file = b.path("assets/RobotoMono-Regular.ttf"),
    });
    user_mod.addAnonymousImport("atkinson_mono_ttf", .{
        .root_source_file = b.path("examples/assets/fonts/atkinson_mono.ttf"),
    });
    // Available to every example but only @embedFile'd (and thus included) by
    // music_streaming — an anonymous import is free unless referenced.
    user_mod.addAnonymousImport("sample_ogg", .{
        .root_source_file = b.path("assets/sample.ogg"),
    });
    user_mod.addAnonymousImport("test_sine_wav", .{
        .root_source_file = b.path("examples/assets/test_sine.wav"),
    });
    return user_mod;
}

/// Wire one shader (VS or FS) into `target_mod`: the compiled WGSL
/// (`<basename>.wgsl`) + its IO schema module (`<basename>_io.zig`), and — when
/// the shader produced externs — the externs module + the CPU-side source
/// (`<basename>.zig`). Uniform across VS/FS; expects examples/<basename>.zig +
/// examples/<basename>_io.zig. Over-provisions imports (an unused module import
/// is lazy/harmless) so every shader example wires exactly the same way.
fn addShaderDep(
    b: *std.Build,
    target_mod: *Module,
    shader_pipeline: *ShaderPipeline,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
    basename: []const u8,
) void {
    const src: LazyPath = b.path(b.fmt("examples/{s}.zig", .{basename}));
    const io_path: LazyPath = b.path(b.fmt("examples/{s}_io.zig", .{basename}));
    const sh: ShaderPipeline.ShaderOutput = shader_pipeline.addShaderEx(src, .{
        .shader_io = io_path,
        .shader_basename = basename,
        .emit_wgsl = true,
        .wgsl_strict = true,
    });
    const wgsl: LazyPath = sh.wgsl orelse
        std.debug.panic("addShaderDep: {s} produced no WGSL", .{basename});
    target_mod.addAnonymousImport(b.fmt("{s}.wgsl", .{basename}), .{ .root_source_file = wgsl });

    const io_name: []const u8 = b.fmt("{s}_io.zig", .{basename});
    const io_mod: *Module = b.createModule(.{
        .root_source_file = io_path,
        .imports = &.{
            .{ .name = "zm", .module = zimrmath_mod },
            .{ .name = "shader_interface", .module = shader_interface_mod },
        },
    });
    target_mod.addImport(io_name, io_mod);

    if (sh.externs) |externs_lp| {
        const externs_name: []const u8 = b.fmt("{s}_externs", .{basename});
        const externs_mod: *Module = b.createModule(.{
            .root_source_file = externs_lp,
            .imports = &.{
                .{ .name = "zm", .module = zimrmath_mod },
                .{ .name = io_name, .module = io_mod },
            },
        });
        target_mod.addAnonymousImport(b.fmt("{s}.zig", .{basename}), .{
            .root_source_file = src,
            .imports = &.{
                .{ .name = "zm", .module = zimrmath_mod },
                .{ .name = "shader_interface", .module = shader_interface_mod },
                .{ .name = io_name, .module = io_mod },
                .{ .name = externs_name, .module = externs_mod },
            },
        });
    }
}

/// Given a prepared example module, wire the generic runner as the exe root
/// (it imports the example as `user_app`) + the install/smoke/bundle/standalone
/// steps. Shared by addWgpuApp and addWgpuShaderApp so the runner plumbing
/// lives in exactly one place.
fn finishWgpuApp(
    b: *std.Build,
    c2js_exe: *Compile,
    wgpu_smoke_install: *Step,
    smoke_focus: []const u8,
    wasm_target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zimr_mod: *Module,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
    buildaux_exe: *Compile,
    user_mod: *Module,
    name: []const u8,
    title: []const u8,
    own_frame: bool,
    /// Set from `App.job_kernels`. Compiles examples/<name>/kernels.zig into a separate,
    /// zero-import wasm for the Web Workers, and inlines it into the page.
    kernel_wasm: ?LazyPath,
) *Compile {
    const under: []const u8 = name;
    const dash_name: []const u8 = blk: {
        const o: []u8 = b.allocator.dupe(u8, name) catch @panic("oom");
        for (o) |*ch| {
            if (ch.* == '_') {
                ch.* = '-';
            }
        }
        break :blk o;
    };
    const dash: []const u8 = dash_name;
    // Served pages live UNDER the serve root (zig-out/web/<name>/) so the gallery
    // (zig-out/web/index.html) links to "<name>/" and the dev server serves them.
    // The `dash` step name (wgpu-<name>) is unchanged — only the output dir moved.
    const install_dir: std.Build.InstallDir = .{ .custom = b.fmt("web/{s}", .{name}) };

    // Own-frame demos ARE the exe (their own main owns the GPU frame); ticked
    // examples are wrapped by the generic runner, which imports them as
    // `user_app` and drives beginDrawing/clearBackground/endDrawing.
    const exe: *Compile = if (own_frame)
        b.addExecutable(.{ .name = under, .root_module = user_mod })
    else blk: {
        const mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/wgpu_runner.zig"),
            .target = wasm_target,
            .optimize = optimize,
        });
        mod.addImport("zimr", zimr_mod);
        mod.addImport("zm", zimrmath_mod);
        mod.addImport("shader_interface", shader_interface_mod);
        mod.addImport("user_app", user_mod);
        break :blk b.addExecutable(.{ .name = under, .root_module = mod });
    };
    exe.wasi_exec_model = .reactor;
    exe.entry = .disabled;
    exe.rdynamic = true;
    const install_art: *InstallArtifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = install_dir },
    });
    // Own-frame demos run their own loop, not the smoke harness's tick contract.
    if (!own_frame) {
        addWgpuSmoke(b, c2js_exe, wgpu_smoke_install, smoke_focus, exe, under);
    }
    // ZIG_BRIDGE Phase 4b: the example's SERVED page is the bridge page.
    // Installed as <dash>/index.html, so `zig build serve` / run-<name> /
    // the HMR client (injected into every .html response) all keep
    // working with zero server.ts changes. The old per-example bun
    // bundle of src/bridge.zig and the examples/<name>/index.html copy
    // are gone — the runtime is born as Zig now.
    const page: LazyPath = bridgePage(b, c2js_exe, exe, title, true, kernel_wasm); // streaming
    const index_install: *InstallFile = b.addInstallFileWithDir(
        page,
        install_dir,
        "index.html",
    );
    const step: *Step = b.step(dash, b.fmt("Build the {s} app demo", .{name}));
    step.dependOn(&install_art.step);
    step.dependOn(&index_install.step);
    _ = addWgpuStandalone(
        b,
        c2js_exe,
        exe,
        b.fmt("{s}.html", .{under}),
        title,
        b.fmt("{s}-standalone", .{dash}),
        b.fmt("Build the {s} app as a single self-contained HTML", .{name}),
        kernel_wasm,
    );
    _ = buildaux_exe;
    return exe;
}

/// Compile an example's `kernels.zig` into the separate, freestanding, ZERO-IMPORT wasm
/// that the Web Workers instantiate.
///
/// Three things worth knowing:
///
///   * THE ROOT IS GENERATED. The example author never writes it — exactly as the
///     gen_externs bootstrap is generated. All it does is ask the registry to emit its
///     exports, which keeps `exportWorkerEntry` (and the worker's buffers) OUT of the
///     app's wasm, where they would be dead weight.
///
///   * IT IS A DIFFERENT TARGET. The app is wasm32-wasi; a worker's kernel is
///     wasm32-freestanding, so it needs its OWN module instances — a Module carries its
///     target, and these cannot be shared with the app's.
///
///   * IT MUST IMPORT NOTHING. `kernels.zig` imports `zimr` like any example, but Zig's
///     lazy analysis only compiles what the kernel actually REACHES — so a pure kernel
///     drags in no DOM, no WebGPU, no WASI, and the import section comes out empty. That
///     is what lets a worker instantiate it with `{}`. c2js ASSERTS the section is empty
///     when it inlines the wasm, so a kernel that reaches for `zimr.drawText` is a build
///     error naming the offending import — not a worker that dies in a thread nobody is
///     watching.
/// THE WEB WORKER'S PROGRAM — Zig, compiled to JavaScript.
///
///     src/jobs_worker.zig --(build-obj -ofmt=c)--> .c --(c2js)--> .js
///
/// The browser will only start a worker from a JavaScript program, so this file cannot be
/// eliminated — but it does not have to be WRITTEN. It used to be ~40 lines of hand-written JS
/// living in a Zig string in bridge.zig: the only hand-written JS in the engine, and the
/// source of our two worst bugs (an ABI spelled twice with nothing checking it, and an `async`
/// handler whose `await` let a job re-enter before the kernel wasm had instantiated).
///
/// Now it is Zig, and the same compiler that checks everything else checks it.
fn buildWorkerJs(b: *std.Build, c2js_exe: *Compile) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    to_c.addFileArg(b.path("src/jobs_worker.zig"));
    const worker_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "jobs_worker.c");

    const to_js: *Run = b.addRunArtifact(c2js_exe);
    to_js.setStdIn(.{ .lazy_path = worker_c });
    return to_js.captureStdOut(.{});
}

fn buildJobKernels(
    b: *std.Build,
    name: []const u8,
    /// Other examples whose `kernels.zig` this one imports, as `k_<dep>`.
    ///
    /// The launcher needs this: a page carries ONE kernel wasm, but the launcher bundles many
    /// examples, so its `kernels.zig` merges their tables into a single registry. That works
    /// because the wasm exports are keyed by NAME rather than an index or a hash — a merged
    /// wasm exports a superset of the names, so every example's `submit` finds its kernel and
    /// nobody renumbers anything.
    deps: []const []const u8,
    optimize: std.builtin.OptimizeMode,
    build_opts_wgpu: *Options,
    build_opts_zm: *Options,
) LazyPath {
    const target: ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const zm_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimrmath.zig"),
        .target = target,
        .optimize = optimize,
    });
    zm_mod.addOptions("build_options", build_opts_zm);

    const iface_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/shader_interface.zig"),
        .target = target,
        .optimize = optimize,
    });
    iface_mod.addImport("zm", zm_mod);

    const engine_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_mod.addImport("zm", zm_mod);
    engine_mod.addImport("shader_interface", iface_mod);
    engine_mod.addOptions("build_options", build_opts_wgpu);

    // A kompute MODULE can be a job kernel — `komputeRegistry(M)` derives the whole worker
    // backend from one — so the kernel wasm's graph has to carry `kompute` too.
    const kompute_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/kompute.zig"),
        .target = target,
        .optimize = optimize,
    });
    kompute_mod.addImport("zm", zm_mod);

    // One module per example's kernels.zig. They all share the SAME engine/kompute/zm module
    // instances — creating a second `kompute` module would put src/kompute.zig in two modules
    // at once, which Zig rejects ("file exists in modules 'kompute' and 'kompute0'").
    const makeKernelsMod = struct {
        fn f(
            bb: *std.Build,
            ex: []const u8,
            t: ResolvedTarget,
            o: std.builtin.OptimizeMode,
            em: *Module,
            km: *Module,
            zmm: *Module,
        ) *Module {
            const m: *Module = bb.createModule(.{
                .root_source_file = bb.path(bb.fmt("examples/{s}/kernels.zig", .{ex})),
                .target = t,
                .optimize = o,
            });
            m.addImport("zimr", em);
            m.addImport("kompute", km);
            m.addImport("zm", zmm);
            return m;
        }
    }.f;

    const kernels_mod: *Module = makeKernelsMod(b, name, target, optimize, engine_mod, kompute_mod, zm_mod);
    for (deps) |dep| {
        const dm: *Module = makeKernelsMod(b, dep, target, optimize, engine_mod, kompute_mod, zm_mod);
        kernels_mod.addImport(b.fmt("k_{s}", .{dep}), dm);
    }

    const wf: *std.Build.Step.WriteFile = b.addWriteFiles();
    const root_src: LazyPath = wf.add("kernel_root.zig",
        \\//! GENERATED by build.zig - do not edit.
        \\//!
        \\//! The root of the KERNEL WASM: the little program each Web Worker instantiates.
        \\//! Its whole job is to ask the registry to emit its wasm exports (one
        \\//! `zimr_job_<name>` per kernel, plus the alloc/out/err protocol).
        \\//!
        \\//! It lives here, and not in the example, so that the APP - which imports
        \\//! kernels.zig for `registry.submit` - never links the worker's buffers.
        \\const kernels = @import("kernels");
        \\
        \\comptime {
        \\    kernels.registry.exportWorkerEntry();
        \\}
        \\
    );

    const root_mod: *Module = b.createModule(.{
        .root_source_file = root_src,
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("kernels", kernels_mod);

    const exe: *Compile = b.addExecutable(.{
        .name = b.fmt("{s}_kernels", .{name}),
        .root_module = root_mod,
    });
    exe.entry = .disabled; // no _start: a kernel wasm is a library of pure functions
    exe.rdynamic = true; // export the generated zimr_job_* symbols
    return exe.getEmittedBin();
}

/// The single-file bridge page for a wasm app: src/bridge.zig -> C ->
/// c2js --html --wasm-embed. The bridge transpile Run is byte-identical
/// across examples, so the build cache collapses it to one execution.
fn bridgePage(
    b: *std.Build,
    c2js_exe: *Compile,
    exe: *Compile,
    title: []const u8,
    streaming: bool,
    /// The example's job kernels, if it has any (see `App.job_kernels`). Inlined into
    /// the page as `window.ZIMR_KERNEL_WASM` — c2js refuses to inline it if its import
    /// section is non-empty, which is how kernel purity is enforced.
    kernel_wasm: ?LazyPath,
) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    to_c.addFileArg(b.path("src/bridge.zig"));
    const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
    const to_html: *Run = b.addRunArtifact(c2js_exe);
    // Full-canvas interactive demo on every page: the fullscreen-toggle button,
    // no orientation lock (portrait works exactly like landscape).
    to_html.addArgs(&.{ "--html", "--title", title, "--fullscreen-landscape" });
    if (streaming) {
        // The SERVED gallery page: STREAM the sibling .wasm (--wasm-url) and share
        // the ONE web/zimr.js runtime (--external-js, one dir up from web/<name>/)
        // instead of inlining 500KB per page. Needs the dev server.
        to_html.addArgs(&.{ "--wasm-url", b.fmt("{s}.wasm", .{exe.name}), "--external-js", "../zimr.js" });
    } else {
        // The STANDALONE twin: base64-inline BOTH the wasm and the runtime into one
        // self-contained file that opens straight from file://.
        to_html.addArg("--wasm-embed");
        to_html.addFileArg(exe.getEmittedBin());
    }
    // The kernel wasm rides along on BOTH paths — inlined even on the streamed page,
    // because at ~20 KB it is not worth a second request.
    if (kernel_wasm) |kw| {
        to_html.addArg("--kernel-wasm-embed");
        to_html.addFileArg(kw);
    }

    // The worker's program, on EVERY page. `jobs.parallel()` is a runtime question — an app
    // with no kernels never spawns a worker and never reads this — but a page that CAN spawn
    // one must already be carrying the program, because `new Worker(url)` cannot go and fetch
    // it later from a blob: origin.
    to_html.addArg("--worker-js-embed");
    to_html.addFileArg(buildWorkerJs(b, c2js_exe));

    to_html.setStdIn(.{ .lazy_path = bridge_c });
    return to_html.captureStdOut(.{});
}

/// Register a descriptor-only wgpu example with ONE call. `name` is the
/// underscore base (e.g. "bouncing_ball"); source is examples/wgpu_<name>/
/// wgpu_<name>.zig, and all step/output names derive from it. The exe root is
/// the generic runner (src/wgpu_runner.zig) which imports the example as
/// `user_app`, owns the frame (beginDrawing/clearBackground/endDrawing), and
/// ticks the app. Examples add deps declaratively on the `App` row: `shaders`
/// (render shaders by basename) and `compute_kernels` (kompute kernels); both
/// flow through buildAppModule + finishWgpuApp. Examples that own their own GPU
/// frame (low-level 3D) keep a bespoke manual block instead.
/// A servable wgpu example: a user source module turned into a wasm reactor
/// exe + served page + standalone HTML. `shaders` (basenames like "julia_fs")
/// wires each compiled WGSL + its IO module into the example; an empty list
/// means a plain app. This is the unified form of the old addWgpuApp /
/// addWgpuShaderApp split — the shader loop is simply a no-op when empty.
/// One engine shader's compiled WGSL, exposed by name so an example whose
/// `configure` hook calls `wireEngineWgsl` can `@embedFile` it. A pre-filtered
/// view of the build's `engine_shaders` list (only entries that emitted WGSL).
pub const EngineWgsl = struct {
    name: []const u8,
    path: LazyPath,
};

/// A servable wgpu example: a user source module turned into a wasm reactor
/// exe + served page + standalone HTML. `shaders` (basenames like "julia_fs")
/// wires each compiled WGSL + its IO module into the example; an empty list
/// means a plain app. This is the unified form of the old addWgpuApp /
/// addWgpuShaderApp split — the shader loop is simply a no-op when empty.
///
/// `root_source_file` is null for zimr's own examples (the path is derived from
/// `name` via the examples/wgpu_<name>/ convention) and set explicitly by an
/// external consumer pointing at their own app source.
///
/// `configure` is the escape hatch for anything the common fields don't cover
/// (build-time asset baking, extra named embeds): a small named function that
/// runs after the standard wiring, before the exe is finished. It keeps the
/// struct from growing a field per special case — the variation lives in
/// composable functions (see `configureHelmetSw`), not in this type. null for
/// the common case. The same hook is what an external program supplies for its
/// own app's build needs.
pub const App = struct {
    name: []const u8,
    title: []const u8,
    root_source_file: ?LazyPath = null,
    shaders: []const []const u8 = &.{},
    /// When true, the example IS the exe root and owns its GPU frame (its own
    /// main loop calls beginFrame/endFrame) instead of being ticked by the
    /// shared `wgpu_runner`. Low-level 3D demos use this. They still get the
    /// same build glue (module, shaders, page, standalone, step) — only the exe
    /// root differs. Own-frame examples are not smoke-tested.
    own_frame: bool = false,
    /// Opt-in GPU compute. When non-empty, the example also imports `kompute`
    /// and each kernel is compiled (Zig -> SPIR-V -> WGSL) and wired in — the
    /// only thing that used to require a separate `addWgpuComputeApp`. Set this
    /// field to add compute to an example; nothing else moves.
    compute_kernels: []const ComputeKernel = &.{},
    /// Opt-in off-main-thread jobs (`zimr.jobs`). When true, `examples/<name>/kernels.zig`
    /// is ALSO compiled — separately, for wasm32-freestanding — into a small, ZERO-IMPORT
    /// wasm that the Web Workers instantiate, and that wasm is base64-inlined into the
    /// page beside the app's own.
    ///
    /// Two wasms, because a worker cannot run the app's: it has no DOM and no WebGPU, so
    /// 96 of the app's imports would be missing, and its 31 MB of linear memory would be
    /// paid PER WORKER. The kernel wasm imports nothing and starts at ~1 MB.
    ///
    /// Set this field to add jobs to an example; nothing else moves.
    job_kernels: bool = false,
    configure: ?*const fn (AppContext, *Module) void = null,
};

/// A shader's deduplicated modules, cached per basename so a shader used by
/// several examples (e.g. `trivial_vs`) is wired ONCE. Putting the same
/// source file into two modules in one compilation is an error, which a combined
/// launcher binary would hit; sharing the module instances avoids it.
pub const ShaderDep = struct {
    wgsl_mod: *Module,
    io_mod: *Module,
    io_name: []const u8,
    src_mod: ?*Module,
};

/// The shared build context threaded into every example, bundled once so a
/// registration is `ctx.addApp(.{ .name = ..., .title = ... })` rather than an
/// 11-argument call. (A later step promotes this and `addApp` into the public
/// `zimr_build` surface so external programs build zimr apps the same way.)
pub const AppContext = struct {
    b: *std.Build,
    wgpu_smoke_install: *Step,
    smoke_focus: []const u8,
    wasm_target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zimr_mod: *Module,
    zimrmath_mod: *Module,
    /// The ONE `kompute` module, shared by EVERY compute example. See its creation site: built
    /// per-example, two compute examples on one page collide as `kompute`/`kompute0`.
    kompute_mod: *Module,
    shader_interface_mod: *Module,
    buildaux_exe: *Compile,
    c2js_exe: *Compile,
    shader_pipeline: *ShaderPipeline,
    /// Pre-filtered engine-shader WGSL (name + path); consumed by the
    /// `wireEngineWgsl` helper. Built once from the build's shader list.
    engine_wgsl: []const EngineWgsl,
    /// The build-time mesh baker; consumed by the `bakeMesh` helper.
    mesh_bake_exe: *Compile,
    /// Shared modules so common source files (common.zig, fonts, shaders) are
    /// each in exactly ONE module across the whole build — required so a launcher
    /// that imports many example modules into one binary does not duplicate them.
    common_mod: *Module,
    roboto_mod: *Module,
    atkinson_mod: *Module,
    ogg_mod: *Module,
    wav_mod: *Module,
    shader_cache: *std.StringHashMap(ShaderDep),
    /// Needed to build an example's job-kernel wasm: it is a DIFFERENT target
    /// (wasm32-freestanding, not wasi), so it needs its own module instances — and those
    /// need their own `build_options`.
    build_opts_wgpu: *Options,
    build_opts_zm: *Options,

    /// Example module using the SHARED common/font modules (no fresh per-example
    /// instances) so the file graph stays single-owner. Mirrors `buildUserMod`.
    pub fn buildUserModShared(ctx: AppContext, name: []const u8) *Module {
        const b: *std.Build = ctx.b;
        const under: []const u8 = name;
        const user_mod: *Module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/{s}.zig", .{ under, under })),
            .target = ctx.wasm_target,
            .optimize = ctx.optimize,
        });
        user_mod.addImport("zimr", ctx.zimr_mod);
        user_mod.addImport("zm", ctx.zimrmath_mod);
        user_mod.addImport("shader_interface", ctx.shader_interface_mod);
        user_mod.addImport("example_common", ctx.common_mod);
        user_mod.addImport("roboto_mono_ttf", ctx.roboto_mod);
        user_mod.addImport("atkinson_mono_ttf", ctx.atkinson_mod);
        user_mod.addImport("sample_ogg", ctx.ogg_mod);
        user_mod.addImport("test_sine_wav", ctx.wav_mod);
        return user_mod;
    }

    /// Memoized `addShaderDep`: a shader basename is wired once into shared
    /// modules, then imported into each example that uses it.
    pub fn addShaderDepShared(
        ctx: AppContext,
        target_mod: *Module,
        basename: []const u8,
    ) void {
        const b: *std.Build = ctx.b;
        const dep: ShaderDep = ctx.shader_cache.get(basename) orelse blk: {
            const src: LazyPath = b.path(b.fmt("examples/{s}.zig", .{basename}));
            const io_path: LazyPath = b.path(b.fmt("examples/{s}_io.zig", .{basename}));
            const sh: ShaderPipeline.ShaderOutput = ctx.shader_pipeline.addShaderEx(src, .{
                .shader_io = io_path,
                .shader_basename = basename,
                .emit_wgsl = true,
                .wgsl_strict = true,
            });
            const wgsl: LazyPath = sh.wgsl orelse
                std.debug.panic("addShaderDepShared: {s} produced no WGSL", .{basename});
            const wgsl_mod: *Module = b.createModule(.{ .root_source_file = wgsl });
            const io_name: []const u8 = b.fmt("{s}_io.zig", .{basename});
            const io_mod: *Module = b.createModule(.{
                .root_source_file = io_path,
                .imports = &.{
                    .{ .name = "zm", .module = ctx.zimrmath_mod },
                    .{ .name = "shader_interface", .module = ctx.shader_interface_mod },
                },
            });
            var src_mod: ?*Module = null;
            if (sh.externs) |externs_lp| {
                const externs_name: []const u8 = b.fmt("{s}_externs", .{basename});
                const externs_mod: *Module = b.createModule(.{
                    .root_source_file = externs_lp,
                    .imports = &.{
                        .{ .name = "zm", .module = ctx.zimrmath_mod },
                        .{ .name = io_name, .module = io_mod },
                    },
                });
                src_mod = b.createModule(.{
                    .root_source_file = src,
                    .imports = &.{
                        .{ .name = "zm", .module = ctx.zimrmath_mod },
                        .{ .name = "shader_interface", .module = ctx.shader_interface_mod },
                        .{ .name = io_name, .module = io_mod },
                        .{ .name = externs_name, .module = externs_mod },
                    },
                });
            }
            const d: ShaderDep = .{ .wgsl_mod = wgsl_mod, .io_mod = io_mod, .io_name = io_name, .src_mod = src_mod };
            ctx.shader_cache.put(basename, d) catch @panic("oom");
            break :blk d;
        };
        target_mod.addImport(b.fmt("{s}.wgsl", .{basename}), dep.wgsl_mod);
        target_mod.addImport(dep.io_name, dep.io_mod);
        if (dep.src_mod) |sm| {
            target_mod.addImport(b.fmt("{s}.zig", .{basename}), sm);
        }
    }

    /// Build just the example's user module (+ shader deps + configure hook),
    /// without finishing the exe. Lets the launcher capture each module and
    /// import several into one binary. `addApp` = this + `finishWgpuApp`.
    pub fn buildAppModule(ctx: AppContext, app: App) *Module {
        const user_mod: *Module = ctx.buildUserModShared(app.name);
        for (app.shaders) |shader_basename| {
            ctx.addShaderDepShared(user_mod, shader_basename);
        }
        if (app.compute_kernels.len > 0) {
            ctx.wireComputeKernels(user_mod, app.name, app.compute_kernels);
        }
        if (app.configure) |configure| {
            configure(ctx, user_mod);
        }
        return user_mod;
    }

    /// Wire GPU compute into an example's module: import `kompute` and compile
    /// each kernel (Zig -> SPIR-V -> WGSL). Kernels live alongside the example
    /// source at `examples/wgpu_<name>/<basename>.zig`.
    pub fn wireComputeKernels(
        ctx: AppContext,
        user_mod: *Module,
        name: []const u8,
        kernels: []const ComputeKernel,
    ) void {
        const b: *std.Build = ctx.b;

        // THE SHARED MODULE — not a fresh one. Minting one here per example is what produced
        // `kompute0` and made two compute examples unable to share a page. See its creation site.
        user_mod.addImport("kompute", ctx.kompute_mod);
        const under: []const u8 = name;
        for (kernels) |k| {
            if (k.entries) |entries| {
                ctx.shader_pipeline.addComputeKernelImports(
                    user_mod,
                    b.path(b.fmt("examples/{s}/{s}.zig", .{ under, k.basename })),
                    entries,
                );
            } else {
                ctx.shader_pipeline.addComputeImport(
                    user_mod,
                    b.path(b.fmt("examples/{s}/{s}.zig", .{ under, k.basename })),
                    b.fmt("{s}_wgsl", .{k.basename}),
                );
            }
        }
    }

    /// Build one example end to end: the user module (+ any shader deps), the
    /// runner exe, the served page, and the standalone. The one entry point.
    pub fn addApp(ctx: AppContext, app: App) *Compile {
        const user_mod: *Module = ctx.buildAppModule(app);
        // `job_kernels` is the entire opt-in: the example's kernels.zig becomes a second,
        // freestanding, zero-import wasm, inlined into the page for the Web Workers.
        const kernel_wasm: ?LazyPath = if (app.job_kernels)
            buildJobKernels(ctx.b, app.name, ctx.optimize, ctx.build_opts_wgpu, ctx.build_opts_zm)
        else
            null;
        return finishWgpuApp(
            ctx.b,
            ctx.c2js_exe,
            ctx.wgpu_smoke_install,
            ctx.smoke_focus,
            ctx.wasm_target,
            ctx.optimize,
            ctx.zimr_mod,
            ctx.zimrmath_mod,
            ctx.shader_interface_mod,
            ctx.buildaux_exe,
            user_mod,
            app.name,
            app.title,
            app.own_frame,
            kernel_wasm,
        );
    }
};

// ---- configure helpers ---------------------------------------------------
// Composable building blocks for an App's `configure` hook. Each does one
// thing to the example's module; a per-example configure function (or an
// external consumer's) calls whichever it needs. This is where special wiring
// lives instead of as fields on `App`.

/// Wire every engine shader's compiled WGSL into `mod` as a named embed, so the
/// example can `@embedFile` it (e.g. for z.pbr3d's pbr_vs/fs).
pub fn wireEngineWgsl(ctx: AppContext, mod: *Module) void {
    for (ctx.engine_wgsl) |wgsl| {
        mod.addAnonymousImport(wgsl.name, .{ .root_source_file = wgsl.path });
    }
}

/// Bake `glb` (project-relative) into a `<import_name>.zig` proxy mesh at build
/// time via `mesh_bake_exe` (grid = vertex-clustering resolution, base = baked
/// texture size) and import it under `import_name`.
pub fn bakeMesh(
    ctx: AppContext,
    mod: *Module,
    glb: []const u8,
    import_name: []const u8,
    grid: u32,
    base: u32,
) void {
    const bake_run: *Run = ctx.b.addRunArtifact(ctx.mesh_bake_exe);
    bake_run.addFileArg(ctx.b.path(glb));
    const baked_path: LazyPath = bake_run.addOutputFileArg(ctx.b.fmt("{s}.zig", .{import_name}));
    bake_run.addArg(ctx.b.fmt("{d}", .{grid}));
    bake_run.addArg(ctx.b.fmt("{d}", .{base}));
    mod.addAnonymousImport(import_name, .{ .root_source_file = baked_path });
}

/// helmet_sw: a CPU vs GPU comparison of one PBR shader. Embeds the engine
/// WGSL (pbr_vs/fs) and bakes a low-res proxy mesh for the comptime corner.
fn configureHelmetSw(ctx: AppContext, mod: *Module) void {
    wireEngineWgsl(ctx, mod);
    bakeMesh(ctx, mod, "examples/helmet_sw/DamagedHelmet.glb", "helmet_proxy", 16, 64);
}

/// shadowmap_sw: the shadow-map CPU | GPU | comptime side-by-side.  Engine
/// WGSL (depth_* + lit_shadow_*), the full bunny OBJ for the live halves, and
/// the decimated proxy (mesh_bake OBJ path) for the comptime corner.
fn configureCelShading(ctx: AppContext, mod: *Module) void {
    wireEngineWgsl(ctx, mod);
    mod.addAnonymousImport("bunny.obj", .{
        .root_source_file = ctx.b.path("examples/shadowmap/bunny.obj"),
    });
}

fn configureShadowmapSw(ctx: AppContext, mod: *Module) void {
    wireEngineWgsl(ctx, mod);
    mod.addAnonymousImport("bunny.obj", .{
        .root_source_file = ctx.b.path("examples/shadowmap/bunny.obj"),
    });
    bakeMesh(ctx, mod, "examples/shadowmap/bunny.obj", "bunny_proxy", 10, 2);
}

/// pbr demo: engine WGSL + the raw helmet glb as a named embed (it lives outside
/// the demo's package dir).
fn configurePbr(ctx: AppContext, mod: *Module) void {
    wireEngineWgsl(ctx, mod);
    mod.addAnonymousImport("DamagedHelmet.glb", .{
        .root_source_file = ctx.b.path("examples/assets/DamagedHelmet.glb"),
    });
}

/// gltf-textured demo: engine WGSL + the shared quad glb data module (also lives
/// outside the demo's package dir).
fn configureGltfTextured(ctx: AppContext, mod: *Module) void {
    wireEngineWgsl(ctx, mod);
    mod.addAnonymousImport("quad_glb_data.zig", .{
        .root_source_file = ctx.b.path("examples/quad_glb_data.zig"),
    });
}

/// Build a wgpu app from an EXTERNAL consumer's `build.zig`. The consumer passes
/// the resolved zimr dependency (`b.dependency("zimr", ...)`) and an `App` with
/// `root_source_file` set to their own app source; everything zimr-side (the
/// runner, example_common, font assets, the engine modules) is resolved through the
/// dependency package so the consumer needs no copy of zimr's tree.
///
/// Produces and installs the wasm reactor exe (the artifact the consumer runs).
/// Scope note: the served bridge page and single-file standalone are NOT wired
/// here yet — they depend on zimr's prebuilt `c2js`/buildaux tools, which aren't
/// exposed across the package boundary. Exposing those is the remaining step to
/// reach full parity with the internal `addApp`; until then a consumer bundles
/// the wasm with their own page (or zimr ships the tools as artifacts).
pub fn addAppExternal(
    b: *std.Build,
    zimr_dep: *std.Build.Dependency,
    optimize: std.builtin.OptimizeMode,
    app: App,
) *Compile {
    const wasm_target: ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });
    const zimr_mod: *Module = zimr_dep.module("zimr");
    const zimrmath_mod: *Module = zimr_dep.module("zimrmath");
    const shader_interface_mod: *Module = zimr_dep.module("shader_interface");

    const user_src: LazyPath = app.root_source_file orelse
        @panic("addAppExternal requires app.root_source_file");
    const user_mod: *Module = b.createModule(.{
        .root_source_file = user_src,
        .target = wasm_target,
        .optimize = optimize,
    });
    user_mod.addImport("zimr", zimr_mod);
    user_mod.addImport("zm", zimrmath_mod);
    user_mod.addImport("shader_interface", shader_interface_mod);
    const common_mod: *Module = b.createModule(.{
        .root_source_file = zimr_dep.path("examples/example_common/example_common.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    common_mod.addImport("zimr", zimr_mod);
    common_mod.addImport("zm", zimrmath_mod);
    user_mod.addImport("example_common", common_mod);
    user_mod.addAnonymousImport("roboto_mono_ttf", .{
        .root_source_file = zimr_dep.path("assets/RobotoMono-Regular.ttf"),
    });
    user_mod.addAnonymousImport("atkinson_mono_ttf", .{
        .root_source_file = zimr_dep.path("examples/assets/fonts/atkinson_mono.ttf"),
    });
    user_mod.addAnonymousImport("sample_ogg", .{
        .root_source_file = zimr_dep.path("assets/sample.ogg"),
    });

    const runner_mod: *Module = b.createModule(.{
        .root_source_file = zimr_dep.path("src/wgpu_runner.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    runner_mod.addImport("zimr", zimr_mod);
    runner_mod.addImport("zm", zimrmath_mod);
    runner_mod.addImport("shader_interface", shader_interface_mod);
    runner_mod.addImport("user_app", user_mod);

    const exe: *Compile = b.addExecutable(.{
        .name = app.name,
        .root_module = runner_mod,
    });
    exe.wasi_exec_model = .reactor;
    exe.entry = .disabled;
    exe.rdynamic = true;
    b.installArtifact(exe);
    return exe;
}

const ComputeKernel = struct {
    basename: []const u8,
    /// Multi-kernel modules (t1178): each named entry is translated to its
    /// own WGSL module (spv2wgsl --entry) imported as `<entry>_wgsl`.
    /// null = single-kernel module, imported as `<basename>_wgsl`.
    entries: ?[]const []const u8 = null,
};

fn addWgpuStandalone(
    b: *std.Build,
    c2js_exe: *Compile,
    exe: *std.Build.Step.Compile,
    out_basename: []const u8,
    title: []const u8,
    step_name: []const u8,
    step_desc: []const u8,
    kernel_wasm: ?LazyPath,
) *std.Build.Step {
    // ZIG_BRIDGE Phase 4a: the standalone IS the bridge page now — the
    // wasm embedded into a single-file HTML whose entire runtime was born
    // as Zig (src/bridge.zig -> C -> c2js). The TS bundle path (buildaux
    // wgpu-standalone + bun-bundled bridge JS) is superseded; its
    // params stay until the deletion sweep retires the bundle Runs.
    const page: LazyPath = bridgePage(b, c2js_exe, exe, title, false, kernel_wasm); // embed
    const out_path: []const u8 = b.fmt("standalone/{s}", .{out_basename});
    const inst: *InstallFile = b.addInstallFile(page, out_path);
    const step: *std.Build.Step = b.step(step_name, step_desc);
    step.dependOn(&inst.step);
    return step;
}

// Walk `.zig-cache` and bail out if total size exceeds 5 GB.  Zig's
// build cache is content-addressed and never garbage-collects on its
// own, so it grows monotonically across builds - eventually it fills
// the disk and you get cryptic "No space left on device" errors mid-
// link.  Catching the bloat here lets us print a one-line "rm -rf
// .zig-cache" remedy instead.
// To keep the per-build overhead negligible, the actual walk runs
// only every 4th build.  A tiny counter file in the cache itself
// (`.zig-cache/.zimr-build-count`) tracks how many builds we've
// seen; the size walk happens when count % N == 0.  Wiping the
// cache also wipes the counter, so the cycle restarts naturally
// after a manual cleanup.
// Cadence rationale: Turn 178 had the cache balloon from ~3 GB to
// 8 GB inside a single turn's worth of builds (~12 builds), past
// the threshold but in the middle of the previous interval-10
// window - disk filled before the next sample.  N=4 keeps the
// fast path cheap while shrinking the "miss" window enough that
// runaway growth is caught early.
// If anything goes wrong (cache missing, permissions, walker errors,
// counter file unreadable) the check silently skips - never blocks a
// build over its own bug.
/// Walk `src/`, `examples/`, `tests/` for shader source files matching
/// `_vs.zig` / `_fs.zig`.  Returns a list of paths relative to the
/// build root.  Used by the ZLS shadow-module registration: ZLS reads
/// `b.addModule(...)` calls but doesn't know about files compiled
/// directly via `zig build-obj`.  Walking the tree lets new shader
/// files get picked up automatically without editing build.zig.
fn collectShaderFiles(b: *std.Build) ![][]const u8 {
    // This function observes the *contents* of src/, examples/, and tests/ at
    // configure time — exactly the kind of untracked observation that the
    // Zig 0.17 configure cache cannot key on (the same reason std.Build's
    // `findProgram` poisons the cache: it walks PATH directories). Without
    // this, adding a new `*_vs.zig`/`*_fs.zig` is invisible until build.zig's
    // own content changes, because the cached configuration is reused and this
    // walk never re-runs. Poisoning forces the configurer to re-run every
    // build so discovery is always fresh. The cost is re-running the (already
    // compiled) configure phase, not recompiling build.zig — measured in
    // single-digit milliseconds for this graph; the maker still caches all
    // compilation independently.
    b.graph.poisonCache();
    const io: std.Io = b.graph.io;
    var paths: ArrayList([]const u8) = .empty;
    // Scan zimr's OWN tree via the build root, not cwd: when zimr is consumed as
    // a dependency, cwd is the consumer's project root (where these dirs don't
    // exist), which silently yielded zero shaders and broke the engine's
    // `@embedFile("default_shapes_vs.wgsl")` downstream. `b.root.root_dir.handle`
    // is zimr's package root in both the root and dependency builds.
    const root_dir: std.Io.Dir = b.root.root_dir.handle;
    for ([_][]const u8{ "src", "examples", "tests" }) |root| {
        var dir: std.Io.Dir = root_dir.openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker: std.Io.Dir.Walker = dir.walk(b.allocator) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const name: []const u8 = entry.basename;
            if (!endsWith(u8, name, "_vs.zig") and !endsWith(u8, name, "_fs.zig")) {
                continue;
            }
            const full: []const u8 = b.fmt("{s}/{s}", .{ root, entry.path });
            // `entry.path` uses OS separators (backslash on Windows).
            // Normalize to forward slash for `b.path()` consistency.
            const normalized: []u8 = b.allocator.dupe(u8, full) catch continue;
            for (normalized) |*c| {
                if (c.* == '\\') {
                    c.* = '/';
                }
            }
            try paths.append(b.allocator, normalized);
        }
    }
    return paths.toOwnedSlice(b.allocator);
}

/// `@floatFromInt` to f64. The lint prefers `zm.float64`, but build.zig is the
/// build SCRIPT — it has no `zm` module in scope and pulling zimrmath into the
/// build graph to convert four integers would be a silly dependency.
/// lint:off float-from-int: build.zig has no zm module (it builds the one that has it)
fn f64of(x: u64) f64 {
    return @floatFromInt(x);
}

/// Free-space report for the filesystem holding the build root.
const DiskSpace = struct {
    free_bytes: u64,
    /// Percent USED, computed the way `df` does it — (blocks - bfree) over
    /// (blocks - bfree + bavail) — so the number here matches the number the
    /// developer sees in a terminal. Reserved-for-root blocks are excluded from
    /// "available" but counted in "used", which is why this is not simply
    /// 1 - free/total.
    used_pct: f64,
};

/// x86_64 Linux `struct statfs`. Zig's std exposes the syscall NUMBER but no
/// wrapper and no struct, so the ABI is spelled out here. Stable since forever.
const LinuxStatfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

const Kernel32 = struct {
    extern "kernel32" fn GetDiskFreeSpaceExA(
        directory_name: ?[*:0]const u8,
        free_bytes_available_to_caller: ?*u64,
        total_number_of_bytes: ?*u64,
        total_number_of_free_bytes: ?*u64,
    ) callconv(.winapi) c_int;
};

/// Returns null when we cannot measure — in which case the caller does NOT block
/// the build. Never fail a developer's build over our own inability to stat a
/// filesystem.
fn diskSpace() ?DiskSpace {
    switch (builtin.os.tag) {
        .linux => {
            var st: LinuxStatfs = undefined;
            const rc: usize = std.os.linux.syscall2(
                .statfs,
                @intFromPtr("."),
                @intFromPtr(&st),
            );
            if (@as(isize, @bitCast(rc)) < 0 or st.f_bsize <= 0) {
                return null;
            }
            const bsize: u64 = @intCast(st.f_bsize);
            const used_blocks: u64 = st.f_blocks -| st.f_bfree;
            const denom: u64 = used_blocks + st.f_bavail;
            if (denom == 0) {
                return null;
            }
            return .{
                .free_bytes = st.f_bavail * bsize,
                .used_pct = 100.0 * f64of(used_blocks) / f64of(denom),
            };
        },
        .windows => {
            var avail: u64 = 0;
            var total: u64 = 0;
            if (Kernel32.GetDiskFreeSpaceExA(".", &avail, &total, null) == 0 or total == 0) {
                return null;
            }
            const used: u64 = total -| avail;
            return .{
                .free_bytes = avail,
                .used_pct = 100.0 * f64of(used) / f64of(total),
            };
        },
        else => return null,
    }
}

/// Guard against the ONLY failure that actually matters: running out of disk
/// mid-link, which surfaces as a cryptic "No space left on device" with no other
/// warning.
///
/// This used to guard on `.zig-cache` SIZE (6 GB on Linux) — but cache size is a
/// PROXY, and a bad one. A 6 GB cache on a disk with 100 GB free is harmless; a
/// 2 GB cache with 200 MB free is fatal. The proxy fired constantly on healthy
/// disks and its remedy — `rm -rf .zig-cache` — costs a ~16-minute cold rebuild.
/// We were paying full rebuilds to avoid a problem we did not have.
///
/// So: measure the hazard. Fail only when the filesystem is ≥ 90% full, which is
/// a single O(1) syscall — cheap enough to run on EVERY build, so the periodic
/// walk (and its counter file) is gone too.
fn checkDiskSpace(b: *std.Build) void {
    const fail_at_pct: f64 = 90.0;

    const space: DiskSpace = diskSpace() orelse return; // cannot measure => do not block
    if (space.used_pct < fail_at_pct) {
        return;
    }

    // Only now is it worth walking the cache — to tell the developer where the
    // space actually went. This is the rare path.
    const io: std.Io = b.graph.io;
    var cache_bytes: u64 = 0;
    if (std.Io.Dir.cwd().openDir(io, ".zig-cache", .{ .iterate = true })) |dir_const| {
        var dir: std.Io.Dir = dir_const;
        defer dir.close(io);
        if (dir.walk(b.allocator)) |walker_const| {
            var walker: std.Io.Dir.Walker = walker_const;
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                const stat: std.Io.Dir.Stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                cache_bytes += stat.size;
            }
        } else |_| {}
    } else |_| {}

    const gb: f64 = 1024.0 * 1024.0 * 1024.0;
    std.debug.print(
        \\
        \\  Disk is {d:.0}% full ({d:.1} GB free) — refusing to build.
        \\
        \\  Running out of space mid-link fails with a cryptic "No space left on
        \\  device" and no other warning, so we stop here instead.
        \\
        \\  .zig-cache is currently {d:.1} GB.
        \\
        \\  Free space cheapest-first:
        \\    rm -rf zig-out          # regenerable build outputs
        \\    rm -rf .zig-cache/tmp   # scratch
        \\    rm -rf .zig-cache       # LAST RESORT: costs a full cold rebuild
        \\
        \\
    , .{ space.used_pct, f64of(space.free_bytes) / gb, f64of(cache_bytes) / gb });
    std.process.exit(1);
}

// ============================================================================
// Zig-shader pipeline helpers — Phase 3 surface.
// ============================================================================
// ShaderPipeline + ShaderOpts now live in `src/shader_codegen.zig` so they
// can be re-exposed as a public `zimr_build` module for downstream
// `build.zig` consumers.  Internally we alias for call-site brevity.

const zimr_build = @import("src/shader_codegen.zig");
const ShaderPipeline = zimr_build.ShaderPipeline;
