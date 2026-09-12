//! tools/bvh_trim.zig — cut a frame range out of a BVH file.
//!
//! Mocap captures are large: `dance1_subject2.bvh` is 43 MB of motion matrix, which cannot be
//! `@embedFile`d into an example that ships in a 13 MB launcher. This produces the trimmed clip
//! the `mocap_viewer` example embeds, so that asset has a recorded provenance and can be
//! regenerated rather than being a mystery blob someone once made by hand.
//!
//! It runs on zimr's OWN codec — `codecs.bvh.parse` then `codecs.bvh.encode`. That is
//! deliberate: it makes the shipped asset a product of the round trip the tests assert, so a
//! parser or writer regression shows up as a broken example rather than as a silent difference
//! between the fixture and the library that reads it.
//!
//!     bvh_trim <input.bvh> <output.bvh> <first_frame> <frame_count>
//!
//! Frames are indices, not seconds — the file's own `Frame Time:` decides what those mean, and
//! 60 fps and 120 fps captures both occur. Divide seconds by `Frame Time` yourself; the tool
//! prints the resulting duration so the arithmetic is checkable.

const std = @import("std");
const codecs = @import("codecs");
const Allocator = std.mem.Allocator;
const bvh = codecs.bvh;

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const io: std.Io = init.io;

    var args_list: std.ArrayList([]u8) = .empty;
    var arg_it: std.process.Args.Iterator =
        try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    while (arg_it.next()) |arg| {
        try args_list.append(arena, try arena.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;
    if (args.len != 5) {
        std.log.err("usage: bvh_trim <in.bvh> <out.bvh> <first_frame> <frame_count>", .{});
        return error.BadArgs;
    }
    const in_path: []const u8 = args[1];
    const out_path: []const u8 = args[2];
    const first: usize = try std.fmt.parseInt(usize, args[3], 10);
    const count: usize = try std.fmt.parseInt(usize, args[4], 10);

    var in_file: std.Io.File = try std.Io.Dir.cwd().openFile(io, in_path, .{});
    defer in_file.close(io);
    const stat: std.Io.File.Stat = try in_file.stat(io);
    const source: []u8 = try arena.alloc(u8, stat.size);
    _ = try in_file.readPositionalAll(io, source, 0);

    var diag: bvh.Diagnostic = .{};
    var data: bvh.Data = bvh.parse(arena, source, &diag) catch |err| {
        std.log.err("{s}: {s} at line {d} near \"{s}\"", .{
            in_path, @errorName(err), diag.line, diag.context,
        });
        return err;
    };
    defer data.deinit();

    if (first >= data.frame_count) {
        std.log.err("first frame {d} is past the end ({d} frames)", .{ first, data.frame_count });
        return error.FirstFramePastEnd;
    }
    const take: usize = @min(count, data.frame_count - first);

    // The trimmed clip shares the hierarchy verbatim and takes a contiguous slice of rows —
    // `motion` is row-major, so the range is one slice rather than a per-row copy.
    const trimmed: bvh.Data = .{
        .arena = data.arena,
        .joints = data.joints,
        .frame_count = take,
        .channel_count = data.channel_count,
        .frame_time = data.frame_time,
        .motion = data.motion[first * data.channel_count ..][0 .. take * data.channel_count],
    };

    const text: []u8 = try bvh.encode(arena, trimmed);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text });

    std.log.info(
        "{s}: frames {d}..{d} of {d} -> {s} ({d} joints, {d:.2}s at {d:.0} fps, {d:.2} MB)",
        .{
            in_path,
            first,
            first + take,
            data.frame_count,
            out_path,
            data.joints.len,
            @as(f32, @floatFromInt(take)) * data.frame_time,
            1.0 / data.frame_time,
            @as(f32, @floatFromInt(text.len)) / (1024.0 * 1024.0),
        },
    );
}
