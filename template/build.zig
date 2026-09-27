// build.zig - an application project built on zimr.
//
//   zig build                     -- build every app (debug) into zig-out/web/
//   zig build -Dmode=release      -- ReleaseSmall with zimr's asserts kept (share this one)
//   zig build -Dmode=ship         -- ReleaseSmall, asserts and profiler stripped
//   zig build serve               -- build everything, serve it on http://127.0.0.1:8081/
//   zig build <name>              -- build one app into zig-out/web/<name>/
//   zig build <name>-standalone   -- one self-contained HTML file in zig-out/standalone/
//   zig build test                -- pure-CPU host unit tests (see below)
//   zig build lint                -- zimr's linter over src/ (rules: see `.lint` below)
//   zig build check               -- lint + host tests + every app
//
// `zimr.Project` supplies all of those steps, the `-Dmode` option, the browser
// runtime (zig-out/web/zimr.js), the dev server, and copies public/ into
// zig-out/web/ as the gallery.
//
// Adding an app:
//   1. Drop `src/myname.zig` next to myproject1/myproject2. It declares
//      `pub const app: z.AppSpec(State) = .{ ... }` and nothing else.
//   2. Add a `project.addApp` call below.
//   3. Add a card to public/index.html linking to `myname/`.
//
// Beyond a plain app, `addApp` takes (see `Project.App` in zimr's build.zig):
//   .shaders = &.{ "wave_fs", ... }   typed Zig shaders from src/shaders/: wave_fs.zig beside
//                                     wave_fs_io.zig; the app embeds "wave_fs.wgsl"
//   .compute_kernels = &.{ ... }      GPU compute (`kompute`), kernels beside the app's source
//   .job_kernels = true               Web Worker jobs (`zimr.jobs`) from <app dir>/kernels.zig
//   .engine_wgsl = true               embed zimr's engine shaders ("pbr_fs.wgsl", ...)
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
        // zimr's linter over src/: `zig build lint`, and part of `check` and every
        // `<app>-standalone`. The always-on rules catch real bugs. The ones below are
        // OPT-IN house taste; zimr's own tree enables all of them except decl_order.
        // Uncomment the ones you agree with.
        // `zig build lint -- --list-rules` prints every rule;
        // `zig build lint -- --enable=<tag>` tries one before you commit to it.
        .lint = .{
            .enable = &.{
                .untyped_local, // write the type on every local: `const n: usize = xs.len;`
                .anon_return, // name the structs functions return (pairs with untyped_local)
                .branch_braces, // braces on every if/else/while/for body, even one-liners
                .decl_order, // define file-scope names above their first use
                .fn_args_multiline, // one parameter per line once a signature gets long
                .module_var, // no mutable globals: state lives in the app's State
                .no_qualified_zm, // `const length = zm.length;` once, then bare `length(v)`
                .reserved_math_names, // no locals named min/max/length/dot in files importing zm
                .prefer_std_alias, // `const ArrayList = std.ArrayList;` at file scope, used bare
                .ascii_comments, // ASCII-only comments (`->`, not an arrow glyph)
            },
        },
    });

    _ = project.addApp(.{ .name = "myproject1", .title = "myproject1 - bouncing balls" });
    _ = project.addApp(.{ .name = "myproject2", .title = "myproject2 - 3D cube" });

    // project.addTest(b.path("src/util.zig"));
}
