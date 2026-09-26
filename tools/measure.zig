//! measure - run a command and record wall time, peak RSS, cache delta and free-disk delta.
//!
//! Replaces `scripts/measure.sh`. Same output format, same `/tmp/measure.log` append, so the
//! numbers already quoted across `claude.md` and the plans stay comparable.
//!
//! Usage - built through the build, then run directly, because this Zig's `std.Build` has no
//! `b.args` and a step cannot forward the command to measure:
//!
//!     zig build measure                        once; installs into tools/zig-out/bin
//!     measure <label> <command...>             .zenv.sh puts tools/zig-out/bin on PATH
//!     measure gate zig build gate -Dautofix=false -j1
//!
//! No timeout argument: this std's `Child` has no `tryWait`, so bounding a run would need a
//! watchdog thread when the caller already has a better mechanism. Wrap the invocation.
//!
//! WHY IT EXISTS
//!
//! 1. The cold-build procedure is an idempotent retry loop, and `--summary all` only prints on
//!    COMPLETION - a chain that needs several timeout rounds leaves no per-round record at all.
//!    Cache delta per round is the only reliable progress signal, so it is captured every time.
//! 2. There is no `/usr/bin/time` in this sandbox, so peak RSS is sampled from `/proc`. The sum
//!    across the whole `zig` process tree is what matters - the build runner plus every
//!    `zig build-exe` it spawns - because the constraint is what the box holds at once, not any
//!    one process.
//!
//! Sampling is 250 ms; a step shorter than that can be under-reported, which is fine, because
//! the steps worth measuring run for tens of seconds.

const std = @import("std");
const fs_space = @import("fs_space.zig");
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;

const log_path = "/tmp/measure.log";
const child_log_path = "/tmp/b.log";

/// Megabytes in use under `.zig-cache`, or 0 if it is not there yet.
fn cacheMegabytes(io: std.Io, gpa: Allocator) usize {
    var total: u64 = 0;
    var dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, ".zig-cache", .{ .iterate = true }) catch {
        return 0;
    };
    defer dir.close(io);
    var walker: std.Io.Dir.Walker = dir.walk(gpa) catch {
        return 0;
    };
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        const stat: std.Io.Dir.Stat = dir.statFile(io, entry.path, .{}) catch continue;
        total += stat.size;
    }
    return @intCast(total / (1024 * 1024));
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    var arg_it: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const argv: [][]u8 = args_list.items;
    if (argv.len < 3) {
        try File.stderr().writeStreamingAll(
            io,
            "usage: measure <label> <command...>\n",
        );
        std.process.exit(2);
    }
    const label: []const u8 = argv[1];
    const command: [][]u8 = argv[2..];

    const cache_before: usize = cacheMegabytes(io, gpa);
    const free_before: ?usize = fs_space.freeMegabytes();
    // `Clock.awake` is the monotonic one - unaffected by an NTP step mid-build.
    const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);

    // The child's own output goes to a fixed file, NOT to this process's stdout.
    //
    // * That is a trap worth naming: redirecting the `measure` invocation captures only this
    // summary line, so a `grep 'error:'` on it reports nothing whatever the build did. The log
    // to read is /tmp/b.log, and it is overwritten by the next measured command.
    const log_file: File = try std.Io.Dir.cwd().createFile(io, child_log_path, .{});
    defer log_file.close(io);

    var child: std.process.Child = try std.process.spawn(io, .{
        .argv = command,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        // * The kernel already tracks peak RSS. `measure.sh` polled /proc every 250 ms and
        // summed across the `zig` process tree because it had no other way; asking for
        // `rusage` is both exact and free, and it counts the build runner's children too
        // (wait4 folds terminated descendants into RUSAGE_CHILDREN).
        .request_resource_usage_statistics = true,
    });

    // BLOCKING WAIT, no internal timeout.
    //
    // `measure.sh` polled so it could kill a run that overran. This std's `Child` exposes
    // `wait` and `kill` but no `tryWait`, so a timeout here would mean a watchdog thread - and
    // the caller already has a better one. Wrap the invocation instead; the summary line is
    // still written for whatever the child did, because the log and the deltas are recorded
    // from this side.
    const term: std.process.Child.Term = try child.wait(io);

    const peak_kb: usize = (child.resource_usage_statistics.getMaxRss() orelse 0) / 1024;

    const total_ns: i96 = std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
    const wall_s: u64 = @intCast(@divTrunc(total_ns, std.time.ns_per_s));
    const cache_after: usize = cacheMegabytes(io, gpa);
    const free_after: ?usize = fs_space.freeMegabytes();
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    // `free=` renders as `n/a` where the platform is not implemented, NEVER as 0 - a zero
    // there reads as "disk full", which is the opposite of "did not measure".
    var free_buf: [64]u8 = undefined;
    const free_text: []const u8 = if (free_after) |after| blk: {
        const delta: usize = if (free_before) |before| before -| after else 0;
        break :blk try bufPrint(&free_buf, "{d}MB (-{d}MB)", .{ after, delta });
    } else "n/a";

    var line_buf: [512]u8 = undefined;
    const line: []const u8 = try bufPrint(
        &line_buf,
        "{s: <44} rc={d: <4} wall={d: <4}s peakRSS={d: <5}MB cache={d}MB (+{d}MB) free={s}\n",
        .{
            label,
            code,
            wall_s,
            peak_kb / 1024,
            cache_after,
            cache_after -| cache_before,
            free_text,
        },
    );
    try File.stdout().writeStreamingAll(io, line);

    const existing: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .unlimited) catch "";
    const merged: []u8 = try std.mem.concat(gpa, u8, &.{ existing, line });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = merged });

    std.process.exit(code);
}
