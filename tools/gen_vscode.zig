//! gen_vscode.zig - generate editor debug/build configs for the wgpu demos.
//!
//! Zig port of the old `scripts/build_launch_json.py`.  Source of truth is the
//! `const example_steps = [_][]const u8{ ... }` array in build.zig; each entry
//! becomes a Chrome debug config + a `zig build <name>` task + a
//! `<name>-standalone` task, written to four files:
//!   .vscode/launch.json, .vscode/tasks.json, .zed/debug.json, .zed/tasks.json
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

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

// ===========================================================================
// VS Code per-name objects (8-space element indent)
// ===========================================================================

fn emitVscodeChrome(w: *Writer, name: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"name\": \"Debug: {s}\",\n", .{name});
    try w.writeAll("            \"type\": \"chrome\",\n");
    try w.writeAll("            \"request\": \"launch\",\n");
    try w.print("            \"url\": \"http://localhost:8080/{s}/\",\n", .{name});
    try w.writeAll("            \"webRoot\": \"${workspaceFolder}/zig-out/web\",\n");
    try w.print("            \"preLaunchTask\": \"zig: build {s}\",\n", .{name});
    try w.writeAll("            \"sourceMaps\": true,\n");
    try w.writeAll("            \"userDataDir\": true,\n");
    try w.writeAll("            \"smartStep\": true\n");
    try w.writeAll("        }");
}

fn emitVscodeBuildTask(w: *Writer, name: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: build {s}\",\n", .{name});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}\"\n", .{name});
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

fn emitVscodeStandaloneTask(w: *Writer, name: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: standalone {s}\",\n", .{name});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}-standalone\",\n", .{name});
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

fn emitZedChrome(w: *Writer, name: []const u8) !void {
    try w.writeAll("    {\n");
    try w.writeAll("        \"adapter\": \"JavaScript\",\n");
    try w.print("        \"label\": \"Debug: {s}\",\n", .{name});
    try w.writeAll("        \"type\": \"chrome\",\n");
    try w.writeAll("        \"request\": \"launch\",\n");
    try w.print("        \"url\": \"http://localhost:8080/{s}/\",\n", .{name});
    try w.writeAll("        \"webRoot\": \"$ZED_WORKTREE_ROOT/zig-out/web\",\n");
    try w.writeAll("        \"sourceMaps\": true,\n");
    try w.writeAll("        \"smartStep\": true,\n");
    try w.print("        \"build\": \"zig: build {s}\"\n", .{name});
    try w.writeAll("    }");
}

fn emitZedBuildTask(w: *Writer, name: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: build {s}\",\n", .{name});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}\"\n", .{name});
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"no_focus\",\n");
    try w.writeAll("        \"use_new_terminal\": false\n");
    try w.writeAll("    }");
}

fn emitZedStandaloneTask(w: *Writer, name: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: standalone {s}\",\n", .{name});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}-standalone\",\n", .{name});
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

fn buildVscodeLaunch(gpa: Allocator, names: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"0.2.0\",\n    \"configurations\": [\n");
    var first: bool = true;
    for (names) |name| {
        try sep(w, &first);
        try emitVscodeChrome(w, name);
    }
    try w.writeAll("\n    ]\n}\n");
    return aw.written();
}

fn buildVscodeTasks(gpa: Allocator, names: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"2.0.0\",\n    \"tasks\": [\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(vscode_serve);
    for (names) |name| {
        try sep(w, &first);
        try emitVscodeBuildTask(w, name);
        try sep(w, &first);
        try emitVscodeStandaloneTask(w, name);
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

fn buildZedDebug(gpa: Allocator, names: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    for (names) |name| {
        try sep(w, &first);
        try emitZedChrome(w, name);
    }
    try w.writeAll("\n]\n");
    return aw.written();
}

fn buildZedTasks(gpa: Allocator, names: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(zed_serve);
    for (names) |name| {
        try sep(w, &first);
        try emitZedBuildTask(w, name);
        try sep(w, &first);
        try emitZedStandaloneTask(w, name);
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
    var names: ArrayList([]const u8) = .empty;
    try parseExamples(gpa, build_src, &names);
    std.mem.sort([]const u8, names.items, {}, lessStr);

    const vscode_launch: []u8 = try buildVscodeLaunch(gpa, names.items);
    const vscode_tasks: []u8 = try buildVscodeTasks(gpa, names.items);
    const zed_debug: []u8 = try buildZedDebug(gpa, names.items);
    const zed_tasks: []u8 = try buildZedTasks(gpa, names.items);

    try cwd.writeFile(io, .{ .sub_path = ".vscode/launch.json", .data = vscode_launch });
    try cwd.writeFile(io, .{ .sub_path = ".vscode/tasks.json", .data = vscode_tasks });
    try cwd.writeFile(io, .{ .sub_path = ".zed/debug.json", .data = zed_debug });
    try cwd.writeFile(io, .{ .sub_path = ".zed/tasks.json", .data = zed_tasks });

    var out_buf: [256]u8 = undefined;
    var ow: std.Io.File.Writer = std.Io.File.stdout().writer(io, &out_buf);
    try ow.interface.print(
        "gen_vscode: wrote 4 files for {d} wgpu examples\n",
        .{names.items.len},
    );
    try ow.interface.flush();
}
