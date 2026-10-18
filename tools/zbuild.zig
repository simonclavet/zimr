//! zbuild - a build-log distiller for `zig build`.
//!
//! `zig build`'s failure summary is a DAG of "transitive failure" nodes, and
//! the ONE line that actually matters - the first `path:line:col: error:` - is
//! buried mid-log, often re-printed, and sits next to unrelated tool nodes
//! (c2js, spv2wgsl) that also say "transitive failure". Reading it by eye or by
//! ad-hoc `grep` is how a three-line fix turns into a long hunt (see the
//! lightmap episode in claude.md).
//!
//! This tool reads a captured build log and prints ONLY the roots: the real
//! compile-error and lint blocks (each error line + its source snippet +
//! attached notes), de-duplicated, with the DAG tree / reused-dependency /
//! command-echo noise suppressed. "transitive failure" is NEVER a root - it's
//! always a downstream node - so those lines are dropped on sight.
//!
//! Usage - in place of `zig build`, same arguments, from the repository root:
//!     zig build zbuild                                  once: installs it into tools/zig-out/bin
//!     tools/zig-out/bin/zbuild check -j1                runs `zig build check -j1`
//!     tools/zig-out/bin/zbuild --log=/tmp/b.log         distills a log captured earlier
//! A project built on zimr (`zimr.Project`) has the same `zig build zbuild`, which installs it into the project's
//! zig-out/bin instead: `zig-out/bin/zbuild check`.
//! It passes the build's output through as it comes - whole lines, each stream's, so neither splits the other's -
//! and announces each finding the moment the build prints it, on a line of its own beginning `zbuild: found:`: a
//! compile error, or a lint finding. A file the linter's autofix rewrote is announced too, `zbuild: fixed: <file>:
//! <rule> x<count>`, as a notice rather than a finding - the build goes on to check it - so that whoever edits that
//! file next reads it again first. A finding of a lint rule still in progress (`[rule, work in progress]`), which
//! never fails a run, is announced as `zbuild: work in progress:` and changes nothing else. When the build fails it
//! ENDS with only the roots - so
//! the answer is the last thing on screen. Both streams come through pipes, which cannot be written positionally, so
//! a finding on stdout is never overwritten by stderr the way `> log 2>&1` does it.
//!
//! By default the build stops at its first finding: once the report holding it is whole - the build's output quiet
//! for a quarter of a second, or two seconds gone - everything it started, its build runner, the compilers, the
//! linter, is stopped with it, and the report follows, instead of after every other step has run. Stopping
//! is safe: the linter writes the files it fixes whole or not at all, and the compiler's cache moves each result into
//! place in one step. `--complete` runs the build to its end instead, for a report of everything: the gate, a change
//! touching many files, a check of several targets at once, or outputs wanted despite a finding elsewhere.
//!
//! The distiller (`distill`) is a pure function over the log text so it can be
//! unit-tested (see the tests at the bottom) without running a build.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const Io = std.Io;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;
const splitScalar = std.mem.splitScalar;
const trim = std.mem.trim;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const lastIndexOfScalar = std.mem.lastIndexOfScalar;
const indexOfPos = std.mem.indexOfPos;
const startsWith = std.mem.startsWith;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const max_blocks: usize = 8; // cap surfaced error blocks (avoid a wall of dups)
const max_block_lines: usize = 12; // cap snippet/note lines per block (trim ref traces)
const fallback_tail: usize = 14; // lines to show if nothing structured is recognized
const max_command: usize = 240; // a failing step's command, cut to this

fn contains(haystack: []const u8, needle: []const u8) bool {
    return indexOf(u8, haystack, needle) != null;
}

fn trimmed(s: []const u8) []const u8 {
    return trim(u8, s, " \t\r\n");
}

/// What the linter's autofix says of a file it rewrote (`zimrlint: fixed <path>: <rule> x<count>, ...`): the text
/// after the prefix, or null for any other line.
fn fixedFileReport(line: []const u8) ?[]const u8 {
    const prefix: []const u8 = "zimrlint: fixed ";
    const start: usize = indexOf(u8, line, prefix) orelse return null;
    const report_start: usize = start + prefix.len;
    return trimmed(line[report_start..]);
}

const Kind = enum {
    err, // path:line:col: error:  -> a real compile error (root)
    failed_step, // "+- run exe X failure" (no "transitive") -> a step that failed on its own (root)
    failed_command, // "failed command: ..." -> what that step ran
    note, // path:line:col: note:   -> context for the error above it
    lint, // path:line:col: [rule]  -> a lint violation (root)
    work_in_progress, // path:line:col: [rule, work in progress] -> a rule in progress: never failing (not a root)
    snippet, // indented source / caret under a diagnostic
    dag, // transitive-failure tree, reused deps, command echoes -> noise
    summary, // "Build Summary: ..."     -> kept as a footer
    blank,
    meta_err, // bare "error: ..." that isn't the boilerplate command-failed line
    other,
};

/// Classify a single log line. Order matters: noise patterns are tested before
/// the diagnostic patterns so a DAG line that happens to contain "error" (e.g.
/// "compile exe X ... 1 errors") is dropped, not surfaced.
fn classify(line: []const u8) Kind {
    const t: []const u8 = trimmed(line);
    if (t.len == 0) {
        return .blank;
    }

    // ---- a LEAF of the failure tree: a step that failed on its own - a tool exiting non-zero, a failing run -
    // "failure" without "transitive". Everything above it in the tree is noise; this is the root, and the
    // `failed command:` line after it says exactly what ran. Tested before the noise rules, which drop every
    // `run exe` line.
    const leaf_failure: bool = endsWith(u8, t, " failure") and !contains(t, "transitive failure");
    if (leaf_failure) {
        return .failed_step;
    }
    if (startsWith(u8, t, "failed command:")) {
        return .failed_command;
    }

    // ---- noise: the DAG summary + dependency bookkeeping + command echoes ----
    if (contains(line, "transitive failure") or
        contains(line, "reused dependencies") or
        contains(line, "install generated") or
        contains(line, "compile exe ") or
        contains(line, "run exe "))
    {
        return .dag;
    }
    if (startsWith(u8, t, "+-") or startsWith(u8, t, "+ -")) {
        return .dag;
    }
    // A compiler / lint invocation echo: a very long line that isn't a
    // diagnostic (the `zig build-exe ... -M... -I...` or `lint_zimr ./a ./b ...` blob).
    if (line.len > 280 and !contains(line, ": error:") and !contains(line, ": note:")) {
        return .dag;
    }

    // ---- diagnostics (the roots we want) ----
    if (contains(line, ": error:")) {
        return .err;
    }
    if (contains(line, ": note:")) {
        return .note;
    }
    // Lint rule line: "path:line:col: [rule-name] message". By here it isn't a
    // DAG/error/note line, so a "`: [`" is the lint format - of a rule still in progress when its brackets say so,
    // which the linter prints but never fails a run for.
    if (contains(line, ": [") and contains(line, ", work in progress] ")) {
        return .work_in_progress;
    }
    if (contains(line, ": [")) {
        return .lint;
    }

    if (startsWith(u8, t, "Build Summary:")) {
        return .summary;
    }
    if (startsWith(u8, t, "error:")) {
        // Drop the boilerplate that precedes a command echo; keep genuine short
        // meta errors (FileNotFound, OutOfMemory, unable to spawn, ...).
        if (contains(line, "the following") or contains(line, "command failed")) {
            return .dag;
        }
        return .meta_err;
    }

    // Indented, not otherwise classified -> a source snippet or caret. Only
    // meaningful when it sits under a surfaced diagnostic (handled by caller).
    if (line[0] == ' ' or line[0] == '\t') {
        return .snippet;
    }
    return .other;
}

/// A finding, as the build prints one: a compile error (`path:line:col: error:`) or a lint finding
/// (`path:line:col: [rule]`) - the lines `distill` keeps as roots.
fn isFinding(line: []const u8) bool {
    const kind: Kind = classify(line);
    return kind == .err or kind == .lint;
}

fn seenBefore(list: []const []const u8, key: []const u8) bool {
    for (list) |k| {
        if (eql(u8, k, key)) {
            return true;
        }
    }
    return false;
}

fn appendLine(out: *ArrayList(u8), gpa: Allocator, line: []const u8) !void {
    try out.appendSlice(gpa, line);
    try out.append(gpa, '\n');
}

/// The distiller. Reads the raw build log, writes a distilled report into `out`.
/// Pure over `input` (no I/O) so it can be unit-tested.
pub fn distill(gpa: Allocator, input: []const u8, out: *ArrayList(u8)) !void {
    var body: ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var seen: ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    // Ring of recent non-noise lines, for the fallback tail.
    var recent: ArrayList([]const u8) = .empty;
    defer recent.deinit(gpa);

    var blocks: usize = 0;
    var suppressed: usize = 0;
    var in_block: bool = false;
    var block_lines: usize = 0;
    var summary_line: ?[]const u8 = null;
    var saw_failure: bool = false;
    // A failing step's `failed command:` belongs to it even with `error: process exited with code N` in between,
    // so the step AWAITS its command rather than keeping a block open; only another root cancels that.
    var step_awaits_command: bool = false;

    var it = splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line: []const u8 = std.mem.trimEnd(u8, raw, "\r");
        const k: Kind = classify(line);
        if (k == .dag) {
            saw_failure = true;
        }
        if (k != .blank and k != .dag) {
            try recent.append(gpa, line);
            if (recent.items.len > fallback_tail) {
                _ = recent.orderedRemove(0);
            }
        }
        switch (k) {
            .err, .lint => {
                saw_failure = true;
                step_awaits_command = false;
                const key: []const u8 = trimmed(line);
                if (seenBefore(seen.items, key)) {
                    in_block = false;
                    suppressed += 1;
                    continue;
                }
                try seen.append(gpa, key);
                if (blocks >= max_blocks) {
                    in_block = false;
                    suppressed += 1;
                    continue;
                }
                if (blocks > 0) {
                    try body.append(gpa, '\n'); // blank between blocks
                }
                try appendLine(&body, gpa, line);
                blocks += 1;
                in_block = true;
                block_lines = 0;
            },
            .failed_step => {
                saw_failure = true;
                const step_name: []const u8 = std.mem.trimStart(u8, trimmed(line), "+- ");
                if (seenBefore(seen.items, step_name)) {
                    in_block = false;
                    continue;
                }
                try seen.append(gpa, step_name);
                if (blocks > 0) {
                    try body.append(gpa, '\n');
                }
                try body.appendSlice(gpa, "failing step: ");
                try appendLine(&body, gpa, step_name);
                blocks += 1;
                in_block = false;
                step_awaits_command = true;
            },
            .failed_command => {
                // Only under its step; cut, because a lint command lists every file in the tree.
                if (step_awaits_command) {
                    step_awaits_command = false;
                    const command: []const u8 = trimmed(line);
                    const cut: bool = command.len > max_command;
                    try body.appendSlice(gpa, "  ");
                    try body.appendSlice(gpa, command[0..@min(command.len, max_command)]);
                    try appendLine(&body, gpa, if (cut) " ..." else "");
                } else {
                    suppressed += 1;
                }
            },
            .meta_err => {
                saw_failure = true;
                const key: []const u8 = trimmed(line);
                if (!seenBefore(seen.items, key)) {
                    try seen.append(gpa, key);
                    try appendLine(&body, gpa, line);
                }
                in_block = false;
            },
            .note, .snippet => {
                if (in_block and block_lines < max_block_lines) {
                    try appendLine(&body, gpa, line);
                    block_lines += 1;
                } else {
                    suppressed += 1;
                }
            },
            .summary => summary_line = line,
            .dag, .work_in_progress, .other => {
                in_block = false;
                suppressed += 1;
            },
            .blank => in_block = false,
        }
    }

    // ---- compose: header, body (or fallback), footer ----
    // ASCII only: a Windows console reads output in its OEM code page, where a UTF-8 box-drawing bar prints as junk.
    const bar: []const u8 = "=== ";
    const bar_end: []const u8 = " ===\n";
    if (blocks > 0) {
        var nb: [96]u8 = undefined;
        const stat: []u8 = try bufPrint(
            &nb,
            "zbuild: {d} root error(s) (suppressed {d} noise lines)",
            .{ blocks, suppressed },
        );
        try out.appendSlice(gpa, bar);
        try out.appendSlice(gpa, stat);
        try out.appendSlice(gpa, bar_end);
        try out.appendSlice(gpa, body.items);
    } else if (saw_failure) {
        // Nothing structured recognized, but the build failed - show a tail so
        // an unknown failure mode still yields something actionable.
        try out.appendSlice(gpa, bar);
        try out.appendSlice(gpa, "zbuild: no structured error recognized - tail");
        try out.appendSlice(gpa, bar_end);
        for (recent.items) |l| {
            try appendLine(out, gpa, l);
        }
    } else {
        try out.appendSlice(gpa, bar);
        try out.appendSlice(gpa, "zbuild: no errors detected");
        try out.appendSlice(gpa, bar_end);
    }

    if (summary_line) |s| {
        try out.appendSlice(gpa, trimmed(s));
        try out.append(gpa, '\n');
    }
}

/// zbuild's arguments are zig build's, forwarded untouched - so they cannot go through std's cli, which would read
/// `-j1` or `-Dmode=release` as zbuild options and refuse them. Its own three are recognised only as the FIRST
/// argument, where zig build takes none of them.
const usage: []const u8 =
    \\usage: zbuild <what zig build takes>   runs `zig build` with exactly those arguments, its output passed through
    \\                                       as it comes, each finding also announced at once (`zbuild: found:`), and
    \\                                       the build stopped at its first; if it fails, the output ends with only the
    \\                                       roots (errors, lint, failing steps)
    \\       zbuild --complete <...>        the same, the build run to its end: a report of everything
    \\       zbuild --log=<file>            the same distillation of a log captured earlier
    \\Installed by `zig build zbuild` - into tools/zig-out/bin in zimr, zig-out/bin in a project built on it; run
    \\from the project's root, like zig build.
    \\
;

/// `distill(log)` onto stdout.
fn report(gpa: Allocator, io: Io, log: []const u8) !void {
    var out: ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try distill(gpa, log, &out);
    try Io.File.stdout().writeStreamingAll(io, out.items);
}

/// How long the build's output must stay quiet, after its first finding, before the build is stopped - and the longest
/// it may go on after that finding. A lint run prints all its findings together, and a compile step its errors, but
/// in pieces arriving milliseconds apart: stopping at the first piece would lose the rest of the same report (a rule's
/// explanation is printed before its first finding, so a lint report runs to kilobytes). Waiting for a quiet moment
/// keeps the whole report, and still stops the minutes of unrelated compiling after it.
const stop_wait_quiet_ms: i64 = 250;
const stop_wait_longest_ns: i96 = 2 * std.time.ns_per_s;

/// Whether zbuild runs where process groups exist: there, a build is stopped whole (`stopBuild`).
const is_posix: bool = builtin.os.tag != .windows;

/// Stops the build and everything it started: on POSIX, its whole process group - the build leads it - then the build
/// itself is reaped; elsewhere, the build alone.
fn stopBuild(child: *std.process.Child, io: Io) void {
    if (is_posix) {
        if (child.id) |build_id| {
            // lint:off catch-suppression: the group may have ended already; the build is reaped just below either way
            std.posix.kill(-build_id, .TERM) catch {};
        }
    }
    child.kill(io);
}

/// The build's whole output, its standard output then its standard error, as the report reads it.
fn buildText(arena: Allocator, streams: *Io.File.MultiReader) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ streams.reader(0).buffered(), "\n", streams.reader(1).buffered() });
}

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;
    const arena: Allocator = init.arena.allocator();
    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    const first: []const u8 = if (argv.len > 1) argv[1] else "";
    const stdout: Io.File = .stdout();
    if (eql(u8, first, "--help") or eql(u8, first, "-h")) {
        try stdout.writeStreamingAll(io, usage);
        return 0;
    }
    if (startsWith(u8, first, "--log=")) {
        const log: []u8 = try Io.Dir.cwd().readFileAlloc(io, first["--log=".len..], arena, .unlimited);
        try report(gpa, io, log);
        return 0;
    }

    // The build, marked so `build.zig` can tell it was started through zbuild. `--complete` and `--fail-fast` are
    // zbuild's own - as the first argument only, like `--log` - and are not passed on. Stopping at the first finding
    // is the default; `--fail-fast` says so explicitly, for the commands written when it was not.
    const is_complete: bool = eql(u8, first, "--complete");
    const has_own_option: bool = is_complete or eql(u8, first, "--fail-fast");
    const is_fail_fast: bool = !is_complete;
    const build_arguments: []const [:0]const u8 = if (has_own_option) argv[2..] else argv[1..];
    var command: ArrayList([]const u8) = .empty;
    try command.appendSlice(arena, &.{ "zig", "build" });
    for (build_arguments) |arg| {
        try command.append(arena, arg);
    }
    try init.environ_map.put("ZIMR_ZBUILD", "1");
    var child: std.process.Child = std.process.spawn(io, .{
        .argv = command.items,
        .environ_map = init.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // On POSIX the build leads a process group of its own, so that stopping it (`--fail-fast`) stops every
        // process it started, not the first alone.
        .pgid = if (is_posix) 0 else null,
    }) catch |err| {
        // The build never started, so there is no log to distill - say so, in words. The usual reason is worth
        // naming: no `zig` on PATH (a fresh shell, or a detached job that dropped its environment - which is exactly
        // how a bare `error: FileNotFound` once sent a build nowhere and nobody the wiser).
        const hint: []const u8 = if (err == error.FileNotFound) " - is `zig` on PATH?" else "";
        const message: []const u8 = try allocPrint(arena, "zbuild: could not start `zig build`: {s}{s}\n", .{
            @errorName(err),
            hint,
        });
        try Io.File.stderr().writeStreamingAll(io, message);
        return 1;
    };
    defer child.kill(io);

    // Both streams, read as they come (`MultiReader.fill` waits until either has more). Each keeps everything read,
    // for the report at the end; `written` is how much of each has been passed through - up to its last whole line,
    // so that a line of one stream is never split by the other's.
    var streams_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var streams: Io.File.MultiReader = undefined;
    streams.init(gpa, io, streams_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer streams.deinit();
    var written: [2]usize = .{ 0, 0 };
    var finding_count: usize = 0;
    // When the first finding arrived: from then on the build is stopped once its output goes quiet, or too long has
    // passed (`stop_wait_quiet_ms`, `stop_wait_longest_ns`).
    var first_finding_at: ?Io.Clock.Timestamp = null;
    while (true) {
        const is_waiting_to_stop: bool = is_fail_fast and first_finding_at != null;
        const read_timeout: Io.Timeout = if (is_waiting_to_stop)
            .{ .duration = .{ .raw = .fromMilliseconds(stop_wait_quiet_ms), .clock = .awake } }
        else
            .none;
        var has_gone_quiet: bool = false;
        const is_end: bool = if (streams.fill(64 * 1024, read_timeout)) |_| false else |err| switch (err) {
            error.EndOfStream => true,
            error.Timeout => quiet: {
                has_gone_quiet = true;
                break :quiet false;
            },
            else => |other| return other,
        };
        for (&written, 0..) |*stream_written, stream_index| {
            const text: []const u8 = streams.reader(stream_index).buffered();
            const unwritten: []const u8 = text[stream_written.*..];
            const whole_length: usize = if (is_end)
                unwritten.len
            else if (lastIndexOfScalar(u8, unwritten, '\n')) |last_newline| last_newline + 1 else 0;
            const fresh: []const u8 = unwritten[0..whole_length];
            if (fresh.len == 0) {
                continue;
            }
            try stdout.writeStreamingAll(io, fresh);
            var lines = splitScalar(u8, fresh, '\n');
            while (lines.next()) |line| {
                if (isFinding(line)) {
                    finding_count += 1;
                    const announcement: []const u8 = try allocPrint(arena, "zbuild: found: {s}\n", .{trimmed(line)});
                    try stdout.writeStreamingAll(io, announcement);
                } else if (fixedFileReport(line)) |fixed_report| {
                    // A file the linter's autofix rewrote: announced, never a finding - the build goes on to format
                    // and check it - so that whoever edits the file next reads it again first.
                    const announcement: []const u8 = try allocPrint(arena, "zbuild: fixed: {s}\n", .{fixed_report});
                    try stdout.writeStreamingAll(io, announcement);
                } else if (classify(line) == .work_in_progress) {
                    const announcement: []const u8 = try allocPrint(
                        arena,
                        "zbuild: work in progress: {s}\n",
                        .{trimmed(line)},
                    );
                    try stdout.writeStreamingAll(io, announcement);
                }
            }
            stream_written.* += whole_length;
        }
        if (is_end) {
            break;
        }
        if (is_fail_fast and finding_count > 0 and first_finding_at == null) {
            first_finding_at = .now(io, .awake);
        }
        const has_waited_longest: bool = if (first_finding_at) |found_at|
            found_at.untilNow(io).raw.nanoseconds >= stop_wait_longest_ns
        else
            false;
        if (is_fail_fast and finding_count > 0 and (has_gone_quiet or has_waited_longest)) {
            stopBuild(&child, io);
            const stopped_note: []const u8 = "zbuild: stopped the build at its first finding " ++
                "(--complete runs it to the end)\n";
            try stdout.writeStreamingAll(io, stopped_note);
            try report(gpa, io, try buildText(arena, &streams));
            return 1;
        }
    }
    try streams.checkAnyError();
    const term: std.process.Child.Term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 1,
    };
    if (exit_code != 0) {
        try report(gpa, io, try buildText(arena, &streams));
    }
    return exit_code;
}

const testing = std.testing;

fn runDistill(input: []const u8) !ArrayList(u8) {
    var out: ArrayList(u8) = .empty;
    try distill(testing.allocator, input, &out);
    return out;
}

test "surfaces the real error, drops the transitive-failure cascade" {
    // Modelled on the actual lightmap failure: the real error is buried, then a
    // DAG of transitive failures (including unrelated tools) follows.
    const log: []const u8 =
        \\shaders-lightmap-rendering-standalone
        \\+- install generated to standalone/shaders_lightmap_rendering.html
        \\   +- run exe c2js
        \\      +- compile exe shaders_lightmap_rendering ReleaseSmall wasm32-wasi-none 1 errors
        \\src/shader_runtime.zig:696:9: error: loadShaderVF: resources in BOTH stages aren't supported
        \\        @compileError("loadShaderVF: resources ...");
        \\        ^~~~~~~~~~~~~
        \\examples/lm/lm.zig:141:75: note: generic function instantiated here
        \\    const shader = try z.shader.loadShader(...);
        \\                       ^~~~~~~~~~~~~~~~~~~~
        \\   +- run exe spv2wgsl (shader.wgsl) transitive failure
        \\      +- compile exe spv2wgsl ReleaseSafe native transitive failure
        \\Build Summary: 6/9 steps succeeded; 1 failed
        \\error: the following build command failed with exit code 1:
        \\/path/to/zig build-exe -Mroot=... -I... -femit-bin=...
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(contains(s, "loadShaderVF: resources in BOTH stages"));
    try testing.expect(contains(s, "note: generic function instantiated here"));
    try testing.expect(contains(s, "Build Summary:"));
    // the cascade + command echo must be gone
    try testing.expect(!contains(s, "transitive failure"));
    try testing.expect(!contains(s, "compile exe"));
    try testing.expect(!contains(s, "build-exe -Mroot"));
    try testing.expect(!contains(s, "install generated"));
}

test "de-duplicates a doubly-printed error" {
    const log: []const u8 =
        \\foo.zig:10:5: error: expected type 'u32', found 'bool'
        \\    const x: u32 = true;
        \\                   ^~~~
        \\some progress line
        \\foo.zig:10:5: error: expected type 'u32', found 'bool'
        \\    const x: u32 = true;
        \\                   ^~~~
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    // the error text should appear exactly once
    var count: usize = 0;
    var i: usize = 0;
    const needle: []const u8 = "expected type 'u32'";
    while (indexOfPos(u8, out.items, i, needle)) |p| {
        count += 1;
        i = p + needle.len;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "surfaces lint violations" {
    const log: []const u8 =
        \\src/codecs.zig:8623:121: [line-length] 121 cols, max 120 (rule 10)
        \\examples/foo.zig:12:1: [fn-args-multiline] put each param on its own line (rule 1)
        \\Build Summary: 3/4 steps succeeded; 1 failed
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "[line-length]"));
    try testing.expect(contains(out.items, "[fn-args-multiline]"));
}

test "a step that failed on its own is the root, with its command - not the transitive tree above it" {
    // The shape of a real `zig build lint-check` failure (Sep 28): the lint tool exited 1, and the only lines about
    // it are a leaf of the tree and its failed command. Everything else says "transitive failure".
    const log: []const u8 =
        \\lint-check
        \\+- run exe zimrlint failure
        \\error: process exited with code 1
        \\failed command: ./.zig-cache/o/410a/zimrlint --enable=untyped-local ./src/a.zig ./src/b.zig
        \\
        \\Build Summary: 3/5 steps succeeded (1 failed)
        \\lint-check transitive failure
        \\+- run exe zimrlint failure
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "failing step: run exe zimrlint failure"));
    try testing.expect(contains(out.items, "failed command: ./.zig-cache/o/410a/zimrlint"));
    try testing.expect(contains(out.items, "1 root error(s)"));
    try testing.expect(!contains(out.items, "transitive failure"));
}

test "clean build reports no errors" {
    const log: []const u8 =
        \\steps [==] 12/12
        \\Build Summary: 12/12 steps succeeded
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "no errors detected"));
    try testing.expect(contains(out.items, "Build Summary:"));
}

test "unknown failure falls back to a tail" {
    const log: []const u8 =
        \\doing a thing
        \\another thing
        \\   +- run exe mystery transitive failure
        \\some unrecognized failure detail on the last line
    ;
    var out: ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "no structured error recognized"));
    try testing.expect(contains(out.items, "unrecognized failure detail"));
    try testing.expect(!contains(out.items, "transitive failure"));
}

test "a lint line of a rule in progress is announced apart: neither a finding nor a root" {
    const in_progress_line: []const u8 = "src/a.zig:8:25: [house-rule, work in progress] write it so";
    const failing_line: []const u8 = "src/a.zig:9:1: [line-length] 125 cols, max 120 (rule 10)";
    try testing.expect(!isFinding(in_progress_line));
    try testing.expect(classify(in_progress_line) == .work_in_progress);
    try testing.expect(isFinding(failing_line));
    var out: ArrayList(u8) = try runDistill(in_progress_line ++ "\n" ++ failing_line ++ "\n");
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "[line-length]"));
    try testing.expect(!contains(out.items, "house-rule"));
}

test "fixedFileReport: the linter's line for a file it fixed, and no other line" {
    const fixed_line: []const u8 = "zimrlint: fixed ./tools/x.zig: fn-args-multiline x1, no-qualified-std x2";
    try expectEqualStrings(
        "./tools/x.zig: fn-args-multiline x1, no-qualified-std x2",
        fixedFileReport(fixed_line).?,
    );
    try expect(fixedFileReport("zimrlint: 1 left in ./tools/x.zig for a person") == null);
    try expect(fixedFileReport("./tools/x.zig:3:1: [line-length] 129 cols, max 120 (rule 10)") == null);
}
