//! lafan_db - LAFAN1 locomotion, out of Daniel Holden's motion-matching database and into BVH.
//!
//! Here's the situation. DReCon needs a pile of locomotion - walking, running, turning, stopping -
//! for its motion-matching controller to search. The obvious source is Ubisoft's LAFAN1 dataset,
//! but its BVH files live in a Git LFS archive, and LFS downloads come from a host we can't always
//! reach. Daniel Holden's Motion-Matching demo (github.com/orangeduck/Motion-Matching) ships the
//! same motion already processed, as `resources/database.bin`, in a plain repository archive. So
//! we read that, and turn it back into ordinary BVH clips our own pipeline understands.
//!
//! What's in the database (from its `generate_database.py`):
//!
//!   * three LAFAN1 takes by subject 5 - `pushAndStumble1` (frames 194-351), `run1` (90-7086)
//!     and `walk1` (80-7791) - each stored twice, as recorded and mirrored left-to-right;
//!   * resampled from LAFAN's 30 fps to 60 fps with cubic interpolation, and played 10% faster
//!     on purpose ("speed up data by 10%"), so each clip is a little brisker than the performer;
//!   * positions in metres, Y up; rotations LOCAL (relative to the parent), as unit quaternions
//!     stored w first;
//!   * one extra bone in front of LAFAN's 22: "Simulation", the character's footprint on the
//!     ground (position and heading, smoothed), with Hips stored relative to it.
//!
//! What we write, one file per take (the mirrored copies are skipped - we can mirror in robot
//! space later if we want them):
//!
//!   * LAFAN's own 22-bone skeleton, Hips as the root. The Simulation bone is folded back in:
//!     Hips' world transform is Simulation * Hips-local, so nothing about the motion changes.
//!   * The root gets six channels (position, then rotation), every other joint three, rotations
//!     in Z-Y-X order - the same layout as the dance capture. Positions in centimetres again.
//!   * An End Site on each leaf (toes, head, hands) a few centimetres along its bone, as BVH
//!     files conventionally have.
//!
//! And the part that makes this trustworthy: after encoding a clip, the tool parses its own text
//! back with `codecs.bvh.parse`, runs forward kinematics both ways - from the database's
//! quaternions, and from the parsed Euler channels - and refuses to write the file unless every
//! joint of every frame agrees to within a hundredth of a millimetre... well, 0.01 cm. So the
//! Euler conversion, the rounding and the codec's round trip are all checked on every frame of
//! the real data, every time this runs.
//!
//!     zig build lafan-db -- <database.bin> <out_dir> <seconds>
//!
//! The data is LAFAN1's, licensed CC BY-NC-ND 4.0 by Ubisoft La Forge; Holden's code is MIT.

const std = @import("std");
const builtin = @import("builtin");
const codecs = @import("codecs");
const zm = @import("zm");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const splat = zm.splat;
const qmul = zm.qmul;
const conjugate = zm.conjugate;
const normalize4 = zm.normalize4;
const rotate = zm.rotate;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const length3 = zm.length3;
const atan2Rad = zm.atan2Rad;
const pi = zm.pi;
const allocPrint = std.fmt.allocPrint;
const readInt = std.mem.readInt;
const sliceAsBytes = std.mem.sliceAsBytes;
const ArgIterator = std.process.Args.Iterator;
const File = std.Io.File;
const Dir = std.Io.Dir;
const Io = std.Io;
const Channel = codecs.bvh.Channel;
const Joint = codecs.bvh.Joint;

// The raw floats are copied straight out of the file, which is little-endian.
comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// LAFAN1's 22 bones, in the database's order (after its extra Simulation root).
const bone_names = [_][]const u8{
    "Hips",          "LeftUpLeg", "LeftLeg",      "LeftFoot",  "LeftToe",     "RightUpLeg",
    "RightLeg",      "RightFoot", "RightToe",     "Spine",     "Spine1",      "Spine2",
    "Neck",          "Head",      "LeftShoulder", "LeftArm",   "LeftForeArm", "LeftHand",
    "RightShoulder", "RightArm",  "RightForeArm", "RightHand",
};

/// Their parents, as indices into `bone_names` (-1 for Hips). The database stores its own parent
/// array; `load` insists it's this one with the Simulation bone in front, so a different database
/// can't be misread as LAFAN.
const bone_parents = [_]i32{ -1, 0, 1, 2, 3, 0, 5, 6, 7, 0, 9, 10, 11, 12, 11, 14, 15, 16, 11, 18, 19, 20 };

/// The takes, in the order the database stores them (each followed by its mirrored copy).
const take_names = [_][]const u8{ "pushAndStumble1_subject5", "run1_subject5", "walk1_subject5" };

/// Leaves and how far their End Site sits along the bone (LAFAN's bones point along +X), in cm.
const EndSite = struct { bone: []const u8, length: f32 };
const end_sites = [_]EndSite{
    .{ .bone = "LeftToe", .length = 5.0 },
    .{ .bone = "RightToe", .length = 5.0 },
    .{ .bone = "Head", .length = 10.0 },
    .{ .bone = "LeftHand", .length = 8.0 },
    .{ .bone = "RightHand", .length = 8.0 },
};

const frames_per_second: f32 = 60.0;

/// The database, read into memory. Rows are frames, columns are bones (Simulation first).
const Database = struct {
    frames: usize,
    bones: usize,
    /// Local positions, metres: for the Simulation bone its ground position, for Hips its
    /// position relative to Simulation, for every other bone its (constant) offset.
    positions: []const [3]f32,
    /// Local rotations as (w, x, y, z).
    rotations: []const [4]f32,
    parents: []const i32,
    starts: []const i32,
    stops: []const i32,

    fn position(db: Database, frame: usize, bone: usize) Vec {
        const p: [3]f32 = db.positions[frame * db.bones + bone];
        return vec(p[0], p[1], p[2]);
    }

    /// The stored (w, x, y, z) as zimrmath's (x, y, z, w) - normalised on the way in.
    ///
    /// The database means to hold unit quaternions, and almost everywhere it does, to about 1e-5.
    /// But not quite everywhere: in `run1` one frame's Simulation and Hips rotations are off by
    /// 1e-4. That sounds harmless until you remember that rotating by a quaternion that isn't unit
    /// also SCALES, by |q|^2 - through a metre of leg, that's a millimetre at the toes. Unit length
    /// is the contract every rotation here relies on, so it's restored before anything uses one.
    fn rotation(db: Database, frame: usize, bone: usize) Quat {
        const r: [4]f32 = db.rotations[frame * db.bones + bone];
        return normalize4(.{ r[1], r[2], r[3], r[0] });
    }
};

/// One of the database's tables: `rows` frames of `cols` bones, `width` floats each.
fn Table(comptime width: usize) type {
    return struct {
        data: []const [width]f32,
        rows: usize,
        cols: usize,
    };
}

/// A cursor over the file. Every array starts with its counts as little u32s, then the raw data.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn count(r: *Reader) !u32 {
        if (r.at + 4 > r.bytes.len) {
            return error.Truncated;
        }
        const value: u32 = readInt(u32, r.bytes[r.at..][0..4], .little);
        r.at += 4;
        return value;
    }

    /// A rows x cols table of `[width]f32`, and its shape.
    fn table(
        r: *Reader,
        gpa: Allocator,
        comptime width: usize,
    ) !Table(width) {
        const rows: usize = try r.count();
        const cols: usize = try r.count();
        const out: [][width]f32 = try gpa.alloc([width]f32, rows * cols);
        const size: usize = rows * cols * width * @sizeOf(f32);
        if (r.at + size > r.bytes.len) {
            return error.Truncated;
        }
        @memcpy(sliceAsBytes(out), r.bytes[r.at..][0..size]);
        r.at += size;
        return .{ .data = out, .rows = rows, .cols = cols };
    }

    fn ints(r: *Reader, gpa: Allocator) ![]const i32 {
        const n: usize = try r.count();
        const out: []i32 = try gpa.alloc(i32, n);
        const size: usize = n * @sizeOf(i32);
        if (r.at + size > r.bytes.len) {
            return error.Truncated;
        }
        @memcpy(sliceAsBytes(out), r.bytes[r.at..][0..size]);
        r.at += size;
        return out;
    }
};

fn load(gpa: Allocator, bytes: []const u8) !Database {
    var r: Reader = .{ .bytes = bytes };
    const positions: Table(3) = try r.table(gpa, 3);
    _ = try r.table(gpa, 3); // velocities: derivable, and we don't need them
    const rotations: Table(4) = try r.table(gpa, 4);
    _ = try r.table(gpa, 3); // angular velocities: likewise
    const db: Database = .{
        .frames = positions.rows,
        .bones = positions.cols,
        .positions = positions.data,
        .rotations = rotations.data,
        .parents = try r.ints(gpa),
        .starts = try r.ints(gpa),
        .stops = try r.ints(gpa),
    };
    // Is it really LAFAN? Simulation, then exactly LAFAN's tree, then one range per take and
    // mirror.
    if (db.bones != bone_names.len + 1 or db.parents.len != db.bones) {
        return error.NotLafan;
    }
    if (db.parents[0] != -1) {
        return error.NotLafan;
    }
    for (bone_parents, 1..) |parent, i| {
        if (db.parents[i] != parent + 1) {
            return error.NotLafan;
        }
    }
    if (db.starts.len != 2 * take_names.len or db.stops.len != db.starts.len) {
        return error.NotLafan;
    }
    return db;
}

/// A rotation as BVH's Z-then-Y-then-X angles in degrees: the (z, y, x) for which
/// Rz(z) * Ry(y) * Rx(x) is `q`. That's exactly how `codecs.bvh` and `globalsAtFrame` rebuild a
/// rotation from channels listed as `Zrotation Yrotation Xrotation`.
///
/// y and z come from the rotation matrix of `q`: its bottom-left entry is -sin(y) and the first
/// column's top two are cos(y) times cos(z) and sin(z). y is taken as an atan2 rather than
/// asin(-r20), because asin is badly conditioned near +-90 degrees.
///
/// x is taken differently, and on purpose: it's whatever rotation is LEFT once z and y are undone.
/// Near gimbal lock (y close to +-90 degrees) z and x are each badly determined - only their
/// difference really is - and the matrix entries they'd come from lose digits to cancellation
/// (r00 = 1 - 2(y^2 + z^2) when that sum is near a half). Computed independently, their errors
/// add up: a third of a degree on a real walking foot. Taken as the remainder, x absorbs z's
/// error instead, and the three angles always rebuild `q`. At exact gimbal lock z is set to 0 and
/// x takes the whole twist.
fn eulerZYX(q: Quat) [3]f32 {
    const x: f32 = q[0];
    const y: f32 = q[1];
    const z: f32 = q[2];
    const w: f32 = q[3];
    const r00: f32 = 1.0 - 2.0 * (y * y + z * z);
    const r10: f32 = 2.0 * (x * y + w * z);
    const r20: f32 = 2.0 * (x * z - w * y);
    const cos_y: f32 = @sqrt(r00 * r00 + r10 * r10);
    const angle_y: f32 = atan2Rad(-r20, cos_y);
    const angle_z: f32 = if (cos_y > 1.0e-6) atan2Rad(r10, r00) else 0.0;
    const undo: Quat = qmul(quatFromAxisAngle(vec(0, 0, 1), angle_z), quatFromAxisAngle(vec(0, 1, 0), angle_y));
    var rest: Quat = qmul(conjugate(undo), q);
    if (rest[3] < 0.0) {
        rest = -rest;
    }
    const angle_x: f32 = 2.0 * atan2Rad(rest[0], rest[3]);
    const degrees: f32 = 180.0 / pi;
    return .{ angle_z * degrees, angle_y * degrees, angle_x * degrees };
}

/// The inverse, the way the BVH codec composes it: the listed channels, left to right.
fn quatFromEulerZYX(angles: [3]f32) Quat {
    const radians: f32 = pi / 180.0;
    const rz: Quat = quatFromAxisAngle(vec(0, 0, 1), angles[0] * radians);
    const ry: Quat = quatFromAxisAngle(vec(0, 1, 0), angles[1] * radians);
    const rx: Quat = quatFromAxisAngle(vec(1, 0, 0), angles[2] * radians);
    return qmul(qmul(rz, ry), rx);
}

/// Round to a fixed step, so the codec's shortest-round-trip printing writes short numbers. A
/// ten-thousandth of a degree and a thousandth of a centimetre are far below anything downstream.
fn quantize(value: f32, step: f32) f32 {
    return @round(value / step) * step;
}

/// Where a bone is and how it's turned, in the world.
const WorldPose = struct {
    position: Vec,
    rotation: Quat,
};

/// Hips' world transform at `frame`: the Simulation bone composed with Hips' local one.
fn hipsWorld(db: Database, frame: usize) WorldPose {
    const sim_position: Vec = db.position(frame, 0);
    const sim_rotation: Quat = db.rotation(frame, 0);
    return .{
        .position = sim_position + rotate(sim_rotation, db.position(frame, 1)),
        .rotation = qmul(sim_rotation, db.rotation(frame, 1)),
    };
}

/// One take as a BVH `Data`: the joints (with End Sites spliced in after the leaves) and the
/// motion, `frames` long from the take's first frame.
fn takeAsBvh(
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    db: Database,
    first: usize,
    frames: usize,
) !codecs.bvh.Data {
    const root_channels = [_]Channel{ .x_position, .y_position, .z_position, .z_rotation, .y_rotation, .x_rotation };
    const joint_channels = [_]Channel{ .z_rotation, .y_rotation, .x_rotation };

    // The hierarchy. `index_of_bone` remembers where each bone landed once End Sites are in.
    var joints: std.ArrayList(Joint) = .empty;
    var index_of_bone: [bone_names.len]i32 = undefined;
    for (bone_names, bone_parents, 0..) |name, parent, b| {
        const offset: Vec = if (parent < 0) vec(0, 0, 0) else db.position(first, b + 1) * splat(100.0);
        index_of_bone[b] = @intCast(joints.items.len);
        try joints.append(gpa, .{
            .name = name,
            .parent = if (parent < 0) -1 else index_of_bone[@intCast(parent)],
            .offset = .{ offset[0], offset[1], offset[2] },
            .channels = if (parent < 0) &root_channels else &joint_channels,
            .end_site = false,
        });
        for (end_sites) |site| {
            if (!std.mem.eql(u8, site.bone, name)) {
                continue;
            }
            try joints.append(gpa, .{
                .name = try allocPrint(gpa, "{s}End", .{name}),
                .parent = index_of_bone[b],
                .offset = .{ site.length, 0.0, 0.0 },
                .channels = &.{},
                .end_site = true,
            });
        }
    }

    // The motion: per frame, the root's position and rotation, then every other bone's rotation.
    const channel_count: usize = root_channels.len + (bone_names.len - 1) * joint_channels.len;
    const motion: []f32 = try gpa.alloc(f32, frames * channel_count);
    for (0..frames) |f| {
        const frame: usize = first + f;
        const row: []f32 = motion[f * channel_count ..][0..channel_count];
        const hips: WorldPose = hipsWorld(db, frame);
        var at: usize = 0;
        inline for (0..3) |c| {
            row[at] = quantize(hips.position[c] * 100.0, 0.001);
            at += 1;
        }
        for (0..bone_names.len) |b| {
            const local: Quat = if (b == 0) hips.rotation else db.rotation(frame, b + 1);
            for (eulerZYX(local)) |angle| {
                row[at] = quantize(angle, 0.0001);
                at += 1;
            }
        }
    }
    return .{
        .arena = arena,
        .joints = joints.items,
        .frame_count = frames,
        .channel_count = channel_count,
        .frame_time = 1.0 / frames_per_second,
        .motion = motion,
    };
}

/// Every bone's world position in centimetres at `frame`, straight from the database.
fn databasePositions(db: Database, frame: usize, out: []Vec) void {
    var world_rotation: [bone_names.len]Quat = undefined;
    for (bone_parents, 0..) |parent, b| {
        if (parent < 0) {
            const hips: WorldPose = hipsWorld(db, frame);
            out[b] = hips.position;
            world_rotation[b] = hips.rotation;
            continue;
        }
        const p: usize = @intCast(parent);
        out[b] = out[p] + rotate(world_rotation[p], db.position(frame, b + 1));
        world_rotation[b] = qmul(world_rotation[p], db.rotation(frame, b + 1));
    }
    for (out) |*position| {
        position.* *= splat(100.0);
    }
}

/// The same, from a parsed BVH frame - rebuilding each rotation from its Euler channels the way
/// the codec does. Only the real bones (not the End Sites) are compared.
fn bvhPositions(data: codecs.bvh.Data, frame: usize, out: []Vec) void {
    const values: []const f32 = data.frame(frame);
    var world_position: [bone_names.len + end_sites.len]Vec = undefined;
    var world_rotation: [bone_names.len + end_sites.len]Quat = undefined;
    var at: usize = 0;
    var bone: usize = 0;
    for (data.joints, 0..) |joint, j| {
        if (joint.end_site) {
            continue;
        }
        var position: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        var angles: [3]f32 = undefined;
        var angle: usize = 0;
        for (joint.channels) |channel| {
            const value: f32 = values[at];
            at += 1;
            switch (channel) {
                .x_position => position[0] = value,
                .y_position => position[1] = value,
                .z_position => position[2] = value,
                else => {
                    angles[angle] = value;
                    angle += 1;
                },
            }
        }
        const local: Quat = quatFromEulerZYX(angles);
        if (joint.parent < 0) {
            world_position[j] = position;
            world_rotation[j] = local;
        } else {
            const p: usize = @intCast(joint.parent);
            world_position[j] = world_position[p] + rotate(world_rotation[p], position);
            world_rotation[j] = qmul(world_rotation[p], local);
        }
        out[bone] = world_position[j];
        bone += 1;
    }
}

fn say(io: Io, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    try File.stdout().writeStreamingAll(io, try allocPrint(gpa, fmt, args));
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: Io = init.io;

    var args: ArgIterator = try ArgIterator.initAllocator(init.minimal.args, gpa);
    _ = args.skip();
    const database_path: []const u8 = args.next() orelse return error.Usage;
    const out_dir: []const u8 = args.next() orelse return error.Usage;
    const seconds: f32 = try std.fmt.parseFloat(f32, args.next() orelse return error.Usage);

    const bytes: []u8 = try Dir.cwd().readFileAlloc(io, database_path, gpa, .limited(256 << 20));
    const db: Database = try load(gpa, bytes);
    try say(io, gpa, "database: {d} frames x {d} bones, {d} ranges\n", .{ db.frames, db.bones, db.starts.len });

    for (take_names, 0..) |name, t| {
        // The recorded copy is range 2t; 2t + 1 is its mirror.
        const first: usize = @intCast(db.starts[2 * t]);
        const available: usize = @as(usize, @intCast(db.stops[2 * t])) - first;
        const wanted: usize = @trunc(seconds * frames_per_second);
        const frames: usize = @min(available, wanted);

        const data: codecs.bvh.Data = try takeAsBvh(gpa, &arena_state, db, first, frames);
        const text: []u8 = try codecs.bvh.encode(gpa, data);

        // The check: read our own file back and compare every joint of every frame.
        var parsed: codecs.bvh.Data = try codecs.bvh.parse(gpa, text, null);
        defer parsed.deinit();
        var worst: f32 = 0.0;
        var worst_frame: usize = 0;
        var worst_bone: usize = 0;
        var from_db: [bone_names.len]Vec = undefined;
        var from_bvh: [bone_names.len]Vec = undefined;
        for (0..frames) |f| {
            databasePositions(db, first + f, &from_db);
            bvhPositions(parsed, f, &from_bvh);
            for (from_db, from_bvh, 0..) |a, b, bone| {
                const off: f32 = length3(a - b);
                if (off > worst) {
                    worst = off;
                    worst_frame = f;
                    worst_bone = bone;
                }
            }
        }
        if (worst > 0.01) {
            // Say exactly where, so a failure points at its cause instead of starting a hunt.
            databasePositions(db, first + worst_frame, &from_db);
            bvhPositions(parsed, worst_frame, &from_bvh);
            const a: Vec = from_db[worst_bone];
            const b: Vec = from_bvh[worst_bone];
            try say(io, gpa, "{s}: round trip off by {d:.4} cm at frame {d}, {s}: database ({d:.3}, {d:.3}, {d:.3}) " ++
                "vs BVH ({d:.3}, {d:.3}, {d:.3}) - not written\n", .{
                name, worst, worst_frame, bone_names[worst_bone], a[0], a[1], a[2], b[0], b[1], b[2],
            });
            return error.RoundTripFailed;
        }

        const path: []u8 = try allocPrint(gpa, "{s}/{s}.bvh", .{ out_dir, name });
        try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        try say(io, gpa, "{s}: {d} frames ({d:.1} s), {d} KB, worst joint round trip {d:.5} cm\n", .{
            path,
            frames,
            @as(f32, @floatFromInt(frames)) / frames_per_second,
            text.len / 1024,
            worst,
        });
    }
}
