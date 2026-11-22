//! c2js_diff - the c2js differential gate: each case's JavaScript must answer what the native program answers.
//!
//!     zig build c2js-diff
//!
//! Every case in `<cases>/cases/` is a Zig program exporting `run_test() i32`. Its answer is computed three ways, and
//! the three must agree:
//!   * NATIVE - the case with `oracle_main.zig` appended, built for this machine and run. The ground truth: the
//!     compiler's own semantics on real hardware, so no expected value is ever written by hand.
//!   * PAGE - Zig -> C (`-ofmt=c`, wasm32) -> c2js -> JavaScript, run by node as a page runs it (`run_as_page.js`).
//!   * WORKLET - the same JavaScript as an audio worklet loads it: strict mode, and no atob, TextDecoder or
//!     TextEncoder, so the prelude's own base64 and UTF-8 are used (`run_as_worklet.js`).
//! A case whose JavaScript holds a `/*TODO` or `/*?` marker - a lowering c2js did not handle, or was unsure of - fails
//! even when its answer matches: the answer may be wrong for other inputs.
//!
//! Then the JS-only cases (`<cases>/js_cases/`): programs reaching JavaScript itself through the kernel, which have no
//! native program to compare with. Each runs against its fixture (`<name>.fixture.js`) and checks itself - run_test()
//! returns 0 - as a page and as a worklet. Last, the prelude's base64 and UTF-8 fallbacks are tested against the
//! built-ins they stand in for (`prelude_fallbacks_test.js`), on the first case's JavaScript.
//!
//! A case that fails is reported with why, and the run goes on to the next, so one run lists every failure.
//! `--known-fail <name>` marks a case failing for a known upstream reason (a Zig C-backend change c2js has not caught
//! up with): it reports XFAIL and does not fail the gate, and XPASS once it passes again - time to take it off.
//!
//! THE CASES RUN AT ONCE, as many as the machine has cores (std.Io's own task limit). Each case is two compiles and a
//! handful of programs, independent of every other case, and one after another a hundred of them left all but one
//! core idle. Each case writes into a report of its own, printed in case order once every case is done, so the
//! output reads the same from run to run: a finished report waits only for the reports before it (`Printer`).
//!
//! It replaces `differential.sh`, which needed a POSIX shell and whose oracle wrote its answer with a Linux system
//! call: in Zig, the gate runs wherever Zig does, Windows included.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Child = std.process.Child;
const RunResult = std.process.RunResult;
const allocPrint = std.fmt.allocPrint;
const concat = std.mem.concat;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const lessThan = std.mem.lessThan;
const sortSlice = std.mem.sort;
const splitScalar = std.mem.splitScalar;
const stem = std.fs.path.stem;
const trim = std.mem.trim;

const DiffArgs = struct {
    @"--known-fail": []const []const u8 = &.{},
    @"--node": []const u8 = "node",
    zig: []const u8,
    c2js: []const u8,
    cases: []const u8,
    scratch: []const u8,
};

const diff_cli: cli.Config(DiffArgs) = .{
    .prog = "c2js_diff",
    .description = "Differential-tests c2js: each case's JavaScript against the native program Zig makes of it.",
    .args = .{
        .@"--known-fail" = .{ .description = "a case failing for a known upstream reason: XFAIL, not a failure" },
        .@"--node" = .{ .description = "the node executable" },
        .zig = .{ .description = "the Zig compiler that builds the cases" },
        .c2js = .{ .description = "the c2js transpiler under test" },
        .cases = .{ .description = "tools/c2js_cases: cases/, js_cases/, oracle_main.zig and the node runners" },
        .scratch = .{ .description = "the directory the intermediate files go in" },
    },
};

/// The largest source or transpiled program read whole. The biggest case's JavaScript is a few hundred kilobytes.
const file_limit: Io.Limit = .limited(64 * 1024 * 1024);

/// What one check came to. `not_reached` is a check stopped before a verdict - a program that would not start, a
/// file that would not open - which `Diff.stopped_by` says more of.
const Verdict = enum { not_reached, agreed, js_only_passed, prelude_passed, failed, known_failed, unexpectedly_passed };

/// Which check a `Diff` runs.
const Kind = enum { differential, js_only, prelude };

/// What the run found, counted from every check's verdict once they are all done.
const Tally = struct {
    agreed: u32 = 0,
    js_only_passed: u32 = 0,
    failed: u32 = 0,
    known_failed: u32 = 0,
    unexpectedly_passed: u32 = 0,

    fn count(tally: *Tally, verdict: Verdict) void {
        switch (verdict) {
            .agreed => tally.agreed += 1,
            .js_only_passed => tally.js_only_passed += 1,
            .known_failed => tally.known_failed += 1,
            .unexpectedly_passed => tally.unexpectedly_passed += 1,
            // A check that never reached a verdict did not pass.
            .failed, .not_reached => tally.failed += 1,
            .prelude_passed => {},
        }
    }
};

/// One check - a case, or the prelude test - and everything it needs. Each has an arena of its own, because the cases
/// run at once and an arena is not threadsafe, and a report of its own, which the `Printer` prints in case order.
const Diff = struct {
    io: Io,
    args: DiffArgs,
    kind: Kind,
    /// Set by the printer, under its mutex, once the check has finished.
    done: bool = false,
    /// The case's source; empty for the prelude test.
    case_path: []const u8,
    /// `oracle_main.zig`, read once and shared: every task only reads it.
    oracle_source: []const u8,
    arena_state: ArenaAllocator,
    /// `arena_state`'s interface, taken once the `Diff` is at its final address.
    arena: Allocator,
    report: ArrayList(u8) = .empty,
    verdict: Verdict = .not_reached,
    /// The JavaScript this check made or reads: a case's own once transpiled, and for the prelude test the first
    /// case's, which it takes the fallbacks from.
    js_path: ?[]const u8 = null,
    /// What stopped the check before a verdict.
    stopped_by: ?anyerror = null,
};

/// A finished check's report, and what stopped it, if anything did. Its task is over, so its arena is free to use.
fn printReport(io: Io, check: *Diff) !void {
    try File.stdout().writeStreamingAll(io, check.report.items);
    const stopped_by: anyerror = check.stopped_by orelse return;
    const label: []const u8 = if (check.kind == .prelude) "prelude fallbacks" else stem(check.case_path);
    const stop_line: []u8 = try allocPrint(check.arena, "  FAIL  {s: <22} the check stopped: {s}\n", .{
        label, @errorName(stopped_by),
    });
    try File.stdout().writeStreamingAll(io, stop_line);
}

/// The run's output, and the checks it comes from: every check's report in case order, each printed as soon as it and
/// every check before it are done. The cases finish in any order; a finished report waits only for the ones before
/// it, so the output streams as the run goes and still reads the same from run to run.
const Printer = struct {
    io: Io,
    checks: []Diff,
    mutex: Io.Mutex = .init,
    /// The first check whose report is not out yet.
    next: usize = 0,

    /// Check `index` has finished: print every report that can now go out.
    fn finished(printer: *Printer, index: usize) void {
        printer.mutex.lockUncancelable(printer.io);
        defer printer.mutex.unlock(printer.io);
        printer.checks[index].done = true;
        while (printer.next < printer.checks.len) {
            const check: *Diff = &printer.checks[printer.next];
            if (!check.done) {
                break;
            }
            // lint:off catch-suppression: a report that cannot reach stdout has nowhere else to go
            printReport(printer.io, check) catch {};
            printer.next += 1;
        }
    }
};

fn say(d: *Diff, comptime format: []const u8, args: anytype) !void {
    const text: []u8 = try allocPrint(d.arena, format, args);
    try d.report.appendSlice(d.arena, text);
}

/// The first `max_lines` lines of `text`, indented under the case they explain.
fn sayFirstLines(d: *Diff, text: []const u8, max_lines: usize) !void {
    var lines = splitScalar(u8, trim(u8, text, " \t\r\n"), '\n');
    var printed: usize = 0;
    while (lines.next()) |line| {
        const has_room: bool = printed < max_lines;
        if (!has_room) {
            break;
        }
        try say(d, "          {s}\n", .{trim(u8, line, "\r")});
        printed += 1;
    }
}

/// Run `argv` to its end and collect what it printed. A program that cannot be started - node missing from PATH -
/// is an error: it stops this case's check, and the report says why (`runCheck`).
fn run(d: *const Diff, argv: []const []const u8) !RunResult {
    return std.process.run(d.arena, d.io, .{ .argv = argv });
}

/// What a program answered: its standard output without the line ending, as a shell's `$(...)` reads it.
fn answerOf(result: RunResult) []const u8 {
    return trim(u8, result.stdout, " \t\r\n");
}

fn casesPath(d: *const Diff, name: []const u8) ![]u8 {
    return allocPrint(d.arena, "{s}/{s}", .{ d.args.cases, name });
}

fn scratchPath(d: *const Diff, file_stem: []const u8, extension: []const u8) ![]u8 {
    return allocPrint(d.arena, "{s}/{s}{s}", .{ d.args.scratch, file_stem, extension });
}

/// Delete an intermediate file the run no longer needs. One never made (a .pdb off Windows) is already gone; one that
/// will not go is said and left - it costs disk, never a verdict.
fn removeScratch(d: *Diff, path: []const u8) void {
    Dir.cwd().deleteFile(d.io, path) catch |err| {
        const was_never_made: bool = err == error.FileNotFound;
        if (!was_never_made) {
            // lint:off catch-suppression: a note that cannot be written to stdout has nowhere else to go
            say(d, "  note  could not delete {s}: {s}\n", .{ path, @errorName(err) }) catch {};
        }
    };
}

fn nameLessThan(_: void, left: []const u8, right: []const u8) bool {
    return lessThan(u8, left, right);
}

/// The `.zig` files directly inside `dir_path`, as paths, sorted by name so every run reports in the same order.
fn listCases(io: Io, arena: Allocator, dir_path: []const u8) ![]const []const u8 {
    const dir: Dir = try Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: ArrayList([]const u8) = .empty;
    var entries: Dir.Iterator = dir.iterate();
    while (try entries.next(io)) |entry| {
        const is_zig_file: bool = entry.kind == .file and endsWith(u8, entry.name, ".zig");
        if (is_zig_file) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    sortSlice([]const u8, names.items, {}, nameLessThan);
    var paths: ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        try paths.append(arena, try allocPrint(arena, "{s}/{s}", .{ dir_path, name }));
    }
    return paths.items;
}

/// How many lines of `js` carry a marker c2js leaves where it did not handle the C (`/*TODO`) or was unsure of it
/// (`/*?`).
fn markerLines(js: []const u8) u32 {
    var count: u32 = 0;
    var lines = splitScalar(u8, js, '\n');
    while (lines.next()) |line| {
        const has_todo: bool = indexOf(u8, line, "/*TODO") != null;
        const has_doubt: bool = indexOf(u8, line, "/*?") != null;
        if (has_todo or has_doubt) {
            count += 1;
        }
    }
    return count;
}

fn isKnownFail(d: *const Diff, name: []const u8) bool {
    for (d.args.@"--known-fail") |known| {
        if (eql(u8, known, name)) {
            return true;
        }
    }
    return false;
}

/// Zig -> C -> JavaScript: the case built to C for wasm32, as the web build makes it, then put through c2js. Returns
/// the JavaScript's path, or null when a step failed - reported, with the first lines of why, and counted.
fn transpile(
    d: *Diff,
    label: []const u8,
    case_path: []const u8,
    file_stem: []const u8,
) !?[]const u8 {
    const c_path: []u8 = try scratchPath(d, file_stem, ".c");
    const js_path: []u8 = try scratchPath(d, file_stem, ".js");
    const refusal_path: []u8 = try scratchPath(d, file_stem, ".c2err");
    const emit_c: []u8 = try allocPrint(d.arena, "-femit-bin={s}", .{c_path});
    const c_build: RunResult = try run(d, &.{
        d.args.zig, "build-obj", case_path, "-ofmt=c", "-OReleaseSmall", "-target", "wasm32-freestanding", emit_c,
    });
    if (!c_build.term.success()) {
        try say(d, "  FAIL  {s: <22} the C build failed:\n", .{label});
        try sayFirstLines(d, c_build.stderr, 8);
        d.verdict = .failed;
        return null;
    }
    defer removeScratch(d, c_path);

    // c2js is a filter - C on stdin, JavaScript on stdout - so it is handed files, which leave nothing to pump.
    const cwd: Dir = .cwd();
    const c_file: File = try cwd.openFile(d.io, c_path, .{});
    defer c_file.close(d.io);
    const js_file: File = try cwd.createFile(d.io, js_path, .{});
    defer js_file.close(d.io);
    const refusal_file: File = try cwd.createFile(d.io, refusal_path, .{});
    defer refusal_file.close(d.io);
    var c2js: Child = try std.process.spawn(d.io, .{
        .argv = &.{d.args.c2js},
        .stdin = .{ .file = c_file },
        .stdout = .{ .file = js_file },
        .stderr = .{ .file = refusal_file },
    });
    const c2js_term: Child.Term = try c2js.wait(d.io);
    // c2js refuses C it does not model, saying what, rather than guessing at it.
    if (!c2js_term.success()) {
        const refusal: []u8 = try cwd.readFileAlloc(d.io, refusal_path, d.arena, file_limit);
        try say(d, "  FAIL  {s: <22} c2js refused the C:\n", .{label});
        try sayFirstLines(d, refusal, 8);
        d.verdict = .failed;
        return null;
    }
    return js_path;
}

/// One differential case: the native program's answer, then its JavaScript's as a page and as a worklet.
fn checkCase(d: *Diff) !void {
    const case_path: []const u8 = d.case_path;
    const name: []const u8 = stem(case_path);
    const cwd: Dir = .cwd();

    // The native oracle: the case with a main appended, built for this machine. The executable is named with this
    // machine's extension, since Windows runs nothing without one.
    const native_stem: []u8 = try allocPrint(d.arena, "{s}.native", .{name});
    const native_source_path: []u8 = try scratchPath(d, native_stem, ".zig");
    const native_exe_path: []u8 = try scratchPath(d, native_stem, builtin.target.exeFileExt());
    const native_pdb_path: []u8 = try scratchPath(d, native_stem, ".pdb");
    // The executables are large: only the small files are kept, to read when a case fails.
    defer removeScratch(d, native_source_path);
    defer removeScratch(d, native_exe_path);
    defer removeScratch(d, native_pdb_path);
    const case_source: []u8 = try cwd.readFileAlloc(d.io, case_path, d.arena, file_limit);
    const native_source: []u8 = try concat(d.arena, u8, &.{ case_source, "\n", d.oracle_source });
    try cwd.writeFile(d.io, .{ .sub_path = native_source_path, .data = native_source });
    const emit_native: []u8 = try allocPrint(d.arena, "-femit-bin={s}", .{native_exe_path});
    const native_build: RunResult = try run(d, &.{ d.args.zig, "build-exe", native_source_path, emit_native });
    if (!native_build.term.success()) {
        try say(d, "  FAIL  {s: <22} the native build failed:\n", .{name});
        try sayFirstLines(d, native_build.stderr, 8);
        d.verdict = .failed;
        return;
    }
    const native_run: RunResult = try run(d, &.{native_exe_path});
    if (!native_run.term.success()) {
        try say(d, "  FAIL  {s: <22} the native program failed:\n", .{name});
        try sayFirstLines(d, native_run.stderr, 8);
        d.verdict = .failed;
        return;
    }
    const native: []const u8 = answerOf(native_run);

    // The JavaScript, run as a page and as a worklet.
    const js_path: []const u8 = (try transpile(d, name, case_path, name)) orelse return;
    d.js_path = js_path;
    const js_source: []u8 = try cwd.readFileAlloc(d.io, js_path, d.arena, file_limit);
    const markers: u32 = markerLines(js_source);
    const page_run: RunResult = try run(d, &.{ d.args.@"--node", try casesPath(d, "run_as_page.js"), js_path });
    const worklet_run: RunResult = try run(d, &.{ d.args.@"--node", try casesPath(d, "run_as_worklet.js"), js_path });
    const page: []const u8 = answerOf(page_run);
    const worklet: []const u8 = answerOf(worklet_run);

    const answers_agree: bool = eql(u8, native, page) and eql(u8, native, worklet);
    const is_unmarked: bool = markers == 0;
    const case_passes: bool = answers_agree and is_unmarked;
    const is_known_fail: bool = isKnownFail(d, name);
    if (case_passes and is_known_fail) {
        try say(d, "  XPASS {s: <22} a known failure now PASSES - take it off --known-fail\n", .{name});
        d.verdict = .unexpectedly_passed;
        return;
    }
    if (case_passes) {
        try say(d, "  ok    {s: <22} native={s} js={s} worklet={s} markers=0\n", .{ name, native, page, worklet });
        d.verdict = .agreed;
        return;
    }
    const detail: []u8 = if (is_unmarked)
        try allocPrint(d.arena, "native={s}  js={s}  worklet={s}  markers=0", .{ native, page, worklet })
    else
        try allocPrint(d.arena, "{d} unhandled-C marker(s)  native={s} js={s}", .{ markers, native, page });
    if (is_known_fail) {
        try say(d, "  XFAIL {s: <22} (known drift) {s}\n", .{ name, detail });
        d.verdict = .known_failed;
        return;
    }
    try say(d, "  FAIL  {s: <22} {s}\n", .{ name, detail });
    d.verdict = .failed;
}

/// One JS-only case: transpiled like the others, then run against its fixture as a page and as a worklet, where it
/// checks itself - run_test() returns 0.
fn checkJsOnlyCase(d: *Diff) !void {
    const case_path: []const u8 = d.case_path;
    const name: []const u8 = stem(case_path);
    const label: []u8 = try allocPrint(d.arena, "js:{s}", .{name});
    const file_stem: []u8 = try allocPrint(d.arena, "js_{s}", .{name});
    const js_path: []const u8 = (try transpile(d, label, case_path, file_stem)) orelse return;
    const fixture_name: []u8 = try allocPrint(d.arena, "js_cases/{s}.fixture.js", .{name});
    const fixture_path: []u8 = try casesPath(d, fixture_name);
    const runner_path: []u8 = try casesPath(d, "run_js_case.js");
    const page_run: RunResult = try run(d, &.{ d.args.@"--node", runner_path, js_path, fixture_path, "page" });
    const worklet_run: RunResult = try run(d, &.{ d.args.@"--node", runner_path, js_path, fixture_path, "worklet" });
    const page: []const u8 = answerOf(page_run);
    const worklet: []const u8 = answerOf(worklet_run);
    const both_succeed: bool = eql(u8, page, "0") and eql(u8, worklet, "0");
    if (both_succeed) {
        try say(d, "  ok    {s: <22} page={s} worklet={s}\n", .{ label, page, worklet });
        d.verdict = .js_only_passed;
        return;
    }
    try say(d, "  FAIL  {s: <22} page={s} worklet={s} (0 is success)\n", .{ label, page, worklet });
    d.verdict = .failed;
}

/// The prelude's base64 and UTF-8 fallbacks, taken from the first case's JavaScript as c2js emitted them, against the
/// built-ins they stand in for. With no JavaScript - no case got that far - there is nothing to test, and the cases'
/// own failures already fail the run.
fn checkPreludeFallbacks(d: *Diff) !void {
    const js_path: []const u8 = d.js_path orelse {
        d.verdict = .prelude_passed;
        return;
    };
    const tester_path: []u8 = try casesPath(d, "prelude_fallbacks_test.js");
    const result: RunResult = try run(d, &.{ d.args.@"--node", tester_path, js_path });
    if (!result.term.success()) {
        try say(d, "  FAIL  prelude fallbacks differ from the built-ins:\n", .{});
        const everything_printed: []u8 = try concat(d.arena, u8, &.{ result.stdout, result.stderr });
        try sayFirstLines(d, everything_printed, 12);
        d.verdict = .failed;
        return;
    }
    var lines = splitScalar(u8, trim(u8, result.stdout, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        try say(d, "  ok    prelude fallbacks: {s}\n", .{trim(u8, line, "\r")});
    }
    d.verdict = .prelude_passed;
}

/// One check, as a task. Whatever stops it is kept with its report rather than lost on another thread - a task can
/// return nothing but cancelation - and the report goes to the printer the moment the check is over.
fn runCheck(printer: *Printer, index: usize) void {
    const d: *Diff = &printer.checks[index];
    const outcome: anyerror!void = switch (d.kind) {
        .differential => checkCase(d),
        .js_only => checkJsOnlyCase(d),
        .prelude => checkPreludeFallbacks(d),
    };
    outcome catch |err| {
        d.stopped_by = err;
    };
    printer.finished(index);
}

pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const args: DiffArgs = cli.args(&init, DiffArgs, diff_cli);
    try Dir.cwd().createDirPath(io, args.scratch);

    const oracle_path: []u8 = try allocPrint(arena, "{s}/oracle_main.zig", .{args.cases});
    const oracle_source: []u8 = try Dir.cwd().readFileAlloc(io, oracle_path, arena, file_limit);
    const differential_dir: []u8 = try allocPrint(arena, "{s}/cases", .{args.cases});
    const js_only_dir: []u8 = try allocPrint(arena, "{s}/js_cases", .{args.cases});
    const differential_paths: []const []const u8 = try listCases(io, arena, differential_dir);
    const js_only_paths: []const []const u8 = try listCases(io, arena, js_only_dir);

    // Every case, then the prelude test last: it reads the first case's JavaScript, so it waits for the cases.
    const check_count: usize = differential_paths.len + js_only_paths.len + 1;
    const checks: []Diff = try arena.alloc(Diff, check_count);
    var printer: Printer = .{ .io = io, .checks = checks };
    for (checks, 0..) |*check, k| {
        const is_differential: bool = k < differential_paths.len;
        const is_prelude: bool = k == check_count - 1;
        const kind: Kind = if (is_differential) .differential else if (is_prelude) .prelude else .js_only;
        const case_path: []const u8 = switch (kind) {
            .differential => differential_paths[k],
            .js_only => js_only_paths[k - differential_paths.len],
            .prelude => "",
        };
        check.* = .{
            .io = io,
            .args = args,
            .kind = kind,
            .case_path = case_path,
            .oracle_source = oracle_source,
            .arena_state = ArenaAllocator.init(init.gpa),
            .arena = undefined,
        };
        // Taken here, in the slice that never moves: the interface points at `arena_state`.
        check.arena = check.arena_state.allocator();
    }
    defer for (checks) |*check| {
        check.arena_state.deinit();
    };

    var group: Io.Group = .init;
    const prelude_index: usize = check_count - 1;
    for (0..prelude_index) |case_index| {
        group.async(io, runCheck, .{ &printer, case_index });
    }
    try group.await(io);
    for (checks[0..differential_paths.len]) |*case| {
        if (case.js_path) |js_path| {
            checks[prelude_index].js_path = js_path;
            break;
        }
    }
    runCheck(&printer, prelude_index);

    // Every report is out: the prelude test was the last of them.
    var tally: Tally = .{};
    for (checks) |*check| {
        tally.count(check.verdict);
    }
    const summary: []u8 = if (tally.failed > 0)
        try allocPrint(arena, "\nDIFFERENTIAL: {d} FAILURE(s), {d} agree, {d} known-fail\n", .{
            tally.failed, tally.agreed, tally.known_failed,
        })
    else
        try allocPrint(arena, "\nDIFFERENTIAL: {d} agree with native, {d} JS-only cases check out" ++
            " ({d} known-fail, {d} unexpected-pass)\n", .{
            tally.agreed, tally.js_only_passed, tally.known_failed, tally.unexpectedly_passed,
        });
    try File.stdout().writeStreamingAll(io, summary);
    if (tally.failed > 0) {
        std.process.exit(1);
    }
}
