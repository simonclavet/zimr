//! lint:alias report
//! test_report - the tables the robot tests print, silent unless `-Dtest-report` asks for them.
//!
//! Many robot tests are measurements as much as checks: they print a table (drift per gain, time
//! to failure per setting) that is read when the physics is being tuned. On any other run the
//! table is noise, and worse than noise: Zig's build runner prints a test binary's whole stderr
//! even when every test passed, under a `failed command:` line, so a green `zig build test` read
//! as a red one. The tables now print only on request:
//!
//!     zig build zn-robot_control -Dtest-report -Dtest-filter="rung 2"
//!
//! * Host tests only. The wasm builds' `build_options` has no `test_report`, and nothing outside
//! a `test` calls `print`, so a module without `build_options` never analyses the import.

const std = @import("std");
const build_options = @import("build_options");

/// True under `-Dtest-report`. A test can read it to skip work whose only product is its table.
pub const enabled: bool = if (@hasDecl(build_options, "test_report")) build_options.test_report else false;

/// `std.debug.print`, when `enabled`; nothing otherwise.
pub fn print(comptime format: []const u8, args: anytype) void {
    if (enabled) {
        // lint:off debug-print: host-only test output, printed only when asked for.
        std.debug.print(format, args);
    }
}
