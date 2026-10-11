//! PR 36930's `std.process.Init.args`, vendored beside `cli.zig`. In the PR it is a METHOD of `std.process.Init`;
//! a copy outside std cannot add one, so it is a free function taking the `Init`. The body is the PR's but for three
//! names that live in `std.process` there: `std.cli` -> the sibling `cli.zig`, `fatal` -> `std.process.fatal`,
//! `exit` -> `std.process.exit`. Reach it through `src/command_line.zig`.

const std = @import("std");
const cli = @import("../cli.zig");
const Init = std.process.Init;
const fatal = std.process.fatal;
const exit = std.process.exit;

/// Parses arguments and automatically prints help if it was requested
/// or the arguments were invalid. See `std.cli.parse`.
pub fn args(init: *const Init, comptime CliArgs: type, comptime config: cli.Config(CliArgs)) CliArgs {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch fatal("Out of memory", .{});
    return cli.parse(arena, CliArgs, config, argv) catch |err| {
        const exit_code: u8 = switch (err) {
            error.HelpRequested => 0,
            error.IncorrectUsage => 1,
            error.OutOfMemory => fatal("Out of memory", .{}),
        };

        // no need to reset it other than good practice
        const prev = init.io.swapCancelProtection(.blocked);
        defer _ = init.io.swapCancelProtection(prev);

        var buf: [4096]u8 = undefined;
        var stderr = init.io.lockStderr(&buf, null) catch |err2| switch (err2) {
            error.Canceled => unreachable,
        };
        cli.printUsage(&stderr.file_writer.interface, CliArgs, config, argv[0]) catch {};
        init.io.unlockStderr();

        exit(exit_code);
    };
}
