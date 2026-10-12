// build.zig - an application project built on zimr.
//
//   zig build                      -- build every app (debug) for this machine's platform - Windows, natively;
//                                     on a machine zimr has no platform for, name one with -Dplatform
//   zig build -Dplatform=web       -- every app for the browser: zig-out/web/<name>/ (served) and
//                                     zig-out/standalone/<name>.html (one file, opens from disk)
//   zig build -Dplatform=windows   -- every app as a Windows program: zig-out/windows/<name>.exe
//   zig build -Dmode=release       -- ReleaseSmall with zimr's asserts kept (share this one)
//   zig build -Dmode=ship          -- ReleaseSmall, asserts and profiler stripped
//   zig build serve -Dplatform=web -- build everything for the web, serve it on http://127.0.0.1:8081/
//   zig build <name>               -- build one app for the platform
//   zig build run-<name>           -- build one app, then run it: the program, or with -Dplatform=web its page in
//                                     a browser (a server already running reloads the tabs showing it instead)
//   zig build run                  -- run-<name> of the first app added below
//   zig build test                -- pure-CPU host unit tests (see below)
//   zig build lint                -- zimr's linter over src/ (rules: see `.lint` below)
//   zig build fix                 -- the linter's autofixes over src/, then zig fmt
//   zig build check               -- lint + host tests + every app, and the editor configs current
//   zig build editor-configs      -- write .vscode/ and .zed/: a debug config for every app, on the web and as a
//                                    Windows program, each with the task that builds the app first
//   zig build zbuild              -- install zig-out/bin/zbuild: `zig-out/bin/zbuild <step>` runs `zig build <step>`
//                                    and, when it fails, ends with only what failed
//
// `zimr.Project` supplies all of those steps, the `-Dmode` option, the browser
// runtime (zig-out/web/zimr.js), the dev server, and copies public/ into
// zig-out/web/ as the gallery.
//
// Adding an app:
//   1. Drop `src/myname.zig` next to the others. It declares
//      `pub const app: z.AppSpec(State) = .{ ... }` and nothing else - or, like myproject3,
//      its own `pub fn main` (then add `.own_frame = true` to its row).
//   2. Add a `project.addApp` call below.
//   3. Add a card to public/index.html linking to `myname/`.
//   4. Run `zig build editor-configs`: .vscode/ and .zed/ gain the app's debug configs.
//
// Beyond a plain app, `addApp` takes (see `Project.App` in zimr's build.zig):
//   .shaders = &.{ "wave_fs", ... }   typed Zig shaders from src/shaders/: wave_fs.zig beside
//                                     wave_fs_io.zig; the app embeds "wave_fs.wgsl"
//   .compute_kernels = &.{ ... }      GPU compute (`kompute`), kernels beside the app's source
//   .job_kernels = true               Web Worker jobs (`zimr.jobs`) from <app dir>/kernels.zig
//   .engine_wgsl = true               embed zimr's engine shaders ("pbr_fs.wgsl", ...)
//   .own_frame = true                 the app's file is the program's root: its own `main`, its own
//                                     frames (src/myproject3.zig; README "Owning your main")
// An app with kernels gets its own directory: src/myname/myname.zig is found by name too.
// Assets and extra imports go on the module `addApp` returns:
//   const game = project.addApp(.{ .name = "game", .title = "Game" });
//   game.module.addAnonymousImport("level1.png", .{ .root_source_file = b.path("assets/level1.png") });
// and code several apps share is a module of its own: `project.addModule(b.path(...))`.
//
// Adding tests:
//   `zig build test` runs every file passed to `project.addTest`. A test cannot live
//   in a file that imports zimr (zimr only builds for the browser), so keep pure-CPU
//   logic in its own module and test that. `zm` and `zn` are importable there.

const std = @import("std");
const zimr = @import("zimr");

pub fn build(b: *std.Build) void {
    const project: *zimr.Project = .init(b, .{
        // zimr's own gallery serves on 8080, so this one can run beside it.
        .port = "8081",
        // .vscode/ and .zed/ hold a debug config for every app, written by `zig build editor-configs` as zimr writes
        // its own; `check` fails when an app was added without rerunning it.
        .editor_configs = true,
        // zimr's linter over src/: `zig build lint`, and part of `check` and of every app's step. Every rule is
        // opt-in, and this project enables them all, as zimr does for itself: in zimr a lint finding is a compile
        // error, and an explained `// lint:off <rule>: <why>` is how code says a rule does not apply where it
        // stands. When zimr gains a rule, add it here (`zig build lint -- --list-rules` prints them all).
        // The list is the configuration - each rule by name, its title beside it.
        .lint = .{
            .enable = &.{
                .import_cycle, // files must not import each other, directly or through others
                .raw_pass_state_bind, // bind pipeline/bind-groups through the PassState cache
                .parse_error, // file failed to parse, AST checks skipped
                .fn_args_multiline, // Rule 1 - fn signatures: 5+ args multiline; 3-4 args one-line only if <=90 cols
                .untyped_local, // Rule 2 - locals: write the type even when Zig can deduce it
                .branch_braces, // Rule 3 - braces required on every if/else/while/for body
                .array_mult, // Rule 5 - array repetition: use @splat, not `**`
                .module_var, // Rule 9 - no module-level mutable globals
                .depth_format, // 3D render needs a depth attachment
                .line_length, // Rule 10 - lines under 120 columns
                .ascii_comments, // Comments are ASCII
                .ascii_test_names, // Test names are ASCII
                .named_struct_init, // Rule 15 - use `.{...}` when the LHS already declares the type
                .turn_in_radian_call, // a pi or tau inside a trig argument means you wanted turns
                .std_math, // no std.math outside zimrmath (GPU-portability)
                .std_debug_assert, // no std.debug.assert outside tools
                .import_at_top, // std/builtin/root imports belong at file scope
                .clamp_pattern, // Bonus rule - prefer zm.clamp over @min(@max())
                .as_round, // Rule - no @as(T, @trunc(x)); use bare builtin or zm.* helper
                .redundant_cast, // Rule - drop the cast helper when the decl already gives the type
                .int_from_float, // Rule - use @trunc/@floor/@round directly, not @intFromFloat
                .reserved_math_names, // Rule - reserved math vocabulary: don't shadow the zm.* core
                .prefer_vec, // Rule - prefer `Vec` over the verbose `@Vector(4, f32)`
                .anon_return, // name the struct a function returns
                .shader_inline_fn, // Shader rule - no `inline fn` in `_fs.zig` / `_vs.zig`
                .shader_no_atan, // Shader rule - `@atan` / `@atan2` not available under SPIR-V
                .sampler_in_branch, // Shader rule - sample textures at the top of shaderMain, not in a branch
                .sampler_in_helper, // Shader rule - texture samples belong in shaderMain, not helper fns
                .decl_order, // declare file-scope names before they are used
                .whole_init_first, // fill uninitialised memory with ONE whole-struct write
                .returned_stack_reference, // never return a pointer to a local
                .catch_suppression, // make swallowing an error a conscious choice
                .prefer_assert_unreachable, // name the impossible, with a message
                .no_catch_return, // `catch |e| return e` is just `try`
                .unused_global, // a private file-scope decl nothing references
                .useless_error_return, // `!T` on a fn whose body can't error
                .duplicate_case, // two switch prongs with the same body
                .redundant_import, // the module already has a file-scope alias
                .canonical_alias, // import a module under the name it declares
                .import_at_root, // bind imports at container scope, not mid-expression
                .state_uninit, // an app's State must be born from a `.{...}` literal
                .no_qualified_zm, // bind zm math keywords once at file scope, use them bare
                .no_qualified_std, // bind the hot std names once at file scope, use them bare
                .custom_degrad, // one spelling for degree/radian conversion
                .no_std_timer, // std.time.Timer does not exist in the pinned std
                .debug_print, // no std.debug.print in code that ships as wasm
                .float_from_int, // `@as(f32, @floatFromInt(x))` is `zm.float(x)`
                .shader_safe, // a SHADER-SAFE file stays compilable for the GPU
                .scope_balance, // every begin{X} in a function has its end{X}
                .screaming_const, // value consts are snake_case, at every depth
                .shader_missing_entry, // a shader body must bind its SPIR-V entry
                .unknown_lint_tag, // a `lint:off` names a rule that does not exist
                .arch_check, // ask the host's facts, not the processor
                .browser_call, // reach the browser through the platform contract
                .own_clock, // read the platform's clock, not the system's
                .process_exit, // only a program's entry point exits
                .prefer_decl_literal, // `.make(...)` when the declaration already names the type
                .constructor_in_view, // a decl-literal constructor only where its declaration names the type
            },
        },
    });

    _ = project.addApp(.{ .name = "myproject1", .title = "myproject1 - bouncing balls" });
    _ = project.addApp(.{ .name = "myproject2", .title = "myproject2 - 3D cube" });
    // Owns its `main` (and each frame), instead of being a descriptor zimr's runner drives: see src/myproject3.zig.
    _ = project.addApp(.{ .name = "myproject3", .title = "myproject3 - owns its main", .own_frame = true });

    // project.addTest(b.path("src/util.zig"));
}
