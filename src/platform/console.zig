//! src/platform/console.zig - the log of the platforms without a browser console: one line per message on standard
//! error, prefixed with its level. It depends on nothing but the standard library, so the Windows and headless
//! platforms and the native loop can all use it - the headless one needing no C library.

const std = @import("std");
const builtin = @import("builtin");

// lint:off module-var: how many error lines the log has written, for a run's verdict (`errorLineCount`)
var error_line_count: u32 = 0;

/// One line of the log on standard error, prefixed with its level. An error line is counted: a native run that
/// logged one is not clean (`errorLineCount`).
pub fn log(level: std.log.Level, text: []const u8) void {
    if (level == .err) {
        // Any thread may log - the network's among them - so the count is kept atomically.
        _ = @atomicRmw(u32, &error_line_count, .Add, 1, .monotonic);
    }
    // Under the test runner the log keeps to `std.log`'s level there (`std.testing.log_level`: warnings and errors), so
    // a passing test that asks a headless platform for something - an address opened, a capture trimmed - is silent.
    if (builtin.is_test and @backingInt(level) > @backingInt(std.testing.log_level)) {
        return;
    }
    const prefix: []const u8 = switch (level) {
        .debug, .info => "[zimr]",
        .warn => "[zimr WARN]",
        .err => "[zimr ERR]",
    };
    // lint:off debug-print: a native platform's log is standard error
    std.debug.print("{s} {s}\n", .{ prefix, text });
}

/// How many error lines the log has written: a leak the debug allocator found, a frame that could not be saved, any
/// `std.log.err` - each a reason a native run is not clean.
pub fn errorLineCount() u32 {
    return @atomicLoad(u32, &error_line_count, .monotonic);
}
