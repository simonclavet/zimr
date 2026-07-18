//! tests/transpile_one.zig — native-binary harness for debugging
//! single-shader transpile failures.  Loads the .spv at argv[1],
//! runs spv2wgsl.convertSpirvToWgsl on it, prints any panic stack
//! trace.
//!
//! Build: zig build-exe tests/transpile_one.zig --dep spv2wgsl -Mspv2wgsl=src/spv2wgsl.zig
//! Run:   ./transpile_one path/to/shader.spv

const std = @import("std");
const spv2wgsl = @import("spv2wgsl");

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.NeedPath;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const bytes = try std.heap.page_allocator.alloc(u8, st.size);
    defer std.heap.page_allocator.free(bytes);
    _ = try f.readPositionalAll(io, bytes, 0);

    const words = @as([*]const u32, @ptrCast(@alignCast(bytes.ptr)))[0 .. bytes.len / 4];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const wgsl = try spv2wgsl.convertSpirvToWgsl(arena.allocator(), words);
    std.log.info("OK: {d} -> {d} WGSL bytes", .{ bytes.len, wgsl.len });
}
