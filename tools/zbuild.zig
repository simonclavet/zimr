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
//! Usage (pairs with the existing capture-to-log pattern):
//!     timeout 175 zig build <step> -Dmode=release -Dautofix=false -j1 >/tmp/b.log 2>&1
//!     zig run tools/zbuild.zig -- /tmp/b.log
//! Pass `-` (or no path) to read stdin instead:
//!     ... 2>&1 | zig run tools/zbuild.zig -- -
//!
//! The distiller (`distill`) is a pure function over the log text so it can be
//! unit-tested (see the tests at the bottom) without running a build.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

const max_blocks: usize = 8; // cap surfaced error blocks (avoid a wall of dups)
const max_block_lines: usize = 12; // cap snippet/note lines per block (trim ref traces)
const fallback_tail: usize = 14; // lines to show if nothing structured is recognized

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

const Kind = enum {
    err, // path:line:col: error:  -> a real compile error (root)
    note, // path:line:col: note:   -> context for the error above it
    lint, // path:line:col: [rule]  -> a lint violation (root)
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

    // ---- noise: the DAG summary + dependency bookkeeping + command echoes ----
    if (contains(line, "transitive failure") or
        contains(line, "reused dependencies") or
        contains(line, "install generated") or
        contains(line, "compile exe ") or
        contains(line, "run exe "))
    {
        return .dag;
    }
    if (std.mem.startsWith(u8, t, "+-") or std.mem.startsWith(u8, t, "+ -")) {
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
    // DAG/error/note line, so a "`: [`" is the lint format.
    if (contains(line, ": [")) {
        return .lint;
    }

    if (std.mem.startsWith(u8, t, "Build Summary:")) {
        return .summary;
    }
    if (std.mem.startsWith(u8, t, "error:")) {
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

fn seenBefore(list: []const []const u8, key: []const u8) bool {
    for (list) |k| {
        if (std.mem.eql(u8, k, key)) {
            return true;
        }
    }
    return false;
}

fn appendLine(out: *std.ArrayList(u8), gpa: Allocator, line: []const u8) !void {
    try out.appendSlice(gpa, line);
    try out.append(gpa, '\n');
}

/// The distiller. Reads the raw build log, writes a distilled report into `out`.
/// Pure over `input` (no I/O) so it can be unit-tested.
pub fn distill(gpa: Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    // Ring of recent non-noise lines, for the fallback tail.
    var recent: std.ArrayList([]const u8) = .empty;
    defer recent.deinit(gpa);

    var blocks: usize = 0;
    var suppressed: usize = 0;
    var in_block: bool = false;
    var block_lines: usize = 0;
    var summary_line: ?[]const u8 = null;
    var saw_failure: bool = false;

    var it = std.mem.splitScalar(u8, input, '\n');
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
            .dag, .other => {
                in_block = false;
                suppressed += 1;
            },
            .blank => in_block = false,
        }
    }

    // ---- compose: header, body (or fallback), footer ----
    const bar: []const u8 = "\u{2501}\u{2501}\u{2501} ";
    const bar_end: []const u8 = " \u{2501}\u{2501}\u{2501}\n";
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
        try out.appendSlice(gpa, "zbuild: no structured error recognized \u{2014} tail");
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

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    // ---- collect args (own each string) ----
    var argv: std.ArrayList([]u8) = .empty;
    defer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator =
        try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try argv.append(gpa, try gpa.dupe(u8, arg));
    }

    // ---- read the log: first positional arg is a path; "-"/absent = stdin ----
    const path: ?[]const u8 = if (argv.items.len > 1 and !std.mem.eql(u8, argv.items[1], "-"))
        argv.items[1]
    else
        null;

    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const input: []u8 = if (path) |p|
        try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited)
    else blk: {
        var rbuf: [4096]u8 = undefined;
        var stdin_r: std.Io.File.Reader = std.Io.File.stdin().reader(io, &rbuf);
        break :blk try stdin_r.interface.allocRemaining(arena, .unlimited);
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try distill(gpa, input, &out);

    var obuf: [4096]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &obuf);
    try stdout_w.interface.writeAll(out.items);
    try stdout_w.interface.flush();
}

// ============================================================================
// Tests - feed realistic captured logs through `distill`, assert the root
// surfaces and the cascade is gone.
// ============================================================================
const testing = std.testing;

fn runDistill(input: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
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
    var out: std.ArrayList(u8) = try runDistill(log);
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
    var out: std.ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    // the error text should appear exactly once
    var count: usize = 0;
    var i: usize = 0;
    const needle: []const u8 = "expected type 'u32'";
    while (std.mem.indexOfPos(u8, out.items, i, needle)) |p| {
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
    var out: std.ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "[line-length]"));
    try testing.expect(contains(out.items, "[fn-args-multiline]"));
}

test "clean build reports no errors" {
    const log: []const u8 =
        \\steps [==] 12/12
        \\Build Summary: 12/12 steps succeeded
    ;
    var out: std.ArrayList(u8) = try runDistill(log);
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
    var out: std.ArrayList(u8) = try runDistill(log);
    defer out.deinit(testing.allocator);
    try testing.expect(contains(out.items, "no structured error recognized"));
    try testing.expect(contains(out.items, "unrecognized failure detail"));
    try testing.expect(!contains(out.items, "transitive failure"));
}
