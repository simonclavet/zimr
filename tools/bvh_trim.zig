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
    if (args.len < 5) {
        std.log.err("usage: bvh_trim <in.bvh> <out.bvh> <first_frame> <frame_count> [drop ...]", .{});
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

    // Optional: drop joints nobody downstream reads. Any joint whose name contains one of the
    // extra arguments goes, and its whole subtree with it - the Geno skeleton's forty finger
    // joints are two thirds of a capture's size, and no robot here has fingers. Their channels
    // leave the motion rows too, so what's left is a smaller but perfectly ordinary BVH.
    const drop: [][]u8 = args[5..];
    const keep: []bool = try arena.alloc(bool, data.joints.len);
    @memset(keep, true);
    for (data.joints, 0..) |joint, j| {
        const parent_dropped: bool = joint.parent >= 0 and !keep[@intCast(joint.parent)];
        const named: bool = for (drop) |fragment| {
            if (std.mem.indexOf(u8, joint.name, fragment) != null) {
                break true;
            }
        } else false;
        keep[j] = !parent_dropped and !named;
    }

    // The trimmed clip shares the hierarchy verbatim and takes a contiguous slice of rows —
    // `motion` is row-major, so the range is one slice rather than a per-row copy.
    // Which kept joints still have a kept child? One that doesn't would be a childless JOINT -
    // not a well-formed BVH, and a body whose direction the retarget can no longer see (a hand
    // pointing where its fingers began). Those get an End Site at their first dropped child's
    // offset instead: the file stays ordinary, and the direction survives.
    const has_kept_child: []bool = try arena.alloc(bool, data.joints.len);
    const stub_offset: [][3]f32 = try arena.alloc([3]f32, data.joints.len);
    @memset(has_kept_child, false);
    for (data.joints, 0..) |joint, j| {
        if (joint.parent < 0) {
            continue;
        }
        const parent: usize = @intCast(joint.parent);
        if (keep[j]) {
            has_kept_child[parent] = true;
        } else if (!has_kept_child[parent]) {
            stub_offset[parent] = joint.offset;
        }
    }

    // The kept joints, renumbered, and the kept channels gathered out of every row.
    var kept_joints: std.ArrayList(bvh.Joint) = .empty;
    var new_index: []i32 = try arena.alloc(i32, data.joints.len);
    var kept_channels: std.ArrayList(usize) = .empty;
    var at: usize = 0;
    for (data.joints, 0..) |joint, j| {
        const channels: usize = joint.channels.len;
        if (keep[j]) {
            new_index[j] = @intCast(kept_joints.items.len);
            var copy: bvh.Joint = joint;
            copy.parent = if (joint.parent < 0) -1 else new_index[@intCast(joint.parent)];
            try kept_joints.append(arena, copy);
            for (0..channels) |c| {
                try kept_channels.append(arena, at + c);
            }
            if (!has_kept_child[j] and !joint.end_site) {
                try kept_joints.append(arena, .{
                    .name = try std.fmt.allocPrint(arena, "{s}End", .{joint.name}),
                    .parent = new_index[j],
                    .offset = stub_offset[j],
                    .channels = &.{},
                    .end_site = true,
                });
            }
        } else {
            new_index[j] = -1;
        }
        at += channels;
    }
    const kept_count: usize = kept_channels.items.len;
    const motion: []f32 = try arena.alloc(f32, take * kept_count);
    for (0..take) |f| {
        const row: []const f32 = data.motion[(first + f) * data.channel_count ..][0..data.channel_count];
        for (kept_channels.items, 0..) |from, c| {
            motion[f * kept_count + c] = row[from];
        }
    }
    const trimmed: bvh.Data = .{
        .arena = data.arena,
        .joints = kept_joints.items,
        .frame_count = take,
        .channel_count = kept_count,
        .frame_time = data.frame_time,
        .motion = motion,
    };

    const text: []u8 = try bvh.encode(arena, trimmed);
    // Read back what we're about to ship: same joints, same frames, same numbers. A trimmer that
    // writes a file it can't parse is worse than one that refuses to write at all.
    var check: bvh.Data = try bvh.parse(arena, text, null);
    defer check.deinit();
    if (check.joints.len != trimmed.joints.len or check.frame_count != trimmed.frame_count or
        check.channel_count != trimmed.channel_count)
    {
        std.log.err("round trip changed the clip's shape - not written", .{});
        return error.RoundTripFailed;
    }
    for (check.motion, trimmed.motion) |got, want| {
        if (@abs(got - want) > 1.0e-3) {
            std.log.err("round trip changed a channel by {d} - not written", .{@abs(got - want)});
            return error.RoundTripFailed;
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text });

    std.log.info(
        "{s}: frames {d}..{d} of {d} -> {s} ({d} joints, {d:.2}s at {d:.0} fps, {d:.2} MB)",
        .{
            in_path,
            first,
            first + take,
            data.frame_count,
            out_path,
            trimmed.joints.len,
            @as(f32, @floatFromInt(take)) * data.frame_time,
            1.0 / data.frame_time,
            @as(f32, @floatFromInt(text.len)) / (1024.0 * 1024.0),
        },
    );
}
