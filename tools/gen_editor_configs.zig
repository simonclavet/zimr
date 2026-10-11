//! gen_editor_configs.zig - write the VS Code AND Zed debug/build configs for zimr's web apps.
//!
//! build.zig names the apps on the command line: every app with a web build (its `web_builds`), by
//! name. Each becomes a Chrome debug config + a `zig build <step> -Dplatform=web` task (the
//! debug build the config opens) + a release task (`-Dmode=release`: the served
//! page and the single-file page, as every web build makes both), written to four files:
//!   .vscode/launch.json, .vscode/tasks.json, .zed/debug.json, .zed/tasks.json
//!
//! `--check` renders the same four files and compares them with the ones on disk instead of writing
//! them. `zig build check` runs it, so an app added without regenerating the configs fails there,
//! naming the stale files. Carriage returns on disk are ignored: a Windows checkout's line endings
//! are not drift.
//!
//! An app has two spellings and the configs need both: its build step is dashed
//! (`hello-world`) while the dev server serves its page from an underscored
//! directory (`zig-out/web/hello_world/`), the same pair `finishWgpuApp` in
//! build.zig derives from one app name. `Example` derives both from whichever spelling it is given.
//!
//! Output is byte-identical to the python's json.dumps(indent=4).
//!
//! Usage: `zig build editor-configs` writes, `zig build check` compares (`--help` for more).

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const sortSlice = std.mem.sort;
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Writer = Io.Writer;

// Optimize mode for the per-demo release task (see claude.md:
// ReleaseSmall + zimr asserts + on-page logs).
const release_mode: []const u8 = "release";

/// One app, in the two spellings the configs need.
const Example = struct {
    /// The dashed build step: `zig build <step>`, and every config label.
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

/// Derive both spellings of every app name, sorted by step. A name whose step is already listed
/// is dropped and recorded in `out_duplicate_steps`, so the caller can refuse the run instead of
/// emitting two configs with one label.
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
            if (eql(u8, listed.step, step)) {
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
    sortSlice(Example, out_examples.items, {}, stepLessThan);
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
    try w.print("                \"{s}\",\n", .{step});
    try w.writeAll("                \"-Dplatform=web\"\n");
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

fn emitVscodeReleaseTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: release {s}\",\n", .{step});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}\",\n", .{step});
    try w.writeAll("                \"-Dplatform=web\",\n");
    try w.print("                \"-Dmode={s}\"\n", .{release_mode});
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
    try w.print("            \"{s}\",\n", .{step});
    try w.writeAll("            \"-Dplatform=web\"\n");
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"no_focus\",\n");
    try w.writeAll("        \"use_new_terminal\": false\n");
    try w.writeAll("    }");
}

fn emitZedReleaseTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: release {s}\",\n", .{step});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}\",\n", .{step});
    try w.writeAll("            \"-Dplatform=web\",\n");
    try w.print("            \"-Dmode={s}\"\n", .{release_mode});
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
    var aw: Io.Writer.Allocating = .init(gpa);
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
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"2.0.0\",\n    \"tasks\": [\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(vscode_serve);
    for (examples) |example| {
        try sep(w, &first);
        try emitVscodeBuildTask(w, example.step);
        try sep(w, &first);
        try emitVscodeReleaseTask(w, example.step);
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
    var aw: Io.Writer.Allocating = .init(gpa);
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
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    try sep(w, &first);
    try w.writeAll(zed_serve);
    for (examples) |example| {
        try sep(w, &first);
        try emitZedBuildTask(w, example.step);
        try sep(w, &first);
        try emitZedReleaseTask(w, example.step);
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

/// The command line (std's cli, `src/command_line.zig`): the apps, and whether to compare rather than write.
const ConfigsArgs = struct {
    @"--check": bool = false,
    apps: []const []const u8 = &.{},
};

const configs_cli: cli.Config(ConfigsArgs) = .{
    .prog = "gen_editor_configs",
    .description = "Writes .vscode/launch.json, .vscode/tasks.json, .zed/debug.json and .zed/tasks.json for the " ++
        "apps named: a debug config, a build task and a release task per app.",
    .args = .{
        .@"--check" = .{ .description = "compare the four files with what they should hold; write nothing" },
        .apps = .{ .description = "every app with a web build, by name (build.zig passes them)" },
    },
};

/// One generated file: where it lives and what it should hold.
const ConfigFile = struct {
    path: []const u8,
    text: []const u8,
};

/// `text` without its carriage returns, so a file checked out with Windows line endings compares
/// equal to the LF text this tool writes.
fn withoutCarriageReturns(gpa: Allocator, text: []const u8) ![]u8 {
    var kept: ArrayList(u8) = .empty;
    for (text) |c| {
        if (c != '\r') {
            try kept.append(gpa, c);
        }
    }
    return kept.items;
}

/// Whether the file on disk already holds what `file` should, line endings aside. A missing file does not.
fn fileIsCurrent(gpa: Allocator, io: Io, cwd: Io.Dir, file: ConfigFile) !bool {
    const on_disk: []u8 = cwd.readFileAlloc(io, file.path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return eql(u8, try withoutCarriageReturns(gpa, on_disk), file.text);
}

pub fn main(init: std.process.Init) !u8 {
    const args: ConfigsArgs = cli.args(&init, ConfigsArgs, configs_cli);
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();

    var out_buf: [512]u8 = undefined;
    var ow: Io.File.Writer = Io.File.stdout().writer(io, &out_buf);
    const out: *Writer = &ow.interface;

    // An empty list would write four config files with nothing in them, and `--check` would then
    // call them current. build.zig always names its apps; a run without any is a broken caller.
    if (args.apps.len == 0) {
        try out.print("gen_editor_configs: no apps named; build.zig passes every app with a web build\n", .{});
        try out.flush();
        return 1;
    }
    var examples: ArrayList(Example) = .empty;
    var duplicate_steps: ArrayList([]const u8) = .empty;
    try collectExamples(gpa, args.apps, &examples, &duplicate_steps);
    if (duplicate_steps.items.len > 0) {
        for (duplicate_steps.items) |step| {
            try out.print("gen_editor_configs: two apps share the build step `{s}`\n", .{step});
        }
        try out.flush();
        return 1;
    }

    const config_files: [4]ConfigFile = .{
        .{ .path = ".vscode/launch.json", .text = try buildVscodeLaunch(gpa, examples.items) },
        .{ .path = ".vscode/tasks.json", .text = try buildVscodeTasks(gpa, examples.items) },
        .{ .path = ".zed/debug.json", .text = try buildZedDebug(gpa, examples.items) },
        .{ .path = ".zed/tasks.json", .text = try buildZedTasks(gpa, examples.items) },
    };

    if (args.@"--check") {
        var stale_count: usize = 0;
        for (config_files) |file| {
            const file_is_current: bool = try fileIsCurrent(gpa, io, cwd, file);
            if (!file_is_current) {
                try out.print("gen_editor_configs: {s} is out of date\n", .{file.path});
                stale_count += 1;
            }
        }
        if (stale_count > 0) {
            try out.print(
                "gen_editor_configs: {d} of 4 editor configs are stale for {d} apps: run `zig build editor-configs`\n",
                .{ stale_count, examples.items.len },
            );
            try out.flush();
            return 1;
        }
        try out.print("gen_editor_configs: the 4 editor configs match the {d} apps\n", .{examples.items.len});
        try out.flush();
        return 0;
    }

    for (config_files) |file| {
        try cwd.writeFile(io, .{ .sub_path = file.path, .data = file.text });
    }
    try out.print("gen_editor_configs: wrote 4 files for {d} apps\n", .{examples.items.len});
    try out.flush();
    return 0;
}
