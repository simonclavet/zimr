//! gen_vscode.zig - generate editor debug/build configs for the wgpu demos.
//!
//! Zig port of the old `scripts/build_launch_json.py`.  Source of truth is the
//! `const example_steps = [_][]const u8{ ... }` array in build.zig; each entry
//! becomes a Chrome debug config + a `zig build <step>` task + a
//! `<step>-standalone` task, written to four files:
//!   .vscode/launch.json, .vscode/tasks.json, .zed/debug.json, .zed/tasks.json
//!
//! An app has two spellings and the configs need both: its build step is dashed
//! (`hello-world`) while the dev server serves its page from an underscored
//! directory (`zig-out/web/hello_world/`), the same pair `finishWgpuApp` in
//! build.zig derives from one app name.  `example_steps` holds either spelling,
//! so `Example` derives both rather than trusting the entry to be one of them.
//!
//! Output is byte-identical to the python's json.dumps(indent=4).
//!
//! Usage: `gen_vscode`  (run from repo root).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

// Optimize mode for the per-demo `-standalone` build (see claude.md:
// ReleaseSmall + zimr asserts + on-page logs).
const standalone_mode: []const u8 = "release";

/// One app, in the two spellings the configs need.
const Example = struct {
    /// The dashed build step: `zig build <step>`, `<step>-standalone`, and every config label.
    step: []const u8,
    /// The underscored directory under zig-out/web/ that the dev server serves the page from.
    served_dir: []const u8,
};

fn stepLessThan(_: void, a: Example, b: Example) bool {
    return std.mem.lessThan(u8, a.step, b.step);
}

/// A copy of `text` with every `from` byte replaced by `to`.
fn withByteReplaced(gpa: Allocator, text: []const u8, from: u8, to: u8) ![]u8 {
    const copy: []u8 = try gpa.dupe(u8, text);
    std.mem.replaceScalar(u8, copy, from, to);
    return copy;
}

/// Insert the `,\n` element separator before every array element except the
/// first.  `first` is cleared after the first call.
fn sep(w: *Writer, first: *bool) !void {
    if (!first.*) {
        try w.writeAll(",\n");
    }
    first.* = false;
}

/// Extract the quoted names from `const example_steps = [_][]const u8{ ... };`.
fn parseExamples(
    gpa: Allocator,
    src: []const u8,
    out: *ArrayList([]const u8),
) !void {
    const anchor: []const u8 = "const example_steps";
    const a: usize = std.mem.indexOf(u8, src, anchor) orelse return error.NotFound;
    const brace: usize = std.mem.indexOfScalarPos(u8, src, a, '{') orelse return error.NotFound;
    const close: usize = std.mem.indexOfPos(u8, src, brace, "};") orelse return error.NotFound;
    const block: []const u8 = src[brace + 1 .. close];
    var i: usize = 0;
    while (i < block.len) {
        if (block[i] != '"') {
            i += 1;
            continue;
        }
        const j: usize = std.mem.indexOfScalarPos(u8, block, i + 1, '"') orelse break;
        try out.append(gpa, try gpa.dupe(u8, block[i + 1 .. j]));
        i = j + 1;
    }
}

/// Derive both spellings of every `example_steps` entry, sorted by step. An entry naming a
/// step already listed is dropped and recorded in `out_duplicate_steps`, so the caller can
/// say so instead of emitting two configs with one label.
fn collectExamples(
    gpa: Allocator,
    raw_names: []const []const u8,
    out_examples: *ArrayList(Example),
    out_duplicate_steps: *ArrayList([]const u8),
) !void {
    for (raw_names) |raw_name| {
        const step: []u8 = try withByteReplaced(gpa, raw_name, '_', '-');
        var step_already_listed: bool = false;
        for (out_examples.items) |listed| {
            if (std.mem.eql(u8, listed.step, step)) {
                step_already_listed = true;
            }
        }
        if (step_already_listed) {
            try out_duplicate_steps.append(gpa, step);
            continue;
        }
        const served_dir: []u8 = try withByteReplaced(gpa, raw_name, '-', '_');
        try out_examples.append(gpa, .{ .step = step, .served_dir = served_dir });
    }
    std.mem.sort(Example, out_examples.items, {}, stepLessThan);
}

// ===========================================================================
// VS Code per-name objects (8-space element indent)
// ===========================================================================

fn emitVscodeChrome(w: *Writer, example: Example) !void {
    try w.writeAll("        {\n");
    try w.print("            \"name\": \"Debug: {s}\",\n", .{example.step});
    try w.writeAll("            \"type\": \"chrome\",\n");
    try w.writeAll("            \"request\": \"launch\",\n");
    try w.print("            \"url\": \"http://localhost:8080/{s}/\",\n", .{example.served_dir});
    try w.writeAll("            \"webRoot\": \"${workspaceFolder}/zig-out/web\",\n");
    try w.print("            \"preLaunchTask\": \"zig: build {s}\",\n", .{example.step});
    try w.writeAll("            \"sourceMaps\": true,\n");
    try w.writeAll("            \"userDataDir\": true,\n");
    try w.writeAll("            \"smartStep\": true\n");
    try w.writeAll("        }");
}

fn emitVscodeBuildTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: build {s}\",\n", .{step});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}\"\n", .{step});
    try w.writeAll("            ],\n");
    try w.writeAll("            \"dependsOn\": [\n");
    try w.writeAll("                \"zig: serve-only (background)\"\n");
    try w.writeAll("            ],\n");
    try w.writeAll("            \"presentation\": {\n");
    try w.writeAll("                \"reveal\": \"silent\",\n");
    try w.writeAll("                \"panel\": \"dedicated\",\n");
    try w.writeAll("                \"clear\": true\n");
    try w.writeAll("            },\n");
    try w.writeAll("            \"problemMatcher\": []\n");
    try w.writeAll("        }");
}

fn emitVscodeStandaloneTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: standalone {s}\",\n", .{step});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}-standalone\",\n", .{step});
    try w.print("                \"-Dmode={s}\"\n", .{standalone_mode});
    try w.writeAll("            ],\n");
    try w.writeAll("            \"presentation\": {\n");
    try w.writeAll("                \"reveal\": \"always\",\n");
    try w.writeAll("                \"panel\": \"dedicated\",\n");
    try w.writeAll("                \"clear\": true\n");
    try w.writeAll("            },\n");
    try w.writeAll("            \"problemMatcher\": []\n");
    try w.writeAll("        }");
}

// ===========================================================================
// Zed per-name objects (4-space element indent)
// ===========================================================================

fn emitZedChrome(w: *Writer, example: Example) !void {
    try w.writeAll("    {\n");
    try w.writeAll("        \"adapter\": \"JavaScript\",\n");
    try w.print("        \"label\": \"Debug: {s}\",\n", .{example.step});
    try w.writeAll("        \"type\": \"chrome\",\n");
    try w.writeAll("        \"request\": \"launch\",\n");
    try w.print("        \"url\": \"http://localhost:8080/{s}/\",\n", .{example.served_dir});
    try w.writeAll("        \"webRoot\": \"$ZED_WORKTREE_ROOT/zig-out/web\",\n");
    try w.writeAll("        \"sourceMaps\": true,\n");
    try w.writeAll("        \"smartStep\": true,\n");
    try w.print("        \"build\": \"zig: build {s}\"\n", .{example.step});
    try w.writeAll("    }");
}

fn emitZedBuildTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: build {s}\",\n", .{step});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}\"\n", .{step});
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"no_focus\",\n");
    try w.writeAll("        \"use_new_terminal\": false\n");
    try w.writeAll("    }");
}

fn emitZedStandaloneTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: standalone {s}\",\n", .{step});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}-standalone\",\n", .{step});
    try w.print("            \"-Dmode={s}\"\n", .{standalone_mode});
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"always\",\n");
    try w.writeAll("        \"use_new_terminal\": false\n");
    try w.writeAll("    }");
}

// ===========================================================================
// Static (nameless) objects - multiline literals end at the closing brace
// with no trailing newline, so `sep` can prepend ",\n".
// ===========================================================================

// The `endsPattern` below MUST match the readiness line `tools/serve.zig`
// prints once the port is bound (`zimr serve: http://127.0.0.1:PORT/ ...`).
// It is how VS Code decides the background server task is "ready" so F5 can
// proceed to launch Chrome; a stale pattern makes every F5 hang.
const vscode_serve =
    \\        {
    \\            "label": "zig: serve-only (background)",
    \\            "type": "shell",
    \\            "command": "zig",
    \\            "args": [
    \\                "build",
    \\                "serve-only"
    \\            ],
    \\            "isBackground": true,
    \\            "problemMatcher": {
    \\                "owner": "zig-serve",
    \\                "pattern": [
    \\                    {
    \\                        "regexp": "^(.*)$",
    \\                        "file": 1,
    \\                        "location": 1,
    \\                        "message": 1
    \\                    }
    \\                ],
    \\                "background": {
    \\                    "activeOnStart": true,
    \\                    "beginsPattern": ".",
    \\                    "endsPattern": "zimr serve: http"
    \\                }
    \\            },
    \\            "presentation": {
    \\                "reveal": "silent",
    \\                "panel": "dedicated",
    \\                "showReuseMessage": false
    \\            },
    \\            "runOptions": {
    \\                "instanceLimit": 1
    \\            }
    \\        }
;

const vscode_extra_release =
    \\        {
    \\            "label": "zig: build (release)",
    \\            "type": "shell",
    \\            "command": "zig",
    \\            "args": [
    \\                "build",
    \\                "-Dmode=release"
    \\            ],
    \\            "group": "build",
    \\            "presentation": {
    \\                "reveal": "silent",
    \\                "panel": "dedicated",
    \\                "clear": true
    \\            },
    \\            "problemMatcher": []
    \\        }
;

const vscode_extra_test =
    \\        {
    \\            "label": "zig: test",
    \\            "type": "shell",
    \\            "command": "zig",
    \\            "args": [
    \\                "build",
    \\                "test",
    \\                "--summary",
    \\                "all"
    \\            ],
    \\            "group": {
    \\                "kind": "test",
    \\                "isDefault": true
    \\            },
    \\            "presentation": {
    \\                "reveal": "always",
    \\                "panel": "dedicated"
    \\            },
    \\            "problemMatcher": []
    \\        }
;

const vscode_extra_smoke =
    \\        {
    \\            "label": "zig: smoke-test",
    \\            "type": "shell",
    \\            "command": "zig",
    \\            "args": [
    \\                "build",
    \\                "-Dmode=debug",
    \\                "smoke-test"
    \\            ],
    \\            "group": "test",
    \\            "presentation": {
    \\                "reveal": "always",
    \\                "panel": "dedicated"
    \\            },
    \\            "problemMatcher": []
    \\        }
;

const zed_serve =
    \\    {
    \\        "label": "zig: serve-only",
    \\        "command": "zig",
    \\        "args": [
    \\            "build",
    \\            "serve-only"
    \\        ],
    \\        "reveal": "always",
    \\        "use_new_terminal": false,
    \\        "allow_concurrent_runs": false
    \\    }
;

const zed_extra_release =
    \\    {
    \\        "label": "zig: build (release)",
    \\        "command": "zig",
    \\        "args": [
    \\            "build",
    \\            "-Dmode=release"
    \\        ],
    \\        "reveal": "always",
    \\        "use_new_terminal": false
    \\    }
;

const zed_extra_test =
    \\    {
    \\        "label": "zig: test",
    \\        "command": "zig",
    \\        "args": [
    \\            "build",
    \\            "test",
    \\            "--summary",
    \\            "all"
    \\        ],
    \\        "reveal": "always",
    \\        "use_new_terminal": false
    \\    }
;

const zed_extra_smoke =
    \\    {
    \\        "label": "zig: smoke-test",
    \\        "command": "zig",
    \\        "args": [
    \\            "build",
    \\            "-Dmode=debug",
    \\            "smoke-test"
    \\        ],
    \\        "reveal": "always",
    \\        "use_new_terminal": false
    \\    }
;

// ===========================================================================
// File assemblers
// ===========================================================================

fn buildVscodeLaunch(gpa: Allocator, examples: []const Example) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"0.2.0\",\n    \"configurations\": [\n");
    var first: bool = true;
    for (examples) |example| {
        try sep(w, &first);
        try emitVscodeChrome(w, example);
    }
    try w.writeAll("\n    ]\n}\n");
    return aw.written();
}

fn buildVscodeTasks(gpa: Allocator, examples: []const Example) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"2.0.0\",\n    \"tasks\": [\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(vscode_serve);
    for (examples) |example| {
        try sep(w, &first);
        try emitVscodeBuildTask(w, example.step);
        try sep(w, &first);
        try emitVscodeStandaloneTask(w, example.step);
    }
    try sep(w, &first);
    try w.writeAll(vscode_extra_release);
    try sep(w, &first);
    try w.writeAll(vscode_extra_test);
    try sep(w, &first);
    try w.writeAll(vscode_extra_smoke);
    try w.writeAll("\n    ]\n}\n");
    return aw.written();
}

fn buildZedDebug(gpa: Allocator, examples: []const Example) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    for (examples) |example| {
        try sep(w, &first);
        try emitZedChrome(w, example);
    }
    try w.writeAll("\n]\n");
    return aw.written();
}

fn buildZedTasks(gpa: Allocator, examples: []const Example) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(zed_serve);
    for (examples) |example| {
        try sep(w, &first);
        try emitZedBuildTask(w, example.step);
        try sep(w, &first);
        try emitZedStandaloneTask(w, example.step);
    }
    try sep(w, &first);
    try w.writeAll(zed_extra_release);
    try sep(w, &first);
    try w.writeAll(zed_extra_test);
    try sep(w, &first);
    try w.writeAll(zed_extra_smoke);
    try w.writeAll("\n]\n");
    return aw.written();
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: std.Io = init.io;
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    const build_src: []u8 = try cwd.readFileAlloc(io, "build.zig", gpa, .unlimited);
    var raw_names: ArrayList([]const u8) = .empty;
    try parseExamples(gpa, build_src, &raw_names);
    var examples: ArrayList(Example) = .empty;
    var duplicate_steps: ArrayList([]const u8) = .empty;
    try collectExamples(gpa, raw_names.items, &examples, &duplicate_steps);

    const vscode_launch: []u8 = try buildVscodeLaunch(gpa, examples.items);
    const vscode_tasks: []u8 = try buildVscodeTasks(gpa, examples.items);
    const zed_debug: []u8 = try buildZedDebug(gpa, examples.items);
    const zed_tasks: []u8 = try buildZedTasks(gpa, examples.items);

    try cwd.writeFile(io, .{ .sub_path = ".vscode/launch.json", .data = vscode_launch });
    try cwd.writeFile(io, .{ .sub_path = ".vscode/tasks.json", .data = vscode_tasks });
    try cwd.writeFile(io, .{ .sub_path = ".zed/debug.json", .data = zed_debug });
    try cwd.writeFile(io, .{ .sub_path = ".zed/tasks.json", .data = zed_tasks });

    var out_buf: [256]u8 = undefined;
    var ow: std.Io.File.Writer = std.Io.File.stdout().writer(io, &out_buf);
    for (duplicate_steps.items) |step| {
        try ow.interface.print(
            "gen_vscode: build.zig's example_steps names `{s}` more than once; its configs are written once\n",
            .{step},
        );
    }
    try ow.interface.print(
        "gen_vscode: wrote 4 files for {d} wgpu examples\n",
        .{examples.items.len},
    );
    try ow.interface.flush();
}
