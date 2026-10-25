// build.zig - zimr (pure-Zig raylib 6.0 port for wasm + WebGL2)
// Target: wasm32-wasi.  WASI gives us a real Zig stdlib (allocator,
// std.fs, std.time, std.log) without dragging in emscripten or libc.
// Browsers don't run WASI natively; we provide a tiny JS shim for the
// few WASI calls we use (fd_write, clock_time_get, random_get,
// proc_exit, args_*, environ_*, fd_close), plus our own custom
// `webgl` / `dom` import modules for canvas, WebGL2, and event input.
// Build steps:
//   zig build                       -- zimr.js, the gallery and the HTML doc pages into
//                                      zig-out/web/; no example wasms, no API docs.
//   zig build <app-step>            -- builds one app for -Dplatform (default: this
//                                      machine's).  web: zig-out/web/<app_name>/ and
//                                      zig-out/standalone/<app_name>.html
//                                      (`hello-world` -> web/hello_world/); windows:
//                                      the program in zig-out/windows/; android: the
//                                      single-file page in an app, zig-out/android/
//                                      <app_name>.apk (needs the Android SDK and a JDK).
//   zig build run-<app-step>        -- builds one app the same way, then runs it.
//                                      android: installs it on the phone adb sees and
//                                      starts it.  windows: the program.  web: its page, through
//                                      the dev server, in the default browser; when a
//                                      server already runs, it reloads the tabs showing
//                                      the page instead (opening one if none does) and
//                                      the step ends - so `zig build --watch
//                                      run-<app-step> -Dplatform=web` beside a running
//                                      `serve-only` reloads the page on every save.
//   zig build run                   -- every example, then the gallery: natively the
//                                      program that starts them, on the web its page.
//   zig build all-examples          -- builds every example for -Dplatform
//   zig build serve                 -- builds every example's web build, then serves
//                                      zig-out/web/ on 127.0.0.1:8080 via the
//                                      pure-Zig server (tools/serve.zig).  Full gallery.
//   zig build serve-only            -- starts the same server after only the default
//                                      install (no example wasms).  The editor debug
//                                      configs pair it with one
//                                      `zig build <app-step> -Dplatform=web` each; a
//                                      plain build does not reload the page, so reload
//                                      it after a rebuild (or rebuild with run-<app-step>).
//   zig build smoke-test            -- runs the wasm smoke tests under Node
//                                      (webtests/runner.mjs); -Dfocus=<list> narrows them
//   zig build test                  -- runs the host-target unit tests + every
//                                      example's typecheck (cheap, all of them)
// Source-of-truth for the port: the raylib 6.0 C source lives under
// raylib_src/ in this repo.  We are NOT tracking upstream raylib past
// 6.0 - every Zig function corresponds to a function in that snapshot
// and behavioural parity is verified against it.

const std = @import("std");
const builtin = @import("builtin");

const ArrayList = std.ArrayList;

const endsWith = std.mem.endsWith;

const eql = std.mem.eql;

const startsWith = std.mem.startsWith;

// Local aliases for the std.Build types this file works with.  See
// `src/shader_codegen.zig` for the rationale - rule 2 (untyped-local)
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

const Io = std.Io;

const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const StringHashMap = std.StringHashMap;

const indexOf = std.mem.indexOf;

const indexOfScalar = std.mem.indexOfScalar;

const splitScalar = std.mem.splitScalar;

const sortSlice = std.mem.sort;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;

// (`builtin` was imported only for the disk-space switch, which now lives in
//  tools/fs_space.zig. Removed rather than left as an unused import.)

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
///   - `iface = null`        -> iface declared inline at the top of
///                              the shader source file (default - the
///                              common case).
///   - `iface = "<basename>"` -> iface lives in `examples/<basename>.zig`,
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
    /// directly (`@import("default_shapes_vs.zig")` -> which in
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

/// The host-side tool executables, built once and shared. Returned as a set
/// so build() can destructure them without threading eight separate values.
/// Every zimrlint rule - each is OPT-IN, so a build names the rules it holds its sources to (zimr's own in
/// `zimr_lint_rules`, an app's in `addLint`'s / `Project`'s `.lint.enable`) and nothing runs by accident.
/// Field names are the rule tags with `-` spelled `_`, in `rule_notes` order (tools/zimrlint.zig); the linter
/// rejects a name that is not a rule, so this list cannot silently drift. The comment is the rule's title.
pub const LintRule = enum {
    import_cycle, // files must not import each other, directly or through others
    raw_pass_state_bind, // bind pipeline/bind-groups through the PassState cache
    parse_error, // file failed to parse, AST checks skipped
    zig_fmt, // the file is laid out as `zig fmt` lays it out
    fn_args_multiline, // Rule 1 - fn signatures: 5+ args multiline; 3-4 args one-line only if <=90 cols
    untyped_local, // Rule 2 - locals: write the type even when Zig can deduce it
    branch_braces, // Rule 3 - braces required on every if/else/while/for body
    array_mult, // Rule 5 - array repetition: use @splat, not `**`
    module_var, // Rule 9 - no module-level mutable globals
    depth_format, // 3D render needs a depth attachment
    line_length, // Rule 10 - lines under 120 columns
    ascii_comments, // Comments are ASCII
    ascii_test_names, // Test names are ASCII
    named_struct_init, // Rule 15 - use `.{...}` when the LHS already declares the type
    prefer_decl_literal, // `.make(...)` when the declaration already names the type
    constructor_in_view, // a decl-literal constructor only where its declaration names the type
    turn_in_radian_call, // a pi or tau inside a trig argument means you wanted turns
    std_math, // no std.math outside zimrmath (GPU-portability)
    std_debug_assert, // no std.debug.assert outside tools
    import_at_top, // std/builtin/root imports belong at file scope
    clamp_pattern, // Bonus rule - prefer zm.clamp over @min(@max())
    as_round, // Rule - no @as(T, @trunc(x)); use bare builtin or zm.* helper
    redundant_cast, // Rule - drop the cast helper when the decl already gives the type
    int_from_float, // Rule - use @trunc/@floor/@round directly, not @intFromFloat
    reserved_math_names, // Rule - reserved math vocabulary: don't shadow the zm.* core
    prefer_vec, // Rule - prefer `Vec` over the verbose `@Vector(4, f32)`
    anon_return, // name the struct a function returns
    shader_inline_fn, // Shader rule - no `inline fn` in `_fs.zig` / `_vs.zig`
    shader_no_atan, // Shader rule - `@atan` / `@atan2` not available under SPIR-V
    sampler_in_branch, // Shader rule - sample textures at the top of shaderMain, not in a branch
    sampler_in_helper, // Shader rule - texture samples belong in shaderMain, not helper fns
    decl_order, // declare file-scope names before they are used
    whole_init_first, // fill uninitialised memory with ONE whole-struct write
    returned_stack_reference, // never return a pointer to a local
    catch_suppression, // make swallowing an error a conscious choice
    prefer_assert_unreachable, // name the impossible, with a message
    no_catch_return, // `catch |e| return e` is just `try`
    unused_global, // a private file-scope decl nothing references
    useless_error_return, // `!T` on a fn whose body can't error
    duplicate_case, // two switch prongs with the same body
    redundant_import, // the module already has a file-scope alias
    canonical_alias, // import a module under the name it declares
    import_at_root, // bind imports at container scope, not mid-expression
    state_uninit, // an app's State must be born from a `.{...}` literal
    no_qualified_zm, // bind zm math keywords once at file scope, use them bare
    no_qualified_std, // bind the hot std names once at file scope, use them bare
    custom_degrad, // one spelling for degree/radian conversion
    no_std_timer, // std.time.Timer does not exist in the pinned std
    debug_print, // no std.debug.print in code that ships as wasm
    float_from_int, // `@as(f32, @floatFromInt(x))` is `zm.float(x)`
    prefer_splat, // `@as(Vec, @splat(x))` is `splat(x)`
    shader_safe, // a SHADER-SAFE file stays compilable for the GPU
    scope_balance, // every begin{X} in a function has its end{X}
    screaming_const, // value consts are snake_case, at every depth
    shader_missing_entry, // a shader body must bind its SPIR-V entry
    unknown_lint_tag, // a `lint:off` names a rule that does not exist
    arch_check, // ask the host's facts, not the processor
    browser_call, // reach the browser through the platform contract
    own_clock, // read the platform's clock, not the system's
    process_exit, // only a program's entry point exits
};

/// The rules zimr holds its own sources to: every rule. (`decl_order` joined last, once the tree was in order:
/// each file reads in layers, vocabulary first and entry points last; real cycles carry an explained per-site
/// directive, and ui.zig - kept in feature order, each widget beside its helpers - an explained file-level one.)
const zimr_lint_rules = [_]LintRule{
    .import_cycle,
    .raw_pass_state_bind,
    .parse_error,
    .zig_fmt,
    .fn_args_multiline,
    .untyped_local,
    .branch_braces,
    .array_mult,
    .module_var,
    .depth_format,
    .line_length,
    .ascii_comments,
    .ascii_test_names,
    .named_struct_init,
    .turn_in_radian_call,
    .std_math,
    .std_debug_assert,
    .import_at_top,
    .clamp_pattern,
    .as_round,
    .redundant_cast,
    .int_from_float,
    .reserved_math_names,
    .prefer_vec,
    .anon_return,
    .shader_inline_fn,
    .shader_no_atan,
    .sampler_in_branch,
    .sampler_in_helper,
    .decl_order,
    .whole_init_first,
    .returned_stack_reference,
    .catch_suppression,
    .prefer_assert_unreachable,
    .no_catch_return,
    .unused_global,
    .useless_error_return,
    .duplicate_case,
    .redundant_import,
    .canonical_alias,
    .import_at_root,
    .state_uninit,
    .no_qualified_zm,
    .no_qualified_std,
    .custom_degrad,
    .no_std_timer,
    .debug_print,
    .float_from_int,
    .prefer_splat,
    .shader_safe,
    .scope_balance,
    .screaming_const,
    .shader_missing_entry,
    .unknown_lint_tag,
    .arch_check,
    .browser_call,
    .own_clock,
    .process_exit,
    // A decl literal where the declaration names the type - one LOGICAL line, however `zig fmt` splits it; `zig build
    // fix` converts every site.
    .prefer_decl_literal,
    // A bare constructor word (`.init(...)`) only where the declaration names the type.
    .constructor_in_view,
};

/// The `--enable=a,b,...` argument turning on `rules`.
pub fn lintEnableArg(b: *std.Build, rules: []const LintRule) []const u8 {
    var arg: ArrayList(u8) = .empty;
    arg.appendSlice(b.allocator, "--enable=") catch @panic("OOM");
    for (rules, 0..) |rule, i| {
        if (i > 0) {
            arg.append(b.allocator, ',') catch @panic("OOM");
        }
        for (@tagName(rule)) |c| {
            arg.append(b.allocator, if (c == '_') '-' else c) catch @panic("OOM");
        }
    }
    return arg.items;
}

/// `rules`, with `zig_fmt` added when it is not among them: what `zig build lint-fix` runs, so a fix always lays the
/// files out as `zig fmt` does - as the `zig fmt` run it replaced did - whether or not the checks hold the files to it.
fn withZigFmt(b: *std.Build, rules: []const LintRule) []const LintRule {
    for (rules) |rule| {
        if (rule == .zig_fmt) {
            return rules;
        }
    }
    const extended: []LintRule = b.allocator.alloc(LintRule, rules.len + 1) catch @panic("OOM");
    @memcpy(extended[0..rules.len], rules);
    extended[rules.len] = .zig_fmt;
    return extended;
}

pub const LintOptions = struct {
    /// The project's Zig sources.
    files: []const LazyPath,
    /// The rules to hold them to - every rule is opt-in, so an empty list checks nothing.
    enable: []const LintRule = &.{},
    /// Apply the mechanical autofixes in place (`--fix`) instead of only reporting.
    fix: bool = false,
    /// The command that applies the autofixes, printed beside every fixable finding and in the summary - a
    /// project's `zig build lint-fix`. Null: the linter's own advice (rerun with `--fix`).
    fix_command: ?[]const u8 = null,
};

/// zimr's linter over a project's own sources, for a project that depends on
/// zimr. Builds the linter from the dependency (one file, plus the std cli
/// parser zimr vendors - `src/command_line.zig` - which it reads its command
/// line through) and keeps its per-file stamps in the project's build cache,
/// never its source tree. Returns the Run; the caller decides what depends on it.
pub fn addLint(b: *std.Build, zimr_dep: *std.Build.Dependency, opts: LintOptions) *Run {
    const exe: *Compile = b.addExecutable(.{
        .name = "zimrlint",
        .root_module = b.createModule(.{
            .root_source_file = zimr_dep.path("tools/zimrlint.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    exe.root_module.addImport("cli", b.createModule(.{
        .root_source_file = zimr_dep.path("src/command_line.zig"),
    }));
    const run: *Run = b.addRunArtifact(exe);
    run.addArg(lintEnableArg(b, opts.enable));
    run.addArg("--cache-dir");
    run.addDirectoryArg(LazyPath.cache_root.path(b, "zimrlint"));
    if (opts.fix) {
        run.addArg("--fix");
    }
    if (opts.fix_command) |command| {
        run.addArgs(&.{ "--fix-command", command });
    }
    for (opts.files) |file| {
        run.addFileArg(file);
    }
    // `zig build lint -- --list-rules` prints the catalog; `-- --enable=<tag>`
    // tries a rule on the project before committing to it in build.zig.
    run.addPassthruArgs();
    return run;
}

const Tools = struct {
    spv2wgsl: *Compile,
    spv2wgsl_check: *Compile,
    lint: *Compile,
    c2js: *Compile,
    serve: *Compile,
    cheatsheet: *Compile,
    buildaux: *Compile,
    mesh_bake: *Compile,
    bvh_trim: *Compile,
    dag: *Compile,
    editor_configs: *Compile,
    gen_files_md: *Compile,
    docfmt: *Compile,
    files_html: *Compile,
    doc_gate: *Compile,
    example_source: *Compile,
    zbuild: *Compile,
    android_apk: *Compile,
};

/// Gives a host tool's own codecs module its build options: no platform (`host = "none"`), so the platform it logs
/// through (`platform.current`, chosen by `host.zig`) is the headless one.
fn addToolHostOptions(b: *std.Build, codecs_mod: *Module) void {
    const options: *Options = b.addOptions();
    options.addOption([]const u8, "host", "none");
    codecs_mod.addOptions("build_options", options);
}

fn buildTools(
    b: *std.Build,
    host_target: ResolvedTarget,
    zimrmath_mod: *Module,
    cli_mod: *Module,
) Tools {
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
    spv2wgsl_tool_exe.root_module.addImport("cli", cli_mod);
    // The binding/structural WGSL validator - same spv2wgsl lib, run over the
    // corpus by `tripwires` as a build-time tripwire (duplicate @group@binding etc.).
    const spv2wgsl_check_exe: *Compile = b.addExecutable(.{
        .name = "spv2wgsl_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/spv2wgsl_check.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    spv2wgsl_check_exe.root_module.addImport("cli", cli_mod);
    spv2wgsl_check_exe.root_module.addImport("spv2wgsl", spv2wgsl_lib_mod);
    // The remaining tools, built DIRECTLY by the main build (pure Zig, like
    // spv2wgsl above) instead of the old `tools/build.zig` sub-build. That
    // sub-build was cwd-relative and wrote into a (read-only-as-a-dependency)
    // cache - incompatible with zimr being consumed as a package. Installed as
    // named artifacts so an external consumer can `dep.artifact("c2js")` etc.
    const zimrlint_exe: *Compile = b.addExecutable(.{
        .name = "zimrlint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zimrlint.zig"),
            .target = host_target,
            // ReleaseSafe, NOT ReleaseFast, for two reasons. The durable one: `std.process.Init`
            // hands `main` a leak-checking `SafeAllocator` only in Debug/ReleaseSafe, and that
            // checker is what found zimrlint leaking the replacement text of every suppressed
            // autofix (2163). The historical one: an earlier dev Zig miscompiled zimrlint under
            // ReleaseFast (SIGILL on every input) - not re-tested since, and no longer the reason.
            .optimize = .ReleaseSafe,
        }),
    });
    zimrlint_exe.root_module.addImport("cli", cli_mod);
    const c2js_exe: *Compile = b.addExecutable(.{
        .name = "c2js",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/c2js.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    c2js_exe.root_module.addImport("cli", cli_mod);
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
            .optimize = .Debug,
        }),
    });
    serve_exe.root_module.addImport("cli", cli_mod);
    const cheatsheet_exe: *Compile = b.addExecutable(.{
        .name = "cheatsheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cheatsheet.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    cheatsheet_exe.root_module.addImport("cli", cli_mod);
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
    buildaux_exe.root_module.addImport("cli", cli_mod);

    // mesh_bake: bake a DECIMATED glTF proxy (+ small base-color block) into
    // a generated `.zig` const - the comptime-corner geometry source for the
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
    addToolHostOptions(b, mesh_bake_codecs_mod);
    const mesh_bake_exe: *Compile = b.addExecutable(.{
        .name = "mesh_bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mesh_bake.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    mesh_bake_exe.root_module.addImport("cli", cli_mod);
    // Its own step too: the two bunny bakes reach it only through generated module files, an edge the build records
    // while it runs - so without a step it is invisible to `zig build tools`, and unusable by hand.
    const mesh_bake_run: *Run = b.addRunArtifact(mesh_bake_exe);
    mesh_bake_run.setCwd(b.path("."));
    mesh_bake_run.has_side_effects = true;
    mesh_bake_run.addPassthruArgs();
    b.step("mesh-bake", "Bake a decimated proxy of a .glb or .obj into a .zig const").dependOn(&mesh_bake_run.step);
    mesh_bake_exe.root_module.addImport("codecs", mesh_bake_codecs_mod);
    // zm too: mesh_bake seeds its bounding box from `floatMax`, and std.math is banned
    // everywhere - a host-only tool is no exception, because the point is that ONE math module
    // is the answer to "where does this live", not that portability happens to not bite here.
    mesh_bake_exe.root_module.addImport("zm", zimrmath_mod);

    // bvh_trim: cut a frame range out of a mocap capture, using zimr's OWN bvh codec, so the
    // clip `mocap_viewer` embeds is a reproducible product of the round trip the tests assert
    // rather than a blob someone trimmed by hand. Own codecs module instance, same reason as
    // mesh_bake above.
    const bvh_trim_codecs_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/codecs.zig"),
    });
    bvh_trim_codecs_mod.addImport("zm", zimrmath_mod);
    addToolHostOptions(b, bvh_trim_codecs_mod);
    const bvh_trim_exe: *Compile = b.addExecutable(.{
        .name = "bvh_trim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bvh_trim.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    bvh_trim_exe.root_module.addImport("cli", cli_mod);
    bvh_trim_exe.root_module.addImport("codecs", bvh_trim_codecs_mod);
    // lafan_db: LAFAN1 locomotion out of Holden's motion-matching database.bin and into BVH clips,
    // each one verified by reading it back (tools/lafan_db.zig). Run it with arguments:
    //     zig build lafan-db -- <database.bin> <out_dir> <seconds>
    const lafan_db_exe: *Compile = b.addExecutable(.{
        .name = "lafan_db",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lafan_db.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    lafan_db_exe.root_module.addImport("cli", cli_mod);
    lafan_db_exe.root_module.addImport("codecs", bvh_trim_codecs_mod);
    lafan_db_exe.root_module.addImport("zm", zimrmath_mod);
    // bvh_trim has been the way assets are cut since it was written; give it a step so the
    // command in an asset's README is the command you actually run.
    const bvh_trim_step: *Step = b.step("bvh-trim", "cut a frame range out of a BVH file");
    const bvh_trim_run: *Run = b.addRunArtifact(bvh_trim_exe);
    bvh_trim_run.setCwd(b.path("."));
    bvh_trim_run.has_side_effects = true;
    bvh_trim_run.addPassthruArgs();
    bvh_trim_step.dependOn(&bvh_trim_run.step);
    const lafan_db_step: *Step = b.step("lafan-db", "convert LAFAN1 locomotion from Holden's database.bin into BVH");
    const lafan_db_run: *Run = b.addRunArtifact(lafan_db_exe);
    lafan_db_run.setCwd(b.path("."));
    lafan_db_run.has_side_effects = true;
    lafan_db_run.addPassthruArgs();
    lafan_db_step.dependOn(&lafan_db_run.step);

    // Four hand-run tools nothing else builds. `zig run tools/<x>.zig` cannot give them the `cli` module (std's
    // command-line parser, vendored), so each is a step instead - `zig build <name> -- <args>`, from the repository
    // root, the arguments forwarded as they are. Debug: they run for a moment, and Debug keeps every safety check
    // while compiling in a second instead of ~25 (a tool's optimise mode follows its RUN time - see claude.md).
    const HandTool = struct { name: []const u8, step: []const u8, what: []const u8 };
    const hand_tools = [_]HandTool{
        .{ .name = "decl_deps", .step = "decl-deps", .what = "The file-scope dependency graph of a Zig file" },
        .{ .name = "rename_local", .step = "rename-local", .what = "Scoped rename of a function-local variable" },
        .{ .name = "rename_pub_fn", .step = "rename-pub-fn", .what = "Rename a top-level function in its file" },
        .{ .name = "zm_namedimports", .step = "zm-namedimports", .what = "Migrate zm.X bodies to named imports" },
    };
    // zbuild: `zig build`, and when it fails, the output ENDS with only the roots. INSTALLED like `measure`, not a
    // step - it runs `zig build` itself, which a step inside `zig build` should not:
    //     zig build zbuild        then        tools/zig-out/bin/zbuild <what zig build takes>
    const zbuild_exe: *Compile = b.addExecutable(.{
        .name = "zbuild",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zbuild.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    const zbuild_install: *Step.InstallArtifact = b.addInstallArtifact(zbuild_exe, .{
        .dest_dir = .{ .override = .{ .custom = "../tools/zig-out/bin" } },
    });
    const zbuild_step: *Step = b.step(
        "zbuild",
        "Install zbuild into tools/zig-out/bin: `zig build`, ending with only what failed",
    );
    zbuild_step.dependOn(&zbuild_install.step);
    // The two multiplayer servers the readme documents. Long-running: a step starts one and it serves until stopped.
    // Both take `--port`; without it, PORT - what render_server's hosting platform sets - then 7777.
    const ServerTool = struct { name: []const u8, step: []const u8, what: []const u8 };
    const servers = [_]ServerTool{
        .{
            .name = "signal_server",
            .step = "signal-server",
            .what = "Run the multiplayer signaling server",
        },
        .{
            .name = "render_server",
            .step = "render-server",
            .what = "Run the deployable server (demo pages + signaling)",
        },
    };
    // The WebSocket protocol both servers speak, shared with the engine's native client.
    const net_core_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/net_core.zig"),
        .target = host_target,
        .optimize = .Debug,
    });
    for (servers) |server| {
        const exe: *Compile = b.addExecutable(.{
            .name = server.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{server.name})),
                .target = host_target,
                .optimize = .Debug,
            }),
        });
        exe.root_module.addImport("cli", cli_mod);
        exe.root_module.addImport("net_core", net_core_mod);
        const run: *Run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.addPassthruArgs();
        b.step(server.step, server.what).dependOn(&run.step);
    }
    for (hand_tools) |tool| {
        const exe: *Compile = b.addExecutable(.{
            .name = tool.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{tool.name})),
                .target = host_target,
                .optimize = .Debug,
            }),
        });
        exe.root_module.addImport("cli", cli_mod);
        const run: *Run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.addPassthruArgs();
        const step: *Step = b.step(tool.step, tool.what);
        step.dependOn(&run.step);
    }

    // dag_check: the file-level import-graph DAG gate (replaces the old
    // scripts/check_dag.py).  Tokenizer-based @import scan, Tarjan SCC, no
    // whitelist; also prints the auto-computed DAG layering.  std-only.
    const dag_check_exe: *Compile = b.addExecutable(.{
        .name = "dag_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dag_check.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    dag_check_exe.root_module.addImport("cli", cli_mod);

    // gen_editor_configs: write (or, with --check, compare) the VS Code and Zed debug+task configs
    // for the apps named on its command line - every app with a web build.  std-only.
    const editor_configs_exe: *Compile = b.addExecutable(.{
        .name = "gen_editor_configs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_editor_configs.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    editor_configs_exe.root_module.addImport("cli", cli_mod);
    // gen_files_md: regenerate src/notes/files.md, the per-file atlas
    // (line/fn/test counts, deps, dependents, curated descriptions).
    // Replaces scripts/gen_files_md.py.  Pulls in tools/file_descriptions.zig
    // (the curated text) as a sibling file-import.  std-only.
    const gen_files_md_exe: *Compile = b.addExecutable(.{
        .name = "gen_files_md",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_files_md.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    gen_files_md_exe.root_module.addImport("cli", cli_mod);
    // doc_gate: fail the build if a published page grows its own <style>, a
    // <script>, a webfont fetch, or loses its docfmt marker.  Fed the same page
    // list build.zig installs.  std-only.
    const doc_gate_exe: *Compile = b.addExecutable(.{
        .name = "doc_gate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/doc_gate.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    doc_gate_exe.root_module.addImport("cli", cli_mod);
    // files_html: render src/notes/files.md as src/notes/files.html, the styled
    // per-file atlas.  Handles only the markdown the atlas uses; the mermaid
    // fence stays a <pre> because rendering it would mean shipping mermaid.js.
    const files_html_exe: *Compile = b.addExecutable(.{
        .name = "files_html",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/files_html.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    files_html_exe.root_module.addImport("cli", cli_mod);
    // docfmt: build-time formatter for every published doc page.  stdin ->
    // stdout filter; injects THE shared stylesheet at the `<!--docfmt:style-->`
    // marker and wraps <pre><code class="zig|language-zig|wgsl"> tokens in spans
    // via std.zig.Tokenizer (or its own small WGSL lexer), so a served page
    // needs no runtime JS and fetches no webfont.  std-only.
    const docfmt_exe: *Compile = b.addExecutable(.{
        .name = "docfmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docfmt.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    docfmt_exe.root_module.addImport("cli", cli_mod);
    // example_source: one example's source files, highlighted by docfmt's own
    // `highlightZig`, as the web/<name>/source.json the gallery's code pane shows
    // (see `installExampleSource`).  std-only; imports docfmt.zig beside it.
    const example_source_exe: *Compile = b.addExecutable(.{
        .name = "example_source",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/example_source.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    example_source_exe.root_module.addImport("cli", cli_mod);
    // android_apk: an app's single-file page packed into a signed Android app, and installed on a phone
    // (`-Dplatform=android`: `zig build <app>`, `run-<app>`). It only runs the Android SDK's and a JDK's tools.
    const android_apk_exe: *Compile = b.addExecutable(.{
        .name = "android_apk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/android_apk.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    android_apk_exe.root_module.addImport("cli", cli_mod);
    return .{
        .spv2wgsl = spv2wgsl_tool_exe,
        .spv2wgsl_check = spv2wgsl_check_exe,
        .lint = zimrlint_exe,
        .c2js = c2js_exe,
        .serve = serve_exe,
        .cheatsheet = cheatsheet_exe,
        .buildaux = buildaux_exe,
        .mesh_bake = mesh_bake_exe,
        .bvh_trim = bvh_trim_exe,
        .dag = dag_check_exe,
        .editor_configs = editor_configs_exe,
        .gen_files_md = gen_files_md_exe,
        .docfmt = docfmt_exe,
        .files_html = files_html_exe,
        .doc_gate = doc_gate_exe,
        .example_source = example_source_exe,
        .zbuild = zbuild_exe,
        .android_apk = android_apk_exe,
    };
}

/// Native/host examples: built for the host as ordinary executables that
/// render via the pure-Zig software renderer (raster) and write PNG files - no
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
    // Run on any host:  `zig build comptime-mandelbrot-ascii`  (the clean
    // name `comptime-mandelbrot` goes to the wgpu example, which draws it)
    const comptime_mandelbrot_step: *Step = b.step(
        "comptime-mandelbrot-ascii",
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
    // ---- the shader on both backends - the codegen-emitted
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
        // `zimr` umbrella - see comment in the example source for
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
        // modules still need wiring - onto sw_runtime itself.
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
    // ---- output.  Each cell is independent - trivially parallelizable.
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
    // ---- compute (no rasterizer) - the simpler architecture for
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
    // ---- (Julia set: z_0 is per-pixel, c is a fixed constant).
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

/// `zig build tools`: COMPILE every tool the build knows - every executable rooted in `tools/` - without running
/// any. A tool nothing compiles rots unseen: `physics_audit` stopped compiling
/// the day `World.addBody` went, and nobody knew. Found by walking the build graph from every top-level step rather
/// than listed by hand, so a new tool is gated the moment it is wired and none can be forgotten. What no step builds
/// (the kept-but-unsupported tools) is left alone - and so is a tool reached ONLY through a generated module file
/// (`addAnonymousImport` of a run's output): the build records that edge while it runs, after this walk. Such a
/// tool gets a step of its own (mesh_bake has one). Nor are the three robot tools in `src/` (st_bench, robot_bench,
/// clip_bake): optimised builds of the robot family's code, which `test-fast` compiles already - gated, every robot
/// change would recompile them for minutes. `gate` depends on it; `tripwires`, run every turn, does not.
fn gateEveryTool(b: *std.Build, gate_step: *Step) void {
    const tools_step: *Step = b.step("tools", "Compile every tool the build knows, run none - so none rots unseen");
    var visited: AutoHashMapUnmanaged(*Step, void) = .empty;
    var pending: ArrayList(*Step) = .empty;
    for (b.top_level_steps.values()) |top| {
        pending.append(b.allocator, &top.step) catch @panic("OOM");
    }
    while (pending.pop()) |step| {
        const gop: AutoHashMapUnmanaged(*Step, void).GetOrPutResult =
            visited.getOrPut(b.allocator, step) catch @panic("OOM");
        if (gop.found_existing) {
            continue;
        }
        pending.appendSlice(b.allocator, step.dependencies.items) catch @panic("OOM");
        const compile: *Compile = step.cast(Compile) orelse continue;
        if (compile.kind != .exe) {
            continue;
        }
        const source: LazyPath = compile.root_module.root_source_file orelse continue;
        const path: []const u8 = switch (source) {
            .src_path => |src| src.sub_path,
            else => continue,
        };
        const in_tools: bool = startsWith(u8, path, "tools/");
        if (in_tools) {
            tools_step.dependOn(&compile.step);
        }
    }
    gate_step.dependOn(tools_step);
}

/// A one-line tip, once per cache, when this build was NOT started through `zbuild` (which sets ZIMR_ZBUILD on the
/// `zig build` it runs). Once, because `build()` runs before any step and cannot know whether this is the build that
/// fails - a line on every build, successful ones included, would teach everyone to skip the build's output. The
/// stamp lives in the local cache, so clearing the cache brings the tip back, once. `exe_path` is where
/// `zig build zbuild` installs it in the build that is running: zimr's tools/zig-out/bin, or a project's zig-out/bin.
/// Only the root build tells it - a dependency's step and path are not the ones the person typing can use.
fn suggestZbuild(b: *std.Build, exe_path: []const u8) void {
    const through_zbuild: bool = b.graph.environ_map.get("ZIMR_ZBUILD") != null;
    const is_dependency: bool = b.pkg_hash.len != 0;
    if (through_zbuild or is_dependency) {
        return;
    }
    const io: Io = b.graph.io;
    const root: Io.Dir = b.root.root_dir.handle;
    const stamp: []const u8 = ".zig-cache/zimr-zbuild-tip";
    const already_shown: bool = blk: {
        root.access(io, stamp, .{}) catch break :blk false;
        break :blk true;
    };
    if (already_shown) {
        return;
    }
    std.debug.print("zimr: tip - `{s} <step> [args]` runs this same build and, when it fails, " ++
        "ends with only what failed (install it once: `zig build zbuild`). Shown once per cache.\n", .{exe_path});
    const file: Io.File = root.createFile(io, stamp, .{}) catch return;
    file.close(io);
}

/// True when `path`'s first directory segment equals `dir`, treating BOTH
/// `/` and `\` as separators. The dir Walker builds `entry.path` with the
/// platform separator (`\` on Windows), so a hard-coded `"dir/"` prefix
/// silently fails to match there - which let the c2js_cases lint corpus slip
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

/// Match an example name against a comma-separated focus list.
/// Empty list (`""`) matches everything - this is the default state
/// when no `-Dfocus` flag is passed.  Entries ending in `*` match as
/// prefixes; bare entries match exactly.  Mirrors the syntax that
/// `webtests/smoke.ts` uses for its `--focus` arg so a single
/// `-Dfocus=` invocation filters both the build artifacts AND the
/// smoke-test runs identically.
/// Examples:
///   matchesFocus("ui_log_viewer", "")                         -> true
///   matchesFocus("ui_log_viewer", "ui_log_viewer")            -> true
///   matchesFocus("ui_log_viewer", "ui_log_viewer,zimrphysics_*")  -> true
///   matchesFocus("zimrphysics_demo", "ui_log_viewer,zimrphysics_*")   -> true
///   matchesFocus("audio_basic", "ui_log_viewer,zimrphysics_*")    -> false
///   matchesFocus("mandelbrot", "tier-a")                      -> true
///   matchesFocus("audio_basic", "tier-a")                     -> false
///
/// `tier-a` is a magic name expanding to a 10-example set chosen for
/// broad, varied feature coverage (2D/UI, 3D mesh+camera, GPU compute,
/// 2D shape primitives, ImGui widgets, CPU/GPU shader duality, docking,
/// ECS, the plot lib + heavy immediate-mode UI, and glTF model + PBR).
/// One example per cross-cutting surface so a broad breakage surfaces
/// fast without build-checking all ~135 examples.  Can be combined with
/// other entries: `-Dfocus=tier-a,ui_tables_*` typechecks the tier plus
/// the prefix.
fn matchesFocus(example_name: []const u8, focus_list: []const u8) bool {
    if (focus_list.len == 0) {
        return true;
    }
    var it = splitScalar(u8, focus_list, ',');
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
                // also writes in frame 0 - neither shows in a single-app smoke)
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

/// Hand `src/bridge.zig` to a `zig build-obj` Run step, and declare the files it imports as
/// inputs of that step. A Run step's cache hashes only the files it is TOLD about - it never
/// sees what the compiler it launches goes on to import - so without these an edit to
/// `dom_input.zig` would leave every page on the old zimr.js. bridge.zig imports
/// `dom_input.zig` (its host-tested input numbering), which reads two enums from `types.zig`.
fn addBridgeSource(b: *std.Build, to_c: *Run) void {
    to_c.addFileArg(b.path("src/bridge.zig"));
    to_c.addFileInput(b.path("src/dom_input.zig"));
    to_c.addFileInput(b.path("src/page_audio.zig"));
    to_c.addFileInput(b.path("src/types.zig"));
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
    addBridgeSource(b, to_c);
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

// addWgpuStandalone - register a `zig build <step_name>` that assembles a
// single self-contained HTML for a wgpu demo via the buildaux CLI (the old
// custom-step `WgpuStandalone` is gone with the 0.17 configurer/maker split).
// Derives the bundled-JS path and output HTML path from out_dir/out_basename,
// depends on the wasm (the Compile's emitted binary) and the JS-bundle step,
// and returns the registered step.  See src/notes/zig17_migration.md B7.

/// Files in an example's folder that the gallery's code pane leaves out. Each
/// `native_verify.zig` is its example's native build-time check (a host exe with
/// a `main`), not code that runs in the browser.
const example_source_hidden = [_][]const u8{"native_verify.zig"};

fn fileNameLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// The names of the .zig files directly in the project-relative `folder`, sorted.
/// A configure-time look at the file system, so it poisons the configure cache
/// (see `collectShaderFiles`). A missing folder simply has no files.
fn zigFilesIn(b: *std.Build, folder: []const u8) []const []const u8 {
    b.graph.poisonCache();
    const io: Io = b.graph.io;
    var names: ArrayList([]const u8) = .empty;
    var dir: Io.Dir = b.root.root_dir.handle.openDir(io, folder, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it: Io.Dir.Iterator = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const is_zig_file: bool = entry.kind == .file and endsWith(u8, entry.name, ".zig");
        if (is_zig_file) {
            // `entry.name` lives in the iterator's buffer, only until the next `next()`.
            names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
        }
    }
    sortSlice([]const u8, names.items, {}, fileNameLessThan);
    return names.items;
}

/// One source file for `example_source`: the path its tab shows, then the file.
fn addExampleSourceFile(b: *std.Build, run: *Run, project_path: []const u8) void {
    run.addArg(project_path);
    run.addFileArg(b.path(project_path));
}

/// True when `sub_path` exists under `b`'s build root. A configure-time look at the
/// file system, so it poisons the configure cache (see `collectShaderFiles`).
fn projectHas(b: *std.Build, sub_path: []const u8) bool {
    b.graph.poisonCache();
    b.root.root_dir.handle.access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}

/// An example's source for the gallery's code pane: `example_source` highlights
/// the files and this installs them as web/<name>/source.json beside the example's
/// page (the graph walk that builds `all-examples` picks it up, like every other
/// file under web/<name>/). The files, in tab order:
///
///   1. examples/<name>/<name>.zig, the example itself;
///   2. every other .zig in examples/<name>/, by name, minus `example_source_hidden`;
///   3. for each of `shaders` (the `App.shaders` basenames), examples/<s>.zig and,
///      when it exists, examples/<s>_io.zig - where `addShaderDepFrom` finds them;
///   4. for each of `app_deps` (`App.app_deps`), examples/<d>/<d>.zig, the other
///      example's file this one imports as the module `<d>`;
///   5. for each of `kernel_deps` (`App.kernel_deps`), examples/<d>/kernels.zig,
///      which this one's kernels.zig imports as `k_<d>`.
///
/// Measured over all 304 gallery examples, that is exactly what each one imports
/// from examples/, except gltf_textured's quad_glb_data.zig, a generated 1 KB byte
/// array better left out, and goban's problems/index.zig, generated too. Every
/// file is an `addFileArg`, so an edit reruns only the examples that show that file.
fn installExampleSource(
    b: *std.Build,
    example_source_exe: *Compile,
    name: []const u8,
    shaders: []const []const u8,
    app_deps: []const []const u8,
    kernel_deps: []const []const u8,
) *InstallFile {
    const run: *Run = b.addRunArtifact(example_source_exe);
    run.addArg(name);
    const source_json: LazyPath = run.addOutputFileArg("source.json");

    const folder: []const u8 = b.fmt("examples/{s}", .{name});
    const main_file: []const u8 = b.fmt("{s}.zig", .{name});
    addExampleSourceFile(b, run, b.fmt("{s}/{s}", .{ folder, main_file }));
    for (zigFilesIn(b, folder)) |file_name| {
        const is_main: bool = eql(u8, file_name, main_file);
        const is_hidden: bool = for (example_source_hidden) |hidden| {
            if (eql(u8, hidden, file_name)) {
                break true;
            }
        } else false;
        if (!is_main and !is_hidden) {
            addExampleSourceFile(b, run, b.fmt("{s}/{s}", .{ folder, file_name }));
        }
    }
    for (shaders) |shader| {
        addExampleSourceFile(b, run, b.fmt("examples/{s}.zig", .{shader}));
        const io_path: []const u8 = b.fmt("examples/{s}_io.zig", .{shader});
        if (projectHas(b, io_path)) {
            addExampleSourceFile(b, run, io_path);
        }
    }
    for (app_deps) |dep| {
        addExampleSourceFile(b, run, b.fmt("examples/{s}/{s}.zig", .{ dep, dep }));
    }
    for (kernel_deps) |dep| {
        addExampleSourceFile(b, run, b.fmt("examples/{s}/kernels.zig", .{dep}));
    }
    const web_dir: std.Build.InstallDir = .{ .custom = b.fmt("web/{s}", .{name}) };
    return b.addInstallFileWithDir(source_json, web_dir, "source.json");
}

/// An app's wasm reactor exe. Own-frame apps ARE the exe (their own main owns the GPU
/// frame); ticked apps are wrapped by the generic runner, which imports them as `user_app`
/// and drives beginDrawing/clearBackground/endDrawing. `zimr_b` resolves the runner's
/// source; the exe belongs to `b` (zimr's builder for its examples, the project's for a
/// `Project` app).
fn appExe(
    b: *std.Build,
    zimr_b: *std.Build,
    name: []const u8,
    user_mod: *Module,
    own_frame: bool,
    wasm_target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zimr_mod: *Module,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
) *Compile {
    const exe: *Compile = if (own_frame)
        b.addExecutable(.{ .name = name, .root_module = user_mod })
    else blk: {
        const mod: *Module = zimr_b.createModule(.{
            .root_source_file = zimr_b.path("src/wgpu_runner.zig"),
            .target = wasm_target,
            .optimize = optimize,
        });
        mod.addImport("zimr", zimr_mod);
        mod.addImport("zm", zimrmath_mod);
        mod.addImport("shader_interface", shader_interface_mod);
        mod.addImport("user_app", user_mod);
        break :blk b.addExecutable(.{ .name = name, .root_module = mod });
    };
    exe.wasi_exec_model = .reactor;
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

/// Compile an example's `kernels.zig` into the separate, freestanding, ZERO-IMPORT wasm
/// that the Web Workers instantiate.
///
/// Three things worth knowing:
///
///   * THE ROOT IS GENERATED. The example author never writes it - exactly as the
///     gen_externs bootstrap is generated. All it does is ask the registry to emit its
///     exports, which keeps `exportWorkerEntry` (and the worker's buffers) OUT of the
///     app's wasm, where they would be dead weight.
///
///   * IT IS A DIFFERENT TARGET. The app is wasm32-wasi; a worker's kernel is
///     wasm32-freestanding, so it needs its OWN module instances - a Module carries its
///     target, and these cannot be shared with the app's.
///
///   * IT MUST IMPORT NOTHING. `kernels.zig` imports `zimr` like any example, but Zig's
///     lazy analysis only compiles what the kernel actually REACHES - so a pure kernel
///     drags in no DOM, no WebGPU, no WASI, and the import section comes out empty. That
///     is what lets a worker instantiate it with `{}`. c2js ASSERTS the section is empty
///     when it inlines the wasm, so a kernel that reaches for `zimr.drawText` is a build
///     error naming the offending import - not a worker that dies in a thread nobody is
///     watching.
/// THE WEB WORKER'S PROGRAM - Zig, compiled to JavaScript.
///
///     src/jobs_worker.zig --(build-obj -ofmt=c)--> .c --(c2js)--> .js
///
/// The browser will only start a worker from a JavaScript program, so this file cannot be
/// eliminated - but it does not have to be WRITTEN. It used to be ~40 lines of hand-written JS
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

/// THE AUDIO WORKLET'S PROGRAM - Zig, compiled to JavaScript as the web worker's is.
///
///     src/audio_worklet.zig --(build-obj -ofmt=c, with zm)--> .c --(c2js)--> .js
///
/// It imports `sound.zig` for the names and sizes both sides of the worklet agree on (`worklet_abi`), and with it the
/// `zm` module, which `Voice` uses - so the compile is given `zm`, and `sound.zig` is declared an input, so that a
/// change to it rebuilds the program.
fn buildAudioWorkletJs(b: *std.Build, c2js_exe: *Compile) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
        "--dep",               "zm",
    });
    to_c.addPrefixedFileArg("-Mroot=", b.path("src/audio_worklet.zig"));
    to_c.addPrefixedFileArg("-Mzm=", b.path("src/zimrmath.zig"));
    to_c.addFileInput(b.path("src/sound.zig"));
    const audio_worklet_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "audio_worklet.c");

    const to_js: *Run = b.addRunArtifact(c2js_exe);
    to_js.setStdIn(.{ .lazy_path = audio_worklet_c });
    return to_js.captureStdOut(.{});
}

/// The page's sound output (`src/page_audio.zig`) transpiled on its own, as the root of its own program: it then
/// publishes its entry points (`page_audio_*`), which the page test drives in Node (`audio_page_test.cjs`). In a page,
/// the bridge imports the same file and calls it directly.
fn buildPageAudioJs(b: *std.Build, c2js_exe: *Compile) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    to_c.addPrefixedFileArg("-Mroot=", b.path("src/page_audio.zig"));
    const page_audio_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "page_audio.c");

    const to_js: *Run = b.addRunArtifact(c2js_exe);
    to_js.setStdIn(.{ .lazy_path = page_audio_c });
    return to_js.captureStdOut(.{});
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
    /// the page as `window.ZIMR_KERNEL_WASM` - c2js refuses to inline it if its import
    /// section is non-empty, which is how kernel purity is enforced.
    kernel_wasm: ?LazyPath,
    /// `App.fullscreen_button`.
    fullscreen_button: bool,
) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    addBridgeSource(b, to_c);
    const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
    const to_html: *Run = b.addRunArtifact(c2js_exe);
    // Full-canvas interactive demo on every page: the fullscreen-toggle button, unless the app leaves it out,
    // no orientation lock (portrait works exactly like landscape).
    to_html.addArgs(&.{ "--html", "--title", title, "--fullscreen-landscape" });
    if (!fullscreen_button) {
        to_html.addArg("--no-fullscreen-button");
    }
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
    // The kernel wasm rides along on BOTH paths - inlined even on the streamed page,
    // because at ~20 KB it is not worth a second request.
    if (kernel_wasm) |kw| {
        to_html.addArg("--kernel-wasm-embed");
        to_html.addFileArg(kw);
    }

    // The worker's program, on EVERY page. `jobs.parallel()` is a runtime question - an app
    // with no kernels never spawns a worker and never reads this - but a page that CAN spawn
    // one must already be carrying the program, because `new Worker(url)` cannot go and fetch
    // it later from a blob: origin.
    to_html.addArg("--worker-js-embed");
    to_html.addFileArg(buildWorkerJs(b, c2js_exe));

    // The audio worklet's program, on every page, for the same reason: the worklet's module is made from it.
    to_html.addArg("--audio-worklet-js-embed");
    to_html.addFileArg(buildAudioWorkletJs(b, c2js_exe));

    to_html.setStdIn(.{ .lazy_path = bridge_c });
    return to_html.captureStdOut(.{});
}

fn addWgpuStandalone(
    b: *std.Build,
    c2js_exe: *Compile,
    exe: *std.Build.Step.Compile,
    out_basename: []const u8,
    title: []const u8,
    kernel_wasm: ?LazyPath,
    fullscreen_button: bool,
) *std.Build.Step {
    // ZIG_BRIDGE Phase 4a: the standalone IS the bridge page now - the
    // wasm embedded into a single-file HTML whose entire runtime was born
    // as Zig (src/bridge.zig -> C -> c2js). The TS bundle path (buildaux
    // wgpu-standalone + bun-bundled bridge JS) is superseded; its
    // params stay until the deletion sweep retires the bundle Runs.
    const page: LazyPath = bridgePage(b, c2js_exe, exe, title, false, kernel_wasm, fullscreen_button); // embed
    const out_path: []const u8 = b.fmt("standalone/{s}", .{out_basename});
    const inst: *InstallFile = b.addInstallFile(page, out_path);
    return &inst.step;
}

/// Where a build's apps run (`-Dplatform`): in a browser - the wasm, as a served page and as a single
/// self-contained HTML file, both from one compile - natively, as a program with a window, or on an Android phone, as
/// the single-file page in an app of its own (`addAndroidBuild`). Every app has one step, `zig build <app>`, which
/// builds it for the chosen platform, and `run-<app>`, which builds it and runs it there.
pub const Platform = enum { web, windows, android };

/// The platform of the machine running the build, when zimr has one for it: the default for `-Dplatform`. Null
/// elsewhere, where each app's step fails with a message naming the choices instead of guessing.
fn hostPlatform() ?Platform {
    return switch (builtin.os.tag) {
        .windows => .windows,
        else => null,
    };
}

/// A step that only gathers others - one platform's build of an app, say - and that `zig build -l` does not list.
/// Not a top-level step: Zig 0.17 lists every reachable step tagged top-level, in `b.top_level_steps` or not. With no
/// step type that does nothing, it is an empty write-files step - one cache hit, shared by every gathering step, since
/// an empty one always hashes the same.
fn gatheringStep(b: *std.Build, name: []const u8) *Step {
    const gathering: *Step.WriteFile = b.addWriteFiles();
    gathering.step.name = b.graph.dupeString(name);
    return &gathering.step;
}

/// A run of the native check on a native program's linked binary: it fails when the program embeds WGSL, which the
/// native host cannot run.
/// The import check on one web page's wasm (`tools/bridge_import_check.zig`): every function it imports must be one
/// `bridge_source` registers.
fn addBridgeImportCheck(
    b: *std.Build,
    check_exe: *Compile,
    bridge_source: LazyPath,
    page_wasm: *Compile,
) *Step.Run {
    const check: *Step.Run = b.addRunArtifact(check_exe);
    check.addPrefixedFileArg("--bridge=", bridge_source);
    check.addFileArg(page_wasm.getEmittedBin());
    return check;
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
    /// `App.fullscreen_button`.
    fullscreen_button: bool,
    /// The example's web/<name>/source.json install (`installExampleSource`), so
    /// building the example alone also refreshes what the gallery's code pane shows.
    source_install: *Step,
    /// Where the app's web build is recorded, under its name: the app's own step depends on it when the build is
    /// for the web (`-Dplatform=web`), and `serve`, `dist` and `test-all-examples` always do.
    web_builds: *StringHashMap(*Step),
    /// The import check every page's wasm passes before its web build counts (`addBridgeImportCheck`).
    bridge_import_check_exe: *Compile,
) *Compile {
    const under: []const u8 = name;
    // Served pages live UNDER the serve root, in the underscored directory
    // (zig-out/web/hello_world/), so the gallery (zig-out/web/index.html) links to
    // "<name>/" and the dev server serves them. The app's one build step is the
    // dashed spelling (`zig build hello-world`), registered with every app's step for `-Dplatform`.
    const install_dir: std.Build.InstallDir = .{ .custom = b.fmt("web/{s}", .{name}) };

    const exe: *Compile = appExe(
        b,
        b,
        under,
        user_mod,
        own_frame,
        wasm_target,
        optimize,
        zimr_mod,
        zimrmath_mod,
        shader_interface_mod,
    );
    const install_art: *InstallArtifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = install_dir },
    });
    // Own-frame demos run their own loop, not the smoke harness's tick contract.
    if (!own_frame) {
        addWgpuSmoke(b, c2js_exe, wgpu_smoke_install, smoke_focus, exe, under);
    }
    // The example's SERVED page is the bridge page: a small index.html that loads the
    // shared runtime from ../zimr.js and streams <name>.wasm from its own directory.
    // Installed as web/<name>/index.html (the underscored name), the URL the gallery
    // links to and the editor debug configs open (http://localhost:8080/<name>/).
    const page: LazyPath = bridgePage(b, c2js_exe, exe, title, true, kernel_wasm, fullscreen_button); // streaming
    const index_install: *InstallFile = b.addInstallFileWithDir(
        page,
        install_dir,
        "index.html",
    );
    // The app's web build: the served page and the single-file page, both from the one wasm.
    const web_build: *Step = gatheringStep(b, b.fmt("{s} for the web", .{name}));
    web_build.dependOn(&install_art.step);
    web_build.dependOn(&index_install.step);
    web_build.dependOn(source_install);
    const standalone_basename: []const u8 = b.fmt("{s}.html", .{under});
    web_build.dependOn(addWgpuStandalone(b, c2js_exe, exe, standalone_basename, title, kernel_wasm, fullscreen_button));
    web_build.dependOn(&addBridgeImportCheck(b, bridge_import_check_exe, b.path("src/bridge.zig"), exe).step);
    web_builds.put(name, web_build) catch @panic("oom");
    _ = buildaux_exe;
    return exe;
}

/// The shared browser runtime, `zimr.js`: src/bridge.zig transpiled to JavaScript, bare (no
/// `--html`). Every served page loads it as `../zimr.js` (see `bridgePage`). `b` must be
/// zimr's own builder: the bridge source is resolved against it.
fn runtimeJs(b: *std.Build, c2js_exe: *Compile) LazyPath {
    const to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    addBridgeSource(b, to_c);
    const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
    const to_js: *Run = b.addRunArtifact(c2js_exe);
    to_js.setStdIn(.{ .lazy_path = bridge_c });
    return to_js.captureStdOut(.{});
}

fn buildJobKernels(
    b: *std.Build,
    name: []const u8,
    /// The app's `kernels.zig` (zimr's examples keep theirs at `examples/<name>/kernels.zig`).
    kernels_src: LazyPath,
    /// Other examples whose `kernels.zig` this one imports, as `k_<dep>`.
    ///
    /// The launcher needs this: a page carries ONE kernel wasm, but the launcher bundles many
    /// examples, so its `kernels.zig` merges their tables into a single registry. That works
    /// because the wasm exports are keyed by NAME rather than an index or a hash - a merged
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

    // A kompute MODULE can be a job kernel - `komputeRegistry(M)` derives the whole worker
    // backend from one - so the kernel wasm's graph has to carry `kompute` too.
    const kompute_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/kompute.zig"),
        .target = target,
        .optimize = optimize,
    });
    kompute_mod.addImport("zm", zm_mod);

    // One module per example's kernels.zig. They all share the SAME engine/kompute/zm module
    // instances - creating a second `kompute` module would put src/kompute.zig in two modules
    // at once, which Zig rejects ("file exists in modules 'kompute' and 'kompute0'").
    const makeKernelsMod = struct {
        fn f(
            bb: *std.Build,
            src: LazyPath,
            t: ResolvedTarget,
            o: std.builtin.OptimizeMode,
            em: *Module,
            km: *Module,
            zmm: *Module,
        ) *Module {
            const m: *Module = bb.createModule(.{
                .root_source_file = src,
                .target = t,
                .optimize = o,
            });
            m.addImport("zimr", em);
            m.addImport("kompute", km);
            m.addImport("zm", zmm);
            return m;
        }
    }.f;

    const kernels_mod: *Module = makeKernelsMod(b, kernels_src, target, optimize, engine_mod, kompute_mod, zm_mod);
    for (deps) |dep| {
        const dep_src: LazyPath = b.path(b.fmt("examples/{s}/kernels.zig", .{dep}));
        const dm: *Module = makeKernelsMod(b, dep_src, target, optimize, engine_mod, kompute_mod, zm_mod);
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
        \\const std = @import("std");
        \\const kernels = @import("kernels");
        \\
        \\comptime {
        \\    kernels.registry.exportWorkerEntry();
        \\}
        \\
        \\/// A kernel wasm imports nothing, so it has no console of its own: its log lines - among them the
        \\/// message of a zimr assert that fails - are kept in its memory, and the worker sends them home with
        \\/// the job's reply, for the page to print (`Registry.workerLogFn`).
        \\pub const std_options: std.Options = .{ .logFn = kernels.registry.workerLogFn };
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

/// One engine shader as an app embeds it: its import name (`<shader>.wgsl`, the same on every platform, so an app's
/// `@embedFile("pbr_vs.wgsl")` never changes) and the file under it - the shader's WGSL for the browser, its SPIR-V for
/// the native host.
pub const EngineShaderEmbed = struct {
    name: []const u8,
    path: LazyPath,
};

pub const ComputeKernel = struct {
    basename: []const u8,
    /// Multi-kernel modules (t1178): each named entry is translated to its
    /// own WGSL module (spv2wgsl --entry) imported as `<entry>_wgsl`.
    /// null = single-kernel module, imported as `<basename>_wgsl`.
    entries: ?[]const []const u8 = null,
    /// Set when the kernel calls zimrnum directly, so the GPU runs the HOST FUNCTION
    /// rather than a transcription of it. Opt-in per kernel because Zig rejects a
    /// `--dep` for a module the file does not import.
    wants_zimrnum: bool = false,
    /// Set when the kernel calls zimrrl, the reinforcement-learning library, directly. Opt-in
    /// per kernel for the same reason as `wants_zimrnum`.
    wants_zimrrl: bool = false,
    /// Where the kernel source lives, when it is NOT `<app dir>/<basename>.zig`: a path
    /// relative to the build root of whoever registers the app (zimr's for its
    /// examples, the project's for a `Project` app).
    ///
    /// ---- WHY THIS EXISTS ----
    ///
    /// zimrnum's GPU half is 2,185 lines across `zn_unary`, `zn_binary`, `zn_matmul` and
    /// `zn_train`, and every one imports `kompute` and `zm` and NOTHING else - no `zimr`, no
    /// example harness. That is library code by every test that matters, and it sits under
    /// `examples/` for one reason: this path was a format string with `examples/` baked in.
    ///
    /// The rule that kept it there - "zimrnum must stay shader-free" - is real and load-bearing,
    /// but it constrains a MODULE'S IMPORT CLOSURE, not a directory. `src/zimrnum.zig` importing
    /// only `std` and `zm` is what makes it a `test-fast` root; a SEPARATE module under `src/`
    /// that imports `kompute` does not touch that closure at all. The fear was of the wrong
    /// thing.
    ///
    /// This field is the whole mechanical difference. With it, moving a kernel into the engine is
    /// a file move plus one line here, rather than a build rewrite.
    source_path: ?[]const u8 = null,
};

/// An Android app's icon (`App.android_icon`, `-Dplatform=android`): a picture on a background, which each phone's
/// launcher cuts to the one shape it gives every icon - a circle, a rounded square. Paths are from the build root:
/// PNG, JPEG (.jpg) or WebP. An app without one shows Android's default icon.
pub const AndroidIcon = struct {
    /// Drawn in the middle of the icon, shrunk into the circle every launcher's shape keeps whole: round art, or art
    /// whose corners are empty, always shows complete.
    foreground: []const u8,
    /// Fills the icon behind it, edge to edge, before the launcher's cut.
    background: Background = .{ .color = "#FFFFFF" },

    pub const Background = union(enum) {
        /// `#RRGGBB`.
        color: []const u8,
        /// A picture, stretched to the square.
        picture: []const u8,
    };
};

/// A servable wgpu example: a user source module turned into a wasm reactor
/// exe + served page + standalone HTML. `shaders` (basenames like "julia_fs")
/// wires each compiled WGSL + its IO module into the example; an empty list
/// means a plain app. This is the unified form of the old addWgpuApp /
/// addWgpuShaderApp split - the shader loop is simply a no-op when empty.
///
/// The source is `examples/<name>/<name>.zig`. (A project that depends on zimr
/// registers its apps through `Project`, whose `App` mirrors this one.)
///
/// `configure` is the escape hatch for anything the common fields don't cover
/// (build-time asset baking, extra named embeds): a small named function that
/// runs after the standard wiring, before the exe is finished. It keeps the
/// struct from growing a field per special case - the variation lives in
/// composable functions (see `configureHelmetSw`), not in this type. null for
/// the common case.
pub const App = struct {
    name: []const u8,
    title: []const u8,
    shaders: []const []const u8 = &.{},
    /// When true, the example IS the exe root and owns its GPU frame (its own
    /// main loop calls beginFrame/endFrame) instead of being ticked by the
    /// shared `wgpu_runner`. Low-level 3D demos use this. They still get the
    /// same build glue (module, shaders, page, standalone, step) - only the exe
    /// root differs, on the web and natively (`nativeAppExe`), where the example's
    /// `main` calls `App.runNative` after `App.run`. Own-frame examples are not
    /// smoke-tested.
    own_frame: bool = false,
    /// Opt-in GPU compute. When non-empty, the example also imports `kompute`
    /// and each kernel is compiled (Zig -> SPIR-V -> WGSL) and wired in - the
    /// only thing that used to require a separate `addWgpuComputeApp`. Set this
    /// field to add compute to an example; nothing else moves.
    compute_kernels: []const ComputeKernel = &.{},
    /// Opt-in off-main-thread jobs (`zimr.jobs`). When true, `examples/<name>/kernels.zig`
    /// is ALSO compiled - separately, for wasm32-freestanding - into a small, ZERO-IMPORT
    /// wasm that the Web Workers instantiate, and that wasm is base64-inlined into the
    /// page beside the app's own.
    ///
    /// Two wasms, because a worker cannot run the app's: it has no DOM and no WebGPU, so
    /// 96 of the app's imports would be missing, and its 31 MB of linear memory would be
    /// paid PER WORKER. The kernel wasm imports nothing and starts at ~1 MB.
    ///
    /// Set this field to add jobs to an example; nothing else moves.
    job_kernels: bool = false,
    /// Other examples whose kernels.zig this one's imports, each as `k_<name>` - for an example whose jobs are another
    /// example's, as goban_outposts' are goban's.
    kernel_deps: []const []const u8 = &.{},
    /// Other examples this one imports, each as the module of its name rooted at `examples/<name>/<name>.zig` - as
    /// go_puzzles_hero imports goban. The gallery's code pane shows each one's file beside the example's own.
    app_deps: []const []const u8 = &.{},
    /// The page's fullscreen-toggle button, in its bottom-right corner. false for an example whose own interface
    /// sits there, or that has no use for it; the page stays full-canvas either way.
    fullscreen_button: bool = true,
    /// The Android app's ID (`-Dplatform=android`): who the app is to a phone and to the Play Store, so it never
    /// changes once the app is published. null: `org.zimr.<name>` (`defaultAndroidAppId`).
    android_app_id: ?[]const u8 = null,
    /// The name under the Android app's icon. null: the title.
    android_label: ?[]const u8 = null,
    /// The Android app's icon, from zimr's root. null: Android's default icon.
    android_icon: ?AndroidIcon = null,
    // lint:off decl-order: AppContext.buildAppModule takes the App this hook belongs to - a cycle
    configure: ?*const fn (AppContext, *Module) void = null,
};

/// What an app's Android build packs (`addAndroidBuild`): its page - the single file, without the fullscreen button,
/// since the app is already full screen and a WebView has no page fullscreen - its ID, the name under its icon, and
/// the icon, its paths from the root of the build that adds the app.
const AndroidPage = struct {
    page: LazyPath,
    app_id: []const u8,
    label: []const u8,
    icon: ?AndroidIcon,
};

/// An app's Android build (`addAndroidBuild`): its APK's install into zig-out/android/ - what `zig build <app>` builds
/// under `-Dplatform=android` - and the run that puts the APK on the phone adb sees and starts it, which `run-<app>`
/// runs once `<app>` has built it.
const AndroidBuild = struct {
    install: *Step,
    phone_run: *Run,
};

/// An app's Android ID when its row gives none (`App.android_app_id`): `org.zimr.` and its name. A name is already a
/// valid ID part - lowercase letters, digits, underscores - unless it starts with a digit (`3d_probe`), which an ID
/// part cannot.
fn defaultAndroidAppId(b: *std.Build, name: []const u8) []const u8 {
    const starts_with_digit: bool = name.len > 0 and std.ascii.isDigit(name[0]);
    const part_prefix: []const u8 = if (starts_with_digit) "app_" else "";
    return b.fmt("org.zimr.{s}{s}", .{ part_prefix, name });
}

/// `android_page` in an Android app, zig-out/android/<file_name>.apk: one full-screen WebView
/// (src/android/WebViewActivity.java), packed and signed by tools/android_apk.zig with the Android SDK and a JDK - the
/// only part of the build that needs either, and only under `-Dplatform=android`. `zimr_b` resolves the activity's
/// source; the APK, and the icon's paths, belong to `b` (zimr's builder for its examples, the project's for a `Project`
/// app).
fn addAndroidBuild(
    b: *std.Build,
    zimr_b: *std.Build,
    android_apk_exe: *Compile,
    file_name: []const u8,
    android_page: AndroidPage,
) AndroidBuild {
    const package_run: *Run = b.addRunArtifact(android_apk_exe);
    package_run.addArg("package");
    package_run.addPrefixedFileArg("--html=", android_page.page);
    package_run.addPrefixedFileArg("--java=", zimr_b.path("src/android/WebViewActivity.java"));
    package_run.addArg(b.fmt("--app-id={s}", .{android_page.app_id}));
    package_run.addArg(b.fmt("--label={s}", .{android_page.label}));
    if (android_page.icon) |icon| {
        package_run.addPrefixedFileArg("--icon-foreground=", b.path(icon.foreground));
        switch (icon.background) {
            .color => |color| package_run.addArg(b.fmt("--icon-background-color={s}", .{color})),
            .picture => |picture| package_run.addPrefixedFileArg("--icon-background=", b.path(picture)),
        }
    }
    // Scratch space for the tool: nothing in the build reads what it leaves there.
    _ = package_run.addPrefixedOutputDirectoryArg("--work=", "work");
    const apk: LazyPath = package_run.addPrefixedOutputFileArg("--out=", b.fmt("{s}.apk", .{file_name}));
    const apk_install: *InstallFile = b.addInstallFile(apk, b.fmt("android/{s}.apk", .{file_name}));

    const phone_run: *Run = b.addRunArtifact(android_apk_exe);
    phone_run.addArg("install");
    phone_run.addPrefixedFileArg("--apk=", apk);
    phone_run.addArg(b.fmt("--app-id={s}", .{android_page.app_id}));
    phone_run.has_side_effects = true;
    return .{ .install = &apk_install.step, .phone_run = phone_run };
}

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

const shader_codegen = @import("src/shader_codegen.zig");

const ShaderPipeline = shader_codegen.ShaderPipeline;

const WgslCorpus = shader_codegen.WgslCorpus;

/// What a run of the corpus tool (`tools/wgsl_corpus.zig`) does with tests/fixtures/wgsl_corpus.txt.
const WgslCorpusMode = enum { check, refresh };

/// The corpus tool over every graphics shader in `corpus`: holding them to tests/fixtures/wgsl_corpus.txt, or
/// rewriting the fixture from them.
fn addWgslCorpusRun(
    b: *std.Build,
    exe: *Compile,
    corpus: *const WgslCorpus,
    mode: WgslCorpusMode,
) *Run {
    const run: *Run = b.addRunArtifact(exe);
    // The fixture and spv2wgsl's source are read from the tree, and a refresh writes the fixture back: paths
    // relative to the build root that the build does not track as inputs, so the run always runs.
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    if (mode == .refresh) {
        run.addArg("--refresh");
    }
    run.addDirectoryArg(corpus.files.getDirectory());
    run.addArg("tests/fixtures/wgsl_corpus.txt");
    // spv2wgsl's source, which says which spv2wgsl wrote the pinned outputs.
    run.addArgs(&.{ "src/spv2wgsl.zig", "tools/spv2wgsl.zig" });
    return run;
}

/// The numerics modules - kompute, zimrnum and zimrrl - for one target. A module carries its target, and a compilation
/// may analyse only one module rooted at a given file, so every native target needs its own three: the web's
/// `kompute_mod` declares the web's target, and a native compilation that analysed it beside its own `kompute` is
/// refused. A null target lets each module take the target of the compilation it is part of.
const NumericsModules = struct {
    kompute: *Module,
    zimrnum: *Module,
    zimrrl: *Module,
};

fn addNumericsModules(
    b: *std.Build,
    target: ?ResolvedTarget,
    optimize: ?std.builtin.OptimizeMode,
    zimrmath_mod: *Module,
) NumericsModules {
    const kompute_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/kompute.zig"),
        .target = target,
        .optimize = optimize,
    });
    kompute_mod.addImport("zm", zimrmath_mod);
    const zimrnum_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimrnum.zig"),
        .target = target,
        .optimize = optimize,
    });
    zimrnum_mod.addImport("zm", zimrmath_mod);
    zimrnum_mod.addImport("kompute", kompute_mod);
    const zimrrl_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimrrl.zig"),
        .target = target,
        .optimize = optimize,
    });
    zimrrl_mod.addImport("zm", zimrmath_mod);
    zimrrl_mod.addImport("zn", zimrnum_mod);
    return .{ .kompute = kompute_mod, .zimrnum = zimrnum_mod, .zimrrl = zimrrl_mod };
}

/// What the headless Vulkan host test takes from the rest of the build.
const VulkanHostTestInputs = struct {
    shader_pipeline: *ShaderPipeline,
    zimrmath_mod: *Module,
    shader_interface_mod: *Module,
    assert_log: bool,
    profile_enabled: bool,
};

/// One of the test's kernel files, built twice: as SPIR-V (one module holding every entry; `entry` only labels the
/// build's output) and as its CPU module, wired as `wireComputeKernels` wires an app's kernels.
const HostTestKernel = struct {
    import_name: []const u8,
    source: []const u8,
    entry: []const u8,
    wants_zimrnum: bool = false,
    wants_zimrrl: bool = false,
};

/// The kernels the test runs: `double_it` (the compute and engine checks), `sort_min` (its atomics are the sort
/// check's subject), and zimrnum's four kernel files (the zimrnum sweep).
const host_test_kernels = [_]HostTestKernel{
    .{ .import_name = "double_it", .source = "examples/compute_smoke/double_it.zig", .entry = "double" },
    .{
        .import_name = "constant_index",
        .source = "examples/compute_smoke/constant_index.zig",
        .entry = "writeConstantElements",
    },
    .{ .import_name = "zn_train", .source = "src/gpu/zn_train.zig", .entry = "fwd_hidden" },
    .{ .import_name = "zn_mlp", .source = "src/gpu/zn_mlp.zig", .entry = "dense_fwd" },
    .{ .import_name = "sort_min", .source = "examples/sort_smoke/sort_min.zig", .entry = "clearGrid" },
    .{
        .import_name = "zn_binary",
        .source = "src/gpu/zn_binary.zig",
        .entry = "squash_correction",
        .wants_zimrnum = true,
    },
    .{ .import_name = "zn_matmul", .source = "src/gpu/zn_matmul.zig", .entry = "matmul" },
    .{ .import_name = "zn_unary", .source = "src/gpu/zn_unary.zig", .entry = "nan_direct" },
    .{
        .import_name = "zrl_binary",
        .source = "src/gpu/zrl_binary.zig",
        .entry = "cartpole_step",
        .wants_zimrrl = true,
    },
};

/// The headless Vulkan host test (`tools/vk_host_test.zig`) built for `target`: the engine on the native host with the
/// target's own numerics modules, every kernel the test runs as its SPIR-V (`<name>_spv`) and as its CPU module, and
/// zimrnum's conformance table. Built for the build machine, it runs on that machine's Vulkan driver - a GPU, or
/// lavapipe; built for Windows, it runs on a Windows machine's GPU.
fn addVulkanHostTest(
    b: *std.Build,
    target: ResolvedTarget,
    inputs: VulkanHostTestInputs,
) *Compile {
    const native_options: *Options = b.addOptions();
    native_options.addOption(bool, "assert_log", inputs.assert_log);
    native_options.addOption(bool, "profile_enabled", inputs.profile_enabled);
    native_options.addOption(bool, "ui_backend_wgpu", true);
    native_options.addOption([]const u8, "host", "native");
    const numerics: NumericsModules = addNumericsModules(b, null, null, inputs.zimrmath_mod);
    // Linux opens the Vulkan loader with the C library's `dlopen`; Windows with `LoadLibraryW`, no C library needed.
    const links_libc: bool = target.result.os.tag != .windows;
    // The engine itself: the test drives the Vulkan host through `z.wgpu` and compute through `z.Compute` - one module
    // holding `wgpu.zig` and `compute_host.zig` both (a second module rooted at `wgpu.zig` would hold that file twice).
    const engine_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = links_libc,
    });
    engine_mod.addImport("shader_interface", inputs.shader_interface_mod);
    engine_mod.addImport("zm", inputs.zimrmath_mod);
    engine_mod.addImport("zn", numerics.zimrnum);
    engine_mod.addImport("zrl", numerics.zimrrl);
    engine_mod.addOptions("build_options", native_options);
    const test_mod: *Module = b.createModule(.{
        .root_source_file = b.path("tools/vk_host_test.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = links_libc,
    });
    test_mod.addImport("zimr", engine_mod);
    test_mod.addImport("zm", inputs.zimrmath_mod);
    const conformance_mod: *Module = b.createModule(.{ .root_source_file = b.path("src/gpu/zn_conformance.zig") });
    conformance_mod.addImport("zm", inputs.zimrmath_mod);
    conformance_mod.addImport("zn", numerics.zimrnum);
    conformance_mod.addImport("zrl", numerics.zimrrl);
    test_mod.addImport("zn_conformance", conformance_mod);
    for (host_test_kernels) |kernel| {
        const kernel_source: LazyPath = b.path(kernel.source);
        const kernel_output: ShaderPipeline.ComputeOutput = inputs.shader_pipeline.addComputeOutput(
            kernel_source,
            kernel.entry,
            kernel.wants_zimrnum,
            kernel.wants_zimrrl,
        );
        const spirv_import_name: []const u8 = b.fmt("{s}_spv", .{kernel.import_name});
        test_mod.addAnonymousImport(spirv_import_name, .{ .root_source_file = kernel_output.spv });
        const kernel_mod: *Module = b.createModule(.{ .root_source_file = kernel_source });
        kernel_mod.addImport("kompute", numerics.kompute);
        kernel_mod.addImport("zm", inputs.zimrmath_mod);
        if (kernel.wants_zimrnum) {
            kernel_mod.addImport("zn", numerics.zimrnum);
        }
        if (kernel.wants_zimrrl) {
            kernel_mod.addImport("zrl", numerics.zimrrl);
        }
        test_mod.addImport(kernel.import_name, kernel_mod);
    }
    return b.addExecutable(.{ .name = "vk_host_test", .root_module = test_mod });
}

/// The headless trainer (`tools/geno_trainer.zig`) built for `target`: the engine on the native host, `zn_mlp`'s
/// kernels as their SPIR-V and their CPU module, the baked dance, and the command-line reader. ReleaseFast: it runs
/// for hours. Built for the build machine it trains on that machine's Vulkan driver; built for Windows, on a Windows
/// machine's GPU.
fn addGenoTrainer(
    b: *std.Build,
    target: ResolvedTarget,
    inputs: VulkanHostTestInputs,
    cli_mod: *Module,
) *Compile {
    const native_options: *Options = b.addOptions();
    native_options.addOption(bool, "assert_log", inputs.assert_log);
    native_options.addOption(bool, "profile_enabled", inputs.profile_enabled);
    native_options.addOption(bool, "ui_backend_wgpu", true);
    native_options.addOption([]const u8, "host", "native");
    const numerics: NumericsModules = addNumericsModules(b, null, null, inputs.zimrmath_mod);
    const links_libc: bool = target.result.os.tag != .windows;
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const engine_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = links_libc,
    });
    engine_mod.addImport("shader_interface", inputs.shader_interface_mod);
    engine_mod.addImport("zm", inputs.zimrmath_mod);
    engine_mod.addImport("zn", numerics.zimrnum);
    engine_mod.addImport("zrl", numerics.zimrrl);
    engine_mod.addOptions("build_options", native_options);
    const trainer_mod: *Module = b.createModule(.{
        .root_source_file = b.path("tools/geno_trainer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = links_libc,
    });
    trainer_mod.addImport("zimr", engine_mod);
    trainer_mod.addImport("zm", inputs.zimrmath_mod);
    trainer_mod.addImport("cli", cli_mod);
    const dance_clip: LazyPath = b.path("examples/geno_ppo/dance.zclip");
    trainer_mod.addAnonymousImport("geno_dance_zclip", .{ .root_source_file = dance_clip });
    const kernel_source: LazyPath = b.path("src/gpu/zn_mlp.zig");
    const kernel_output: ShaderPipeline.ComputeOutput = inputs.shader_pipeline.addComputeOutput(
        kernel_source,
        "dense_fwd",
        false,
        false,
    );
    trainer_mod.addAnonymousImport("zn_mlp_spv", .{ .root_source_file = kernel_output.spv });
    const kernel_mod: *Module = b.createModule(.{ .root_source_file = kernel_source });
    kernel_mod.addImport("kompute", numerics.kompute);
    kernel_mod.addImport("zm", inputs.zimrmath_mod);
    trainer_mod.addImport("zn_mlp", kernel_mod);
    return b.addExecutable(.{ .name = "geno_trainer", .root_module = trainer_mod });
}

fn addNativeWgslCheck(b: *std.Build, check_exe: *Compile, program: *Compile) *Step.Run {
    const check: *Step.Run = b.addRunArtifact(check_exe);
    check.addFileArg(program.getEmittedBin());
    return check;
}

/// An example with no native build yet, and why.
const WindowsPending = struct {
    name: []const u8,
    reason: []const u8,
};

/// The examples with no native build yet - left out of `all-examples-windows`, and shown in the native gallery with
/// the reason. Each reason names what is missing; the platforms plan has the step that writes it.
const windows_pending = [_]WindowsPending{
    .{ .name = "net_rtc_smoke", .reason = "WebRTC exists only in the browser" },
};

/// The reason `name` has no native build yet, or null when it has one.
fn windowsPendingReason(name: []const u8) ?[]const u8 {
    for (windows_pending) |pending| {
        if (eql(u8, pending.name, name)) {
            return pending.reason;
        }
    }
    return null;
}

/// What `zig build <app>` builds for `platform`: the app's web build, its native program, its Android app, or - when
/// there is none - a step that fails naming the reason: no zimr platform for this machine, a native build still
/// pending, or an app that exists only natively (the gallery) or only on the web.
fn appBuildFor(
    b: *std.Build,
    platform: ?Platform,
    name: []const u8,
    web_builds: *const StringHashMap(*Step),
    windows_builds: *const StringHashMap(*Step.InstallArtifact),
    android_builds: *const StringHashMap(AndroidBuild),
) *Step {
    const chosen: Platform = platform orelse {
        const message: []const u8 = b.fmt("zimr has no platform for this machine yet: build {s} with " ++
            "-Dplatform=web, -Dplatform=windows or -Dplatform=android", .{name});
        return &b.addFail(message).step;
    };
    switch (chosen) {
        .web => if (web_builds.get(name)) |web_build| {
            return web_build;
        },
        .windows => if (windows_builds.get(name)) |install| {
            return &install.step;
        },
        .android => if (android_builds.get(name)) |android_build| {
            return android_build.install;
        },
    }
    const reason: []const u8 = switch (chosen) {
        .web, .android => "it runs only natively",
        .windows => windowsPendingReason(name) orelse "it runs only on the web",
    };
    return &b.addFail(b.fmt("{s} has no {s} build: {s}", .{ name, @tagName(chosen), reason })).step;
}

/// A run of the dev server (tools/serve.zig) over zig-out/web/, on `port` (null: the server's own default, 8080).
/// `page` is the page to show, such as "/hello_world/": the server opens it in a browser - or, when a server of the
/// same directory is already running there, that one reloads the tabs showing it (opening one if none does) and
/// this run ends at once. From the build root, so `zig build` started in a subdirectory serves the same files.
fn addServeRun(
    b: *std.Build,
    serve_exe: *Compile,
    port: ?[]const u8,
    page: ?[]const u8,
) *Run {
    const run: *Run = b.addRunArtifact(serve_exe);
    run.setCwd(b.path("."));
    run.addArgs(&.{ "--root", "zig-out/web" });
    if (port) |listen_port| {
        run.addArgs(&.{ "--port", listen_port });
    }
    if (page) |shown| {
        run.addArgs(&.{ "--open", shown });
    }
    return run;
}

/// What `zig build run-<app>` does for `platform`, once `app_step` - the app's `zig build <app>` - has built it: runs
/// the installed program (installed, so the native gallery finds the examples beside it), shows the app's page
/// through the dev server (`addServeRun`), or puts its Android app on the phone and starts it. An app with no build for
/// the platform has none to run either: `app_step` already fails saying why, and running is that failure.
fn appRunFor(
    b: *std.Build,
    platform: ?Platform,
    name: []const u8,
    app_step: *Step,
    serve_exe: *Compile,
    web_builds: *const StringHashMap(*Step),
    windows_builds: *const StringHashMap(*Step.InstallArtifact),
    android_builds: *const StringHashMap(AndroidBuild),
) *Step {
    const chosen: Platform = platform orelse return app_step;
    switch (chosen) {
        .windows => {
            const install: *Step.InstallArtifact = windows_builds.get(name) orelse return app_step;
            const program_run: *Run = b.addRunArtifact(install.artifact);
            program_run.step.dependOn(app_step);
            return &program_run.step;
        },
        .android => {
            const android_build: AndroidBuild = android_builds.get(name) orelse return app_step;
            android_build.phone_run.step.dependOn(app_step);
            return &android_build.phone_run.step;
        },
        .web => {
            if (!web_builds.contains(name)) {
                return app_step;
            }
            const page_run: *Run = addServeRun(b, serve_exe, null, b.fmt("/{s}/", .{name}));
            page_run.step.dependOn(app_step);
            // The page loads ../zimr.js, which the default install writes.
            page_run.step.dependOn(b.getInstallStep());
            return &page_run.step;
        },
    }
}

/// Installs a Windows program, and its PDB, into `b`'s zig-out/windows/. The PDB goes through `pdb_void_workaround`
/// when there is one - a Zig compiler bug's workaround, not part of the build's design: `tools/pdb_void_workaround.zig`
/// says what it fixes, and it goes when the bug does. It installs the PDB rewritten so LLDB sees the program's `void`
/// functions, in place of the linker's.
fn installWindowsProgram(
    b: *std.Build,
    exe: *Compile,
    pdb_void_workaround: ?*Compile,
) *InstallArtifact {
    const windows_dir: std.Build.InstallDir = .{ .custom = "windows" };
    const workaround_exe: ?*Compile = if (exe.producesPdbFile()) pdb_void_workaround else null;
    const install: *InstallArtifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = windows_dir },
        .pdb_dir = if (workaround_exe == null) .default else .disabled,
    });
    if (workaround_exe) |fix_exe| {
        const pdb_name: []const u8 = b.fmt("{s}.pdb", .{exe.name});
        const fix_run: *Run = b.addRunArtifact(fix_exe);
        fix_run.addFileArg(exe.getEmittedPdb());
        const fixed_pdb: LazyPath = fix_run.addOutputFileArg(pdb_name);
        install.step.dependOn(&b.addInstallFileWithDir(fixed_pdb, windows_dir, pdb_name).step);
    }
    return install;
}

/// Installs a Windows program into `install_builder`'s zig-out/windows/, once it has passed the context's native
/// check (no WGSL inside). zimr's examples install with zimr's builder, a project's apps with the project's.
fn installWindowsApp(
    install_builder: *std.Build,
    ctx: AppContext,
    exe: *Compile,
) *Step.InstallArtifact {
    const install: *Step.InstallArtifact = installWindowsProgram(install_builder, exe, ctx.pdb_void_workaround);
    if (ctx.native_wgsl_check) |check_exe| {
        install.step.dependOn(&addNativeWgslCheck(install_builder, check_exe, exe).step);
    }
    return install;
}

/// A native program for the context's target - Windows, or the build's own machine for a headless run - rooted as the
/// web's `appExe` roots the app's wasm: an own-frame app's module IS the program (its `main` drives its frames), any
/// other is the browser build's own runner with `app_mod` as its app. Not yet installed (`installWindowsApp`).
fn nativeAppExe(
    ctx: AppContext,
    app_mod: *Module,
    name: []const u8,
    own_frame: bool,
) *Compile {
    const b: *std.Build = ctx.b;
    if (own_frame) {
        return b.addExecutable(.{ .name = name, .root_module = app_mod });
    }
    const runner_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/wgpu_runner.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    runner_mod.addImport("zimr", ctx.zimr_mod);
    runner_mod.addImport("zm", ctx.zimrmath_mod);
    runner_mod.addImport("shader_interface", ctx.shader_interface_mod);
    runner_mod.addImport("user_app", app_mod);
    return b.addExecutable(.{ .name = name, .root_module = runner_mod });
}

/// `nativeAppExe`'s program compiled as an object and not linked (`platforms-check`): every line of the engine and the
/// app compiled for the context's target, without the system's libraries a link would need.
fn nativeAppObject(
    ctx: AppContext,
    app_mod: *Module,
    name: []const u8,
) *Compile {
    const b: *std.Build = ctx.b;
    const runner_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/wgpu_runner.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    runner_mod.addImport("zimr", ctx.zimr_mod);
    runner_mod.addImport("zm", ctx.zimrmath_mod);
    runner_mod.addImport("shader_interface", ctx.shader_interface_mod);
    runner_mod.addImport("user_app", app_mod);
    return b.addObject(.{ .name = name, .root_module = runner_mod });
}

/// The launcher's roster names each flagship in its own source, as an `@import("ex_<name>")`, and the build's list
/// wires those imports: the two must name the same flagships. A name the build lacks leaves an import unwired; a name
/// the launcher lacks wires a module nothing uses and makes the flagship sweep one step too long. Read at configure
/// time, so a list out of step stops the build with both names listed.
fn checkLauncherRoster(b: *std.Build, build_names: []const []const u8) void {
    const io: Io = b.graph.io;
    const root: Io.Dir = b.root.root_dir.handle;
    const launcher_path: []const u8 = "examples/launcher/launcher.zig";
    const source: []const u8 = root.readFileAlloc(io, launcher_path, b.allocator, .limited(1 << 20)) catch |err| {
        std.debug.panic("checkLauncherRoster: cannot read {s}: {s}", .{ launcher_path, @errorName(err) });
    };
    var roster_count: usize = 0;
    var cursor: usize = 0;
    const import_prefix: []const u8 = "@import(\"ex_";
    while (indexOfPos(u8, source, cursor, import_prefix)) |found| {
        const name_start: usize = found + import_prefix.len;
        const name_end: usize = indexOfScalarPos(u8, source, name_start, '"') orelse break;
        const roster_name: []const u8 = source[name_start..name_end];
        const is_in_build: bool = for (build_names) |build_name| {
            if (eql(u8, build_name, roster_name)) {
                break true;
            }
        } else false;
        if (!is_in_build) {
            std.debug.panic("the launcher runs `{s}`, which the build's flagship list does not name", .{roster_name});
        }
        roster_count += 1;
        cursor = name_end;
    }
    if (roster_count != build_names.len) {
        std.debug.panic("the build's flagship list names {d} flagships, the launcher's roster {d}", .{
            build_names.len,
            roster_count,
        });
    }
}

/// `addHeadlessRun` for an app module already built - the launcher's, with every flagship imported - named `name`.
/// Returns the program, for more runs of it.
fn addHeadlessRunOf(
    b: *std.Build,
    ctx: AppContext,
    app_mod: *Module,
    name: []const u8,
    own_frame: bool,
    script_path: ?[]const u8,
) *Compile {
    const exe: *Compile = nativeAppExe(ctx, app_mod, name, own_frame);
    const install: *Step.InstallArtifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "headless/bin" } },
    });
    const run: *Run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    // Run from the build root, so the paths below - relative, as install paths are known only once the build runs -
    // resolve from it.
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("ZIMR_CAPTURE_DIR", b.fmt("zig-out/headless/{s}", .{name}));
    if (script_path) |path| {
        run.setEnvironmentVariable("ZIMR_SCRIPT", path);
    }
    const dash_name: []const u8 = std.mem.replaceOwned(u8, b.allocator, name, "_", "-") catch @panic("oom");
    const step: *Step = b.step(
        b.fmt("{s}-headless", .{dash_name}),
        b.fmt("Run {s} headless (-Dscript)", .{name}),
    );
    step.dependOn(&install.step);
    step.dependOn(&run.step);
    return exe;
}

/// The step `<name>-headless` (dashes for underscores): `app` built for the build's own machine with the headless host,
/// installed as zig-out/headless/bin/<name>, and run - always, its output being the point - with `script_path`'s
/// script, or a second of frames without one; frames it captures without a path go to zig-out/headless/<name>/.
fn addHeadlessRun(
    b: *std.Build,
    ctx: AppContext,
    app: App,
    script_path: ?[]const u8,
) *Compile {
    return addHeadlessRunOf(b, ctx, ctx.buildAppModule(app), app.name, app.own_frame, script_path);
}

/// How wide a gallery screenshot is saved (`gallery-shots`), its height in proportion: a thumbnail the native
/// gallery shows beside the example's description.
const gallery_shot_width: u32 = 320;

/// How wide the web gallery's copy of a screenshot is saved (`gallery-shots`), its height in proportion: the list
/// beside the running example shows it in an 80 by 60 box, cropped to fill it, so a 16 by 9 frame is drawn about 107
/// pixels wide - 224 is sharp on a screen of two device pixels to the pixel, at a third of the 320's bytes.
const web_gallery_shot_width: u32 = 224;

/// The frames a gallery screenshot is taken after: two seconds, as the script's clock counts them.
const gallery_shot_frames: u32 = 120;

/// How an example's gallery screenshot is taken: the script lines run first - a person's input taking the example
/// past a first screen that is not what it is about, each line ending in a newline - then the frames drawn before
/// the picture. An example with no row in `gallery_shot_recipes` takes the defaults.
const GalleryShotRecipe = struct {
    name: []const u8,
    lead_in: []const u8 = "",
    frames: u32 = gallery_shot_frames,
};

/// The examples whose gallery screenshot is not `gallery_shot_frames` frames of their first screen.
const gallery_shot_recipes = [_]GalleryShotRecipe{
    // The training examples size their work by the frame time: another round a frame while frames come in under
    // budget, up to a cap. The script's clock gives every frame a sixtieth of a second however long it took, so the
    // rounds a frame climb to the cap and stay there: two seconds of track_train are about 5,700 rounds of humanoid
    // physics, a quarter of an hour in a Debug build. Twelve frames are 78 rounds.
    .{ .name = "track_train", .frames = 12 },
    .{ .name = "geno_train", .frames = 12 },
    .{ .name = "getup_train", .frames = 12 },
    .{ .name = "geno_ppo", .frames = 12 },
    // goban opens on its main menu: a click on Start Game - x 270 .. 633, y 695 .. 740 of the 900 x 900 window,
    // measured on the menu's own gallery thumbnail - starts a 13 x 13 game of plain Go, and the pointer then leaves
    // the board, so that no ghost stone follows it. The release gets a frame of its own: the button counts a release
    // only with the pointer still over it.
    .{
        .name = "goban",
        .lead_in =
        \\.{ .advance = 3 }
        \\.{ .move = .{ .x = 450, .y = 718 } }
        \\.{ .press = .left }
        \\.{ .advance = 1 }
        \\.{ .release = .left }
        \\.{ .advance = 1 }
        \\.{ .move = .{ .x = 20, .y = 20 } }
        \\
        ,
    },
};

/// How `name`'s gallery screenshot is taken: its row of `gallery_shot_recipes`, or the defaults.
fn galleryShotRecipe(name: []const u8) GalleryShotRecipe {
    for (gallery_shot_recipes) |recipe| {
        if (eql(u8, recipe.name, name)) {
            return recipe;
        }
    }
    return .{ .name = name };
}

/// The `gallery-shots` run of one example: its headless program run from the build root with a script on its
/// standard input - its recipe's lead-in and frames (`galleryShotRecipe`), a thumbnail saved as
/// zig-out/gallery_shots/<name>.png for the native gallery and a smaller one as zig-out/web/shots/<name>.png for the
/// web gallery's list (where `dist` finds it), the end - and the audio start screen skipped
/// (`ZIMR_SKIP_START_SCREEN`), so that the picture is the example's own.
fn addGalleryShot(b: *std.Build, exe: *Compile, name: []const u8) *Run {
    const run: *Run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("ZIMR_SKIP_START_SCREEN", "1");
    // The script on the standard input: `-` says so.
    run.setEnvironmentVariable("ZIMR_SCRIPT", "-");
    run.setEnvironmentVariable("ZIMR_CAPTURE_DIR", b.fmt("zig-out/headless/{s}", .{name}));
    const thumbnail_line: []const u8 = b.fmt(
        ".{{ .capture_thumbnail = .{{ .path = \"zig-out/gallery_shots/{s}.png\", .width = {d} }} }}\n",
        .{ name, gallery_shot_width },
    );
    const web_thumbnail_line: []const u8 = b.fmt(
        ".{{ .capture_thumbnail = .{{ .path = \"zig-out/web/shots/{s}.png\", .width = {d} }} }}\n",
        .{ name, web_gallery_shot_width },
    );
    const recipe: GalleryShotRecipe = galleryShotRecipe(name);
    const script: []const u8 = b.fmt(
        "{s}.{{ .advance = {d} }}\n{s}{s}.quit\n",
        .{ recipe.lead_in, recipe.frames, thumbnail_line, web_thumbnail_line },
    );
    run.setStdIn(.{ .bytes = script });
    return run;
}

/// A program for the native Windows host (`nativeAppExe`), installed as `zig-out/windows/<name>.exe` once it has passed
/// the context's native check (no WGSL inside).
fn addWindowsApp(
    ctx: AppContext,
    app_mod: *Module,
    name: []const u8,
    own_frame: bool,
) *Step.InstallArtifact {
    return installWindowsApp(ctx.b, ctx, nativeAppExe(ctx, app_mod, name, own_frame));
}

/// The row of `apps` named `name`; a name with no row is a mistake in this file.
fn appNamed(apps: []const App, name: []const u8) App {
    for (apps) |app| {
        if (eql(u8, app.name, name)) {
            return app;
        }
    }
    std.debug.panic("no app named {s}", .{name});
}

/// The shared build context threaded into every example, bundled once so a
/// registration is `ctx.addApp(.{ .name = ..., .title = ... })` rather than an
/// 11-argument call. (A later step promotes this and `addApp` into the public
/// `shader_codegen` surface so external programs build zimr apps the same way.)
/// A system `platforms-check` compiles the engine for, with no platform of its own yet (`platform/unwritten.zig`): its
/// name and its target.
const PlatformCheckTarget = struct {
    name: []const u8,
    triple: []const u8,
};

/// The systems `platforms-check` compiles the launcher for beyond the web and Windows: Linux, macOS and Android.
const platform_check_targets = [_]PlatformCheckTarget{
    .{ .name = "linux", .triple = "x86_64-linux-gnu" },
    .{ .name = "macos", .triple = "aarch64-macos" },
    .{ .name = "android", .triple = "aarch64-linux-android" },
};

/// The engine built for one of `platform_check_targets`: its target, its zimr module, its numerics modules.
const PlatformCheckEngine = struct {
    target: ResolvedTarget,
    zimr_mod: *Module,
    numerics: NumericsModules,
};

pub const AppContext = struct {
    b: *std.Build,
    wgpu_smoke_install: *Step,
    smoke_focus: []const u8,
    /// The target every app module is built for: wasm for the web, Windows for the native host.
    target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zimr_mod: *Module,
    zimrmath_mod: *Module,
    /// zimrnum, the numerics library.
    zimrnum_mod: *Module,
    zimrrl_mod: *Module,
    /// The ONE `kompute` module, shared by EVERY compute example. See its creation site: built
    /// per-example, two compute examples on one page collide as `kompute`/`kompute0`.
    kompute_mod: *Module,
    shader_interface_mod: *Module,
    buildaux_exe: *Compile,
    c2js_exe: *Compile,
    shader_pipeline: *ShaderPipeline,
    /// The engine's shaders an app may embed (`wireEngineShaders`): WGSL in the web context, SPIR-V in the native one.
    engine_shader_embeds: []const EngineShaderEmbed,
    /// The build-time mesh baker; consumed by the `bakeMesh` helper.
    mesh_bake_exe: *Compile,
    /// Shared modules so common source files (common.zig, fonts, shaders) are
    /// each in exactly ONE module across the whole build - required so a launcher
    /// that imports many example modules into one binary does not duplicate them.
    common_mod: *Module,
    roboto_mod: *Module,
    atkinson_mod: *Module,
    ogg_mod: *Module,
    wav_mod: *Module,
    shader_cache: *StringHashMap(ShaderDep),
    /// Needed to build an example's job-kernel wasm: it is a DIFFERENT target
    /// (wasm32-freestanding, not wasi), so it needs its own module instances - and those
    /// need their own `build_options`.
    build_opts_wgpu: *Options,
    build_opts_zm: *Options,
    /// Whether each shader is embedded as the compiler's SPIR-V rather than as WGSL - for the native (Vulkan) host.
    /// The import keeps the shader's WGSL name either way, so app code reads the same import on both hosts.
    vulkan_shaders: bool = false,
    /// The check every native program passes before it is installed (`tools/native_wgsl_check.zig`: no WGSL inside),
    /// or null where no native programs are built.
    native_wgsl_check: ?*Compile = null,
    /// A Zig compiler bug's workaround every Windows program's PDB goes through (`tools/pdb_void_workaround.zig`), or
    /// null where no Windows programs are built. Deleted with the tool once Zig is fixed.
    pdb_void_workaround: ?*Compile = null,
    /// The check every web page's wasm passes (`tools/bridge_import_check.zig`): every import registered by the bridge.
    bridge_import_check: ?*Compile = null,

    /// Example module using the SHARED common/font modules (no fresh per-example
    /// instances) so the file graph stays single-owner. Mirrors `buildUserMod`.
    pub fn buildUserModShared(ctx: AppContext, name: []const u8) *Module {
        const b: *std.Build = ctx.b;
        const under: []const u8 = name;
        return ctx.userModule(b.path(b.fmt("examples/{s}/{s}.zig", .{ under, under })));
    }

    /// An app module rooted anywhere - a zimr example or a project's app - with the
    /// imports every app gets. `Project` builds its apps through this too, so the two
    /// cannot drift apart.
    pub fn userModule(ctx: AppContext, root: LazyPath) *Module {
        const user_mod: *Module = ctx.b.createModule(.{
            .root_source_file = root,
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
        user_mod.addImport("zimr", ctx.zimr_mod);
        user_mod.addImport("zm", ctx.zimrmath_mod);
        // zimrnum: the numerics library. `zm`-and-`kompute`-only, so an example gains it
        // without pulling anything new into the graph.
        user_mod.addImport("zn", ctx.zimrnum_mod);
        user_mod.addImport("zrl", ctx.zimrrl_mod);
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
        ctx.addShaderDepFrom(target_mod, basename, ctx.b.path("examples"));
    }

    /// `addShaderDepShared` for shaders in any directory: `<dir>/<basename>.zig` and its
    /// `<dir>/<basename>_io.zig`. The cache is keyed by basename alone, so every shader
    /// wired through one context must come from one directory - a `Project` gets a
    /// context (and cache) of its own for that reason.
    pub fn addShaderDepFrom(
        ctx: AppContext,
        target_mod: *Module,
        basename: []const u8,
        dir: LazyPath,
    ) void {
        const b: *std.Build = ctx.b;
        const dep: ShaderDep = ctx.shader_cache.get(basename) orelse blk: {
            const src: LazyPath = dir.path(b, b.fmt("{s}.zig", .{basename}));
            const io_path: LazyPath = dir.path(b, b.fmt("{s}_io.zig", .{basename}));
            const sh: ShaderPipeline.ShaderOutput = ctx.shader_pipeline.addShaderEx(src, .{
                .shader_io = io_path,
                .shader_basename = basename,
                .emit_wgsl = !ctx.vulkan_shaders,
                .wgsl_strict = true,
            });
            // The shader's bytes, under its WGSL name either way: the web embeds the WGSL, the native host the
            // compiler's SPIR-V.
            const embedded: LazyPath = if (ctx.vulkan_shaders) sh.spv else (sh.wgsl orelse
                std.debug.panic("addShaderDepShared: {s} produced no WGSL", .{basename}));
            const wgsl_mod: *Module = b.createModule(.{ .root_source_file = embedded });
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
    /// import several into one binary. The whole example = this + `finishWgpuApp`.
    pub fn buildAppModule(ctx: AppContext, app: App) *Module {
        const b: *std.Build = ctx.b;
        const user_mod: *Module = ctx.buildUserModShared(app.name);
        for (app.shaders) |shader_basename| {
            ctx.addShaderDepShared(user_mod, shader_basename);
        }
        if (app.compute_kernels.len > 0) {
            const app_dir: LazyPath = b.path(b.fmt("examples/{s}", .{app.name}));
            ctx.wireComputeKernels(user_mod, b, app_dir, app.compute_kernels);
        }
        for (app.app_deps) |dep| {
            user_mod.addImport(dep, ctx.buildUserModShared(dep));
        }
        if (app.configure) |configure| {
            configure(ctx, user_mod);
        }
        return user_mod;
    }

    /// Wire GPU compute into an app's module: import `kompute` and compile
    /// each kernel (Zig -> SPIR-V -> WGSL). A kernel lives at
    /// `<app_dir>/<basename>.zig` unless its `source_path` says otherwise, which
    /// is resolved against `owner` - the builder that registered the app (zimr's
    /// for its examples, the project's for a `Project` app).
    pub fn wireComputeKernels(
        ctx: AppContext,
        user_mod: *Module,
        owner: *std.Build,
        app_dir: LazyPath,
        kernels: []const ComputeKernel,
    ) void {
        const b: *std.Build = ctx.b;

        // THE SHARED MODULE - not a fresh one. Minting one here per example is what produced
        // `kompute0` and made two compute examples unable to share a page. See its creation site.
        user_mod.addImport("kompute", ctx.kompute_mod);

        // The conformance table - the CPU reference the GPU sweep is judged against - is engine
        // code (`src/gpu/zn_conformance.zig`), not part of any example. Offered to every app
        // that takes compute kernels; the field sweep is the one that uses it today.
        const conformance_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/gpu/zn_conformance.zig"),
        });
        conformance_mod.addImport("zm", ctx.zimrmath_mod);
        conformance_mod.addImport("zn", ctx.zimrnum_mod);
        conformance_mod.addImport("zrl", ctx.zimrrl_mod);
        user_mod.addImport("zn_conformance", conformance_mod);
        // The browser runs each entry's WGSL; the native host, the kernel file's SPIR-V - under the same import name.
        const kernel_embed: ShaderPipeline.KernelEmbed = if (ctx.vulkan_shaders) .spirv else .wgsl;
        for (kernels) |k| {
            const kernel_src: LazyPath = if (k.source_path) |custom|
                owner.path(custom)
            else
                app_dir.path(b, b.fmt("{s}.zig", .{k.basename}));

            // ---- THE KERNEL'S ZIG SOURCE, AS A NAMED MODULE ----
            //
            // `addComputeKernelImports` below provides only the COMPILED WGSL, as
            // `<entry>_wgsl`. The Zig source was reached by a RELATIVE import in the example
            // - `@import("zn_matmul.zig")` - which is what tied the kernels to living beside
            // the example that used them. They are 2,185 lines whose whole closure is
            // `kompute` + `zm`; that is library code, and it belongs under `src/`.
            //
            // Exposed here as `@import("<basename>")` so the caller no longer cares where the
            // file sits, which is the entire blocker to moving it.
            const kernel_mod: *Module = b.createModule(.{ .root_source_file = kernel_src });
            kernel_mod.addImport("kompute", ctx.kompute_mod);
            kernel_mod.addImport("zm", ctx.zimrmath_mod);
            if (k.wants_zimrnum) {
                kernel_mod.addImport("zn", ctx.zimrnum_mod);
            }
            if (k.wants_zimrrl) {
                kernel_mod.addImport("zrl", ctx.zimrrl_mod);
            }
            user_mod.addImport(k.basename, kernel_mod);

            if (k.entries) |entries| {
                ctx.shader_pipeline.addComputeKernelImports(
                    user_mod,
                    kernel_src,
                    entries,
                    k.wants_zimrnum,
                    k.wants_zimrrl,
                    kernel_embed,
                );
            } else {
                ctx.shader_pipeline.addComputeImport(
                    user_mod,
                    kernel_src,
                    b.fmt("{s}_wgsl", .{k.basename}),
                    kernel_embed,
                );
            }
        }
    }
};

// ---- configure helpers ---------------------------------------------------
// Composable building blocks for an App's `configure` hook. Each does one
// thing to the example's module; a per-example configure function calls
// whichever it needs. This is where special wiring lives instead of as fields on
// `App`. (A project has no hook: `Project.addApp` returns the app's module, and
// `Project.bakeMesh` / `App.engine_wgsl` cover these two helpers.)

/// Wire every engine shader into `mod` as a named embed, so the example can `@embedFile` it (`pbr_vs.wgsl` for
/// z.pbr3d, say): the context's form of each - WGSL for the browser, SPIR-V for the native host.
pub fn wireEngineShaders(ctx: AppContext, mod: *Module) void {
    for (ctx.engine_shader_embeds) |embed| {
        mod.addAnonymousImport(embed.name, .{ .root_source_file = embed.path });
    }
}

/// Bake `glb` (a .glb or .obj) into a `<import_name>.zig` proxy mesh at build
/// time via `mesh_bake_exe` (grid = vertex-clustering resolution, base = baked
/// texture size) and import it under `import_name`.
pub fn bakeMesh(
    ctx: AppContext,
    mod: *Module,
    glb: LazyPath,
    import_name: []const u8,
    grid: u32,
    base: u32,
) void {
    const bake_run: *Run = ctx.b.addRunArtifact(ctx.mesh_bake_exe);
    bake_run.addFileArg(glb);
    const baked_path: LazyPath = bake_run.addOutputFileArg(ctx.b.fmt("{s}.zig", .{import_name}));
    bake_run.addArg(ctx.b.fmt("{d}", .{grid}));
    bake_run.addArg(ctx.b.fmt("{d}", .{base}));
    mod.addAnonymousImport(import_name, .{ .root_source_file = baked_path });
}

/// Every kernel of `src/gpu/zn_mlp.zig`: the pages that build their pipeline table from the module's whole kernel
/// list (geno_ppo, geno_lab) register them all, SAC's and SuperTrack's included.
const zn_mlp_entries = [_][]const u8{
    "dense_fwd",
    "act_bwd",
    "dense_bwd_x",
    "dense_bwd_w",
    "mse_bwd",
    "mse_value",
    "adam",
    "ppo_mean_grad",
    "ppo_logstd_grad",
    "squash_fwd",
    "squash_logp",
    "sac_target",
    "min_route",
    "squash_bwd",
    "squash_logstd_grad",
    "alpha_grad",
    "polyak",
    "cp_wm_input",
    "cp_wm_input_bwd",
    "cp_force",
    "cp_force_bwd",
    "cp_step",
    "cp_step_bwd",
    "cp_track_bwd",
    "add_block",
    "lat_advance",
    "lat_take",
    "lat_gather",
    "lat_act",
    "lat_act_bwd",
    "st_policy_fwd",
    "st_policy_bwd",
    "st_world_fwd",
    "st_world_bwd",
    "st_reduce",
};

/// geno_lab: the training lab. Embeds the dance clip the training page trains on (`examples/geno_ppo/dance.zclip`),
/// the one file both read.
fn configureGenoLab(ctx: AppContext, mod: *Module) void {
    mod.addAnonymousImport("geno_dance_zclip", .{ .root_source_file = ctx.b.path("examples/geno_ppo/dance.zclip") });
}

/// geno_dance: the skinned-character viewer. Embeds the engine WGSL so its shadow and
/// G-buffer passes (mocap_plan.md section 12) can build their own pipelines from `depth_vs/fs` and
/// `lit_shadow_vs/fs` rather than duplicating those shaders.
fn configureGenoDance(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
}

/// helmet_sw: a CPU vs GPU comparison of one PBR shader. Embeds the engine
/// WGSL (pbr_vs/fs) and bakes a low-res proxy mesh for the comptime corner.
fn configureHelmetSw(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    bakeMesh(ctx, mod, ctx.b.path("examples/helmet_sw/DamagedHelmet.glb"), "helmet_proxy", 16, 64);
}

/// shadowmap_sw: the shadow-map CPU | GPU | comptime side-by-side.  Engine
/// WGSL (depth_* + lit_shadow_*), the full bunny OBJ for the live halves, and
/// the decimated proxy (mesh_bake OBJ path) for the comptime corner.
fn configureCelShading(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    mod.addAnonymousImport("bunny.obj", .{
        .root_source_file = ctx.b.path("examples/shadowmap/bunny.obj"),
    });
}

fn configureShadowmapSw(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    mod.addAnonymousImport("bunny.obj", .{
        .root_source_file = ctx.b.path("examples/shadowmap/bunny.obj"),
    });
    bakeMesh(ctx, mod, ctx.b.path("examples/shadowmap/bunny.obj"), "bunny_proxy", 10, 2);
}

/// pbr demo: engine WGSL + the raw helmet glb as a named embed (it lives outside
/// the demo's package dir).
fn configurePbr(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    mod.addAnonymousImport("DamagedHelmet.glb", .{
        .root_source_file = ctx.b.path("examples/assets/DamagedHelmet.glb"),
    });
}

fn configureAnimBlend(ctx: AppContext, mod: *Module) void {
    // CC0 rigged character (models by @iP) - walk + attack clips.
    mod.addAnonymousImport("greenman.glb", .{
        .root_source_file = ctx.b.path("examples/assets/gltf/greenman.glb"),
    });
}

fn configureBoneSocket(ctx: AppContext, mod: *Module) void {
    // CC0 rigged character + sword from raylib's resources (models by @iP).
    mod.addAnonymousImport("greenman.glb", .{
        .root_source_file = ctx.b.path("examples/assets/gltf/greenman.glb"),
    });
    mod.addAnonymousImport("greenman_sword.glb", .{
        .root_source_file = ctx.b.path("examples/assets/gltf/greenman_sword.glb"),
    });
}

fn configureNormalmap(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    mod.addAnonymousImport("tiles_diffuse.png", .{
        .root_source_file = ctx.b.path("examples/assets/normalmap/tiles_diffuse.png"),
    });
    mod.addAnonymousImport("tiles_normal.png", .{
        .root_source_file = ctx.b.path("examples/assets/normalmap/tiles_normal.png"),
    });
}

/// gltf-textured demo: engine WGSL + the shared quad glb data module (also lives
/// outside the demo's package dir).
fn configureGltfTextured(ctx: AppContext, mod: *Module) void {
    wireEngineShaders(ctx, mod);
    mod.addAnonymousImport("quad_glb_data.zig", .{
        .root_source_file = ctx.b.path("examples/quad_glb_data.zig"),
    });
}

// ============================================================================
// Project: the build of an application that depends on zimr.
// ============================================================================

//
// A project's whole build.zig can be:
//
//     const std = @import("std");
//     const zimr = @import("zimr");
//
//     pub fn build(b: *std.Build) void {
//         const project: *zimr.Project = .init(b, .{});
//         _ = project.addApp(.{ .name = "mygame", .title = "My game" });
//     }
//
// That gives `zig build` (every app into zig-out/web/), `zig build serve`,
// `zig build <name>`, `zig build run-<name>` (build it, then run it: the program,
// its page in a browser, or with -Dplatform=android its app on the phone),
// `zig build run` (the first app's run-<name>), `zig build <name>-standalone`,
// `zig build test` and `zig build check`, and the `-Dmode=debug|release|ship` option.
//
// A project's build.zig runs AFTER zimr's `build()` has configured the engine as a
// dependency - every module, tool and the shader pipeline - and `Project` REUSES
// those instances rather than making a second set: there must be exactly one
// `kompute` module (two collide as `kompute`/`kompute0`), and zimr's tools resolve
// their own sources against zimr's tree. `build()` leaves them in
// `published_engines` (see `publishEngine`); `Project.init` finds zimr's entry.

/// `-Dmode`, the one build knob (see `build`). A project declares the same option
/// and forwards it, so the engine and the apps always compile in the same mode.
pub const Mode = enum {
    debug,
    release,
    ship,
};

/// What zimr's `build()` leaves for projects: the example build context, plus the
/// dev server. `builder` is zimr's builder, the key `Project.init` looks it up by.
const PublishedEngine = struct {
    builder: *std.Build,
    /// The web build's context, and the Windows one: a project builds its apps with the one `-Dplatform` picks.
    ctx: AppContext,
    windows_ctx: AppContext,
    serve_exe: *Compile,
    /// The build-log distiller, which a project installs into its own zig-out/bin (`zig build zbuild`).
    zbuild_exe: *Compile,
    /// The editor-config writer (`tools/gen_editor_configs.zig`), which a project runs over its own apps
    /// (`Project.Config.editor_configs`).
    editor_configs_exe: *Compile,
    /// The APK packer (`tools/android_apk.zig`), which packs a project's pages under `-Dplatform=android`.
    android_apk_exe: *Compile,
};

/// One entry per configured zimr instance (in practice one). A file-scope `var`
/// because it is the only channel from a dependency's `build()` to the build
/// functions a consumer calls afterwards: both are this same file, compiled once
/// into the build runner.
// lint:off module-var: only channel from a dependency's build() to the consumer's build calls
var published_engines: ArrayList(PublishedEngine) = .empty;

/// zimr's own build.zig struct: `dependencyFromBuildZig` finds zimr by it, whatever
/// name the project gave the dependency.
const build_zig = @This();

fn newShaderCache(b: *std.Build) *StringHashMap(ShaderDep) {
    const cache: *StringHashMap(ShaderDep) = b.allocator.create(StringHashMap(ShaderDep)) catch @panic("OOM");
    cache.* = StringHashMap(ShaderDep).init(b.allocator);
    return cache;
}

/// Publish the example build context for `Project`. `ctx` points at `build()`'s
/// locals, which are gone by the time a project reads it, so the pipeline is
/// copied to the heap; the shader cache is left empty for `Project.init` to
/// replace with one of the project's own.
fn publishEngine(
    b: *std.Build,
    ctx: AppContext,
    windows_ctx: AppContext,
    serve_exe: *Compile,
    zbuild_exe: *Compile,
    editor_configs_exe: *Compile,
    android_apk_exe: *Compile,
) void {
    const pipeline: *ShaderPipeline = b.allocator.create(ShaderPipeline) catch @panic("OOM");
    pipeline.* = ctx.shader_pipeline.*;
    var published: AppContext = ctx;
    published.shader_pipeline = pipeline;
    published.shader_cache = newShaderCache(b);
    var published_windows: AppContext = windows_ctx;
    published_windows.shader_pipeline = pipeline;
    published_windows.shader_cache = newShaderCache(b);
    published_engines.append(b.allocator, .{
        .builder = b,
        .ctx = published,
        .windows_ctx = published_windows,
        .serve_exe = serve_exe,
        .zbuild_exe = zbuild_exe,
        .editor_configs_exe = editor_configs_exe,
        .android_apk_exe = android_apk_exe,
    }) catch @panic("OOM");
}

/// Every .zig file under the project-relative `dirs`, for zimrlint (which takes files).
/// A configure-time walk, so it poisons the configure cache (see `collectShaderFiles`).
fn zigFilesUnder(b: *std.Build, dirs: []const []const u8) []const LazyPath {
    b.graph.poisonCache();
    const io: Io = b.graph.io;
    var files: ArrayList(LazyPath) = .empty;
    for (dirs) |root| {
        var dir: Io.Dir = b.root.root_dir.handle.openDir(io, root, .{ .iterate = true }) catch
            std.debug.panic("zimr.Project: cannot open lint directory '{s}'", .{root});
        defer dir.close(io);
        var walker: Io.Dir.Walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !endsWith(u8, entry.basename, ".zig")) {
                continue;
            }
            // `entry.path` uses OS separators and is only valid until the next `next()`.
            const rel: []u8 = b.fmt("{s}/{s}", .{ root, entry.path });
            for (rel) |*c| {
                if (c.* == '\\') {
                    c.* = '/';
                }
            }
            files.append(b.allocator, b.path(rel)) catch @panic("OOM");
        }
    }
    return files.items;
}

pub const Project = struct {
    b: *std.Build,
    /// The zimr dependency, resolved with this project's `-Dmode`.
    dep: *std.Build.Dependency,
    /// zimr's engine for the platform the apps are built for (`platform`) - the web's or Windows' - with a
    /// shader cache of the project's own: shader basenames are the project's choice, and its `julia_fs` must not
    /// resolve to zimr's.
    ctx: AppContext,
    /// The web's context, whatever the platform: the host tests' numerics modules come from it.
    web_ctx: AppContext,
    /// The platform the apps are built for (`-Dplatform`, read as zimr's own build reads it); null on a machine
    /// zimr has no platform for, where each app's step fails naming the choices.
    platform: ?Platform,
    mode: Mode,
    /// The apps' target - the web's wasm, or Windows' - and optimize mode, for adding another package's module
    /// to an app (`b.dependency("foo", .{ .target = project.target, ... })`).
    target: ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shader_dir: LazyPath,
    web_dir: std.Build.InstallDir,
    test_step: *Step,
    check_step: *Step,
    /// Set when `Config.lint` is: every app's step and `check` depend on it.
    lint_step: ?*Step,
    /// What every served page needs beside its own files: zimr.js, and the public directory's gallery. A web app's
    /// `run-<name>` installs these and that app only; the default install, every app.
    site_step: *Step,
    /// The dev server, and the port it serves on (`Config.port`): `serve`, and each web app's `run-<name>`.
    serve_exe: *Compile,
    port: []const u8,
    /// zimr's APK packer, for each app under `-Dplatform=android` (`addAndroidBuild`).
    android_apk_exe: *Compile,
    /// `zig build run`: the first app's `run-<name>`, which `addApp` wires in.
    run_step: *Step,
    /// Whether an app is wired into `run_step` yet.
    has_run_app: bool,
    /// The two runs of zimr's editor-config writer when `Config.editor_configs` is on - `zig build editor-configs`,
    /// and its `--check` in `check` - which `addApp` names every app to. Empty when the configs are off.
    editor_configs_runs: []const *Run,

    pub const Config = struct {
        /// Copied as-is into zig-out/web/: the gallery page, a manifest, icons.
        /// Skipped when the directory does not exist.
        public_dir: ?[]const u8 = "public",
        /// Where `App.shaders` basenames are looked up.
        shader_dir: []const u8 = "src/shaders",
        /// The dev server's port (`zig build serve`, and `run-<name>` on the web).
        port: []const u8 = "8080",
        /// zimr's linter over the project's sources. Gates the shareable artifacts
        /// (`*-standalone`) and `check`, never a plain build.
        lint: ?Lint = null,
        /// VS Code and Zed debug configs in the project's .vscode/ and .zed/, as zimr keeps its own: for every app a
        /// web one (Chrome, through the dev server) and a Windows one (CodeLLDB), each with the task that builds the
        /// app first. `zig build editor-configs` writes them, and `check` fails once an app is added
        /// without rewriting them.
        editor_configs: bool = false,
    };

    pub const Lint = struct {
        /// Project-relative directories: every .zig file under them is linted.
        dirs: []const []const u8 = &.{"src"},
        /// The rules to hold them to - every rule is opt-in, so an empty list checks nothing (the template
        /// lists all of them). Only the project's own files are linted, never zimr's.
        enable: []const LintRule = &.{},
    };

    /// One browser app. The fields mirror zimr's own `App` rows, so an example copies
    /// into a project with its row.
    pub const App = struct {
        /// Names the wasm, the page directory (zig-out/web/<name>/), and the steps `<name>`, `run-<name>` and
        /// `<name>-standalone` - so not `install`, `serve`, `run`, `test`, `check` or `zbuild`.
        name: []const u8,
        /// The page's <title>.
        title: []const u8,
        /// Default: src/<name>/<name>.zig when it exists, else src/<name>.zig. An app
        /// with compute or job kernels wants its own directory: they sit beside it.
        root_source_file: ?LazyPath = null,
        /// Typed Zig shaders by basename, each `<shader_dir>/<basename>.zig` beside its
        /// `<basename>_io.zig`. The app embeds "<basename>.wgsl" and imports
        /// "<basename>_io.zig".
        shaders: []const []const u8 = &.{},
        /// GPU compute (`kompute`): each kernel is `<app dir>/<basename>.zig`, or its
        /// project-relative `source_path`.
        compute_kernels: []const ComputeKernel = &.{},
        /// Off-main-thread jobs (`zimr.jobs`): `<app dir>/kernels.zig` becomes the
        /// zero-import wasm the page's Web Workers run.
        job_kernels: bool = false,
        /// Embed every engine shader's WGSL (`@embedFile("pbr_fs.wgsl")`, ...).
        engine_wgsl: bool = false,
        /// The app's source is the program's root - the wasm's, or the Windows program's - instead of zimr's runner:
        /// it declares `main` (which calls `App.run`) and opens and closes each frame itself. Such an app is not a
        /// descriptor, so no launcher can host it.
        own_frame: bool = false,
        /// The page's fullscreen-toggle button, in its bottom-right corner; the page stays full-canvas without it.
        fullscreen_button: bool = true,
        /// The Android app's ID (`-Dplatform=android`): who the app is to a phone and to the Play Store, so it never
        /// changes once the app is published - give it your own before then. null: `org.zimr.<name>`.
        android_app_id: ?[]const u8 = null,
        /// The name under the Android app's icon. null: the title.
        android_label: ?[]const u8 = null,
        /// The Android app's icon (`zimr.AndroidIcon`), its paths from the project's root. null: Android's default.
        android_icon: ?AndroidIcon = null,
    };

    pub const AppBuild = struct {
        exe: *Compile,
        /// The app's module: give it embeds (`addAnonymousImport`) and imports.
        module: *Module,
    };

    pub fn init(b: *std.Build, config: Config) *Project {
        const mode: Mode = b.option(Mode, "mode", "debug | release | ship (default: debug)") orelse .debug;
        const dep: *std.Build.Dependency = b.dependencyFromBuildZig(build_zig, .{ .mode = mode });
        const engine: PublishedEngine = for (published_engines.items) |e| {
            if (e.builder == dep.builder) {
                break e;
            }
        } else @panic("zimr.Project: zimr's build() published no engine");

        const platform: ?Platform = b.option(
            Platform,
            "platform",
            "web | windows | android (default: this machine's platform, when zimr has one)",
        ) orelse hostPlatform();
        var web_ctx: AppContext = engine.ctx;
        web_ctx.shader_cache = newShaderCache(b);
        var windows_ctx: AppContext = engine.windows_ctx;
        windows_ctx.shader_cache = newShaderCache(b);
        const ctx: AppContext = if (platform == .windows) windows_ctx else web_ctx;
        const web_dir: std.Build.InstallDir = .{ .custom = "web" };

        const p: *Project = b.allocator.create(Project) catch @panic("OOM");
        p.* = .{
            .b = b,
            .dep = dep,
            .ctx = ctx,
            .web_ctx = web_ctx,
            .platform = platform,
            .mode = mode,
            .target = ctx.target,
            .optimize = ctx.optimize,
            .shader_dir = b.path(config.shader_dir),
            .web_dir = web_dir,
            .test_step = b.step("test", "Run the host unit tests"),
            .check_step = b.step("check", "Lint (when configured), host tests, and build every app"),
            .lint_step = null,
            .site_step = gatheringStep(b, "the site's shared files"),
            .serve_exe = engine.serve_exe,
            .port = config.port,
            .android_apk_exe = engine.android_apk_exe,
            .run_step = b.step("run", "Build the first app for -Dplatform and run it (as its run-<name> does)"),
            .has_run_app = false,
            .editor_configs_runs = &.{},
        };
        p.check_step.dependOn(p.test_step);
        p.check_step.dependOn(b.getInstallStep());
        b.getInstallStep().dependOn(p.site_step);

        // The runtime every served page loads as ../zimr.js.
        const zimr_js: LazyPath = runtimeJs(ctx.b, ctx.c2js_exe);
        p.site_step.dependOn(&b.addInstallFileWithDir(zimr_js, web_dir, "zimr.js").step);

        if (config.public_dir) |dir| {
            if (projectHas(b, dir)) {
                const public_install: *std.Build.Step.InstallDir = b.addInstallDirectory(.{
                    .source_dir = b.path(dir),
                    .install_dir = web_dir,
                    .install_subdir = "",
                });
                p.site_step.dependOn(&public_install.step);
            }
        }

        // Relative to the project root, so this assumes the default `zig-out` prefix -
        // as zimr's own `serve` does.
        const serve_run: *Run = addServeRun(b, engine.serve_exe, config.port, null);
        serve_run.step.dependOn(b.getInstallStep());
        const serve_step: *Step = b.step(
            "serve",
            b.fmt("Build every app and serve zig-out/web/ on http://127.0.0.1:{s}/", .{config.port}),
        );
        // The dev server serves the web build: under another platform it says so rather than serve stale pages.
        if (platform == .web) {
            serve_step.dependOn(&serve_run.step);
        } else {
            const message: []const u8 = "serve builds and serves the web build: run zig build serve -Dplatform=web";
            serve_step.dependOn(&b.addFail(message).step);
        }

        // `zig build zbuild` - zimr's build-log distiller, installed into the project's zig-out/bin: a step only
        // installs it, since it runs `zig build` itself (see tools/zbuild.zig).
        const zbuild_install: *Step.InstallArtifact = b.addInstallArtifact(engine.zbuild_exe, .{});
        const zbuild_step: *Step = b.step(
            "zbuild",
            "Install zbuild into zig-out/bin: `zig build`, ending with only what failed",
        );
        zbuild_step.dependOn(&zbuild_install.step);
        suggestZbuild(b, "zig-out/bin/zbuild");

        // `zig build editor-configs` - zimr's own editor-config writer, over the project's apps (`addApp` names
        // each one to both runs) - and its `--check` in `check`, so an app added without rewriting them fails there.
        if (config.editor_configs) {
            const write_run: *Run = editorConfigsRun(b, engine.editor_configs_exe, config.port);
            const check_run: *Run = editorConfigsRun(b, engine.editor_configs_exe, config.port);
            check_run.addArg("--check");
            // It reads the four files, which are not declared inputs: never trust a cached pass.
            check_run.has_side_effects = true;
            const editor_configs_step: *Step = b.step(
                "editor-configs",
                "Write .vscode/ and .zed/: a web and a Windows debug config for every app, and their build tasks",
            );
            editor_configs_step.dependOn(&write_run.step);
            p.check_step.dependOn(&check_run.step);
            p.editor_configs_runs = b.allocator.dupe(*Run, &.{ write_run, check_run }) catch @panic("OOM");
        }

        if (config.lint) |lint| {
            const lint_step: *Step = b.step("lint", "Run zimr's linter over the project's sources");
            const lint_files: []const LazyPath = zigFilesUnder(b, lint.dirs);
            const lint_options: LintOptions = .{
                .files = lint_files,
                .enable = lint.enable,
                .fix_command = "zig build lint-fix",
            };
            lint_step.dependOn(&addLint(b, dep, lint_options).step);
            p.check_step.dependOn(lint_step);
            p.lint_step = lint_step;
            // `zig build lint-fix` - what every fixable finding points to, and the one step that rewrites a source:
            // the autofixes, each file written once and laid out as `zig fmt` lays it out (whether or not the
            // project's rules check layout), and the diff of every file printed as it is written. Named beside
            // `lint` so it says what it fixes: a bare `fix` read as fixing whatever failed.
            var fix_options: LintOptions = lint_options;
            fix_options.fix = true;
            fix_options.enable = withZigFmt(b, lint.enable);
            const lint_fix_step: *Step = b.step(
                "lint-fix",
                "Rewrite sources: lint autofixes, zig fmt layout, each diff shown",
            );
            lint_fix_step.dependOn(&addLint(b, dep, fix_options).step);
        }
        return p;
    }

    /// A run of zimr's editor-config writer from the project's root, in its project form: steps and outputs spelled as
    /// the apps are named, the dev server the project's `serve` on `port`. The apps come later, from `addApp`.
    fn editorConfigsRun(b: *std.Build, writer_exe: *Compile, port: []const u8) *Run {
        const run: *Run = b.addRunArtifact(writer_exe);
        run.addArgs(&.{ "--project", b.fmt("--port={s}", .{port}) });
        run.setCwd(b.path("."));
        return run;
    }

    /// How an app's `run-<name>` runs it once built (`appRun`): the installed Windows program, its page through the dev
    /// server, or the run that puts its Android app on the phone and starts it (`AndroidBuild.phone_run`).
    const AppRunner = union(enum) {
        program: *Compile,
        page,
        phone: *Run,
    };

    /// What an app's `run-<name>` does once `app_step` has built the app, as `runner` says. On a machine zimr has no
    /// platform for, `app_step` fails naming the choices, and running is that failure.
    fn appRun(
        p: *Project,
        name: []const u8,
        app_step: *Step,
        runner: AppRunner,
    ) *Step {
        const b: *std.Build = p.b;
        if (p.platform == null) {
            return app_step;
        }
        switch (runner) {
            .program => |exe| {
                const program_run: *Run = b.addRunArtifact(exe);
                program_run.step.dependOn(app_step);
                return &program_run.step;
            },
            .phone => |phone_run| {
                phone_run.step.dependOn(app_step);
                return &phone_run.step;
            },
            .page => {
                const page_run: *Run = addServeRun(b, p.serve_exe, p.port, b.fmt("/{s}/", .{name}));
                page_run.step.dependOn(app_step);
                // The page loads ../zimr.js, one of the site's shared files.
                page_run.step.dependOn(p.site_step);
                return &page_run.step;
            },
        }
    }

    /// The app's `run-<name>` step (`appRun`). The first app's is also `zig build run`.
    fn addAppRun(
        p: *Project,
        name: []const u8,
        app_step: *Step,
        runner: AppRunner,
    ) void {
        const b: *std.Build = p.b;
        const app_run: *Step = p.appRun(name, app_step, runner);
        const run_app_step: *Step = b.step(
            b.fmt("run-{s}", .{name}),
            b.fmt("Build {s} for -Dplatform and run it: the program, its page in a browser, or on the phone", .{name}),
        );
        run_app_step.dependOn(app_run);
        if (!p.has_run_app) {
            p.run_step.dependOn(app_run);
            p.has_run_app = true;
        }
    }

    /// Add one browser app: its wasm and served page (in `zig build` and step
    /// `<name>`), its single self-contained HTML file (`<name>-standalone`), and
    /// `run-<name>`, which builds it and runs it.
    pub fn addApp(p: *Project, app: Project.App) AppBuild {
        const b: *std.Build = p.b;
        const ctx: AppContext = p.ctx;
        const root: LazyPath = app.root_source_file orelse p.defaultRoot(app.name);
        const app_dir: LazyPath = root.dirname();

        const user_mod: *Module = ctx.userModule(root);
        for (app.shaders) |basename| {
            ctx.addShaderDepFrom(user_mod, basename, p.shader_dir);
        }
        if (app.compute_kernels.len > 0) {
            ctx.wireComputeKernels(user_mod, b, app_dir, app.compute_kernels);
        }
        if (app.engine_wgsl) {
            wireEngineShaders(ctx, user_mod);
        }
        const app_step: *Step = b.step(app.name, b.fmt(
            "Build {s} for -Dplatform: zig-out/web/{s}/ and zig-out/standalone/{s}.html, zig-out/windows/{s}.exe or " ++
                "zig-out/android/{s}.apk",
            .{ app.name, app.name, app.name, app.name, app.name },
        ));
        if (p.lint_step) |lint_step| {
            app_step.dependOn(lint_step);
        }
        // Whatever `-Dplatform` this build is for, the app builds for both, so the editor configs debug it on both.
        for (p.editor_configs_runs) |editor_configs_run| {
            editor_configs_run.addArgs(&.{ app.name, b.fmt("--windows={s}", .{app.name}) });
        }
        if (p.platform == .windows) {
            // Natively, background jobs run in the program itself, so no kernel wasm is built.
            const windows_exe: *Compile = nativeAppExe(ctx, user_mod, app.name, app.own_frame);
            const windows_install: *InstallArtifact = installWindowsApp(b, ctx, windows_exe);
            b.getInstallStep().dependOn(&windows_install.step);
            app_step.dependOn(&windows_install.step);
            p.addAppRun(app.name, app_step, .{ .program = windows_exe });
            return .{ .exe = windows_exe, .module = user_mod };
        }
        const kernel_wasm: ?LazyPath = if (app.job_kernels)
            buildJobKernels(
                ctx.b,
                app.name,
                app_dir.path(b, "kernels.zig"),
                &.{},
                ctx.optimize,
                ctx.build_opts_wgpu,
                ctx.build_opts_zm,
            )
        else
            null;
        const exe: *Compile = appExe(
            b,
            ctx.b,
            app.name,
            user_mod,
            app.own_frame,
            ctx.target,
            ctx.optimize,
            ctx.zimr_mod,
            ctx.zimrmath_mod,
            ctx.shader_interface_mod,
        );
        // On Android the app is its single-file page in an APK of its own, which the app's step and the default install
        // build instead of the web's files.
        if (p.platform == .android) {
            const android_build: AndroidBuild = addAndroidBuild(b, ctx.b, p.android_apk_exe, app.name, .{
                .page = bridgePage(ctx.b, ctx.c2js_exe, exe, app.title, false, kernel_wasm, false),
                .app_id = app.android_app_id orelse defaultAndroidAppId(b, app.name),
                .label = app.android_label orelse app.title,
                .icon = app.android_icon,
            });
            b.getInstallStep().dependOn(android_build.install);
            app_step.dependOn(android_build.install);
            if (ctx.bridge_import_check) |check_exe| {
                app_step.dependOn(&addBridgeImportCheck(b, check_exe, ctx.b.path("src/bridge.zig"), exe).step);
            }
            p.addAppRun(app.name, app_step, .{ .phone = android_build.phone_run });
            return .{ .exe = exe, .module = user_mod };
        }

        // Served: web/<name>/index.html streams the <name>.wasm beside it and loads ../zimr.js.
        const app_install_dir: std.Build.InstallDir = .{ .custom = b.fmt("web/{s}", .{app.name}) };
        const wasm_install: *InstallArtifact = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = app_install_dir },
        });
        const page: LazyPath = bridgePage(
            ctx.b,
            ctx.c2js_exe,
            exe,
            app.title,
            true,
            kernel_wasm,
            app.fullscreen_button,
        );
        const page_install: *InstallFile = b.addInstallFileWithDir(page, app_install_dir, "index.html");
        b.getInstallStep().dependOn(&wasm_install.step);
        b.getInstallStep().dependOn(&page_install.step);

        // Standalone: the wasm and the runtime inlined into one file that opens from file://.
        const standalone: LazyPath = bridgePage(
            ctx.b,
            ctx.c2js_exe,
            exe,
            app.title,
            false,
            kernel_wasm,
            app.fullscreen_button,
        );
        const standalone_path: []const u8 = b.fmt("standalone/{s}.html", .{app.name});
        const standalone_install: *InstallFile = b.addInstallFile(standalone, standalone_path);
        // A machine zimr has no platform for builds nothing it would have to guess at.
        if (p.platform == null) {
            const message: []const u8 = b.fmt("zimr has no platform for this machine yet: build {s} with " ++
                "-Dplatform=web, -Dplatform=windows or -Dplatform=android", .{app.name});
            app_step.dependOn(&b.addFail(message).step);
            p.addAppRun(app.name, app_step, .page);
            return .{ .exe = exe, .module = user_mod };
        }
        app_step.dependOn(&wasm_install.step);
        app_step.dependOn(&page_install.step);
        app_step.dependOn(&standalone_install.step);
        if (ctx.bridge_import_check) |check_exe| {
            app_step.dependOn(&addBridgeImportCheck(b, check_exe, ctx.b.path("src/bridge.zig"), exe).step);
        }
        p.addAppRun(app.name, app_step, .page);
        return .{ .exe = exe, .module = user_mod };
    }

    /// A module for code several apps share, with the imports an app gets
    /// (`app.module.addImport("shared", project.addModule(b.path("src/shared.zig")))`).
    pub fn addModule(p: *Project, root: LazyPath) *Module {
        return p.ctx.userModule(root);
    }

    /// Host unit tests for pure-CPU code, run by `zig build test`. `zm` and `zn` are
    /// importable; `zimr` is not - it only builds for the browser.
    pub fn addTest(p: *Project, root: LazyPath) void {
        const b: *std.Build = p.b;
        const test_mod: *Module = b.createModule(.{
            .root_source_file = root,
            .target = b.graph.host,
            .optimize = .Debug,
        });
        test_mod.addImport("zm", p.web_ctx.zimrmath_mod);
        test_mod.addImport("zn", p.web_ctx.zimrnum_mod);
        test_mod.addImport("zrl", p.web_ctx.zimrrl_mod);
        const test_exe: *Compile = b.addTest(.{ .root_module = test_mod });
        p.test_step.dependOn(&b.addRunArtifact(test_exe).step);
    }

    /// Bake a mesh (.glb or .obj) into a proxy module `mod` imports as `import_name`
    /// (see zimr's `bakeMesh`).
    pub fn bakeMesh(
        p: *Project,
        mod: *Module,
        mesh: LazyPath,
        import_name: []const u8,
        grid: u32,
        base: u32,
    ) void {
        build_zig.bakeMesh(p.ctx, mod, mesh, import_name, grid, base);
    }

    /// A file inside zimr, for reusing its bundled assets.
    pub fn zimrPath(p: *Project, sub_path: []const u8) LazyPath {
        return p.dep.path(sub_path);
    }

    fn defaultRoot(p: *Project, name: []const u8) LazyPath {
        const nested: []const u8 = p.b.fmt("src/{s}/{s}.zig", .{ name, name });
        if (projectHas(p.b, nested)) {
            return p.b.path(nested);
        }
        return p.b.path(p.b.fmt("src/{s}.zig", .{name}));
    }
};

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
    // configure time - exactly the kind of untracked observation that the
    // Zig 0.17 configure cache cannot key on (the same reason std.Build's
    // `findProgram` poisons the cache: it walks PATH directories). Without
    // this, adding a new `*_vs.zig`/`*_fs.zig` is invisible until build.zig's
    // own content changes, because the cached configuration is reused and this
    // walk never re-runs. Poisoning forces the configurer to re-run every
    // build so discovery is always fresh. The cost is re-running the (already
    // compiled) configure phase, not recompiling build.zig - measured in
    // single-digit milliseconds for this graph; the maker still caches all
    // compilation independently.
    b.graph.poisonCache();
    const io: Io = b.graph.io;
    var paths: ArrayList([]const u8) = .empty;
    // Scan zimr's OWN tree via the build root, not cwd: when zimr is consumed as
    // a dependency, cwd is the consumer's project root (where these dirs don't
    // exist), which silently yielded zero shaders and broke the engine's
    // `@embedFile("default_shapes_vs.wgsl")` downstream. `b.root.root_dir.handle`
    // is zimr's package root in both the root and dependency builds.
    const root_dir: Io.Dir = b.root.root_dir.handle;
    for ([_][]const u8{ "src", "examples", "tests" }) |root| {
        var dir: Io.Dir = root_dir.openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker: Io.Dir.Walker = dir.walk(b.allocator) catch continue;
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

/// The fast test roots `src/robot_tests.zig` stands in for: each `@import("x.zig")` it makes, as
/// `src/x.zig`. Read at configure time so that file is the ONE list. A robot file it does not
/// import stays a `test-fast` member of its own - the failure direction is a test run twice, never
/// a test not run - and an unreadable file gives the empty list for the same reason.
fn robotTestsMembers(b: *std.Build) []const []const u8 {
    b.graph.poisonCache(); // a source file read at configure time; see collectShaderFiles
    const io: Io = b.graph.io;
    const aggregate_path: []const u8 = "src/robot_tests.zig";
    // lint:off catch-suppression: missing file -> no roots aggregated -> every root runs itself
    const text: []u8 = b.root.root_dir.handle.readFileAlloc(io, aggregate_path, b.allocator, .unlimited) catch {
        return &.{};
    };
    const import_open: []const u8 = "@import(\"";
    var members: ArrayList([]const u8) = .empty;
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const code: []const u8 = std.mem.trimStart(u8, line, " ");
        if (startsWith(u8, code, "//")) {
            continue;
        }
        const at: usize = indexOf(u8, code, import_open) orelse continue;
        const rest: []const u8 = code[at + import_open.len ..];
        const close: usize = indexOfScalar(u8, rest, '"') orelse continue;
        const target: []const u8 = rest[0..close];
        if (!endsWith(u8, target, ".zig")) {
            continue;
        }
        members.append(b.allocator, b.fmt("src/{s}", .{target})) catch @panic("OOM");
    }
    return members.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// `zig build check`: compiles the build already has, compiled again with nothing asked of them - no install, no
/// run - so Zig passes `-fno-emit-bin` and stops after semantic analysis. ZLS's build-on-save runs the step named
/// `check` on every save and shows its compile errors in the editor, so this is what the squiggles come from:
///
///   * every test compile - `src/tests.zig`, the fast roots, the native and Vulkan host tests, an example's own
///     tests, the tools' tests - so a test body is checked as well as the code it reaches;
///   * every tool under tools/;
///   * the web build of the examples `-Dfocus` names, and of `launcher` alone without it: the launcher compiles every
///     flagship in one program, the most code for one compile. Pass `-Dfocus` through ZLS's `build_on_save_args`.
///
/// Found by walking the graph, as `gateEveryTool` finds the tools, so a test added anywhere joins it. Twins - one
/// root, one name, one target - are checked once, and the robot family once, through `src/robot_tests.zig`: each of
/// its members also has a test compile of its own (its `test-<stem>` step), and checking those as well would analyse
/// the family's closure once per member, on every save. Nothing here lints, links or runs: `tripwires` and `test`
/// do that.
fn addCompileCheck(b: *std.Build, focus: []const u8) void {
    const examples_focus: []const u8 = if (focus.len == 0) "launcher" else focus;
    const robot_tests_members: []const []const u8 = robotTestsMembers(b);
    const Original = struct {
        compile: *Compile,
        root_path: []const u8,
    };
    var originals: ArrayList(Original) = .empty;
    var checked: StringHashMap(void) = .init(b.allocator);
    var visited: AutoHashMapUnmanaged(*Step, void) = .empty;
    var pending: ArrayList(*Step) = .empty;
    for (b.top_level_steps.values()) |top| {
        pending.append(b.allocator, &top.step) catch @panic("OOM");
    }
    while (pending.pop()) |step| {
        const gop: AutoHashMapUnmanaged(*Step, void).GetOrPutResult =
            visited.getOrPut(b.allocator, step) catch @panic("OOM");
        if (gop.found_existing) {
            continue;
        }
        pending.appendSlice(b.allocator, step.dependencies.items) catch @panic("OOM");
        const compile: *Compile = step.cast(Compile) orelse continue;
        const source: LazyPath = compile.root_module.root_source_file orelse continue;
        const root_path: []const u8 = switch (source) {
            .src_path => |src| src.sub_path,
            else => continue,
        };
        const target: std.Target = compile.rootModuleTarget();
        var is_robot_tests_member: bool = false;
        for (robot_tests_members) |member| {
            if (eql(u8, member, root_path)) {
                is_robot_tests_member = true;
            }
        }
        const is_test: bool = compile.kind == .@"test" and !is_robot_tests_member;
        const is_tool: bool = compile.kind == .exe and startsWith(u8, root_path, "tools/");
        // An example's page: its wasm, rooted at the runner (or at the example itself when it runs its own frames).
        const is_example_page: bool = compile.kind == .exe and target.cpu.arch == .wasm32 and
            (eql(u8, root_path, "src/wgpu_runner.zig") or startsWith(u8, root_path, "examples/"));
        const is_focused_example: bool = is_example_page and matchesFocus(compile.name, examples_focus);
        if (!is_test and !is_tool and !is_focused_example) {
            continue;
        }
        const twin_key: []const u8 = b.fmt("{t} {s} {s} {t}-{t}", .{
            compile.kind,
            compile.name,
            root_path,
            target.cpu.arch,
            target.os.tag,
        });
        if (checked.contains(twin_key)) {
            continue;
        }
        checked.put(twin_key, {}) catch @panic("OOM");
        originals.append(b.allocator, .{ .compile = compile, .root_path = root_path }) catch @panic("OOM");
    }

    const check_step: *Step = b.step(
        "check",
        "Compile-only, no binaries: every test, every tool and the -Dfocus examples (ZLS runs it on save)",
    );
    for (originals.items) |original| {
        const from: *Compile = original.compile;
        // A test is named after its root file: most are called "test", which would say nothing in the build's output.
        const is_test: bool = from.kind == .@"test";
        const twin_name: []const u8 = if (is_test) std.fs.path.stem(original.root_path) else from.name;
        const twin: *Compile = if (is_test)
            b.addTest(.{
                .name = twin_name,
                .root_module = from.root_module,
                .test_runner = from.test_runner,
            })
        else
            b.addExecutable(.{
                .name = twin_name,
                .root_module = from.root_module,
            });
        // What decides the program's start code: a page has no `main`, and without these it would be asked for one.
        twin.entry = from.entry;
        twin.wasi_exec_model = from.wasi_exec_model;
        twin.rdynamic = from.rdynamic;
        check_step.dependOn(&twin.step);
    }
}

/// `@floatFromInt` to f64. The lint prefers `zm.float64`, but build.zig is the
/// build SCRIPT - it has no `zm` module in scope and pulling zimrmath into the
/// build graph to convert four integers would be a silly dependency.
/// lint:off float-from-int: build.zig has no zm module (it builds the one that has it)
fn f64of(x: u64) f64 {
    return @floatFromInt(x);
}

const fs_space = @import("tools/fs_space.zig");

/// Free-space report for the filesystem holding the build root.
const DiskSpace = fs_space.DiskSpace;

/// Free space, from the ONE hand-declared kernel ABI in this repo.
///
/// This was three declarations and a switch right here - `LinuxStatfs`, a `kernel32` extern,
/// and `diskSpace()`. `tools/measure.zig` then grew a SECOND copy that was Linux-only and
/// returned 0 rather than null on an unsupported platform, which reads as "disk full" instead
/// of "did not measure". A hand-written kernel struct is exactly the thing not to have two of,
/// so it lives in `tools/fs_space.zig` and both callers go through it.
fn diskSpace() ?DiskSpace {
    return fs_space.query();
}

/// Guard against the ONLY failure that actually matters: running out of disk
/// mid-link, which surfaces as a cryptic "No space left on device" with no other
/// warning.
///
/// This used to guard on `.zig-cache` SIZE (6 GB on Linux) - but cache size is a
/// PROXY, and a bad one. A 6 GB cache on a disk with 100 GB free is harmless; a
/// 2 GB cache with 200 MB free is fatal. The proxy fired constantly on healthy
/// disks and its remedy - `rm -rf .zig-cache` - costs a ~16-minute cold rebuild.
/// We were paying full rebuilds to avoid a problem we did not have.
///
/// So: measure the hazard. Fail only when the filesystem is >= 97% full, which is
/// a single O(1) syscall - cheap enough to run on EVERY build, so the periodic
/// walk (and its counter file) is gone too.
///
/// 97 (not 90): keeping the dev `serve` (Debug) and the `dist` (ReleaseSmall)
/// artifacts warm side-by-side ~doubles the example cache, which alone pushed a
/// healthy disk past a 90% gate and forced a `rm -rf .zig-cache` cold rebuild -
/// the very cost this guard exists to avoid. 97% still leaves room before an
/// actual mid-link "No space left on device".
fn checkDiskSpace(b: *std.Build) void {
    const fail_at_pct: f64 = 97.0;

    const space: DiskSpace = diskSpace() orelse return; // cannot measure => do not block
    if (space.used_pct < fail_at_pct) {
        return;
    }

    // Only now is it worth walking the cache - to tell the developer where the
    // space actually went. This is the rare path.
    const io: Io = b.graph.io;
    var cache_bytes: u64 = 0;
    if (Io.Dir.cwd().openDir(io, ".zig-cache", .{ .iterate = true })) |dir_const| {
        var dir: Io.Dir = dir_const;
        defer dir.close(io);
        if (dir.walk(b.allocator)) |walker_const| {
            var walker: Io.Dir.Walker = walker_const;
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                const stat: Io.Dir.Stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
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
        \\    rm -rf .zig-cache/tmp && mkdir .zig-cache/tmp   # scratch (the build needs the dir itself)
        \\    rm -rf .zig-cache       # LAST RESORT: costs a full cold rebuild
        \\  Never delete single entries under .zig-cache/o: a cached step then fails
        \\  ("checking cache failed: FileNotFound") instead of rebuilding.
        \\
        \\
    , .{ space.used_pct, f64of(space.free_bytes) / gb, f64of(cache_bytes) / gb });
    std.process.exit(1);
}

// ============================================================================
// Zig-shader pipeline helpers - Phase 3 surface.
// ============================================================================

// ShaderPipeline + ShaderOpts now live in `src/shader_codegen.zig` so they
// can be re-exposed as a public `shader_codegen` module for downstream
// `build.zig` consumers.  Internally we alias for call-site brevity.

/// What `wireHostTestImports` wires in: the modules and the shader list `build` creates once.
const HostTestWiring = struct {
    engine_shaders: []const EngineShader,
    zimrmath_mod: *Module,
    shader_builtins_mod: *Module,
    shader_interface_mod: *Module,
    zimrnum_mod: *Module,
    zimrrl_mod: *Module,
    build_opts: *Options,
};

/// Every import `src/tests.zig`'s module needs, for `target`. ONE definition, used by the host
/// tests (native) and `test-windows` (cross-compiled, compile-only): `test-windows` had drifted to a
/// single import (`shader_interface`) and stopped compiling at the first `@import("zm")`.
fn wireHostTestImports(
    b: *std.Build,
    test_mod: *Module,
    target: ResolvedTarget,
    wiring: HostTestWiring,
) void {
    // render.zig does `@embedFile("shadow_vs.glsl")` and friends.
    // Engine shader imports get wired into
    // and every example's module above; the host test module needs
    // them too or any test reaching render.zig fails to compile.
    for (wiring.engine_shaders) |s| {
        // The GLSL path is dead. render.zig only needs these @embedFile-able to
        // COMPILE (host tests don't run GL), so wire a placeholder for the .glsl
        // imports - otherwise the host test demands the real .glsl, which runs the
        // gated-off spirv-opt/cross/zglsl pipeline and fails the gate.
        const is_glsl: bool = endsWith(u8, s.name, ".glsl");
        const src: std.Build.LazyPath = if (is_glsl)
            b.path("src/shaders/_deleted_glsl_placeholder.glsl")
        else
            s.path;
        test_mod.addAnonymousImport(s.name, .{ .root_source_file = src });
        // The WGSL twin too: the host-test graph reaches the wgpu render
        // stack now (leak_test -> draw3d -> renderer_2d, GL-retirement P5
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
                    .target = target,
                    .optimize = .ReleaseSafe,
                });
                externs_mod_t.addImport("zm", wiring.zimrmath_mod);
                externs_mod_t.addImport("shader_builtins", wiring.shader_builtins_mod);
                test_mod.addImport(externs_dep_name, externs_mod_t);
            }
        }
    }
    // `shader_interface` named module so `tests.zig`'s aggregator
    // (and any iface file reached through it) resolves
    // `@import("shader_interface")`.
    test_mod.addImport("shader_interface", wiring.shader_interface_mod);
    // Same for `zm` - the unified math module.  src/*.zig files
    // do `const zm = @import("zm");` since Stage 5 of math-
    // unification migrated path imports of math.zig to module
    // imports.  Without this wire, every src/ test that reaches
    // a math-using file fails to compile.
    test_mod.addImport("zm", wiring.zimrmath_mod);
    // `zn` because `tests.zig` reaches `zimr.zig` as a FILE (refAllDecls), not through
    // `zimr_mod`, so it needs every import `zimr_mod` has - and `zimr.zig` re-exports
    // `robot_gym`, which imports `zn`. A module import runs none of zimrnum's own tests.
    test_mod.addImport("zn", wiring.zimrnum_mod);
    test_mod.addImport("zrl", wiring.zimrrl_mod);
    test_mod.addAnonymousImport("atomic_buildgrid_spv", .{
        .root_source_file = b.path("tests/fixtures/atomics/atomic_buildgrid.spv"),
    });
    test_mod.addOptions("build_options", wiring.build_opts);
}

/// `zig build vorbis-reference`: the engine's Vorbis decoder against stb_vorbis, decoding the same file, compared frame
/// by frame (`tools/vorbis_reference/vorbis_reference.zig`). stb_vorbis.c - public domain, Sean Barrett's - is built
/// with zig's C compiler into this test alone: a reference for the decoder's tests, never part of the engine. The
/// engine's codecs come in as a module of their own, with the math and zimrnum they import.
fn addVorbisReferenceStep(
    b: *std.Build,
    native_target: std.Build.ResolvedTarget,
    zimrmath_mod: *std.Build.Module,
    zimrnum_mod: *std.Build.Module,
) void {
    const codecs_mod: *std.Build.Module = b.createModule(.{
        .root_source_file = b.path("src/codecs.zig"),
        .target = native_target,
        .optimize = .ReleaseSafe,
    });
    codecs_mod.addImport("zm", zimrmath_mod);
    codecs_mod.addImport("zn", zimrnum_mod);
    const reference_mod: *std.Build.Module = b.createModule(.{
        .root_source_file = b.path("tools/vorbis_reference/vorbis_reference.zig"),
        .target = native_target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    reference_mod.addImport("codecs", codecs_mod);
    reference_mod.addCSourceFile(.{
        .file = b.path("tools/vorbis_reference/stb_vorbis.c"),
        .flags = &.{ "-O2", "-DSTB_VORBIS_NO_STDIO", "-DSTB_VORBIS_NO_PUSHDATA_API" },
    });
    const reference_test: *std.Build.Step.Compile = b.addTest(.{ .root_module = reference_mod });
    const reference_run: *std.Build.Step.Run = b.addRunArtifact(reference_test);
    const step: *std.Build.Step = b.step("vorbis-reference", "The Vorbis decoder against stb_vorbis, frame by frame");
    step.dependOn(&reference_run.step);
}

pub fn build(b: *std.Build) void {
    // Pre-flight: bail out if the local .zig-cache has bloated past
    // the soft cap.  The cache is content-addressed and Zig never
    // garbage-collects it, so builds can quietly grow to tens of
    // gigabytes over time and fail with cryptic "No space left on
    // device" errors mid-link.  Catching it here is the friendly
    // path - the message tells the user what to do.
    checkDiskSpace(b);
    suggestZbuild(b, "tools/zig-out/bin/zbuild");

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
    // Three explicit modes. Missing -> build aborts with a clear error.  Rationale:
    // implicit-default ReleaseSmall once shipped when callers thought
    // they were debugging (broken VS Code breakpoints, hard to spot).
    // Explicit is cheaper than confused.
    // The mode picks the optimize level per platform: the web's wasm is downloaded,
    // so its release builds are ReleaseSmall; a native program is not, so it gets
    // Zig's safety in `release` and full speed in `ship`.
    //            wasm (web)     native (windows, headless)   zimr asserts + profiler
    //   debug    Debug          Debug                        on
    //   release  ReleaseSmall   ReleaseSafe                  on
    //   ship     ReleaseSmall   ReleaseFast                  off
    // `release` keeps zimr's asserts on purpose: in ReleaseSmall, Zig's
    // built-in runtime safety (`std.debug.assert`, integer overflow,
    // unreachable, etc.) is stripped no matter what we do.  The only asserts
    // that survive a wasm `release` are the ones zimr declares via
    // `src/utils.zig` - those are re-enabled at compile time via the
    // `assert_log` build option.  `ship` is the variant that strips those too.
    // Mapping rationale:
    //   - `debug`: dev / breakpoints / DWARF.  Used by all VS Code
    //     tasks.  Bigger wasm (~1.5 MB) but full source-level
    //     debugging and ALL asserts (Zig's + zimr's).
    //   - `release`: production ship + zimr asserts still fire.  Used by
    //     `zig build publish` so the prebuilt artifact uploaded to Pages
    //     still trips our own assert macros.
    //   - `ship`: true zero-overhead ship (no asserts, profiler stripped).
    //     The lean build users get.
    // Smoke artifacts piggyback on the same mode - there's no separate
    // `-Dsmoke-optimize` knob anymore.  Smoke runs at whatever mode
    // the rest of the build is at; in practice that's always `debug`
    // because smoke is a dev tool.
    // (`Mode` is declared at file scope: `Project` declares the same option in a
    // consumer's build and forwards it here.)

    // -Dmode defaults to `debug` when omitted.  Real callers (VS Code
    // tasks, `zig build publish`) all pass -Dmode
    // explicitly; the default is for `zig build test` and hand-typing
    // during development.  No warning - debug is the right default for
    // unconfigured invocations; production callers know to pass the
    // release modes.
    const mode: Mode = b.option(
        Mode,
        "mode",
        "debug | release | ship (default: debug)",
    ) orelse .debug;
    // The platform this build's apps run on (`Platform`); the default is this machine's, when zimr has one.
    const platform: ?Platform = b.option(
        Platform,
        "platform",
        "web | windows | android (default: this machine's platform, when zimr has one)",
    ) orelse hostPlatform();
    const wasm_optimize: std.builtin.OptimizeMode = switch (mode) {
        .debug => .Debug,
        .release, .ship => .ReleaseSmall,
    };
    const native_optimize: std.builtin.OptimizeMode = switch (mode) {
        .debug => .Debug,
        .release => .ReleaseSafe,
        .ship => .ReleaseFast,
    };

    // The deprecated WebGL/GLSL path is UNPLUGGED from the build: its ~80
    // examples, the `-Dgl` flag, the GL-only native fractal steps, and the
    // zglsl tool were removed. The example files remain on disk for porting to
    // wgpu; they are simply not built. wgpu is the only buildable target.
    // (GL-retirement P3: the GL `zimr` / `zimr_mod_smoke` wasm modules are
    // gone - the docs lib was their last consumer and now documents
    // zimr.  src/zimr.zig itself is deleted in P5.)

    // Umbrella module for the WebGPU stack - re-exports every public
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
        .optimize = wasm_optimize,
        .link_libc = false,
    });

    // `shader_interface` is the typed-shader public API surface
    // (`Sampler2D`, `Attr`, `merge`, ...).  Registered as a named
    // module so iface files (`src/shaders/*_io.zig`) can
    // `@import("shader_interface")` from anywhere - same iface
    // file works inside the wgpu module, inside the codegen bootstrap
    // exes (Phase 2 of the typed-shader plan), and inside external
    // projects building against zimr.  Without this, iface files
    // would need `@import("../shader_interface.zig")` which
    // escapes the module path when an iface file is loaded as
    // the root of its own module (codegen case).
    //
    // No target set - the same module is imported by wasm exe
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
    // modules can wire it as a dep - `src/zimr.zig` does
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
        // No `.target` - math.zig is imported by modules with various
        // targets (wasm32-wasi for exes, native for host tests).  When
        // the module has no target, consumers resolve it lazily through
        // their own target.  Hardcoding wasm_target here causes a Zig
        // 0.16 compiler segfault when the native test compile pulls
        // math in transitively.
    });

    // THE ONE `kompute` MODULE. Every GPU-compute example imports THIS - it is not built per
    // example, and that is the whole point.
    //
    // `wireComputeKernels` used to call `b.createModule(root = src/kompute.zig)` afresh for each
    // example. One compute example per page, and that was invisible. Put TWO on the same page -
    // which is exactly what the launcher is - and Zig sees two distinct modules with the same
    // root file, renames the second to `kompute0`, and then the kernel source that imports
    // "kompute" straddles both:
    //
    //     escape_kernel.zig: error: file exists in modules 'kompute' and 'kompute0'
    //
    // It looked like a four_ways bug. It was not. The launcher happened to contain exactly ONE
    // compute example (fluid_sort), so ANY second one would have broken it - four_ways was
    // simply the first to try. Sharing one module fixes the class, not the instance.
    const kompute_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/kompute.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    kompute_mod.addImport("zm", zimrmath_mod);

    // zimrnum: the numerics / statistics / deep-learning library. Two imports and no more -
    // see `src/notes/zimrnum_plan.md` section 3 for why that constraint is load-bearing rather than
    // tidy: it is what keeps the library in the fast test tier and lets a `zm`-only module
    // adopt it without acquiring a GPU dependency.
    const zimrnum_mod: *Module = b.addModule("zn", .{
        .root_source_file = b.path("src/zimrnum.zig"),
    });
    zimrnum_mod.addImport("zm", zimrmath_mod);
    zimrnum_mod.addImport("kompute", kompute_mod);
    // `zrl`: reinforcement learning, built on zn (src/zimrrl.zig). It imports zm and zn; zn never imports it, so
    // the dependency only runs from reinforcement learning to the generic library. Kernel modules do not receive it.
    const zimrrl_mod: *Module = b.addModule("zrl", .{
        .root_source_file = b.path("src/zimrrl.zig"),
    });
    zimrrl_mod.addImport("zm", zimrmath_mod);
    zimrrl_mod.addImport("zn", zimrnum_mod);
    // `cli`: every tool's command line - std's parser from Zig PR 36930, vendored in `src/cli.zig`, behind zimr's
    // front door `src/command_line.zig`. No target: each tool resolves it for its own.
    const cli_mod: *Module = b.createModule(.{ .root_source_file = b.path("src/command_line.zig") });
    // shader_builtins.zig - the SPIR-V shader DSL (decorators, texture/sampler
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
    // zimrnum for the engine's own learners (`robot_gym.PpoTrainer`). It depends on `zm` and
    // `kompute` only, so this adds no cycle, and Zig analyses it only where it is used.
    zimr_mod.addImport("zn", zimrnum_mod);
    zimr_mod.addImport("zrl", zimrrl_mod);

    // Now that zimrmath_mod exists, give shader_interface the zm alias (see the
    // note at its declaration above). Every context that pulls shader_interface
    // already has zm wired alongside it, so this introduces no new graph edges
    // for consumers - it just lets shader_interface use Vec/Vec2/Vec3.
    shader_interface_mod.addImport("zm", zimrmath_mod);

    // ---- The `shader_codegen` module (`ShaderPipeline`'s types).
    // A project that depends on zimr compiles its shaders through
    // `Project` (`App.shaders`), which reuses THIS build's pipeline
    // instance - see `src/shader_codegen.zig` for why a second instance
    // cannot work. Internal zimr code accesses the same types via a
    // relative `@import("src/shader_codegen.zig")` further down in this
    // file.
    _ = b.addModule("shader_codegen", .{
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
    // assert_log - profiler gating is `mode != .ship`.
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
    // `-Dslow-tests`: also run the tests a module skips by default because a few of them cost most
    // of its run (robot_mjcf's retarget diagnostics: three tests, 23.7 of 29.5 s). A compiler bump
    // or an arc close turns it on from the command line - it used to mean editing a constant in
    // the source, and the only test of the shipped `solvePointCloud` lived behind it. Host tests
    // only: the wasm options never carry it, and readers check for it with `@hasDecl`.
    const slow_tests: bool = b.option(
        bool,
        "slow-tests",
        "Also run the slow tests skipped by default (long simulations, sweeps, learning curves)",
    ) orelse false;
    build_opts.addOption(bool, "slow_tests", slow_tests);
    // `-Dtest-report`: print the tables the robot tests measure (drift per gain, time to failure per
    // setting). Off, a passing test binary writes nothing - which matters because this build runner
    // prints any test binary's stderr even when every test passed, labelled `failed command:`, so the
    // tables made a green `zig build test` read as red. See `src/test_report.zig`.
    const test_report: bool = b.option(
        bool,
        "test-report",
        "Print the robot tests' measurement tables (otherwise a passing run is silent)",
    ) orelse false;
    build_opts.addOption(bool, "test_report", test_report);
    // `-Dparked-tests`: also run the PARKED tests - slow ones that check something real but were set aside while the
    // suite was trimmed (Oct 12). `report.parked` in `src/test_report.zig`; `grep -n "report.parked()" src` lists them.
    const parked_tests: bool = b.option(
        bool,
        "parked-tests",
        "Also run the parked tests: slow, set aside for now (with -Dslow-tests)",
    ) orelse false;
    build_opts.addOption(bool, "parked_tests", parked_tests);
    // `-Dtrain-chunk`: run the TRAINING tests - a few minutes of learning that resume from a
    // checkpoint on disk and save one when they finish. Never part of the slow suite: a test suite
    // that takes a different amount of time depending on what is lying in `train/` is not a test
    // suite. Each run is one chunk of a long job; run it again to carry on.
    const train_chunk: bool = b.option(
        bool,
        "train-chunk",
        "Run the resumable training chunks (robot_ppo_track), one chunk per invocation",
    ) orelse false;
    build_opts.addOption(bool, "train_chunk", train_chunk);
    // `-Dtest-shards=N`: run the robot family's test binary as N processes, each with every Nth test
    // (`src/test_runner.zig`). The robot family is ONE binary of ~760 tests, and Zig runs a binary's
    // tests one after another, so `zig build test` waited on a single core for all of them while the
    // rest of the build had long finished. Default: one per CPU. Run arguments, not build options -
    // changing either of these two rebuilds nothing.
    const default_test_shards: usize = std.Thread.getCpuCount() catch 1;
    const test_shards: u32 = b.option(
        u32,
        "test-shards",
        "Processes the robot family's test binary is split across (default: one per CPU)",
    ) orelse @intCast(default_test_shards);
    // `-Dtest-timing`: every fast-tier test process lists its tests of a second or more (and is silent with none).
    const test_timing: bool = b.option(
        bool,
        "test-timing",
        "List each fast-tier test process's tests of a second or more",
    ) orelse false;

    // Options for the WebGPU modules: same as build_opts but ui_backend_wgpu=true.
    const build_opts_wgpu: *Options = b.addOptions();
    build_opts_wgpu.addOption(bool, "assert_log", assert_log);
    build_opts_wgpu.addOption(bool, "profile_enabled", profile_enabled);
    build_opts_wgpu.addOption(bool, "ui_backend_wgpu", true);
    zimr_mod.addOptions("build_options", build_opts_wgpu);

    // ---- The zimr module for the native Windows host (vulkan_port_plan_v2.md, stage S2): the same source as the
    // web module, built for x86_64-windows-gnu with `host = "native"`, so `wgpu.zig` routes every GPU call to the
    // Vulkan host. The engine shaders below are wired into it as SPIR-V under the import names the web module gets
    // as WGSL, so engine code embeds "<name>.wgsl" unchanged and receives what its host loads.
    const windows_target: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-windows-gnu",
    }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triple
    const build_opts_windows: *Options = b.addOptions();
    build_opts_windows.addOption(bool, "assert_log", assert_log);
    build_opts_windows.addOption(bool, "profile_enabled", profile_enabled);
    build_opts_windows.addOption(bool, "ui_backend_wgpu", true);
    build_opts_windows.addOption([]const u8, "host", "native");
    // The numerics modules built for Windows: the engine, the apps' kernels and their zimrnum all on one `kompute`.
    const windows_numerics: NumericsModules = addNumericsModules(b, windows_target, native_optimize, zimrmath_mod);
    const zimr_windows_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = windows_target,
        .optimize = native_optimize,
        .link_libc = false,
    });
    zimr_windows_mod.addImport("shader_interface", shader_interface_mod);
    zimr_windows_mod.addImport("zm", zimrmath_mod);
    zimr_windows_mod.addImport("zn", windows_numerics.zimrnum);
    zimr_windows_mod.addImport("zrl", windows_numerics.zimrrl);
    zimr_windows_mod.addOptions("build_options", build_opts_windows);

    // ---- The zimr module for a headless run (platforms_plan.md B8): the Windows module's twin for the machine the
    // build runs on, with `host = "headless"` - no window; the Vulkan host draws into a screen of its own, on a GPU or
    // on Mesa's software driver. Linux opens the Vulkan loader with the C library's `dlopen`, so it links libc.
    const headless_target: ResolvedTarget = b.graph.host;
    const build_opts_headless: *Options = b.addOptions();
    build_opts_headless.addOption(bool, "assert_log", assert_log);
    build_opts_headless.addOption(bool, "profile_enabled", profile_enabled);
    build_opts_headless.addOption(bool, "ui_backend_wgpu", true);
    build_opts_headless.addOption([]const u8, "host", "headless");
    const headless_numerics: NumericsModules = addNumericsModules(b, headless_target, native_optimize, zimrmath_mod);
    const zimr_headless_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimr.zig"),
        .target = headless_target,
        .optimize = native_optimize,
        .link_libc = headless_target.result.os.tag != .windows,
    });
    zimr_headless_mod.addImport("shader_interface", shader_interface_mod);
    zimr_headless_mod.addImport("zm", zimrmath_mod);
    zimr_headless_mod.addImport("zn", headless_numerics.zimrnum);
    zimr_headless_mod.addImport("zrl", headless_numerics.zimrrl);
    zimr_headless_mod.addOptions("build_options", build_opts_headless);

    // ---- The engine for the systems the unwritten platform stands for (platforms_plan.md B9): Linux, macOS and
    // Android, each the Windows module's twin for its own target, with `host = "native"` - built by `platforms-check`
    // alone, which compiles the launcher for them, so that code compiling only for Windows or the browser is found the
    // day it is written. Each opens the Vulkan loader with the C library's `dlopen`, so it links libc.
    var platform_check_engines: [platform_check_targets.len]PlatformCheckEngine = undefined;
    for (platform_check_targets, &platform_check_engines) |check_target, *check_engine| {
        const check_resolved: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = check_target.triple,
        }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triples
        const check_options: *Options = b.addOptions();
        check_options.addOption(bool, "assert_log", assert_log);
        check_options.addOption(bool, "profile_enabled", profile_enabled);
        check_options.addOption(bool, "ui_backend_wgpu", true);
        check_options.addOption([]const u8, "host", "native");
        const check_numerics: NumericsModules = addNumericsModules(b, check_resolved, native_optimize, zimrmath_mod);
        const check_zimr_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/zimr.zig"),
            .target = check_resolved,
            .optimize = native_optimize,
            .link_libc = true,
        });
        check_zimr_mod.addImport("shader_interface", shader_interface_mod);
        check_zimr_mod.addImport("zm", zimrmath_mod);
        check_zimr_mod.addImport("zn", check_numerics.zimrnum);
        check_zimr_mod.addImport("zrl", check_numerics.zimrrl);
        check_zimr_mod.addOptions("build_options", check_options);
        check_engine.* = .{ .target = check_resolved, .zimr_mod = check_zimr_mod, .numerics = check_numerics };
    }

    // zimrmath.zig's assert family reads `build_options.assert_log` on its
    // host (CPU) branch. `@import("build_options")` inside zimrmath.zig
    // resolves within THIS module, so adding it here makes it available to
    // every host consumer of `zm` at once (mesh_bake, the 3D examples,
    // kompute, ...) - no per-consumer addOptions needed. The SPIR-V compile
    // uses a separate `-Mzm=` module instance with no build_options, but its
    // CPU branch is comptime-dead (is_gpu), so it never references it.
    // zm gets its OWN options instance (a distinct generated file) so it never
    // collides with an importing module's build_options. When zm is pulled into a
    // module that already has a "build_options" (e.g. the GL test_mod, which also
    // uses build_opts), Zig dedup-renames zm's import to "build_options0" - and
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
    // dir.  This is the live successor to the GL `smoke-install` above -
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

    // `zig build test` is the single inner-loop step.  It runs host
    // unit tests AND typechecks every example (via `addObject` deps
    // added in the example loop below).  Examples target wasm so they
    // can't be folded into `b.addTest`; instead each gets an
    // `addObject` step wired to `test_step`, so a syntax/type error
    // in any example surfaces here.  ~7s warm - replaces what used
    // to be a separate `zig build check` step.  The actual host-test
    // wiring (the `addTest` + `addRunArtifact` loop) lives further
    // down where it has access to the test file list.
    //
    // -- ** ONE COMMAND FOR EVERY TEST THAT IS QUICK --
    //
    // `test` runs `test-fast` too (wired below), so it is the engine half (`src/tests.zig`) AND the
    // shader-free half (zimrnum, zimrmath, the robot family) - each binary once, in parallel. What
    // it leaves out is the long end: `-Dslow-tests` adds the tests that simulate for seconds or
    // learn for minutes, and `test-all-examples` builds every wasm instead of the tier-A eight.
    const test_step: *Step = b.step(
        "test",
        "Every quick test: engine + shader-free suites + tier-A examples (-Dslow-tests for the long ones)",
    );

    // * Run only tests whose name contains this substring. Passed straight to Zig's own test
    // runner, which has always supported it - nothing was plumbing it through.
    const test_filter: ?[]const u8 = b.option(
        []const u8,
        "test-filter",
        "Run only tests whose name contains this substring",
    );

    // -- *** `zig build test-fast` - the modules that need NO SHADERS --
    //
    // `src/tests.zig` is ONE root that imports everything, so a change to `robot.zig` rebuilds
    // a binary linked against ~50 compiled shaders. Measured: `robot.zig` alone tests in 33 s
    // (118 tests) while the full suite is minutes, and robot.zig's only dependencies are `zm`
    // and `build_options`.
    //
    // * This step exists because the physics/robotics half of the engine has NOTHING to do with
    // the render half, and paying the render half's build cost to test a Jacobian is the reason
    // the suite stopped being run at all.
    const test_fast_step: *Step = b.step(
        "test-fast",
        "Unit tests for the shader-free modules: zimrnum, zimrmath, robot, physics, codecs",
    );
    // `test` is the superset. `src/tests.zig` leaves the robot family to `src/robot_tests.zig`, which
    // runs here, so without this edge `zig build test` would not run a single robot test.
    test_step.dependOn(test_fast_step);
    // (Was a custom makeFn that printed "all tests passed".  The
    // configurer/maker split removed user makeFn closures; the maker's
    // Build Summary already prints per-step success, so the printer is
    // gone.  See src/notes/zig17_migration.md B2.)

    // `zig build all-examples` aggregates every per-example install.
    // Default `zig build` (b.getInstallStep()) builds the runtime only;
    // example wasms ride along only when -Dfocus matches.  Anything that
    // truly needs every wasm (serve, dist, the gallery picker) declares
    // a dependency on this step.  We attach b.getInstallStep() as a
    // child so the static bundle and zimr.js come along too.  (API docs
    // are their own `zig build docs` step, never pulled in here.)
    const web_examples_step: *Step = gatheringStep(b, "every example for the web");
    web_examples_step.dependOn(b.getInstallStep());

    // ---- Shader pipeline.  Declared early because the examples loop below
    // uses `shader_pipeline.addShaderImport` for examples that have a
    // `<name>_fs.zig` sibling. The pipeline is pure Zig (the spv2wgsl
    // artifact, built above) - the old `tools/build.zig` sub-build that built
    // the C++ SPIR-V tools (spirv-opt/val/cross) is gone, along with the GLSL
    // path that used them. WGSL is the only target and never touches C++.
    // Walk src/, examples/, tests/ for shader source files.  Picks
    // up new ones automatically as the codebase grows.  Filter is
    // strict - only `_vs.zig` and `_fs.zig` basenames, so false
    // positives are near-zero.  ZLS shadow modules so the editor can
    // resolve `@import("zm")` inside any shader source - build
    // behaviour is unchanged (these shadows aren't depended on by any
    // exe).  Stage 10 of math-unification deleted the old
    // `shadermath` module; `zm` (the unified math.zig) is the only
    // math import shader sources ever need now.
    // ---- Pure-Zig shader tools, built by the MAIN build as artifacts.
    // Invoking these via `addArtifactArg` (see ShaderPipeline) makes
    // each a real dependency edge: edit the tool's source -> it
    // rebuilds -> its emitted-binary hash changes -> every downstream
    // shader Run re-fires -> WGSL/GLSL re-translates automatically.
    // This closes the stale-output hole that the nested `tools/
    // build.zig` + `addFileInput(path)` shape left open - a nested
    // `zig build` is a cache boundary the outer build can't see
    // across, so the path could be hashed before the sub-build
    // rewrote it.  (The C++ SPIR-V tools stay in tools/ behind the
    // path + tools_subbuild shape; they're genuinely external.)
    const host_target: ResolvedTarget = b.graph.host;

    // -- `zig build measure`, then `measure <label> <command...>` --
    //
    // Replaces `scripts/measure.sh`. Records wall time, peak RSS, cache delta and free-disk
    // delta to /tmp/measure.log, which is where every timing quoted in claude.md and the plans
    // came from - so the format is deliberately unchanged and old rows stay comparable.
    const measure_exe: *Compile = b.addExecutable(.{
        .name = "measure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/measure.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    // INSTALLED, not run through the build. This Zig's `Build` has no `b.args`, so a step
    // cannot forward trailing `--` arguments - and `measure` is useless without them. It goes
    // to `tools/zig-out/bin`, which `.zenv.sh` already puts on PATH:
    //
    //     zig build measure          once, to build it
    //     measure gate zig build gate -Dautofix=false -j1
    const measure_install: *Step.InstallArtifact = b.addInstallArtifact(measure_exe, .{
        .dest_dir = .{ .override = .{ .custom = "../tools/zig-out/bin" } },
    });
    const measure_step: *Step = b.step(
        "measure",
        "Build the timing harness into tools/zig-out/bin (then: measure <label> <command...>)",
    );
    measure_step.dependOn(&measure_install.step);

    // Host-side tool executables (pure-Zig, built by the main build as named
    // artifacts; an external consumer can `dep.artifact("c2js")` etc.). Grouped
    // into buildTools, which returns the set; destructured back to the local
    // names the rest of build() already uses.
    const tools: Tools = buildTools(b, host_target, zimrmath_mod, cli_mod);
    const spv2wgsl_tool_exe: *Compile = tools.spv2wgsl;
    const spv2wgsl_check_exe: *Compile = tools.spv2wgsl_check;
    const zimrlint_exe: *Compile = tools.lint;
    const c2js_exe: *Compile = tools.c2js;
    const serve_exe: *Compile = tools.serve;
    const cheatsheet_exe: *Compile = tools.cheatsheet;
    const buildaux_exe: *Compile = tools.buildaux;
    const mesh_bake_exe: *Compile = tools.mesh_bake;

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

    // robot-bench: the section 4g speed acceptance measurement, and the source of the
    // numbers readme.html quotes.  It has to be a build step, not a file with a
    // `main` nobody can reach: a benchmark that takes a hand-rolled `build-exe`
    // with a stubbed build_options to run is a number nobody can check, and
    // readme.html quotes it.  ReleaseFast because the thing being measured is
    // the engine at the speed it ships, and the cases assert their own premise
    // (case 4 fails the step if the Go1 is not actually holding its pose), so a
    // red exit here means the measurement was nonsense rather than merely slow.
    // `zig build robot-bench`.
    const robot_bench_exe: *Compile = b.addExecutable(.{
        .name = "robot_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/robot_bench.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    robot_bench_exe.root_module.addImport("zm", zimrmath_mod);
    robot_bench_exe.root_module.addOptions("build_options", build_opts_wgpu);
    const robot_bench_run: *Run = b.addRunArtifact(robot_bench_exe);
    const robot_bench_step: *Step = b.step(
        "robot-bench",
        "Measure robot.zig step cost on four models (native, ReleaseFast)",
    );
    robot_bench_step.dependOn(&robot_bench_run.step);

    // clip-bake: the tracking clips retargeted, filtered, windowed and lifted ONCE, into the
    // compact binaries the training pages embed (`examples/getup_train/*.zclip`). Every file is
    // read back and compared with the clip it came from before the tool reports it written.
    // `zig build clip-bake` - rerun it whenever the retarget, the filter or the lift changes.
    const clip_bake_exe: *Compile = b.addExecutable(.{
        .name = "clip_bake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/robot_clip_bake.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    clip_bake_exe.root_module.addImport("zm", zimrmath_mod);
    clip_bake_exe.root_module.addOptions("build_options", build_opts_wgpu);
    const clip_bake_run: *Run = b.addRunArtifact(clip_bake_exe);
    clip_bake_run.has_side_effects = true;
    const clip_bake_step: *Step = b.step("clip-bake", "Bake the tracking clips into the pages' compact binaries");
    clip_bake_step.dependOn(&clip_bake_run.step);

    // st-bench (plan B1): SuperTrack's learning curve on Geno's 10-second dance, deterministic, on the CPU - the rig
    // every remaining recipe decision is measured on. Rooted in `src/` like robot-bench and clip-bake, because a root
    // under `tools/` cannot reach the robot files. TWO builds of the one file (Simon's option C): `st_bench`
    // ReleaseFast for long runs, `st_bench_safe` ReleaseSafe - 1.7x the time, every index checked - to clear a
    // configuration first. The rows are bitwise identical between them, which is what makes the Fast one checkable
    // (`st_bench --compare=safe.csv,fast.csv`). INSTALLED like `measure`, since a step cannot forward arguments:
    //     zig build st-bench        then        tools/zig-out/bin/st_bench --minutes=10 --out=/tmp/curve.csv
    const st_bench_step: *Step = b.step(
        "st-bench",
        "Build SuperTrack's learning-curve bench (st_bench, st_bench_safe) into tools/zig-out/bin",
    );
    const StBenchBuild = struct { name: []const u8, optimize: std.builtin.OptimizeMode };
    const st_bench_builds = [2]StBenchBuild{
        .{ .name = "st_bench", .optimize = .ReleaseFast },
        .{ .name = "st_bench_safe", .optimize = .ReleaseSafe },
    };
    for (st_bench_builds) |bench_build| {
        const exe: *Compile = b.addExecutable(.{
            .name = bench_build.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/robot_st_bench.zig"),
                .target = host_target,
                .optimize = bench_build.optimize,
            }),
        });
        exe.root_module.addImport("zm", zimrmath_mod);
        exe.root_module.addImport("zn", zimrnum_mod);
        exe.root_module.addImport("zrl", zimrrl_mod);
        exe.root_module.addImport("cli", cli_mod);
        exe.root_module.addOptions("build_options", build_opts);
        const install: *Step.InstallArtifact = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "../tools/zig-out/bin" } },
        });
        st_bench_step.dependOn(&install.step);
    }

    // shadowmap-sw-verify: the NATIVE gate for the shadow-map side-by-side's
    // comptime corner.  Compiling this exe bakes `scene.bakeCorner` at comptime
    // (the compile-time-budget gate); running it re-renders the same function
    // at runtime, byte-compares the two, sanity-checks the images, and dumps
    // corner_lit.png + corner_shadowmap.png for eyeball verification.  The
    // bunny proxy comes from mesh_bake's OBJ path (grid 10 ~ 693 tris).
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
        // NOTE (resolved): Zig 0.17.0-dev.956-early-1245 had an LLVM-backend
        // SEGV (rc=139, no Zig panic) compiling this native exe in any optimized
        // mode; the workaround forced the self-hosted x86 backend. As of the
        // current 0.17.0-dev.1245 toolchain the regression is gone - BOTH
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
    cel_proxy_bake.addArg("14"); // finer than the shadow corner - bands need surface
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
    // ReleaseSafe: it rasterises two large images through zimr's software renderer, which is real work. (It was
    // once OOM-killed at 3.85 GB in either mode - the layout had grown 15,000 px wide; fixed Sep 28, see the tool.)
    const dag_png_exe: *Compile = b.addExecutable(.{
        .name = "dag_png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dag_png.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    dag_png_exe.root_module.addImport("cli", cli_mod);
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
    // Every graphics shader the pipeline translates, collected as it is added, for the `corpus` step. Only zimr's
    // own build checks the corpus, so a project depending on zimr collects nothing.
    const wgsl_corpus: *WgslCorpus = b.allocator.create(WgslCorpus) catch @panic("OOM");
    wgsl_corpus.* = WgslCorpus.init(b);
    if (b.pkg_hash.len == 0) {
        shader_pipeline.wgsl_corpus = wgsl_corpus;
    }

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
    // there still embed them - placeholders; dies in P5).  The engine source
    // (`src/rlgl.zig`, `src/render.zig`) does `@embedFile("<name>.glsl")`
    // in place of inline-GLSL string constants.  Examples are free
    // to reuse the engine shaders via the same `@embedFile` form -
    // an example that wants the default VS just writes
    // `@embedFile("default_vs.glsl")`.  Unused imports cost nothing
    // (the bytes only enter the wasm via an explicit `@embedFile`).
    var engine_shaders: ArrayList(EngineShader) = .empty;
    // Every engine shader's SPIR-V, by name: what the native module embeds, and what `vk-shader-probe` checks.
    const EngineSpirv = struct { name: []const u8, spirv: LazyPath };
    var engine_spirv: ArrayList(EngineSpirv) = .empty;
    // Old-style 3D-pipeline shaders that haven't migrated to the
    // IoT pattern yet.  They access `shader_externs.X` at module
    // scope and call `shader_externs.setup()` - both broken by
    // the native-import codegen surgery (externs moved into
    // `_Spirv` namespace).  Skipped from the build until migrated;
    // none are on the wgpu critical path (Renderer2D uses only
    // default_shapes_vs/fs which already use IoT).  Re-enable
    // by migrating to IoT or by prefixing extern accesses with
    // `shader_externs._Spirv.`.  Tracked: turn 4 of the gpu-foundations plan.
    // (GL-retirement P5: the old WebGL 3D shader sources - default/
    // shadow/skybox/unlit - are deleted; nothing embeds their .glsl
    // names anymore.  The gravestone below survives only because LIVE
    // shader entries still carry a `<name>.glsl` placeholder name that
    // consumer loops wire unconditionally; collapsing engine_shaders to
    // wgsl-primary naming is queued in P6.)
    const glsl_gravestone: LazyPath = b.path("src/shaders/_deleted_glsl_placeholder.glsl");
    for (zls_shader_paths) |path| {
        if (!startsWith(u8, path, "src/shaders/")) {
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
        // file -> addShader skips Stage 0 entirely; pre-typed-shader
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
        // fails the build - opt-out per-shader via `wgsl_strict =
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
            // `src/notes/webgpu-migration-plan.md` section 3 Phase C.
            //
            // zimr_mod consumes these via
            // `@embedFile("default_shapes_vs.wgsl")` (Renderer2D).
            const wgsl_import_name: []const u8 = b.fmt("{s}.wgsl", .{sh_name});
            zimr_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = wgsl_path });
            zimr_windows_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = out.spv });
            zimr_headless_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = out.spv });
            for (&platform_check_engines) |*check_engine| {
                check_engine.zimr_mod.addAnonymousImport(wgsl_import_name, .{ .root_source_file = out.spv });
            }
            engine_spirv.append(b.allocator, .{ .name = sh_name, .spirv = out.spv }) catch @panic("OOM");
            captured_wgsl_path = wgsl_path;
            captured_wgsl_name = wgsl_import_name;
        }
        // The pbr AND default_shapes shader SOURCES are part of the
        // zimr module (re-exported as `z.pbr_shaders.vs` / `.fs`
        // and `z.default_shapes.vs` / `.fs`) so the software half of
        // side-by-sides runs the same `shaderMain` the GPU pipeline
        // compiled to WGSL above.  Their named-module dep - the
        // generated `<name>_externs` (IoT/Out/installSpirvEntry) - gets
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
            zimr_windows_mod.addImport(b.fmt("{s}_externs", .{sh_name}), externs_mod);
            zimr_headless_mod.addImport(b.fmt("{s}_externs", .{sh_name}), externs_mod);
            for (&platform_check_engines) |*check_engine| {
                check_engine.zimr_mod.addImport(b.fmt("{s}_externs", .{sh_name}), externs_mod);
            }
        }
        engine_shaders.append(b.allocator, .{
            .path = glsl_gravestone,
            .name = import_name,
            .wgsl_path = captured_wgsl_path,
            .wgsl_name = captured_wgsl_name,
            .externs_path = out.externs,
            .source_path = b.path(path),
            .sh_name = sh_name,
        }) catch @panic("OOM");
    }

    // ---- native-input-test: the rules turning Windows' input messages into the engine's input calls
    // (src/native_input.zig), tested on the build machine - nothing in them calls Windows.
    {
        const native_input_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/native_input.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        native_input_mod.addImport("zm", zimrmath_mod);
        native_input_mod.addImport("shader_interface", shader_interface_mod);
        const native_input_tests: *Step.Compile = b.addTest(.{ .root_module = native_input_mod });
        const native_input_step: *Step = b.step("native-input-test", "Run the native input translation's tests");
        native_input_step.dependOn(&b.addRunArtifact(native_input_tests).step);
    }

    // ---- platform-contract-test: the contract between the engine and a platform (src/platform/contract.zig) - its
    // check finds a missing request and a wrong type, and the template platform keeps it.
    {
        const platform_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        platform_mod.addImport("zm", zimrmath_mod);
        platform_mod.addImport("shader_interface", shader_interface_mod);
        // src/host.zig reads the host's kind from `build_options`: a host test runs on no platform (`none`).
        addToolHostOptions(b, platform_mod);
        const platform_tests: *Step.Compile = b.addTest(.{ .root_module = platform_mod });
        const platform_step: *Step = b.step("platform-contract-test", "Run the platform contract's tests");
        platform_step.dependOn(&b.addRunArtifact(platform_tests).step);
    }

    // ---- vk-gen-test: the Vulkan binding generator's tests (tools/vk_gen.zig), on excerpts of the registry.
    {
        const gen_codecs_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/codecs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        gen_codecs_mod.addImport("zm", zimrmath_mod);
        addToolHostOptions(b, gen_codecs_mod);
        const gen_mod: *Module = b.createModule(.{
            .root_source_file = b.path("tools/vk_gen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        gen_mod.addImport("codecs", gen_codecs_mod);
        const gen_tests: *Step.Compile = b.addTest(.{ .root_module = gen_mod });
        const gen_test_step: *Step = b.step("vk-gen-test", "Run the Vulkan binding generator's tests");
        gen_test_step.dependOn(&b.addRunArtifact(gen_tests).step);

        // ---- vk-gen: rewrites src/vk.zig's generated part from the registry; the build itself never needs it.
        const vulkan_registry: ?[]const u8 = b.option(
            []const u8,
            "vulkan-registry",
            "The Vulkan registry, vk.xml (Vulkan-Headers' registry/vk.xml), for vk-gen",
        );
        const vk_gen_step: *Step = b.step(
            "vk-gen",
            "Regenerate src/vk.zig from the Vulkan registry (needs -Dvulkan-registry=<path to vk.xml>)",
        );
        if (vulkan_registry) |registry_path| {
            const gen_exe: *Step.Compile = b.addExecutable(.{ .name = "vk_gen", .root_module = gen_mod });
            const generate: *Step.Run = b.addRunArtifact(gen_exe);
            generate.setCwd(b.path("."));
            generate.addArg(registry_path);
            generate.addArg("src/vk.zig");
            generate.has_side_effects = true;
            vk_gen_step.dependOn(&generate.step);
        } else {
            const message: []const u8 = "vk-gen needs the Vulkan registry: -Dvulkan-registry=<path to vk.xml>";
            vk_gen_step.dependOn(&b.addFail(message).step);
        }
    }

    // ---- vk-shader-probe: every engine shader, legalized as the native host loads it, created as a Vulkan shader
    // module with the Khronos validation layer validating its SPIR-V (vulkan_port_plan_v2.md 5.5, the probe's GPU
    // half). It runs on the build machine, with whatever Vulkan driver is there: a GPU, or Mesa's software driver
    // (lavapipe) on a machine without one. It needs the validation layer (the Vulkan SDK, or the
    // `vulkan-validationlayers` package).
    {
        const probe_mod: *Module = b.createModule(.{
            .root_source_file = b.path("tools/vk_shader_probe.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            // The Vulkan loader is opened with the C library's `dlopen`.
            .link_libc = true,
        });
        probe_mod.addAnonymousImport("vk", .{ .root_source_file = b.path("src/vk.zig") });
        probe_mod.addAnonymousImport("spv_vulkan", .{ .root_source_file = b.path("src/spv_vulkan.zig") });
        const probe_exe: *Step.Compile = b.addExecutable(.{ .name = "vk_shader_probe", .root_module = probe_mod });
        const probe_run: *Step.Run = b.addRunArtifact(probe_exe);
        for (engine_spirv.items) |shader| {
            probe_run.addPrefixedFileArg(b.fmt("{s}=", .{shader.name}), shader.spirv);
        }
        const probe_step: *Step = b.step(
            "vk-shader-probe",
            "Create every engine shader as a Vulkan module under the validation layer (needs a Vulkan driver)",
        );
        probe_step.dependOn(&probe_run.step);
    }

    // native_wgsl_check: the check every native program passes before it is installed - no WGSL inside, since the
    // native host runs SPIR-V only (`tools/native_wgsl_check.zig`; `addWindowsApp` runs it on each Windows program).
    const native_wgsl_check_exe: *Compile = b.addExecutable(.{
        .name = "native_wgsl_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/native_wgsl_check.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    native_wgsl_check_exe.root_module.addImport("cli", cli_mod);
    // pdb_void_workaround: not a check but a Zig compiler bug's workaround, which every Windows program's PDB goes
    // through so LLDB sees the program's `void` functions (`tools/pdb_void_workaround.zig`). It fails the build once
    // Zig is fixed; then delete the tool and every `pdb_void_workaround` here.
    const pdb_void_workaround_exe: *Compile = b.addExecutable(.{
        .name = "pdb_void_workaround",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pdb_void_workaround.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    pdb_void_workaround_exe.root_module.addImport("cli", cli_mod);
    // bridge_import_check: the check every web page's wasm passes - every function it imports is one the bridge
    // registers (`tools/bridge_import_check.zig`), so a missing one fails the build rather than the page's load.
    const bridge_import_check_exe: *Compile = b.addExecutable(.{
        .name = "bridge_import_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bridge_import_check.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    bridge_import_check_exe.root_module.addImport("cli", cli_mod);

    // The headless trainer's Windows install (`geno-trainer-windows`, below). The training lab starts runs with the
    // trainer beside its own executable, so the lab's Windows build installs it too.
    var geno_trainer_windows_install: ?*Step = null;
    // ---- vk-host-test: the Vulkan host headless, driven through `wgpu.zig` as the engine drives it, with the
    // validation layer on; plus `native_os.zig`'s tests. Built for the build machine and run on its Vulkan driver - a
    // GPU, or Mesa's software driver (lavapipe) on a machine without one. Needs the validation layer.
    {
        const host_test_inputs: VulkanHostTestInputs = .{
            .shader_pipeline = &shader_pipeline,
            .zimrmath_mod = zimrmath_mod,
            .shader_interface_mod = shader_interface_mod,
            .assert_log = assert_log,
            .profile_enabled = profile_enabled,
        };
        const host_test_exe: *Compile = addVulkanHostTest(b, b.graph.host, host_test_inputs);
        const host_test_run: *Step.Run = b.addRunArtifact(host_test_exe);
        const native_os_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/native_os.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        });
        const native_os_tests: *Step.Compile = b.addTest(.{ .root_module = native_os_mod });
        const host_test_step: *Step = b.step(
            "vk-host-test",
            "Run the Vulkan host headless under the validation layer (needs a Vulkan driver and the layer)",
        );
        host_test_step.dependOn(&host_test_run.step);
        host_test_step.dependOn(&b.addRunArtifact(native_os_tests).step);
        // The same test for Windows, to run on a Windows machine's GPU: real parallel dispatches, real atomics, a real
        // driver's precision - what lavapipe, which runs a command buffer's dispatches one after another, cannot show.
        const windows_host_test_exe: *Compile = addVulkanHostTest(b, windows_target, host_test_inputs);
        const windows_host_test_install: *InstallArtifact = installWindowsProgram(
            b,
            windows_host_test_exe,
            pdb_void_workaround_exe,
        );
        const windows_host_test_check: *Step.Run = addNativeWgslCheck(b, native_wgsl_check_exe, windows_host_test_exe);
        windows_host_test_install.step.dependOn(&windows_host_test_check.step);
        const windows_host_test_step: *Step = b.step(
            "vk-host-test-windows",
            "Build zig-out/windows/vk_host_test.exe, the Vulkan host test, to run on a Windows machine's GPU",
        );
        windows_host_test_step.dependOn(&windows_host_test_install.step);

        // ---- geno-trainer: DReCon trained by PPO on Geno, headless, in a run folder (`tools/geno_trainer.zig`):
        // installed beside the headless programs for the build machine, and beside the Windows programs for Windows.
        //     zig build geno-trainer        then        zig-out/headless/bin/geno_trainer --run=runs/night1
        const trainer_exe: *Compile = addGenoTrainer(b, b.graph.host, host_test_inputs, cli_mod);
        const trainer_install: *InstallArtifact = b.addInstallArtifact(trainer_exe, .{
            .dest_dir = .{ .override = .{ .custom = "headless/bin" } },
        });
        const trainer_step: *Step = b.step(
            "geno-trainer",
            "Build zig-out/headless/bin/geno_trainer, the headless trainer of a run folder",
        );
        trainer_step.dependOn(&trainer_install.step);
        const windows_trainer_exe: *Compile = addGenoTrainer(b, windows_target, host_test_inputs, cli_mod);
        const windows_trainer_install: *InstallArtifact = installWindowsProgram(
            b,
            windows_trainer_exe,
            pdb_void_workaround_exe,
        );
        const windows_trainer_step: *Step = b.step(
            "geno-trainer-windows",
            "Build zig-out/windows/geno_trainer.exe, the headless trainer, for a Windows machine's GPU",
        );
        windows_trainer_step.dependOn(&windows_trainer_install.step);
        geno_trainer_windows_install = &windows_trainer_install.step;
    }

    // ---- The example build context, shared with projects that depend on zimr.
    // Pre-filter the engine shaders that emitted WGSL into (name, path) pairs so
    // the `wireEngineShaders` configure helper can embed them. (engine_shaders is
    // fully populated by here.)
    var web_engine_embeds: ArrayList(EngineShaderEmbed) = .empty;
    for (engine_shaders.items) |s| {
        if (s.wgsl_path) |wgsl_path| {
            web_engine_embeds.append(b.allocator, .{ .name = s.wgsl_name.?, .path = wgsl_path }) catch @panic("oom");
        }
    }
    // The same shaders, under the same import names, as SPIR-V: what the native host's apps embed.
    var native_engine_embeds: ArrayList(EngineShaderEmbed) = .empty;
    for (engine_spirv.items) |shader| {
        const import_name: []const u8 = b.fmt("{s}.wgsl", .{shader.name});
        native_engine_embeds.append(b.allocator, .{ .name = import_name, .path = shader.spirv }) catch @panic("oom");
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
        .optimize = wasm_optimize,
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
    var shader_cache = StringHashMap(ShaderDep).init(b.allocator);

    const wgpu_app_ctx: AppContext = .{
        .b = b,
        .wgpu_smoke_install = wgpu_smoke_install,
        .smoke_focus = smoke_focus,
        .target = wasm_target,
        .optimize = wasm_optimize,
        .zimr_mod = zimr_mod,
        .zimrmath_mod = zimrmath_mod,
        .zimrnum_mod = zimrnum_mod,
        .zimrrl_mod = zimrrl_mod,
        .kompute_mod = kompute_mod,
        .shader_interface_mod = shader_interface_mod,
        .buildaux_exe = buildaux_exe,
        .c2js_exe = c2js_exe,
        .shader_pipeline = &shader_pipeline,
        .engine_shader_embeds = web_engine_embeds.items,
        .mesh_bake_exe = mesh_bake_exe,
        .common_mod = shared_common_mod,
        .roboto_mod = shared_roboto_mod,
        .atkinson_mod = shared_atkinson_mod,
        .ogg_mod = shared_ogg_mod,
        .wav_mod = shared_wav_mod,
        .shader_cache = &shader_cache,
        .build_opts_wgpu = build_opts_wgpu,
        .build_opts_zm = build_opts_zm,
        .bridge_import_check = bridge_import_check_exe,
    };
    // ---- The Windows apps' context: the web context's twin, for the native host. It changes only what the target
    // decides: the target, the engine and the modules importing it (`example_common`, `kompute`) as Windows instances,
    // shaders embedded as SPIR-V, and a shader cache of its own (its modules hold other bytes).
    const windows_common_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/example_common/example_common.zig"),
        .target = windows_target,
        .optimize = native_optimize,
    });
    windows_common_mod.addImport("zimr", zimr_windows_mod);
    windows_common_mod.addImport("zm", zimrmath_mod);
    var windows_shader_cache: StringHashMap(ShaderDep) = .init(b.allocator);
    var windows_app_ctx: AppContext = wgpu_app_ctx;
    windows_app_ctx.target = windows_target;
    windows_app_ctx.optimize = native_optimize;
    windows_app_ctx.zimr_mod = zimr_windows_mod;
    windows_app_ctx.common_mod = windows_common_mod;
    windows_app_ctx.kompute_mod = windows_numerics.kompute;
    windows_app_ctx.zimrnum_mod = windows_numerics.zimrnum;
    windows_app_ctx.zimrrl_mod = windows_numerics.zimrrl;
    windows_app_ctx.shader_cache = &windows_shader_cache;
    windows_app_ctx.vulkan_shaders = true;
    windows_app_ctx.native_wgsl_check = native_wgsl_check_exe;
    windows_app_ctx.pdb_void_workaround = pdb_void_workaround_exe;
    windows_app_ctx.engine_shader_embeds = native_engine_embeds.items;
    // A project's build.zig (see `Project`) runs after this function has returned,
    // and reaches the engine through this handle - so it is published ABOVE the
    // phase split, the last point a dependency's build() gets to.
    publishEngine(
        b,
        wgpu_app_ctx,
        windows_app_ctx,
        serve_exe,
        tools.zbuild,
        tools.editor_configs,
        tools.android_apk,
    );

    // ========================================================================
    // PHASE SPLIT - everything above is what a CONSUMER needs: the exposed
    // modules (zimr/zimrmath/shader_interface/shader_codegen), the pure-Zig tool
    // artifacts, the shader pipeline, the engine-shader WGSL embedded into
    // `zimr_mod`, and the example build context `Project` reuses. Everything
    // BELOW is dev/demo machinery - the 137-example
    // gallery, bridge demos, smoke tests, the c2js corpus/diff gates, the
    // cheatsheet, dist, and serve. A project depending on zimr must not pay to
    // construct (or risk root-relative path failures from) any of it, so bail
    // out here when zimr is a dependency (`pkg_hash` is non-empty for deps,
    // empty for the root project).
    // ========================================================================
    if (b.pkg_hash.len != 0) {
        return;
    }

    // ---- The headless apps' context: the Windows context's twin for the build's own machine (`zimr_headless_mod`).
    const headless_common_mod: *Module = b.createModule(.{
        .root_source_file = b.path("examples/example_common/example_common.zig"),
        .target = headless_target,
        .optimize = native_optimize,
    });
    headless_common_mod.addImport("zimr", zimr_headless_mod);
    headless_common_mod.addImport("zm", zimrmath_mod);
    var headless_shader_cache: StringHashMap(ShaderDep) = .init(b.allocator);
    var headless_app_ctx: AppContext = windows_app_ctx;
    headless_app_ctx.target = headless_target;
    headless_app_ctx.zimr_mod = zimr_headless_mod;
    headless_app_ctx.common_mod = headless_common_mod;
    headless_app_ctx.kompute_mod = headless_numerics.kompute;
    headless_app_ctx.zimrnum_mod = headless_numerics.zimrnum;
    headless_app_ctx.zimrrl_mod = headless_numerics.zimrrl;
    headless_app_ctx.shader_cache = &headless_shader_cache;

    // Build a map: example-name -> list of shader file paths owned
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
    // editing this build.zig - each compiled artifact is importable
    // from the example's CPU side as `@embedFile("<basename>.glsl")`.
    //
    // Sibling `<basename>_io.zig` files alongside the shader file
    // are auto-discovered and wired as `--dep io` so example-side
    // shaders can use the typed API end-to-end without build.zig
    // edits.

    // Copy static site content into zig-out/web.  (GL-retirement P5:
    // the GL gallery picker index.html + per-example host.html + the
    // WebGL runtime bundle are gone - the wgpu examples each carry
    // their own page, and standalones bake src/bridge.zig.)
    const docfmt_exe: *Compile = tools.docfmt;
    const readme_step: *Step = b.step("readme", "Generate zig-out/web/readme.html (shared style + highlighting)");
    const doc_pages_step: *Step = b.step("doc-pages", "Generate every styled doc page into zig-out/web");
    // The gate is fed the SAME list the loop below installs, one addFileArg per
    // page, so a page cannot be published without being checked.
    const doc_gate_run: *Run = b.addRunArtifact(tools.doc_gate);
    doc_gate_run.step.name = "doc-gate (one stylesheet, no script, no network, no id twice, every page reached)";
    const doc_gate_step: *Step = b.step("doc-gate", "Check every published page against the shared doc style");
    doc_gate_step.dependOn(&doc_gate_run.step);

    // Non-HTML static content: copied verbatim.
    inline for (.{
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

    // EVERY published doc page goes through `docfmt` (tools/docfmt.zig) rather
    // than being copied: it injects THE shared stylesheet at the page's
    // `<!--docfmt:style-->` marker and highlights every
    // <pre><code class="zig|language-zig|wgsl"> block with std.zig.Tokenizer (or
    // the small WGSL lexer in the same file).  All of it happens at build time,
    // so each served page stays pure HTML+CSS: no runtime JS, no webfont fetch,
    // and one constant to edit when a colour changes.  See
    // `src/notes/docs_style_plan.md`.
    //
    // Ordering note: the pages are standalone under three different directories
    // in the repo and land flat here as `<name>.html`, which keeps readme.html's
    // links relative and avoids shipping the whole notes tree.
    //
    // `robots.html` is checked against `src/robot.zig` by `zig build doc-sync`
    // on every build, so what ships here cannot quote drifted source.
    // `zimrnum-tutorial.html`'s reference table is checked against
    // `src/zimrnum.zig` by a test in that file (it `@embedFile`s the page), so
    // what ships cannot name a declaration the library no longer has.
    // The API cheatsheet is the one page GENERATED rather than written: tools/cheatsheet.zig reads the public API
    // from src/ on every build, so the page cannot fall behind the code it describes - the committed copy it
    // replaced had, by 70 KB. `zig build cheatsheet` builds just this page.
    const cheatsheet_step: *Step = b.step("cheatsheet", "Generate the API cheatsheet page into zig-out/web");
    const cheatsheet_run: *Run = b.addRunArtifact(cheatsheet_exe);
    cheatsheet_run.addArg("src");
    const cheatsheet_html: LazyPath = cheatsheet_run.addOutputFileArg("cheatsheet.html");
    // It reads every src/*.zig, which the build cannot see - a cached run would replay yesterday's page after a
    // source change. So it always runs; docfmt after it is still a cache hit whenever the page came out the same.
    cheatsheet_run.has_side_effects = true;

    // Every published page, written or generated: styled by docfmt, checked by the doc gate, installed to web/.
    const DocPage = struct { source: LazyPath, name: []const u8 };
    const doc_pages = [_]DocPage{
        // The examples GALLERY landing page (manifest-driven: a filterable list
        // on the left, the selected web/<name>/ running in a frame beside it;
        // index.html#<name> links straight to one).
        .{ .source = b.path("src/web/index.html"), .name = "index.html" },
        // The project landing page, with the launcher running live in an iframe.
        .{ .source = b.path("src/web/readme.html"), .name = "readme.html" },
        .{ .source = cheatsheet_html, .name = "cheatsheet.html" },
        // The from-scratch graphics tutorial readme.html links to.
        .{ .source = b.path("src/web/tutorial.html"), .name = "tutorial.html" },
        .{ .source = b.path("src/notes/tutorials/robots.html"), .name = "robots.html" },
        .{ .source = b.path("src/notes/tutorials/zimrrl-tutorial.html"), .name = "zimrrl-tutorial.html" },
        .{ .source = b.path("src/notes/tutorials/mujoco-tutorial.html"), .name = "mujoco-tutorial.html" },
        .{ .source = b.path("src/notes/tutorials/gpu-compute-tutorial.html"), .name = "gpu-compute-tutorial.html" },
        .{ .source = b.path("src/notes/tutorials/rtt-tutorial.html"), .name = "rtt-tutorial.html" },
        .{
            .source = b.path("src/notes/tutorials/shader_authoring_tutorial.html"),
            .name = "shader-authoring-tutorial.html",
        },
        .{ .source = b.path("src/notes/tutorials/wgpu-ports-tutorial.html"), .name = "wgpu-ports-tutorial.html" },
        .{ .source = b.path("src/notes/tutorials/zimrnum-tutorial.html"), .name = "zimrnum-tutorial.html" },
        // Robot motion capture: capture -> retarget -> servo -> balance -> learned tracking.
        .{ .source = b.path("src/notes/tutorials/robot-mocap-tutorial.html"), .name = "robot-mocap-tutorial.html" },
        // Graphics backends: how one engine reaches WebGPU, Vulkan and Metal.
        .{ .source = b.path("src/notes/tutorials/backends-tutorial.html"), .name = "backends-tutorial.html" },
        // Sound: samples, the mixer, its two sides, each platform's output, latency, instruments.
        .{ .source = b.path("src/notes/tutorials/sound_tutorial.html"), .name = "sound_tutorial.html" },
        // goban: a Go board's points, the disjoint-set forest that keeps its groups, and the rules on top of it.
        .{ .source = b.path("src/notes/tutorials/goban_tutorial.html"), .name = "goban_tutorial.html" },
        // The per-file atlas, generated as HTML by `zig build files-html`.
        .{ .source = b.path("src/notes/files.html"), .name = "files.html" },
    };
    for (doc_pages) |page| {
        doc_gate_run.addPrefixedFileArg(b.fmt("{s}=", .{page.name}), page.source);
        const fmt_run: *Run = b.addRunArtifact(docfmt_exe);
        fmt_run.setStdIn(.{ .lazy_path = page.source });
        const page_out: LazyPath = fmt_run.captureStdOut(.{});
        const inst: *InstallFile = b.addInstallFileWithDir(page_out, web_install, page.name);
        b.getInstallStep().dependOn(&inst.step);
        const inst_smoke: *InstallFile = b.addInstallFileWithDir(page_out, smoke_install, page.name);
        smoke_install_step.dependOn(&inst_smoke.step);
        doc_pages_step.dependOn(&inst.step);
        if (eql(u8, page.name, "readme.html")) {
            // Standalone step so you can regenerate just the landing page
            // without triggering the full install graph (shader pipeline, lint,
            // every example).
            readme_step.dependOn(&inst.step);
        }
        if (eql(u8, page.name, "cheatsheet.html")) {
            cheatsheet_step.dependOn(&inst.step);
        }
    }

    // (readme.html is produced by the docfmt loop above, along with every other
    // doc page; `zig build readme` still regenerates just that one.)

    // Shared runtime JS: ONE web/zimr.js (the transpiled bridge) that every
    // served example page references via <script src="../zimr.js"> (--external-js
    // in bridgePage), so the ~500KB runtime is fetched + cached ONCE instead of
    // inlined into every page. Built exactly like bridgePage but WITHOUT --html
    // - bare JS to stdout. The standalone twin still inlines (file://-portable).
    {
        const zimr_js: LazyPath = runtimeJs(b, c2js_exe);
        const zimr_js_install: *InstallFile = b.addInstallFileWithDir(zimr_js, web_install, "zimr.js");
        b.getInstallStep().dependOn(&zimr_js_install.step);
        const zimr_js_smoke: *InstallFile = b.addInstallFileWithDir(zimr_js, smoke_install, "zimr.js");
        smoke_install_step.dependOn(&zimr_js_smoke.step);
    }

    // ---- WebGPU demo (Phase 1 of the wgpu migration; see notes/MIGRATION_PROGRESS.md).
    // Standalone target - does NOT touch the existing GL example flow
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
        .optimize = wasm_optimize,
        .link_libc = false,
    });
    wgpu_bringup_mod.addImport("zimr", zimr_mod);
    wgpu_bringup_mod.addImport("zm", zimrmath_mod);
    wgpu_bringup_mod.addImport("shader_interface", shader_interface_mod);

    // Wire ENGINE WGSL imports onto wgpu_bringup_mod so the demo can
    // `@embedFile("default_shapes_vs.wgsl")` and feed it as the VS
    // half of a `loadShader` call.  Same pattern as `zimr_mod`'s
    // wiring (line ~660 above), but late-bound - the engine-emission
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
        // it explicitly here - same approach as wgpu-mandelbrot-split below.
        const mandel_out: shader_codegen.ShaderPipeline.ShaderOutput = shader_pipeline.addShaderEx(
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
        // schema files - wired as modules, not compiled as shaders.
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
            const sh_out: shader_codegen.ShaderPipeline.ShaderOutput =
                shader_pipeline.addShaderEx(b.path(pair.source_path), .{
                    .shader_io = b.path(pair.io_path),
                    .shader_basename = pair.sh_name,
                    .emit_wgsl = true,
                    .wgsl_strict = true, // these are bedrock - no // ERROR: tolerated
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
    const wgpu_page: LazyPath = bridgePage(b, c2js_exe, wgpu_bringup_exe, "zimr - WebGPU - 2D demo", false, null, true);
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

    // ---- bridge-hello: ZIG_BRIDGE_PLAN Phase 1 - the bridge monolith ----
    // src/bridge.zig -> C (wasm32-freestanding) -> tools c2js -> one HTML page.
    // No wasm module, no hand-written JS/HTML anywhere in this chain.
    {
        const to_c: *Run = b.addSystemCommand(&.{
            b.graph.zig_exe,       "build-obj",
            "-ofmt=c",             "-target",
            "wasm32-freestanding", "-OReleaseSmall",
        });
        addBridgeSource(b, to_c);
        const bridge_c: LazyPath = to_c.addPrefixedOutputFileArg("-femit-bin=", "bridge.c");
        const to_html: *Run = b.addRunArtifact(c2js_exe);
        to_html.setStdIn(.{ .lazy_path = bridge_c });
        to_html.addArgs(&.{ "--html", "--title", "zimr bridge phase-1" });
        const hello_html: LazyPath = to_html.captureStdOut(.{});
        const inst: *std.Build.Step.InstallFile = b.addInstallFile(hello_html, "bridge-hello/bridge_hello.html");
        const step: *std.Build.Step = b.step("bridge-hello", "ZIG_BRIDGE Phase 1: the Zig bridge monolith as a page");
        step.dependOn(&inst.step);
    }

    // ---- bridge-slice: Phase 2 - the app owns the page (D9-D11) ----
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
        addBridgeSource(b, to_c);
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

    // ---- bridge-classic-probe: Phase 3a - the classic zimr contract ----
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
        addBridgeSource(b, to_c);
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
    // Same one-call helper as the cube - a second consumer proving the
    // standalone generalizes across wgpu demos (any future demo is one call).
    const bringup_standalone_step: *Step = b.step(
        "standalone",
        "Build the 2D wgpu demo as a single self-contained HTML (no Python)",
    );
    bringup_standalone_step.dependOn(addWgpuStandalone(
        b,
        c2js_exe,
        wgpu_bringup_exe,
        "wgpu_bringup.html",
        "zimr · WebGPU · 2D demo",
        null,
        true,
    ));

    // ---- wgpu-shapes: the first 2D drawing demo on WebGPU (N5a gate) ----
    // Drives the WgpuGl adapter (f.gl) via z.beginDrawing/drawRectangle/
    // drawCircle - the same free-function shape as a GL example. Proves WgpuGl
    // renders real 2D geometry on-screen (retires N4's "visual pending").
    // ---- wgpu example apps: one table, one builder ----------------------
    // Every servable wgpu demo is a row in `wgpu_apps`, built through
    // `wgpu_app_ctx` (constructed above the phase split, because projects share
    // it). `buildAppModule` + `finishWgpuApp` unify
    // the old addWgpuApp / addWgpuShaderApp split: an empty `.shaders` is just
    // a no-op loop. Bespoke examples that need build-time wiring (asset baking,
    // engine-shader embeds) set a `.configure` hook instead of growing this
    // struct - see configureHelmetSw. Examples that own their GPU frame (cube,
    // lambert, pbr, gltf) don't fit the runner contract and stay manual above.
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
        .{ .name = "input_actions", .title = "zimr - WebGPU - input actions" },
        .{ .name = "ui_widgets_data_types", .title = "zimr - WebGPU - input data types" },
        .{ .name = "text_field", .title = "zimr - WebGPU - text field" },
        .{ .name = "ui_code_editor", .title = "zimr - WebGPU - code editor" },
        .{ .name = "ui_log_viewer", .title = "zimr - WebGPU - log viewer" },
        .{ .name = "ui_data_grid_phone", .title = "zimr - data grid phone" },
        .{ .name = "ui_imgui_extras", .title = "zimr - UI imgui extras" },
        .{ .name = "ui_input_callbacks", .title = "zimr - ui_input_callbacks (Phase A4)" },
        .{ .name = "ui_text_editing", .title = "zimr - UI text editing" },
        .{ .name = "monitors", .title = "zimr - monitors" },
        .{ .name = "input_gamepad", .title = "zimr - gamepads" },
        .{ .name = "audio_mixer", .title = "zimr - the mixer" },
        .{ .name = "audio_keyboard", .title = "zimr - keyboard" },
        .{ .name = "audio_scale_star", .title = "zimr - the major scale in thirds" },
        .{ .name = "audio_scale_star_hands", .title = "zimr - the scale star, two hands" },
        .{ .name = "ui_shortcuts", .title = "zimr - ui shortcuts (B2 capstone)" },
        .{ .name = "ui_mouse_drag", .title = "zimr - ui mouse drag (B1 capstone)" },
        .{ .name = "ui_custom_rendering", .title = "zimr - UI custom rendering" },
        .{ .name = "ui_plot", .title = "zimr - interactive plot" },
        .{ .name = "plot_demo", .title = "zimr - plot demo" },
        .{ .name = "plot3d_demo", .title = "zimr - 3D plot demo" },
        .{ .name = "mocap_viewer", .title = "zimr - mocap viewer" },
        .{
            .name = "geno_dance",
            .title = "zimr - geno + mocap",
            .configure = configureGenoDance,
        },
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
        .{ .name = "comptime_mandelbrot", .title = "zimr - WebGPU - comptime Mandelbrot" },
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
        .{ .name = "profiler_flamegraph", .title = "zimr - profiler flamegraph" },
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
        .{
            .name = "shaders_lightmap_rendering",
            .title = "zimr - shaders - lightmap rendering",
            .shaders = &.{ "lightmap_vs", "lightmap_fs" },
        },
        .{ .name = "dynamic_mesh", .title = "zimr - WebGPU - dynamic mesh" },
        .{ .name = "zimrphysics_demo", .title = "zimr - WebGPU - zimrphysics demo" },
        .{ .name = "zimrphysics2d_demo", .title = "zimr - WebGPU - zimrphysics2d demo" },
        .{ .name = "physics_sidebyside", .title = "zimr - WebGPU - 2D | 3D physics side by side" },
        .{ .name = "robot_pendulum", .title = "zimr - WebGPU - robot: double pendulum" },
        .{ .name = "robot_demo", .title = "zimr - WebGPU - robot demo" },
        .{ .name = "robot_sidebyside", .title = "zimr - WebGPU - maximal | generalized" },
        .{ .name = "robot_contact", .title = "zimr - WebGPU - robot contact" },
        .{ .name = "robot_3d", .title = "zimr - WebGPU - KUKA iiwa from URDF" },
        .{ .name = "quadruped", .title = "zimr - WebGPU - Unitree Go1 from MJCF" },
        .{ .name = "gripper", .title = "zimr - WebGPU - arm and coupled gripper" },
        .{ .name = "cartpole", .title = "zimr - WebGPU - a policy learning to balance" },
        .{ .name = "mpc_cartpole", .title = "zimr - WebGPU - MPC planning in real time" },
        .{ .name = "mpc_quadruped", .title = "zimr - WebGPU - quadruped trunk MPC" },
        .{ .name = "three_leg", .title = "zimr - WebGPU - standing on three legs" },
        .{ .name = "balance_flywheel", .title = "zimr - WebGPU - why a robot windmills its arms" },
        .{ .name = "crane", .title = "zimr - WebGPU - carrying a swinging load" },
        .{ .name = "rocket", .title = "zimr - WebGPU - landing an engine you cannot switch off" },
        .{ .name = "chain_ik", .title = "zimr - WebGPU - ten joints for a two-joint job" },
        .{ .name = "catch", .title = "zimr - WebGPU - catching, not swatting" },
        .{ .name = "tracking", .title = "zimr - WebGPU - preview beats feedback" },
        .{ .name = "friction_slope", .title = "zimr - WebGPU - does friction obey Coulomb?" },
        .{ .name = "humanoid", .title = "zimr - WebGPU - humanoid from MJCF" },
        .{ .name = "ragdoll_compare", .title = "zimr - WebGPU - ragdolls: reduced vs maximal" },
        .{ .name = "rl_humanoid", .title = "zimr - WebGPU - PPO learning to walk, live" },
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
        // thread, CPU worker, GPU. It is the only example that wants BOTH opt-ins at once -
        // `compute_kernels` gives it .cpu and .gpu, `job_kernels` gives it .worker - and
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
        .{ .name = "dance_track", .title = "zimr - dance_track" },
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
        .{
            .name = "bone_socket",
            .title = "zimr - WebGPU - bone socket (rigged character)",
            .configure = configureBoneSocket,
        },
        .{
            .name = "models_animation_blend_custom",
            .title = "zimr - WebGPU - animation blend (per-bone)",
            .configure = configureAnimBlend,
        },
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
        .{ .name = "textures_gif_player", .title = "zimr - WebGPU - textures gif player" },
        .{ .name = "text_sprite_fonts", .title = "zimr - WebGPU - text sprite fonts" },
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
        .{
            .name = "pipeline_msaa",
            .title = "zimr - WebGPU - pipeline MSAA",
            .shaders = &.{ "pipeline_msaa_vs", "pipeline_msaa_fs" },
        },
        .{ .name = "pipeline_sampler", .title = "zimr - WebGPU - pipeline sampler" },
        .{ .name = "texture_views", .title = "zimr - texture views" },
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
        .{ .name = "tic_tac_toe", .title = "zimr - WebGPU - tic tac toe" },
        .{ .name = "langton_ant", .title = "zimr - WebGPU - langton ant" },
        // The computer opponent's search runs as a job (examples/goban/kernels.zig): on a worker in a page, a thread
        // natively, inline where neither can be had.
        .{ .name = "goban", .title = "zimr - goban", .job_kernels = true },
        // goban on 8 x 8 against the computer, from a scattered start, with no interface: goban's code, another app.
        .{
            .name = "goban_outposts",
            .title = "zimr - goban outposts",
            .job_kernels = true,
            .kernel_deps = &.{"goban"},
            .app_deps = &.{"goban"},
        },
        // goban's kill problems against the computer, with Undo and Next: goban's code, another app.
        .{
            .name = "goban_problems",
            .title = "zimr - goban problems",
            .job_kernels = true,
            .kernel_deps = &.{"goban"},
            .app_deps = &.{"goban"},
        },
        // Fights, life puzzles and kill puzzles in turn, abandoned down and solved up: goban's code, another app.
        .{
            .name = "go_puzzles_hero",
            .title = "zimr - go puzzles hero",
            .job_kernels = true,
            .kernel_deps = &.{"goban"},
            .app_deps = &.{"goban"},
            .fullscreen_button = false,
            // The ID Android Studio's first build had, so the APK installs over it and keeps the player's progress.
            .android_app_id = "com.bofstudios.gopuzzleshero",
            .android_label = "Go Puzzles Hero",
            // goban's own black stone on goban's own board.
            .android_icon = .{
                .foreground = "examples/goban/black_stone.png",
                .background = .{ .picture = "examples/goban/wood.png" },
            },
        },
        .{ .name = "snake", .title = "zimr - WebGPU - snake" },
        .{ .name = "fps_playground", .title = "zimr - WebGPU - fps playground" },
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
        .{ .name = "shapes_gallery", .title = "zimr - shapes gallery" },
        .{ .name = "mesh_builder", .title = "zimr - mesh builder" },
        .{ .name = "platonic_solids", .title = "zimr - platonic solids" },
        .{ .name = "icosphere_demo", .title = "zimr - icosphere subdivision" },
        .{ .name = "rock_demo", .title = "zimr - procedural rocks" },
        .{ .name = "state_persistence", .title = "zimr - state persistence" },
        .{ .name = "net_ws_smoke", .title = "zimr - p2p signaling (ws)" },
        .{ .name = "net_rtc_smoke", .title = "zimr - p2p webrtc" },
        .{ .name = "net_cursors", .title = "zimr - shared cursors" },
        .{ .name = "hello_world", .title = "zimr - WebGPU - hello world" },
        .{ .name = "life", .title = "zimr - WebGPU - life" },
        .{ .name = "colors_palette", .title = "zimr - WebGPU - colors" },
        .{ .name = "easings_ball", .title = "zimr - WebGPU - easings" },
        .{ .name = "input_keys", .title = "zimr - WebGPU - input keys" },
        .{ .name = "input_mouse_wheel", .title = "zimr - WebGPU - mouse wheel" },
        .{ .name = "input_mouse", .title = "zimr - WebGPU - input mouse" },
        .{ .name = "input_cursor_shapes", .title = "zimr - WebGPU - input cursor shapes" },
        .{ .name = "input_pointer_lock", .title = "zimr - WebGPU - input pointer lock" },
        .{ .name = "window_requests", .title = "zimr - WebGPU - window requests" },
        .{ .name = "easings_box", .title = "zimr - WebGPU - easings box" },
        .{ .name = "easings_rectangles", .title = "zimr - WebGPU - easings rects" },
        .{ .name = "collision_area", .title = "zimr - WebGPU - collision" },
        .{ .name = "ellipse_collision", .title = "zimr - WebGPU - ellipse collision" },
        .{ .name = "ball_physics", .title = "zimr - WebGPU - ball physics" },
        .{ .name = "bouncing_ball", .title = "zimr - WebGPU - bouncing ball" },
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
        // frame; `.own_frame` routes finishWgpuApp (and natively `nativeAppExe`)
        // to root the exe at the demo instead of the shared runner. Same
        // declarative glue otherwise.
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
            .configure = wireEngineShaders,
        },
        .{
            .name = "depth_rendering",
            .title = "zimr - WebGPU - depth rendering",
            .own_frame = true,
            .configure = wireEngineShaders,
        },
        .{
            .name = "shadowmap",
            .title = "zimr - WebGPU - shadow map",
            .configure = wireEngineShaders,
        },
        .{
            .name = "cel_shading",
            .title = "zimr - WebGPU - cel shading + inverted-hull ink",
            .configure = configureCelShading,
        },
        .{
            .name = "depth_writing",
            .title = "zimr - WebGPU - fragment depth writing",
            .configure = wireEngineShaders,
        },
        .{
            .name = "box_collisions",
            .title = "zimr - WebGPU - box collisions (drag the player)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "cubicmap",
            .title = "zimr - WebGPU - cubicmap maze",
            .configure = wireEngineShaders,
        },
        .{
            .name = "first_person_maze",
            .title = "zimr - WebGPU - first person maze",
            .configure = wireEngineShaders,
        },
        .{
            .name = "heightmap",
            .title = "zimr - WebGPU - heightmap terrain",
            .configure = wireEngineShaders,
        },
        .{
            .name = "point_rendering",
            .title = "zimr - WebGPU - point rendering (1k to 1M points)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "mesh_picking",
            .title = "zimr - WebGPU - mesh picking (tap to pick)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "fog_rendering",
            .title = "zimr - WebGPU - distance fog (shared gbuffer_vs)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "deferred_render",
            .title = "zimr - WebGPU - deferred rendering (MRT G-buffer)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "shader_effects",
            .title = "zimr - WebGPU - 2D shader effects gallery",
            .configure = wireEngineShaders,
        },
        .{
            .name = "shaders_shapes_textures",
            .title = "zimr - shaders - shapes + textures (BeginShaderMode)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "text_font_sdf",
            .title = "zimr - WebGPU - text font SDF",
            .configure = wireEngineShaders,
        },
        .{
            .name = "shaders_multi_texture",
            .title = "zimr - shaders - multi-texture (mask + divider)",
            .configure = wireEngineShaders,
        },
        .{
            .name = "hybrid_render",
            .title = "zimr - WebGPU - hybrid raster + raymarch (shared depth)",
            .configure = wireEngineShaders,
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
            .name = "shaders_normalmap_rendering",
            .title = "zimr - shaders - normal map rendering",
            .configure = configureNormalmap,
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
            .configure = wireEngineShaders,
        },
        .{
            .name = "obj_simple",
            .title = "zimr - WebGPU - OBJ simple",
            .own_frame = true,
            .configure = wireEngineShaders,
        },
        .{
            .name = "obj_bunny",
            .title = "zimr - WebGPU - OBJ bunny",
            .own_frame = true,
            .configure = wireEngineShaders,
        },
        .{
            .name = "damaged_helmet",
            .title = "zimr - WebGPU - damaged helmet",
            .own_frame = true,
            .configure = wireEngineShaders,
        },
        // Compute apps: regular examples that opt into GPU compute via
        // `.compute_kernels`. No separate list or builder - adding compute to any
        // example above is just adding this one field.
        .{
            // PPO learning a cartpole hold with its update on the GPU (zn_mlp), beside MPC
            // planning on the CPU - the same robot.zig cartpole on both sides.
            .name = "cartpole_duel",
            .title = "zimr - cartpole: PPO on the GPU vs MPC on the CPU",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &.{
                        "dense_fwd",
                        "act_bwd",
                        "dense_bwd_x",
                        "dense_bwd_w",
                        "mse_bwd",
                        "mse_value",
                        "adam",
                        "ppo_mean_grad",
                        "ppo_logstd_grad",
                        // The page's pipeline table is built from the module's whole kernel
                        // list, so every kernel is registered, SAC's included.
                        "squash_fwd",
                        "squash_logp",
                        "sac_target",
                        "min_route",
                        "squash_bwd",
                        "squash_logstd_grad",
                        "alpha_grad",
                        "polyak",
                        "cp_wm_input",
                        "cp_wm_input_bwd",
                        "cp_force",
                        "cp_force_bwd",
                        "cp_step",
                        "cp_step_bwd",
                        "cp_track_bwd",
                        "add_block",
                        "lat_advance",
                        "lat_take",
                        "lat_gather",
                        "lat_act",
                        "lat_act_bwd",
                        "st_policy_fwd",
                        "st_policy_bwd",
                        "st_world_fwd",
                        "st_world_bwd",
                        "st_reduce",
                    },
                },
            },
        },
        .{
            // Geno's own skeleton moved by the captures, with the collision shapes fitted to its
            // skinned mesh riding on its bones - the new robot's body, judged by eye before it is
            // ever simulated.
            .name = "geno_fit",
            .title = "zimr - Geno's body, on the captures",
        },
        .{
            // Geno as a physical robot: its model from the fixture, on a floor, pulled through a copied
            // clip by the tracking task's own servo - no learning, just how far a spring alone gets.
            .name = "geno_track",
            .title = "zimr - Geno, servoing a copied clip",
        },
        .{
            // The get-up reference on the robot, frame by frame: no physics, no learning - just what
            // the tracking pages ask a character to follow, and what its feet are doing while they do.
            .name = "getup_frames",
            .title = "zimr - the get-up reference, frame by frame",
        },
        .{
            // SuperTrack on the device: the characters stepped on the CPU, the ring, the world model
            // and the policy all resident on the GPU. Its kernels are the kit's - the three dense
            // stages with their backward pairs, the loss, Adam, and the latent model's own five.
            .name = "track_train",
            .title = "zimr - SuperTrack, learned on this device",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &.{
                        "dense_fwd",
                        "act_bwd",
                        "dense_bwd_x",
                        "dense_bwd_w",
                        "mse_bwd",
                        "mse_value",
                        "adam",
                        "ppo_mean_grad",
                        "ppo_logstd_grad",
                        // The page's pipeline table is built from the module's whole kernel
                        // list, so every kernel is registered, SAC's included.
                        "squash_fwd",
                        "squash_logp",
                        "sac_target",
                        "min_route",
                        "squash_bwd",
                        "squash_logstd_grad",
                        "alpha_grad",
                        "polyak",
                        "cp_wm_input",
                        "cp_wm_input_bwd",
                        "cp_force",
                        "cp_force_bwd",
                        "cp_step",
                        "cp_step_bwd",
                        "cp_track_bwd",
                        "add_block",
                        "lat_advance",
                        "lat_take",
                        "lat_gather",
                        "lat_act",
                        "lat_act_bwd",
                        "st_policy_fwd",
                        "st_policy_bwd",
                        "st_world_fwd",
                        "st_world_bwd",
                        "st_reduce",
                    },
                    .wants_zimrnum = true,
                },
            },
        },
        .{
            // SuperTrack on the device: the characters stepped on the CPU, the ring, the world model
            // and the policy all resident on the GPU. Its kernels are the kit's - the three dense
            // stages with their backward pairs, the loss, Adam, and the latent model's own five.
            .name = "geno_train",
            .title = "zimr - SuperTrack on Geno, learned on this device",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &.{
                        "dense_fwd",
                        "act_bwd",
                        "dense_bwd_x",
                        "dense_bwd_w",
                        "mse_bwd",
                        "mse_value",
                        "adam",
                        "ppo_mean_grad",
                        "ppo_logstd_grad",
                        // The page's pipeline table is built from the module's whole kernel
                        // list, so every kernel is registered, SAC's included.
                        "squash_fwd",
                        "squash_logp",
                        "sac_target",
                        "min_route",
                        "squash_bwd",
                        "squash_logstd_grad",
                        "alpha_grad",
                        "polyak",
                        "cp_wm_input",
                        "cp_wm_input_bwd",
                        "cp_force",
                        "cp_force_bwd",
                        "cp_step",
                        "cp_step_bwd",
                        "cp_track_bwd",
                        "add_block",
                        "lat_advance",
                        "lat_take",
                        "lat_gather",
                        "lat_act",
                        "lat_act_bwd",
                        "st_policy_fwd",
                        "st_policy_bwd",
                        "st_world_fwd",
                        "st_world_bwd",
                        "st_reduce",
                    },
                    .wants_zimrnum = true,
                },
            },
        },
        .{
            // PPO learning a cartpole hold with its update on the GPU (zn_mlp), beside MPC
            // planning on the CPU - the same robot.zig cartpole on both sides.
            .name = "getup_train",
            .title = "zimr - getting up, learned on this device",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &.{
                        "dense_fwd",
                        "act_bwd",
                        "dense_bwd_x",
                        "dense_bwd_w",
                        "mse_bwd",
                        "mse_value",
                        "adam",
                        "ppo_mean_grad",
                        "ppo_logstd_grad",
                        // The page's pipeline table is built from the module's whole kernel
                        // list, so every kernel is registered, SAC's included.
                        "squash_fwd",
                        "squash_logp",
                        "sac_target",
                        "min_route",
                        "squash_bwd",
                        "squash_logstd_grad",
                        "alpha_grad",
                        "polyak",
                        "cp_wm_input",
                        "cp_wm_input_bwd",
                        "cp_force",
                        "cp_force_bwd",
                        "cp_step",
                        "cp_step_bwd",
                        "cp_track_bwd",
                        "add_block",
                        "lat_advance",
                        "lat_take",
                        "lat_gather",
                        "lat_act",
                        "lat_act_bwd",
                        "st_policy_fwd",
                        "st_policy_bwd",
                        "st_world_fwd",
                        "st_world_bwd",
                        "st_reduce",
                    },
                },
            },
        },
        .{
            // PPO learning a cartpole hold with its update on the GPU (zn_mlp), beside MPC
            // planning on the CPU - the same robot.zig cartpole on both sides.
            .name = "geno_ppo",
            .title = "zimr - PPO on Geno, learned on this device",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &zn_mlp_entries,
                },
            },
        },
        .{
            // The training lab: a run folder's network shown on Geno (examples/geno_lab). The same kernels as
            // geno_ppo's, and its dance clip.
            .name = "geno_lab",
            .title = "zimr - the training lab",
            .compute_kernels = &.{
                .{
                    .basename = "zn_mlp",
                    .source_path = "src/gpu/zn_mlp.zig",
                    .entries = &zn_mlp_entries,
                },
            },
            .configure = configureGenoLab,
        },
        .{
            // The XOR network trained on the GPU and the CPU in lockstep, one step per frame. The
            // whole step is eight dispatches over one buffer set; only the loss comes back. See
            // src/notes/zimrnum_plan.md stage C.
            .name = "zimrnum_train",
            .title = "zimr - zimrnum train",
            .compute_kernels = &.{
                .{
                    .basename = "zn_train",
                    .source_path = "src/gpu/zn_train.zig",
                    .entries = &.{
                        "fwd_hidden",
                        "fwd_out",
                        "loss_grad",
                        "loss_value",
                        "bwd_w2",
                        "bwd_h",
                        "bwd_w1",
                        "step",
                    },
                },
            },
        },
        .{
            // The zimrnum GPU spike: one elementwise kernel, checked in-page against the CPU
            // implementation of the same operation. See src/notes/zimrnum_plan.md stage 2.5.
            .name = "zimrnum_field",
            .title = "zimr - zimrnum field",
            .compute_kernels = &.{
                .{
                    .basename = "zn_binary",
                    .source_path = "src/gpu/zn_binary.zig",
                    // `squash_correction` calls `zn.squashCorrection` rather than restating it.
                    .wants_zimrnum = true,
                    // * One entry per line: `zig fmt` column-aligns a list whose items share a line, and
                    // that realignment broke an append anchor repeatedly during the port. The
                    // kernel files' own `kernels` lists are formatted the same way for the same
                    // reason.
                    .entries = &.{
                        "squash_correction",
                        "polyak_follow",
                        "adam_step_warm",
                        "add",
                        "mul",
                        "sub",
                        "div",
                        "relu_grad",
                        "sgd_step",
                        "bcast_add",
                        "sigmoid_grad",
                        "tanh_grad",
                        "minimum",
                        "maximum",
                        "atan2f",
                        "hypotf",
                        "greater",
                        "less",
                        "equal",
                        "lerpf",
                        "mse_loss",
                        "mae_loss",
                        "huber_loss",
                        "bce_loss",
                        "conv2d_same",
                        "not_equal",
                        "greater_equal",
                        "less_equal",
                        "where_pick",
                        "sgd_momentum",
                        "adam_step",
                        "mesh_grid_x",
                        "mesh_grid_y",
                        "repeat_each",
                        "slice_columns",
                        "concat_columns",
                    },
                },
                .{
                    .basename = "zrl_binary",
                    .source_path = "src/gpu/zrl_binary.zig",
                    // Its kernels call zimrrl's functions (`zrl.cartpoleStep`, ...) rather than restating them.
                    .wants_zimrrl = true,
                    .entries = &.{
                        "cartpole_step",
                        "cartpole_pole",
                        "ppo_clip",
                        "disc_reward",
                    },
                },
                .{
                    .basename = "zn_matmul",
                    .source_path = "src/gpu/zn_matmul.zig",
                    .entries = &.{
                        "matmul",
                        "matmul_tiled",
                        "matmul_bt",
                        "transpose",
                    },
                },
                .{
                    .basename = "zn_unary",
                    .source_path = "src/gpu/zn_unary.zig",
                    .entries = &.{
                        "nan_direct",
                        "relu",
                        "sigmoid",
                        "tanhf",
                        "gelu",
                        "expf",
                        "absf",
                        "neg",
                        "scale",
                        "softmax_rows",
                        "layernorm_rows",
                        "sum_axis0",
                        "sum_all",
                        "sum_all_tiled",
                        "mean_all",
                        "max_all",
                        "sqrtf",
                        "logf",
                        "floorf",
                        "ceilf",
                        "signf",
                        "square",
                        "reciprocal",
                        "truncf",
                        "roundf",
                        "sinf",
                        "cosf",
                        "clampf",
                        "softplus",
                        "silu",
                        "leaky_relu",
                        "elu",
                        "min_all",
                        "max_axis0",
                        "min_axis0",
                        "mean_axis0",
                        "argmax_axis0",
                        "cumsum_rows",
                        "variance_axis0",
                        "max_pool2d",
                        "avg_pool2d",
                        "log2f",
                        "log10f",
                        "expm1",
                        "log1p",
                        "cbrtf",
                        "sinhf",
                        "coshf",
                        "asinhf",
                        "atanhf",
                        "rsqrtf",
                        "signz",
                        "expm1z",
                        "log1pz",
                        "reluz",
                        "log_sum_exp_rows",
                        "sin_turns",
                        "cos_turns",
                        "exp2f",
                        "affine_f",
                        "count_nonzero",
                        "all_nonzero",
                        "any_nonzero",
                        "prod_all",
                        "diff_forward",
                    },
                },
            },
        },
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
    // `zig build example-sources`: every example's web/<name>/source.json - what the
    // gallery's code pane shows - without compiling a single wasm. Each example's own
    // step (and so `all-examples`, `serve` and `dist`) installs its file as well.
    const example_sources_step: *Step = b.step(
        "example-sources",
        "Install every example's highlighted source (web/<name>/source.json) for the gallery's code pane",
    );
    var app_mods = StringHashMap(*Module).init(b.allocator);
    // Each app's build per platform, by app name: filled as the apps are built, read by `registerAppSteps`' block
    // below, which gives every app its one step. Natively, the program's install - its step, and the program its
    // `run-<app>` step runs.
    var web_builds: StringHashMap(*Step) = .init(b.allocator);
    var windows_builds: StringHashMap(*Step.InstallArtifact) = .init(b.allocator);
    // Under `-Dplatform=android`, each web app's Android build, by app name: its page in an APK. Nothing of it exists
    // under another platform, so no other build looks for the Android SDK.
    var android_builds: StringHashMap(AndroidBuild) = .init(b.allocator);
    for (wgpu_apps) |wgpu_app| {
        const m: *Module = wgpu_app_ctx.buildAppModule(wgpu_app);
        const source_install: *InstallFile = installExampleSource(
            b,
            tools.example_source,
            wgpu_app.name,
            wgpu_app.shaders,
            wgpu_app.app_deps,
            wgpu_app.kernel_deps,
        );
        example_sources_step.dependOn(&source_install.step);
        // `job_kernels` is the whole opt-in: the example's kernels.zig ALSO becomes a
        // separate, freestanding, zero-import wasm for the Web Workers, inlined into the
        // page beside the app's own. Nothing else about the example moves.
        const kernel_wasm: ?LazyPath = if (wgpu_app.job_kernels)
            buildJobKernels(
                b,
                wgpu_app.name,
                b.path(b.fmt("examples/{s}/kernels.zig", .{wgpu_app.name})),
                wgpu_app.kernel_deps,
                wasm_optimize,
                build_opts_wgpu,
                build_opts_zm,
            )
        else
            null;
        const app_exe: *Compile = finishWgpuApp(
            b,
            c2js_exe,
            wgpu_smoke_install,
            smoke_focus,
            wasm_target,
            wasm_optimize,
            zimr_mod,
            zimrmath_mod,
            shader_interface_mod,
            buildaux_exe,
            m,
            wgpu_app.name,
            wgpu_app.title,
            wgpu_app.own_frame,
            kernel_wasm,
            wgpu_app.fullscreen_button,
            &source_install.step,
            &web_builds,
            bridge_import_check_exe,
        );
        if (platform == .android) {
            android_builds.put(wgpu_app.name, addAndroidBuild(b, b, tools.android_apk, wgpu_app.name, .{
                .page = bridgePage(b, c2js_exe, app_exe, wgpu_app.title, false, kernel_wasm, false),
                .app_id = wgpu_app.android_app_id orelse defaultAndroidAppId(b, wgpu_app.name),
                .label = wgpu_app.android_label orelse wgpu_app.title,
                .icon = wgpu_app.android_icon,
            })) catch @panic("oom");
        }
        app_mods.put(wgpu_app.name, m) catch @panic("oom");
    }

    // ---- Headless runs (platforms_plan.md B8): `zig build <name>-headless` runs an example without a window, on the
    // machine's Vulkan driver - a GPU, or Mesa's software one - with the validation layer on, and installs it as
    // zig-out/headless/bin/<name>, to run again directly. `-Dscript` names the script it runs (`native_input.Command`);
    // frames it captures without a path go to zig-out/headless/<name>/. Every example the native host runs.
    const script_path: ?[]const u8 = b.option([]const u8, "script", "Headless runs: the script to run");
    // ---- `gallery-shots`: a thumbnail of every example, for the native gallery to show beside its description and
    // the web gallery beside its name - each example's headless program run for two seconds and its frame saved
    // shrunk twice (`addGalleryShot`): into zig-out/gallery_shots/, where the native gallery looks, from beside its own
    // executable, at ../gallery_shots/, and smaller into zig-out/web/shots/, which the web gallery's list loads.
    // `-Dshots=a,b,c` takes only those examples; the step builds every example's headless program otherwise.
    const gallery_shots_step: *Step = b.step(
        "gallery-shots",
        "Save a thumbnail of every example for the native and web galleries (-Dshots=a,b,c for only those)",
    );
    const shot_names_option: ?[]const u8 = b.option([]const u8, "shots", "gallery-shots: only these examples");
    for (wgpu_apps) |wgpu_app| {
        if (windowsPendingReason(wgpu_app.name) != null) {
            continue;
        }
        const headless_exe: *Compile = addHeadlessRun(b, headless_app_ctx, wgpu_app, script_path);
        const is_shot: bool = if (shot_names_option) |shot_names| listed: {
            var listed_names = std.mem.tokenizeScalar(u8, shot_names, ',');
            while (listed_names.next()) |listed_name| {
                if (eql(u8, listed_name, wgpu_app.name)) {
                    break :listed true;
                }
            }
            break :listed false;
        } else true;
        if (is_shot) {
            gallery_shots_step.dependOn(&addGalleryShot(b, headless_exe, wgpu_app.name).step);
        }
    }

    // ---- audio-scale-star-check: the scale star run headless with its script - the seven notes, then the seven
    // chords - and the sound it saved checked against its expectations, window by window: the pitch classes that sound
    // and the loudness (`tools/sound_capture_check.zig`). Installing the program first makes zig-out/headless/, where
    // the script saves the sound. On the machine's Vulkan driver, as every headless run.
    {
        const scale_star_app: App = appNamed(&wgpu_apps, "audio_scale_star");
        const scale_star_module: *Module = headless_app_ctx.buildAppModule(scale_star_app);
        const scale_star_exe: *Compile = nativeAppExe(headless_app_ctx, scale_star_module, "audio_scale_star", false);
        const scale_star_install: *Step.InstallArtifact = b.addInstallArtifact(scale_star_exe, .{
            .dest_dir = .{ .override = .{ .custom = "headless/bin" } },
        });
        const run_scale_star: *Run = b.addRunArtifact(scale_star_exe);
        run_scale_star.has_side_effects = true;
        run_scale_star.setCwd(b.path("."));
        run_scale_star.setEnvironmentVariable("ZIMR_SCRIPT", "examples/audio_scale_star/check.script");
        run_scale_star.setEnvironmentVariable("ZIMR_CAPTURE_DIR", "zig-out/headless/audio_scale_star");
        run_scale_star.step.dependOn(&scale_star_install.step);
        const check_zm_module: *Module = b.createModule(.{
            .root_source_file = b.path("src/zimrmath.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        });
        check_zm_module.addOptions("build_options", build_opts_zm);
        const sound_check_exe: *Compile = b.addExecutable(.{
            .name = "sound_capture_check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/sound_capture_check.zig"),
                .target = host_target,
                .optimize = .ReleaseSafe,
            }),
        });
        sound_check_exe.root_module.addImport("cli", cli_mod);
        sound_check_exe.root_module.addImport("zm", check_zm_module);
        const run_sound_check: *Run = b.addRunArtifact(sound_check_exe);
        run_sound_check.has_side_effects = true;
        run_sound_check.setCwd(b.path("."));
        run_sound_check.addArg("zig-out/headless/audio_scale_star_check.wav");
        run_sound_check.addArg("examples/audio_scale_star/check.expect");
        run_sound_check.step.dependOn(&run_scale_star.step);
        const scale_star_check_step: *Step = b.step(
            "audio-scale-star-check",
            "Run the scale star headless with its script and check the sound it saved (tools/sound_capture_check.zig)",
        );
        scale_star_check_step.dependOn(&run_sound_check.step);
    }

    // ---- Every example for Windows, and the gallery that starts them: each its own executable, as the web serves
    // each its own page, built through the Windows context so each app is wired exactly as on the web. Recorded in
    // `windows_builds` for the apps' steps; an example the native host cannot run yet is on `windows_pending`, with
    // the reason its step and the gallery show.
    {
        for (wgpu_apps) |wgpu_app| {
            if (windowsPendingReason(wgpu_app.name) != null) {
                continue;
            }
            const example_mod: *Module = windows_app_ctx.buildAppModule(wgpu_app);
            const example_install: *Step.InstallArtifact = addWindowsApp(
                windows_app_ctx,
                example_mod,
                wgpu_app.name,
                wgpu_app.own_frame,
            );
            windows_builds.put(wgpu_app.name, example_install) catch @panic("oom");
        }
        var pending_names: [windows_pending.len][]const u8 = undefined;
        var pending_reasons: [windows_pending.len][]const u8 = undefined;
        for (windows_pending, &pending_names, &pending_reasons) |pending, *name, *reason| {
            name.* = pending.name;
            reason.* = pending.reason;
        }
        const gallery_options: *Options = b.addOptions();
        gallery_options.addOption([]const []const u8, "pending_names", &pending_names);
        gallery_options.addOption([]const []const u8, "pending_reasons", &pending_reasons);
        const gallery_mod: *Module = windows_app_ctx.buildUserModShared("zimr_gallery");
        gallery_mod.addOptions("gallery_options", gallery_options);
        gallery_mod.addAnonymousImport("examples_manifest", .{ .root_source_file = b.path("src/web/manifest.json") });
        const gallery_install: *Step.InstallArtifact = addWindowsApp(
            windows_app_ctx,
            gallery_mod,
            "zimr_gallery",
            false,
        );
        windows_builds.put("zimr_gallery", gallery_install) catch @panic("oom");
        // The gallery headless (`zimr-gallery-headless`): its list and panel drawn into a captured screen, for a
        // script to look at.
        const gallery_headless_mod: *Module = headless_app_ctx.buildUserModShared("zimr_gallery");
        gallery_headless_mod.addOptions("gallery_options", gallery_options);
        gallery_headless_mod.addAnonymousImport("examples_manifest", .{
            .root_source_file = b.path("src/web/manifest.json"),
        });
        _ = addHeadlessRunOf(b, headless_app_ctx, gallery_headless_mod, "zimr_gallery", false, script_path);
    }
    // The launcher's examples, one name each; `examples/launcher` imports each as `ex_<name>`.
    const flagships = [_][]const u8{
        "helmet_sw",
        "bone_socket",
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
        "physics_sidebyside",
        "mpc_cartpole",
        "mandel_sidebyside",
        "rt_sidebyside",
        "plot_demo",
        "plot3d_demo",
        "sph_fluid_2d",
        "fluid_sort",
        "zimrnum_field",
        "four_ways",
        "worker_png",
        "mandel_julia",
        "waving_cubes",
        "tic_tac_toe",
        "langton_ant",
        "snake",
        "goban",
        "fps_playground",
        "starfield",
        "shader_effects",
        "audio_scale_star_hands",
        "quadruped",
        "gallery_all",
    };
    {
        const launcher_windows_mod: *Module = windows_app_ctx.buildUserModShared("launcher");
        inline for (flagships) |flagship_name| {
            const flagship_mod: *Module = windows_app_ctx.buildAppModule(appNamed(&wgpu_apps, flagship_name));
            launcher_windows_mod.addImport("ex_" ++ flagship_name, flagship_mod);
        }
        const launcher_windows_install: *Step.InstallArtifact = addWindowsApp(
            windows_app_ctx,
            launcher_windows_mod,
            "launcher",
            false,
        );
        windows_builds.put("launcher", launcher_windows_install) catch @panic("oom");
    }
    // ---- `platforms-check` (platforms_plan.md B9): the launcher - every flagship in one program - compiled for every
    // platform: the web's page and Windows' program, as their own steps build them, and for Linux, macOS and Android
    // an object of the launcher's program on the unwritten platform (`platform/unwritten.zig`), compiled and not
    // linked, so that no system's libraries are needed here. Code that compiles only for Windows or the browser fails
    // here the day it is written. The web's page joins it below, once every web build is registered.
    const platforms_check_step: *Step = b.step(
        "platforms-check",
        "Compile the launcher for the web, Windows, Linux, macOS and Android",
    );
    {
        platforms_check_step.dependOn(&windows_builds.get("launcher").?.step);
        for (platform_check_targets, &platform_check_engines) |check_target, *check_engine| {
            const check_common_mod: *Module = b.createModule(.{
                .root_source_file = b.path("examples/example_common/example_common.zig"),
                .target = check_engine.target,
                .optimize = native_optimize,
            });
            check_common_mod.addImport("zimr", check_engine.zimr_mod);
            check_common_mod.addImport("zm", zimrmath_mod);
            const check_shader_cache: *StringHashMap(ShaderDep) = b.allocator.create(StringHashMap(ShaderDep)) catch
                @panic("oom");
            check_shader_cache.* = StringHashMap(ShaderDep).init(b.allocator);
            var check_ctx: AppContext = windows_app_ctx;
            check_ctx.target = check_engine.target;
            check_ctx.zimr_mod = check_engine.zimr_mod;
            check_ctx.common_mod = check_common_mod;
            check_ctx.kompute_mod = check_engine.numerics.kompute;
            check_ctx.zimrnum_mod = check_engine.numerics.zimrnum;
            check_ctx.zimrrl_mod = check_engine.numerics.zimrrl;
            check_ctx.shader_cache = check_shader_cache;
            check_ctx.pdb_void_workaround = null;
            const check_launcher_mod: *Module = check_ctx.buildUserModShared("launcher");
            inline for (flagships) |flagship_name| {
                const flagship_mod: *Module = check_ctx.buildAppModule(appNamed(&wgpu_apps, flagship_name));
                check_launcher_mod.addImport("ex_" ++ flagship_name, flagship_mod);
            }
            const check_name: []const u8 = b.fmt("launcher_{s}", .{check_target.name});
            const check_object: *Compile = nativeAppObject(check_ctx, check_launcher_mod, check_name);
            platforms_check_step.dependOn(&check_object.step);
        }
    }
    // ---- The launcher headless (`launcher-headless`): every flagship in one program, so that one build sweeps them
    // all - a script switches from each to the next with the launcher's Page Down, and captures it.
    {
        checkLauncherRoster(b, &flagships);
        const launcher_headless_mod: *Module = headless_app_ctx.buildUserModShared("launcher");
        inline for (flagships) |flagship_name| {
            const flagship_mod: *Module = headless_app_ctx.buildAppModule(appNamed(&wgpu_apps, flagship_name));
            launcher_headless_mod.addImport("ex_" ++ flagship_name, flagship_mod);
        }
        const launcher_exe: *Compile = addHeadlessRunOf(
            b,
            headless_app_ctx,
            launcher_headless_mod,
            "launcher",
            false,
            script_path,
        );
        // `flagships-check`: the launcher runs every flagship in turn, each for 40 frames, captured into
        // zig-out/headless/launcher/; the step fails when the run is not clean - a leak, a validation message, a
        // script line that failed. The script is written here, from the flagship list itself, and given on the
        // standard input: a capture, then Page Down - the launcher's "next" - and another, once per flagship.
        var sweep_script: ArrayList(u8) = .empty;
        sweep_script.appendSlice(b.allocator, ".{ .advance = 40 }\n.capture\n") catch @panic("OOM");
        for (1..flagships.len) |_| {
            const next_flagship: []const u8 = ".{ .key_down = .page_down }\n.{ .advance = 1 }\n" ++
                ".{ .key_up = .page_down }\n.{ .advance = 40 }\n.capture\n";
            sweep_script.appendSlice(b.allocator, next_flagship) catch @panic("OOM");
        }
        const sweep: *Run = b.addRunArtifact(launcher_exe);
        sweep.has_side_effects = true;
        sweep.setCwd(b.path("."));
        sweep.setStdIn(.{ .bytes = sweep_script.items });
        sweep.setEnvironmentVariable("ZIMR_SCRIPT", "-");
        sweep.setEnvironmentVariable("ZIMR_CAPTURE_DIR", "zig-out/headless/launcher");
        const flagships_check: *Step = b.step(
            "flagships-check",
            "Run every flagship headless in the launcher, capturing each; fails on a leak or a validation message",
        );
        flagships_check.dependOn(&sweep.step);
    }
    // ---- kernels-wgsl: every compute kernel entry's WGSL, installed as zig-out/kernels-wgsl/<file>__<entry>.wgsl -
    // so a change to kompute or spv2wgsl is checked against the previous build by comparing two directories.
    {
        const kernels_wgsl_step: *Step = b.step(
            "kernels-wgsl",
            "Install every compute kernel entry's WGSL into zig-out/kernels-wgsl, one file per entry",
        );
        // A kernel used by several apps is built once per app, under one name; two different files under one name
        // would hide one of them, so that stops the build.
        var source_by_name: StringHashMap([]const u8) = .init(b.allocator);
        for (shader_pipeline.compute_outputs.items) |output| {
            const seen: StringHashMap([]const u8).GetOrPutResult = source_by_name.getOrPut(output.name) catch
                @panic("OOM");
            if (seen.found_existing) {
                if (!eql(u8, seen.value_ptr.*, output.source_name)) {
                    std.debug.panic("kernels-wgsl: {s} and {s} both give {s}", .{
                        seen.value_ptr.*,
                        output.source_name,
                        output.name,
                    });
                }
                continue;
            }
            seen.value_ptr.* = output.source_name;
            const installed_path: []const u8 = b.fmt("kernels-wgsl/{s}.wgsl", .{output.name});
            const install: *Step.InstallFile = b.addInstallFile(output.wgsl, installed_path);
            kernels_wgsl_step.dependOn(&install.step);
        }
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
        // to blame the jobs wiring - and I did, twice. The real cause had nothing to do with
        // jobs: `wireComputeKernels` minted a FRESH `kompute` module per example. With one
        // compute example per page that is invisible. A launcher is BY DEFINITION many examples
        // on one page, so Zig saw two distinct modules rooted at the same `src/kompute.zig`,
        // renamed the second `kompute0`, and rejected the file for belonging to both. Its error
        // named `escape_kernel.zig` - the import that tripped over the clash, not the cause.
        //
        // The cap was silent, and it was ONE COMPUTE EXAMPLE PER PAGE. `AppContext` already
        // held a shared `kompute_mod`; the wiring simply never reached for it.
        const launcher_kernels: LazyPath = buildJobKernels(
            b,
            "launcher",
            b.path("examples/launcher/kernels.zig"),
            &.{ "worker_png", "four_ways", "goban" },
            wasm_optimize,
            build_opts_wgpu,
            build_opts_zm,
        );

        inline for (flagships) |fname| {
            launcher_mod.addImport("ex_" ++ fname, app_mods.get(fname).?);
        }
        const launcher_source: *InstallFile = installExampleSource(
            b,
            tools.example_source,
            "launcher",
            &.{},
            &.{},
            &.{},
        );
        example_sources_step.dependOn(&launcher_source.step);
        const launcher_exe: *Compile = finishWgpuApp(
            b,
            c2js_exe,
            wgpu_smoke_install,
            smoke_focus,
            wasm_target,
            wasm_optimize,
            zimr_mod,
            zimrmath_mod,
            shader_interface_mod,
            buildaux_exe,
            launcher_mod,
            "launcher",
            "zimr - launcher",
            false,
            launcher_kernels,
            true,
            &launcher_source.step,
            &web_builds,
            bridge_import_check_exe,
        );
        if (platform == .android) {
            android_builds.put("launcher", addAndroidBuild(b, b, tools.android_apk, "launcher", .{
                .page = bridgePage(b, c2js_exe, launcher_exe, "zimr - launcher", false, launcher_kernels, false),
                .app_id = defaultAndroidAppId(b, "launcher"),
                .label = "zimr - launcher",
                .icon = null,
            })) catch @panic("oom");
        }
    }

    // ---- One step per app: `zig build <app>` builds it for `-Dplatform` - the web build (served page and single
    // file) or the native program - or, on a machine zimr has no platform for, fails naming the choices. An app
    // without a build for the chosen platform fails naming the reason. `all-examples` builds every app the platform
    // has, natively the gallery that starts them included. The steps that ship something are listed for the lint
    // gate below.
    var artifact_step_names: ArrayList([]const u8) = .empty;
    {
        var app_names: ArrayList([]const u8) = .empty;
        var web_names: StringHashMap(*Step).KeyIterator = web_builds.keyIterator();
        while (web_names.next()) |name| {
            app_names.append(b.allocator, name.*) catch @panic("oom");
        }
        var windows_names: StringHashMap(*Step.InstallArtifact).KeyIterator = windows_builds.keyIterator();
        while (windows_names.next()) |name| {
            if (!web_builds.contains(name.*)) {
                app_names.append(b.allocator, name.*) catch @panic("oom");
            }
        }
        sortSlice([]const u8, app_names.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        const all_examples_step: *Step = b.step(
            "all-examples",
            "Build every example for -Dplatform: the web's pages, each program and the native gallery, or each APK",
        );
        var gallery_step: ?*Step = null;
        var launcher_run_step: ?*Step = null;
        for (app_names.items) |name| {
            // `serve`, `dist` and `test-all-examples` build every web page whatever `-Dplatform` says. The graph walk
            // below finds the wasm installs only through some top-level step, and natively no app step reaches them.
            if (web_builds.get(name)) |web_build| {
                web_examples_step.dependOn(web_build);
                // The launcher's page: the web's part of `platforms-check`.
                if (eql(u8, name, "launcher")) {
                    platforms_check_step.dependOn(web_build);
                }
            }
            const dash_name: []const u8 = std.mem.replaceOwned(u8, b.allocator, name, "_", "-") catch @panic("oom");
            const app_build: *Step = appBuildFor(b, platform, name, &web_builds, &windows_builds, &android_builds);
            const app_step: *Step = b.step(dash_name, b.fmt("Build {s} for -Dplatform (web, windows or android)", .{
                name,
            }));
            app_step.dependOn(app_build);
            const is_lab_for_windows: bool = eql(u8, name, "geno_lab") and platform == .windows;
            if (is_lab_for_windows) {
                app_step.dependOn(geno_trainer_windows_install.?);
            }
            // `all-examples` builds the apps the platform has; one it lacks (the gallery on the web, an app still
            // pending natively) is left out, and its own step says why. With no platform at all every app's step
            // fails naming the choices, and `all-examples` fails with them.
            const in_all_examples: bool = if (platform) |chosen| switch (chosen) {
                .web => web_builds.contains(name),
                .windows => windows_builds.contains(name),
                .android => android_builds.contains(name),
            } else true;
            if (in_all_examples) {
                all_examples_step.dependOn(app_build);
            }
            artifact_step_names.append(b.allocator, dash_name) catch @panic("oom");
            // `run-<app>` builds it as `<app>` does - lint gate included - then runs it.
            const run_step: *Step = b.step(
                b.fmt("run-{s}", .{dash_name}),
                b.fmt("Build {s} for -Dplatform and run it: the program, its page in a browser, or on the phone", .{
                    name,
                }),
            );
            run_step.dependOn(appRunFor(
                b,
                platform,
                name,
                app_step,
                serve_exe,
                &web_builds,
                &windows_builds,
                &android_builds,
            ));
            if (eql(u8, name, "zimr_gallery")) {
                gallery_step = app_step;
            }
            if (eql(u8, name, "launcher")) {
                launcher_run_step = run_step;
            }
        }
        artifact_step_names.append(b.allocator, "all-examples") catch @panic("oom");

        // `zig build run`: the gallery, for the platform - natively the program that starts each example, so every
        // example is built first; on the web the gallery page, beside every example's page, as `serve` builds them. On
        // a phone, where one app is one page, the launcher: the flagship examples in one app.
        const run_gallery_step: *Step = b.step(
            "run",
            "Build every example for -Dplatform and run the gallery: the native program, the web page in a browser, " ++
                "or the launcher on the phone",
        );
        const gallery_build: *Step = gallery_step orelse @panic("zimr_gallery has no app step");
        if (platform == .web) {
            const gallery_page_run: *Run = addServeRun(b, serve_exe, null, "/");
            gallery_page_run.step.dependOn(web_examples_step);
            run_gallery_step.dependOn(&gallery_page_run.step);
        } else if (platform == .android) {
            run_gallery_step.dependOn(launcher_run_step orelse @panic("launcher has no run step"));
        } else if (platform == null) {
            // No platform for this machine: the gallery's step fails naming the choices.
            run_gallery_step.dependOn(gallery_build);
        } else {
            const gallery_run: *Step = appRunFor(
                b,
                platform,
                "zimr_gallery",
                gallery_build,
                serve_exe,
                &web_builds,
                &windows_builds,
                &android_builds,
            );
            gallery_run.dependOn(all_examples_step);
            run_gallery_step.dependOn(gallery_run);
        }
    }

    // stub WebGPU + WASI imports, runs `_initialize` + 60 frames of
    // `update`, verifies no traps and no missing imports.  Catches
    // function signature mismatches between Zig externs and the JS
    // bridge - the kind of bug that would otherwise only surface in
    // the browser, with a confusing "missing import" error.
    const wgpu_smoke_step: *Step = b.step(
        "smoke",
        "Smoke-test the WebGPU demo wasm in Node (no real GPU needed)",
    );
    // ---- JS test runner: Node (not Bun) -----------------------------------
    // The wasm-execution test harnesses need a JS runtime only for
    // WebAssembly.instantiate + a host import shim; everything else they use
    // is node:fs/crypto/path. Node 22 provides all of it and strips TS types
    // inline, so Bun is not a test dependency. (A pure-Zig wasm runner would
    // mean embedding an interpreter - disproportionate; Node is the simplest
    // ubiquitous thing that runs wasm with JS host functions.)
    // DOGFOODED (Phase 5b): the smoke test LOGIC is webtests/wgpu_smoke.zig,
    // compiled to wasm32 and transpiled to JS by our OWN c2js, then run under
    // Node via webtests/runner.mjs (the only hand-written JS in the path -
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

    // zimrnum-ref: the tutorial's reference table is compared against zimrnum's public surface
    // by a test, which makes a hand-written table of a hundred-plus rows a standing hazard.
    // tools/zimrnum_ref.zig regenerates it from the source.
    const zimrnum_ref_exe: *Compile = b.addExecutable(.{
        .name = "zimrnum_ref",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zimrnum_ref.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    zimrnum_ref_exe.root_module.addImport("cli", cli_mod);
    const zimrnum_ref_run: *Run = b.addRunArtifact(zimrnum_ref_exe);
    zimrnum_ref_run.has_side_effects = true; // rewrites the tutorial
    const zimrnum_ref_step: *Step = b.step(
        "zimrnum-ref",
        "Regenerate the zimrnum tutorial's reference table from src/zimrnum.zig",
    );
    zimrnum_ref_step.dependOn(&zimrnum_ref_run.step);

    // zimrnum-hello: the tutorial's opening program, as a real executable.
    //
    // Section 2.1 shows it in full and quotes its output. An example printed in a document and
    // compiled nowhere is a claim; this makes it a build target, so a signature change breaks the
    // build rather than the document.
    const zimrnum_hello_exe: *Compile = b.addExecutable(.{
        .name = "zimrnum_hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zimrnum_hello.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zn", .module = zimrnum_mod },
            },
        }),
    });
    const zimrnum_hello_run: *Run = b.addRunArtifact(zimrnum_hello_exe);
    const zimrnum_hello_step: *Step = b.step(
        "zimrnum-hello",
        "Run the tutorial's opening program (section 2.1)",
    );
    zimrnum_hello_step.dependOn(&zimrnum_hello_run.step);

    // doc-sync: the tutorials quote real source, and a quote that has drifted teaches a
    // version of the code that does not exist. tools/doc_sync.zig makes that checkable.
    const doc_sync_exe: *Compile = b.addExecutable(.{
        .name = "doc_sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/doc_sync.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    doc_sync_exe.root_module.addImport("cli", cli_mod);
    // URDF import: read a robot description, write a checked-in Zig model. The output is
    // committed rather than generated on the fly - see tools/urdf_import.zig for why.
    const urdf_module: *std.Build.Module = b.createModule(.{
        .root_source_file = b.path("src/urdf.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    urdf_module.addImport("zm", zimrmath_mod);
    const urdf_import_exe: *Compile = b.addExecutable(.{
        .name = "urdf_import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/urdf_import.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    urdf_import_exe.root_module.addImport("cli", cli_mod);
    urdf_import_exe.root_module.addImport("urdf", urdf_module);
    const urdf_import_step: *Step = b.step(
        "urdf-import",
        "regenerate the checked-in Zig models from their URDF sources",
    );
    const urdf_import_run: *Run = b.addRunArtifact(urdf_import_exe);
    urdf_import_run.setCwd(b.path("."));
    urdf_import_run.addArgs(&.{
        "src/tests/fixtures/robot/kuka_iiwa.urdf",
        "src/tests/fixtures/robot/kuka_iiwa.zig",
        "@import(\"../../../robot.zig\")",
    });

    // * THE SAME MODEL, EMITTED AGAIN FOR THE EXAMPLE - because an example cannot import
    // across a module boundary, and a hand-copied model GOES STALE SILENTLY.
    //
    // It already did: `robot_3d` carried a copy made before the importer learned to emit
    // collision hulls, so the example simulated a robot with `ngeom = 0`. The bridge created
    // no proxies, the arm did not exist to the collision detector, and it swept through a
    // crate tower reporting zero contacts - with every other part of the seam correct.
    // Nothing warns about a stale copy; it compiles and runs and is simply an older robot.
    //
    // Regenerating both from one source means they cannot disagree. The import path differs
    // only because the example reaches `robot` through the `zimr` module.
    const urdf_import_example: *Run = b.addRunArtifact(urdf_import_exe);
    urdf_import_example.setCwd(b.path("."));
    urdf_import_example.addArgs(&.{
        "src/tests/fixtures/robot/kuka_iiwa.urdf",
        "examples/robot_3d/kuka_iiwa.zig",
        "@import(\"zimr\").robot",
    });
    urdf_import_example.step.dependOn(&urdf_import_run.step);
    urdf_import_step.dependOn(&urdf_import_example.step);
    // Format the generated file, the same way scripts/robot_oracle.py does for its
    // fixtures. A generated file that is checked in has to survive `zig fmt --check`, or
    // the formatting gate fails on code nobody wrote.
    const urdf_fmt: *Run = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    urdf_fmt.addArg("src/tests/fixtures/robot/kuka_iiwa.zig");
    urdf_fmt.addArg("examples/robot_3d/kuka_iiwa.zig");
    urdf_fmt.setCwd(b.path("."));
    urdf_fmt.step.dependOn(&urdf_import_example.step);
    urdf_import_step.dependOn(&urdf_fmt.step);

    const doc_sync_step: *Step = b.step("doc-sync", "check tutorial code against its source");
    const doc_sync_run: *Run = b.addRunArtifact(doc_sync_exe);
    doc_sync_run.setCwd(b.path("."));
    doc_sync_step.dependOn(&doc_sync_run.step);
    // doc-folds: a tutorial's code blocks are GENERATED from the source - each block names its
    // declaration (data-src / data-decl) and tools/doc_folds.zig fills it in, plus a reference
    // table of every public declaration. `zig build doc-folds` rewrites them; the gate (below)
    // does it too, or only checks with -Dautofix=false. Add a page here when it starts tagging.
    const doc_folds_exe: *Compile = b.addExecutable(.{
        .name = "doc_folds",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/doc_folds.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    doc_folds_exe.root_module.addImport("cli", cli_mod);
    // One generator per page: zimrnum-tutorial.html's folds belong to tools/zimrnum_ref.zig (derived from
    // the `zn.` names each example uses), so it is not listed here.
    const doc_folds_pages = [_][]const u8{
        "src/notes/tutorials/robot-mocap-tutorial.html",
        "src/notes/tutorials/backends-tutorial.html",
        "src/notes/tutorials/gpu-compute-tutorial.html",
        "src/notes/tutorials/sound_tutorial.html",
        "src/notes/tutorials/goban_tutorial.html",
    };
    const doc_folds_step: *Step = b.step(
        "doc-folds",
        "regenerate the tutorials' code blocks and reference from the source",
    );
    const doc_folds_fix: *Run = b.addRunArtifact(doc_folds_exe);
    doc_folds_fix.setCwd(b.path("."));
    doc_folds_fix.has_side_effects = true;
    doc_folds_fix.addArg("--fix");
    doc_folds_fix.addArgs(&doc_folds_pages);
    doc_folds_step.dependOn(&doc_folds_fix.step);

    // c2js CANARY: the marker gate catches C that c2js KNOWS it cannot model;
    // this catches C it models WRONGLY. The battery is transpiled the normal way
    // and compared against the same computation folded by Zig's comptime
    // evaluator, which never passes through c2js. See webtests/c2js_canary.zig.
    const canary_step: *Step = b.step("c2js-canary", "differential-test c2js integer lowering");
    const canary_to_c: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,       "build-obj",
        "-ofmt=c",             "-target",
        "wasm32-freestanding", "-OReleaseSmall",
    });
    canary_to_c.addFileArg(b.path("webtests/c2js_canary.zig"));
    const canary_c: LazyPath = canary_to_c.addPrefixedOutputFileArg("-femit-bin=", "c2js_canary.c");
    const canary_to_js: *Run = b.addRunArtifact(c2js_exe);
    canary_to_js.setStdIn(.{ .lazy_path = canary_c });
    const canary_js: LazyPath = canary_to_js.captureStdOut(.{});
    const canary_run: *Run = b.addSystemCommand(&.{ "node", "webtests/c2js_canary.mjs" });
    canary_run.addFileArg(canary_js);
    canary_step.dependOn(&canary_run.step);

    // THE AUDIO WORKLET'S PROGRAM, run in Node against a module that plays both parts of a page
    // (`src/audio_worklet_test_module.zig`): the program as the pages embed it, the module built for the browser's
    // instance shape - freestanding, no entry point, its entry points exported. See
    // `tools/c2js_cases/audio_worklet_test.cjs`.
    const audio_worklet_test_step: *Step = b.step(
        "audio-worklet-test",
        "run the audio worklet's program in Node: commands from a real mixer, blocks against a local renderer",
    );
    const audio_test_target: ResolvedTarget = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const audio_test_zm_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimrmath.zig"),
        .target = audio_test_target,
        .optimize = .ReleaseSmall,
    });
    audio_test_zm_mod.addOptions("build_options", build_opts_zm);
    // zimrnum, for the mixer's analysis (`analyser`, its transform).
    const audio_test_zn_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/zimrnum.zig"),
        .target = audio_test_target,
        .optimize = .ReleaseSmall,
    });
    audio_test_zn_mod.addImport("zm", audio_test_zm_mod);
    const audio_test_mod: *Module = b.createModule(.{
        .root_source_file = b.path("src/audio_worklet_test_module.zig"),
        .target = audio_test_target,
        .optimize = .ReleaseSmall,
    });
    audio_test_mod.addImport("zm", audio_test_zm_mod);
    audio_test_mod.addImport("zn", audio_test_zn_mod);
    const audio_test_exe: *Compile = b.addExecutable(.{
        .name = "audio_worklet_test_module",
        .root_module = audio_test_mod,
    });
    audio_test_exe.entry = .disabled;
    audio_test_exe.rdynamic = true;
    const audio_worklet_program: LazyPath = buildAudioWorkletJs(b, c2js_exe);
    const audio_worklet_test_run: *Run = b.addSystemCommand(&.{ "node", "tools/c2js_cases/audio_worklet_test.cjs" });
    audio_worklet_test_run.addFileArg(audio_worklet_program);
    audio_worklet_test_run.addArtifactArg(audio_test_exe);
    audio_worklet_test_step.dependOn(&audio_worklet_test_run.step);

    // THE PAGE'S SIDE OF THE SOUND, run in Node against a stand-in browser that follows Chrome where Chrome is
    // stricter than the specification - `process` kept only on exactly `true`, a processor's error fired as
    // `processorerror` - with the page's sound output (`page_audio.zig`, transpiled on its own), the worklet's program
    // and the test module as the app. See `tools/c2js_cases/audio_page_test.cjs`.
    const audio_page_test_step: *Step = b.step(
        "audio-page-test",
        "run the page's sound path in Node against a Chrome-strict stand-in: a held note must sound to the end",
    );
    const audio_page_test_run: *Run = b.addSystemCommand(&.{ "node", "tools/c2js_cases/audio_page_test.cjs" });
    audio_page_test_run.addFileArg(buildPageAudioJs(b, c2js_exe));
    audio_page_test_run.addFileArg(audio_worklet_program);
    audio_page_test_run.addArtifactArg(audio_test_exe);
    audio_page_test_step.dependOn(&audio_page_test_run.step);

    // ---- corpus: spv2wgsl's regression corpus (tools/wgsl_corpus.zig) ----
    // Every graphics shader the pipeline translated (`wgsl_corpus`, filled as each one is added), held to
    // tests/fixtures/wgsl_corpus.txt: no unresolved ids; the interface each shows the host - entry point, inputs,
    // outputs, bindings - which is the same whichever Zig compiled it; and the WGSL spv2wgsl writes for SPIR-V it
    // has been given before. What it checks is what this build compiles, named by source file, never what an older
    // build left in the cache - so the step builds every shader first, and runs the tool's own tests first too.
    // `corpus-refresh` rewrites the fixture from this build.
    const wgsl_corpus_exe: *Compile = b.addExecutable(.{
        .name = "wgsl_corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wgsl_corpus.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    wgsl_corpus_exe.root_module.addImport("cli", cli_mod);
    const wgsl_corpus_tests: *Compile = b.addTest(.{ .root_module = wgsl_corpus_exe.root_module });
    const wgsl_corpus_tests_run: *Run = b.addRunArtifact(wgsl_corpus_tests);
    const wgsl_corpus_cmd: *Run = addWgslCorpusRun(b, wgsl_corpus_exe, wgsl_corpus, .check);
    wgsl_corpus_cmd.step.dependOn(&wgsl_corpus_tests_run.step);
    const corpus_step: *Step = b.step(
        "corpus",
        "Hold every graphics shader's WGSL to tests/fixtures/wgsl_corpus.txt",
    );
    corpus_step.dependOn(&wgsl_corpus_cmd.step);

    // ---- c2js-diff: the transpiler's differential regression gate -----
    // The original webzig transpiler shipped a 100-case differential
    // suite (intake/webzig-all/webzig/tests/cases/*.zig): each case
    // `export fn run_test() i32` returning 0. The gate compiles each case
    // to NATIVE (oracle) and runs it, then transpiles the SAME case
    // through OUR c2js -> JS and runs run_test() under Node, asserting
    // the JS result equals the native result AND that no /*TODO|/*?
    // unhandled-lowering marker reached the output. This is what proves
    // c2js transpiles ARBITRARY Zig correctly, not just zimr's linted
    // subset - which is exactly why these case files are NOT linted
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
    // KNOWN_FAIL: empty - all four cases that failed on the current Zig's C-backend
    // output (packed_bitcast, packed_struct_wide, arrays_of_structs,
    // odd_width_aggregate) have been fixed in c2js and now pass. The gate is a clean
    // regression gate: ANY failure is a real regression. If a future Zig C-backend
    // change breaks a case, add its name here (XFAIL, non-fatal) while c2js catches up.
    c2js_diff_cmd.setEnvironmentVariable("KNOWN_FAIL", "");
    c2js_diff_cmd.step.dependOn(&c2js_diff_install.step);
    c2js_diff_step.dependOn(&c2js_diff_cmd.step);
    // The converter's own unit tests (its literal decoding, say), built from the same module as the converter.
    const c2js_unit_tests: *Compile = b.addTest(.{ .root_module = c2js_exe.root_module });
    const c2js_unit_run: *Run = b.addRunArtifact(c2js_unit_tests);
    c2js_diff_step.dependOn(&c2js_unit_run.step);

    // Pin this build's shaders in the corpus fixture: after a deliberate change to a shader's interface or to
    // spv2wgsl's output, and on each machine (each compiler) whose WGSL should be compared. Commit the fixture with
    // the change that moved it.
    const wgsl_corpus_refresh_cmd: *Run = addWgslCorpusRun(b, wgsl_corpus_exe, wgsl_corpus, .refresh);
    wgsl_corpus_refresh_cmd.step.dependOn(&wgsl_corpus_tests_run.step);
    const corpus_refresh_step: *Step = b.step(
        "corpus-refresh",
        "Pin every graphics shader's interface and WGSL in tests/fixtures/wgsl_corpus.txt",
    );
    corpus_refresh_step.dependOn(&wgsl_corpus_refresh_cmd.step);

    // native_target - used by both wgpu-diff (below) and the
    // per-file test loop later.  Declared here at first use; the
    // later for-loop reuses the same value.
    const native_target: ResolvedTarget = b.standardTargetOptions(.{});

    // bmpc-cartpole: BMPC learns to balance a cartpole - the end-to-end gate of the BMPC agent. It trains a small agent
    // for a few minutes, so it runs on demand rather than in test-fast. Built ReleaseSafe, with safety checks kept: zm,
    // zn and zrl set no optimisation of their own, so they compile as this root does.
    {
        const bmpc_cartpole_mod: *Module = b.createModule(.{
            .root_source_file = b.path("src/robot_bmpc_cartpole.zig"),
            .target = native_target,
            .optimize = .ReleaseSafe,
        });
        bmpc_cartpole_mod.addImport("zm", zimrmath_mod);
        bmpc_cartpole_mod.addImport("zn", zimrnum_mod);
        bmpc_cartpole_mod.addImport("zrl", zimrrl_mod);
        const bmpc_cartpole_test: *Compile = b.addTest(.{ .root_module = bmpc_cartpole_mod });
        if (test_filter) |f| {
            bmpc_cartpole_test.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
        }
        const bmpc_cartpole_run: *Run = b.addRunArtifact(bmpc_cartpole_test);
        bmpc_cartpole_run.has_side_effects = true;
        const bmpc_cartpole_step: *Step = b.step("bmpc-cartpole", "BMPC learns to balance a cartpole (on demand)");
        bmpc_cartpole_step.dependOn(&bmpc_cartpole_run.step);
    }

    // test-goban: the tests at the end of `examples/goban/goban.zig`, built from the example's own file for the build's
    // machine. The rules, the forest and the diagrams need only `zm`, and Zig analyses only what the tests reach, so
    // nothing of the engine is compiled. Debug, unlike the suite's ReleaseSafe: these tests run in well under a second,
    // so the compile is the whole wait, and Debug is the mode whose backend compiles incrementally -
    // `zig build test-goban --watch -fincremental` reruns the tests on every save after a short recompile.
    {
        const goban_test_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/goban/goban.zig"),
            .target = native_target,
            .optimize = .Debug,
        });
        goban_test_mod.addImport("zm", zimrmath_mod);
        // The arena (`goban-arena`, below) is one of these tests, and skips itself here.
        const goban_test_options: *Step.Options = b.addOptions();
        goban_test_options.addOption(bool, "run_arena", false);
        goban_test_mod.addOptions("goban_test_options", goban_test_options);
        const goban_test: *Compile = b.addTest(.{ .root_module = goban_test_mod });
        if (test_filter) |f| {
            goban_test.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
        }
        const goban_test_run: *Run = b.addRunArtifact(goban_test);
        const goban_test_step: *Step = b.step("test-goban", "The goban example's rules, forest and diagrams");
        goban_test_step.dependOn(&goban_test_run.step);
    }

    // goban-arena: two settings of goban's computer opponent play each other - the `arena:` tests at the end of
    // `examples/goban/goban.zig` - and the score is printed. ReleaseFast, since a match is a hundred games of searches;
    // on demand, like bmpc-cartpole, since a match takes minutes.
    {
        const goban_arena_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/goban/goban.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
        });
        goban_arena_mod.addImport("zm", zimrmath_mod);
        const goban_arena_options: *Step.Options = b.addOptions();
        goban_arena_options.addOption(bool, "run_arena", true);
        goban_arena_mod.addOptions("goban_test_options", goban_arena_options);
        const goban_arena: *Compile = b.addTest(.{ .root_module = goban_arena_mod });
        const arena_filter: []const u8 = test_filter orelse "arena:";
        goban_arena.filters = b.allocator.dupe([]const u8, &.{arena_filter}) catch @panic("OOM");
        const goban_arena_run: *Run = b.addRunArtifact(goban_arena);
        goban_arena_run.has_side_effects = true;
        const goban_arena_description: []const u8 = "Two settings of goban's computer play a match (on demand)";
        const goban_arena_step: *Step = b.step("goban-arena", goban_arena_description);
        goban_arena_step.dependOn(&goban_arena_run.step);
    }

    // goban-play: a game against goban's computer from the command line (examples/goban/goban_play.zig) - each call the
    // whole game, its moves after `--`: `zbuild goban-play -- --computer white d5 c4`. ReleaseFast, so its second of
    // search runs as many iterations as the app's natively.
    {
        const goban_play_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/goban/goban_play.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
        });
        goban_play_mod.addImport("zm", zimrmath_mod);
        const goban_play_exe: *Compile = b.addExecutable(.{ .name = "goban-play", .root_module = goban_play_mod });
        const goban_play_run: *Run = b.addRunArtifact(goban_play_exe);
        // What follows `--` goes to the program, and the run is never cached: each call is a new move.
        goban_play_run.addPassthruArgs();
        const goban_play_step: *Step = b.step("goban-play", "A game against goban's computer from the command line");
        goban_play_step.dependOn(&goban_play_run.step);
    }

    // goban-problems-convert: published SGF problems turned into goban's kill problems, each target found with goban's
    // search (examples/goban/goban_problems_tool.zig): `zbuild goban-problems-convert -- --out <dir> <sgf files>`.
    {
        const goban_convert_mod: *Module = b.createModule(.{
            .root_source_file = b.path("examples/goban/goban_problems_tool.zig"),
            .target = native_target,
            .optimize = .ReleaseFast,
        });
        goban_convert_mod.addImport("zm", zimrmath_mod);
        const goban_convert_exe: *Compile = b.addExecutable(.{
            .name = "goban-problems-convert",
            .root_module = goban_convert_mod,
        });
        const goban_convert_run: *Run = b.addRunArtifact(goban_convert_exe);
        goban_convert_run.addPassthruArgs();
        const goban_convert_description: []const u8 = "goban's kill problems from published SGF problems";
        const goban_convert_step: *Step = b.step("goban-problems-convert", goban_convert_description);
        goban_convert_step.dependOn(&goban_convert_run.step);
    }

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
    // No JS, no Node, no npm.  Pure Zig - aligned with the "pure
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
        // same host-test graph (tests.zig -> render stack), so it needs the
        // identical shader wiring: .glsl placeholders (the real .glsl would
        // run the gated-off spirv-opt path), the .wgsl twins that
        // renderer_2d @embedFiles, the shapes externs modules, AND
        // build_options (ui.zig and the wgpu stack @import it). Previously
        // diff_mod wired only the .glsl names + zm + shader_interface and
        // so failed to compile (missing build_options + .wgsl embeds) -
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
        diff_mod.addImport("zn", zimrnum_mod);
        diff_mod.addImport("zrl", zimrrl_mod);
        diff_mod.addAnonymousImport("atomic_buildgrid_spv", .{
            .root_source_file = b.path("tests/fixtures/atomics/atomic_buildgrid.spv"),
        });
        diff_mod.addImport("shader_interface", shader_interface_mod);
        diff_mod.addOptions("build_options", build_opts);
        const t: *Compile = b.addTest(.{
            .root_module = diff_mod,
            .filters = &.{
                // Phase 0 - corpus runner + WGSL structural validator
                "spv2wgsl corpus",   "wgsl_check",     "scanBugs",
                // Phase 1.1 - module split scaffolds (types.zig has
                // real tests; block_table/walker/selection/loop/switch
                // are scaffolds whose `scaffold compiles` smoke runs
                // through these filters).
                "Op enum",           "StorageClass",   "BuiltIn",
                "scaffold compiles",
                // Phase 1.3 - BlockTable construction tests.
                "registerBlocks",
                // Phase 2 - walker scaffold + StopSet.
                "emitStopExit",
                "StopSet",           "emitBlock",      "emitBranch",
            },
        });
        const run: *Run = b.addRunArtifact(t);
        run.has_side_effects = true;
        transpiler_diff_step.dependOn(&run.step);
    }

    // ---- Smoke test: load each live wgpu example wasm in Node and check
    // it boots + ticks frames without trapping (no real GPU needed - the
    // wgpu/dom/wasi imports are stubbed).  By default smoke-test runs the
    // whole wgpu gallery; -Dfocus=<names|prefix*> (or the `tier-a` magic
    // value) narrows it.  The old GL `smoke.ts` gallery was retired with
    // the WebGL backend - this is its wgpu successor.
    // DOGFOODED (Phase 5b): same Zig logic + runner.mjs as wgpu-smoke, in
    // directory mode over the wgpu gallery. Reuses the smoke_logic_js
    // LazyPath transpiled above (c2js output of webtests/wgpu_smoke.zig).
    const smoke_step: *Step = b.step("smoke-test", "Run wgpu wasm smoke tests (Zig logic via c2js + Node)");
    const smoke_cmd: *Run = b.addSystemCommand(&.{ "node", "webtests/runner.mjs" });
    smoke_cmd.addFileArg(smoke_logic_js);
    smoke_cmd.addArg("--web-dir=zig-out/wgpu-smoke/web");
    // `-Dsmoke-frames=N`: how many frames each page runs (default 60). Hundreds of frames expose what
    // grows per frame - the harness prints live CPU bytes at the halfway frame and the last.
    const smoke_frames: u32 = b.option(u32, "smoke-frames", "Frames each smoke-test page runs (default 60)") orelse 60;
    smoke_cmd.addArg(b.fmt("--frames={d}", .{smoke_frames}));
    if (smoke_focus.len > 0) {
        // wgpu_smoke.ts doesn't know the `tier-a` magic value (only
        // matchesFocus does), so expand it to the literal wgpu example
        // basenames before passing.  Keep this list in sync with the
        // `tier_a_names` table in matchesFocus - both sides must agree so
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
    // and diffs it against bridge.zig - pure Zig, no Node, no wasm execution.
    // Sits between install and smoke_cmd so a bridge gap fails the smoke.
    const verify_imports_exe: *Compile = b.addExecutable(.{
        .name = "verify_imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/verify_imports.zig"),
            .target = host_target,
            .optimize = .ReleaseFast,
        }),
    });
    verify_imports_exe.root_module.addImport("cli", cli_mod);
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
    //   zig build test -Dfocus=tier-a       - typecheck only (~2s)
    //   zig build smoke-test -Dfocus=tier-a - Node smoke for tier-a
    //                                          examples (~15s warm)
    //   zig build tier-a-check              - the combined audit
    //                                          (test + smoke + wgpu)
    //
    // `tier-a` is a magic focus value (see matchesFocus) expanding to
    // the five example names.  Full unfocused `zig build test` and
    // `zig build smoke-test` stay for arc-close / cross-cutting-
    // invariant changes; the norm is -Dfocus=tier-a per turn.
    //
    // `tier-a-check` is the canonical per-turn audit gate for arcs
    // that touch cross-cutting code (drawing, ui, math, shader pipe).
    // For wgpu-only arcs, `tripwires` is faster.
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

    // editor-configs: write the VS Code and Zed debug/build configs for every app with a web build, and a Zed native
    // debug scenario for every app with a Windows program. The names come from the registries (`web_builds`,
    // `windows_builds`), not from a list kept by hand beside them, so no app can be missing from the editors and no
    // config can name an app that is not there. What can still go stale is the four checked-in files - an app added
    // and the configs never regenerated - and `tripwires` runs the same tool with `--check` for that.
    // The tool sorts the apps itself, so the maps' order does not matter here.
    var editor_config_apps: ArrayList([]const u8) = .empty;
    var web_app_names: StringHashMap(*Step).KeyIterator = web_builds.keyIterator();
    while (web_app_names.next()) |name| {
        editor_config_apps.append(b.allocator, name.*) catch @panic("oom");
    }
    var windows_app_names: StringHashMap(*Step.InstallArtifact).KeyIterator = windows_builds.keyIterator();
    while (windows_app_names.next()) |name| {
        editor_config_apps.append(b.allocator, b.fmt("--windows={s}", .{name.*})) catch @panic("oom");
    }
    const editor_configs_run: *Run = b.addRunArtifact(tools.editor_configs);
    editor_configs_run.addArgs(editor_config_apps.items);
    editor_configs_run.setCwd(b.path("."));
    editor_configs_run.step.name = "editor-configs (.vscode/.zed configs for every web and Windows app)";
    const editor_configs_step: *Step = b.step("editor-configs", "Regenerate the VS Code and Zed debug+task configs");
    editor_configs_step.dependOn(&editor_configs_run.step);
    const editor_configs_check: *Run = b.addRunArtifact(tools.editor_configs);
    editor_configs_check.addArg("--check");
    editor_configs_check.addArgs(editor_config_apps.items);
    editor_configs_check.setCwd(b.path("."));
    // It reads the four files, which are not declared inputs: never trust a cached pass.
    editor_configs_check.has_side_effects = true;
    editor_configs_check.step.name = "editor-configs --check (the checked-in configs match every web and Windows app)";

    // files-md: regenerate src/notes/files.md, the per-file atlas (Zig port
    // of scripts/gen_files_md.py).
    const gen_files_md_run: *Run = b.addRunArtifact(tools.gen_files_md);
    gen_files_md_run.step.name = "files-md (regenerate src/notes/files.md atlas)";
    const gen_files_md_step: *Step = b.step("files-md", "Regenerate src/notes/files.md atlas");
    gen_files_md_step.dependOn(&gen_files_md_run.step);

    // files-html: render that atlas as src/notes/files.html, which the docfmt
    // loop then styles like every other page. Depends on files-md so the two
    // cannot disagree.
    const files_html_run: *Run = b.addRunArtifact(tools.files_html);
    files_html_run.step.name = "files-html (render src/notes/files.html from the atlas)";
    files_html_run.has_side_effects = true;
    files_html_run.step.dependOn(&gen_files_md_run.step);
    const files_html_step: *Step = b.step("files-html", "Regenerate src/notes/files.html from files.md");
    files_html_step.dependOn(&files_html_run.step);

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
    tier_a_check_step.dependOn(&wgsl_corpus_cmd.step);

    // ---- `zig build tripwires`: the cheap invariants, run before every snapshot ----------
    // Each one guards something a compile alone cannot see, and none of them compiles `src/`, the test roots or the
    // examples - `zig build test` and the app steps do that. Wired here and further down, beside what each checks:
    //   - the spv2wgsl corpus: every graphics shader held to tests/fixtures/wgsl_corpus.txt;
    //   - the fixture WGSL check: tests/fixture_fs.zig through Zig -> SPIR-V -> spv2wgsl (`test` runs it too);
    //   - the binding tripwire over the corpus (spv2wgsl_check: no two resources on one @group/@binding);
    //   - zimrmath's and zimrnum's GPU branches compiled for SPIR-V (`zm-gpu`, `zn-rl-gpu`);
    //   - the wgpu_bringup build and its Node smoke (no real GPU needed);
    //   - the doc gate, the tutorials' folds and the checked-in editor configs;
    //   - `tools-test`, and `lint-check` (every rule, the layout included).
    // `gate` runs all of it and much more. `check` is the other half (`addCompileCheck`): every test, every tool and
    // the focused examples compiled with no binaries and nothing run - the step ZLS's build-on-save runs.
    const tripwires_step: *Step = b.step(
        "tripwires",
        "Cheap invariants, not a compile: shader corpus and bindings, SPIR-V probes, smoke, docs, configs, lint",
    );
    tripwires_step.dependOn(&wgsl_corpus_cmd.step);
    tripwires_step.dependOn(&wgpu_smoke_cmd.step);
    // The checked-in VS Code and Zed configs cover every web app, and Zed's every Windows app (`editor-configs`
    // writes them).
    tripwires_step.dependOn(&editor_configs_check.step);

    // -- zm's GPU branch, actually verified rather than asserted --
    //
    // zimrmath is the one module allowed to touch std.math, on the deal that each wrapper carries
    // a hand-rolled GPU branch "verified to compile for a shader". Nothing enforced that clause: a
    // helper counted as verified if some shader happened to call it, so the least-used ones were
    // the least checked. `src/shaders/zm_gpu_probe.zig` calls them on a VECTOR type from a real
    // SPIR-V entry point, and this step compiles it with the same flags the shader pipeline uses.
    //
    // It earned its place immediately: `nan`, `inf`, `floatMax`, `floatMin` and `floatEps` take a
    // type rather than a value, and every one was a compile error for `@Vector(4, f32)` - the type
    // a shader actually computes in.
    const zm_gpu_probe: *Run = b.addSystemCommand(&.{
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
        "--dep",
        "zm",
    });
    zm_gpu_probe.addPrefixedFileArg("-Mroot=", b.path("src/shaders/zm_gpu_probe.zig"));
    zm_gpu_probe.addPrefixedFileArg("-Mzm=", b.path("src/zimrmath.zig"));
    _ = zm_gpu_probe.addPrefixedOutputFileArg("-femit-bin=", "zm_gpu_probe.spv");
    zm_gpu_probe.step.name = "zm-gpu (zimrmath compiles for SPIR-V, on vectors)";
    const zm_gpu_step: *Step = b.step("zm-gpu", "Compile zimrmath for SPIR-V through a probe shader");
    zm_gpu_step.dependOn(&zm_gpu_probe.step);
    tripwires_step.dependOn(&zm_gpu_probe.step);

    // ---- THE SAME TRIPWIRE FOR ZIMRNUM'S RL ARITHMETIC ----
    //
    // `zimrnum.zig` is shader-FREE by design - that is what keeps it a `test-fast` root - but
    // shader-free is not shader-INCOMPATIBLE, and nothing held the difference. The op sweep
    // covers 92 kernels and NOT ONE reinforcement-learning operation, so PPO's surrogate and
    // the off-policy targets had never been compiled for a device at all.
    //
    // They are written scalar-first (`ppoClipSample`: no allocation, no error union, no slice)
    // precisely so a kernel can call the SAME function the CPU loop calls. Two transcriptions
    // of one formula is how a CPU/GPU comparison becomes circular. This proves the shape stays
    // callable; the sweep would prove the ANSWERS agree, and no RL row is in it yet.
    const zn_rl_gpu_probe: *Run = b.addSystemCommand(&.{
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
        "--dep",
        "zm",
        "--dep",
        "zrl",
        "-Mroot=src/shaders/zn_rl_gpu_probe.zig",
        "-Mzm=src/zimrmath.zig",
        "--dep",
        "zm",
        "-Mzn=src/zimrnum.zig",
        // zrl's own dependency list: it imports zm and zn.
        "--dep",
        "zm",
        "--dep",
        "zn",
        "-Mzrl=src/zimrrl.zig",
        "-femit-bin=.zig-cache/zn_rl_gpu_probe.spv",
    });
    zn_rl_gpu_probe.step.name = "zn-rl-gpu (zimrrl's RL arithmetic compiles for SPIR-V)";
    const zn_rl_gpu_step: *Step = b.step(
        "zn-rl-gpu",
        "Compile zimrnum's RL scalar arithmetic for SPIR-V through a probe shader",
    );
    zn_rl_gpu_step.dependOn(&zn_rl_gpu_probe.step);
    tripwires_step.dependOn(&zn_rl_gpu_probe.step);
    // Doc style tripwire: every published page keeps one shared stylesheet, no
    // <script>, no webfont fetch. Cheap (four greps over eleven files), and it
    // is the only thing standing between the uniform docs and the five palettes
    // they came from - see `src/notes/docs_style_plan.md`.
    tripwires_step.dependOn(&doc_gate_run.step);
    // Binding/structural WGSL tripwire: run the validator over every shader in
    // the corpus. Depends on wgpu_smoke_cmd so the shaders are compiled into
    // .zig-cache first (the tool walks the cache).
    // Fails the build on any duplicate @group@binding - the collision Dawn
    // rejects on-device that the mock smoke test can't see.
    const spv_bind_check_run: *Run = b.addRunArtifact(spv2wgsl_check_exe);
    spv_bind_check_run.addArg("our-corpus");
    spv_bind_check_run.has_side_effects = true; // reads .zig-cache; never cache the result
    spv_bind_check_run.step.dependOn(&wgpu_smoke_cmd.step);
    tripwires_step.dependOn(&spv_bind_check_run.step);
    // fixture_wgsl_check.step dependency wired further below at the
    // fixture's declaration site (line ~1641).

    // ---- Dev server: pure-Zig (tools/serve.zig), no shell required. --
    // A server on 127.0.0.1:8080 (serve.zig's default port): zig-out/web/ as it is
    // on disk, with no file watcher or rebuild. A page reloads when a
    // `zig build run-<app> -Dplatform=web` (`appRunFor`) rebuilds it and asks;
    // otherwise a rebuilt app shows up on the next manual reload. When a server
    // of zig-out/web/ already holds the port, these steps use it and end at once.
    // Two flavors, beside the `run-<app>` steps:
    //   `zig build serve`        -- builds every example's web build first (whatever
    //                               -Dplatform says), then serves.  Terminal-
    //                               friendly "give me the whole gallery" entry point.
    //   `zig build serve-only`   -- just starts the server.  The default install
    //                               still runs first (zimr.js, the gallery, the
    //                               HTML docs) but builds no example wasms: each
    //                               editor debug config builds its one app with
    //                               `zig build <step> -Dplatform=web` before
    //                               launching Chrome.
    //                               VS Code's background task runs this, so the
    //                               first F5 of a session doesn't pay for every
    //                               example.
    const serve: *Step = b.step(
        "serve",
        "Build all examples, then serve zig-out/web/ on localhost:8080 (pure-Zig server)",
    );
    const serve_cmd: *Run = addServeRun(b, serve_exe, null, null);
    serve_cmd.step.dependOn(web_examples_step);
    serve.dependOn(&serve_cmd.step);

    const serve_only: *Step = b.step(
        "serve-only",
        "Start the dev server without rebuilding examples (static + runtime only)",
    );
    const serve_only_cmd: *Run = addServeRun(b, serve_exe, null, null);
    serve_only_cmd.step.dependOn(b.getInstallStep());
    serve_only.dependOn(&serve_only_cmd.step);

    // `zig build tools-test`: the gallery tools' own tests - the dev server (an idle
    // browser socket must not stall other requests; the test is the measurement in
    // tools/serve.zig's header) and example_source (no highlighted span crosses a
    // newline). In `tripwires`: both compile in seconds and run in well under one.
    // And docfmt: its stylesheet's CSS escapes (a doubled backslash once printed "\25b8" in every fold's title).
    const tools_test_step: *Step = b.step(
        "tools-test",
        "Test the dev server, example_source, docfmt, the doc gate and android_apk",
    );
    for ([_][]const u8{ "tools/serve.zig", "tools/example_source.zig", "tools/docfmt.zig" }) |tool_root| {
        const tool_test: *Compile = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tool_root),
                .target = host_target,
                .optimize = .ReleaseSafe,
            }),
        });
        tools_test_step.dependOn(&b.addRunArtifact(tool_test).step);
    }
    // The doc gate imports the command-line module, so its test is wired on its own.
    const doc_gate_test: *Compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/doc_gate.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    doc_gate_test.root_module.addImport("cli", cli_mod);
    tools_test_step.dependOn(&b.addRunArtifact(doc_gate_test).step);
    // android_apk's choices that need no SDK: which build-tools and platform are newest, an app ID's shape, the
    // label's escaping in the manifest.
    const android_apk_test: *Compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/android_apk.zig"),
            .target = host_target,
            .optimize = .ReleaseSafe,
        }),
    });
    android_apk_test.root_module.addImport("cli", cli_mod);
    tools_test_step.dependOn(&b.addRunArtifact(android_apk_test).step);
    const native_wgsl_check_test: *Compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/native_wgsl_check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    native_wgsl_check_test.root_module.addImport("cli", cli_mod);
    tools_test_step.dependOn(&b.addRunArtifact(native_wgsl_check_test).step);
    const pdb_void_workaround_test: *Compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pdb_void_workaround.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    pdb_void_workaround_test.root_module.addImport("cli", cli_mod);
    tools_test_step.dependOn(&b.addRunArtifact(pdb_void_workaround_test).step);
    const bridge_import_check_test: *Compile = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bridge_import_check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    bridge_import_check_test.root_module.addImport("cli", cli_mod);
    tools_test_step.dependOn(&b.addRunArtifact(bridge_import_check_test).step);
    // `zig build lint-test`: the linter's own tests - every rule's fires/clean pairs, the fix loop, and through its
    // import `line_diff.zig`'s - with zbuild's (which lines are findings) and doc_folds'. In `gate`, not `tripwires`:
    // zimrlint is the biggest tool, and its test build is the slow one.
    const lint_test_step: *Step = b.step("lint-test", "Test zimrlint (with line_diff), zbuild and doc_folds");
    for ([_][]const u8{ "tools/zimrlint.zig", "tools/zbuild.zig", "tools/doc_folds.zig" }) |tool_root| {
        const tool_test: *Compile = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tool_root),
                .target = host_target,
                .optimize = .ReleaseSafe,
            }),
        });
        // zbuild is the one of the three that reads no command line through std's cli.
        if (!eql(u8, tool_root, "tools/zbuild.zig")) {
            tool_test.root_module.addImport("cli", cli_mod);
        }
        lint_test_step.dependOn(&b.addRunArtifact(tool_test).step);
    }
    tripwires_step.dependOn(tools_test_step);

    // `zig build external-check`: build webtests/external_project/, a project that
    // depends on THIS checkout through `Project` - the way template/ does - so
    // the package boundary is compiled by something. zimr_template once drifted for
    // months as a separate repo nothing here built against. A nested `zig build`,
    // with its cache and output under zimr's own .zig-cache/ and zig-out/ so the
    // fixture tree stays clean; `check` there = its lint + host test + every app,
    // and each standalone page exercises the embedded-runtime path.
    const external_cmd: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "check",
        "basic",
        "shaded",
        "four_ways",
        "-Dplatform=web",
        b.fmt("-Dmode={s}", .{@tagName(mode)}),
        "--cache-dir",
        "../../.zig-cache/external_project",
        "--prefix",
        "../../zig-out/external_project",
        "--summary",
        "failures",
    });
    external_cmd.setCwd(b.path("webtests/external_project"));
    external_cmd.has_side_effects = true;
    const external_check: *Step = b.step(
        "external-check",
        "Build webtests/external_project/, a project depending on zimr via `Project`",
    );
    external_check.dependOn(&external_cmd.step);

    // `zig build template-check`: the same nested build for template/, the starter
    // project zimr ships (formerly the separate zimr_template repo). Living in this
    // tree, a `Project` change and the template edit it needs land in one commit, and
    // `gate` runs this so neither ships without the other. Plain `check` (lint + every
    // app): external-check already covers the standalone pages, and naming the
    // template's apps here would tie this file to what a user renames them to.
    const template_cmd: *Run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "check",
        b.fmt("-Dmode={s}", .{@tagName(mode)}),
        "--cache-dir",
        "../.zig-cache/template",
        "--prefix",
        "../zig-out/template",
        "--summary",
        "failures",
    });
    template_cmd.setCwd(b.path("template"));
    template_cmd.has_side_effects = true;
    const template_check: *Step = b.step(
        "template-check",
        "Build template/, the starter project, against this checkout",
    );
    template_check.dependOn(&template_cmd.step);

    // ---- Host-target unit tests for pure-CPU modules. ----------------
    // Pure CPU code (raymath, gestures, etc.) gets tested on the native
    // host so we get real ASAN and proper Zig test infrastructure.
    // Modules with browser dependencies are excluded.  `test_step`
    // itself was declared near the top so the example loop could
    // wire its typecheck objects to it.
    // (`native_target` was declared earlier alongside the wgpu-diff
    // step that also uses it.)
    // The modules and shaders every host-test module imports, built once (`wireHostTestImports`).
    const host_test_wiring: HostTestWiring = .{
        .engine_shaders = engine_shaders.items,
        .zimrmath_mod = zimrmath_mod,
        .shader_builtins_mod = shader_builtins_mod,
        .shader_interface_mod = shader_interface_mod,
        .zimrnum_mod = zimrnum_mod,
        .zimrrl_mod = zimrrl_mod,
        .build_opts = build_opts,
    };
    for (test_files) |tf| {
        const test_mod: *Module = b.createModule(.{
            .root_source_file = b.path(tf),
            .target = native_target,
            // -- ** ReleaseSafe, NOT Debug --
            //
            // Both keep every safety check - bounds, overflow, undefined reads - which is what
            // matters: the `deriv_cdof_dot` overflow that a ReleaseFast probe wrote straight
            // past was caught here on the first run.
            //
            // * AND IT IS MEASURABLY FASTER, which is not a luxury. Debug did not finish inside
            // a 285 s budget; ReleaseSafe completes in 235. A suite that times out gets re-run
            // rather than read, and a re-run costs more attention than the compile time saved.
            //
            // * IT ALSO REPORTS THINGS DEBUG NEVER REACHED. The first ReleaseSafe run surfaced
            // a leak the timing-out Debug run had never got far enough to print.
            .optimize = .ReleaseSafe,
            .pic = true,
        });
        // Every import `src/tests.zig` needs - one definition, shared with `test-windows`
        // (see `wireHostTestImports`).
        wireHostTestImports(b, test_mod, native_target, host_test_wiring);
        // -- ** `-Dtest-filter=<substring>` --
        //
        // Zig's test runner already supports a name filter; nothing was passing one through,
        // so the only way to run ONE test was to run all of them. Measured: the whole suite is
        // minutes, `robot_mpc` alone is 117 s (36 tests, several of them finite-difference
        // sweeps), and a single filtered test is seconds.
        //
        // * This does NOT shorten the COMPILE - the test binary still links every shader
        // module `src/tests.zig` transitively needs. It shortens the RUN. `-Dtest-fast` below
        // is the one that shortens the compile.
        // -- *** THE FAST TIER --
        //
        // One test artifact per shader-free module, each depending only on `zm` and
        // `build_options`. `robot.zig` measured 33 s this way against minutes for the full
        // root, because it links no shaders at all.
        //
        // * Kept as a LIST rather than folded into the big root, so adding a module here is a
        // one-line decision that says "this has no render dependency" - and the compiler
        // enforces it: a module that grows one stops building in this tier.
        const fast_test_roots = [_][]const u8{
            // *** `zimrmath.zig` FIRST, BECAUSE IT HAD NO GATE AT ALL. Every module and every
            // shader depends on it, its dedicated `math-test` step below is commented out, and
            // `refAllDecls` never reaches a test block - so THREE of its own tests stopped
            // compiling on the 1980 bump and nothing said a word. It costs one artifact.
            "src/zimrmath.zig",
            // *** `zimrnum.zig` - the numerics / statistics / deep-learning library. It belongs in THIS tier
            // by construction: its whole closure is `zm` + `kompute` + `std`, all shader-free.
            // Everything that touches a queue lives in `zimrnum_gpu.zig` instead, and that split
            // is what keeps a thousand numerical tests running in seconds. See
            // `src/notes/zimrnum_plan.md` section 3 - do not collapse the two files.
            "src/zimrnum.zig",
            // `zimrrl.zig` - the reinforcement-learning library, built on zimrnum. Its closure is `zm`, `zn` and
            // `std`, shader-free for the same reason, so it belongs to this tier; `zig build test-zimrrl` runs it
            // alone.
            "src/zimrrl.zig",
            // `spv_vulkan.zig` - the Vulkan host's SPIR-V reading, checking and legalizing (vulkan_port_plan_v2.md
            // 5.5). Std only, so it runs here on every platform; its tests carry real modules from the compiler.
            "src/spv_vulkan.zig",
            // `page_audio.zig` - the page's sound output, written for the bridge but kept apart to be tested: its
            // tests touch no JavaScript handle (the panel's text builder), so they run here; what does touch them runs
            // in Node (`audio-page-test`). `zig build test-page_audio` runs it alone.
            "src/page_audio.zig",
            // `gpu.zig` - the descriptor encoders, whose tests round-trip every blob through `gpu_abi.zig`'s decoders
            // (the Vulkan host's reading). Its closure (`wgpu.zig`, `shader_introspect.zig`, `shader_interface`) is
            // shader-free.
            "src/gpu.zig",
            // `sound.zig` - the mixer, its renderer, the instrument and the worklet's entry points. Its closure is
            // shader-free; `zig build test-sound` runs it alone, in seconds.
            "src/sound.zig",
            // `native_os.zig` - the native host's operating-system services: files by path, child programs, saved
            // values. Built here without the C library, so its two tests that need it (the environment, the Vulkan
            // loader) skip; the others need only `std.Io` and the system's own calls.
            "src/native_os.zig",
            // `codecs.zig` - the image and audio codecs: PNG, GIF, WAV, Ogg Vorbis. Every root here imports it already;
            // `zig build test-codecs` runs its own tests alone.
            "src/codecs.zig",
            "src/robot.zig",
            "src/robot_physics.zig",
            "src/robot_control.zig",
            "src/robot_mpc.zig",
            "src/robot_scene.zig",
            "src/urdf.zig",
            "src/mjcf.zig",
            "src/robot_urdf.zig",
            "src/robot_mjcf.zig",
            // ** THE TWO NUMERICS MODULES. Both are shader-free by construction - `zimrmath`
            // imports only `std`, and `zimrnum` imports `zm` and `kompute` and nothing else,
            // which is the constraint that keeps it in this tier.
            //
            // They were NOT here, so the only way to run 127 + 170 tests was a hand-typed
            // `zig test --dep zm --dep kompute -Mroot=... -Mzm=... -Mkompute=...`. A gate you
            // have to remember the command line for is a gate that gets skipped.
            // (These two were listed TWICE - once here and once at the top of this list - so
            // `test-fast` built and ran both of them twice over. Removed; the per-root steps
            // below would not even configure with a duplicate, which is how it surfaced.)
            // * The retarget integration test: real BVH -> real ragdoll. It belongs here
            // because `codecs.zig` needs only `zm` too - the whole animation-to-robot path is
            // shader-free, which is what makes it testable in seconds.
            "src/tests/ragdoll_bvh_test.zig",
            // The GPU sweep's CPU reference and the table that judges it. Its closure is
            // `zm` + `zn`, so it belongs in this tier: the row invariants - no duplicated
            // (kernel, input) pair, no negative tolerance, no out_len past the buffer - are
            // checkable with no device at all, and every one of them would make the device
            // comparison meaningless before it ever ran.
            "src/gpu/zn_conformance.zig",
            // ** The robot family's tests, compiled once and run once: it imports every robot
            // root above, and `test-fast` runs it INSTEAD of them (they keep their `zn-` steps).
            // Its import list is read back by `robotTestsMembers`, so it is the one list.
            "src/robot_tests.zig",
            // std's cli parser (vendored from Zig PR 36930) and the PR's own tests.
            "src/cli.zig",
            // Its front door, and the explanation it adds: each checked against the parser's own verdict.
            "src/command_line.zig",
            // Stage 0 of `src/notes/ragdoll_compare_plan.md`: the humanoid in maximal coordinates.
            "src/robot_maximal.zig",
            // The retargeted dance as target poses, and how well each engine follows them.
            "src/robot_dance.zig",
            // Humanoid locomotion as an RL environment: pose-offset actions on the Tracker.
            "src/robot_gym.zig",
            // The GPU learning kit's proofs on its CPU twin (zn_mlp imported by path, which a
            // file of the zimr module may not do - see the file's header).
            "src/gpu_learn_tests.zig",
            "src/kit_mlp.zig",
            "src/robot_track.zig",
            "src/robot_world.zig",
            "src/robot_supertrack.zig",
            "src/robot_latent.zig",
            "src/robot_geno.zig",
            "src/robot_lab.zig",
            "src/robot_latent_kit_tests.zig",
            "src/robot_track_resident_tests.zig",
            "src/robot_policy.zig",
            // The tracking task, decision by decision, and its n-step transitions.
            "src/robot_track_env.zig",
            "src/robot_ppo_track_tests.zig",
            "src/robot_mocap_tutorial.zig",
            // SuperTrack alone (a supervised world model + a policy through it) on the cartpole.
        };
        const robot_tests_members: []const []const u8 = robotTestsMembers(b);
        // `-Dfast-root=<file>`: that one file of the list alone - its tests checked without building every other root.
        const fast_root_description: []const u8 = "test-fast: run only this file of the fast list (its path as listed)";
        const fast_root_only: ?[]const u8 = b.option([]const u8, "fast-root", fast_root_description);
        for (fast_test_roots) |root| {
            if (fast_root_only) |only_root| {
                if (!eql(u8, root, only_root)) {
                    continue;
                }
            }
            // * The module ROOT is the file itself, so a test under `src/tests/` reaching a
            // sibling with `@import("../x.zig")` would escape the module path. Those tests
            // import through `src/` instead - see `ragdoll_bvh_test.zig`.
            // Tests run ReleaseSafe: optimised, with every bounds and overflow check still armed,
            // which is what a test is for. A TRAINING chunk is different - it is the same code,
            // already proven by those tests, run for hours - so under `-Dtrain-chunk` it builds
            // ReleaseFast. Zig's ReleaseFast does not relax floating point, so the numbers are
            // the same; only the checks are gone.
            const fast_optimize: std.builtin.OptimizeMode = if (train_chunk) .ReleaseFast else .ReleaseSafe;
            const fast_mod: *Module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = native_target,
                .optimize = fast_optimize,
            });
            // One module for the options, shared: two modules rooted at the same options file are a compile error.
            const fast_options_mod: *Module = build_opts.createModule();
            fast_mod.addImport("zm", zimrmath_mod);
            fast_mod.addImport("build_options", fast_options_mod);
            fast_mod.addImport("shader_interface", shader_interface_mod);
            // Named imports for tests that need siblings, so nothing reaches across the
            // module root with a relative path.
            const codecs_mod: *Module = b.createModule(.{
                .root_source_file = b.path("src/codecs.zig"),
                .target = native_target,
                .optimize = fast_optimize,
            });
            codecs_mod.addImport("zm", zimrmath_mod);
            codecs_mod.addImport("build_options", fast_options_mod);
            const robot_mod: *Module = b.createModule(.{
                .root_source_file = b.path("src/robot.zig"),
                .target = native_target,
                .optimize = fast_optimize,
            });
            robot_mod.addImport("zm", zimrmath_mod);
            robot_mod.addImport("build_options", fast_options_mod);
            fast_mod.addImport("codecs", codecs_mod);
            fast_mod.addImport("robot", robot_mod);
            // `zimrnum` authors its GPU kernels through the kompute DSL, so it needs the same
            // one shared kompute module every compute example uses.
            fast_mod.addImport("kompute", kompute_mod);
            // `src/gpu/zn_conformance.zig` holds the CPU reference the GPU sweep is judged
            // against, so it imports zimrnum itself. Offered to every fast root for the same
            // reason `codecs` and `robot` are: cheaper than a second list to keep in step.
            fast_mod.addImport("zn", zimrnum_mod);
            fast_mod.addImport("zrl", zimrrl_mod);
            const ft: *Compile = b.addTest(.{
                .root_module = fast_mod,
                // std's runner, plus `--shard=K/N` and `--timing` (see the file's header).
                .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .server },
            });
            if (test_filter) |f| {
                ft.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
            }
            // A root `src/robot_tests.zig` imports is compiled and run THERE, once, as part of
            // the union - adding it here as well would compile its closure a second time.
            var aggregated_elsewhere: bool = false;
            for (robot_tests_members) |member| {
                if (eql(u8, member, root)) {
                    aggregated_elsewhere = true;
                }
            }
            const stem: []const u8 = std.fs.path.stem(root);

            // -- ** ONE BINARY, `test_shards` PROCESSES --
            //
            // Each shard runs every `test_shards`th test of the same compiled binary, so the
            // compile is paid once and the run spreads over the cores. Only the robot family is
            // split - the union and its members' `zn-` binaries - because only its simulations run
            // long: measured Oct 11, zimrnum's whole binary is 4.6 s, zimrrl 0.8 s, zimrmath 0.1 s,
            // and sixteen processes of those would only fill the progress tree. A training chunk
            // stays one process: it is one long job writing to `train/`, not a suite to split.
            const robot_family: bool = aggregated_elsewhere or eql(u8, root, "src/robot_tests.zig");
            const shards: u32 = if (train_chunk or !robot_family) 1 else @max(1, test_shards);
            var fast_runs: ArrayList(*Run) = .empty;
            for (0..shards) |shard| {
                const fast_run: *Run = b.addRunArtifact(ft);
                if (shards > 1) {
                    fast_run.addArg(b.fmt("--shard={d}/{d}", .{ shard, shards }));
                    fast_run.setName(b.fmt("run test {s} {d}/{d}", .{ stem, shard, shards }));
                }
                if (test_timing) {
                    fast_run.addArg("--timing");
                }
                // A training chunk exists for what it writes to `train/`, which the build cache cannot see:
                // the same binary with the same arguments would otherwise be a cached, skipped run - no
                // output and no learning. With `-Dtrain-chunk`, every run happens.
                if (train_chunk) {
                    fast_run.has_side_effects = true;
                }
                if (!aggregated_elsewhere) {
                    test_fast_step.dependOn(&fast_run.step);
                }
                fast_runs.append(b.allocator, fast_run) catch @panic("OOM");
            }

            // -- A STEP PER ROOT, because `test-fast` rebuilds all six --
            //
            // Working on zimrnum means recompiling zimrmath, robot, codecs and physics
            // alongside it for no reason: 71-212 s against 43 s for the one module that
            // changed, 7 s with `-Dtest-filter`. The step name is `test-` and the file stem, so
            // `src/zimrnum.zig` gives `zig build test-zimrnum` and `src/sound.zig` `zig build test-sound`.
            //
            // * These are for ITERATION. `zig build test-fast` is what the gate runs, and it
            // is what catches a break in a module you did not think you had touched - which
            // has happened more than once this arc.
            const one_name: []const u8 = b.fmt("test-{s}", .{stem});
            const one_desc: []const u8 = b.fmt("Tests for {s} ALONE - the fast iteration loop", .{root});
            const one_step: *Step = b.step(one_name, one_desc);
            for (fast_runs.items) |fast_run| {
                one_step.dependOn(&fast_run.step);
            }
        }

        addVorbisReferenceStep(b, native_target, zimrmath_mod, zimrnum_mod);

        const t: *Compile = b.addTest(.{ .root_module = test_mod });
        if (test_filter) |f| {
            t.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
        }
        const run: *Run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    // The session layer's mesh test (`tests/net_mesh_test.zig`): Sessions bound to in-process fakes of the signaling
    // server and of WebRTC, pumped together with no browser and no network. It needs only the session layer and the
    // typed messages above it, given as modules, so it is a test of its own rather than one of `src/tests.zig`'s.
    const mesh_mod: *Module = b.createModule(.{
        .root_source_file = b.path("tests/net_mesh_test.zig"),
        .target = native_target,
        .optimize = .ReleaseSafe,
    });
    const mesh_imports = [_][2][]const u8{ .{ "net_core", "src/net_core.zig" }, .{ "net_typed", "src/net_typed.zig" } };
    for (mesh_imports) |import| {
        mesh_mod.addImport(import[0], b.createModule(.{
            .root_source_file = b.path(import[1]),
            .target = native_target,
            .optimize = .ReleaseSafe,
        }));
    }
    const mesh_test: *Compile = b.addTest(.{ .root_module = mesh_mod });
    if (test_filter) |f| {
        mesh_test.filters = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
    }
    test_step.dependOn(&b.addRunArtifact(mesh_test).step);

    // Native/host examples: software renderer, PNG output - zimr without
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
        }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triple
        for (test_files) |tf| {
            const t_mod: *Module = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = win_target,
                .optimize = .Debug,
                .pic = true,
            });
            // The host tests' own wiring, for this target - it had drifted to one import.
            wireHostTestImports(b, t_mod, win_target, host_test_wiring);
            const t: *Compile = b.addTest(.{ .root_module = t_mod });
            // Don't run - just compile.  The .exe wouldn't execute on
            // a non-Windows host without Wine, and the goal is to
            // catch compile errors anyway.
            test_windows_step.dependOn(&t.step);
        }
    }

    // ---- vk-abi-check: `src/vk.zig` against the official Vulkan headers (vulkan_port_plan_v2.md 5.8).
    // `vk.zig` is declared by hand; a wrong structure would make the driver read plausible garbage. This step
    // translates the headers with translate-c and compiles `tools/vk_abi_check.zig` against both, for
    // x86_64-windows-gnu: every comparison is comptime, so the compile IS the check. Development-only - it needs the
    // headers' include directory: `-Dvulkan-headers=<dir>`, or `VULKAN_SDK` (its `Include`). Nothing else in the
    // build ever needs the headers.
    const vk_abi_check_step: *Step = b.step(
        "vk-abi-check",
        "Compare src/vk.zig with the Vulkan headers (needs -Dvulkan-headers=<include dir> or VULKAN_SDK)",
    );
    const vulkan_headers_option: ?[]const u8 = b.option(
        []const u8,
        "vulkan-headers",
        "The Vulkan headers' include directory, for vk-abi-check",
    );
    const vulkan_sdk: ?[]const u8 = b.graph.environ_map.get("VULKAN_SDK");
    const vulkan_headers: ?[]const u8 = vulkan_headers_option orelse
        if (vulkan_sdk) |sdk| b.pathJoin(&.{ sdk, "Include" }) else null;
    if (vulkan_headers) |headers_directory| {
        const abi_target: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = "x86_64-windows-gnu",
        }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triple
        // The reference header: the core API, the few Windows types vulkan_win32.h names, then vulkan_win32.h -
        // what vulkan.h includes for Win32, without windows.h (whose intrinsics translate-c cannot read).
        const reference_files: *Step.WriteFile = b.addWriteFiles();
        const reference_header: LazyPath = reference_files.add("vk_abi_reference.h",
            \\#include <stdint.h>
            \\#include <stddef.h>
            \\#include <vulkan/vulkan_core.h>
            \\typedef struct HINSTANCE__ *HINSTANCE;
            \\typedef struct HWND__ *HWND;
            \\typedef struct HMONITOR__ *HMONITOR;
            \\typedef void *HANDLE;
            \\typedef unsigned long DWORD;
            \\typedef const wchar_t *LPCWSTR;
            \\typedef struct _SECURITY_ATTRIBUTES SECURITY_ATTRIBUTES;
            \\#define VK_USE_PLATFORM_WIN32_KHR 1
            \\#include <vulkan/vulkan_win32.h>
            \\
        );
        const reference_translation: *Step.TranslateC = b.addTranslateC(.{
            .root_source_file = reference_header,
            .target = abi_target,
            .optimize = .Debug,
            .link_libc = true,
        });
        reference_translation.addIncludePath(.{ .cwd_relative = headers_directory });
        const vk_module_for_check: *Module = b.createModule(.{
            .root_source_file = b.path("src/vk.zig"),
            .target = abi_target,
            .optimize = .Debug,
        });
        const abi_check: *Compile = b.addExecutable(.{
            .name = "vk_abi_check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/vk_abi_check.zig"),
                .target = abi_target,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "vk", .module = vk_module_for_check },
                    .{ .name = "vk_c", .module = reference_translation.createModule() },
                },
            }),
        });
        vk_abi_check_step.dependOn(&abi_check.step);
    } else {
        vk_abi_check_step.dependOn(&b.addFail(
            "vk-abi-check needs the Vulkan headers: -Dvulkan-headers=<include dir>, or set VULKAN_SDK",
        ).step);
    }

    // ---- win32-abi-check: `src/win32.zig` against the Windows headers Zig ships (MinGW-w64).
    // The twin of vk-abi-check, for the window layer's hand-declared user32/kernel32: windows.h is translated with
    // translate-c and `tools/win32_abi_check.zig` compiled against both, for x86_64-windows-gnu - every comparison
    // is comptime. It needs nothing outside the toolchain. The clang intrinsic headers windows.h pulls in are skipped
    // (their include guards defined): translate-c cannot read them, and no declaration checked here involves them.
    const win32_abi_check_step: *Step = b.step(
        "win32-abi-check",
        "Compare src/win32.zig with the Windows headers Zig ships (compile-only)",
    );
    {
        const abi_target: ResolvedTarget = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = "x86_64-windows-gnu",
        }) catch unreachable); // lint:off catch-suppression: hardcoded-valid triple
        const reference_files: *Step.WriteFile = b.addWriteFiles();
        const reference_header: LazyPath = reference_files.add("win32_abi_reference.h",
            \\#define WIN32_LEAN_AND_MEAN 1
            \\#define __X86INTRIN_H 1
            \\#define __IMMINTRIN_H 1
            \\#define __INTRIN_H 1
            \\#define _INTRIN_H_ 1
            \\#include <windows.h>
            \\
        );
        const reference_translation: *Step.TranslateC = b.addTranslateC(.{
            .root_source_file = reference_header,
            .target = abi_target,
            .optimize = .Debug,
            .link_libc = true,
        });
        const win32_module_for_check: *Module = b.createModule(.{
            .root_source_file = b.path("src/win32.zig"),
            .target = abi_target,
            .optimize = .Debug,
        });
        const abi_check: *Compile = b.addExecutable(.{
            .name = "win32_abi_check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/win32_abi_check.zig"),
                .target = abi_target,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "win32", .module = win32_module_for_check },
                    .{ .name = "win32_c", .module = reference_translation.createModule() },
                },
            }),
        });
        win32_abi_check_step.dependOn(&abi_check.step);
    }

    // ---- vk-hello-windows: stage S1 of the Vulkan port (vulkan_port_plan_v2.md section 6) - a Win32 window
    // cleared through Vulkan, with no engine. Cross-compiled here, run on Windows: `zig-out/windows/vk_hello.exe`.
    // Debug, so a panic prints a stack trace from the .pdb installed beside it.
    const vk_hello_step: *Step = b.step(
        "vk-hello-windows",
        "Build zig-out/windows/vk_hello.exe: a window that clears through Vulkan (stage S1)",
    );
    {
        const vk_hello_exe: *Compile = b.addExecutable(.{
            .name = "vk_hello",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vk_hello.zig"),
                .target = windows_target,
                .optimize = .Debug,
                .imports = &.{.{ .name = "zm", .module = zimrmath_mod }},
            }),
        });
        const vk_hello_install: *Step.InstallArtifact = b.addInstallArtifact(vk_hello_exe, .{
            .dest_dir = .{ .override = .{ .custom = "windows" } },
        });
        vk_hello_step.dependOn(&vk_hello_install.step);
    }

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
    // **LOCAL ONLY - `zig build docs`, never the default install or `dist`.**
    // The bundle's sources.tar is the whole source tree (~100 MB), over
    // GitHub's 100 MB per-file limit, so shipping it got the pages push
    // rejected.  It is its own step, and `dist-copy` (tools/buildaux.zig)
    // skips docs/ so a stale local bundle can't leak into prebuilt/.
    // **Install location is zig-out/web/docs/**, not zig-out/docs/, so the
    // dev server serves it: `zig build docs`, then `zig build serve-only`
    // and open http://localhost:8080/docs/.  The bundle uses fetch() for
    // source viewing, so it must be served over HTTP - opening index.html
    // via file:// works for navigation but the source-view panel won't load.
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

    const docs_step: *Step = b.step("docs", "Generate API docs in zig-out/web/docs/ (local only, not in dist)");
    docs_step.dependOn(&install_docs.step);

    // ---- `zig build dist` -- mirror zig-out/web/ into prebuilt/.
    // `prebuilt/` is gitignored on main; `zig build publish` (below) pushes
    // its contents to the orphan `pages` branch that GitHub Pages serves at
    // https://simonclavet.github.io/zimr/.  Pair with `-Dmode=release` for
    // ReleaseSmall wasm.  The API docs (`zig build docs`) are deliberately
    // left out - see the docs block above.
    const dist_step: *Step = b.step("dist", "Refresh prebuilt/ from zig-out/web/ for distribution");
    // A pure-Zig recursive copy in the buildaux CLI (the old custom makeFn
    // Step is gone in 0.17).  Avoids the cross-shell quoting/exit-code mess
    // of xcopy/cp wrappers and works the same on Windows, Linux and macOS.
    // It also writes `prebuilt/.nojekyll` so GitHub Pages skips Jekyll.
    // Depend on web_examples_step (not just b.getInstallStep()) so the
    // mirror always has every wasm.
    const dist_copy: *Run = b.addRunArtifact(buildaux_exe);
    dist_copy.addArg("dist-copy");
    // Pinned to the build root: `publish` reads the prebuilt/ this writes.
    dist_copy.setCwd(b.path("."));
    dist_copy.step.dependOn(web_examples_step);
    dist_step.dependOn(&dist_copy.step);

    // ---- `zig build publish -Dmode=release` -- dist, then force-push prebuilt/ to `pages`.
    // Replaces release.bat / release.sh (`buildaux publish-pages`).  main stays
    // source-only: the CONTENTS of prebuilt/ become a single parentless commit
    // that replaces the `pages` branch on `origin`, so history never accumulates
    // and the gallery costs one copy on the remote.  The working tree, the real
    // index and main are never touched; committing source to main is separate.
    // GitHub Pages serves that branch (Settings -> Pages -> Deploy from a branch
    // -> `pages`, `/ (root)`) at https://simonclavet.github.io/zimr/.
    // GitHub limits: 100 MB per file (warns above 50 MB), 1 GB per Pages site -
    // why `dist` leaves the ~100 MB docs bundle out.
    // A debug build must never ship, and a step cannot change `-Dmode` (it is
    // fixed at configure time), so without a release mode the step fails before
    // compiling anything.  Only reachable by name - it pushes to a remote.
    const publish_step: *Step = b.step(
        "publish",
        "Build dist, then force-push prebuilt/ to the `pages` branch (needs -Dmode=release)",
    );
    if (mode == .debug) {
        publish_step.dependOn(&b.addFail(
            "publish ships ReleaseSmall wasm: pass -Dmode=release (or -Dmode=ship)",
        ).step);
    } else {
        const publish_run: *Run = b.addRunArtifact(buildaux_exe);
        publish_run.addArgs(&.{ "publish-pages", "origin" });
        publish_run.setCwd(b.path("."));
        // Side effects => inherited stdio: git's progress and credential prompts reach the terminal.
        publish_run.has_side_effects = true;
        publish_run.step.dependOn(dist_step);
        publish_step.dependOn(&publish_run.step);
    }

    // ============================================================================
    // `zig build lint` - AST-based style linter.
    // ============================================================================
    // Encodes the mechanical rules from `src/notes/claude.md` as
    // checks runnable per-file or on the whole codebase.  Spec
    // in `src/notes/lint-zimr-plan.md`.
    // Default scan (no args): every *.zig under the scan roots below.
    // Specific files: `-Dlint-files=a.zig,b.zig`.
    // Mode: hard gate (turn 379).  `zig build lint` exits non-zero
    // on any issue - the layout included, as the `zig-fmt` rule - and
    // `zig build lint-check` adds the template's layout, for use as a CI gate.
    //
    // Every rule is opt-in (`LintRule`); zimr turns its own set on through
    // `zimr_lint_rules` - the same argument on the check and on the fix below,
    // so the two agree on what a violation is. `zimrlint --list-rules` prints the catalog.
    const lint_enable: []const u8 = lintEnableArg(b, &zimr_lint_rules);
    const lint_run: *Run = b.addRunArtifact(zimrlint_exe);
    lint_run.addArg(lint_enable);
    // Every fixable finding names the step that fixes it, and the summary prints it on a line of its own.
    lint_run.addArgs(&.{ "--fix-command", "zig build lint-fix" });
    // -- THE LINT RATCHET --
    //
    // `childNodes` returned no children for `.assign` and `.while_cont`, so every rule in
    // zimrlint silently skipped assignment right-hand sides and `while (i < n) : (i += 1)`
    // bodies. Fixing the walk exposed 594 pre-existing violations: the tree was never clean, the
    // walker was blind, and the hard gate's "after all rules cleared" was true only of what it
    // could see.
    //
    // `tools/lint_baseline.tsv` grandfathers those by (file, rule) COUNT. Anything above the
    // recorded count fails, so new code is held to every rule from today while the backlog stays
    // visible in one file and shrinks by deleting lines. Regenerate deliberately, never
    // casually: `zimrlint --baseline tools/lint_baseline.tsv --write-baseline <files...>`.
    lint_run.addArg("--baseline");
    lint_run.addFileArg(b.path("tools/lint_baseline.tsv"));

    // The `lint-fix` step's lint: the same files, rules and baseline, in `--fix` mode - the ONE run that rewrites
    // sources, and only when `zig build lint-fix` is asked for by name. Each file it rewrites is written once, laid out
    // as `zig fmt` lays it out (`zig-fmt` is one of the rules), and its diff is printed the moment it is written.
    const lint_fix: *Run = b.addRunArtifact(zimrlint_exe);
    lint_fix.addArg(lint_enable);
    lint_fix.addArg("--baseline");
    lint_fix.addFileArg(b.path("tools/lint_baseline.tsv"));
    // `zig build fmt`: the layout alone - `zig-fmt` by itself, in `--fix` mode - over the same files.
    const fmt_fix: *Run = b.addRunArtifact(zimrlint_exe);
    fmt_fix.addArgs(&.{ "--enable=zig-fmt", "--fix" });
    // The coverage guard (L4d): every tracked node of every linted file must be walked - a node the walk misses is
    // code no rule can see. `--coverage` lists the outermost unwalked nodes and fails. The same files as `lint`; the
    // gate runs it (one more walk of the whole tree), `tripwires` does not.
    const lint_coverage: *Run = b.addRunArtifact(zimrlint_exe);
    lint_coverage.addArg("--coverage");

    // Smoke check: compile `tests/fixture_fs.zig` end-to-end and
    // assert the output begins with `#version 300 es`.  Wired into
    // the default `test` step; runs every time tests run.  The
    // file exercises a representative subset of the unified `zm`
    // module (Vec2/Vec3/Vec, swizzles, scalar + vector generics,
    // location decorator), so a regression in either zm or the
    // build pipeline trips this gate.
    //
    // Implementation note: pure-Zig step (no `sh -c`).  The previous
    // version called `sh -c "head -1 ... | grep -q ..."` which works in
    // git-bash / WSL but blows up in a plain Windows cmd.exe with
    // "failed to spawn sh: FileNotFound".  Same problem `distCopyMake`
    // above solves for the dist copy - we follow that pattern here.
    // (GLSL fixture-header check removed - the GLSL path is retiring; the WGSL
    // fixture check below is the live regression gate for the shader pipeline.)

    // Parallel WGSL fixture check.  Validates that the new
    // `addShaderWgsl` build step runs end-to-end (spv2wgsl tool
    // exists, accepts the opt'd SPIR-V, produces non-empty WGSL).
    // The fixture is the same `tests/fixture_fs.zig` as the GLSL
    // check - so we know one Zig source compiles to BOTH .glsl
    // (via spirv-cross) and .wgsl (via spv2wgsl).  See
    // `src/notes/webgpu-migration-plan.md` section 3 Phase B.
    const fixture_wgsl: LazyPath = shader_pipeline.addShaderWgsl(
        b.path("tests/fixture_fs.zig"),
        .{},
    );
    const fixture_wgsl_check: *Run = b.addRunArtifact(buildaux_exe);
    fixture_wgsl_check.addArg("check-wgsl-clean");
    fixture_wgsl_check.addFileArg(fixture_wgsl);
    fixture_wgsl_check.expectExitCode(0);
    test_step.dependOn(&fixture_wgsl_check.step);
    // `tripwires` (declared earlier) also depends on this; wire here
    // because the step exists above and the check is constructed here.
    tripwires_step.dependOn(&fixture_wgsl_check.step);

    // (GLSL math-pipeline check removed - the GLSL path is retiring. zm is verified
    // through the WGSL/compute path (turn ~979) and host math tests instead.)
    // Default scan: every src/*.zig file.  To lint a specific subset,
    // pass `-Dlint-files=a.zig,b.zig` (a build option - observable by
    // the configurer).  The old `-- foo.zig` positional override is
    // gone: the configurer/maker split made passthru args unobservable
    // to build.zig, so file targeting moved to an option while flags
    // still flow through addPassthruArgs.  See zig17_migration.md B3.
    const lint_files_opt: ?[]const u8 = b.option(
        []const u8,
        "lint-files",
        "Comma-separated Zig files to lint instead of the default full-tree scan.",
    );
    // -- *** LINT AND FMT ARE CHECKED, NEVER APPLIED BY A BUILD, AND NEVER IN A COMPILE'S WAY (Simon, Oct 18) --
    //
    // No build writes a source file. `lint` and `lint-check` CHECK - the layout too, as the `zig-fmt` rule - and
    // list every finding; a fixable one ends `autofix: zig build lint-fix`, and the summary prints that command on a
    // line of its own. `zig build lint-fix` is the one step that rewrites: the linter's autofixes and `zig fmt`'s
    // layout, then the tutorials' generated code blocks - each file's diff printed the moment it is written. It was
    // `zig build fix` until Oct 25: a bare `fix` read as fixing whatever failed, compile errors included.
    //
    // Where style is required - every app's step, `all-examples`, `dist`, `tripwires`, and in `-Dmode=ship` the
    // install - the step depends on `lint-check`, which runs BESIDE the compile, not before it: a compile error and
    // a lint finding are reported by the same build, and neither hides the other.
    //
    // Gone with it, Oct 18: `-Dautofix`, which rewrote files in every build (one reformatted a file between reading
    // it and an exact-text edit of it; another deleted a declaration whose first use had not been written yet), and
    // `-Dgate`, which put the lint ahead of every wasm compile, so a line-length finding hid the type error behind it.
    const has_file_arg: bool = lint_files_opt != null;
    // Dependency-safe: this scan walks zimr's own tree via cwd-relative paths,
    // which only resolve when zimr is the ROOT project. When zimr is consumed as
    // a package (b.pkg_hash non-empty), cwd is the consumer's root, so skip it -
    // a consumer never lints zimr's sources, and the lint steps just stay empty.
    if (!has_file_arg and b.pkg_hash.len == 0) {
        const io: Io = b.graph.io;
        const cwd: Io.Dir = .cwd();
        // Scan RECURSIVELY: every *.zig under src/, examples/,
        // tools/, and webtests/, plus build.zig.  The walk descends into
        // subdirectories - this is deliberate.  An earlier
        // non-recursive `dir.iterate()` only saw top-level src/*.zig
        // and SILENTLY skipped subdir files (src/spv2wgsl/*.zig,
        // src/shaders/*.zig, ...), letting hundreds of lint violations
        // accumulate there unseen.  Recursion closes that hole.
        //
        // tools/ was a SECOND blind spot: it holds first-class authored
        // code (the linter itself, the transpiler CLIs
        // `spv2wgsl`/`spv2wgsl_check`, the extern-gen tool, and
        // tools/build.zig) that was never linted
        // because the walk only covered src/ and examples/.  It is now
        // a scan root.
        //
        // Excluded subtrees (path-prefix match on the walk-relative
        // path): `notes/staging/` (vendored upstream code) and
        // `c2js_cases/` under tools/ (matched via `firstSegmentIs`, which
        // is separator-agnostic so it also holds on Windows) - the c2js
        // transpiler corpus is ARBITRARY Zig by design (not zimr's linted
        // subset), exactly
        // like the top-level `tests/` shader fixtures (which are already
        // excluded simply by not being a scan root). NOTE: `src/tests/`
        // IS now linted - the host unit-test suite is first-class zimr
        // code - so only the deliberately-foreign test CORPORA stay
        // ungated.
        //
        // Under tools/ specifically we must NOT descend into the
        // bundled toolchains / caches / prebuilt binaries - those are
        // thousands of third-party stdlib .zig files that are not ours
        // to style-gate (see `tools_skip_prefix` below).
        //
        // Finally, `deletion_skip` lists individual authored files that
        // are SCHEDULED FOR DELETION and therefore not worth linting or
        // "fixing" - per the fix-on-notice exception in claude.md, a
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
        // out of the error switch below - `continue` targeting an inline loop
        // from inside a runtime switch is a comptime-control-flow error. `root`
        // is only ever used at runtime here (eql / b.fmt), so nothing needs the
        // unroll.
        const scan_roots = [_][]const u8{ "src", "examples", "tools", "webtests", "scripts" };
        for (scan_roots) |root| {
            var dir: Io.Dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
                // A scan root that isn't present in this checkout (e.g.
                // `scripts/`, whose Python helpers were ported to `tools/`)
                // simply has nothing to lint - skip it rather than aborting
                // the whole configure.
                error.FileNotFound => continue,
                else => @panic("cannot open scan dir"),
            };
            defer dir.close(io);
            var walker: Io.Dir.Walker = dir.walk(b.allocator) catch @panic("walk init");
            defer walker.deinit();
            while (walker.next(io) catch @panic("dir walk")) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                if (!endsWith(u8, entry.basename, ".zig")) {
                    continue;
                }
                // std's cli parser, vendored from Zig PR 36930 (`src/cli.zig`, `src/cli/`): upstream's code in
                // upstream's style, kept verbatim so it can be deleted the day std has it - not zimr's to restyle.
                const vendored_cli: bool = eql(u8, entry.path, "cli.zig") or firstSegmentIs(entry.path, "cli");
                if (eql(u8, root, "src") and vendored_cli) {
                    continue;
                }
                // entry.path is relative to `root` (e.g. "spv2wgsl/ir.zig").
                // (src/tests/ is intentionally NOT skipped - see the policy
                // note above; the top-level tests/ corpus is excluded by not
                // being a scan root.)
                if (indexOf(u8, entry.path, "notes/staging/") != null) {
                    continue;
                }
                // webtests/external_project/ stands for an OUTSIDE project: it is held
                // to the rules its own `Project` lint config enables (its `check`,
                // run by `external-check`), not to zimr's house rules.
                if (eql(u8, root, "webtests") and firstSegmentIs(entry.path, "external_project")) {
                    continue;
                }
                // Skip the bundled toolchains / caches under tools/.
                if (eql(u8, root, "tools")) {
                    // c2js transpiler corpus - arbitrary Zig by design, not
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
                lint_fix.addFileArg(b.path(path));
                fmt_fix.addFileArg(b.path(path));
                lint_coverage.addFileArg(b.path(path));
            }
        }
        // Top-level build.zig is included.  It uses build-helper
        // aliases (Step, Module, etc.) at the top of the file to
        // keep the type annotations short - see the alias block
        // near the top of build.zig and src/shader_codegen.zig.
        lint_run.addFileArg(b.path("build.zig"));
        lint_fix.addFileArg(b.path("build.zig"));
        fmt_fix.addFileArg(b.path("build.zig"));
        lint_coverage.addFileArg(b.path("build.zig"));
    }
    // Explicit file subset (from -Dlint-files) when the default scan
    // was skipped above.
    if (lint_files_opt) |csv| {
        var it = std.mem.tokenizeScalar(u8, csv, ',');
        while (it.next()) |f| {
            lint_run.addFileArg(b.path(f));
            lint_fix.addFileArg(b.path(f));
            fmt_fix.addFileArg(b.path(f));
            lint_coverage.addFileArg(b.path(f));
        }
    }
    // Forward any remaining flags (e.g. `-- --enable=decl-order`) to the
    // lint exe.  Passthru args are no longer observable by build.zig
    // (configurer/maker split), which is fine: only the exe parses them.
    lint_run.addPassthruArgs();
    lint_fix.addPassthruArgs();
    lint_fix.addArg("--fix");
    const lint_step: *Step = b.step("lint", "Run AST-based style linter on Zig sources");
    lint_step.dependOn(&lint_run.step);
    const lint_coverage_step: *Step = b.step(
        "lint-coverage",
        "Fail if the linter's walk misses any tracked node of the linted sources",
    );
    lint_coverage_step.dependOn(&lint_coverage.step);

    // ============================================================================
    // `zig build fmt` / `zig build lint-check` - the layout, and the style gate
    // ============================================================================
    // `zig-fmt` is a lint rule, so the layout is checked with every other rule and its finding names the command
    // that fixes it - `zig fmt --check` named a file and said nothing more. `zig build fmt` lays the files out and
    // does nothing else, printing each diff; `zig build lint-fix` does that and every other autofix. `lint-check` is
    // the style gate the artifact steps and `tripwires` depend on.
    //
    // The template project is laid out with the repository - its build.zig and every file under template/src, not
    // template/ whole (a `zig build` inside it leaves .zig-cache/ and zig-out/ there) - though its own `Project` lint
    // config holds it to the rules; here it is held to `zig-fmt` alone. A template layout slip fails `tripwires`
    // without blocking an example build. Only in zimr's own checkout: a project depending on zimr has no template/.
    var template_files: ArrayList(LazyPath) = .empty;
    if (b.pkg_hash.len == 0) {
        template_files.append(b.allocator, b.path("template/build.zig")) catch @panic("OOM");
        template_files.appendSlice(b.allocator, zigFilesUnder(b, &.{"template/src"})) catch @panic("OOM");
    }
    const template_fmt_check: *Run = b.addRunArtifact(zimrlint_exe);
    template_fmt_check.addArgs(&.{ "--enable=zig-fmt", "--fix-command", "zig build lint-fix" });
    const template_fmt_fix: *Run = b.addRunArtifact(zimrlint_exe);
    template_fmt_fix.addArgs(&.{ "--enable=zig-fmt", "--fix" });
    for (template_files.items) |file| {
        template_fmt_check.addFileArg(file);
        template_fmt_fix.addFileArg(file);
        fmt_fix.addFileArg(file);
    }
    const fmt_step: *Step = b.step("fmt", "Lay out the linted files and template/ as zig fmt does, each diff printed");
    fmt_step.dependOn(&fmt_fix.step);

    const lint_check_step: *Step = b.step("lint-check", "Style gate: every lint rule, the layout (zig-fmt) included");
    lint_check_step.dependOn(&lint_run.step);
    lint_check_step.dependOn(&template_fmt_check.step);

    // -- *** `zig build gate` - EVERYTHING, so nobody has to remember the list ---------
    //
    // Every turn of the zimrnum port ran the same six things by hand: `lint`, `check`,
    // `fmt --check`, the zimrnum tests, the zimrmath tests, and two smokes. The two test
    // suites had no build step at all, so running them meant typing
    //
    //     zig test -OReleaseSafe --dep zm --dep kompute -Mroot=src/zimrnum.zig ...
    //
    // from memory. **A gate you have to remember the command line for is a gate that gets
    // skipped**, and the one time it was skipped the reference table had drifted.
    //
    // `test-fast` now includes both numerics modules, so this step is their home too.
    const gate_step: *Step = b.step(
        "gate",
        "The full per-turn gate: lint + fmt + tripwires + fast tests + consumer builds. Run this before shipping.",
    );
    gate_step.dependOn(lint_check_step);
    gate_step.dependOn(lint_coverage_step);
    gate_step.dependOn(lint_test_step);
    gate_step.dependOn(test_fast_step);
    gate_step.dependOn(tripwires_step);
    // The audio worklet's program against a real mixer's commands: nothing in a browser-free sandbox runs it otherwise.
    gate_step.dependOn(audio_worklet_test_step);
    // The page's side of it, against a stand-in browser as strict as Chrome.
    gate_step.dependOn(audio_page_test_step);
    // c2js, which turns the page's own code - the bridge, page audio, the worklet's program - into JavaScript, against
    // its corpus: every case agrees with the same Zig compiled natively. A change in the C that Zig emits can break the
    // transpiler in forms the page's own tests never meet; the corpus holds those forms. About 100 s.
    gate_step.dependOn(c2js_diff_step);
    // The launcher compiled for every platform: the web, Windows, and as objects for Linux, macOS and Android on the
    // unwritten platform - so that code compiling only for one system fails on the day it is written.
    gate_step.dependOn(platforms_check_step);
    // The two projects that depend on this checkout the way a user's does. Neither is in
    // `tripwires` (about a minute cold, too slow for the turn loop), and a consumer build no
    // aggregate step ran is how zimr_template drifted.
    gate_step.dependOn(external_check);
    gate_step.dependOn(template_check);
    // The tutorials can't drift from the code. First their code blocks are checked against the source - regenerated
    // only by `zig build lint-fix` or `zig build doc-folds`, which print each page's diff - then every quoted line is
    // checked to exist in the source (doc-sync).
    const gate_doc_folds: *Run = b.addRunArtifact(doc_folds_exe);
    gate_doc_folds.setCwd(b.path("."));
    gate_doc_folds.has_side_effects = true;
    gate_doc_folds.addArg("--check");
    gate_doc_folds.addArgs(&doc_folds_pages);
    // `tripwires` too, which runs every turn: a fold once sat stale for days while only `gate` looked. Always run,
    // since the sources the folds quote are files the build cannot see.
    const check_doc_folds: *Run = b.addRunArtifact(doc_folds_exe);
    check_doc_folds.setCwd(b.path("."));
    check_doc_folds.has_side_effects = true;
    check_doc_folds.addArg("--check");
    check_doc_folds.addArgs(&doc_folds_pages);
    tripwires_step.dependOn(&check_doc_folds.step);
    const gate_doc_sync: *Run = b.addRunArtifact(doc_sync_exe);
    gate_doc_sync.setCwd(b.path("."));
    gate_doc_sync.has_side_effects = true;
    gate_doc_sync.step.dependOn(&gate_doc_folds.step);
    gate_step.dependOn(&gate_doc_sync.step);
    // NOT the smokes: `smoke-test` needs `-Dfocus=<example>` and there is no "all" value, so
    // they stay one command per example - `zig build smoke-test -Dfocus=zimrnum_field`. The
    // full audit including them is `tier-a-check`; this step is the fast one that should run
    // before every ship.

    // The graph walk: every top-level step's transitive dependencies, once each, to collect what no step names
    // directly - the wasm installs `all-examples` and `test` build, and the pages beside them. No compile waits on
    // the lint (Oct 18): the steps that require a clean tree depend on `lint-check` beside their compile, wired
    // after this walk, so a compile error and a lint finding come out of one build.
    {
        var seen: AutoHashMapUnmanaged(*Step, void) = .empty;
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
            // `all-examples` must build the WHOLE gallery (its stated job -
            // serve / dist / a full-tree compile check all hang off it).
            // Nothing wired the per-example installs into it, so it silently
            // built only the runtime.  Pick up every wasm example's install
            // artifact here; the wasm32 filter keeps native build tools out.
            if (s.tag == .install_artifact) {
                const ia: *InstallArtifact = s.cast(InstallArtifact).?;
                if (ia.artifact.rootModuleTarget().cpu.arch == .wasm32) {
                    web_examples_step.dependOn(s);
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
            // above misses them - the gallery's clickable pages would never
            // build. Grab every install_file under web/<name>/ so `all-examples`
            // (and thus serve / dist) assembles the full clickable tree.
            if (s.tag == .install_file) {
                const inf: *InstallFile = s.cast(InstallFile).?;
                switch (inf.dir) {
                    .custom => |c| {
                        if (startsWith(u8, c, "web/")) {
                            web_examples_step.dependOn(s);
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
    const test_web_examples_step: *Step = b.step(
        "test-all-examples",
        "Host unit tests + build every example wasm (exhaustive)",
    );
    test_web_examples_step.dependOn(test_step);
    test_web_examples_step.dependOn(web_examples_step);

    // Bare `zig build` (install) is mostly a JS bundle + static files with no
    // Compile of its own, so depend on the gates directly too - otherwise a
    // compile-less install would skip the style check entirely.
    // A ship build's bare `zig build` holds the tree to the style too (its artifacts already do, below).
    if (mode == .ship) {
        b.getInstallStep().dependOn(lint_check_step);
    }
    // ARTIFACTS REQUIRE A CLEAN TREE: every app's step, `all-examples`, `dist` and `tripwires` depend on the
    // non-mutating `lint-check` (every rule, the layout included). The compile runs beside it, never after it; the
    // step fails unless both pass, and every fixable finding names `zig build lint-fix`.
    for (artifact_step_names.items) |name| {
        b.top_level_steps.get(name).?.step.dependOn(lint_check_step);
    }
    for (b.top_level_steps.values()) |tls| {
        const name: []const u8 = tls.step.name;
        if (eql(u8, name, "dist") or eql(u8, name, "tripwires")) {
            tls.step.dependOn(lint_check_step);
        }
    }
    // `zig build lint-fix` - the ONE step that rewrites sources, and the command every fixable finding names: the
    // linter's autofixes and `zig fmt`'s layout (`zig-fmt`), the template's layout, then the tutorials' code blocks
    // regenerated from the fixed source. Every rewritten file's diff is printed the moment it is written, and whatever
    // is left for a person is listed under its file.
    const fix_doc_folds: *Run = b.addRunArtifact(doc_folds_exe);
    fix_doc_folds.setCwd(b.path("."));
    fix_doc_folds.has_side_effects = true;
    fix_doc_folds.addArg("--fix");
    fix_doc_folds.addArgs(&doc_folds_pages);
    fix_doc_folds.step.dependOn(&lint_fix.step);
    const lint_fix_step: *Step = b.step(
        "lint-fix",
        "Rewrite sources: lint autofixes, zig fmt layout, tutorial code blocks - every change printed as a diff",
    );
    lint_fix_step.dependOn(&lint_fix.step);
    lint_fix_step.dependOn(&template_fmt_fix.step);
    lint_fix_step.dependOn(&fix_doc_folds.step);

    // LAST, once every step exists: `zig build tools` compiles every tool, and `gate` includes it.
    gateEveryTool(b, gate_step);
    // And after that walk, so `tools` never picks up a compile-only twin: `zig build check`, what ZLS runs on save.
    addCompileCheck(b, smoke_focus);
}
