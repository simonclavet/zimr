//! gen_editor_configs.zig - write the VS Code AND Zed debug/build configs for zimr's apps.
//!
//! build.zig names the apps on the command line: every app with a web build (its `web_builds`), by
//! name. Each becomes a Chrome debug config + a `zig build <step> -Dplatform=web` task (the
//! debug build the config opens) + a release task (`-Dmode=release`: the served
//! page and the single-file page, as every web build makes both), written to four files:
//!   .vscode/launch.json, .vscode/tasks.json, .zed/debug.json, .zed/tasks.json
//!
//! Every app with a Windows program (its `windows_builds`) comes as `--windows=<name>` and gets a
//! native debug config in both editors: CodeLLDB launching zig-out/windows/<name>.exe, after a
//! `zig build <step> -Dplatform=windows` task has built it (`emitVscodeNative`, `emitZedNative`).
//!
//! `--check` renders the same four files and compares them with the ones on disk instead of writing
//! them. `zig build check` runs it, so an app added without regenerating the configs fails there,
//! naming the stale files. Carriage returns on disk are ignored: a Windows checkout's line endings
//! are not drift.
//!
//! An app has two spellings and the configs need both: its build step is dashed
//! (`hello-world`) while the dev server serves its page from an underscored
//! directory (`zig-out/web/hello_world/`) and its Windows program is `zig-out/windows/hello_world.exe`,
//! the same pair `finishWgpuApp` and `nativeAppExe` in build.zig derive from one app name. `Example`
//! derives both from whichever spelling it is given.
//!
//! `--project` writes the same configs for a `zimr.Project` (build.zig's `Project`, `Config.editor_configs`),
//! from its project root. Its apps' steps and outputs are spelled as the apps are named, its dev server is
//! `serve -Dplatform=web` on `--port`, which builds every app before serving, and zimr's smoke task is left
//! out. Every project app is a web app and a Windows app.
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
    /// The build step: `zig build <step>`, and every config label.
    step: []const u8,
    /// The name the app's outputs carry: the directory under zig-out/web/ that the dev server serves the page from,
    /// and the Windows program, zig-out/windows/<output_name>.exe.
    output_name: []const u8,
};

/// What differs between zimr's own configs and a `zimr.Project`'s (`--project`, `--port`).
const Layout = struct {
    /// zimr derives a dashed step and an underscored output name from each app's name (`hello-world`,
    /// `hello_world`); a project spells both as the app is named.
    derive_spellings: bool,
    /// The dev server's step, and the arguments that run it: zimr's `serve-only` serves what is already built, a
    /// project's `serve` builds every app for the web first and so names the platform.
    serve_step: []const u8,
    serve_args: []const []const u8,
    /// The port the dev server listens on, in every page's URL.
    port: []const u8,
    /// zimr's Node smoke harness (`smoke-test`), which a project does not have.
    smoke_task: bool,
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

/// The items of a JSON array of strings, one per line at `indent`, comma-separated; the caller writes the brackets.
fn emitStringItems(w: *Writer, indent: []const u8, items: []const []const u8) !void {
    for (items, 0..) |item, index| {
        const is_last_item: bool = index + 1 == items.len;
        const separator: []const u8 = if (is_last_item) "" else ",";
        try w.print("{s}\"{s}\"{s}\n", .{ indent, item, separator });
    }
}

/// Both spellings of every app name, sorted by step: derived the way zimr spells them, or the name itself for both
/// (`Layout.derive_spellings`). A name whose step is already listed is dropped and recorded in
/// `out_duplicate_steps`, so the caller can refuse the run instead of emitting two configs with one label.
fn collectExamples(
    gpa: Allocator,
    raw_names: []const []const u8,
    derive_spellings: bool,
    out_examples: *ArrayList(Example),
    out_duplicate_steps: *ArrayList([]const u8),
) !void {
    for (raw_names) |raw_name| {
        const step: []const u8 = if (derive_spellings) try withByteReplaced(gpa, raw_name, '_', '-') else raw_name;
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
        const output_name: []const u8 = if (derive_spellings)
            try withByteReplaced(gpa, raw_name, '-', '_')
        else
            raw_name;
        try out_examples.append(gpa, .{ .step = step, .output_name = output_name });
    }
    sortSlice(Example, out_examples.items, {}, stepLessThan);
}

// ===========================================================================
// VS Code per-name objects (8-space element indent)
// ===========================================================================

fn emitVscodeChrome(w: *Writer, example: Example, layout: Layout) !void {
    try w.writeAll("        {\n");
    try w.print("            \"name\": \"Debug: {s}\",\n", .{example.step});
    try w.writeAll("            \"type\": \"chrome\",\n");
    try w.writeAll("            \"request\": \"launch\",\n");
    try w.print("            \"url\": \"http://localhost:{s}/{s}/\",\n", .{ layout.port, example.output_name });
    try w.writeAll("            \"webRoot\": \"${workspaceFolder}/zig-out/web\",\n");
    try w.print("            \"preLaunchTask\": \"zig: build {s}\",\n", .{example.step});
    try w.writeAll("            \"sourceMaps\": true,\n");
    try w.writeAll("            \"userDataDir\": true,\n");
    try w.writeAll("            \"smartStep\": true\n");
    try w.writeAll("        }");
}

fn emitVscodeBuildTask(w: *Writer, step: []const u8, layout: Layout) !void {
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
    try w.print("                \"zig: {s} (background)\"\n", .{layout.serve_step});
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

fn emitZedChrome(w: *Writer, example: Example, layout: Layout) !void {
    try w.writeAll("    {\n");
    try w.writeAll("        \"adapter\": \"JavaScript\",\n");
    try w.print("        \"label\": \"Debug: {s}\",\n", .{example.step});
    try w.writeAll("        \"type\": \"chrome\",\n");
    try w.writeAll("        \"request\": \"launch\",\n");
    try w.print("        \"url\": \"http://localhost:{s}/{s}/\",\n", .{ layout.port, example.output_name });
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
// Native objects: an app's Windows program under CodeLLDB, in VS Code (8-space element indent) and Zed (4-space)
// ===========================================================================

/// The label of the task that builds an app's Windows program. Each editor's debug config names the task by it and
/// the task declares it, so all four print this one spelling.
const native_build_label: []const u8 = "zig: build {s} (windows)";

/// LLDB's own PDB reader. CodeLLDB ships msdia140.dll beside codelldb.exe, so LLDB otherwise reads PDBs through
/// Microsoft's DIA, which names every Zig frame in the call stack as a C declaration
/// (`static void update(unsigned __int64 *, struct wgpu_app.Frame *, struct myproject1.State *)`). Only LLDB 22 and
/// later has this setting, and an older one rejects the command: Zed downloads a CodeLLDB that has it, but VS Code's
/// can carry LLDB 21, so VS Code gets the reader from the extension's `lldb.useNativePDBReader` instead, in the
/// hand-written .vscode/settings.json.
const lldb_native_pdb_reader: []const u8 = "settings set plugin.symbol-file.pdb.reader native";

/// No fast stepping: with it, stepping over hello_world's `z.loadFont` crashes LLDB itself (0xC0000005), which ends
/// the debug session.
const lldb_fast_stepping_off: []const u8 = "settings set target.use-fast-stepping false";

/// The LLDB commands a Zed native config runs before it loads the program.
const zed_lldb_init_commands = [_][]const u8{ lldb_native_pdb_reader, lldb_fast_stepping_off };

/// The LLDB commands a VS Code native config runs before it loads the program; the PDB reader comes from the
/// workspace settings (`lldb_native_pdb_reader` says why).
const vscode_lldb_init_commands = [_][]const u8{lldb_fast_stepping_off};

/// A VS Code debug config for an app's Windows program, the twin of `emitZedNative`: the CodeLLDB extension
/// (`vadimcn.vscode-lldb`) launches zig-out/windows/<output_name>.exe from the workspace root once the native build
/// task has built it. It reads `lldb.useNativePDBReader` from .vscode/settings.json, which this tool does not write.
fn emitVscodeNative(w: *Writer, example: Example) !void {
    try w.writeAll("        {\n");
    try w.print("            \"name\": \"Debug: {s} (windows)\",\n", .{example.step});
    try w.writeAll("            \"type\": \"lldb\",\n");
    try w.writeAll("            \"request\": \"launch\",\n");
    try w.writeAll("            \"program\": \"${workspaceFolder}/zig-out/windows/");
    try w.print("{s}.exe\",\n", .{example.output_name});
    try w.writeAll("            \"cwd\": \"${workspaceFolder}\",\n");
    try w.writeAll("            \"initCommands\": [\n");
    try emitStringItems(w, "                ", &vscode_lldb_init_commands);
    try w.writeAll("            ],\n");
    try w.print("            \"preLaunchTask\": \"" ++ native_build_label ++ "\"\n", .{example.step});
    try w.writeAll("        }");
}

fn emitVscodeNativeBuildTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"" ++ native_build_label ++ "\",\n", .{step});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try w.writeAll("                \"build\",\n");
    try w.print("                \"{s}\",\n", .{step});
    try w.writeAll("                \"-Dplatform=windows\"\n");
    try w.writeAll("            ],\n");
    try w.writeAll("            \"presentation\": {\n");
    try w.writeAll("                \"reveal\": \"silent\",\n");
    try w.writeAll("                \"panel\": \"dedicated\",\n");
    try w.writeAll("                \"clear\": true\n");
    try w.writeAll("            },\n");
    try w.writeAll("            \"problemMatcher\": []\n");
    try w.writeAll("        }");
}

/// A Zed debug scenario for an app's Windows program: CodeLLDB, which Zed downloads by itself, launches
/// zig-out/windows/<output_name>.exe from the project root, as `zig build run-<step>` runs it, once the native build
/// task has built it.
fn emitZedNative(w: *Writer, example: Example) !void {
    try w.writeAll("    {\n");
    try w.writeAll("        \"adapter\": \"CodeLLDB\",\n");
    try w.print("        \"label\": \"Debug: {s} (windows)\",\n", .{example.step});
    try w.writeAll("        \"request\": \"launch\",\n");
    try w.print("        \"program\": \"$ZED_WORKTREE_ROOT/zig-out/windows/{s}.exe\",\n", .{example.output_name});
    try w.writeAll("        \"cwd\": \"$ZED_WORKTREE_ROOT\",\n");
    try w.writeAll("        \"initCommands\": [\n");
    try emitStringItems(w, "            ", &zed_lldb_init_commands);
    try w.writeAll("        ],\n");
    try w.print("        \"build\": \"" ++ native_build_label ++ "\"\n", .{example.step});
    try w.writeAll("    }");
}

fn emitZedNativeBuildTask(w: *Writer, step: []const u8) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"" ++ native_build_label ++ "\",\n", .{step});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try w.writeAll("            \"build\",\n");
    try w.print("            \"{s}\",\n", .{step});
    try w.writeAll("            \"-Dplatform=windows\"\n");
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"no_focus\",\n");
    try w.writeAll("        \"use_new_terminal\": false\n");
    try w.writeAll("    }");
}

// ===========================================================================
// Nameless objects - multiline literals end at the closing brace
// with no trailing newline, so `sep` can prepend ",\n".
// ===========================================================================

// The `endsPattern` below MUST match the readiness line `tools/serve.zig`
// prints once the port is bound (`zimr serve: http://127.0.0.1:PORT/ ...`).
// It is how VS Code decides the background server task is "ready" so F5 can
// proceed to launch Chrome; a stale pattern makes every F5 hang.
const vscode_serve_after_args =
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

/// The VS Code task that starts the dev server and keeps it running. Every web build task depends on it, so the first
/// F5 starts it and every later one finds it running (`instanceLimit`).
fn emitVscodeServeTask(w: *Writer, layout: Layout) !void {
    try w.writeAll("        {\n");
    try w.print("            \"label\": \"zig: {s} (background)\",\n", .{layout.serve_step});
    try w.writeAll("            \"type\": \"shell\",\n");
    try w.writeAll("            \"command\": \"zig\",\n");
    try w.writeAll("            \"args\": [\n");
    try emitStringItems(w, "                ", layout.serve_args);
    try w.writeAll("            ],\n");
    try w.writeAll(vscode_serve_after_args);
}

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

/// The Zed task that starts the dev server. Zed has no background task to depend on, so it is run by hand before the
/// first web debug session, and `allow_concurrent_runs` keeps a second one from fighting the first for the port.
fn emitZedServeTask(w: *Writer, layout: Layout) !void {
    try w.writeAll("    {\n");
    try w.print("        \"label\": \"zig: {s}\",\n", .{layout.serve_step});
    try w.writeAll("        \"command\": \"zig\",\n");
    try w.writeAll("        \"args\": [\n");
    try emitStringItems(w, "            ", layout.serve_args);
    try w.writeAll("        ],\n");
    try w.writeAll("        \"reveal\": \"always\",\n");
    try w.writeAll("        \"use_new_terminal\": false,\n");
    try w.writeAll("        \"allow_concurrent_runs\": false\n");
    try w.writeAll("    }");
}

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

fn buildVscodeLaunch(
    gpa: Allocator,
    web_examples: []const Example,
    windows_examples: []const Example,
    layout: Layout,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"0.2.0\",\n    \"configurations\": [\n");
    var first: bool = true;
    for (web_examples) |example| {
        try sep(w, &first);
        try emitVscodeChrome(w, example, layout);
    }
    for (windows_examples) |example| {
        try sep(w, &first);
        try emitVscodeNative(w, example);
    }
    try w.writeAll("\n    ]\n}\n");
    return aw.written();
}

fn buildVscodeTasks(
    gpa: Allocator,
    web_examples: []const Example,
    windows_examples: []const Example,
    layout: Layout,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("{\n    \"version\": \"2.0.0\",\n    \"tasks\": [\n");
    var first: bool = true;
    try sep(w, &first);
    try emitVscodeServeTask(w, layout);
    for (web_examples) |example| {
        try sep(w, &first);
        try emitVscodeBuildTask(w, example.step, layout);
        try sep(w, &first);
        try emitVscodeReleaseTask(w, example.step);
    }
    for (windows_examples) |example| {
        try sep(w, &first);
        try emitVscodeNativeBuildTask(w, example.step);
    }
    try sep(w, &first);
    try w.writeAll(vscode_extra_release);
    try sep(w, &first);
    try w.writeAll(vscode_extra_test);
    if (layout.smoke_task) {
        try sep(w, &first);
        try w.writeAll(vscode_extra_smoke);
    }
    try w.writeAll("\n    ]\n}\n");
    return aw.written();
}

fn buildZedDebug(
    gpa: Allocator,
    web_examples: []const Example,
    windows_examples: []const Example,
    layout: Layout,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    for (web_examples) |example| {
        try sep(w, &first);
        try emitZedChrome(w, example, layout);
    }
    for (windows_examples) |example| {
        try sep(w, &first);
        try emitZedNative(w, example);
    }
    try w.writeAll("\n]\n");
    return aw.written();
}

fn buildZedTasks(
    gpa: Allocator,
    web_examples: []const Example,
    windows_examples: []const Example,
    layout: Layout,
) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll("[\n");
    var first: bool = true;
    try sep(w, &first);
    try emitZedServeTask(w, layout);
    for (web_examples) |example| {
        try sep(w, &first);
        try emitZedBuildTask(w, example.step);
        try sep(w, &first);
        try emitZedReleaseTask(w, example.step);
    }
    for (windows_examples) |example| {
        try sep(w, &first);
        try emitZedNativeBuildTask(w, example.step);
    }
    try sep(w, &first);
    try w.writeAll(zed_extra_release);
    try sep(w, &first);
    try w.writeAll(zed_extra_test);
    if (layout.smoke_task) {
        try sep(w, &first);
        try w.writeAll(zed_extra_smoke);
    }
    try w.writeAll("\n]\n");
    return aw.written();
}

/// The command line (std's cli, `src/command_line.zig`): the web apps, the Windows apps, whose layout they follow, and
/// whether to compare rather than write.
const ConfigsArgs = struct {
    @"--check": bool = false,
    @"--project": bool = false,
    @"--port": []const u8 = "8080",
    @"--windows": []const []const u8 = &.{},
    apps: []const []const u8 = &.{},
};

const configs_cli: cli.Config(ConfigsArgs) = .{
    .prog = "gen_editor_configs",
    .description = "Writes .vscode/launch.json, .vscode/tasks.json, .zed/debug.json and .zed/tasks.json for the " ++
        "apps named: a debug config, a build task and a release task per app, and a native debug config with its " ++
        "build task per --windows app.",
    .args = .{
        .@"--check" = .{ .description = "compare the four files with what they should hold; write nothing" },
        .@"--project" = .{ .description = "the apps are a zimr.Project's, written from the project's root" },
        .@"--port" = .{ .description = "the port the dev server listens on" },
        .@"--windows" = .{ .description = "an app with a Windows program, by name, once each (build.zig passes them)" },
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

    // A missing list would write the configs without those apps, and `--check` would then hold the files to that.
    // zimr's build.zig always names its web apps and its Windows apps, and a project names each app it adds as both;
    // a run without either list is a broken caller, or a project with no apps.
    if (args.apps.len == 0) {
        const who_names_apps: []const u8 = if (args.@"--project")
            "the project names each app `project.addApp` adds"
        else
            "build.zig passes every app with a web build";
        try out.print("gen_editor_configs: no apps named; {s}\n", .{who_names_apps});
        try out.flush();
        return 1;
    }
    if (args.@"--windows".len == 0) {
        try out.print("gen_editor_configs: no Windows apps named; build.zig passes each as --windows=<name>\n", .{});
        try out.flush();
        return 1;
    }
    // zimr's own configs, or a project's (`Layout` says what differs).
    const layout: Layout = if (args.@"--project") .{
        .derive_spellings = false,
        .serve_step = "serve",
        .serve_args = &.{ "build", "serve", "-Dplatform=web" },
        .port = args.@"--port",
        .smoke_task = false,
    } else .{
        .derive_spellings = true,
        .serve_step = "serve-only",
        .serve_args = &.{ "build", "serve-only" },
        .port = args.@"--port",
        .smoke_task = true,
    };
    var web_examples: ArrayList(Example) = .empty;
    var windows_examples: ArrayList(Example) = .empty;
    var duplicate_steps: ArrayList([]const u8) = .empty;
    try collectExamples(gpa, args.apps, layout.derive_spellings, &web_examples, &duplicate_steps);
    try collectExamples(gpa, args.@"--windows", layout.derive_spellings, &windows_examples, &duplicate_steps);
    if (duplicate_steps.items.len > 0) {
        for (duplicate_steps.items) |step| {
            try out.print("gen_editor_configs: two apps share the build step `{s}`\n", .{step});
        }
        try out.flush();
        return 1;
    }

    const web_apps: []const Example = web_examples.items;
    const windows_apps: []const Example = windows_examples.items;
    const config_files: [4]ConfigFile = .{
        .{ .path = ".vscode/launch.json", .text = try buildVscodeLaunch(gpa, web_apps, windows_apps, layout) },
        .{ .path = ".vscode/tasks.json", .text = try buildVscodeTasks(gpa, web_apps, windows_apps, layout) },
        .{ .path = ".zed/debug.json", .text = try buildZedDebug(gpa, web_apps, windows_apps, layout) },
        .{ .path = ".zed/tasks.json", .text = try buildZedTasks(gpa, web_apps, windows_apps, layout) },
    };
    const web_count: usize = web_examples.items.len;
    const windows_count: usize = windows_examples.items.len;

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
                "gen_editor_configs: {d} of 4 editor configs are stale for {d} web and {d} Windows apps: " ++
                    "run `zig build editor-configs`\n",
                .{ stale_count, web_count, windows_count },
            );
            try out.flush();
            return 1;
        }
        try out.print(
            "gen_editor_configs: the 4 editor configs match the {d} web and {d} Windows apps\n",
            .{ web_count, windows_count },
        );
        try out.flush();
        return 0;
    }

    for (config_files) |file| {
        // A project's first run finds no .vscode/ or .zed/ to write into.
        if (std.fs.path.dirname(file.path)) |config_dir| {
            try cwd.createDirPath(io, config_dir);
        }
        try cwd.writeFile(io, .{ .sub_path = file.path, .data = file.text });
    }
    try out.print(
        "gen_editor_configs: wrote 4 files for {d} web and {d} Windows apps\n",
        .{ web_count, windows_count },
    );
    try out.flush();
    return 0;
}
