//! robot_clip_bake - the tracking clips, prepared once, offline, for pages to embed.
//!
//! A page that trains on a motion capture needs the capture on the robot: retargeted by inverse
//! kinematics, filtered, cut to the stretch that matters, and lifted frame by frame clear of the
//! floor. Done in the page, that means embedding megabytes of capture text and spending seconds of
//! a phone's startup on IK. Done here, once, it is a few hundred kilobytes of floats the page loads
//! instantly - and exactly the same numbers, because this runs the very functions the page used to.
//!
//! Every file is read back and compared with the clip it came from before this says it wrote it,
//! the same self-check the capture tools do. `zig build clip-bake`.

const std = @import("std");
const zm = @import("zm");
const rbt = @import("robot.zig");
const dance = @import("robot_dance.zig");
const track = @import("robot_track.zig");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");

const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

/// One clip to bake: where it comes from, how much of it the retarget sees, which frames are kept,
/// and where the result goes.
const Job = struct {
    name: []const u8,
    capture: []const u8,
    seconds: f32,
    /// The window kept, in frames of the retargeted clip; `count` 0 keeps the rest of the clip.
    first: usize,
    count: usize,
    out: []const u8,
};

const jobs = [_]Job{
    // The get-up proper: 9 s to 14 s of the take, lying down to standing (hips 6 cm -> 81 cm).
    .{
        .name = "get-up",
        .capture = "assets/lafan1/fallAndGetUp2_subject2.bvh",
        .seconds = 14.5,
        .first = 540,
        .count = 300,
        .out = "examples/getup_train/getup.zclip",
    },
    // The walk the SuperTrack and world-model tests train on - baked so each test loads it in an instant
    // instead of spending half a minute on inverse kinematics first. The same pipeline the tests used,
    // so the same clip, number for number.
    .{
        .name = "walk",
        .capture = "assets/lafan1/walk1_subject2.bvh",
        .seconds = 12.0,
        .first = 0,
        .count = 0,
        .out = "assets/lafan1/walk1_subject2.zclip",
    },
    // The dance, all twenty seconds of the cut we have.
    .{
        .name = "dance",
        .capture = "assets/lafan1/dance2_subject2.bvh",
        .seconds = 20.0,
        .first = 0,
        .count = 0,
        .out = "examples/getup_train/dance.zclip",
    },
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa: Allocator = debug_allocator.allocator();
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    // The robot, exactly as the tracking stack and the pages build it.
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, flex2_xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = zm.vec(0, 0, -9.81), .max_contacts = 256 };
    options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var scratch: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch.deinit();

    const rest_bytes: []u8 = try readAll(gpa, io, "assets/lafan1/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();

    for (jobs) |job| {
        const capture_bytes: []u8 = try readAll(gpa, io, job.capture);
        defer gpa.free(capture_bytes);
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, capture_bytes, null);
        defer capture.deinit();
        const retarget: dance.RetargetOptions = .{ .seconds = job.seconds };
        var raw: dance.Clip = try dance.retargetClip(gpa, m, imported.names, &capture, &rest, retarget);
        defer raw.deinit();
        var smooth: dance.Clip = try raw.smoothed(m, 5.0);
        defer smooth.deinit();
        const count: usize = if (job.count == 0) smooth.frame_count - job.first else job.count;
        var clip: dance.Clip = try smooth.window(job.first, count);
        defer clip.deinit();
        const lift: f32 = try track.liftPerFrame(gpa, m, &clip, &scratch, 3.0);

        const bytes: []u8 = try clip.toBytes(gpa);
        defer gpa.free(bytes);
        {
            const file: std.Io.File = try std.Io.Dir.cwd().createFile(io, job.out, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, bytes);
        }

        // Read it back from disk and hold it against the clip it came from, number for number.
        const written: []u8 = try readAll(gpa, io, job.out);
        defer gpa.free(written);
        var back: dance.Clip = try dance.Clip.fromBytes(gpa, written);
        defer back.deinit();
        const same_shape: bool = back.frame_count == clip.frame_count and back.nq == clip.nq and
            back.frame_time == clip.frame_time;
        const same_numbers: bool = std.mem.eql(f32, back.targets, clip.targets) and
            std.mem.eql(f32, back.residual, clip.residual) and
            std.mem.eql(u32, back.residual_body, clip.residual_body);
        if (!same_shape or !same_numbers) {
            try say(gpa, io, "clip-bake: {s} did not read back as written\n", .{job.out});
            return error.BakeMismatch;
        }
        try say(gpa, io, "clip-bake: {s} -> {s}: {d} frames, {d} bytes (from {d} of capture text), " ++
            "lifted up to {d:.3} m, verified\n", .{
            job.name,
            job.out,
            clip.frame_count,
            bytes.len,
            capture_bytes.len,
            lift,
        });
    }
}

/// A line to stdout, through the Io layer like the capture tools - not `std.debug.print`, which
/// the engine's lint keeps out of `src/` because it bypasses the logging everything else goes
/// through.
fn say(gpa: Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const text: []u8 = try allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn readAll(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}
