//! lint:alias report
//! test_report - the tables the robot tests print, silent unless `-Dtest-report` asks for them.
//!
//! Many robot tests are measurements as much as checks: they print a table (drift per gain, time
//! to failure per setting) that is read when the physics is being tuned. On any other run the
//! table is noise, and worse than noise: Zig's build runner prints a test binary's whole stderr
//! even when every test passed, under a `failed command:` line, so a green `zig build test` read
//! as a red one. The tables now print only on request:
//!
//!     zig build test-robot_control -Dtest-report -Dtest-filter="rung 2"
//!
//! * Host tests only. The wasm builds' `build_options` has no `test_report`, and nothing outside
//! a `test` calls `print`, so a module without `build_options` never analyses the import.

const std = @import("std");
const build_options = @import("build_options");

/// True under `-Dtest-report`. To gate a whole test on it, call `requested` instead.
pub const enabled: bool = if (@hasDecl(build_options, "test_report")) build_options.test_report else false;

/// `enabled`, as a value the compiler does not fold. A MEASUREMENT test - one whose only product is
/// its table, asserting nothing - gates on this and skips unless the table is asked for:
///
///     if (!report.requested()) {
///         return error.SkipZigTest;
///     }
///
/// * Not on `enabled` itself: a comptime-false gate makes the `return` unconditional, the compiler
/// stops analysing the test there, and the rest of its body would go uncompiled - and quietly rot -
/// between the runs that print it. A call is runtime-known, so the whole body is still checked.
pub fn requested() bool {
    return enabled;
}

/// True under `-Dparked-tests`. To gate a whole test on it, call `parked` instead.
pub const parked_enabled: bool = if (@hasDecl(build_options, "parked_tests")) build_options.parked_tests else false;

/// Whether a PARKED test skips. A parked test checks something real but costs more than it is worth while the suite
/// is being trimmed (Oct 12); it keeps compiling, and `-Dslow-tests -Dparked-tests` runs it. The list to revisit is
/// `grep -n "report.parked()" src`.
///
///     if (report.parked()) {
///         return error.SkipZigTest;
///     }
///
/// * A call for the same reason as `requested`: the parked body is still analysed on every run.
pub fn parked() bool {
    return !parked_enabled;
}

/// A FAILING CHECK's EXPLANATION, printed always - unlike `print`, which is for measurements asked for: a check that
/// fails says what failed whether or not reports were asked for.
pub fn failure(comptime format: []const u8, args: anytype) void {
    // lint:off debug-print: a failing check's explanation, printed when and only when it fails.
    std.debug.print(format, args);
}

/// `std.debug.print`, when `enabled`; nothing otherwise.
pub fn print(comptime format: []const u8, args: anytype) void {
    if (enabled) {
        // lint:off debug-print: host-only test output, printed only when asked for.
        std.debug.print(format, args);
    }
}

/// SEVERAL CHECKS OF ONE TEST, EVERY ONE LOOKED AT. `try expect` leaves a test at its first failing check, and the
/// run says nothing of the checks after it. A check given to `holds` is explained when it does not hold (`failure`)
/// and counted; the test goes on, and fails where it calls `finish`. One run then names every check that fails.
///
///     var checks: report.Checks = .{};
///     checks.holds(pushes > 0, "no push was given\n", .{});
///     checks.holds(watched <= pushes, "{d} watched of {d} pushes\n", .{ watched, pushes });
///     try checks.finish();
pub const Checks = struct {
    failed: u32 = 0,

    /// Counts and explains the check when `condition` is false. `format` and `args` are `failure`'s.
    pub fn holds(
        checks: *Checks,
        condition: bool,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (condition) {
            return;
        }
        checks.failed += 1;
        failure(format, args);
    }

    /// Fails the test when any check did not hold.
    pub fn finish(checks: Checks) !void {
        if (checks.failed > 0) {
            return error.ChecksDoNotHold;
        }
    }
};
