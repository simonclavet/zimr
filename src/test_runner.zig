//! test_runner - Zig's own test runner, plus two things a long suite needs: ONE SHARD of the tests per
//! process, and HOW LONG EACH TEST TOOK.
//!
//! The robot family is one test binary of ~760 tests (`src/robot_tests.zig`), and Zig's runner runs a
//! binary's tests one after another - so `zig build test` waited minutes on one core while the others
//! sat idle. build.zig runs the robot family's binaries as `-Dtest-shards` processes instead, each given
//! `--shard=K/N`: a shard tells the build runner its tests ARE the binary's tests - those whose index is
//! K modulo N - and runs only those. Interleaved rather than in blocks, so one file's slow tests spread
//! over the shards instead of landing in one.
//!
//!     zig build test -Dslow-tests -Dtest-timing     each process also lists its tests of a second or more
//!
//! * Everything else is std's runner as of the pinned 0.17 (`lib/compiler/test_runner.zig`): the same
//! server protocol, a fresh `testing.allocator` and `testing.io` for every test, the same leak and
//! logged-error accounting. Fuzzing and the simple-backend path are left out - no zimr test fuzzes, and
//! the host tests build with LLVM. Diff it against std's on a compiler bump.

const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SafeAllocator = std.heap.SafeAllocator;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const indexOfScalar = std.mem.indexOfScalar;
const sortSlice = std.mem.sort;
const parseInt = std.fmt.parseInt;
const panic = std.debug.panic;
const testing = std.testing;
const Server = std.zig.Server;
const TestResults = Server.Message.TestResults;
const TestFn = std.builtin.TestFn;

const runner_io: Io = Io.Threaded.global_single_threaded.io();

/// `--timing` lists the tests that took at least this long, and a process with none prints nothing: the build
/// runner shows a passing binary's stderr under a `failed command:` line, so a list of 0.00 s tests is noise.
const timing_floor_ns: u64 = std.time.ns_per_s;
/// And at most this many of them, slowest first.
const timing_rows: usize = 20;

// lint:off module-var: `log` is reached through `std_options`, which carries no context.
var log_err_count: usize = 0;
// Nanoseconds each test took, by its index in `builtin.test_functions`. A slice allocated by `main`, not an
// array: the compiler fills `builtin.test_functions` in after analysis, so its length is not comptime-known.
// lint:off module-var: filled by `runOne`, read by the sort's comparator, which carries no state of its own.
var test_ns: []u64 = &.{};

/// The tests one process runs: those whose index is `index` modulo `count`.
const Shard = struct {
    index: u32 = 0,
    count: u32 = 1,

    /// How many of the binary's tests this shard runs.
    fn len(shard: Shard) u32 {
        const total: u32 = @intCast(builtin.test_functions.len);
        if (shard.index >= total) {
            return 0;
        }
        return (total - shard.index + shard.count - 1) / shard.count;
    }

    /// The index in `builtin.test_functions` of this shard's `local`-th test.
    fn global(shard: Shard, local: u32) u32 {
        return shard.index + local * shard.count;
    }

    /// `K/N`, from `--shard=K/N`.
    fn parse(text: []const u8) Shard {
        const slash: usize = indexOfScalar(u8, text, '/') orelse {
            panic("--shard wants K/N, got {s}", .{text});
        };
        const index: u32 = parseInt(u32, text[0..slash], 10) catch {
            panic("--shard wants K/N, got {s}", .{text});
        };
        const count: u32 = parseInt(u32, text[slash + 1 ..], 10) catch {
            panic("--shard wants K/N, got {s}", .{text});
        };
        if (count == 0 or index >= count) {
            panic("--shard wants K/N with K < N, got {s}", .{text});
        }
        return .{ .index = index, .count = count };
    }
};

const Options = struct {
    listen: bool = false,
    timing: bool = false,
    shard: Shard = .{},
};

/// What running one test came to.
const Outcome = struct {
    status: TestResults.Status,
    /// The error a failing test returned.
    err: ?anyerror = null,
    leaks: usize,
    log_errors: usize,
};

fn print(comptime format: []const u8, args: anytype) void {
    // lint:off debug-print: a native test runner, writing to the stderr the build runner shows.
    std.debug.print(format, args);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

pub const std_options: std.Options = .{
    .logFn = log,
};

/// Runs `builtin.test_functions[index]` with a fresh testing allocator and `Io`, as std's runner does, and
/// times it.
fn runOne(init: std.process.Init.Minimal, index: u32) Outcome {
    testing.environ = init.environ;
    testing.log_level = .warn;
    testing.allocator_instance = SafeAllocator.init(std.heap.page_allocator, .{
        .canary = 0xc3a701ba,
        .check_write_after_free = true,
    });
    testing.io_instance = Io.Threaded.init(testing.allocator, .{
        .argv0 = Io.Threaded.Argv0.init(init.args),
        .environ = init.environ,
    });
    log_err_count = 0;

    // lint:off own-clock: the test runner times the tests themselves; there is no platform here.
    const started: Io.Timestamp = .now(runner_io, .awake);
    var outcome: Outcome = .{ .status = .pass, .leaks = 0, .log_errors = 0 };
    if (builtin.test_functions[index].func()) |_| {
        outcome.status = .pass;
    } else |err| {
        if (err == error.SkipZigTest) {
            outcome.status = .skip;
        } else {
            outcome.status = .fail;
            outcome.err = err;
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
    }
    test_ns[index] = @intCast(started.untilNow(runner_io, .awake).nanoseconds);

    testing.io_instance.deinit();
    outcome.leaks = testing.allocator_instance.deinit();
    outcome.log_errors = log_err_count;
    return outcome;
}

/// `value`, or the most an unsigned `T` holds when it is more (std's `lossyCast`, which `std.math` keeps
/// out of reach here).
fn saturate(comptime T: type, value: usize) T {
    const most: T = ~@as(T, 0);
    return @intCast(@min(value, most));
}

fn slowerFirst(_: void, a: u32, b: u32) bool {
    return test_ns[a] > test_ns[b];
}

fn seconds(ns: u64) f64 {
    const ns_float: f64 = @floatFromInt(ns);
    return ns_float / std.time.ns_per_s;
}

/// The shard's total and its tests over `timing_floor_ns`, slowest first - or nothing, when no test reached it.
fn printTiming(shard: Shard) void {
    const gpa: Allocator = std.heap.page_allocator;
    const count: u32 = shard.len();
    const order: []u32 = gpa.alloc(u32, count) catch |err| {
        panic("unable to allocate the timing table: {t}", .{err});
    };
    defer gpa.free(order);
    var total_ns: u64 = 0;
    for (order, 0..) |*slot, local| {
        slot.* = shard.global(@intCast(local));
        total_ns += test_ns[slot.*];
    }
    sortSlice(u32, order, {}, slowerFirst);
    var slow_count: usize = 0;
    while (slow_count < count and test_ns[order[slow_count]] >= timing_floor_ns) {
        slow_count += 1;
    }
    if (slow_count == 0) {
        return;
    }
    print("\nshard {d}/{d}: {d} tests in {d:.1} s; {d} took a second or more:\n", .{
        shard.index, shard.count, count, seconds(total_ns), slow_count,
    });
    for (order[0..@min(slow_count, timing_rows)]) |index| {
        print("  {d:>8.2} s  {s}\n", .{ seconds(test_ns[index]), builtin.test_functions[index].name });
    }
}

fn serveMetadata(server: *Server, shard: Shard) !void {
    const gpa: Allocator = std.heap.page_allocator;
    var string_bytes: ArrayList(u8) = .empty;
    defer string_bytes.deinit(gpa);
    // Reserve 0 for null.
    try string_bytes.append(gpa, 0);

    const count: u32 = shard.len();
    const names: []u32 = try gpa.alloc(u32, count);
    defer gpa.free(names);
    const expected_panic_msgs: []u32 = try gpa.alloc(u32, count);
    defer gpa.free(expected_panic_msgs);
    for (names, expected_panic_msgs, 0..) |*name, *expected_panic_msg, local| {
        const test_fn: TestFn = builtin.test_functions[shard.global(@intCast(local))];
        name.* = @intCast(string_bytes.items.len);
        try string_bytes.ensureUnusedCapacity(gpa, test_fn.name.len + 1);
        string_bytes.appendSliceAssumeCapacity(test_fn.name);
        string_bytes.appendAssumeCapacity(0);
        expected_panic_msg.* = 0;
    }
    try server.serveTestMetadata(.{
        .names = names,
        .expected_panic_msgs = expected_panic_msgs,
        .string_bytes = string_bytes.items,
    });
}

/// The build runner's side of the conversation: it asks for the test list, then for each test by its
/// index in that list - which, for a shard, is not its index in the binary.
fn mainServer(init: std.process.Init.Minimal, options: Options) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server: Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    while (true) {
        const header: std.zig.Client.Message.Header = try server.receiveMessage();
        switch (header.tag) {
            .exit => {
                if (options.timing) {
                    printTiming(options.shard);
                }
                return;
            },
            .query_test_metadata => {
                try serveMetadata(&server, options.shard);
            },
            .run_test => {
                const local: u32 = try server.receiveBody_u32();
                // Let the build runner know the test is starting: its clock and its timeout start here.
                try server.serveStringMessage(.test_started, &.{});
                const outcome: Outcome = runOne(init, options.shard.global(local));
                try server.serveTestResults(.{
                    .index = local,
                    .flags = .{
                        .status = outcome.status,
                        .fuzz = false,
                        .log_err_count = saturate(@FieldType(TestResults.Flags, "log_err_count"), outcome.log_errors),
                        .leak_count = saturate(@FieldType(TestResults.Flags, "leak_count"), outcome.leaks),
                    },
                });
            },
            else => {
                panic("unsupported message: {x}", .{@backingInt(header.tag)});
            },
        }
    }
}

/// The binary run by hand: one line per test, then a summary.
fn mainTerminal(init: std.process.Init.Minimal, options: Options) void {
    const count: u32 = options.shard.len();
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var log_errors: usize = 0;
    for (0..count) |local| {
        const index: u32 = options.shard.global(@intCast(local));
        print("{d}/{d} {s}...", .{ local + 1, count, builtin.test_functions[index].name });
        const outcome: Outcome = runOne(init, index);
        log_errors += outcome.log_errors;
        if (outcome.leaks != 0) {
            leaked += 1;
        }
        switch (outcome.status) {
            .pass => {
                passed += 1;
                print("OK\n", .{});
            },
            .skip => {
                skipped += 1;
                print("SKIP\n", .{});
            },
            .fail => {
                failed += 1;
                print("FAIL ({t})\n", .{outcome.err.?});
            },
        }
    }
    if (passed == count) {
        print("All {d} tests passed.\n", .{passed});
    } else {
        print("{d} passed; {d} skipped; {d} failed.\n", .{ passed, skipped, failed });
    }
    if (log_errors != 0) {
        print("{d} errors were logged.\n", .{log_errors});
    }
    if (leaked != 0) {
        print("{d} tests leaked memory.\n", .{leaked});
    }
    if (options.timing) {
        printTiming(options.shard);
    }
    if (leaked != 0 or log_errors != 0 or failed != 0) {
        // lint:off process-exit: the entry point's own status.
        std.process.exit(1);
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var fba_buffer: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
    const args: []const [:0]const u8 = init.args.toSlice(fba.allocator()) catch |err| {
        panic("unable to parse command line args: {t}", .{err});
    };

    var options: Options = .{};
    for (args[1..]) |arg| {
        if (eql(u8, arg, "--listen=-")) {
            options.listen = true;
        } else if (startsWith(u8, arg, "--seed=")) {
            testing.random_seed = parseInt(u32, arg["--seed=".len..], 0) catch {
                panic("unable to parse --seed command line argument: {s}", .{arg});
            };
        } else if (startsWith(u8, arg, "--cache-dir=")) {
            // Only std's fuzzer reads it.
        } else if (startsWith(u8, arg, "--shard=")) {
            options.shard = Shard.parse(arg["--shard=".len..]);
        } else if (eql(u8, arg, "--timing")) {
            options.timing = true;
        } else {
            panic("unrecognized command line argument: {s}", .{arg});
        }
    }

    test_ns = std.heap.page_allocator.alloc(u64, builtin.test_functions.len) catch |err| {
        panic("unable to allocate the test times: {t}", .{err});
    };
    @memset(test_ns, 0);

    if (options.listen) {
        mainServer(init, options) catch |err| {
            panic("internal test runner failure: {t}", .{err});
        };
    } else {
        mainTerminal(init, options);
    }
}
