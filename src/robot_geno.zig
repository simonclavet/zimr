//! robot_geno - Geno's own measurements, as the robot's.
//!
//! WHY THIS FILE EXISTS
//!
//! The captures we train on are the LaFAN *resolved* set: already retargeted onto the Geno character
//! by the people who published it. Every one of their 35 joints is a Geno joint - Geno has 40 more,
//! all fingers - and their bone offsets agree with Geno's to under two millimetres. So a robot built
//! from Geno's own skeleton needs no retargeting at all: tracking a capture becomes copying its joint
//! rotations, with nothing to align and nothing to tune.
//!
//! That matters beyond tidiness. A retarget that matches SEGMENT DIRECTIONS silently rotates anything
//! whose rest orientation differs, and the foot is exactly such a thing: in Geno's rest pose the line
//! from ankle to toe DESCENDS about 22 degrees, because the toe joint sits below the ankle and a mocap
//! skeleton has no heel at all. A robot whose foot segment is horizontal inherits that 22 degrees as
//! sole tilt, and then cannot stand on the reference it is asked to follow. Built from these
//! measurements, the anatomy is inside the model instead of being fought by it.
//!
//! WHAT IS HERE
//!
//!   - **R1, the skeleton.** The bind pose (the A-pose the mesh is skinned in) and the stance pose (a
//!     T-pose) as the viewer ships them, parsed into bones with parents and offsets IN METRES - Geno's
//!     files are centimetres, y-up - and every bone's rotation, both in the world and relative to its
//!     parent.
//!   - **R2, the rest pose.** Which pose the robot calls "no rotation" (bind - see `rest_pose` for
//!     why), and the two small functions the whole robot will rest on: a pose's joint rotations
//!     measured away from rest (`jointFromLocal`, which is all retargeting is now) and the kinematics
//!     that turn them back into a pose (`restForward`).
//!   - **R3, the mesh and the sole.** Geno's skinned mesh read whole (`readMesh`), and the plane each
//!     foot stands on derived from it (`solePlane`) - so the robot's feet are placed from the body they
//!     copy, not from a guess.
//!   - **R5, mass and inertia.** The volume inside the skin, measured (`measureVolume`), and shared out
//!     between the bones: every segment's mass, centre and inertia tensor - cut at the joints the way
//!     the anthropometry tables cut them (`Partition.joint_planes`, R5b).
//!
//!   - **R6, joint ranges.** How far every joint actually turns across the tracking set's four clips -
//!     total, swing and twist, each limit holding 99.5 % of the frames, the rarer extremes named.
//!
//!   - **R6b, the model.** All of the above written out as MJCF the engine loads (`writeModel`): the
//!     kinematic tree in the bind pose, ball joints with measured limits, the body's own masses.
//!
//! The shapes, the floor and the actuators follow, one measured step at a time (the plan's Phase R).

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const codecs = @import("codecs.zig");
/// The task's clip format - a copied clip is one, exactly as an IK-baked clip is.
const dance = @import("robot_dance.zig");
/// SuperTrack's learner on the CPU: the latent world model and the policy trained through it.
const latent = @import("robot_latent.zig");
/// DReCon's observation and action layer, and the SAC agent - for the model-free trials on Geno (S2b).
const robot_policy = @import("robot_policy.zig");
const robot_gym = @import("robot_gym.zig");
/// The task's servo - the law a policy acts through - which Geno must be driven by unchanged (R8a).
const robot_track = @import("robot_track.zig");
/// The stable spring both servo laws share.
const robot_maximal = @import("robot_maximal.zig");
/// The collision shapes `tools/geno_fit.py` fitted to Geno's mesh (R4), in bind-pose world coordinates.
const shapes = @import("robot_geno_shapes.zig");

const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const assertf = zm.assertf;
const splat = zm.splat;
const qmul = zm.qmul;
const rotate = zm.rotate;
const qidentity = zm.qidentity;
const conjugate = zm.conjugate;
const dot3 = zm.dot3;
const normalize3 = zm.normalize3;
const dot4 = zm.dot4;
const atan2Rad = zm.atan2Rad;
const int = zm.int;
const float = zm.float;
const float64 = zm.float64;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const radFromDeg = zm.radFromDeg;
const degFromRad = zm.degFromRad;
const asinRad = zm.asinRad;
const clamp = zm.clamp;
const pi = zm.pi;
const length3 = zm.length3;

/// Geno's files are in centimetres; everything in zimr is metres.
pub const cm: f32 = 0.01;

/// One bone of the skeleton: what it is called, whose child it is, and where it sits in its parent's
/// frame when nothing is rotated.
pub const Bone = struct {
    name: []const u8,
    /// Index of the parent bone, or -1 for the root.
    parent: i32,
    /// The offset from the parent, in METRES.
    offset: Vec,
};

/// A pose of the skeleton: every bone's world position and rotation, with the skeleton it came from.
pub const Posed = struct {
    bones: []Bone,
    /// Every bone's place in the world, in metres.
    positions: []Vec,
    /// Every bone's rotation in the WORLD.
    rotations: []Quat,
    /// Every bone's OWN rotation - the one its channels spell out, relative to its parent. The robot
    /// is built from these (its body frames are the rest pose's locals, R2), and copying a capture onto
    /// it is comparing a capture's locals with the rest's, joint by joint.
    locals: []Quat,
    names: [][]u8,

    pub fn deinit(self: *Posed, gpa: Allocator) void {
        for (self.names) |name| {
            gpa.free(name);
        }
        gpa.free(self.names);
        gpa.free(self.locals);
        gpa.free(self.rotations);
        gpa.free(self.positions);
        gpa.free(self.bones);
    }

    /// The bone with this exact name, or null. Names are Geno's own ("LeftFoot", "LeftToeBase").
    pub fn find(self: Posed, want: []const u8) ?usize {
        for (self.bones, 0..) |bone, i| {
            if (std.mem.eql(u8, bone.name, want)) {
                return i;
            }
        }
        return null;
    }

    /// Where a named bone sits, in metres.
    pub fn at(self: Posed, want: []const u8) ?Vec {
        return if (self.find(want)) |i| self.positions[i] else null;
    }
};

/// One channel of a BVH frame, applied to a joint's local place and turn: a position channel SETS its
/// coordinate (centimetres in, metres out), a rotation channel COMPOSES onto the turn so far. Rotations
/// go on in the order the file lists them - files disagree (ZYX, XYZ and ZXY all occur in the wild), so
/// that order is read from each file, never assumed.
fn applyChannel(channel: codecs.bvh.Channel, value: f32, local: *Vec, turn: *Quat) void {
    switch (channel) {
        .x_position => local.*[0] = value * cm,
        .y_position => local.*[1] = value * cm,
        .z_position => local.*[2] = value * cm,
        .x_rotation => turn.* = qmul(turn.*, quatFromAxisAngle(vec(1, 0, 0), radFromDeg(value))),
        .y_rotation => turn.* = qmul(turn.*, quatFromAxisAngle(vec(0, 1, 0), radFromDeg(value))),
        .z_rotation => turn.* = qmul(turn.*, quatFromAxisAngle(vec(0, 0, 1), radFromDeg(value))),
    }
}

/// Read one of Geno's pose files - the bind pose or the stance - into bones and their world places.
/// The file's single frame IS the pose; its hierarchy is the skeleton.
///
/// The kinematics are done here rather than borrowed from the renderer's, because this file belongs to
/// the shader-free tier that the robot's tests run in - and because the offsets then come straight out
/// of the file instead of being recovered from a pose.
pub fn readPose(gpa: Allocator, bytes: []const u8) !Posed {
    var data: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer data.deinit();
    const count: usize = data.joints.len;
    assertf(count > 0, @src(), "readPose: a skeleton with no joints", .{});

    const positions: []Vec = try gpa.alloc(Vec, count);
    errdefer gpa.free(positions);
    const rotations: []Quat = try gpa.alloc(Quat, count);
    errdefer gpa.free(rotations);
    const locals: []Quat = try gpa.alloc(Quat, count);
    errdefer gpa.free(locals);
    const names: [][]u8 = try gpa.alloc([]u8, count);
    errdefer gpa.free(names);
    var made: usize = 0;
    errdefer for (names[0..made]) |name| {
        gpa.free(name);
    };
    const bones: []Bone = try gpa.alloc(Bone, count);
    errdefer gpa.free(bones);

    const frame: []const f32 = data.frame(0);
    var taken: usize = 0;
    for (data.joints, 0..) |joint, i| {
        names[i] = try gpa.dupe(u8, joint.name);
        made += 1;
        const offset: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]) * splat(cm);
        bones[i] = .{ .name = names[i], .parent = joint.parent, .offset = offset };

        // The channels of this joint, in the order the file lists them - which is also the order the
        // rotations must be applied in. Files disagree (ZYX, XYZ and ZXY all occur in the wild), so the
        // order is read, never assumed.
        var local: Vec = offset;
        var turn: Quat = qidentity();
        for (joint.channels) |channel| {
            applyChannel(channel, frame[taken], &local, &turn);
            taken += 1;
        }
        locals[i] = turn;
        if (joint.parent < 0) {
            positions[i] = local;
            rotations[i] = turn;
        } else {
            const up: usize = @intCast(joint.parent);
            positions[i] = positions[up] + rotate(rotations[up], local);
            rotations[i] = qmul(rotations[up], turn);
        }
    }
    return .{ .bones = bones, .positions = positions, .rotations = rotations, .locals = locals, .names = names };
}

// -------- R2: the rest pose --------
//
// Every joint of a robot reads "no rotation" in ONE pose - its zero pose - and much of the model is
// measured from there: a joint's range is an angle away from it, a hinge's axis is drawn in it, and the
// servo holding the robot still is holding it there. So which pose that is gets DECIDED, and written
// down once, before anything is built on top of it.

/// The two poses Geno ships in - either could be the robot's zero.
pub const RestPose = enum {
    /// The A-pose the mesh is skinned in: arms 45 degrees down, feet flat on the floor.
    bind,
    /// A T-pose: arms out level. The same bones and offsets as bind; only the rotations differ.
    stance,
};

/// DECLARED: the robot's zero pose is Geno's BIND pose.
///
/// Three reasons, the first of which settles it on its own:
///
///   1. **The mesh lives there.** Geno's mesh is skinned in the bind pose, so everything this phase
///      measures from the body - the collision shapes (R4), the sole each foot stands on (R3), every
///      segment's mass (R5) - is measured in bind. With bind as the zero pose all of that is exact at
///      q = 0, and there is no pose conversion anywhere between the mesh and the model to get wrong.
///   2. **The file's own zero is a poor middle.** With every ROTATION at zero (the translations kept,
///      which in these files are the offsets), Geno stands with both arms straight UP - the upper arm
///      89 degrees above level, the fingertips 2.1 m above the toes - legs straight down and feet level.
///      A robot whose body frames were simply the offsets would call that "no rotation", and centre
///      every joint range on the arms overhead: about as far from how arms are used as a pose can be.
///      (Measured, and asserted in the R2 test. Careful measuring it: Geno's files carry POSITION
///      channels on every joint, not just the root, so zeroing every channel collapses the skeleton
///      onto its hips - which is not the file's zero, just a broken pose.)
///
///      It also shows where the foot's anatomy lives. At zero rotation the ankle-to-ball line is LEVEL;
///      it is the ankle's rest rotation that tilts it 23 degrees down. So the tilt is in the pose, not
///      in the bones - which is why a copy of the rotations carries it for free.
///   3. **It is a natural middle.** Arms half down, legs straight, feet flat: most joints spend their
///      everyday motion around it, which is where a symmetric limit wants its centre.
///
/// The stance stays one file away as a stored pose, and `jointFromLocal` turns it into joint rotations
/// like any other pose.
pub const rest_pose: RestPose = .bind;

/// THE ANATOMY CONSTANT, written once. In the rest pose, with the foot flat on the floor, the line from
/// the ankle to the ball of the foot DESCENDS by this many degrees - the toe joint sits below the ankle,
/// and a mocap skeleton has no heel. It is not an error to correct; it is the shape of a foot. A robot
/// whose foot segment was level inherited it as sole tilt (35.7 degrees on average when a foot was down,
/// on the old robot); a robot built from Geno carries it inside its foot instead. (The stance reads
/// 21.9; the R2 test holds this number to the measurement.)
pub const rest_sole_descent_deg: f32 = 23.3;

/// A pose's joint rotation, as the ROBOT's joint reads it: the turn AWAY FROM THE REST POSE.
///
/// This is how the robot will be put together (R6b builds it exactly so): every body's frame is the
/// rest pose's local rotation, and its joint turns on top of that. So a body's world rotation is
///
///     the robot's:    parent_world * rest_local * joint
///     the capture's:  parent_world * pose_local
///
/// and the two are the same rotation exactly when `joint = conj(rest_local) * pose_local`, which is all
/// this function does. Now that the robot and the captures share one skeleton, that single line IS
/// retargeting (R7) - no inverse kinematics, no alignment, nothing to tune.
pub fn jointFromLocal(rest_local: Quat, pose_local: Quat) Quat {
    return qmul(conjugate(rest_local), pose_local);
}

/// Forward kinematics as the ROBOT will do it: from joint rotations measured away from the rest pose
/// (identity = rest), rather than from a file's channels. Writes every bone's world position and
/// rotation.
///
/// It exists to prove the convention BEFORE a model is built on it. Identity joints must give back the
/// rest pose itself; `jointFromLocal` of any other pose must give back THAT pose - bone for bone, to
/// float noise. If either ever stops being true, the robot and its captures have quietly parted, and
/// every number measured afterwards would be about the wrong body.
pub fn restForward(
    bones: []const Bone,
    rest_locals: []const Quat,
    root_position: Vec,
    joints: []const Quat,
    out_positions: []Vec,
    out_rotations: []Quat,
) void {
    const n: usize = bones.len;
    const matched: bool = rest_locals.len == n and joints.len == n;
    assertf(matched, @src(), "restForward: {d} bones, {d} rest rotations, {d} joints", .{
        n,
        rest_locals.len,
        joints.len,
    });
    assertf(out_positions.len >= n and out_rotations.len >= n, @src(), "restForward: room for {d} bones, need {d}", .{
        @min(out_positions.len, out_rotations.len),
        n,
    });
    for (bones, 0..) |bone, i| {
        // The body's own frame - its rest rotation - and then its joint on top of it.
        const turn: Quat = qmul(rest_locals[i], joints[i]);
        if (bone.parent < 0) {
            // The root is not an offset from anything: the pose says where it is.
            out_positions[i] = root_position;
            out_rotations[i] = turn;
        } else {
            // Parents come before their children in the file, so the parent is already placed.
            assertf(bone.parent < i, @src(), "restForward: bone {d}'s parent {d} comes after it", .{ i, bone.parent });
            const up: usize = @intCast(bone.parent);
            out_positions[i] = out_positions[up] + rotate(out_rotations[up], bone.offset);
            out_rotations[i] = qmul(out_rotations[up], turn);
        }
    }
}

// -------- R3: Geno's mesh, and the sole it stands on --------

/// Geno's skinned mesh, exactly as the viewer's export script writes it
/// (`GenoView/resources/export_geno.py`, the `Geno.bin` it saves):
///
///     three u32 counts                      vertices, triangles, joints
///     per vertex, each a solid block:       position (3 f32, METRES), texture coordinate (2 f32),
///                                           normal (3 f32), four joint indices (u8), four weights (f32)
///     per triangle                          three vertex indices (u16)
///     per joint                             name (32 bytes, zero-padded), parent (i32)
///     per joint, again                      world transform in the bind pose: position (3 f32),
///                                           rotation (x, y, z, w), scale (3 f32, always 1)
///
/// Only what the robot needs is kept: where the vertices are, which joints move them, the triangles (R5
/// measures volumes with them), and each joint's name and bind position - the last so a test can prove
/// the mesh and our own skeleton share one frame before anything is measured across the two.
pub const Mesh = struct {
    /// Every vertex in the bind pose, in metres, y-up, the floor at y = 0.
    positions: []Vec,
    /// Up to four joints moving each vertex (indices into `joint_names`), and how much each does.
    joints: [][4]u8,
    weights: [][4]f32,
    /// Three vertex indices per triangle.
    triangles: [][3]u16,
    joint_names: [][]u8,
    joint_parents: []i32,
    /// Each joint's world position in the bind pose, as the exporter wrote it.
    joint_bind_positions: []Vec,

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        for (self.joint_names) |name| {
            gpa.free(name);
        }
        gpa.free(self.joint_bind_positions);
        gpa.free(self.joint_parents);
        gpa.free(self.joint_names);
        gpa.free(self.triangles);
        gpa.free(self.weights);
        gpa.free(self.joints);
        gpa.free(self.positions);
    }

    /// The joint that moves vertex `v` the most - in plain words, whose flesh this is.
    pub fn owner(self: Mesh, v: usize) usize {
        var best: usize = 0;
        for (1..4) |k| {
            if (self.weights[v][k] > self.weights[v][best]) {
                best = k;
            }
        }
        return self.joints[v][best];
    }

    /// The joint with this exact name, or null.
    pub fn joint(self: Mesh, want: []const u8) ?usize {
        for (self.joint_names, 0..) |name, j| {
            if (std.mem.eql(u8, name, want)) {
                return j;
            }
        }
        return null;
    }
};

/// Reads little-endian numbers off the front of a byte slice, for the one binary format in this file.
/// A short read is an assertion, not an error: the file is a fixture we ship, and a truncated or
/// misunderstood one is a bug that should stop everything and say where.
const LittleEndian = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *LittleEndian, n: usize) []const u8 {
        assertf(self.at + n <= self.bytes.len, @src(), "readMesh: wanted {d} bytes at {d}, the file has {d}", .{
            n,
            self.at,
            self.bytes.len,
        });
        const out: []const u8 = self.bytes[self.at .. self.at + n];
        self.at += n;
        return out;
    }

    fn skip(self: *LittleEndian, n: usize) void {
        _ = self.take(n);
    }

    fn byte(self: *LittleEndian) u8 {
        return self.take(1)[0];
    }

    fn uint16(self: *LittleEndian) u16 {
        return std.mem.readInt(u16, self.take(2)[0..2], .little);
    }

    fn uint32(self: *LittleEndian) u32 {
        return std.mem.readInt(u32, self.take(4)[0..4], .little);
    }

    fn int32(self: *LittleEndian) i32 {
        return std.mem.readInt(i32, self.take(4)[0..4], .little);
    }

    fn float32(self: *LittleEndian) f32 {
        return @bitCast(self.uint32());
    }

    fn triple(self: *LittleEndian) Vec {
        const x: f32 = self.float32();
        const y: f32 = self.float32();
        const z: f32 = self.float32();
        return vec(x, y, z);
    }
};

/// Read Geno's skinned mesh (the layout is spelled out on `Mesh`). The whole file must be accounted
/// for - a byte left over means the layout above is not the file's, and nothing measured from it could
/// be trusted.
pub fn readMesh(gpa: Allocator, bytes: []const u8) !Mesh {
    var r: LittleEndian = .{ .bytes = bytes };
    const vertex_count: usize = r.uint32();
    const triangle_count: usize = r.uint32();
    const joint_count: usize = r.uint32();

    const positions: []Vec = try gpa.alloc(Vec, vertex_count);
    errdefer gpa.free(positions);
    for (positions) |*p| {
        p.* = r.triple();
    }
    // Texture coordinates (two floats each) and normals (three): a robot has no use for either.
    r.skip(vertex_count * (2 + 3) * @sizeOf(f32));

    const joints: [][4]u8 = try gpa.alloc([4]u8, vertex_count);
    errdefer gpa.free(joints);
    for (joints) |*four| {
        for (0..4) |k| {
            four[k] = r.byte();
        }
    }
    const weights: [][4]f32 = try gpa.alloc([4]f32, vertex_count);
    errdefer gpa.free(weights);
    for (weights) |*four| {
        for (0..4) |k| {
            four[k] = r.float32();
        }
    }
    const triangles: [][3]u16 = try gpa.alloc([3]u16, triangle_count);
    errdefer gpa.free(triangles);
    for (triangles) |*three| {
        for (0..3) |k| {
            three[k] = r.uint16();
        }
    }

    const joint_names: [][]u8 = try gpa.alloc([]u8, joint_count);
    errdefer gpa.free(joint_names);
    var named: usize = 0;
    errdefer for (joint_names[0..named]) |name| {
        gpa.free(name);
    };
    const joint_parents: []i32 = try gpa.alloc(i32, joint_count);
    errdefer gpa.free(joint_parents);
    for (0..joint_count) |j| {
        // A C-style name: 32 bytes, the name, then zeros.
        const raw: []const u8 = r.take(32);
        const name_length: usize = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        joint_names[j] = try gpa.dupe(u8, raw[0..name_length]);
        named += 1;
        joint_parents[j] = r.int32();
    }
    const joint_bind_positions: []Vec = try gpa.alloc(Vec, joint_count);
    errdefer gpa.free(joint_bind_positions);
    for (joint_bind_positions) |*p| {
        p.* = r.triple();
        // The rotation (four floats) and the scale (three, always 1): our own kinematics of the bind
        // file give the rotations, in the convention the robot uses, so these are not needed.
        r.skip(7 * @sizeOf(f32));
    }
    assertf(r.at == bytes.len, @src(), "readMesh: {d} bytes left over - the layout is not the file's", .{
        bytes.len - r.at,
    });
    return .{
        .positions = positions,
        .joints = joints,
        .weights = weights,
        .triangles = triangles,
        .joint_names = joint_names,
        .joint_parents = joint_parents,
        .joint_bind_positions = joint_bind_positions,
    };
}

/// Which foot.
pub const Side = enum {
    left,
    right,

    /// How Geno's bone names begin on this side: "LeftFoot", "RightToeBase".
    pub fn prefix(side: Side) []const u8 {
        return switch (side) {
            .left => "Left",
            .right => "Right",
        };
    }
};

/// "Touching the floor" means within this much of the sole plane. A flat sole's lowest vertices lie
/// within a few millimetres of one another, while a lifted heel or toe clears the floor by centimetres,
/// so the band sits comfortably between the two.
pub const touch_band: f32 = 0.005;

/// Where one foot meets the floor in the rest pose, measured on the mesh.
pub const Sole = struct {
    /// The sole plane's height: the foot's lowest vertex, in metres. The floor is y = 0.
    height: f32,
    /// How far the ankle joint rides above the sole - the foot's depth. A robot foot without it
    /// hovers wherever the capture's foot is planted (the old robot's was 2.7 cm).
    ankle_height: f32,
    /// How far the touching region reaches along the foot, from the ankle, along the foot's forward
    /// direction on the floor: `heel` is its rearmost point (negative means behind the ankle) and `toe`
    /// its foremost.
    heel: f32,
    toe: f32,
    /// Where the ball of the foot - the toe joint - sits along that same line. Anything touching past
    /// it is under the toes.
    ball: f32,
    /// How many of the foot's vertices lie within `touch_band` of the sole.
    touching: usize,
};

/// R3: derive a foot's sole from Geno's own mesh, in the rest pose.
///
/// The foot's flesh is every vertex whose strongest joint is the foot or its toe. Its lowest point is
/// the sole plane - the plane the robot's foot geoms must share when the model is assembled (R6b takes
/// it from here, not from a guess). The vertices within `touch_band` of that plane are the ones that
/// touch, and how far they reach along the foot says whether the heel AND the toes are down - which is
/// what "flat" means for a foot whose ankle-to-ball line is tilted by `rest_sole_descent_deg`.
pub fn solePlane(mesh: Mesh, bind: Posed, side: Side) !Sole {
    var foot_buffer: [32]u8 = undefined;
    var toe_buffer: [32]u8 = undefined;
    const foot_name: []const u8 = try bufPrint(&foot_buffer, "{s}Foot", .{side.prefix()});
    const toe_name: []const u8 = try bufPrint(&toe_buffer, "{s}ToeBase", .{side.prefix()});

    // The foot's own frame on the floor: from the ankle, pointing where the foot points.
    const ankle: Vec = bind.at(foot_name) orelse return error.NoAnkle;
    const ball: Vec = bind.at(toe_name) orelse return error.NoBall;
    const forward: Vec = normalize3((ball - ankle) * vec(1, 0, 1));

    const foot_joint: usize = mesh.joint(foot_name) orelse return error.NoFootInMesh;
    const toe_joint: usize = mesh.joint(toe_name) orelse return error.NoToeInMesh;

    // First pass: the lowest point of the foot's flesh.
    var lowest: f32 = 1.0e9;
    for (mesh.positions, 0..) |p, v| {
        const whose: usize = mesh.owner(v);
        if (whose == foot_joint or whose == toe_joint) {
            lowest = @min(lowest, p[1]);
        }
    }
    if (lowest == 1.0e9) {
        return error.NoFootVertices;
    }

    // Second pass: the vertices that touch, and how far along the foot they reach.
    var heel: f32 = 1.0e9;
    var toe: f32 = -1.0e9;
    var touching: usize = 0;
    for (mesh.positions, 0..) |p, v| {
        const whose: usize = mesh.owner(v);
        if ((whose == foot_joint or whose == toe_joint) and p[1] <= lowest + touch_band) {
            const along: f32 = dot3(p - ankle, forward);
            heel = @min(heel, along);
            toe = @max(toe, along);
            touching += 1;
        }
    }
    return .{
        .height = lowest,
        .ankle_height = ankle[1] - lowest,
        .heel = heel,
        .toe = toe,
        .ball = dot3(ball - ankle, forward),
        .touching = touching,
    };
}

// -------- R5: mass and inertia, from the body's own volume --------
//
// A robot's masses are usually guesses - a density times each collision shape's volume, or numbers out
// of a table. Ours can do better, because the body itself is right here: Geno's mesh is a skin around a
// volume, and that volume can be MEASURED, then shared out between the bones by the same rule that says
// whose flesh a vertex is. The collision shapes are the wrong thing to weigh: they are sized to meet the
// floor where the skin does and to overlap at every joint, so their volumes add up to far more than the
// body's (108 litres against Geno's own, measured below).

/// What the robot is made of: water, a thousand kilograms a cubic metre. A living body is within a few
/// percent of that - lungs and fat below it, muscle and bone above - and ONE density everywhere is the
/// point: the flesh's shape decides how the mass is shared, not a table.
pub const density: f32 = 1000.0;

/// How finely the volume is sampled: vertical columns this far apart across the floor, and steps this
/// long up each column. A centimetre puts every limb dozens of samples across.
pub const volume_step: f32 = 0.01;

/// One bone's share of the body, summed as the volume is sampled. Kept in f64: a segment is thousands of
/// tiny samples, and f32 would quietly lose the small ones against the running total.
pub const Share = struct {
    /// Cubic metres.
    volume: f64 = 0.0,
    /// The first moment: the sum of volume times position, which divided by the volume is the centre.
    first: [3]f64 = .{ 0.0, 0.0, 0.0 },
    /// The second moment about the WORLD origin: the sum of volume times position_i times position_j,
    /// plus each sample's own spread. The inertia tensor comes out of it (see `inertia`).
    second: [3][3]f64 = .{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },

    /// Add one sample: a small upright box of `size` (x, y, z) around `at`. Its own spread about its
    /// centre is added too - a uniform box's second moment along an axis is its length there squared
    /// over twelve, per unit volume - which makes the sum EXACT for anything built of such boxes, and
    /// keeps small segments (a hand is ten samples across) from reading too light in rotation.
    fn addBox(self: *Share, at: Vec, size: [3]f64) void {
        const v: f64 = size[0] * size[1] * size[2];
        const p: [3]f64 = .{ at[0], at[1], at[2] };
        self.volume += v;
        for (0..3) |i| {
            self.first[i] += v * p[i];
            for (0..3) |j| {
                self.second[i][j] += v * p[i] * p[j];
            }
            self.second[i][i] += v * size[i] * size[i] / 12.0;
        }
    }

    /// Fold another share into this one - how bones become segments.
    pub fn merge(self: *Share, other: Share) void {
        self.volume += other.volume;
        for (0..3) |i| {
            self.first[i] += other.first[i];
            for (0..3) |j| {
                self.second[i][j] += other.second[i][j];
            }
        }
    }

    /// Kilograms.
    pub fn mass(self: Share) f32 {
        return @floatCast(self.volume * density);
    }

    /// The centre of mass, in the rest pose's world coordinates.
    pub fn centre(self: Share) Vec {
        return vec(
            @floatCast(self.first[0] / self.volume),
            @floatCast(self.first[1] / self.volume),
            @floatCast(self.first[2] / self.volume),
        );
    }

    /// The inertia tensor about the centre of mass, in world axes, kilogram square metres.
    ///
    /// From the moments by the parallel-axis theorem in matrix form: move the second moment from the
    /// origin to the centre (`S_c = S - V c c^T`), then `I = density (trace(S_c) 1 - S_c)` - which is
    /// just the definition, `I = integral of (|r|^2 1 - r r^T) dm`, with the integral already summed.
    pub fn inertia(self: Share) [3][3]f32 {
        const c: [3]f64 = .{ self.first[0] / self.volume, self.first[1] / self.volume, self.first[2] / self.volume };
        var about_centre: [3][3]f64 = undefined;
        for (0..3) |i| {
            for (0..3) |j| {
                about_centre[i][j] = self.second[i][j] - self.volume * c[i] * c[j];
            }
        }
        const trace: f64 = about_centre[0][0] + about_centre[1][1] + about_centre[2][2];
        var out: [3][3]f32 = undefined;
        for (0..3) |i| {
            for (0..3) |j| {
                const diagonal: f64 = if (i == j) trace else 0.0;
                out[i][j] = @floatCast(density * (diagonal - about_centre[i][j]));
            }
        }
        return out;
    }
};

/// Which vertex is nearest a point, answered fast. Every vertex is filed under the cube of side `cell`
/// it sits in; a query searches outward from its own cube, one shell of cubes at a time, and stops as
/// soon as nothing in an unsearched shell could be closer than the best found - every cube `ring`
/// shells out is at least `ring` whole cubes from any point in the middle one.
const Nearest = struct {
    positions: []const Vec,
    cell: f32,
    low: Vec,
    size: [3]usize,
    /// For cube k, its vertices are `order[first[k]..first[k + 1]]`.
    first: []u32,
    order: []u32,

    fn init(gpa: Allocator, positions: []const Vec, cell: f32) !Nearest {
        var low: Vec = positions[0];
        var high: Vec = positions[0];
        for (positions) |p| {
            low = @min(low, p);
            high = @max(high, p);
        }
        var size: [3]usize = undefined;
        // A vector's lanes can only be picked at compile time, hence the inline loop.
        inline for (0..3) |axis| {
            size[axis] = int(usize, (high[axis] - low[axis]) / cell) + 1;
        }
        var grid: Nearest = .{
            .positions = positions,
            .cell = cell,
            .low = low,
            .size = size,
            .first = &.{},
            .order = &.{},
        };
        const cubes: usize = size[0] * size[1] * size[2];

        // A counting sort by cube: count, add up, then drop each vertex into its place.
        const first: []u32 = try gpa.alloc(u32, cubes + 1);
        errdefer gpa.free(first);
        @memset(first, 0);
        for (positions) |p| {
            first[grid.cubeOf(p) + 1] += 1;
        }
        for (1..cubes + 1) |k| {
            first[k] += first[k - 1];
        }
        const order: []u32 = try gpa.alloc(u32, positions.len);
        errdefer gpa.free(order);
        const next: []u32 = try gpa.alloc(u32, cubes);
        defer gpa.free(next);
        @memcpy(next, first[0..cubes]);
        for (positions, 0..) |p, v| {
            const k: usize = grid.cubeOf(p);
            order[next[k]] = @intCast(v);
            next[k] += 1;
        }
        grid.first = first;
        grid.order = order;
        return grid;
    }

    fn deinit(self: *Nearest, gpa: Allocator) void {
        gpa.free(self.order);
        gpa.free(self.first);
    }

    /// The cube a point falls in along one axis, held inside the grid.
    fn along(self: Nearest, p: Vec, comptime axis: usize) i64 {
        const raw: f32 = (p[axis] - self.low[axis]) / self.cell;
        const top: i64 = @intCast(self.size[axis] - 1);
        return if (raw <= 0.0) 0 else @min(int(i64, raw), top);
    }

    fn index(self: Nearest, x: i64, y: i64, z: i64) usize {
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        const uz: usize = @intCast(z);
        return (ux * self.size[1] + uy) * self.size[2] + uz;
    }

    fn cubeOf(self: Nearest, p: Vec) usize {
        return self.index(self.along(p, 0), self.along(p, 1), self.along(p, 2));
    }

    fn find(self: Nearest, p: Vec) usize {
        const cx: i64 = self.along(p, 0);
        const cy: i64 = self.along(p, 1);
        const cz: i64 = self.along(p, 2);
        const widest: i64 = @intCast(@max(self.size[0], @max(self.size[1], self.size[2])));
        var best: usize = 0;
        var best_squared: f32 = 1.0e30;
        var ring: i64 = 0;
        while (ring <= widest) : (ring += 1) {
            var dx: i64 = -ring;
            while (dx <= ring) : (dx += 1) {
                var dy: i64 = -ring;
                while (dy <= ring) : (dy += 1) {
                    var dz: i64 = -ring;
                    while (dz <= ring) : (dz += 1) {
                        // Only this shell - everything inside it was searched on an earlier ring.
                        if (@max(magnitude(dx), @max(magnitude(dy), magnitude(dz))) != ring) {
                            continue;
                        }
                        const x: i64 = cx + dx;
                        const y: i64 = cy + dy;
                        const z: i64 = cz + dz;
                        const outside: bool = x < 0 or y < 0 or z < 0 or x >= self.size[0] or
                            y >= self.size[1] or z >= self.size[2];
                        if (outside) {
                            continue;
                        }
                        const k: usize = self.index(x, y, z);
                        for (self.order[self.first[k]..self.first[k + 1]]) |v| {
                            const d: Vec = self.positions[v] - p;
                            const squared: f32 = dot3(d, d);
                            if (squared < best_squared) {
                                best_squared = squared;
                                best = v;
                            }
                        }
                    }
                }
            }
            const reach: f32 = float(ring) * self.cell;
            if (best_squared <= reach * reach) {
                break;
            }
        }
        return best;
    }

    fn magnitude(v: i64) i64 {
        return if (v < 0) -v else v;
    }
};

/// The body's volume, sampled and shared out: one `Share` per mesh joint, and how cleanly it went.
pub const BodyVolume = struct {
    /// Indexed like the mesh's joints.
    shares: []Share,
    /// How many columns met the skin at all, and how many met it an ODD number of times. A closed skin
    /// is always crossed an even number of times - in, out, in, out - so an odd count marks a hole or a
    /// seam there, and its last crossing is dropped rather than guessed at.
    columns_hit: usize,
    odd_columns: usize,

    pub fn deinit(self: *BodyVolume, gpa: Allocator) void {
        gpa.free(self.shares);
    }

    /// Everything, as one share: the whole body.
    pub fn whole(self: BodyVolume) Share {
        var all: Share = .{};
        for (self.shares) |share| {
            all.merge(share);
        }
        return all;
    }
};

// -------- R5b: cutting the mass at the joints --------
//
// The skin weights say which bone each bit of flesh MOVES with, and near a joint that answer is a blend:
// a vertex that is half foot and half shin goes wherever its larger half does. The anthropometry tables -
// and every rigid-body model of a person built from them - cut differently, at planes through the joint
// centres. Measured (R5), the two agree everywhere except the shoulder, where the skin weights give the
// arm the whole cap of the shoulder, and the ankle, where they give the foot the ankle's flesh: the upper
// arm and the foot came out 31 % and 37 % heavier than the nearer table. So for MASS the body is cut the
// tables' way (D21). The collision shapes keep the skin weights - for them, "what moves with the bone" is
// exactly the right question.

/// The robot's bodies: EVERY bone of Geno's that the captures turn, so that copying a capture onto the
/// robot stays a copy (Simon: retargeting must not lose quality). Only the fingers and the leaf "End"
/// joints are left out - the captures never turn a finger, and an end joint turns nothing below it.
///
/// Collision shapes are a separate matter: a body may have none. The clavicles (`LeftShoulder`,
/// `RightShoulder`) and `Neck1` are full bodies with ball joints and their own share of the mass, but
/// carry no shape - their round pills looked wrong and cost collisions, and the chest and the slim neck
/// capsule cover them.
pub const body_names = [_][]const u8{
    "Hips",        "Spine",     "Spine1",        "Spine2",       "Spine3",
    "Neck",        "Neck1",     "Head",          "LeftShoulder", "LeftArm",
    "LeftForeArm", "LeftHand",  "RightShoulder", "RightArm",     "RightForeArm",
    "RightHand",   "LeftUpLeg", "LeftLeg",       "LeftFoot",     "LeftToeBase",
    "RightUpLeg",  "RightLeg",  "RightFoot",     "RightToeBase",
};

/// The bodies that make up the trunk. Its long axis stands upright in the rest pose, which is what a
/// limb joining it is cut square to.
const trunk_names = [_][]const u8{ "Hips", "Spine", "Spine1", "Spine2", "Spine3", "LeftShoulder", "RightShoulder" };

fn isTrunk(name: []const u8) bool {
    for (trunk_names) |trunk| {
        if (std.mem.eql(u8, trunk, name)) {
            return true;
        }
    }
    return false;
}

fn isBody(name: []const u8) bool {
    for (body_names) |body| {
        if (std.mem.eql(u8, body, name)) {
            return true;
        }
    }
    return false;
}

/// Where a body points when no body hangs off it to say so: the hand at its middle finger, the head at
/// the top of the skull, the toes at their tips.
fn tipOf(name: []const u8) ?[]const u8 {
    const tips = [_][2][]const u8{
        .{ "LeftHand", "LeftHandMiddle1" },
        .{ "RightHand", "RightHandMiddle1" },
        .{ "Head", "HeadEnd" },
        .{ "LeftToeBase", "LeftToeBaseEnd" },
        .{ "RightToeBase", "RightToeBaseEnd" },
    };
    for (tips) |pair| {
        if (std.mem.eql(u8, pair[0], name)) {
            return pair[1];
        }
    }
    return null;
}

/// How the sampled volume is shared out between the bones.
pub const Partition = enum {
    /// By the skin weights alone: each sample goes to whichever joint owns the nearest skin vertex. Every
    /// mesh joint gets its own share - fingers and helper joints included.
    skin_weights,
    /// By the skin weights, then settled at every joint by a plane through the joint centre, and summed
    /// per BODY (`body_names`). The plane follows the anthropometry tables' own convention: it is
    /// perpendicular to the PROXIMAL segment's long axis. Along a limb that is the limb itself (the knee
    /// is cut square to the thigh, the ankle square to the shank - so the heel stays with the foot). Where
    /// a limb meets the TRUNK - the shoulder, the hip, the neck - the proximal axis is the trunk's, which
    /// stands upright, so the cut is level: the cap of the shoulder above the joint centre is trunk.
    ///
    /// (Tried first and measured worse: the MITRE between the two segments. At the shoulder it is nearly
    /// vertical, and handed the arm everything outboard of the joint - clavicle flesh included.)
    joint_planes,
};

/// The bodies and the planes between them, worked out once from the mesh's own bind skeleton (which the
/// R3 test shows sits on our kinematics to a fraction of a micrometre).
const Bodies = struct {
    /// For every mesh joint: the mesh joint of the body it belongs to - itself, for a body.
    body_of: []usize,
    /// For every body: its parent body (the root's is itself). Unused for other joints.
    parent: []usize,
    /// For every body: the normal of the plane through its joint, pointing INTO the body.
    normal: []Vec,

    fn init(gpa: Allocator, mesh: Mesh) !Bodies {
        const n: usize = mesh.joint_names.len;
        const body_of: []usize = try gpa.alloc(usize, n);
        errdefer gpa.free(body_of);
        const parent: []usize = try gpa.alloc(usize, n);
        errdefer gpa.free(parent);
        const normal: []Vec = try gpa.alloc(Vec, n);
        errdefer gpa.free(normal);

        // Every joint rides the first body at or above it.
        for (0..n) |j| {
            var at: i32 = @intCast(j);
            while (at >= 0 and !isBody(mesh.joint_names[@intCast(at)])) {
                at = mesh.joint_parents[@intCast(at)];
            }
            assertf(at >= 0, @src(), "joint {s} hangs from no body", .{mesh.joint_names[j]});
            body_of[j] = @intCast(at);
        }
        for (0..n) |j| {
            const up: i32 = mesh.joint_parents[j];
            parent[j] = if (up < 0 or !isBody(mesh.joint_names[j])) j else body_of[@intCast(up)];
            normal[j] = vec(0, 1, 0);
        }

        // The plane at each body's joint is square to the PROXIMAL segment's long axis - the direction
        // the parent ARRIVES at this joint along, or upright where the parent is the trunk - and faces
        // the way this body LEAVES: toward the middle of the bodies hanging off it, or its tip.
        for (0..n) |j| {
            if (parent[j] == j) {
                continue;
            }
            const here: Vec = mesh.joint_bind_positions[j];
            var ahead: Vec = vec(0, 0, 0);
            var children: f32 = 0.0;
            for (0..n) |k| {
                if (k != j and parent[k] == j) {
                    ahead += mesh.joint_bind_positions[k];
                    children += 1.0;
                }
            }
            if (children > 0.0) {
                ahead = ahead / splat(children);
            } else {
                const tip: []const u8 = tipOf(mesh.joint_names[j]) orelse return error.BodyWithoutTip;
                ahead = mesh.joint_bind_positions[mesh.joint(tip) orelse return error.NoTipJoint];
            }
            const leaving: Vec = normalize3(ahead - here);
            const axis: Vec = if (isTrunk(mesh.joint_names[parent[j]]))
                vec(0, 1, 0)
            else
                normalize3(here - mesh.joint_bind_positions[parent[j]]);
            // Square to the axis, facing into this body: flip the axis if the body leaves against it.
            normal[j] = if (dot3(axis, leaving) >= 0.0) axis else -axis;
        }
        return .{ .body_of = body_of, .parent = parent, .normal = normal };
    }

    fn deinit(self: *Bodies, gpa: Allocator) void {
        gpa.free(self.normal);
        gpa.free(self.parent);
        gpa.free(self.body_of);
    }

    /// Where a sample at `p`, which the skin gives to `body`, belongs once the planes are drawn: behind
    /// its own body's plane it is the parent's, and past a child's plane it is that child's. Only the two
    /// bodies meeting at a joint ever trade flesh there - the chest never loses anything to an elbow.
    fn settle(self: Bodies, mesh: Mesh, body: usize, p: Vec) usize {
        const up: usize = self.parent[body];
        if (up != body and dot3(p - mesh.joint_bind_positions[body], self.normal[body]) < 0.0) {
            return up;
        }
        for (self.parent, 0..) |its_parent, child| {
            if (child != body and its_parent == body) {
                if (dot3(p - mesh.joint_bind_positions[child], self.normal[child]) > 0.0) {
                    return child;
                }
            }
        }
        return body;
    }
};

/// R5: measure the volume inside the mesh, and share it between the joints whose flesh it is.
///
/// HOW. Vertical rays, one up each column of a grid laid across the floor `step` apart. Where a ray
/// meets the skin is found triangle by triangle (each triangle only visits the columns under its own
/// footprint), the crossings are sorted up each column, and they pair off - in, out, in, out - into
/// the stretches of the column that lie inside the body. That is EXACT up the column, a midpoint rule
/// across it, and indifferent to which way the triangles wind: only the count of crossings matters.
///
/// Each stretch is then walked in steps of `step`, and every step - a little upright box - goes to the
/// joint that owns the NEAREST VERTEX of the skin: the skin weights' own answer to "whose flesh is
/// this", the same rule the collision shapes were fitted with, carried inward from the surface. With
/// `.joint_planes` it is then settled at the joint planes and summed per body (see `Partition`).
///
/// The column grid is nudged by odd fractions of a step, different in x and z, so no column runs
/// exactly through a vertex or along an edge - there, two triangles would both report one crossing, and
/// the in/out pairing would break.
pub fn measureVolume(
    gpa: Allocator,
    mesh: Mesh,
    step: f32,
    partition: Partition,
) !BodyVolume {
    assertf(step > 0.0, @src(), "measureVolume: a step of {d}", .{step});
    var bodies: ?Bodies = if (partition == .joint_planes) try Bodies.init(gpa, mesh) else null;
    defer if (bodies) |*b| b.deinit(gpa);
    var low: Vec = mesh.positions[0];
    var high: Vec = mesh.positions[0];
    for (mesh.positions) |p| {
        low = @min(low, p);
        high = @max(high, p);
    }
    const nudge_x: f32 = 0.0123 * step;
    const nudge_z: f32 = 0.0371 * step;
    const wide: usize = int(usize, (high[0] - low[0]) / step) + 2;
    const deep: usize = int(usize, (high[2] - low[2]) / step) + 2;
    const Crossing = struct {
        column: u32,
        y: f32,

        fn before(_: void, a: @This(), b: @This()) bool {
            return a.column < b.column or (a.column == b.column and a.y < b.y);
        }
    };

    // Every place a column crosses the skin.
    var crossings: ArrayList(Crossing) = .empty;
    defer crossings.deinit(gpa);
    for (mesh.triangles) |triangle| {
        const a: Vec = mesh.positions[triangle[0]];
        const b: Vec = mesh.positions[triangle[1]];
        const c: Vec = mesh.positions[triangle[2]];
        // The triangle seen from above. A wall-on triangle has no footprint and no crossing.
        const denominator: f32 = (b[2] - c[2]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[2] - c[2]);
        if (@abs(denominator) < 1.0e-12) {
            continue;
        }
        const from_x: f32 = (@min(a[0], @min(b[0], c[0])) - low[0] - nudge_x) / step - 0.5;
        const to_x: f32 = (@max(a[0], @max(b[0], c[0])) - low[0] - nudge_x) / step - 0.5;
        const from_z: f32 = (@min(a[2], @min(b[2], c[2])) - low[2] - nudge_z) / step - 0.5;
        const to_z: f32 = (@max(a[2], @max(b[2], c[2])) - low[2] - nudge_z) / step - 0.5;
        const first_x: usize = if (from_x <= 0.0) 0 else int(usize, from_x);
        const first_z: usize = if (from_z <= 0.0) 0 else int(usize, from_z);
        const last_x: usize = if (to_x <= 0.0) 0 else @min(int(usize, to_x) + 1, wide - 1);
        const last_z: usize = if (to_z <= 0.0) 0 else @min(int(usize, to_z) + 1, deep - 1);
        for (first_x..last_x + 1) |ix| {
            const x: f32 = low[0] + (float(ix) + 0.5) * step + nudge_x;
            for (first_z..last_z + 1) |iz| {
                const z: f32 = low[2] + (float(iz) + 0.5) * step + nudge_z;
                // Barycentric weights of the column's point in the footprint; all three non-negative
                // means the column passes through this triangle, at the height they interpolate.
                const wa: f32 = ((b[2] - c[2]) * (x - c[0]) + (c[0] - b[0]) * (z - c[2])) / denominator;
                const wb: f32 = ((c[2] - a[2]) * (x - c[0]) + (a[0] - c[0]) * (z - c[2])) / denominator;
                const wc: f32 = 1.0 - wa - wb;
                if (wa >= 0.0 and wb >= 0.0 and wc >= 0.0) {
                    try crossings.append(gpa, .{
                        .column = @intCast(ix * deep + iz),
                        .y = wa * a[1] + wb * b[1] + wc * c[1],
                    });
                }
            }
        }
    }
    std.mem.sort(Crossing, crossings.items, {}, Crossing.before);

    var nearest: Nearest = try Nearest.init(gpa, mesh.positions, 0.03);
    defer nearest.deinit(gpa);
    const shares: []Share = try gpa.alloc(Share, mesh.joint_names.len);
    errdefer gpa.free(shares);
    @memset(shares, .{});

    const items: []const Crossing = crossings.items;
    var columns_hit: usize = 0;
    var odd_columns: usize = 0;
    var start: usize = 0;
    while (start < items.len) {
        var end: usize = start;
        while (end < items.len and items[end].column == items[start].column) {
            end += 1;
        }
        const run: []const Crossing = items[start..end];
        columns_hit += 1;
        if (run.len % 2 == 1) {
            odd_columns += 1;
        }
        const ix: usize = run[0].column / deep;
        const iz: usize = run[0].column % deep;
        const x: f32 = low[0] + (float(ix) + 0.5) * step + nudge_x;
        const z: f32 = low[2] + (float(iz) + 0.5) * step + nudge_z;
        // In, out; in, out. An odd last crossing has no partner and is left alone.
        var pair: usize = 0;
        while (pair + 1 < run.len) : (pair += 2) {
            const top: f32 = run[pair + 1].y;
            var y: f32 = run[pair].y;
            while (y < top) {
                const next: f32 = @min(y + step, top);
                const at: Vec = vec(x, 0.5 * (y + next), z);
                // Whose flesh (the skin's answer), then - if cutting at the joints - whose body.
                const owner: usize = mesh.owner(nearest.find(at));
                const holder: usize = if (bodies) |b| b.settle(mesh, b.body_of[owner], at) else owner;
                shares[holder].addBox(at, .{ step, next - y, step });
                y = next;
            }
        }
        start = end;
    }
    return .{ .shares = shares, .columns_hit = columns_hit, .odd_columns = odd_columns };
}

// -------- R6: joint ranges, from what the captures actually do --------
//
// A joint limit is a claim about the body: this far, and no further. Guessed, it is either too tight -
// the robot cannot reach a pose its captures ask for, and the tracker spends itself fighting a wall - or
// too loose, and a policy discovers that a knee can fold backwards. Measured, it is exactly what the
// captures USE, with the rare extreme named instead of quietly allowed.

/// How far one joint turns across a library of captures, measured away from the rest pose (R2).
///
/// Three measures, because the robot's joint types are still being chosen (D18):
///   - the TOTAL turn: what a ball joint's single limit bounds;
///   - the SWING: how far the bone's DIRECTION moves from where it points at rest - for a knee or an
///     elbow, its bend;
///   - the TWIST: the signed turn about the bone itself - which a hinge cannot make at all, so a narrow
///     twist band is the evidence that a hinge would do.
/// Every limit holds 99.5 % of the frames (the twist's two tails together). What lies beyond is the
/// joint's tail, and `excess` says how far it reaches past the limit.
pub const Range = struct {
    /// The body this joint moves (`body_names`).
    name: []const u8,
    frames: usize,
    total_limit: f32,
    total_max: f32,
    swing_limit: f32,
    swing_max: f32,
    twist_low: f32,
    twist_high: f32,
    twist_min: f32,
    twist_max: f32,

    /// How far the furthest frame goes past this joint's limits, in degrees.
    pub fn excess(self: Range) f32 {
        const total: f32 = self.total_max - self.total_limit;
        const swing: f32 = self.swing_max - self.swing_limit;
        const twist: f32 = @max(self.twist_low - self.twist_min, self.twist_max - self.twist_high);
        return @max(total, @max(swing, twist));
    }
};

/// A rotation's swing and twist, in degrees (see `swingTwist`).
const SwingTwist = struct {
    /// How far the axis itself is carried off, never negative.
    swing: f32,
    /// The signed turn about the axis, in (-180, 180].
    twist: f32,
};

/// A rotation split into the TWIST about `axis` and the SWING that carries `axis` somewhere else
/// (rotation = swing * twist), each as an angle in degrees - the twist signed, the swing not.
///
/// The twist is the rotation's projection onto the axis: keep the part of its vector along the axis, and
/// its scalar, and renormalise. What is left once the twist is taken out is the swing.
fn swingTwist(q: Quat, axis: Vec) SwingTwist {
    const along: f32 = dot3(q, axis);
    const size: f32 = @sqrt(along * along + q[3] * q[3]);
    if (size < 1.0e-9) {
        // The axis is turned right round: a pure half-turn swing, and no twist to speak of.
        return .{ .swing = 180.0, .twist = 0.0 };
    }
    const twist: Quat = .{ axis[0] * along / size, axis[1] * along / size, axis[2] * along / size, q[3] / size };
    const swing: Quat = qmul(q, conjugate(twist));
    var twist_angle: f32 = degFromRad(2.0 * atan2Rad(along, q[3]));
    // A quaternion and its negative are one rotation; fold the twist into (-180, 180].
    if (twist_angle > 180.0) {
        twist_angle -= 360.0;
    }
    if (twist_angle <= -180.0) {
        twist_angle += 360.0;
    }
    return .{ .swing = degFromRad(2.0 * atan2Rad(length3(swing), @abs(swing[3]))), .twist = twist_angle };
}

/// The value below which a fraction `p` of `sorted` lies.
fn percentile(sorted: []const f32, p: f32) f32 {
    const at: usize = @trunc(p * float(sorted.len - 1) + 0.5);
    return sorted[@min(at, sorted.len - 1)];
}

/// The nearest body at or above bone `i` of a pose's skeleton, or null for none.
fn bodyAbove(pose: Posed, i: usize) ?usize {
    var at: i32 = @intCast(i);
    while (at >= 0) : (at = pose.bones[@intCast(at)].parent) {
        if (isBody(pose.bones[@intCast(at)].name)) {
            return @intCast(at);
        }
    }
    return null;
}

/// R6: measure every joint's range over a library of captures, all on Geno's skeleton.
///
/// Every body but the root (a free joint has no range) is measured as the robot will move it: its
/// rotation away from rest, `jointFromLocal(rest, pose)` (R2). Should a skeleton joint ever sit BETWEEN
/// two bodies without being one, its rotation is carried by the body below it: both the rest and the
/// pose rotations of a body are taken as the product down the chain from just below its parent body to
/// itself. (Today every turned bone is a body, so every chain is one bone long.) The swing and twist are
/// measured about the bone as it lies in its own rest frame, pointing at the bodies it carries (or at its
/// tip - the middle finger, the top of the skull, the end of the toes).
///
/// The caller owns the returned slice. Names point into `body_names`.
pub fn measureRanges(gpa: Allocator, rest: Posed, captures: []const []const u8) ![]Range {
    assertf(std.mem.eql(u8, body_names[0], "Hips"), @src(), "measureRanges: the root must come first", .{});
    const measured: []const []const u8 = body_names[1..];
    const count: usize = measured.len;

    // In the rest pose, for each joint: its chain of skeleton bones, the chain's rest turn, and its bone
    // axis in its own rest frame.
    const chains: [][]usize = try gpa.alloc([]usize, count);
    defer gpa.free(chains);
    var chained: usize = 0;
    defer for (chains[0..chained]) |chain| {
        gpa.free(chain);
    };
    const rest_turns: []Quat = try gpa.alloc(Quat, count);
    defer gpa.free(rest_turns);
    const axes: []Vec = try gpa.alloc(Vec, count);
    defer gpa.free(axes);
    for (measured, 0..) |name, m| {
        const bone: usize = rest.find(name) orelse return error.BodyNotInSkeleton;
        // The chain, from the body upward to just below its parent body.
        var up_to: usize = 0;
        var walk: i32 = @intCast(bone);
        while (walk >= 0) : (walk = rest.bones[@intCast(walk)].parent) {
            if (walk != bone and isBody(rest.bones[@intCast(walk)].name)) {
                break;
            }
            up_to += 1;
        }
        const chain: []usize = try gpa.alloc(usize, up_to);
        chains[m] = chain;
        chained += 1;
        // Filled from the top down, so that the rotations compose parent first.
        walk = @intCast(bone);
        var slot: usize = up_to;
        while (slot > 0) : (walk = rest.bones[@intCast(walk)].parent) {
            slot -= 1;
            chain[slot] = @intCast(walk);
        }
        var turn: Quat = qidentity();
        for (chain) |k| {
            turn = qmul(turn, rest.locals[k]);
        }
        rest_turns[m] = turn;

        // Where the bone points: the middle of the bodies it carries, or its tip.
        var ahead: Vec = vec(0, 0, 0);
        var carried: f32 = 0.0;
        for (rest.bones, 0..) |other, k| {
            if (k != bone and isBody(other.name) and other.parent >= 0) {
                const above: ?usize = bodyAbove(rest, @intCast(other.parent));
                if (above != null and above.? == bone) {
                    ahead += rest.positions[k];
                    carried += 1.0;
                }
            }
        }
        if (carried > 0.0) {
            ahead = ahead / splat(carried);
        } else {
            const tip: []const u8 = tipOf(name) orelse return error.BodyWithoutTip;
            ahead = rest.at(tip) orelse return error.NoTipBone;
        }
        axes[m] = rotate(conjugate(rest.rotations[bone]), normalize3(ahead - rest.positions[bone]));
    }

    // Every frame of every capture: the three angles, per joint.
    var totals: []ArrayList(f32) = try gpa.alloc(ArrayList(f32), count);
    defer gpa.free(totals);
    var swings: []ArrayList(f32) = try gpa.alloc(ArrayList(f32), count);
    defer gpa.free(swings);
    var twists: []ArrayList(f32) = try gpa.alloc(ArrayList(f32), count);
    defer gpa.free(twists);
    for (0..count) |m| {
        totals[m] = .empty;
        swings[m] = .empty;
        twists[m] = .empty;
    }
    defer for (0..count) |m| {
        totals[m].deinit(gpa);
        swings[m].deinit(gpa);
        twists[m].deinit(gpa);
    };
    for (captures) |bytes| {
        var data: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
        defer data.deinit();
        // Each chain's bones, found by name in this capture's own skeleton.
        const lookup: [][]usize = try gpa.alloc([]usize, count);
        defer gpa.free(lookup);
        var looked: usize = 0;
        defer for (lookup[0..looked]) |found| {
            gpa.free(found);
        };
        for (chains, 0..) |chain, m| {
            const found: []usize = try gpa.alloc(usize, chain.len);
            lookup[m] = found;
            looked += 1;
            for (chain, 0..) |k, c| {
                found[c] = for (data.joints, 0..) |joint, j| {
                    if (std.mem.eql(u8, joint.name, rest.bones[k].name)) {
                        break j;
                    }
                } else return error.CaptureMissesJoint;
            }
        }
        const locals: []Quat = try gpa.alloc(Quat, data.joints.len);
        defer gpa.free(locals);
        for (0..data.frame_count) |f| {
            const frame: []const f32 = data.frame(f);
            var taken: usize = 0;
            for (data.joints, 0..) |joint, j| {
                var place: Vec = vec(0, 0, 0);
                var turn: Quat = qidentity();
                for (joint.channels) |channel| {
                    applyChannel(channel, frame[taken], &place, &turn);
                    taken += 1;
                }
                locals[j] = turn;
            }
            for (lookup, 0..) |found, m| {
                var pose: Quat = qidentity();
                for (found) |j| {
                    pose = qmul(pose, locals[j]);
                }
                const joint: Quat = jointFromLocal(rest_turns[m], pose);
                const split: SwingTwist = swingTwist(joint, axes[m]);
                try totals[m].append(gpa, degFromRad(2.0 * atan2Rad(length3(joint), @abs(joint[3]))));
                try swings[m].append(gpa, split.swing);
                try twists[m].append(gpa, split.twist);
            }
        }
    }

    const ranges: []Range = try gpa.alloc(Range, count);
    for (measured, 0..) |name, m| {
        const total: []f32 = totals[m].items;
        const swing: []f32 = swings[m].items;
        const twist: []f32 = twists[m].items;
        std.mem.sort(f32, total, {}, std.sort.asc(f32));
        std.mem.sort(f32, swing, {}, std.sort.asc(f32));
        std.mem.sort(f32, twist, {}, std.sort.asc(f32));
        ranges[m] = .{
            .name = name,
            .frames = total.len,
            .total_limit = percentile(total, 0.995),
            .total_max = total[total.len - 1],
            .swing_limit = percentile(swing, 0.995),
            .swing_max = swing[swing.len - 1],
            .twist_low = percentile(twist, 0.0025),
            .twist_high = percentile(twist, 0.9975),
            .twist_min = twist[0],
            .twist_max = twist[twist.len - 1],
        };
    }
    return ranges;
}

// -------- R6b: the model, assembled --------

/// The one turn between Geno's world and the engine's. Geno's files are y-up; the engine's robots are
/// z-up (MuJoCo's convention - gravity along -z). A quarter turn about x takes one to the other:
/// (x, y, z) goes to (x, -z, y).
pub const y_up_to_z_up: Quat = .{ 0.70710678, 0.0, 0.0, 0.70710678 };

/// How far past the library's largest turn a joint may go. R6 found the 99.5 % limits too tight - most
/// joints' rarest frames pass them by 2 to 10 degrees - so a limit is the whole library's maximum plus
/// this, and every captured frame is reachable.
pub const range_margin_deg: f32 = 5.0;

const ModelError = error{ OutOfMemory, BodyNotInMesh, BodyWithoutRange };

/// Every ball joint's ARMATURE - rotor inertia on the joint's own degrees of freedom - and DAMPING: the old
/// robot's own defaults, and MuJoCo's standard remedy for light links (hands, toes, the neck bones, the
/// clavicles) stepped at 60 Hz against a stiff floor. Armature adds inertia to a joint's motion alone, so
/// the body's measured masses are untouched. (No passive STIFFNESS, which the old robot also had: it would
/// pull every joint toward the bind pose and bias every pose Geno holds.)
pub const joint_armature: f32 = 0.01;
/// The floor's friction. A contact's friction is the geometric mean of the two surfaces' - Geno's shapes
/// carry MJCF's 1.0 - so the floor's own number sets how well the feet grip. Measured on the held stand:
/// at the collision world's default (0.5, so 0.71 combined) a foot SKATED 28 cm in 2 s while the robot only
/// tried to stand; at 4.0 (2.0 combined), 5 cm. 2.0 (1.41 combined) is a grippy shoe on a floor. (The servo-
/// only get-up scores lower with grip - 2.60 s against 3.02 - because sliding had let the body follow a
/// reference that sinks into the floor while lying down: a score that rewarded skating.)
pub const floor_friction: f32 = 2.0;

/// DReCon's choice of bodies, in Geno's names - the same anatomy the old robot's policy used: the feet, the
/// chest, the head and the forearms WATCHED; the spine above the pelvis, the legs and the upper arms
/// ACTUATED, elbows and toes left to the reference. Geno's root is its hips, so the old robot's "pelvis"
/// joint is Geno's first spine joint. Ten actuated ball joints: 30 of the robot's 69 action dimensions.
pub const drecon_watched = [_][]const u8{
    "LeftToeBase", "RightToeBase", "Spine3", "Head", "LeftForeArm", "RightForeArm",
};
pub const drecon_actuated = [_][]const u8{
    "Spine",      "Spine1",   "LeftUpLeg", "LeftLeg", "LeftFoot",
    "RightUpLeg", "RightLeg", "RightFoot", "LeftArm", "RightArm",
};

/// The armature that lets Geno STAND (S2c): in the task's servo a joint's strength is its free-flight inertia,
/// and 2 on every joint makes each as strong standing as the load it carries needs. With the capture-point
/// reflex it holds the T-pose the full 10 s; it costs the dance nothing (1.26 s against 1.24 for the servo).
pub const standing_armature: f32 = 2.0;

/// THE CAPTURE-POINT REFLEX (S2c), shared by `ServoRun` and the page: lean the body back through the ankles'
/// targets when its capture point drifts ahead of the feet. Treat the body as an inverted pendulum on its
/// feet: its capture point, `com + velocity / omega` with `omega = sqrt(g / height)`, is where the centre of
/// mass would come to rest if the feet were put there. A foot held flat by the floor, turned +d against its
/// shin, tips everything above it by -d - and -d about the sideways axis x is BACKWARD here, since Geno faces
/// -y in the engine's z-up world. Fore and aft only for now: the T-pose falls forward.
pub const Reflex = struct {
    /// The feet's bodies, where their ball joints keep their quaternions, and the root whose subtree's
    /// centre of mass is the whole body's.
    feet: [2]u32,
    foot_adr: [2]usize,
    root: u32,
    /// The centre of mass one frame ago, for its velocity.
    com_before: Vec = .{ 0, 0, 0, 0 },
    have_com: bool = false,

    pub fn init(imported: *const robot_mjcf.Imported, root: u32) !Reflex {
        const m: *const rbt.Model = &imported.model;
        var reflex: Reflex = .{ .feet = undefined, .foot_adr = undefined, .root = root };
        for ([_][]const u8{ "LeftFoot", "RightFoot" }, 0..) |name, k| {
            reflex.feet[k] = imported.bodyIndex(name) orelse return error.NoFoot;
            const joint: usize = for (m.jnt_body, 0..) |owner, j| {
                if (owner == reflex.feet[k]) {
                    break j;
                }
            } else return error.FootWithoutJoint;
            reflex.foot_adr[k] = m.jnt_qpos_adr[joint];
        }
        return reflex;
    }

    /// Forget the last frame: after any jump, the next velocity would be the jump's.
    pub fn forget(self: *Reflex) void {
        self.have_com = false;
    }

    /// `target` with the lean in its ankles, written into `goal` - `gain` radians per metre of capture point
    /// ahead of the feet, clamped to 0.35 rad (about 20 degrees).
    pub fn apply(
        self: *Reflex,
        d: *const rbt.Data,
        gain: f32,
        frame_time: f32,
        target: []const f32,
        goal: []f32,
    ) void {
        const com: Vec = d.subtree_com[self.root];
        const velocity: Vec = if (self.have_com) (com - self.com_before) / splat(frame_time) else vec(0, 0, 0);
        self.com_before = com;
        self.have_com = true;
        const support: Vec = (d.body_xpos[self.feet[0]] + d.body_xpos[self.feet[1]]) * splat(0.5);
        const omega: f32 = @sqrt(9.81 / @max(com[2], 0.3));
        const capture: Vec = com + velocity / splat(omega);
        const ahead: f32 = support[1] - capture[1];
        const lean: f32 = clamp(gain * ahead, -0.35, 0.35);
        @memcpy(goal, target);
        const turn: Quat = quatFromAxisAngle(vec(1, 0, 0), lean);
        for (self.feet, self.foot_adr) |foot, adr| {
            // The turn about the world's x, carried into the ankle joint's own frame (w last: R7).
            const world: Quat = d.body_xrot[foot];
            const local: Quat = qmul(qmul(conjugate(world), turn), world);
            const q: []f32 = goal[adr..][0..4];
            const bent: Quat = qmul(.{ q[0], q[1], q[2], q[3] }, local);
            q[0] = bent[0];
            q[1] = bent[1];
            q[2] = bent[2];
            q[3] = bent[3];
        }
    }
};

/// The servo's spring for Geno: the task's defaults - a critically damped 20 Hz spring - with ONE change,
/// chosen by the tuning sweep over the get-up (the "S1 tuning sweep" test): the acceleration cap raised from
/// 400 to 3000 rad/s^2. The cap was clipping the servo's authority exactly when the body needed it: mean
/// time to failure on the get-up 2.61 -> 3.02 s. (Higher caps change nothing - it stops binding near 3000;
/// heavier armature and damping, alone or combined, did not beat it.)
pub const servo_gains: robot_track.Gains = .{ .max_acceleration = 3000.0 };
pub const joint_damping: f32 = 0.2;

/// Which body carries a fitted shape. Every shape rides its own bone - except the neck's, which rides
/// Neck1: the shapes are designed to OVERLAP at every joint (so a joint reads as connected), and the
/// engine, like MuJoCo, only spares ADJACENT bodies from colliding. With Neck1 a body again (the copy
/// must stay exact), the neck capsule on Neck would sit two joints from the head it overlaps by 9.5 cm -
/// and that overlap, collided, threw the standing robot through the floor. On Neck1 it is adjacent to the
/// head. The chest's own overlaps across shapeless bodies - with the neck, and with the upper arms across
/// the clavicles - are named in the model's contact exclusions instead (`writeExclusions`).
pub fn carrierOf(bone: []const u8) []const u8 {
    return if (std.mem.eql(u8, bone, "Neck")) "Neck1" else bone;
}

/// Writes the body tree, one body at a time, depth first.
const ModelWriter = struct {
    gpa: Allocator,
    text: *ArrayList(u8),
    rest: Posed,
    mesh: Mesh,
    masses: BodyVolume,
    ranges: []const Range,

    fn body(
        self: ModelWriter,
        bone: usize,
        parent: ?usize,
        depth: usize,
    ) ModelError!void {
        const name: []const u8 = self.rest.bones[bone].name;
        const here: Vec = self.rest.positions[bone];
        const turn: Quat = self.rest.rotations[bone];

        // Where the body sits, and how it is turned, in its parent body's frame - both straight from the
        // bind pose. The root alone is placed in the world, and only it meets the z-up turn.
        var place: Vec = undefined;
        var facing: Quat = undefined;
        if (parent) |up| {
            const back: Quat = conjugate(self.rest.rotations[up]);
            place = rotate(back, here - self.rest.positions[up]);
            facing = qmul(back, turn);
        } else {
            place = rotate(y_up_to_z_up, here);
            facing = qmul(y_up_to_z_up, turn);
        }
        try self.indent(depth);
        // MJCF writes a quaternion scalar-first: w x y z.
        try self.text.print(self.gpa, "<body name=\"{s}\" pos=\"{d:.6} {d:.6} {d:.6}\" " ++
            "quat=\"{d:.7} {d:.7} {d:.7} {d:.7}\">\n", .{
            name, place[0], place[1], place[2], facing[3], facing[0], facing[1], facing[2],
        });

        // The joint: free at the root, a ball everywhere else, limited by the library's largest turn.
        try self.indent(depth + 1);
        if (parent == null) {
            try self.text.appendSlice(self.gpa, "<freejoint/>\n");
        } else {
            const range: Range = for (self.ranges) |r| {
                if (std.mem.eql(u8, r.name, name)) {
                    break r;
                }
            } else return error.BodyWithoutRange;
            try self.text.print(self.gpa, "<joint name=\"{s}\" type=\"ball\" range=\"0 {d:.2}\" " ++
                "armature=\"{d}\" damping=\"{d}\"/>\n", .{
                name,
                @min(range.total_max + range_margin_deg, 180.0),
                joint_armature,
                joint_damping,
            });
        }

        // The body's own mass (R5, cut at the joints: R5b), its centre and inertia moved into its frame.
        const share: Share = self.masses.shares[self.mesh.joint(name) orelse return error.BodyNotInMesh];
        const centre: Vec = rotate(conjugate(turn), share.centre() - here);
        const world: [3][3]f32 = share.inertia();
        // The body's axes, seen from the world; the tensor in the body's frame is I_ij = a_i . I a_j.
        var axes: [3][3]f32 = undefined;
        inline for (0..3) |i| {
            var unit: Vec = vec(0, 0, 0);
            unit[i] = 1.0;
            const a: Vec = rotate(turn, unit);
            axes[i] = .{ a[0], a[1], a[2] };
        }
        var local: [3][3]f32 = undefined;
        for (0..3) |i| {
            for (0..3) |j| {
                var sum: f32 = 0.0;
                for (0..3) |r| {
                    for (0..3) |c| {
                        sum += axes[i][r] * world[r][c] * axes[j][c];
                    }
                }
                local[i][j] = sum;
            }
        }
        try self.indent(depth + 1);
        // MJCF's full inertia order: Ixx Iyy Izz Ixy Ixz Iyz.
        try self.text.print(self.gpa, "<inertial pos=\"{d:.6} {d:.6} {d:.6}\" mass=\"{d:.5}\" " ++
            "fullinertia=\"{e:.6} {e:.6} {e:.6} {e:.6} {e:.6} {e:.6}\"/>\n", .{
            centre[0],   centre[1],   centre[2],   share.mass(),
            local[0][0], local[1][1], local[2][2], local[0][1],
            local[0][2], local[1][2],
        });

        // The body's collision shape (R4), carried into its frame. Massless: the body already weighs
        // what its flesh weighs (R5), and a shape - sized to meet the floor where the skin does - must not
        // add a second guess at it.
        for (shapes.geoms) |geom| {
            if (!std.mem.eql(u8, carrierOf(geom.bone), name)) {
                continue;
            }
            const back: Quat = conjugate(turn);
            try self.indent(depth + 1);
            switch (geom.shape) {
                .capsule => {
                    const a: Vec = rotate(back, vec(geom.a[0], geom.a[1], geom.a[2]) - here);
                    const b: Vec = rotate(back, vec(geom.b[0], geom.b[1], geom.b[2]) - here);
                    // A capsule whose ends meet IS a sphere - the pelvis is one: its section is no wider
                    // than it is deep, so the fit left it no length. MJCF's `fromto` needs a direction to
                    // point the capsule along, and a zero-length segment has none; a sphere needs none.
                    if (length3(b - a) < 1.0e-4) {
                        const middle: Vec = (a + b) * splat(0.5);
                        try self.text.print(self.gpa, "<geom name=\"{s}\" type=\"sphere\" " ++
                            "pos=\"{d:.6} {d:.6} {d:.6}\" size=\"{d:.6}\" mass=\"0\"/>\n", .{
                            name, middle[0], middle[1], middle[2], geom.radius,
                        });
                        continue;
                    }
                    try self.text.print(self.gpa, "<geom name=\"{s}\" type=\"capsule\" " ++
                        "fromto=\"{d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\" size=\"{d:.6}\" mass=\"0\"/>\n", .{
                        name, a[0], a[1], a[2], b[0], b[1], b[2], geom.radius,
                    });
                },
                .box => {
                    const box_centre: Vec = rotate(back, vec(geom.a[0], geom.a[1], geom.a[2]) - here);
                    const r: [4]f32 = geom.rotation;
                    const facing_box: Quat = qmul(back, .{ r[0], r[1], r[2], r[3] });
                    try self.text.print(self.gpa, "<geom name=\"{s}\" type=\"box\" pos=\"{d:.6} {d:.6} {d:.6}\" " ++
                        "quat=\"{d:.7} {d:.7} {d:.7} {d:.7}\" size=\"{d:.6} {d:.6} {d:.6}\" mass=\"0\"/>\n", .{
                        name,          box_centre[0], box_centre[1], box_centre[2],
                        facing_box[3], facing_box[0], facing_box[1], facing_box[2],
                        geom.half[0],  geom.half[1],  geom.half[2],
                    });
                },
            }
        }

        // The bodies hanging off this one: every body whose nearest body above is this.
        for (self.rest.bones, 0..) |other, k| {
            if (k != bone and isBody(other.name) and other.parent >= 0) {
                if (bodyAbove(self.rest, @intCast(other.parent))) |above| {
                    if (above == bone) {
                        try self.body(k, bone, depth + 1);
                    }
                }
            }
        }
        try self.indent(depth);
        try self.text.appendSlice(self.gpa, "</body>\n");
    }

    fn indent(self: ModelWriter, depth: usize) ModelError!void {
        try self.text.appendNTimes(self.gpa, ' ', 2 * depth);
    }
};

/// The closest distance between two segments (Ericson, Real-Time Collision Detection, 5.1.9). A sphere is
/// a segment of no length.
fn segmentGap(p1: Vec, q1: Vec, p2: Vec, q2: Vec) f32 {
    const d1: Vec = q1 - p1;
    const d2: Vec = q2 - p2;
    const r: Vec = p1 - p2;
    const a: f32 = dot3(d1, d1);
    const e: f32 = dot3(d2, d2);
    const f: f32 = dot3(d2, r);
    var s: f32 = 0.0;
    var t: f32 = 0.0;
    if (a <= 1.0e-12 and e <= 1.0e-12) {
        return length3(r);
    }
    if (a <= 1.0e-12) {
        t = clamp(f / e, 0.0, 1.0);
    } else {
        const c: f32 = dot3(d1, r);
        if (e <= 1.0e-12) {
            s = clamp(-c / a, 0.0, 1.0);
        } else {
            const b: f32 = dot3(d1, d2);
            const denominator: f32 = a * e - b * b;
            s = if (denominator > 1.0e-12) clamp((b * f - c * e) / denominator, 0.0, 1.0) else 0.0;
            t = (b * s + f) / e;
            if (t < 0.0) {
                t = 0.0;
                s = clamp(-c / a, 0.0, 1.0);
            } else if (t > 1.0) {
                t = 1.0;
                s = clamp((b - c) / a, 0.0, 1.0);
            }
        }
    }
    return length3((p1 + d1 * splat(s)) - (p2 + d2 * splat(t)));
}

/// SELF-COLLISION, OFF FOR NOW (Simon, Sep 24): the copied dance puts Geno's limbs inside each other - hand
/// into hand 62 mm, hand into forearm 57, spine into forearm 33 (the fitted shapes are fuller than the actor's
/// flesh) - and the solver throws them apart, a limb missing the next frame by up to 29 mm in one step. A
/// learner would be punished for overlaps no policy can undo. So the model excludes every pair of Geno's
/// bodies; set this back to `true` once training works, and it excludes only the pairs overlapping at rest.
pub const self_collision: bool = false;

/// SHAPES THAT OVERLAP AT REST NEVER COLLIDE. The shapes are designed to overlap - at every joint, so a
/// joint reads as connected, and down the torso, whose pills stack into one body. Shapes that already
/// overlap in the rest pose are one piece of the body, not two things colliding; left to collide, the
/// torso's pills - each overlapping the one TWO joints away, not just its neighbour - blow the spine apart
/// on the very first step. The engine spares adjacent bodies on its own; every other pair of shapes that
/// overlaps at rest is named here (MuJoCo's own practice). Capsules and the pelvis's sphere only: the
/// feet's and toes' boxes overlap nothing but their adjacent neighbours.
///
/// While `self_collision` is off, EVERY pair of shape-carrying bodies is excluded instead: Geno collides with
/// the floor and nothing else.
fn writeExclusions(gpa: Allocator, text: *ArrayList(u8)) !void {
    if (!self_collision) {
        // Each shape-carrying body once, in the table's order, then every pair of them.
        var carriers: [shapes.geoms.len][]const u8 = undefined;
        var count: usize = 0;
        for (shapes.geoms) |geom| {
            const body: []const u8 = carrierOf(geom.bone);
            const seen: bool = for (carriers[0..count]) |known| {
                if (std.mem.eql(u8, known, body)) {
                    break true;
                }
            } else false;
            if (!seen) {
                carriers[count] = body;
                count += 1;
            }
        }
        for (carriers[0..count], 0..) |first, i| {
            for (carriers[i + 1 .. count]) |second| {
                try text.print(gpa, "    <exclude body1=\"{s}\" body2=\"{s}\"/>\n", .{ first, second });
            }
        }
        return;
    }
    for (shapes.geoms, 0..) |first, i| {
        if (first.shape != .capsule) {
            continue;
        }
        for (shapes.geoms[i + 1 ..]) |second| {
            if (second.shape != .capsule) {
                continue;
            }
            const gap: f32 = segmentGap(
                vec(first.a[0], first.a[1], first.a[2]),
                vec(first.b[0], first.b[1], first.b[2]),
                vec(second.a[0], second.a[1], second.a[2]),
                vec(second.b[0], second.b[1], second.b[2]),
            );
            if (gap < first.radius + second.radius) {
                try text.print(gpa, "    <exclude body1=\"{s}\" body2=\"{s}\"/>\n", .{
                    carrierOf(first.bone),
                    carrierOf(second.bone),
                });
            }
        }
    }
}

/// R6b: write the robot as MJCF - the kinematic tree, its mass, its collision shapes and the floor.
/// The actuators and the standing guard follow.
///
/// How it is built - and why a capture will copy onto it exactly:
///   - **every body's frame IS its bone's frame in the rest pose** (R2): its `pos` and `quat` are the
///     bone's rest place and turn relative to its parent body, straight from the bind pose. With every
///     joint at zero the model stands in the bind pose - to the micrometre, which the R6b test checks
///     through the engine's own kinematics.
///   - **only the root meets the z-up turn.** Everything below it is relative, and relative numbers do
///     not care which way is up - so a capture's joint rotations (`jointFromLocal`) drive the model
///     exactly as they come, with no conversion anywhere.
///   - **every joint is a ball** (D18, from R6: the elbows twist across about 75 degrees and the right
///     knee 46 - a hinge would throw captured motion away), limited to the library's largest turn plus
///     `range_margin_deg`.
///   - **masses and inertias are the body's own** (R5, cut at the joints: R5b), as full tensors in each
///     body's frame.
///
/// Every bone the captures turn is a body (see `body_names`), so a capture copies onto it bone for bone.
/// (Folding Neck1 into the head was tried and measured: 12.9 mm off at the head. Not a copy.) The caller
/// owns the returned text.
pub fn writeModel(
    gpa: Allocator,
    rest: Posed,
    mesh: Mesh,
    masses: BodyVolume,
    ranges: []const Range,
) ![]u8 {
    var text: ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, "<mujoco model=\"geno\">\n  <compiler angle=\"degree\"/>\n  <worldbody>\n");
    // The floor: the z = 0 plane of the engine's z-up world, where Geno's y = 0 lands.
    try text.appendSlice(gpa, "    <geom name=\"floor\" type=\"plane\" size=\"20 20 0.1\"/>\n");
    const root: usize = rest.find(body_names[0]) orelse return error.NoRoot;
    const writer: ModelWriter = .{
        .gpa = gpa,
        .text = &text,
        .rest = rest,
        .mesh = mesh,
        .masses = masses,
        .ranges = ranges,
    };
    try writer.body(root, null, 2);
    try text.appendSlice(gpa, "  </worldbody>\n  <contact>\n");
    try writeExclusions(gpa, &text);
    try text.appendSlice(gpa, "  </contact>\n</mujoco>\n");
    return text.toOwnedSlice(gpa);
}

// -------- R7: retargeting, which is now a copy --------

/// One frame of a capture, read into every joint's local place (from its position channels) and local
/// turn (from its rotation channels, in the file's own order).
pub fn captureFrame(
    capture: codecs.bvh.Data,
    frame: usize,
    places: []Vec,
    turns: []Quat,
) void {
    const values: []const f32 = capture.frame(frame);
    var taken: usize = 0;
    for (capture.joints, 0..) |joint, j| {
        var place: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]) * splat(cm);
        var turn: Quat = qidentity();
        for (joint.channels) |channel| {
            applyChannel(channel, values[taken], &place, &turn);
            taken += 1;
        }
        places[j] = place;
        turns[j] = turn;
    }
}

/// Writes a capture's frames into the robot's position vector - R7, retargeting, which on a robot built
/// from the capture's own skeleton is a COPY: each body's joint takes `jointFromLocal(rest, pose)` of the
/// capture joints it carries, and the root takes the capture root's place and turn, turned z-up.
///
/// Two of the engine's conventions matter here, and neither is assumed - both are read off the engine's
/// own rest pose, where every ball joint holds the identity and the root holds its rest place and turn:
/// where a quaternion keeps its w (MuJoCo writes it first), and whether the free joint's turn is the root's
/// whole world turn or a turn on top of the root body's own frame.
pub const Copier = struct {
    const Link = struct {
        /// Where this body's ball joint keeps its four numbers.
        adr: u32,
        /// The capture joints whose turns this body carries, parent first (one, while every turned bone
        /// is a body).
        chain: [4]u16,
        chain_len: u8,
        /// That chain's turn in the rest pose.
        rest: Quat,
    };
    links: []Link,
    root_adr: u32,
    root_joint: u16,
    w_first: bool,
    root_absolute: bool,
    /// The root body's rest turn in the engine's world - what a composed free joint turns on top of.
    root_rest: Quat,

    pub fn init(
        gpa: Allocator,
        imported: *const robot_mjcf.Imported,
        rest: Posed,
        capture: codecs.bvh.Data,
    ) !Copier {
        const model: *const rbt.Model = &imported.model;
        const links: []Link = try gpa.alloc(Link, body_names.len - 1);
        errdefer gpa.free(links);
        var copier: Copier = undefined;
        for (body_names, 0..) |name, n| {
            const body: u32 = imported.bodyIndex(name) orelse return error.BodyMissingFromModel;
            const joint: usize = for (model.jnt_body, 0..) |owner, j| {
                if (owner == body) {
                    break j;
                }
            } else return error.BodyWithoutJoint;
            const captured: u16 = @intCast(for (capture.joints, 0..) |candidate, c| {
                if (std.mem.eql(u8, candidate.name, name)) {
                    break c;
                }
            } else return error.CaptureMissesBody);
            if (n == 0) {
                copier.root_adr = model.jnt_qpos_adr[joint];
                copier.root_joint = captured;
                continue;
            }
            // The chain, as in `measureRanges`: from this body up to just below its parent body.
            const bone: usize = rest.find(name) orelse return error.BodyNotInSkeleton;
            var chain: [4]u16 = undefined;
            var chain_length: u8 = 0;
            var walk: i32 = @intCast(bone);
            while (walk >= 0) : (walk = rest.bones[@intCast(walk)].parent) {
                if (walk != bone and isBody(rest.bones[@intCast(walk)].name)) {
                    break;
                }
                chain_length += 1;
            }
            walk = @intCast(bone);
            var turn: Quat = qidentity();
            var slot: u8 = chain_length;
            while (slot > 0) : (walk = rest.bones[@intCast(walk)].parent) {
                slot -= 1;
                const bone_name: []const u8 = rest.bones[@intCast(walk)].name;
                chain[slot] = @intCast(for (capture.joints, 0..) |candidate, c| {
                    if (std.mem.eql(u8, candidate.name, bone_name)) {
                        break c;
                    }
                } else return error.CaptureMissesJoint);
            }
            for (chain[0..chain_length]) |c| {
                const rest_bone: usize = rest.find(capture.joints[c].name) orelse return error.BodyNotInSkeleton;
                turn = qmul(turn, rest.locals[rest_bone]);
            }
            links[n - 1] = .{
                .adr = model.jnt_qpos_adr[joint],
                .chain = chain,
                .chain_len = chain_length,
                .rest = turn,
            };
        }
        // At rest a ball joint holds the identity: the 1 is its w.
        const first: f32 = model.qpos0[links[0].adr];
        const last: f32 = model.qpos0[links[0].adr + 3];
        const identity_found: bool = @abs(first - 1.0) < 1.0e-6 or @abs(last - 1.0) < 1.0e-6;
        assertf(identity_found, @src(), "Copier: rest ball joint reads {d}, {d}", .{
            first,
            last,
        });
        copier.w_first = @abs(first - 1.0) < 1.0e-6;
        copier.links = links;
        // At rest the root's turn is either its whole rest turn (absolute) or nothing on top of it.
        const root_bone: usize = rest.find(body_names[0]) orelse return error.NoRoot;
        copier.root_rest = qmul(y_up_to_z_up, rest.rotations[root_bone]);
        const held: Quat = copier.load(model.qpos0, copier.root_adr + 3);
        copier.root_absolute = @abs(dot4(held, copier.root_rest)) > 1.0 - 1.0e-5;
        const composed: bool = @abs(held[3]) > 1.0 - 1.0e-5;
        assertf(copier.root_absolute or composed, @src(), "Copier: the root's rest turn is neither", .{});
        return copier;
    }

    pub fn deinit(self: *Copier, gpa: Allocator) void {
        gpa.free(self.links);
    }

    fn load(self: Copier, qpos: []const f32, adr: u32) Quat {
        const q: []const f32 = qpos[adr .. adr + 4];
        return if (self.w_first) .{ q[1], q[2], q[3], q[0] } else .{ q[0], q[1], q[2], q[3] };
    }

    fn store(self: Copier, qpos: []f32, adr: u32, q: Quat) void {
        const out: []f32 = qpos[adr .. adr + 4];
        if (self.w_first) {
            out[0] = q[3];
            out[1] = q[0];
            out[2] = q[1];
            out[3] = q[2];
        } else {
            out[0] = q[0];
            out[1] = q[1];
            out[2] = q[2];
            out[3] = q[3];
        }
    }

    /// Write one frame - every capture joint's local turn, and the root's local place - into `qpos`.
    pub fn write(self: Copier, turns: []const Quat, root_place: Vec, qpos: []f32) void {
        const place: Vec = rotate(y_up_to_z_up, root_place);
        qpos[self.root_adr] = place[0];
        qpos[self.root_adr + 1] = place[1];
        qpos[self.root_adr + 2] = place[2];
        const whole: Quat = qmul(y_up_to_z_up, turns[self.root_joint]);
        self.store(qpos, self.root_adr + 3, if (self.root_absolute) whole else qmul(conjugate(self.root_rest), whole));
        for (self.links) |link| {
            var pose: Quat = qidentity();
            for (link.chain[0..link.chain_len]) |c| {
                pose = qmul(pose, turns[c]);
            }
            self.store(qpos, link.adr, jointFromLocal(link.rest, pose));
        }
    }
};

// -------- R8a: the training task's inputs, for Geno --------

/// Where Geno's model lives as a file, so the task and the pages load it instead of re-measuring the body
/// (sampling its volume takes seconds). A test holds it equal to a fresh `writeModel`, and rewrites it when
/// the model has changed - so a new model is always a diff someone sees, never a silent drift.
pub const model_fixture_path: []const u8 = "src/tests/fixtures/robot/geno.xml";

/// A whole capture as the task's clip: every frame copied onto the robot (`Copier`), in the engine's own
/// position layout - the same `dance.Clip` the IK baker makes, so the task takes it as it is.
///
/// Each frame's residual is how far the farthest body sits from the RECORDED capture, and which body that
/// is. On a copy that is never a fitting error - rotations are exact, and so are positions for rigid bones
/// (R7) - it is the capture's own stretch: the thighs and upper arms change length by up to 3 mm, and a
/// rigid robot cannot follow a bone that does. The caller owns the clip.
pub fn copyClip(
    gpa: Allocator,
    imported: *const robot_mjcf.Imported,
    rest: Posed,
    capture: codecs.bvh.Data,
) !dance.Clip {
    var copier: Copier = try .init(gpa, imported, rest, capture);
    defer copier.deinit(gpa);
    const nq: usize = imported.model.qpos0.len;
    const frames: usize = capture.frame_count;
    const targets: []f32 = try gpa.alloc(f32, frames * nq);
    errdefer gpa.free(targets);
    const residual: []f32 = try gpa.alloc(f32, frames);
    errdefer gpa.free(residual);
    const residual_body: []u32 = try gpa.alloc(u32, frames);
    errdefer gpa.free(residual_body);

    var data: rbt.Data = try rbt.Data.init(gpa, &imported.model);
    defer data.deinit();
    @memcpy(data.pos, imported.model.qpos0);
    @memset(data.vel, 0);
    const count: usize = capture.joints.len;
    const places: []Vec = try gpa.alloc(Vec, count);
    defer gpa.free(places);
    const turns: []Quat = try gpa.alloc(Quat, count);
    defer gpa.free(turns);
    const recorded: []Vec = try gpa.alloc(Vec, count);
    defer gpa.free(recorded);
    const world_turns: []Quat = try gpa.alloc(Quat, count);
    defer gpa.free(world_turns);

    for (0..frames) |f| {
        captureFrame(capture, f, places, turns);
        // The capture as recorded, for the residual.
        for (capture.joints, 0..) |joint, j| {
            if (joint.parent >= 0) {
                const up: usize = @intCast(joint.parent);
                recorded[j] = recorded[up] + rotate(world_turns[up], places[j]);
                world_turns[j] = qmul(world_turns[up], turns[j]);
            } else {
                recorded[j] = places[j];
                world_turns[j] = turns[j];
            }
        }
        // The copy, into this frame's slot of the clip.
        const pose: []f32 = targets[f * nq ..][0..nq];
        @memcpy(pose, data.pos);
        copier.write(turns, places[copier.root_joint], pose);
        @memcpy(data.pos, pose);
        data.stage = .stale;
        rbt.kinematics(&imported.model, &data);
        // Where the robot's bodies stand, against the recording.
        var worst: f32 = 0.0;
        var worst_body: u32 = 0;
        for (body_names) |name| {
            const b: u32 = imported.bodyIndex(name) orelse return error.BodyMissingFromModel;
            const j: usize = for (capture.joints, 0..) |candidate, c| {
                if (std.mem.eql(u8, candidate.name, name)) {
                    break c;
                }
            } else return error.CaptureMissesBody;
            const off: f32 = length3(data.body_xpos[b] - rotate(y_up_to_z_up, recorded[j]));
            if (off > worst) {
                worst = off;
                worst_body = b;
            }
        }
        residual[f] = worst;
        residual_body[f] = worst_body;
    }
    return .{
        .gpa = gpa,
        .frame_count = frames,
        .frame_time = capture.frame_time,
        .nq = nq,
        .targets = targets,
        .residual = residual,
        .residual_body = residual_body,
    };
}

/// Geno on a floor, driven through a clip by the tracking task's servo alone - the loop the `geno_track`
/// page runs, here where a test can run it headless. It owns the collision world, the bridge and the
/// servo's working space; the bridge keeps pointers into it, so a `ServoRun` is initialised in place and
/// never moved.
pub const ServoRun = struct {
    /// How the servo's accelerations become torques. Both laws ask the same stable spring for the same
    /// accelerations; they differ in one thing only - whether the torques know about the floor.
    pub const Law = enum {
        /// The task's `pdTorques`: floating-base inverse dynamics, the torques of a body in free flight.
        /// Weight costs nothing in flight, so a STANDING body gets no help holding it up.
        floating,
        /// Inverse dynamics WITH the contacts (`robot_dance.contactConsistentTorques`): the torques a body
        /// standing on those feet actually needs, its root moving however the feet can carry it.
        consistent,
    };
    /// How strongly the consistent law asks the root to follow the reference - the existing code's value.
    pub const root_weight: f32 = 100.0;

    law: Law = .floating,
    /// The servo's spring: its frequency, damping ratio and acceleration cap (`servo_gains` by default).
    gains: robot_track.Gains = servo_gains,
    gpa: Allocator,
    model: *const rbt.Model,
    data: rbt.Data,
    reference: rbt.Data,
    world: zimrphysics.World,
    bridge: robot_physics.Bridge,
    hips: u32,
    accel: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    torque: []f32,
    wrench: []f32,
    contact: dance.ContactScratch,
    /// The floor's friction, kept so the collision world can be rebuilt as it was.
    friction: f32,
    /// CAPTURE-POINT BALANCE THROUGH THE ANKLES (S2c): radians of lean per metre the capture point sits
    /// ahead of the feet, given to both ankles' targets. Zero is the servo alone.
    balance_gain: f32 = 0.0,
    /// The target the servo is actually given, when balance edits it.
    goal: []f32,
    /// Lift every start onto the floor (`rbt.restOnFloor`, 1 mm clear) - off only to measure what it prevents.
    rest_on_floor: bool = true,
    /// VELOCITY FEEDFORWARD: the servo damps toward the reference's velocity, not zero
    /// (`robot_track.pdTorquesToward`) - only through `step`, which knows the clip.
    feedforward: bool = false,
    reference_velocity: []f32,
    /// Collide with the floor and itself - off ONLY to measure what contacts do to a step.
    collide: bool = true,
    /// The start's lift onto the floor - how far the copied pose had to rise to stand on it, not in it.
    lift: f32 = 0.0,
    /// The capture-point reflex - its memory forgotten by every clean start.
    reflex: Reflex,
    /// ONE failure criterion (ON.0b): `lost` asks it.
    check: FailureCheck,

    pub fn init(
        self: *ServoRun,
        gpa: Allocator,
        imported: *const robot_mjcf.Imported,
        friction: f32,
    ) !void {
        const m: *const rbt.Model = &imported.model;
        const nv: usize = m.nv;
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .gpa = undefined,
            .model = undefined,
            .data = undefined,
            .reference = undefined,
            .world = undefined,
            .bridge = undefined,
            .hips = undefined,
            .accel = undefined,
            .scratch = undefined,
            .dense = undefined,
            .full = undefined,
            .torque = undefined,
            .wrench = undefined,
            .contact = undefined,
            .friction = undefined,
            .goal = undefined,
            .reference_velocity = undefined,
            .reflex = undefined,
            .check = undefined,
        };
        self.gpa = gpa;
        self.model = m;
        self.hips = imported.bodyIndex("Hips") orelse return error.NoHips;
        self.reflex = try .init(imported, self.hips);
        self.data = try rbt.Data.init(gpa, m);
        self.reference = try rbt.Data.init(gpa, m);
        self.check = try .init(gpa, m);
        @memcpy(self.data.pos, m.qpos0);
        @memset(self.data.vel, 0);
        self.data.stage = .stale;
        rbt.forward(m, &self.data);
        self.accel = try gpa.alloc(f32, nv);
        self.scratch = try gpa.alloc(f32, nv);
        self.dense = try gpa.alloc(f32, nv * nv);
        self.full = try gpa.alloc(f32, nv);
        self.torque = try gpa.alloc(f32, nv);
        self.wrench = try gpa.alloc(f32, nv);
        self.contact = try .init(gpa, nv);
        self.law = .floating;
        self.gains = servo_gains;
        self.friction = friction;
        self.balance_gain = 0.0;
        self.rest_on_floor = true;
        self.feedforward = false;
        self.collide = true;
        self.lift = 0.0;
        self.reference_velocity = try gpa.alloc(f32, m.nv);
        self.goal = try gpa.alloc(f32, m.nq);
        try self.buildWorld();
    }

    /// The collision world - a floor, a static box whose top face is the engine's z = 0 - and the bridge
    /// that joins it to the robot. Built once; `start` only makes it forget.
    fn buildWorld(self: *ServoRun) !void {
        self.world = try .init(self.gpa, 64);
        const floor_shape: zimrphysics.ShapeId = try self.world.shapes.add(self.gpa, .{
            .box = .{ .half_extent = vec(50, 50, 0.5), .convex_radius = 0.001 },
        });
        _ = try self.world.createBody(.{
            .shape = floor_shape,
            .position = vec(0, 0, -0.5),
            .rotation = qidentity(),
            .motion_type = .static,
            .friction = self.friction,
        });
        self.bridge = try .init(self.gpa, &self.world, self.model, &self.data, 256);
        self.bridge.listen(&self.world);
    }

    pub fn deinit(self: *ServoRun) void {
        self.bridge.deinit(&self.world);
        self.world.deinit(self.gpa);
        self.contact.deinit();
        self.gpa.free(self.goal);
        self.gpa.free(self.reference_velocity);
        self.gpa.free(self.wrench);
        self.gpa.free(self.torque);
        self.gpa.free(self.full);
        self.gpa.free(self.dense);
        self.gpa.free(self.scratch);
        self.gpa.free(self.accel);
        self.check.deinit(self.gpa);
        self.reference.deinit();
        self.data.deinit();
    }

    /// Has the robot lost the clean reference at clip frame `f`? The one failure criterion (`FailureCheck`).
    pub fn lost(self: *ServoRun, clip: *const dance.Clip, f: usize) bool {
        return self.check.lost(self.model, &self.data, clip, f);
    }

    /// Place the robot exactly on frame `f` of the clip - a copy - and still, as if nothing had run before.
    ///
    /// A CLEAN start, not just a teleport. Every layer keeps something from its last step to speed up the
    /// next - the dynamics solver its warm-start forces, the collision world its contact impulses, the bridge
    /// its sense of how far each body moved - and teleported with those in place, the robot's first steps
    /// are pushed by the previous run's floor: the same start falls differently each time. So exactly that
    /// memory is forgotten, and nothing else is rebuilt: no allocation, and still bit-for-bit repeatable.
    pub fn start(self: *ServoRun, clip: *const dance.Clip, f: usize) !void {
        self.data.reset(self.model);
        self.data.forgetWarmStart();
        forgetContacts(&self.world);
        // The task's own reset (`robot_track.resetToFrame`, the fleet's too): the frame's pose, and the
        // velocity the discrete trajectory has there - the backward difference INTO the frame, since
        // semi-implicit Euler reaches frame f as x_f = x_(f-1) + dt * v_f. One reset for tests, the page and
        // training: a second copy is a second place to get a free joint wrong.
        robot_track.resetToFrame(self.model, &self.data, clip, f);
        // Then rested ON the floor, 1 mm clear: a copied pose sinks its feet into it (up to 48 mm on the dance),
        // and the contact solver would throw that overlap out in one step - a jump and a spin.
        self.lift = if (self.rest_on_floor) rbt.restOnFloor(self.model, &self.data, 0.001) else 0.0;
        // The jump to the new pose is a teleport, not a motion: nothing must be swept along it.
        self.bridge.teleported();
        self.reflex.forget();
    }

    /// The reference's velocity over frames f -> f+1 - `rbt.differentiatePos`, the tangent difference
    /// `robot_track.resetToFrame` launches with (a rotation's rate is a quaternion logarithm, not a
    /// subtraction). Zero at the clip's end.
    pub fn referenceVelocity(
        self: *ServoRun,
        clip: *const dance.Clip,
        f: usize,
        out: []f32,
    ) void {
        if (f + 1 >= clip.frame_count) {
            @memset(out, 0.0);
            return;
        }
        const nq: usize = self.model.nq;
        rbt.differentiatePos(
            self.model,
            out,
            clip.targets[f * nq ..][0..nq],
            clip.targets[(f + 1) * nq ..][0..nq],
            clip.frame_time,
        );
    }

    /// A saved moment of the simulation: what the next step reads (positions, velocities) and the balance
    /// reflex's memory. Solver warm starts and cached contacts are NOT saved - `restore` forgets them, exactly
    /// as a clean start does - so every rollout from one snapshot starts identically (the sampling planner's
    /// candidates must be compared fairly), at the price of a small difference from the run that never
    /// stopped (measured by the test).
    pub const Snapshot = struct {
        pos: []f32,
        vel: []f32,
        com_before: Vec = .{ 0, 0, 0, 0 },
        have_com: bool = false,

        pub fn init(gpa: Allocator, m: *const rbt.Model) !Snapshot {
            const pos: []f32 = try gpa.alloc(f32, m.nq);
            errdefer gpa.free(pos);
            return .{ .pos = pos, .vel = try gpa.alloc(f32, m.nv) };
        }

        pub fn deinit(self: *Snapshot, gpa: Allocator) void {
            gpa.free(self.pos);
            gpa.free(self.vel);
        }
    };

    pub fn save(self: *const ServoRun, into: *Snapshot) void {
        @memcpy(into.pos, self.data.pos);
        @memcpy(into.vel, self.data.vel);
        into.com_before = self.reflex.com_before;
        into.have_com = self.reflex.have_com;
    }

    pub fn restore(self: *ServoRun, from: *const Snapshot) void {
        self.data.reset(self.model);
        self.data.forgetWarmStart();
        forgetContacts(&self.world);
        @memcpy(self.data.pos, from.pos);
        @memcpy(self.data.vel, from.vel);
        self.data.stage = .stale;
        rbt.forward(self.model, &self.data);
        self.bridge.teleported();
        self.reflex.com_before = from.com_before;
        self.reflex.have_com = from.have_com;
    }

    /// Everything a collision world remembers from past steps that can push on the next one: the manifold
    /// cache's warm-start impulses, and the contact sets it tells beginnings and endings apart with. Emptied,
    /// with their memory kept for reuse. (The world has no reset of its own.)
    pub fn forgetContacts(world: *zimrphysics.World) void {
        world.cache.normal_now.clearRetainingCapacity();
        world.cache.normal_prev.clearRetainingCapacity();
        world.cache.friction_now.clearRetainingCapacity();
        world.cache.friction_prev.clearRetainingCapacity();
        world.contacts_prev.clearRetainingCapacity();
        world.contacts_curr.clearRetainingCapacity();
    }

    /// One control step toward frame `f`, exactly as the task takes it - collide, the servo's torques,
    /// the dynamics - and how far the hips then are from where the clip has them.
    pub fn step(self: *ServoRun, clip: *const dance.Clip, f: usize) !f32 {
        const target: []const f32 = clip.targets[f * clip.nq ..][0..clip.nq];
        if (!self.feedforward) {
            return self.stepMoving(target, null, clip.frame_time);
        }
        // The velocity the body should END this step with. Semi-implicit Euler moves a body by its NEW
        // velocity, `x_end = x + dt * v_end`, so the end velocity that lands exactly on frame f is the
        // difference f-1 -> f - consistent with the position target. (Onward from f, f -> f+1, is a frame
        // ahead: the spring then trades position for velocity, and misses both.)
        self.referenceVelocity(clip, if (f > 0) f - 1 else 0, self.reference_velocity);
        return self.stepMoving(target, self.reference_velocity, clip.frame_time);
    }

    /// One control step toward any target pose - a clip's frame, or a pose held still.
    pub fn stepToward(self: *ServoRun, requested: []const f32, frame_time: f32) !f32 {
        return self.stepMoving(requested, null, frame_time);
    }

    /// One control step toward a pose, and - when `velocity` is given - toward that velocity too.
    fn stepMoving(
        self: *ServoRun,
        requested: []const f32,
        velocity: ?[]const f32,
        frame_time: f32,
    ) !f32 {
        const target: []const f32 = if (self.balance_gain != 0.0) blk: {
            self.reflex.apply(&self.data, self.balance_gain, frame_time, requested, self.goal);
            break :blk self.goal;
        } else requested;
        if (self.collide) {
            try self.bridge.sync(&self.world, self.model, &self.data);
            try zimrphysics.step(&self.world, frame_time);
            self.bridge.harvest(&self.data);
        }
        rbt.biasForce(self.model, &self.data);
        switch (self.law) {
            .floating => robot_track.pdTorquesToward(
                self.model,
                &self.data,
                target,
                velocity,
                self.gains,
                frame_time,
                self.accel,
                self.scratch,
                self.dense,
                self.full,
                self.torque,
            ),
            .consistent => self.consistentTorques(target, frame_time),
        }
        @memcpy(self.data.applied_force, self.torque);
        rbt.step(self.model, &self.data);
        rbt.forward(self.model, &self.data);
        @memcpy(self.reference.pos, requested);
        self.reference.stage = .stale;
        rbt.kinematics(self.model, &self.reference);
        return length3(self.data.body_xpos[self.hips] - self.reference.body_xpos[self.hips]);
    }

    /// The consistent law: the same spring's accelerations - the root's included, as a wish toward the
    /// reference - turned into the whole body's wanted forces by plain inverse dynamics, then into joint
    /// torques the contacts can actually support.
    fn consistentTorques(self: *ServoRun, target: []const f32, frame_time: f32) void {
        const gains: robot_track.Gains = self.gains;
        rbt.differentiatePos(self.model, self.scratch, self.data.pos, target, 1.0);
        for (self.accel, self.scratch, self.data.vel) |*wanted, error_now, velocity| {
            const spring: f32 = robot_maximal.stableSpringAccel(
                error_now,
                velocity,
                gains.frequency,
                gains.damping,
                frame_time,
            );
            wanted.* = clamp(spring, -gains.max_acceleration, gains.max_acceleration);
        }
        rbt.inverseDynamics(self.model, &self.data, self.accel, self.wrench);
        rbt.massMatrixDense(self.model, &self.data, self.dense);
        _ = dance.contactConsistentTorques(
            self.model,
            &self.data,
            self.wrench,
            self.dense,
            root_weight,
            &self.contact,
            self.torque,
        );
    }

    /// From frame `from`, how many frames the robot stays with the clip: until it loses the reference (`lost`),
    /// or the clip ends.
    pub fn survive(self: *ServoRun, clip: *const dance.Clip, from: usize) !usize {
        try self.start(clip, from);
        var f: usize = from + 1;
        while (f < clip.frame_count) : (f += 1) {
            _ = try self.step(clip, f);
            if (self.lost(clip, f)) {
                return f - from;
            }
        }
        // Frames stepped: from + 1 .. frame_count - 1 (a loss at f returns f - from, the same count).
        return clip.frame_count - from - 1;
    }
};

/// D1 - PREDICTIVE SAMPLING over the TRUE simulator: MuJoCo MPC's simplest planner, and a teacher that cannot
/// exploit a model, because it has none - every candidate is played out in the real physics.
///
/// The plan is a few KNOTS of pose offsets for DReCon's actuated joints (a rotation vector each - the very
/// action space a policy will act in), spread over a horizon and joined by straight lines. Every control step:
///   1. perturb the current plan `samples` ways (candidate 0 is the plan itself, unperturbed);
///   2. play each one `horizon` steps ahead from the SAVED moment - `ServoRun.save` / `restore`, bit-identical
///      starts - and score it: how far every body strays from where the clip has it, plus a penalty for each
///      step left after a fall;
///   3. step for real with the winner's first offsets, and shift the winner one step on in time: the next plan.
/// The step taken for real IS the winner's first rollout step (same restored moment, same physics), so what
/// was scored is exactly what happens. Costs `samples x horizon` physics steps per frame.
pub const Planner = struct {
    gpa: Allocator,
    run: *ServoRun,
    /// Where DReCon's actuated joints keep their quaternions, and where their three degrees of freedom sit
    /// in the task's action (every joint's freedoms but the free root's six).
    joint_adr: []usize,
    joint_dof: []usize,
    options: Options,
    /// Plans: `knots` rows, 3 numbers (a rotation vector, radians) per actuated joint.
    nominal: []f32,
    /// DReCon's ACTION FILTER (Simon Clavet's): the offsets a joint actually receives, `applied += beta *
    /// (raw - applied)` each step - and a copy saved with the moment, so every candidate starts alike.
    applied: []f32 = &.{},
    applied_saved: []f32 = &.{},
    /// `Options.height_bodies`, resolved to body indices (empty: every body).
    height_set: []u32 = &.{},
    /// The posture gate's body, and the robot's standing height of it (the bind pose's, above its lowest point).
    posture_body: u32 = 0,
    stand_height: f32 = 0.0,
    /// Physics steps since the start - which of them are decisions.
    phase: u64 = 0,
    /// The raw and applied offsets at every decision taken for real, per freedom (radians): their sums and
    /// the raw's largest, and how many raw offsets passed 0.2, 0.6 and 1.0 rad - what a student's action
    /// scale must be able to express.
    raw_sum: f64 = 0.0,
    applied_sum: f64 = 0.0,
    raw_largest: f32 = 0.0,
    raw_past: [3]u64 = .{ 0, 0, 0 },
    offsets_counted: u64 = 0,
    candidate: []f32,
    best: []f32,
    /// MPPI's memory of a control step: every candidate played, and what each cost.
    pool: []f32 = &.{},
    costs: []f32 = &.{},
    /// The pose the servo is given, and a body placed on the clip's frame to measure against.
    target: []f32,
    probe: rbt.Data,
    moment: ServoRun.Snapshot,
    rng: std.Random.DefaultPrng,
    /// CANDIDATE RECORDING (D3): when set, every step of every candidate rollout - the rejected ones too - is
    /// appended to `candidates` (environment `candidate_env`, one segment per rollout), every
    /// `candidate_every`-th control step. The teacher's CHOSEN actions are a function of its state, so a world
    /// model learns little about what actions do from them; its candidates are diverse actions around them,
    /// played out in the true simulator exactly where balance is decided.
    candidates: ?*robot_track.Replay = null,
    candidate_env: usize = 0,
    candidate_scale: f32 = 1.0,
    candidate_every: usize = 5,
    candidate_segment: u32 = 1_000_000,
    control_steps: usize = 0,
    recording_candidates: bool = false,
    candidate_action: []f32 = &.{},
    candidate_scratch: []f32 = &.{},
    /// DART-style jitter on recorded candidate steps, in action units: each step executes - and records - its
    /// plan's action plus independent noise, so the data holds action variation that is NOT a function of the
    /// state (what teaches a world model what actions do), around the teacher's own states.
    candidate_jitter: f32 = 0.0,

    pub const Options = struct {
        samples: usize = 16,
        horizon: usize = 15,
        knots: usize = 3,
        /// The perturbation, in radians per offset.
        sigma: f32 = 0.1,
        /// DReCon's filter on the plan's offsets: each step a joint receives `beta` of the new offset and keeps
        /// the rest of what it had (DReCon's 0.2). A plan is then RAW actions - what a DReCon policy outputs, so
        /// what a student would be taught - and the body sees them smoothed. 1 is no filter (bit for bit).
        filter: f32 = 1.0,
        /// DReCon's clock: a DECISION every `decimation` physics steps - the filter takes one new raw action and
        /// the joints hold what it gives until the next. The planner re-plans only at decisions; a student
        /// that is DReCon's policy acts on the same clock. 1 is a decision every step.
        decimation: u32 = 1,
        /// The joints the plan moves (body names; each body's joint gets a rotation-vector offset). DReCon's
        /// ten by default - its locomotion set: no elbows, shoulders, upper spine or neck. A get-up pushes off
        /// the floor with exactly those (ON.2.1c), and SuperTrack's policy offsets every joint.
        actuated: []const []const u8 = &drecon_actuated,
        /// A MEMORYLESS teacher (D5, Sep 25): each decision plans from what a student can SEE - the filter's
        /// state, the offsets the joints currently receive, held at every knot ("keep doing what you're
        /// doing") - instead of the plan carried from the last decision. Measured: with the carried plan,
        /// half of every label was that memory (warm vs cold, same seed, differed by more than the signal
        /// between states), and a clone could only memorise. `iterations` then refines within a decision.
        markov: bool = false,
        /// MPPI iterations a decision: each re-centres on the last one's average and samples afresh.
        iterations: u32 = 1,
        /// GRAVITY in the cost (ON.2.1d, Sep 26). The shape is measured with every body seen from the root's own
        /// position AND rotation - so the body's height and its tilt against gravity both drop out, and lying on
        /// the floor with the right joint angles costs what kneeling upright with them costs. For the dance that
        /// never mattered (standing keeps the root up); for the get-up the rise IS that vertical motion. So,
        /// as SuperTrack's own loss does (its L_hei and L_up): every body's HEIGHT against the reference's
        /// (metres, the mean over bodies) and the UP vector in the root's frame against the reference's. Zero
        /// is the old cost, bit for bit.
        height_weight: f32 = 0.0,
        up_weight: f32 = 0.0,
        /// ...counted only BEYOND these tolerances (a hinge; Sep 26). At full weight the gravity terms halved the
        /// dance (3.65 -> 1.87 s): a dance's height errors are small but everywhere - a swing foot a few cm off -
        /// and the height term double-counted what the shape already asks, pulling limbs toward their heights
        /// when balance wanted a foot planted. The get-up's gaps are the other kind, 0.3-1 m. Metres (each body's
        /// height) and the up vectors' distance (0.2 is ~11 degrees).
        height_tolerance: f32 = 0.0,
        up_tolerance: f32 = 0.0,
        /// GRAVITY WHERE THE SHAPE IS BLIND, and nowhere else (Sep 26). The shape measures every body RELATIVE TO
        /// THE ROOT, so the limbs' heights are already in it - counting them again (`height_weight`) pulled a
        /// dancer's swing foot toward its height and halved the dance; hinging it (`height_tolerance`) kept the
        /// dance but cost the get-up its rise. What the shape drops is exactly two things: the ROOT's own height,
        /// and its tilt against gravity (`up_weight`). This term adds back the first - the hips' height gap,
        /// metres - with no hinge.
        root_height_weight: f32 = 0.0,
        /// The bodies the height term (`height_weight`) counts - empty is every body. For ONE cost across every
        /// clip (Simon: the set will be ~100 clips, get-ups hidden in some): the body's AXIS (`axis_bodies`) -
        /// what leads a rise from the floor, and what a dance's swinging limbs leave alone.
        height_bodies: []const []const u8 = &.{},
        /// POSTURE-GATED gravity (Sep 26): the height and up terms weighted by how low the REFERENCE is -
        /// nothing while its head is at or above `posture_high` of the robot's standing head height (a standing
        /// dance: its dips to recover balance stay free - any height term taxed them, halving the dance), all
        /// of it at or below `posture_low` (lying, kneeling, rising), a straight line between. A property of each
        /// frame's reference pose, not of any clip: a get-up hidden anywhere turns it on by going low.
        posture_gate: bool = false,
        posture_body: []const u8 = "Head",
        posture_low: f32 = 0.5,
        posture_high: f32 = 0.9,
        /// The fall penalty's EARLY WARNING: a rollout pays it once it comes within this fraction of the task's
        /// own limits (`FailureCheck.within`) - the one failure criterion, with a margin. At the full limits the
        /// search only learned of a fall once it was under way (the root 60 cm off or tilted 86 degrees) and the
        /// dance fell from 3.43 s to 1.3 s; 0.6 puts the root's limit at 0.36 m, where the old warning was.
        danger: f32 = 0.6,
        /// The largest offset per degree of freedom, radians - a squashed policy's reach, `[-1, 1]` times its
        /// action scale. Unlimited, a plan random-walks: every step shifts the winner and perturbs it again,
        /// and offsets past 3 rad appear - actions no policy could take, and no teacher for one.
        limit: f32 = 1.0e30,
        /// MPPI (model predictive path integral) instead of predictive sampling: the plan becomes the
        /// candidates' COST-WEIGHTED AVERAGE, weights exp(-(cost - best) / lambda), rather than the single best.
        /// One argmax of perturbed plans is mostly perturbation - fine as a trajectory re-planned every step,
        /// noise as one decision (a student regressing on it learned jitter). The average keeps what the good
        /// candidates agree on. `temperature` sets lambda relative to the costs' own spread (mean - best), so
        /// it needs no knowledge of the cost's scale: small is sharp (near the argmax), large is a plain mean.
        mppi: bool = false,
        temperature: f32 = 0.1,
        seed: u64 = 1,
    };

    /// What a fall costs, per step left in the horizon - far more than any upright step's error.
    const fall_penalty: f32 = 10.0;

    pub fn init(
        gpa: Allocator,
        run: *ServoRun,
        imported: *const robot_mjcf.Imported,
        options: Options,
    ) !Planner {
        const m: *const rbt.Model = run.model;
        const joint_adr: []usize = try gpa.alloc(usize, options.actuated.len);
        errdefer gpa.free(joint_adr);
        const joint_dof: []usize = try gpa.alloc(usize, options.actuated.len);
        errdefer gpa.free(joint_dof);
        for (options.actuated, joint_adr, joint_dof) |name, *adr, *dof| {
            const body: u32 = imported.bodyIndex(name) orelse return error.NoBody;
            const joint: usize = for (m.jnt_body, 0..) |owner, j| {
                if (owner == body) {
                    break j;
                }
            } else return error.NoJoint;
            adr.* = m.jnt_qpos_adr[joint];
            dof.* = m.jnt_dof_adr[joint] - robot_track.rootDofs(m);
        }
        // The height term's bodies: the names this robot has (a skeleton's name may be merged into a neighbour).
        var height_set: std.ArrayList(u32) = .empty;
        errdefer height_set.deinit(gpa);
        for (options.height_bodies) |name| {
            if (imported.bodyIndex(name)) |body| {
                try height_set.append(gpa, body);
            }
        }
        if (options.height_bodies.len > 0 and height_set.items.len == 0) {
            return error.NoBody;
        }
        const size: usize = options.knots * joint_adr.len * 3;
        const nominal: []f32 = try gpa.alloc(f32, size);
        errdefer gpa.free(nominal);
        @memset(nominal, 0.0);
        const applied: []f32 = try gpa.alloc(f32, options.actuated.len * 3);
        errdefer gpa.free(applied);
        @memset(applied, 0.0);
        const applied_saved: []f32 = try gpa.alloc(f32, options.actuated.len * 3);
        errdefer gpa.free(applied_saved);
        const candidate: []f32 = try gpa.alloc(f32, size);
        errdefer gpa.free(candidate);
        const best: []f32 = try gpa.alloc(f32, size);
        errdefer gpa.free(best);
        const target: []f32 = try gpa.alloc(f32, m.nq);
        errdefer gpa.free(target);
        var probe: rbt.Data = try rbt.Data.init(gpa, m);
        errdefer probe.deinit();
        // The posture gate's body, and its standing height: the bind pose's, above the bind pose's own lowest point.
        var posture_body: u32 = 0;
        var stand_height: f32 = 0.0;
        if (options.posture_gate) {
            posture_body = imported.bodyIndex(options.posture_body) orelse return error.NoBody;
            @memcpy(probe.pos, m.qpos0);
            probe.stage = .stale;
            rbt.kinematics(m, &probe);
            stand_height = probe.body_xpos[posture_body][2] - rbt.lowestPoint(m, &probe);
        }
        return .{
            .gpa = gpa,
            .run = run,
            .joint_adr = joint_adr,
            .joint_dof = joint_dof,
            .options = options,
            .nominal = nominal,
            .applied = applied,
            .applied_saved = applied_saved,
            .candidate = candidate,
            .best = best,
            .target = target,
            .probe = probe,
            .moment = try .init(gpa, m),
            .rng = .init(options.seed),
            .height_set = try height_set.toOwnedSlice(gpa),
            .posture_body = posture_body,
            .stand_height = stand_height,
        };
    }

    pub fn deinit(self: *Planner) void {
        if (self.height_set.len > 0) {
            self.gpa.free(self.height_set);
        }
        if (self.pool.len > 0) {
            self.gpa.free(self.pool);
            self.gpa.free(self.costs);
        }
        if (self.candidate_action.len > 0) {
            self.gpa.free(self.candidate_action);
            self.gpa.free(self.candidate_scratch);
        }
        self.moment.deinit(self.gpa);
        self.probe.deinit();
        self.gpa.free(self.target);
        self.gpa.free(self.best);
        self.gpa.free(self.candidate);
        self.gpa.free(self.applied_saved);
        self.gpa.free(self.applied);
        self.gpa.free(self.nominal);
        self.gpa.free(self.joint_dof);
        self.gpa.free(self.joint_adr);
    }

    /// One joint's offset at `t` steps into the horizon: straight lines between knots spread evenly over it.
    fn offsetAt(self: *const Planner, plan: []const f32, t: f32, joint: usize) Vec {
        const span: f32 = float(self.options.horizon - 1) / float(self.options.knots - 1);
        const along: f32 = clamp(t / span, 0.0, float(self.options.knots - 1));
        const k: usize = @min(int(usize, along), self.options.knots - 2);
        const w: f32 = along - float(k);
        const stride: usize = self.joint_adr.len * 3;
        const a: []const f32 = plan[k * stride + joint * 3 ..][0..3];
        const b: []const f32 = plan[(k + 1) * stride + joint * 3 ..][0..3];
        return vec(a[0] + w * (b[0] - a[0]), a[1] + w * (b[1] - a[1]), a[2] + w * (b[2] - a[2]));
    }

    /// The clip's frame `g` with the plan's offsets at step `h`, each turning its joint in the joint's own
    /// frame (w last: R7).
    fn offsetTarget(
        self: *Planner,
        clip: *const dance.Clip,
        g: usize,
        plan: []const f32,
        h: usize,
        decide: bool,
    ) []const f32 {
        const nq: usize = self.run.model.nq;
        @memcpy(self.target, clip.targets[g * nq ..][0..nq]);
        // Through the filter and on DReCon's clock - or, with neither, the plan's offsets straight (bit for bit).
        const through: bool = self.options.filter != 1.0 or self.options.decimation > 1;
        for (self.joint_adr, 0..) |adr, j| {
            var r: Vec = self.offsetAt(plan, float(h), j);
            if (through) {
                const held: []f32 = self.applied[j * 3 ..][0..3];
                if (decide) {
                    const beta: f32 = self.options.filter;
                    held[0] += beta * (r[0] - held[0]);
                    held[1] += beta * (r[1] - held[1]);
                    held[2] += beta * (r[2] - held[2]);
                }
                r = vec(held[0], held[1], held[2]);
            }
            const angle: f32 = length3(r);
            if (angle < 1.0e-6) {
                continue;
            }
            const turn: Quat = quatFromAxisAngle(r / splat(angle), angle);
            const q: []f32 = self.target[adr..][0..4];
            const turned: Quat = qmul(.{ q[0], q[1], q[2], q[3] }, turn);
            q[0] = turned[0];
            q[1] = turned[1];
            q[2] = turned[2];
            q[3] = turned[3];
        }
        return self.target;
    }

    /// How far the simulated body is from the clip's frame: the SHAPE (every body's mean distance with both
    /// bodies seen from their own root - heading and wandering removed), the root's miss across the floor, and
    /// the hips' plain distance (the fall rule's).
    const Stray = struct {
        shape: f32,
        across: f32,
        hips: f32,
        height: f32,
        up: f32,
        root_height: f32,
        /// How much gravity counts at this frame: 1 without the posture gate.
        gravity: f32,
    };

    /// How much a metre of the root's wandering counts against a metre of shape. Shape first, as tracking
    /// rewards weigh it: scored in the world, a body that has drifted gets bent toward where the dance IS on
    /// the floor, and loses the dance itself.
    const across_weight: f32 = 0.3;

    fn strayFrom(
        self: *Planner,
        clip: *const dance.Clip,
        g: usize,
    ) Stray {
        const m: *const rbt.Model = self.run.model;
        @memcpy(self.probe.pos, clip.targets[g * m.nq ..][0..m.nq]);
        self.probe.stage = .stale;
        rbt.kinematics(m, &self.probe);
        const hips: u32 = self.run.hips;
        const sim_root: Quat = conjugate(self.run.data.body_xrot[hips]);
        const ref_root: Quat = conjugate(self.probe.body_xrot[hips]);
        var sum: f32 = 0.0;
        var heights: f32 = 0.0;
        for (1..m.nbody) |b| {
            const here: Vec = rotate(sim_root, self.run.data.body_xpos[b] - self.run.data.body_xpos[hips]);
            const there: Vec = rotate(ref_root, self.probe.body_xpos[b] - self.probe.body_xpos[hips]);
            sum += length3(here - there);
            if (self.height_set.len == 0) {
                heights += self.heightGap(b);
            }
        }
        if (self.height_set.len > 0) {
            for (self.height_set) |b| {
                heights += self.heightGap(b);
            }
        }
        const counted: usize = if (self.height_set.len > 0) self.height_set.len else m.nbody - 1;
        // Gravity's direction as each root sees it: world up (z), turned into the root's frame.
        const world_up: Vec = vec(0.0, 0.0, 1.0);
        const tilt: f32 = length3(rotate(sim_root, world_up) - rotate(ref_root, world_up));
        const up_apart: f32 = @max(0.0, tilt - self.options.up_tolerance);
        const off: Vec = self.run.data.body_xpos[hips] - self.probe.body_xpos[hips];
        return .{
            .shape = sum / float(m.nbody - 1),
            .across = length3(vec(off[0], off[1], 0.0)),
            .hips = length3(off),
            .height = heights / float(counted),
            .up = up_apart,
            .root_height = @abs(off[2]),
            .gravity = self.gravityAt(),
        };
    }

    /// The posture gate's weight at the frame the probe is posed at: 1 when the reference's gate body is at or
    /// below `posture_low` of its standing height, 0 at or above `posture_high`, a straight line between.
    fn gravityAt(self: *const Planner) f32 {
        if (!self.options.posture_gate) {
            return 1.0;
        }
        const height: f32 = self.probe.body_xpos[self.posture_body][2] / self.stand_height;
        const span: f32 = self.options.posture_high - self.options.posture_low;
        return clamp((self.options.posture_high - height) / span, 0.0, 1.0);
    }

    /// One body's height off the reference's (metres), beyond the tolerance - read after `strayFrom` has posed
    /// the probe at the reference.
    fn heightGap(self: *const Planner, b: usize) f32 {
        const gap: f32 = @abs(self.run.data.body_xpos[b][2] - self.probe.body_xpos[b][2]);
        return @max(0.0, gap - self.options.height_tolerance);
    }

    /// A candidate played out from the saved moment at frame `f`: its summed stray, and the fall penalty.
    fn rollout(
        self: *Planner,
        clip: *const dance.Clip,
        f: usize,
        plan: []const f32,
    ) !f32 {
        var total: f32 = 0.0;
        const segment: u32 = self.candidate_segment;
        if (self.recording_candidates) {
            self.candidate_segment += 1;
        }
        for (0..self.options.horizon) |h| {
            const g: usize = @min(f + h, clip.frame_count - 1);
            if (self.recording_candidates) {
                // The state this rollout step starts from and the action applied there, as the fleet records
                // its own steps (the frame it is AT: g - 1, stepping toward g) - the plan's action plus the
                // jitter, within the planner's reach, and EXACTLY that action executed (`applyAction`).
                const action: []f32 = self.candidate_action;
                _ = self.actionFor(plan, float(h), self.candidate_scale, action);
                if (self.candidate_jitter > 0.0) {
                    const reach: f32 = self.options.limit / self.candidate_scale;
                    const random: std.Random = self.rng.random();
                    for (self.joint_dof) |dof| {
                        for (action[dof..][0..3]) |*a| {
                            a.* = clamp(a.* + self.candidate_jitter * random.floatNorm(f32), -reach, reach);
                        }
                    }
                }
                self.candidates.?.append(
                    self.candidate_env,
                    self.run.data.pos,
                    self.run.data.vel,
                    action,
                    @intCast(@max(g, 1) - 1),
                    0,
                    segment,
                );
                const m: *const rbt.Model = self.run.model;
                robot_track.applyAction(
                    m,
                    clip.targets[g * m.nq ..][0..m.nq],
                    action,
                    self.candidate_scale,
                    self.candidate_scratch,
                    self.target,
                );
                _ = try self.run.stepToward(self.target, clip.frame_time);
            } else {
                const decide: bool = (self.phase + h) % @max(self.options.decimation, 1) == 0;
                _ = try self.run.stepToward(self.offsetTarget(clip, g, plan, h, decide), clip.frame_time);
            }
            const stray: Stray = self.strayFrom(clip, g);
            const gravity: f32 = self.options.height_weight * stray.height + self.options.up_weight * stray.up +
                self.options.root_height_weight * stray.root_height;
            total += stray.shape + across_weight * stray.across + stray.gravity * gravity;
            if (self.run.check.within(self.run.model, &self.run.data, clip, g, self.options.danger)) {
                total += fall_penalty * float(self.options.horizon - h);
                break;
            }
        }
        return total;
    }

    /// Choose the step toward clip frame `f`: sample, play out, keep the winner in `best`. Leaves the run
    /// restored at the moment it planned from - the state the real step starts from.
    pub fn choose(self: *Planner, clip: *const dance.Clip, f: usize) !void {
        self.control_steps += 1;
        self.recording_candidates = self.candidates != null and self.control_steps % self.candidate_every == 0;
        if (self.recording_candidates and self.candidate_action.len == 0) {
            self.candidate_action = try self.gpa.alloc(f32, robot_track.actionSize(self.run.model));
            self.candidate_scratch = try self.gpa.alloc(f32, self.run.model.nv);
        }
        self.run.save(&self.moment);
        @memcpy(self.applied_saved, self.applied);
        if (self.options.mppi and self.pool.len == 0) {
            self.pool = try self.gpa.alloc(f32, self.options.samples * self.candidate.len);
            self.costs = try self.gpa.alloc(f32, self.options.samples);
        }
        if (self.options.markov) {
            const joints: usize = self.joint_adr.len;
            for (0..self.options.knots) |knot| {
                @memcpy(self.nominal[knot * joints * 3 ..][0 .. joints * 3], self.applied[0 .. joints * 3]);
            }
        }
        var best_cost: f32 = 1.0e30;
        const random: std.Random = self.rng.random();
        var iteration: u32 = 0;
        while (iteration < @max(self.options.iterations, 1)) : (iteration += 1) {
            if (iteration > 0) {
                // Re-centre on what the last iteration chose, and search around it afresh.
                @memcpy(self.nominal, self.best);
                best_cost = 1.0e30;
            }
            try self.sampleOnce(clip, f, random, &best_cost);
        }
        self.run.restore(&self.moment);
        @memcpy(self.applied, self.applied_saved);
    }

    /// One round of the search: the nominal and `samples - 1` perturbations of it, each played out from the
    /// saved moment; the winner (or MPPI's average) in `best`.
    fn sampleOnce(
        self: *Planner,
        clip: *const dance.Clip,
        f: usize,
        random: std.Random,
        best_cost: *f32,
    ) !void {
        for (0..self.options.samples) |k| {
            const limit: f32 = self.options.limit;
            for (self.candidate, self.nominal) |*c, n| {
                const tried: f32 = if (k == 0) n else n + self.options.sigma * random.floatNorm(f32);
                c.* = clamp(tried, -limit, limit);
            }
            self.run.restore(&self.moment);
            @memcpy(self.applied, self.applied_saved);
            const cost: f32 = try self.rollout(clip, f, self.candidate);
            if (cost < best_cost.*) {
                best_cost.* = cost;
                @memcpy(self.best, self.candidate);
            }
            if (self.options.mppi) {
                @memcpy(self.pool[k * self.candidate.len ..][0..self.candidate.len], self.candidate);
                self.costs[k] = cost;
            }
        }
        if (self.options.mppi) {
            self.average(best_cost.*);
        }
    }

    /// MPPI's plan: the candidates averaged, each weighted exp(-(cost - best) / lambda), lambda the temperature
    /// times the costs' spread (their mean above the best) - scale-free. Written over `best`.
    fn average(self: *Planner, best_cost: f32) void {
        const n: usize = self.options.samples;
        var mean: f32 = 0.0;
        for (self.costs) |c| {
            mean += c;
        }
        mean /= float(n);
        const lambda: f32 = self.options.temperature * @max(mean - best_cost, 1.0e-6);
        var total: f32 = 0.0;
        @memset(self.best, 0.0);
        for (0..n) |k| {
            const weight: f32 = @exp(-(self.costs[k] - best_cost) / lambda);
            total += weight;
            for (self.best, self.pool[k * self.best.len ..][0..self.best.len]) |*b, c| {
                b.* += weight * c;
            }
        }
        for (self.best) |*b| {
            b.* /= total;
        }
    }

    /// Take the chosen step for real - the winner's first offsets, from the moment `choose` restored - and shift
    /// the winner one step on in time: the next plan. Returns how far the hips are from the clip's.
    pub fn act(self: *Planner, clip: *const dance.Clip, f: usize) !f32 {
        const every: u64 = @max(self.options.decimation, 1);
        const decide: bool = self.phase % every == 0;
        _ = try self.run.stepToward(self.offsetTarget(clip, f, self.best, 0, decide), clip.frame_time);
        self.phase += 1;
        if (!decide) {
            // Held: the plan is not consulted, and not shifted - that happens once a decision.
            return self.strayFrom(clip, f).hips;
        }
        for (0..self.joint_adr.len) |j| {
            const raw: Vec = self.offsetAt(self.best, 0.0, j);
            const raws = [3]f32{ raw[0], raw[1], raw[2] };
            for (raws, 0..) |value, axis| {
                const size: f32 = @abs(value);
                self.raw_sum += size;
                self.raw_largest = @max(self.raw_largest, size);
                for ([_]f32{ 0.2, 0.6, 1.0 }, 0..) |edge, b| {
                    if (size > edge) {
                        self.raw_past[b] += 1;
                    }
                }
                self.applied_sum += @abs(self.applied[j * 3 + axis]);
                self.offsets_counted += 1;
            }
        }
        const stride: usize = self.joint_adr.len * 3;
        const span: f32 = float(self.options.horizon - 1) / float(self.options.knots - 1);
        for (0..self.options.knots) |k| {
            for (0..self.joint_adr.len) |j| {
                const shifted: Vec = self.offsetAt(self.best, float(k) * span + float(every), j);
                self.nominal[k * stride + j * 3 ..][0..3].* = .{ shifted[0], shifted[1], shifted[2] };
            }
        }
        return self.strayFrom(clip, f).hips;
    }

    /// One real control step at clip frame `f`: plan, then act.
    pub fn step(self: *Planner, clip: *const dance.Clip, f: usize) !f32 {
        if (self.phase % @max(self.options.decimation, 1) == 0) {
            try self.choose(clip, f);
        }
        return self.act(clip, f);
    }

    /// The winner's first offsets as the TASK's action: its layout (every joint's freedoms but the root's),
    /// divided by the action scale - `robot_track.applyAction` turns them back into the same turns. Returns
    /// the largest offset, in radians.
    pub fn actionOf(self: *const Planner, scale: f32, out: []f32) f32 {
        return self.actionFor(self.best, 0.0, scale, out);
    }

    /// Any plan's offsets at `t` steps into the horizon, as the task's action (see `actionOf`).
    pub fn actionFor(
        self: *const Planner,
        plan: []const f32,
        t: f32,
        scale: f32,
        out: []f32,
    ) f32 {
        @memset(out, 0.0);
        var largest: f32 = 0.0;
        for (self.joint_dof, 0..) |dof, j| {
            const r: Vec = self.offsetAt(plan, t, j);
            largest = @max(largest, length3(r));
            out[dof + 0] = r[0] / scale;
            out[dof + 1] = r[1] / scale;
            out[dof + 2] = r[2] / scale;
        }
        return largest;
    }

    /// What a recording made: how many steps, and the largest offset the planner used, in radians.
    pub const Recording = struct { frames: usize, largest_offset: f32 };

    /// `survive`, RECORDED in the task's own format - each real step's state (the one it is taken FROM), its
    /// action, the frame it is at and the segment, exactly as `robot_track.Fleet.step` appends them - into
    /// `replay`'s environment `env`. The data a world model must see: deliberate actions where balance is
    /// decided, from a planner with nothing to exploit.
    pub fn record(
        self: *Planner,
        clip: *const dance.Clip,
        from: usize,
        cap: usize,
        replay: *robot_track.Replay,
        env: usize,
        segment: u32,
        scale: f32,
        action: []f32,
    ) !Recording {
        try self.run.start(clip, from);
        // A new start: nothing held in the filter, and the clock at a decision.
        @memset(self.applied, 0.0);
        self.phase = 0;
        @memset(self.nominal, 0.0);
        var largest: f32 = 0.0;
        const last: usize = @min(clip.frame_count, from + 1 + cap);
        var f: usize = from + 1;
        while (f < last) : (f += 1) {
            if (self.phase % @max(self.options.decimation, 1) == 0) {
                try self.choose(clip, f);
                largest = @max(largest, self.actionOf(scale, action));
                replay.append(env, self.run.data.pos, self.run.data.vel, action, @intCast(f - 1), 0, segment);
            }
            _ = try self.act(clip, f);
            if (self.run.lost(clip, f)) {
                return .{ .frames = f - from, .largest_offset = largest };
            }
        }
        return .{ .frames = last - from, .largest_offset = largest };
    }

    /// From frame `from`, how many frames the PLANNED robot stays with the clip (the servo's rule), at most `cap`.
    pub fn survive(
        self: *Planner,
        clip: *const dance.Clip,
        from: usize,
        cap: usize,
    ) !usize {
        try self.run.start(clip, from);
        // A new start: nothing held in the filter, and the clock at a decision.
        @memset(self.applied, 0.0);
        self.phase = 0;
        @memset(self.nominal, 0.0);
        const last: usize = @min(clip.frame_count, from + 1 + cap);
        var f: usize = from + 1;
        while (f < last) : (f += 1) {
            _ = try self.step(clip, f);
            if (self.run.lost(clip, f)) {
                return f - from;
            }
        }
        // Frames stepped (from + 1 .. last - 1) - a loss at f returns f - from, the same count.
        return last - from - 1;
    }
};

/// THE CLIP'S PER-FRAME LIFT (R8a part 5): every frame whose lowest collision point pierces the floor gets its
/// root raised just enough to sit `clearance` above it - never lowered, since a clip's flight phases are real.
/// A pose copied from a capture does not know where the simulated floor is: the walk's feet sink up to 17 mm
/// into it on many frames, and a servo pulled toward those poses fights the floor all the time. Applied AFTER
/// the copy (the copy itself stays exact to the recording). `probe` is any data for `m`. Returns how many
/// frames it raised, and the largest raise.
pub const Raise = struct { frames: usize, most: f32 };

pub fn restClipOnFloor(
    m: *const rbt.Model,
    probe: *rbt.Data,
    clip: *dance.Clip,
    clearance: f32,
) Raise {
    var raised: usize = 0;
    var most: f32 = 0.0;
    for (0..clip.frame_count) |f| {
        const frame: []f32 = clip.targets[f * clip.nq ..][0..clip.nq];
        @memcpy(probe.pos, frame);
        probe.stage = .stale;
        rbt.kinematics(m, probe);
        const lift: f32 = clearance - rbt.lowestPoint(m, probe);
        if (lift > 0.0) {
            frame[2] += lift;
            raised += 1;
            most = @max(most, lift);
        }
    }
    return .{ .frames = raised, .most = most };
}

/// A pose HELD: one frame of a capture, copied onto the robot and repeated for `seconds` at `frame_time` -
/// a clip the task can run like any other, whose reference simply never moves. The root is lifted 5 mm,
/// as Geno's soles sit 4.5 mm below the floor at rest. The caller owns the clip.
pub fn heldClip(
    gpa: Allocator,
    imported: *const robot_mjcf.Imported,
    rest: Posed,
    pose: codecs.bvh.Data,
    seconds: f32,
    frame_time: f32,
) !dance.Clip {
    var once: dance.Clip = try copyClip(gpa, imported, rest, pose);
    defer once.deinit();
    const frames: usize = @trunc(seconds / frame_time);
    const nq: usize = once.nq;
    const targets: []f32 = try gpa.alloc(f32, frames * nq);
    errdefer gpa.free(targets);
    const residual: []f32 = try gpa.alloc(f32, frames);
    errdefer gpa.free(residual);
    const residual_body: []u32 = try gpa.alloc(u32, frames);
    for (0..frames) |f| {
        const frame: []f32 = targets[f * nq ..][0..nq];
        @memcpy(frame, once.targets[0..nq]);
        frame[2] += 0.005;
    }
    @memset(residual, once.residual[0]);
    @memset(residual_body, once.residual_body[0]);
    return .{
        .gpa = gpa,
        .frame_count = frames,
        .frame_time = frame_time,
        .nq = nq,
        .targets = targets,
        .residual = residual,
        .residual_body = residual_body,
    };
}

// -------- Tests --------

const expect = std.testing.expect;
const bind_bvh: []const u8 = @embedFile("tests/fixtures/robot/geno_bind.bvh");
const stance_bvh: []const u8 = @embedFile("tests/fixtures/robot/geno_stance.bvh");
const mesh_bin: []const u8 = @embedFile("tests/fixtures/robot/geno.bin");
const rbt = @import("robot.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const robot_physics = @import("robot_physics.zig");
const zimrphysics = @import("zimrphysics.zig");

/// How far apart two rotations are, in degrees (0 = the same rotation, whichever sign each carries).
///
/// Measured on the rotation BETWEEN them, as 2 atan2(|its axis part|, |its angle part|) - not as acos
/// of the two quaternions' dot product. Near zero, which is exactly where a test lives, acos is
/// ill-conditioned: a dot product one float step below 1 reads as 0.04 degrees of error that is not
/// there. atan2 of the small part over the large one has no such cliff.
fn degreesApart(a: Quat, b: Quat) f32 {
    const between: Quat = qmul(conjugate(a), b);
    return degFromRad(2.0 * atan2Rad(length3(between), @abs(between[3])));
}

test "robot_geno: R1 - Geno's measurements, as our own code reads them" {
    // The skeleton the robot will be built from, checked against what the character actually is. These
    // are the numbers every later step depends on, so they are asserted here rather than trusted:
    // a silent change in the parser, the codec or the file would otherwise show up much later as a
    // robot that no longer matches its captures.
    const gpa: Allocator = std.testing.allocator;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var stance: Posed = try readPose(gpa, stance_bvh);
    defer stance.deinit(gpa);

    // The leg chain, which is what the foot problem lives in.
    const hips: Vec = bind.at("Hips") orelse return error.NoHips;
    const knee: Vec = bind.at("LeftLeg") orelse return error.NoKnee;
    const ankle: Vec = bind.at("LeftFoot") orelse return error.NoAnkle;
    const toe: Vec = bind.at("LeftToeBase") orelse return error.NoToe;
    const thigh: f32 = length3(knee - (bind.at("LeftUpLeg") orelse return error.NoHip));
    const shin: f32 = length3(ankle - knee);
    const foot: f32 = length3(toe - ankle);

    // The anatomy constant: in the rest pose, with the foot flat on the floor, the line from ankle to
    // toe DESCENDS - because the toe joint sits below the ankle, and there is no heel bone at all.
    const drop: Vec = toe - ankle;
    const descent: f32 = @abs(degFromRad(asinRad(clamp(drop[1] / length3(drop), -1.0, 1.0))));
    const stance_ankle: Vec = stance.at("LeftFoot") orelse return error.NoAnkle;
    const stance_toe: Vec = stance.at("LeftToeBase") orelse return error.NoToe;
    const stance_drop: Vec = stance_toe - stance_ankle;
    const stance_descent: f32 =
        @abs(degFromRad(asinRad(clamp(stance_drop[1] / length3(stance_drop), -1.0, 1.0))));

    report.print("\n  Geno, in metres: hips {d:.3} m up, thigh {d:.3}, shin {d:.3}, ankle-to-toe {d:.3}\n", .{
        hips[1],
        thigh,
        shin,
        foot,
    });
    report.print("  the ankle sits {d:.3} m up, its toe {d:.3} m up: the rest sole descends " ++
        "{d:.1} deg (bind), {d:.1} deg (stance)\n", .{ ankle[1], toe[1], descent, stance_descent });

    // Geno is a human-sized character: hips a little under a metre, a thigh and a shin of about
    // forty centimetres each.
    try expect(hips[1] > 0.7 and hips[1] < 1.0);
    try expect(thigh > 0.3 and thigh < 0.45);
    try expect(shin > 0.3 and shin < 0.45);
    // The ankle rides well above the floor, which is why a foot with no depth ends up hovering.
    try expect(ankle[1] > 0.06 and ankle[1] < 0.10);
    // And the anatomy this whole phase turns on, in both poses.
    try expect(descent > 15.0 and descent < 30.0);
    try expect(stance_descent > 15.0 and stance_descent < 30.0);

    // Both files describe the SAME skeleton: same bones, same offsets. Only the rotations differ - one
    // is the A-pose the mesh is bound in, the other a T-pose.
    try expect(bind.bones.len == stance.bones.len);
    var worst: f32 = 0.0;
    for (bind.bones, stance.bones) |a, b| {
        try expect(std.mem.eql(u8, a.name, b.name));
        try expect(a.parent == b.parent);
        if (a.parent >= 0) {
            worst = @max(worst, length3(a.offset - b.offset));
        }
    }
    report.print("  bind and stance: {d} bones, identical hierarchy, offsets differ by at most {d:.4} m\n", .{
        bind.bones.len,
        worst,
    });
    try expect(worst < 0.002);
}

test "robot_geno: R2 - the robot's zero pose is Geno's bind pose, and a pose is a copy" {
    const gpa: Allocator = std.testing.allocator;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var stance: Posed = try readPose(gpa, stance_bvh);
    defer stance.deinit(gpa);
    const n: usize = bind.bones.len;

    const identity: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(identity);
    @memset(identity, qidentity());
    const positions: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(positions);
    const rotations: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(rotations);

    // 1. WHY NOT THE FILE'S OWN ZERO. Identity rest rotations and identity joints are exactly "every
    //    rotation at zero, every offset kept" - what a robot built from the bare offsets would call rest.
    //    Measured: both arms point straight up, and the foot is level (its tilt is the ankle's rotation).
    restForward(bind.bones, identity, bind.positions[0], identity, positions, rotations);
    const shoulder: usize = bind.find("LeftArm") orelse return error.NoShoulder;
    const elbow: usize = bind.find("LeftForeArm") orelse return error.NoElbow;
    const upper_arm: Vec = positions[elbow] - positions[shoulder];
    const arm_up: f32 = degFromRad(asinRad(clamp(upper_arm[1] / length3(upper_arm), -1.0, 1.0)));
    const zero_ankle: usize = bind.find("LeftFoot") orelse return error.NoAnkle;
    const zero_ball: usize = bind.find("LeftToeBase") orelse return error.NoBall;
    const zero_foot: Vec = positions[zero_ball] - positions[zero_ankle];
    const zero_slope: f32 = clamp(zero_foot[1] / length3(zero_foot), -1.0, 1.0);
    const zero_descent: f32 = @abs(degFromRad(asinRad(zero_slope)));

    // 2. THE DECLARATION HOLDS: on the bind pose's own rotations, identity joints ARE the bind pose,
    //    bone for bone. q = 0 is the pose the mesh is skinned in.
    restForward(bind.bones, bind.locals, bind.positions[0], identity, positions, rotations);
    var rest_place: f32 = 0.0;
    var rest_turn: f32 = 0.0;
    for (0..n) |i| {
        rest_place = @max(rest_place, length3(positions[i] - bind.positions[i]));
        rest_turn = @max(rest_turn, degreesApart(rotations[i], bind.rotations[i]));
    }

    // 3. A POSE IS A COPY: the stance, as joint rotations away from rest, rebuilt by the robot's own
    //    kinematics, lands on the stance - every bone, to float noise. This is R7's whole method, checked
    //    before any capture is copied with it.
    const joints: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(joints);
    for (joints, 0..) |*j, i| {
        j.* = jointFromLocal(bind.locals[i], stance.locals[i]);
    }
    restForward(bind.bones, bind.locals, stance.positions[0], joints, positions, rotations);
    var copy_place: f32 = 0.0;
    var copy_turn: f32 = 0.0;
    for (0..n) |i| {
        copy_place = @max(copy_place, length3(positions[i] - stance.positions[i]));
        copy_turn = @max(copy_turn, degreesApart(rotations[i], stance.rotations[i]));
    }

    // 4. THE ANATOMY CONSTANT, held to the measurement in the declared rest pose.
    const ankle: Vec = bind.at("LeftFoot") orelse return error.NoAnkle;
    const ball: Vec = bind.at("LeftToeBase") orelse return error.NoBall;
    const drop: Vec = ball - ankle;
    const descent: f32 = @abs(degFromRad(asinRad(clamp(drop[1] / length3(drop), -1.0, 1.0))));

    // The numbers first, so that a failure below always shows the evidence it failed on.
    report.print("\n  R2: at the file's zero the upper arm points {d:.0} deg above level and the foot descends " ++
        "{d:.1} deg;\n  identity joints = bind to {e:.1} m / {e:.1} deg; " ++
        "the stance copied = the stance to {e:.1} m / " ++
        "{e:.1} deg;\n  rest sole descent {d:.2} deg (constant {d:.1})\n", .{
        arm_up,
        zero_descent,
        rest_place,
        rest_turn,
        copy_place,
        copy_turn,
        descent,
        rest_sole_descent_deg,
    });
    // The file's zero: arms overhead, foot level - a poor middle, and the anatomy is in the rotations.
    try expect(arm_up > 80.0);
    try expect(zero_descent < 1.0);
    try expect(rest_place < 1.0e-6);
    try expect(rest_turn < 1.0e-2);
    try expect(copy_place < 1.0e-5);
    try expect(copy_turn < 1.0e-2);
    try expect(@abs(descent - rest_sole_descent_deg) < 0.05);
}

test "robot_geno: R3 - the sole plane, derived from Geno's own mesh" {
    const gpa: Allocator = std.testing.allocator;
    var mesh: Mesh = try readMesh(gpa, mesh_bin);
    defer mesh.deinit(gpa);
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);

    // The file, understood whole - `readMesh` has already asserted that every byte was accounted for.
    try expect(mesh.positions.len == 10_329);
    try expect(mesh.triangles.len == 18_660);
    try expect(mesh.joint_names.len == 75);

    // ONE FRAME FOR BOTH. Every joint the mesh names is a bone of our skeleton, and sits where our own
    // kinematics of the bind file put it. Without this, a sole measured on the mesh and an ankle
    // measured on the skeleton could disagree by an offset nobody would see.
    var worst: f32 = 0.0;
    for (mesh.joint_names, 0..) |name, j| {
        const ours: Vec = bind.at(name) orelse return error.MeshJointNotInSkeleton;
        worst = @max(worst, length3(ours - mesh.joint_bind_positions[j]));
    }
    try expect(worst < 1.0e-3);

    for ([_]Side{ .left, .right }) |side| {
        const sole: Sole = try solePlane(mesh, bind, side);
        report.print("  R3 {s}: sole at {d:.4} m, ankle {d:.4} m above it; {d} vertices touch, from {d:.3} m " ++
            "(heel) to {d:.3} m (toes) along the foot, the ball at {d:.3}\n", .{
            side.prefix(),
            sole.height,
            sole.ankle_height,
            sole.touching,
            sole.heel,
            sole.toe,
            sole.ball,
        });
        // The known answer: posed at bind, the lowest point is on the floor to 5 mm...
        try expect(@abs(sole.height) <= 0.005);
        // ...the HEEL touches (contact behind the ankle)...
        try expect(sole.heel < 0.0);
        // ...and so do the TOES (contact past the ball of the foot): the sole is flat, heel to toe.
        try expect(sole.toe > sole.ball);
        // The foot's depth: the ankle rides 8-9.5 cm above the sole, as a human's does.
        try expect(sole.ankle_height > 0.08 and sole.ankle_height < 0.095);
    }
    report.print("  mesh and skeleton share one frame: 75 joints, worst {e:.1} m apart\n", .{worst});
}

test "robot_geno: R5 - the volume sampler, on a box whose answer is known" {
    // THE METHOD FIRST, on something with an exact answer: a 0.3 x 0.5 x 0.2 m box, deliberately NOT at
    // the origin, so that a mistake in moving the moments to the centre cannot hide. Uniform density:
    // volume abc, mass density * abc, and about its centre I_xx = m (b^2 + c^2) / 12 and so on.
    const gpa: Allocator = std.testing.allocator;
    const size: [3]f32 = .{ 0.3, 0.5, 0.2 };
    const middle: Vec = vec(0.1, 0.4, -0.05);
    var corners: [8]Vec = undefined;
    for (0..8) |k| {
        const sx: f32 = if (k & 1 == 0) -0.5 else 0.5;
        const sy: f32 = if (k & 2 == 0) -0.5 else 0.5;
        const sz: f32 = if (k & 4 == 0) -0.5 else 0.5;
        corners[k] = middle + vec(sx * size[0], sy * size[1], sz * size[2]);
    }
    // Twelve triangles, two to a face; their winding is irrelevant to the sampler, so it is not fussed.
    var triangles: [12][3]u16 = .{
        .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 4, 5, 7 }, .{ 4, 7, 6 }, // z = -c/2, z = +c/2
        .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 2, 3, 7 }, .{ 2, 7, 6 }, // y = -b/2 (bottom), y = +b/2 (top)
        .{ 0, 2, 6 }, .{ 0, 6, 4 }, .{ 1, 3, 7 }, .{ 1, 7, 5 }, // x = -a/2, x = +a/2
    };
    var joints: [8][4]u8 = @splat(.{ 0, 0, 0, 0 });
    var weights: [8][4]f32 = @splat(.{ 1, 0, 0, 0 });
    var name: [3]u8 = "Box".*;
    var names: [1][]u8 = .{&name};
    var parents: [1]i32 = .{-1};
    var bind_positions: [1]Vec = .{middle};
    const box: Mesh = .{
        .positions = &corners,
        .joints = &joints,
        .weights = &weights,
        .triangles = &triangles,
        .joint_names = &names,
        .joint_parents = &parents,
        .joint_bind_positions = &bind_positions,
    };
    var sampled: BodyVolume = try measureVolume(gpa, box, volume_step, .skin_weights);
    defer sampled.deinit(gpa);
    const share: Share = sampled.whole();
    const m: f32 = density * size[0] * size[1] * size[2];
    const expected: [3]f32 = .{
        m * (size[1] * size[1] + size[2] * size[2]) / 12.0,
        m * (size[0] * size[0] + size[2] * size[2]) / 12.0,
        m * (size[0] * size[0] + size[1] * size[1]) / 12.0,
    };
    const got: [3][3]f32 = share.inertia();
    report.print("\n  R5 box: mass {d:.3} kg (exact {d:.3}), centre off by {e:.1} m, " ++
        "inertia {d:.4} {d:.4} {d:.4} " ++
        "(exact {d:.4} {d:.4} {d:.4}), odd columns {d}\n", .{
        share.mass(),
        m,
        length3(share.centre() - middle),
        got[0][0],
        got[1][1],
        got[2][2],
        expected[0],
        expected[1],
        expected[2],
        sampled.odd_columns,
    });
    try expect(sampled.odd_columns == 0);
    try expect(@abs(share.mass() / m - 1.0) < 0.01);
    try expect(length3(share.centre() - middle) < 1.0e-3);
    for (0..3) |i| {
        try expect(@abs(got[i][i] / expected[i] - 1.0) < 0.02);
        for (0..3) |j| {
            if (i != j) {
                // A box on its axes has no products of inertia.
                try expect(@abs(got[i][j]) < 1.0e-3 * expected[0]);
            }
        }
    }
}

/// A body segment as the anthropometry tables cut it, and what fraction of the body's mass two of the
/// most used tables give it: de Leva (1996, adult male) and Dempster (1955, as tabulated by Winter).
/// They disagree by more than 20 % on the thigh and the trunk - they cut the hip in different places -
/// so a segment is judged against the nearer of the two.
const Segment = struct {
    name: []const u8,
    /// Where the segment starts, by bone name: every mesh joint belongs to the first of these found
    /// walking up its parents, so fingers join the hand and helper joints the limb they sit on.
    roots: []const []const u8,
    de_leva: f32,
    dempster: f32,
};

const anthropometry = [_]Segment{
    .{ .name = "head and neck", .roots = &.{ "Head", "Neck" }, .de_leva = 0.0694, .dempster = 0.081 },
    .{
        .name = "trunk",
        .roots = &.{ "Hips", "Spine", "Spine1", "Spine2", "Spine3", "LeftShoulder", "RightShoulder" },
        .de_leva = 0.4346,
        .dempster = 0.497,
    },
    .{ .name = "upper arm", .roots = &.{"LeftArm"}, .de_leva = 0.0271, .dempster = 0.028 },
    .{ .name = "forearm", .roots = &.{"LeftForeArm"}, .de_leva = 0.0162, .dempster = 0.016 },
    .{ .name = "hand", .roots = &.{"LeftHand"}, .de_leva = 0.0061, .dempster = 0.006 },
    .{ .name = "thigh", .roots = &.{"LeftUpLeg"}, .de_leva = 0.1416, .dempster = 0.100 },
    .{ .name = "shank", .roots = &.{"LeftLeg"}, .de_leva = 0.0433, .dempster = 0.0465 },
    .{ .name = "foot", .roots = &.{ "LeftFoot", "LeftToeBase" }, .de_leva = 0.0137, .dempster = 0.0145 },
};

/// The right side's segment roots: named so that walking up from a right-hand finger stops at the
/// right hand rather than running on into the trunk.
const right_roots = [_][]const u8{
    "RightArm", "RightForeArm", "RightHand", "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase",
};

/// The first bone at or above mesh joint `j` that starts a segment, by name - or null for none.
fn segmentRoot(mesh: Mesh, j: usize) ?[]const u8 {
    var at: i32 = @intCast(j);
    while (at >= 0) : (at = mesh.joint_parents[@intCast(at)]) {
        const name: []const u8 = mesh.joint_names[@intCast(at)];
        for (anthropometry) |segment| {
            for (segment.roots) |root| {
                if (std.mem.eql(u8, name, root)) {
                    return root;
                }
            }
        }
        for (right_roots) |root| {
            if (std.mem.eql(u8, name, root)) {
                return root;
            }
        }
    }
    return null;
}

/// One of the tables' segments, as a measured body weighs it: every share whose segment root is one of
/// the segment's roots, merged.
fn segmentShare(mesh: Mesh, body: BodyVolume, segment: Segment) Share {
    var share: Share = .{};
    for (body.shares, 0..) |joint_share, j| {
        const root: []const u8 = segmentRoot(mesh, j) orelse continue;
        for (segment.roots) |wanted| {
            if (std.mem.eql(u8, root, wanted)) {
                share.merge(joint_share);
            }
        }
    }
    return share;
}

/// Group a measured body's shares into the tables' segments and compare: prints each segment's share of
/// the mass against de Leva and Dempster, checks that every segment's inertia is physically possible, and
/// says which segments land beyond 20 % of BOTH tables.
fn compareWithTables(mesh: Mesh, body: BodyVolume, total: f32) ![anthropometry.len]bool {
    var beyond: [anthropometry.len]bool = @splat(false);
    for (anthropometry, 0..) |segment, index| {
        var share: Share = .{};
        for (body.shares, 0..) |joint_share, j| {
            const root: []const u8 = segmentRoot(mesh, j) orelse continue;
            for (segment.roots) |wanted| {
                if (std.mem.eql(u8, root, wanted)) {
                    share.merge(joint_share);
                }
            }
        }
        const fraction: f32 = share.mass() / total;
        const off_de_leva: f32 = fraction / segment.de_leva - 1.0;
        const off_dempster: f32 = fraction / segment.dempster - 1.0;
        const near: bool = @abs(off_de_leva) <= 0.2 or @abs(off_dempster) <= 0.2;
        const inertia: [3][3]f32 = share.inertia();
        // Any real body's inertia obeys the triangle inequality on its diagonal, in any axes:
        // I_xx + I_yy - I_zz is twice the integral of z^2 dm, which cannot be negative.
        const realisable: bool = inertia[0][0] + inertia[1][1] >= inertia[2][2] and
            inertia[1][1] + inertia[2][2] >= inertia[0][0] and inertia[2][2] + inertia[0][0] >= inertia[1][1] and
            inertia[0][0] > 0.0 and inertia[1][1] > 0.0 and inertia[2][2] > 0.0;
        report.print("  {s:<14} {d:6.2} kg = {d:5.2} % (de Leva {d:5.2}, {d:4.0} %; " ++
            "Dempster {d:5.2}, {d:4.0} %){s}\n", .{
            segment.name,
            share.mass(),
            fraction * 100.0,
            segment.de_leva * 100.0,
            off_de_leva * 100.0,
            segment.dempster * 100.0,
            off_dempster * 100.0,
            if (near) "" else "   <-- beyond 20 % of both",
        });
        beyond[index] = !near;
        try expect(realisable);
    }
    return beyond;
}

test "robot_geno: R5 - Geno's mass and inertia, from its own volume" {
    const gpa: Allocator = std.testing.allocator;
    var mesh: Mesh = try readMesh(gpa, mesh_bin);
    defer mesh.deinit(gpa);
    var body: BodyVolume = try measureVolume(gpa, mesh, volume_step, .skin_weights);
    defer body.deinit(gpa);

    const whole: Share = body.whole();
    var low: f32 = 1.0e9;
    var high: f32 = -1.0e9;
    for (mesh.positions) |p| {
        low = @min(low, p[1]);
        high = @max(high, p[1]);
    }
    const height: f32 = high - low;
    const total: f32 = whole.mass();
    report.print("\n  R5 Geno: {d:.3} m tall, {d:.1} litres, {d:.1} kg at {d:.0} kg/m^3 (BMI {d:.1}); " ++
        "{d} columns, {d} odd\n", .{
        height,
        whole.volume * 1000.0,
        total,
        density,
        total / (height * height),
        body.columns_hit,
        body.odd_columns,
    });

    const beyond: [anthropometry.len]bool = try compareWithTables(mesh, body, total);
    // THE KNOWN ANSWER, as far as it holds: about 70 kg at Geno's height (60 - a lean build), and the
    // skin closed well enough that almost no column had to drop a crossing (none did).
    try expect(total > 56.0 and total < 84.0);
    try expect(float(body.odd_columns) < 0.02 * float(body.columns_hit));
    // Six of the eight segments land within 20 % of a published table. The UPPER ARM and the FOOT come
    // out 30-45 % heavier than both - and the R5b test shows it is not the partition: cut at the joints
    // the tables' own way, they weigh the same. It is Geno's build. Pinned here exactly, so a NEW
    // deviation fails this test.
    for (anthropometry, beyond) |segment, off| {
        const expected_off: bool = std.mem.eql(u8, segment.name, "upper arm") or std.mem.eql(u8, segment.name, "foot");
        try expect(off == expected_off);
    }
}

test "robot_geno: R5b - cut the tables' way, and what it shows about Geno's build" {
    const gpa: Allocator = std.testing.allocator;
    var mesh: Mesh = try readMesh(gpa, mesh_bin);
    defer mesh.deinit(gpa);
    var by_skin: BodyVolume = try measureVolume(gpa, mesh, volume_step, .skin_weights);
    defer by_skin.deinit(gpa);
    var by_planes: BodyVolume = try measureVolume(gpa, mesh, volume_step, .joint_planes);
    defer by_planes.deinit(gpa);

    // The planes only move flesh from one body to its neighbour: the body as a whole cannot change.
    const total: f32 = by_planes.whole().mass();
    try expect(@abs(by_planes.whole().volume - by_skin.whole().volume) < 1.0e-9);
    // Every sample now sits on a BODY - no finger or helper joint keeps a share of its own.
    for (by_planes.shares, 0..) |share, j| {
        if (!isBody(mesh.joint_names[j])) {
            try expect(share.volume == 0.0);
        }
    }

    report.print("\n  R5b, cut at the joints ({d:.1} kg):\n", .{total});
    const beyond: [anthropometry.len]bool = try compareWithTables(mesh, by_planes, total);
    // THE FINDING. Cut the tables' own way, six of the eight segments land within 20 % of a table - and
    // the two that do not are the SAME two as with the skin weights, at nearly the same weight. However
    // the body is cut at the joints, then, those two stay heavy: the partition is not the cause. Geno's
    // upper arms and feet ARE heavier, as a share of the body, than the adults the tables measured - a
    // stylised character's build - and the robot keeps Geno's body, because the robot is meant to BE Geno.
    for (anthropometry, beyond) |segment, off| {
        const expected_off: bool = std.mem.eql(u8, segment.name, "upper arm") or std.mem.eql(u8, segment.name, "foot");
        try expect(off == expected_off);
    }
    for (anthropometry) |segment| {
        const heavy: bool = std.mem.eql(u8, segment.name, "upper arm") or std.mem.eql(u8, segment.name, "foot");
        if (!heavy) {
            continue;
        }
        const by_weights: f32 = segmentShare(mesh, by_skin, segment).mass();
        const by_cuts: f32 = segmentShare(mesh, by_planes, segment).mass();
        report.print("  {s}: {d:.2} kg by the skin weights, {d:.2} kg cut at the joints\n", .{
            segment.name,
            by_weights,
            by_cuts,
        });
        try expect(@abs(by_cuts / by_weights - 1.0) < 0.05);
    }
}

/// Read a whole file under the working directory - for the tests that use the tracking set in `assets/`,
/// which `@embedFile` cannot reach from here.
fn readAsset(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

test "robot_geno: R6 - joint ranges, from the tracking set's four clips" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    // The library: every capture we have on Geno's own skeleton. (The stumble exists only on LaFAN's
    // ORIGINAL 22-joint skeleton, whose rotations mean something else, so it cannot join.)
    const paths = [_][]const u8{
        "assets/lafan1/walk1_subject2.bvh",
        "assets/lafan1/run1_subject2.bvh",
        "assets/lafan1/dance1_subject2.bvh",
        "assets/lafan1/fallAndGetUp2_subject2.bvh",
    };
    var files: [paths.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (files[0..loaded]) |file| {
        gpa.free(file);
    };
    for (paths, 0..) |path, k| {
        files[k] = readAsset(gpa, threaded.io(), path) catch return error.SkipZigTest;
        loaded += 1;
    }
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    const ranges: []Range = try measureRanges(gpa, bind, &files);
    defer gpa.free(ranges);

    report.print("\n  R6 over {d} frames: joint, total and swing (limit / max), twist band [limits] (extremes)\n", .{
        ranges[0].frames,
    });
    for (ranges) |range| {
        report.print("  {s:<13} total {d:5.1} / {d:5.1}  swing {d:5.1} / {d:5.1}  twist [{d:6.1}, {d:6.1}] " ++
            "({d:6.1}, {d:6.1}){s}\n", .{
            range.name,
            range.total_limit,
            range.total_max,
            range.swing_limit,
            range.swing_max,
            range.twist_low,
            range.twist_high,
            range.twist_min,
            range.twist_max,
            if (range.excess() > 2.0) "   <-- a tail past 2 deg" else "",
        });
    }

    // Every joint was measured on every frame of the library.
    for (ranges) |range| {
        try expect(range.frames == 1200 + 1200 + 1800 + 1080);
    }
    // THE KNOWN ANSWER, from anatomy: a knee bends well past a right angle in a get-up (kneeling,
    // squatting) and no human knee folds past about 165 degrees; an elbow bends past 60 degrees in a
    // dance and a run, and stops short of 165 too. If the swing were not the bend, these would say so.
    for (ranges) |range| {
        const knee: bool = std.mem.eql(u8, range.name, "LeftLeg") or std.mem.eql(u8, range.name, "RightLeg");
        const elbow: bool = std.mem.eql(u8, range.name, "LeftForeArm") or std.mem.eql(u8, range.name, "RightForeArm");
        if (knee) {
            try expect(range.swing_max > 90.0 and range.swing_max < 165.0);
        }
        if (elbow) {
            try expect(range.swing_max > 60.0 and range.swing_max < 165.0);
        }
    }
}

test "robot_geno: R6b, R6c, R7 - the model: assembled in the bind pose, standing on a floor, copying a capture" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const paths = [_][]const u8{
        "assets/lafan1/walk1_subject2.bvh",
        "assets/lafan1/run1_subject2.bvh",
        "assets/lafan1/dance1_subject2.bvh",
        "assets/lafan1/fallAndGetUp2_subject2.bvh",
    };
    var files: [paths.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (files[0..loaded]) |file| {
        gpa.free(file);
    };
    for (paths, 0..) |path, k| {
        files[k] = readAsset(gpa, threaded.io(), path) catch return error.SkipZigTest;
        loaded += 1;
    }
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var mesh: Mesh = try readMesh(gpa, mesh_bin);
    defer mesh.deinit(gpa);
    var masses: BodyVolume = try measureVolume(gpa, mesh, volume_step, .joint_planes);
    defer masses.deinit(gpa);
    const ranges: []Range = try measureRanges(gpa, bind, &files);
    defer gpa.free(ranges);

    const xml: []u8 = try writeModel(gpa, bind, mesh, masses, ranges);
    defer gpa.free(xml);

    // R8a, PART 1: THE MODEL AS A FIXTURE. The stored model must be this one, byte for byte. If it is missing
    // or stale, it is rewritten here and the test fails once - so a changed model always arrives as a diff.
    const stored: ?[]u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch null;
    defer if (stored) |bytes| gpa.free(bytes);
    const current: bool = if (stored) |bytes| std.mem.eql(u8, bytes, xml) else false;
    if (!current) {
        const file: std.Io.File = try std.Io.Dir.cwd().createFile(threaded.io(), model_fixture_path, .{});
        defer file.close(threaded.io());
        try file.writeStreamingAll(threaded.io(), xml);
        report.print("\n  R8a: {s} was {s} - rewritten from writeModel; review the diff and run again\n", .{
            model_fixture_path,
            if (stored == null) "missing" else "stale",
        });
    }
    try expect(current);

    // Through the engine's whole import path, exactly as a page would load a robot.
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    // Room for a whole body's contacts and joint limits at once, as the engine's other humanoid tests give.
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .max_contacts = 256,
    });
    defer imported.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &imported.model);
    defer data.deinit();
    @memcpy(data.pos, imported.model.qpos0);
    @memset(data.vel, 0);
    data.stage = .stale;
    rbt.kinematics(&imported.model, &data);

    // THE KNOWN ANSWER: at rest, every body stands where Geno's bind pose puts its joint (turned z-up).
    var worst: f32 = 0.0;
    for (body_names) |name| {
        const b: u32 = imported.bodyIndex(name) orelse return error.BodyMissingFromModel;
        const expected: Vec = rotate(y_up_to_z_up, bind.at(name) orelse return error.BodyMissingFromPose);
        worst = @max(worst, length3(data.body_xpos[b] - expected));
    }
    // And the body's whole mass arrived, spread over the bodies.
    var total: f32 = 0.0;
    for (imported.model.body_mass) |mass| {
        total += mass;
    }
    report.print("\n  R6b: {d} bytes of MJCF, {d} bodies; at rest every body within {e:.1} m " ++
        "of the bind pose; " ++
        "{d:.2} kg in the model (the body: {d:.2})\n", .{
        xml.len,
        body_names.len,
        worst,
        total,
        masses.whole().mass(),
    });
    try expect(worst < 1.0e-3);
    // Every pair of shapes that overlaps at rest is excluded - among them the three that meet across
    // shapeless bodies (the chest with each upper arm, and with Neck1), so at least those.
    report.print("  R6c: {d} pairs of shapes overlap at rest, and never collide\n", .{
        imported.model.exclude_pairs.len,
    });
    try expect(imported.model.exclude_pairs.len >= 3);
    // The shapes are massless, so the body's measured mass is the model's, to the gram.
    try expect(@abs(total - masses.whole().mass()) < 0.05);

    // EVERY SHAPE WHERE THE FITTER PUT IT. The engine places a shape from its body's pose and the shape's
    // own place in that body; at rest that must land on the fitted shape itself (turned z-up) - its
    // centre, and for a capsule its radius. Found by name in both the parsed robot and the built model.
    var shape_worst: f32 = 0.0;
    var placed: usize = 0;
    for (shapes.geoms) |fitted| {
        const carrier: []const u8 = carrierOf(fitted.bone);
        const b: u32 = imported.bodyIndex(carrier) orelse return error.ShapeBodyMissing;
        const parsed: mjcf.Body = for (robot.bodies) |candidate| {
            if (std.mem.eql(u8, candidate.name, carrier)) {
                break candidate;
            }
        } else return error.ShapeBodyNotParsed;
        const geom: mjcf.Geom = robot.geoms[parsed.geom_start];
        const at: Vec = data.body_xpos[b] + rotate(data.body_xrot[b], geom.pos);
        const centre: Vec = switch (fitted.shape) {
            .capsule => vec(
                0.5 * (fitted.a[0] + fitted.b[0]),
                0.5 * (fitted.a[1] + fitted.b[1]),
                0.5 * (fitted.a[2] + fitted.b[2]),
            ),
            .box => vec(fitted.a[0], fitted.a[1], fitted.a[2]),
        };
        shape_worst = @max(shape_worst, length3(at - rotate(y_up_to_z_up, centre)));
        if (fitted.shape == .capsule) {
            try expect(@abs(geom.size[0] - fitted.radius) < 1.0e-5);
        }
        placed += 1;
    }
    report.print("  R6b: {d} shapes placed by the engine, every centre within {e:.1} m of the fit\n", .{
        placed,
        shape_worst,
    });
    try expect(placed == shapes.geoms.len);
    try expect(shape_worst < 1.0e-3);

    // -- THE STANDING GUARD (standing rule 7): in a world with a floor, Geno stays ON it. --
    //
    // No actions - no servo, nothing - so the ragdoll crumples, and "still standing" is not the question.
    // The question is whether this world HAS a floor that holds, because a world without one passes many
    // tests while every number measured in it is about a body in free fall. So the answer is chosen to be
    // loud: after 30 frames, half a second, free fall would have carried the ankles 1.2 m BELOW the floor;
    // with a floor, no body's origin goes below it at all.
    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    // The floor is a static box whose top face is z = 0. (The model's own floor plane is for readers of
    // the file; the dynamics engine only collides through this world.) A millimetre of convex radius, as
    // the bridge's own tests use.
    const floor_shape: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(20, 20, 0.5), .convex_radius = 0.001 },
    });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, 0, -0.5),
        .rotation = qidentity(),
        .motion_type = .static,
    });
    // Geno's bind soles sit 4.5 mm below its floor (R3), so lift the root 5 mm and let it settle. First,
    // prove the free joint's third coordinate IS the root's height, rather than assume the layout.
    const hips_height: f32 = rotate(y_up_to_z_up, bind.at("Hips") orelse return error.NoHips)[2];
    try expect(@abs(data.pos[2] - hips_height) < 1.0e-4);
    data.pos[2] += 0.005;
    rbt.forward(&imported.model, &data);
    const root: u32 = imported.bodyIndex("Hips") orelse return error.NoRootBody;
    const start_height: f32 = data.body_xpos[root][2];

    var bridge: robot_physics.Bridge = try .init(gpa, &world, &imported.model, &data, 256);
    defer bridge.deinit(&world);
    bridge.listen(&world);
    const dt: f32 = imported.model.opt.timestep;
    const steps_per_frame: usize = @max(int(usize, (1.0 / 60.0) / dt + 0.5), 1);
    var touched: bool = false;
    for (0..30 * steps_per_frame) |_| {
        try bridge.sync(&world, &imported.model, &data);
        try zimrphysics.step(&world, dt);
        bridge.harvest(&data);
        if (data.contact_count > 0) {
            touched = true;
        }
        rbt.step(&imported.model, &data);
    }
    rbt.forward(&imported.model, &data);
    var lowest: f32 = 1.0e9;
    var finite: bool = true;
    for (body_names) |name| {
        const b: u32 = imported.bodyIndex(name) orelse return error.BodyMissingFromModel;
        const z: f32 = data.body_xpos[b][2];
        lowest = @min(lowest, z);
        finite = finite and z == z;
    }
    const end_height: f32 = data.body_xpos[root][2];
    report.print("  R6b guard: {d} steps; contacts {s}; the hips went from {d:.3} to {d:.3} m; " ++
        "lowest body origin " ++
        "{d:.3} m\n", .{ 30 * steps_per_frame, if (touched) "yes" else "NONE", start_height, end_height, lowest });
    try expect(finite);
    // It met the floor...
    try expect(touched);
    // ...the floor held: every body's origin is above it (free fall would put the ankles 1.2 m under)...
    try expect(lowest > 0.0);
    // ...and nothing launched it. (This needs the model's contact exclusions: the shapes overlap by design
    // at every joint, and across the shapeless clavicles and neck those overlaps are not adjacent bodies -
    // collided, they throw the robot metres up. `writeExclusions` names them.)
    try expect(end_height < start_height + 0.05);

    // -- R7: RETARGETING IS A COPY, on all four clips, through the engine's own kinematics. --
    //
    // Two claims, because the captures are not quite rigid: they stretch the thighs and the upper arms by up
    // to 3 mm from frame to frame (the knees' and elbows' own translations move), and no rigid robot can copy
    // a bone that changes length. So: (1) against the capture's kinematics recomputed with the ROBOT's rigid
    // bone lengths, the copy must be exact; (2) against the capture as recorded, what remains is its stretch.
    var worst_rigid: f32 = 0.0;
    var worst_recorded: f32 = 0.0;
    var worst_turn: f32 = 0.0;
    var frames_copied: usize = 0;

    // THE SOLE PROBE. Its axis comes from the REST pose, where the sole is flat by construction: whatever
    // the box's own axes, its local normal is the world's up carried back through the rest pose, and a
    // frame's tilt is how far that normal has turned from up. It is read on the walk's first frame - a
    // quiet stance before the first step. (The get-up's final frame is not one: its feet are turned 90
    // degrees from their rest, so it does not end flat-footed.)
    var rest: rbt.Data = try rbt.Data.init(gpa, &imported.model);
    defer rest.deinit();
    @memcpy(rest.pos, imported.model.qpos0);
    @memset(rest.vel, 0);
    rest.stage = .stale;
    rbt.kinematics(&imported.model, &rest);
    const feet = [_][]const u8{ "LeftFoot", "RightFoot" };
    var foot_body: [feet.len]u32 = undefined;
    var foot_box: [feet.len]Quat = undefined;
    var foot_normal: [feet.len]Vec = undefined;
    for (feet, 0..) |foot, k| {
        foot_body[k] = imported.bodyIndex(foot) orelse return error.NoFoot;
        const parsed: mjcf.Body = for (robot.bodies) |candidate| {
            if (std.mem.eql(u8, candidate.name, foot)) {
                break candidate;
            }
        } else return error.FootNotParsed;
        foot_box[k] = robot.geoms[parsed.geom_start].rot;
        foot_normal[k] = rotate(conjugate(qmul(rest.body_xrot[foot_body[k]], foot_box[k])), vec(0, 0, 1));
    }
    var worst_tilt: f32 = 0.0;

    for (files, 0..) |clip_bytes, clip_index| {
        var clip: codecs.bvh.Data = try codecs.bvh.parse(gpa, clip_bytes, null);
        defer clip.deinit();
        var copier: Copier = try .init(gpa, &imported, bind, clip);
        defer copier.deinit(gpa);
        const count: usize = clip.joints.len;
        const places: []Vec = try gpa.alloc(Vec, count);
        defer gpa.free(places);
        const turns: []Quat = try gpa.alloc(Quat, count);
        defer gpa.free(turns);
        // The robot's rigid bone lengths: every joint's translation as the bind file has it.
        const rigid: []Vec = try gpa.alloc(Vec, count);
        defer gpa.free(rigid);
        for (clip.joints, 0..) |joint, j| {
            rigid[j] = if (bind.find(joint.name)) |b| bind.bones[b].offset else vec(0, 0, 0);
        }
        const recorded_places: []Vec = try gpa.alloc(Vec, count);
        defer gpa.free(recorded_places);
        const rigid_places: []Vec = try gpa.alloc(Vec, count);
        defer gpa.free(rigid_places);
        const world_turns: []Quat = try gpa.alloc(Quat, count);
        defer gpa.free(world_turns);
        // Which clip joint each body is, found once.
        var joint_of: [body_names.len]usize = undefined;
        for (body_names, 0..) |name, n| {
            joint_of[n] = for (clip.joints, 0..) |candidate, c| {
                if (std.mem.eql(u8, candidate.name, name)) {
                    break c;
                }
            } else return error.CaptureMissesBody;
        }
        for (0..clip.frame_count) |f| {
            captureFrame(clip, f, places, turns);
            // The capture's kinematics twice: as recorded, and with the robot's rigid bones. The root's own
            // translation is the motion itself, so both take it from the frame.
            for (clip.joints, 0..) |joint, j| {
                if (joint.parent >= 0) {
                    const up: usize = @intCast(joint.parent);
                    recorded_places[j] = recorded_places[up] + rotate(world_turns[up], places[j]);
                    rigid_places[j] = rigid_places[up] + rotate(world_turns[up], rigid[j]);
                    world_turns[j] = qmul(world_turns[up], turns[j]);
                } else {
                    recorded_places[j] = places[j];
                    rigid_places[j] = places[j];
                    world_turns[j] = turns[j];
                }
            }
            copier.write(turns, places[copier.root_joint], data.pos);
            data.stage = .stale;
            rbt.kinematics(&imported.model, &data);
            for (body_names, 0..) |name, n| {
                const b: u32 = imported.bodyIndex(name) orelse return error.BodyMissingFromModel;
                const j: usize = joint_of[n];
                const at: Vec = data.body_xpos[b];
                worst_rigid = @max(worst_rigid, length3(at - rotate(y_up_to_z_up, rigid_places[j])));
                worst_recorded = @max(worst_recorded, length3(at - rotate(y_up_to_z_up, recorded_places[j])));
                worst_turn = @max(worst_turn, degreesApart(data.body_xrot[b], qmul(y_up_to_z_up, world_turns[j])));
            }
            if (clip_index == 0 and f == 0) {
                for (0..feet.len) |k| {
                    const normal: Vec = rotate(qmul(data.body_xrot[foot_body[k]], foot_box[k]), foot_normal[k]);
                    const across: f32 = @sqrt(normal[0] * normal[0] + normal[1] * normal[1]);
                    worst_tilt = @max(worst_tilt, degFromRad(atan2Rad(across, normal[2])));
                }
            }
            frames_copied += 1;
        }
    }

    report.print("  R7: {d} frames of four clips copied; every body turned as captured to {e:.1} deg;\n" ++
        "  positions: exact against rigid bones to {e:.1} m; against the recorded capture {d:.4} m (its stretch);\n" ++
        "  the walk's standing soles tilt {d:.1} deg\n", .{
        frames_copied,
        worst_turn,
        worst_rigid,
        worst_recorded,
        worst_tilt,
    });
    // THE KNOWN ANSWER. The copy is exact: every body turned as captured, and placed where the capture's own
    // kinematics puts it with the robot's rigid bones - on every frame of all four clips...
    try expect(worst_turn < 1.0e-2);
    try expect(worst_rigid < 1.0e-4);
    // ...what remains against the recorded capture is the capture's stretch, never more (3.3 mm at most)...
    try expect(worst_recorded < 3.5e-3);
    // ...and a standing frame's soles are flat.
    try expect(worst_tilt < 5.0);

    // R8a, PART 2: THE CLIPS BY COPY. Each tracking clip becomes the task's clip - every frame the engine's
    // own position vector - and no frame's residual exceeds the capture's own stretch (R7b: 3.2 mm).
    const expected_frames = [_]usize{ 1200, 1200, 1800, 1080 };
    var worst_residual: f32 = 0.0;
    for (files, expected_frames) |clip_bytes, frame_count| {
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, clip_bytes, null);
        defer capture.deinit();
        var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        defer clip.deinit();
        try expect(clip.frame_count == frame_count);
        try expect(clip.nq == imported.model.qpos0.len);
        for (clip.residual) |r| {
            worst_residual = @max(worst_residual, r);
        }
    }
    report.print("  R8a: four clips copied into the task's format ({d} numbers a frame); " ++
        "worst residual {d:.4} m\n", .{
        imported.model.qpos0.len,
        worst_residual,
    });
    try expect(worst_residual < 3.5e-3);
}

/// How far a robot's joints are from a target: the error in velocity space over every degree of freedom but
/// the root's six (the robot's place in the world, which a servo does not - cannot - drive).
const JointError = struct {
    /// The error's length, over every joint degree of freedom.
    total: f32,
    /// The largest single degree of freedom's.
    worst: f32,
};

fn jointError(
    model: *const rbt.Model,
    d: *rbt.Data,
    goal: []const f32,
    space: []f32,
) JointError {
    rbt.differentiatePos(model, space, d.pos, goal, 1.0);
    var total: f32 = 0.0;
    var worst: f32 = 0.0;
    for (space[6..]) |e| {
        total += e * e;
        worst = @max(worst, @abs(e));
    }
    return .{ .total = @sqrt(total), .worst = worst };
}

test "robot_geno: R8a part 3 - the task's servo drives all 23 of Geno's ball joints to a copied pose" {
    // THE SERVO, UNCHANGED. `robot_track.pdTorques` asks a stable, critically damped spring for an
    // ACCELERATION on every degree of freedom, then realises it through the model's own inverse dynamics -
    // so one frequency serves every joint, and each joint's torque comes from the body's measured inertia
    // (a thigh and a hand, servoed alike). Nothing in it knows which robot it drives. Proven here on Geno:
    // loaded from its fixture, as the task will load it, with gravity and contacts away so that only the
    // servo acts. From the bind pose toward the walk's first frame, copied, every joint must close in on
    // its target within half a second.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const walk_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(walk_bytes);

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    const frame_time: f32 = 1.0 / 60.0;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, 0),
        .timestep = frame_time,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    @memcpy(data.pos, m.qpos0);
    @memset(data.vel, 0);
    data.stage = .stale;

    // The target: the walk's first frame, copied onto Geno.
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var walk: codecs.bvh.Data = try codecs.bvh.parse(gpa, walk_bytes, null);
    defer walk.deinit();
    var copier: Copier = try .init(gpa, &imported, bind, walk);
    defer copier.deinit(gpa);
    const places: []Vec = try gpa.alloc(Vec, walk.joints.len);
    defer gpa.free(places);
    const turns: []Quat = try gpa.alloc(Quat, walk.joints.len);
    defer gpa.free(turns);
    captureFrame(walk, 0, places, turns);
    const target: []f32 = try gpa.dupe(f32, m.qpos0);
    defer gpa.free(target);
    copier.write(turns, places[copier.root_joint], target);

    // The servo's working space, as the task allocates it.
    const nv: usize = m.nv;
    const accel: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(accel);
    const scratch: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(scratch);
    const dense: []f32 = try gpa.alloc(f32, nv * nv);
    defer gpa.free(dense);
    const full: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(full);
    const torque: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(torque);
    const root: usize = 6;

    const start: JointError = jointError(m, &data, target, scratch);
    for (0..30) |_| {
        rbt.forward(m, &data);
        rbt.biasForce(m, &data);
        robot_track.pdTorques(m, &data, target, .{}, frame_time, accel, scratch, dense, full, torque);
        @memcpy(data.applied_force, torque);
        rbt.step(m, &data);
    }
    const end: JointError = jointError(m, &data, target, scratch);
    report.print("\n  R8a servo: {d} ball joints, {d} degrees of freedom; joint error {d:.3} rad -> {d:.5} rad " ++
        "in 0.5 s (worst dof {d:.5} rad)\n", .{ body_names.len - 1, nv - root, start.total, end.total, end.worst });
    try expect(end.total == end.total);
    // THE KNOWN ANSWER: every joint within 1 % of its target in half a second, and no degree of freedom off
    // by more than a hundredth of a radian. (It once stalled at a third of the way: the engine applied a
    // ball joint's range to the quaternion's first number - fixed where ranges are assigned, in robot.zig.)
    try expect(end.total < 0.01 * start.total);
    try expect(end.worst < 0.01);
}

test "robot_geno: R9 and R10, measured early - Geno held and servoed on a floor, headless" {
    // What the `geno_track` page shows, measured instead of watched. Nothing is asserted beyond sanity yet:
    // these are the numbers R9 and R10 will be judged by, taken before the reference is lifted per frame
    // (R8) and before joints have cone limits (E1).
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);

    const names = [_][]const u8{ "walk", "get-up" };
    const paths = [_][]const u8{ "assets/lafan1/walk1_subject2.bvh", "assets/lafan1/fallAndGetUp2_subject2.bvh" };
    for (names, paths, 0..) |name, path, k| {
        const bytes: []u8 = readAsset(gpa, threaded.io(), path) catch return error.SkipZigTest;
        defer gpa.free(bytes);
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
        defer capture.deinit();
        var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        defer clip.deinit();
        for ([_]ServoRun.Law{ .floating, .consistent }) |law| {
            var run: ServoRun = undefined;
            try run.init(gpa, &imported, floor_friction);
            defer run.deinit();
            run.law = law;

            if (k == 0) {
                // R9 EARLY: hold the BIND pose - symmetric, both feet flat, statically stable - for two
                // seconds. Lifted 5 mm, as the bind soles sit 4.5 mm below the floor.
                const stance: []f32 = try gpa.dupe(f32, imported.model.qpos0);
                defer gpa.free(stance);
                stance[2] += 0.005;
                @memcpy(run.data.pos, stance);
                @memset(run.data.vel, 0);
                run.data.stage = .stale;
                rbt.forward(run.model, &run.data);
                const at_start: Vec = run.data.body_xpos[run.hips];
                // (f) WHICH JOINT GIVES WAY FIRST: every ball joint's angle from its target, each frame, and
                // the frame it first passes 5 degrees - the order names the mechanism.
                const joints: usize = body_names.len - 1;
                var dof_of: [body_names.len - 1]u32 = undefined;
                for (body_names[1..], 0..) |body, n| {
                    const b: u32 = imported.bodyIndex(body) orelse return error.BodyMissingFromModel;
                    dof_of[n] = for (run.model.jnt_body, 0..) |owner, j| {
                        if (owner == b) {
                            break run.model.jnt_dof_adr[j];
                        }
                    } else return error.BodyWithoutJoint;
                }
                var gave_way: [body_names.len - 1]?usize = @splat(null);
                for (0..120) |frame| {
                    _ = try run.stepToward(stance, 1.0 / 60.0);
                    rbt.differentiatePos(run.model, run.scratch, run.data.pos, stance, 1.0);
                    for (0..joints) |n| {
                        const e: []const f32 = run.scratch[dof_of[n]..][0..3];
                        const angle: f32 = degFromRad(@sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2]));
                        if (gave_way[n] == null and angle > 5.0) {
                            gave_way[n] = frame;
                        }
                    }
                    if (law == .floating and (frame + 1) % 15 == 0) {
                        report.print("    t {d:.2} s: hips {d:.3} m from the start\n", .{
                            float(frame + 1) / 60.0,
                            length3(run.data.body_xpos[run.hips] - at_start),
                        });
                    }
                }
                if (law == .floating) {
                    // The first five joints past 5 degrees, in the order they went.
                    var reported: usize = 0;
                    for (0..120) |frame| {
                        for (0..joints) |n| {
                            if (gave_way[n] == frame and reported < 5) {
                                report.print("    {s} passed 5 deg at {d:.2} s\n", .{
                                    body_names[n + 1],
                                    float(frame) / 60.0,
                                });
                                reported += 1;
                            }
                        }
                    }
                }
                const drift: f32 = length3(run.data.body_xpos[run.hips] - at_start);
                // Do the FEET slide? Each foot's travel along the floor over the 2 s, at the floor's friction
                // and at eight times it - the same slide at both means friction is not reaching the solve.
                if (law == .floating) {
                    for ([_]f32{ floor_friction, 8.0 * floor_friction }) |friction| {
                        var probe: ServoRun = undefined;
                        try probe.init(gpa, &imported, friction);
                        defer probe.deinit();
                        @memcpy(probe.data.pos, stance);
                        @memset(probe.data.vel, 0);
                        probe.data.stage = .stale;
                        rbt.forward(probe.model, &probe.data);
                        const foot: u32 = imported.bodyIndex("LeftFoot") orelse return error.NoFoot;
                        const foot_start: Vec = probe.data.body_xpos[foot];
                        for (0..120) |_| {
                            _ = try probe.stepToward(stance, 1.0 / 60.0);
                        }
                        const slid: Vec = (probe.data.body_xpos[foot] - foot_start) * vec(1, 1, 0);
                        report.print("    floor friction {d:.1}: the left foot slides {d:.3} m along the floor " ++
                            "in 2 s\n", .{ friction, length3(slid) });
                    }
                }
                report.print("\n  R9 early ({t}): the bind pose held 2 s - the hips drift {d:.4} m\n", .{
                    law,
                    drift,
                });
                try expect(drift == drift);
            }

            // R10 EARLY: start every second through the clip; how long does the servo keep up?
            var total: f32 = 0.0;
            var starts: usize = 0;
            var shortest: f32 = 1.0e9;
            var longest: f32 = 0.0;
            var from: usize = 0;
            while (from + 60 < clip.frame_count) : (from += 60) {
                const seconds: f32 = float(try run.survive(&clip, from)) * clip.frame_time;
                total += seconds;
                starts += 1;
                shortest = @min(shortest, seconds);
                longest = @max(longest, seconds);
            }
            report.print("  R10 early ({t}), {s}: mean time to failure {d:.2} s " ++
                "(shortest {d:.2}, longest {d:.2})\n", .{
                law,
                name,
                total / float(starts),
                shortest,
                longest,
            });
            try expect(starts > 0 and total == total);
        }
    }
}

test "robot_geno: S1 tuning sweep - which settings keep the get-up up longest" {
    // A slow test - a minute of simulation - run when the tuning is revisited (`-Dslow-tests`).
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    // Each setting judged by the get-up's mean time to failure over 17 starts through the clip. Last run:
    // STIFFNESS - stable all the way to 120 Hz on a 60 Hz step (the spring is evaluated at the step's end,
    // through inverse dynamics), but 20 Hz keeps the get-up up longest (3.02 s; 40-120 Hz: 2.5-2.6 s) - a
    // stiffer servo follows the reference harder where it cannot be followed.
    // The model's knobs are set on the parsed model in memory, so the search
    // leaves the fixture alone; the winner is then written into `writeModel` and `servo_gains`.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const getup_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/fallAndGetUp2_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(getup_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, getup_bytes, null);
    defer capture.deinit();

    const Setting = struct {
        armature: f32,
        damping: f32,
        frequency: f32,
        max_acceleration: f32,
        friction: f32,
    };
    const settings = [_]Setting{
        .{ .armature = 0.01, .damping = 0.2, .frequency = 20, .max_acceleration = 3000, .friction = 0.5 },
        .{ .armature = 0.01, .damping = 0.2, .frequency = 20, .max_acceleration = 3000, .friction = 1.0 },
        .{ .armature = 0.01, .damping = 0.2, .frequency = 20, .max_acceleration = 3000, .friction = 2.0 },
        .{ .armature = 0.01, .damping = 0.2, .frequency = 20, .max_acceleration = 3000, .friction = 4.0 },
    };
    for (settings) |setting| {
        for (robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = setting.armature;
                joint.damping = setting.damping;
            }
        }
        var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
            .gravity = vec(0, 0, -9.81),
            .timestep = 1.0 / 60.0,
            .max_contacts = 256,
        });
        defer imported.deinit();
        var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        defer clip.deinit();
        var run: ServoRun = undefined;
        try run.init(gpa, &imported, setting.friction);
        defer run.deinit();
        run.gains.frequency = setting.frequency;
        run.gains.max_acceleration = setting.max_acceleration;
        var total: f32 = 0.0;
        var starts: usize = 0;
        var from: usize = 0;
        while (from + 60 < clip.frame_count) : (from += 60) {
            total += float(try run.survive(&clip, from)) * clip.frame_time;
            starts += 1;
        }
        report.print("  sweep: floor friction {d:.1}, armature {d:.2} damping {d:.1} " ++
            "frequency {d:.0} Hz max accel {d:.0}: " ++
            "get-up MTTF {d:.2} s\n", .{
            setting.friction,
            setting.armature,
            setting.damping,
            setting.frequency,
            setting.max_acceleration,
            total / float(starts),
        });
        try expect(total == total);
    }
}

test "robot_geno: a restart is a clean start - the same start ends the same way, to the bit" {
    // Determinism, the known answer: run a stretch of the walk, restart at the same frame, run it again -
    // every body must end exactly where it did. Anything carried across the restart (a warm start, a cached
    // contact) shows up here as a difference.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const walk_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(walk_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var walk: codecs.bvh.Data = try codecs.bvh.parse(gpa, walk_bytes, null);
    defer walk.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, walk);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();

    var ends: [2][]f32 = undefined;
    for (&ends) |*end| {
        try run.start(&clip, 0);
        for (1..46) |f| {
            _ = try run.step(&clip, f);
        }
        end.* = try gpa.dupe(f32, run.data.pos);
    }
    defer for (ends) |end| {
        gpa.free(end);
    };
    var differ: usize = 0;
    for (ends[0], ends[1]) |a, b| {
        if (a != b) {
            differ += 1;
        }
    }
    report.print("\n  determinism: 45 steps of the walk, twice from a restart - {d} of {d} numbers differ\n", .{
        differ,
        ends[0].len,
    });
    try expect(differ == 0);
}

/// One way to train SuperTrack on the held T-pose - the knobs that decide whether it is stable.
const HoldRecipe = struct {
    /// Noisy servo steps before any learning: they fill the ring and set the world model's normaliser, so
    /// they must reach the states the policy will later reach - falls included.
    prefill_steps: usize,
    prefill_noise: f32,
    world_rate: f32,
    world_pretrain: usize,
    rounds: usize,
    world_per_round: usize,
    policy_per_round: usize,
    policy_rate: f32,
    /// Exploration while acting, as a fraction of the policy's authority.
    explore: f32,
    /// How many frames the policy is trained through the world model at once - how far ahead it can see its
    /// correction pay off. A topple takes about a second to unfold.
    window: usize = 8,
    /// The penalty on the size of an action.
    w_action: f32 = 0.1,
    /// The penalty on an action's jump from one window step to the next (CAPS temporal smoothness).
    w_smooth: f32 = 0.0,
};

/// What a trial ends with: the losses, and each controller's mean time to failure in the real simulator.
const HoldResult = struct {
    world_loss: f32,
    policy_loss: f32,
    /// Mean time to failure in the real simulator.
    servo: f32,
    policy: f32,
    /// Inside the world model, on held-out windows: the tracking loss with no action and with the policy's,
    /// and the policy's mean action there. Equal losses and a tiny action: the model sees nothing to gain by
    /// acting. A lower loss with the policy but no gain in reality: the model is wrong about what acting does.
    in_model_zero: f32,
    in_model_policy: f32,
    in_model_action: f32,
    /// In the real simulator over `judge_steps`: falls, and the mean tracking reward (DReCon's - higher is
    /// closer to the reference). Falls alone cannot rank two controllers that both stay up.
    servo_falls: u64 = 0,
    policy_falls: u64 = 0,
    servo_reward: f32 = 0.0,
    policy_reward: f32 = 0.0,
    policy_action: f32 = 0.0,
    policy_jitter: f32 = 0.0,
};

/// Judged in the real simulator: a fresh fleet (seed 99), the policy acting noise-free - or zero actions,
/// the servo alone - for `steps`, counting falls and averaging the tracking reward. What `Learner.judge`
/// does, plus the reward it does not report.
/// A controller judged: falls, the mean tracking reward, and - for a policy - how big its actions are and how
/// much they JUMP from one frame to the next (both mean |.| per freedom, in action units). A policy that looks
/// like it is exploding is one whose actions jump: the servo chases a target that moves by the reach every frame.
const Quality = struct { falls: u64, reward: f32, action: f32 = 0.0, jitter: f32 = 0.0 };

fn judgeQuality(
    learner: *latent.Learner,
    steps: usize,
    servo_only: bool,
) !Quality {
    const trained: *robot_track.Fleet = learner.fleet;
    var options: robot_track.Fleet.Options = trained.options;
    options.seed = 99;
    const judge_fleet: *robot_track.Fleet = try .init(learner.gpa, trained.m, trained.clips, options);
    defer judge_fleet.deinit();
    learner.fleet = judge_fleet;
    defer learner.fleet = trained;
    var sum: f64 = 0.0;
    const actions: []f32 = learner.fleet_actions;
    const before: []f32 = try learner.gpa.alloc(f32, actions.len);
    defer learner.gpa.free(before);
    @memset(before, 0.0);
    var size: f64 = 0.0;
    var jump: f64 = 0.0;
    for (0..steps) |k| {
        if (servo_only) {
            @memset(actions, 0.0);
            _ = judge_fleet.step(actions);
        } else {
            learner.act(1, 0.0);
        }
        for (actions, before) |a, b| {
            size += @abs(a);
            if (k > 0) {
                jump += @abs(a - b);
            }
        }
        @memcpy(before, actions);
        for (judge_fleet.rewards[0..options.envs]) |r| {
            sum += r;
        }
    }
    const count: f64 = float(steps * actions.len);
    return .{
        .falls = judge_fleet.failed,
        .reward = @floatCast(sum / float(steps * options.envs)),
        .action = @floatCast(size / count),
        .jitter = @floatCast(jump / count),
    };
}

/// One trial: Geno's model from its fixture, a 10 s held T-pose, the task's fleet and the CPU learner, both
/// unchanged, trained by `recipe` from `seed`, then judged against the servo alone.
/// What a trial trains on: the held T-pose, or the first `seconds` of a capture - and, optionally, one armature
/// for every joint (2 is what let Geno stand).
const TrialSource = struct {
    capture: ?[]const u8 = null,
    /// Where the cut starts in the capture, and how long it runs.
    from_seconds: f32 = 0.0,
    seconds: f32 = 10.0,
    /// The fleet's action reach, radians per unit.
    action_scale: f32 = 0.3,
    armature: ?f32 = null,
};

fn holdTrial(
    gpa: Allocator,
    model_text: []const u8,
    recipe: HoldRecipe,
    seed: u64,
) !HoldResult {
    return trackTrial(gpa, model_text, recipe, seed, .{});
}

fn trackTrial(
    gpa: Allocator,
    model_text: []const u8,
    recipe: HoldRecipe,
    seed: u64,
    source: TrialSource,
) !HoldResult {
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    if (source.armature) |armature| {
        for (robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = armature;
            }
        }
    }
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var stance: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_bvh, null);
    defer stance.deinit();
    var held: dance.Clip = if (source.capture) |bytes| blk: {
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
        defer capture.deinit();
        var copied: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        // The cut: `seconds` from `from_seconds` - learning focused where it is wanted.
        const skip: usize = @trunc(source.from_seconds / copied.frame_time);
        if (skip > 0) {
            const nq: usize = copied.nq;
            const keep: usize = copied.frame_count - skip;
            std.mem.copyForwards(f32, copied.targets[0 .. keep * nq], copied.targets[skip * nq ..][0 .. keep * nq]);
            std.mem.copyForwards(f32, copied.residual[0..keep], copied.residual[skip..][0..keep]);
            std.mem.copyForwards(u32, copied.residual_body[0..keep], copied.residual_body[skip..][0..keep]);
            copied.frame_count = keep;
        }
        copied.frame_count = @min(copied.frame_count, int(usize, source.seconds / copied.frame_time));
        // Every frame resting ON the floor, not in it (R8a part 5): the fleet's reward and observations use
        // the reference's absolute root height, and a reference sunk into the floor punishes standing on it.
        var probe: rbt.Data = try rbt.Data.init(gpa, &imported.model);
        defer probe.deinit();
        _ = restClipOnFloor(&imported.model, &probe, &copied, 0.001);
        break :blk copied;
    } else try heldClip(gpa, &imported, bind, stance, source.seconds, 1.0 / 60.0);
    defer held.deinit();

    const envs: usize = 8;
    const fleet: *robot_track.Fleet = try .init(gpa, &imported.model, &.{&held}, .{
        .envs = envs,
        .capacity = 256,
        .action_scale = source.action_scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
        .seed = seed,
    });
    defer fleet.deinit();
    const noise: []f32 = try gpa.alloc(f32, envs * robot_track.actionSize(&imported.model));
    defer gpa.free(noise);
    var rng: std.Random.DefaultPrng = .init(seed +% 4);
    for (0..recipe.prefill_steps) |_| {
        for (noise) |*a| {
            a.* = recipe.prefill_noise * rng.random().floatNorm(f32);
        }
        _ = fleet.step(noise);
    }
    const learner: *latent.Learner = try .init(gpa, fleet, .{
        .hidden = 64,
        .window = recipe.window,
        .batch = 16,
        .rate = recipe.policy_rate,
        .w_action = recipe.w_action,
        .w_smooth = recipe.w_smooth,
        .seed = seed,
        .world = .{ .hidden = 64, .steps = 8, .batch = 16, .rate = recipe.world_rate, .seed = seed },
    });
    defer learner.deinit();
    var world_loss: f32 = 0.0;
    var policy_loss: f32 = 0.0;
    for (0..recipe.world_pretrain) |_| {
        if (try learner.world.trainStep(fleet)) |loss| {
            world_loss = loss;
        }
    }
    for (0..recipe.rounds) |_| {
        learner.act(32, recipe.explore);
        for (0..recipe.world_per_round) |_| {
            if (try learner.world.trainStep(fleet)) |loss| {
                world_loss = loss;
            }
        }
        for (0..recipe.policy_per_round) |_| {
            if (try learner.trainPolicy()) |loss| {
                policy_loss = loss;
            }
        }
    }
    const zero: latent.InModel = learner.modelLoss(100, 7, false, recipe.window);
    const acting: latent.InModel = learner.modelLoss(100, 7, true, recipe.window);
    const servo_quality: Quality = try judgeQuality(learner, judge_steps, true);
    const policy_quality: Quality = try judgeQuality(learner, judge_steps, false);
    return .{
        .servo_falls = servo_quality.falls,
        .policy_falls = policy_quality.falls,
        .servo_reward = servo_quality.reward,
        .policy_reward = policy_quality.reward,
        .policy_action = policy_quality.action,
        .policy_jitter = policy_quality.jitter,
        .world_loss = world_loss,
        .policy_loss = policy_loss,
        // Judged over 20 s: `judge` divides environment-steps by failures, so it moves only in whole failures -
        // over its 300-step default, 31 falls read 1.29 s and 32 read 1.25, and a policy delaying every fall
        // by a tenth of a second could not show. Four times the window, four times the resolution.
        .servo = (try learner.judge(judge_steps, 99, true)) orelse 0.0,
        .policy = (try learner.judge(judge_steps, 99, false)) orelse 0.0,
        .in_model_zero = zero.loss,
        .in_model_policy = acting.loss,
        .in_model_action = acting.action,
    };
}

/// How long each controller is judged in the real simulator, in frames (20 s).
const judge_steps: usize = 1200;

/// The recipe first tried (Sep 23): unstable across seeds - seed 1 held 2.67 s, seed 2 0.43.
const first_recipe: HoldRecipe = .{
    .prefill_steps = 150,
    .prefill_noise = 0.1,
    .world_rate = 1.0e-3,
    .world_pretrain = 1000,
    .rounds = 60,
    .world_per_round = 8,
    .policy_per_round = 8,
    .policy_rate = 3.0e-4,
    .explore = 0.3,
};

/// S2's first stabilising recipe: a normaliser that has seen falls (a longer, noisier prefill), a gentler
/// world model that keeps up (a lower rate, twice the updates), and a slower policy (so it exploits the
/// model's mistakes less quickly). Budgeted for two seeds to a call.
const steady_recipe: HoldRecipe = .{
    .prefill_steps = 400,
    .prefill_noise = 0.3,
    .world_rate = 3.0e-4,
    .world_pretrain = 600,
    .rounds = 30,
    .world_per_round = 16,
    .policy_per_round = 8,
    .policy_rate = 1.0e-4,
    .explore = 0.3,
};

test "robot_geno: S0 - SuperTrack learns to hold Geno's T-pose, headless" {
    // The first SuperTrack test on Geno: the CPU learner and the task's fleet, both unchanged - the fleet
    // takes any model and any clip - holding the T-pose, which the servo alone cannot (it tips over). A
    // policy that holds it longer than the servo has learned the balance a spring lacks. Reported, not
    // asserted: one seed is an anecdote, so each recipe runs over several, and the plan keeps the table.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    for (hold_seeds) |seed| {
        const result: HoldResult = try holdTrial(gpa, model_text, hold_recipe, seed);
        report.print("\n  S0 seed {d}: world loss {d:.3}, policy loss {d:.3}; " ++
            "time to failure: servo {d:.2} s, " ++
            "policy {d:.3} s ({d:.0} and {d:.0} falls);\n" ++
            "  in the model: tracking loss {d:.4} doing nothing, {d:.4} with the policy, " ++
            "its mean action {d:.4}", .{
            seed,
            result.world_loss,
            result.policy_loss,
            result.servo,
            result.policy,
            float(judge_steps * 8) / (result.servo * 60.0),
            float(judge_steps * 8) / (result.policy * 60.0),
            result.in_model_zero,
            result.in_model_policy,
            result.in_model_action,
        });
        try expect(result.world_loss == result.world_loss and result.policy_loss == result.policy_loss);
    }
}

/// The stable world of `steady_recipe` - its losses settled (world 0.119) where the first recipe's diverged -
/// with the policy given its pace back: `steady_recipe` alone left it at zero (it tied the servo exactly).
const committed_recipe: HoldRecipe = .{
    .prefill_steps = 400,
    .prefill_noise = 0.3,
    .world_rate = 3.0e-4,
    .world_pretrain = 600,
    .rounds = 30,
    .world_per_round = 16,
    .policy_per_round = 16,
    .policy_rate = 3.0e-4,
    .explore = 0.3,
};

/// The stable world again, and a policy that can SEE its correction pay off: a 32-frame window (half a
/// second, the SuperTrack paper's) instead of 8 - within 0.13 s no correction to a topple pays, so a stable
/// model rightly taught the policy to do nothing - and the learner's default action penalty (0.01).
const farsighted_recipe: HoldRecipe = .{
    .prefill_steps = 400,
    .prefill_noise = 0.3,
    .world_rate = 3.0e-4,
    .world_pretrain = 600,
    .rounds = 20,
    .world_per_round = 16,
    .policy_per_round = 8,
    .policy_rate = 3.0e-4,
    .explore = 0.3,
    .window = 32,
    .w_action = 0.01,
};

/// Which recipe the T-pose test runs, and over which seeds. (`first_recipe` stays as the baseline row.)
const hold_recipe: HoldRecipe = farsighted_recipe;
comptime {
    _ = first_recipe;
    _ = steady_recipe;
    _ = committed_recipe;
}
const hold_seeds = [_]u64{1};

test "robot_geno: S2b - SAC holds Geno's T-pose, model-free" {
    // The critic-based model-free baseline: robot_gym's SAC agent, unchanged, acting in DReCon's layer on
    // Geno (its watched and actuated bodies, its action filter) on the held T-pose. No world model anywhere:
    // if early training cannot trust one, this family must carry it. One update per fleet step - one per
    // eight transitions - is what one CPU core affords; DroQ's twenty per transition would not fit here.
    // Judged like PPO: episode length with the mean action, against the servo alone, over 1,200 steps.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const model_text: []u8 = readAsset(gpa, io, model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var stance: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_bvh, null);
    defer stance.deinit();
    var held: dance.Clip = try heldClip(gpa, &imported, bind, stance, 10.0, 1.0 / 60.0);
    defer held.deinit();

    const envs: usize = 8;
    const fleet: *robot_track.Fleet = try .init(gpa, m, &.{&held}, .{
        .envs = envs,
        .capacity = 16,
        .gains = servo_gains,
        .floor_friction = floor_friction,
    });
    defer fleet.deinit();
    var subset: robot_policy.Subset = try robot_policy.subsetFor(
        gpa,
        m,
        imported.names,
        &drecon_watched,
        &drecon_actuated,
    );
    defer subset.deinit(gpa);
    var controller: robot_policy.Controller = try .init(gpa, m, subset, envs, .{});
    defer controller.deinit();
    const n_obs: usize = robot_policy.observationSize(subset);
    const n_act: usize = subset.dofs;
    const agent: *robot_gym.SacAgent = try .init(gpa, n_obs, n_act, .{ .hidden = 64, .batch = 128, .warmup = 1000 });
    defer agent.deinit();
    var sim_state: robot_track.State = try .init(gpa, m.nbody);
    defer sim_state.deinit(gpa);
    var views: robot_policy.Views = try .init(gpa, m);
    defer views.deinit(gpa);
    const obs: []f32 = try gpa.alloc(f32, envs * n_obs);
    defer gpa.free(obs);
    const next: []f32 = try gpa.alloc(f32, envs * n_obs);
    defer gpa.free(next);
    const applied: []f32 = try gpa.alloc(f32, envs * n_act);
    defer gpa.free(applied);

    const Observer = struct {
        fn all(
            model: *rbt.Model,
            f: *robot_track.Fleet,
            sub: robot_policy.Subset,
            c: *robot_policy.Controller,
            sim: *robot_track.State,
            seen: *robot_policy.Views,
            out: []f32,
            size: usize,
        ) void {
            for (0..f.options.envs) |env| {
                robot_track.stateOf(model, &f.data[env], sim);
                const row: []f32 = out[env * size ..][0..size];
                const clip: *const dance.Clip = f.clips[f.clip_of[env]];
                robot_policy.observeFrom(model, sub, f, clip, f.frame[env], sim.*, seen, c.lastAction(env), row);
            }
        }
    };
    Observer.all(m, fleet, subset, &controller, &sim_state, &views, obs, n_obs);
    const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    var transitions: usize = 0;
    while (true) {
        const elapsed: i96 = std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (@divTrunc(elapsed, 1_000_000) > sac_budget_ms) {
            break;
        }
        for (0..envs) |env| {
            agent.act(obs[env * n_obs ..][0..n_obs], applied[env * n_act ..][0..n_act], false);
        }
        _ = fleet.step(controller.apply(applied));
        Observer.all(m, fleet, subset, &controller, &sim_state, &views, next, n_obs);
        for (0..envs) |env| {
            try agent.remember(
                obs[env * n_obs ..][0..n_obs],
                applied[env * n_act ..][0..n_act],
                fleet.rewards[env],
                next[env * n_obs ..][0..n_obs],
                fleet.dones[env],
            );
            if (fleet.dones[env]) {
                controller.forget(env);
            }
        }
        transitions += envs;
        try agent.update();
        @memcpy(obs, next);
    }

    // Judged: the mean action, then the servo alone, each over 1,200 steps of the same fleet.
    var lengths: [2]f32 = undefined;
    for (0..2) |k| {
        var ended: usize = 0;
        var frames: usize = 0;
        var running: [8]usize = @splat(0);
        for (0..1200) |_| {
            Observer.all(m, fleet, subset, &controller, &sim_state, &views, obs, n_obs);
            for (0..envs) |env| {
                const slot: []f32 = applied[env * n_act ..][0..n_act];
                if (k == 0) {
                    agent.act(obs[env * n_obs ..][0..n_obs], slot, true);
                } else {
                    @memset(slot, 0.0);
                }
            }
            _ = fleet.step(controller.apply(applied));
            for (0..envs) |env| {
                running[env] += 1;
                if (fleet.dones[env]) {
                    ended += 1;
                    frames += running[env];
                    running[env] = 0;
                    controller.forget(env);
                }
            }
        }
        lengths[k] = if (ended > 0) float(frames) / float(ended) else 1200.0;
    }
    report.print("\n  SAC on Geno's T-pose, {d} s ({d} transitions): judged {d:.1} frames an episode | " ++
        "servo alone {d:.1}\n", .{ @divTrunc(sac_budget_ms, 1000), transitions, lengths[0], lengths[1] });
    try expect(lengths[0] == lengths[0]);
}

/// The SAC trial's training time, in milliseconds.
const sac_budget_ms: i96 = 110_000;

test "robot_geno: S2c - the T-pose HOLDS: standing armature and the capture-point reflex" {
    // The standing result, guarded. In this servo a joint's strength is its free-flight inertia (torque =
    // inertia x the spring's acceleration), so `standing_armature` on every joint makes each as strong as the
    // load it carries standing; the reflex leans the body back through the ankles when its capture point
    // drifts ahead of the feet. Neither alone holds (armature alone ~1.2 s, the reflex alone ~1.0 s). The
    // reflex has a window: 2-4 holds, 8 over-corrects into a wobble. Known answer: gain 3 holds all 10 s.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var stance: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_bvh, null);
    defer stance.deinit();
    var held: dance.Clip = try heldClip(gpa, &imported, bind, stance, 10.0, 1.0 / 60.0);
    defer held.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    for ([_]f32{ 0.0, 2.0, 3.0, 4.0, 8.0 }) |gain| {
        run.balance_gain = gain;
        const seconds: f32 = float(try run.survive(&held, 0)) * held.frame_time;
        report.print("{s}  standing armature, reflex gain {d:.0}: the T-pose held {d:.2} s\n", .{
            if (gain == 0.0) "\n" else "",
            gain,
            seconds,
        });
        if (gain == 3.0) {
            try expect(seconds > 9.5);
        }
    }
}

test "robot_geno: the dance's first 5 s - the servo alone, with light joints and with armature 2" {
    // Armature 2 everywhere let Geno stand; the dance is FAST, and heavier joints swing slower. Before training
    // on either robot: the servo alone on the dance's first 5 s, starting every half second.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    for ([_]f32{ joint_armature, 2.0 }) |armature| {
        var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
        defer doc.deinit();
        var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
        defer robot.deinit();
        for (robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = armature;
            }
        }
        var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
            .gravity = vec(0, 0, -9.81),
            .timestep = 1.0 / 60.0,
            .max_contacts = 256,
        });
        defer imported.deinit();
        var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        defer clip.deinit();
        clip.frame_count = 300;
        var run: ServoRun = undefined;
        try run.init(gpa, &imported, floor_friction);
        defer run.deinit();
        for ([_]bool{ false, true }) |feedforward| {
            run.feedforward = feedforward;
            var total: f32 = 0.0;
            var starts: usize = 0;
            var from: usize = 0;
            while (from + 30 < clip.frame_count) : (from += 30) {
                total += float(try run.survive(&clip, from)) * clip.frame_time;
                starts += 1;
            }
            report.print("{s}  dance, first 5 s, armature {d:.2}, {s}: the servo alone keeps up " ++
                "{d:.2} s on average ({d} starts)\n", .{
                if (armature == joint_armature and !feedforward) "\n" else "",
                armature,
                if (feedforward) "feedforward" else "zero-velocity damping",
                total / float(starts),
                starts,
            });
            try expect(total == total);
        }
    }
}

test "robot_geno: S0 dance - SuperTrack on the dance's first 5 s" {
    // Back to SuperTrack, on the dance - the first 5 s only (Simon) - with the stable recipe, judged over 20 s.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    // First result (Sep 23, seed 1): the servo alone NEVER failed in 20 s x 8 environments by the fleet's fall
    // criterion (judge returns null: printed as 0) - the policy failed 10 times (16 s). In the model it cut the
    // tracking loss 19%: exploitation again. The dance needs a tracking-QUALITY judge, not only falls.
    const result: HoldResult = try trackTrial(gpa, model_text, farsighted_recipe, 1, .{
        .capture = dance_bytes,
        .seconds = 5.0,
        .armature = dance_armature,
    });
    report.print("\n  S0 dance (first 5 s, armature {?d:.2}): world loss {d:.3}, policy loss {d:.3};\n" ++
        "  real simulator, {d} steps x 8: servo {d} falls, mean reward {d:.4} | " ++
        "policy {d} falls, mean reward {d:.4};\n" ++
        "  in the model {d:.4} doing nothing, {d:.4} with the policy\n", .{
        dance_armature,
        result.world_loss,
        result.policy_loss,
        judge_steps,
        result.servo_falls,
        result.servo_reward,
        result.policy_falls,
        result.policy_reward,
        result.in_model_zero,
        result.in_model_policy,
    });
    try expect(result.world_loss == result.world_loss);
}

/// The armature the dance trial's robot gets - chosen by the servo-alone comparison above: armature 2 costs
/// the dance nothing (1.26 s against 1.24) and lets the robot stand.
const dance_armature: ?f32 = 2.0;

test "robot_geno: D1 - save and restore: two rollouts from one moment are identical" {
    // The sampling planner's foundation: every candidate plan must start from the SAME moment. Known answers:
    // two 20-step rollouts from one restore are bit-identical; and the drift from the run that never stopped
    // (restore forgets warm starts and cached contacts) is measured, to know what the planner's rollouts cost.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var moment: ServoRun.Snapshot = try .init(gpa, run.model);
    defer moment.deinit(gpa);
    const nq: usize = run.model.nq;
    const outcomes: []f32 = try gpa.alloc(f32, 3 * nq);
    defer gpa.free(outcomes);

    try run.start(&clip, 0);
    for (0..30) |f| {
        _ = try run.step(&clip, f);
    }
    run.save(&moment);
    // The run that never stopped, then two rollouts from the restored moment.
    for (0..3) |k| {
        if (k > 0) {
            run.restore(&moment);
        }
        for (30..50) |f| {
            _ = try run.step(&clip, f);
        }
        @memcpy(outcomes[k * nq ..][0..nq], run.data.pos);
    }
    var identical: usize = 0;
    var drift: f32 = 0.0;
    for (0..nq) |i| {
        if (outcomes[nq + i] == outcomes[2 * nq + i]) {
            identical += 1;
        }
    }
    for (0..3) |axis| {
        drift = @max(drift, @abs(outcomes[axis] - outcomes[nq + axis]));
    }
    report.print("\n  D1 restore: {d} of {d} numbers identical across two rollouts; the restored rollout's root " ++
        "drifts {d:.2} mm from the run that never stopped, after 20 steps\n", .{ identical, nq, drift * 1000.0 });
    try expect(identical == nq);
}

test "robot_geno: a restart rests on the floor - no jump, no spin" {
    // Simon, on the phone: "he jumps up and spins quickly on resets". A copied pose puts feet INTO the floor,
    // and the contact solver throws the overlap out in one step. Known answers, on the walk's first frame:
    // the penetration before the lift; the lowest point after it exactly 1 mm clear; and the first ten
    // steps' largest vertical speed and spin rate without and with the lift.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    // The page's own walk - the clip Simon was watching.
    const walk_bytes: []u8 = readAsset(gpa, threaded.io(), "examples/geno_track/walk.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(walk_bytes);
    var walk: codecs.bvh.Data = try codecs.bvh.parse(gpa, walk_bytes, null);
    defer walk.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, walk);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    for ([_]bool{ false, true }) |lifted| {
        run.rest_on_floor = lifted;
        try run.start(&clip, 0);
        const lowest: f32 = rbt.lowestPoint(run.model, &run.data);
        var jump: f32 = 0.0;
        var spin: f32 = 0.0;
        for (0..10) |f| {
            _ = try run.step(&clip, f);
            jump = @max(jump, run.data.vel[2]);
            spin = @max(spin, length3(vec(run.data.vel[3], run.data.vel[4], run.data.vel[5])));
        }
        report.print("{s}  restart {s}: lowest point {d:.1} mm; first ten steps: up to {d:.2} m/s upward, " ++
            "{d:.2} rad/s of spin\n", .{
            if (lifted) "" else "\n",
            if (lifted) "rested on the floor" else "as copied",
            lowest * 1000.0,
            jump,
            spin,
        });
        if (lifted) {
            try expect(@abs(lowest - 0.001) < 1.0e-5);
        }
    }
}

test "robot_geno: a launch at a random dance frame - every body onto the next frame" {
    // Simon: reset at a random frame of the dance and verify the guy is LAUNCHED correctly. Known answer: the
    // launch velocities, integrated for one frame, carry every body onto the reference's next frame - to float
    // precision, since the velocity IS the engine's tangent difference of the two frames. Then the physical
    // launch - one real step, gravity, contacts and servo - against the same next frame, and the same launched
    // at rest: a moving body launched still lags by its own speed times a frame.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    const m: *const rbt.Model = run.model;
    var probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer probe.deinit();
    var next: rbt.Data = try rbt.Data.init(gpa, m);
    defer next.deinit();
    var before_frame: rbt.Data = try rbt.Data.init(gpa, m);
    defer before_frame.deinit();
    var rng: std.Random.DefaultPrng = .init(7);
    var worst_kinematic: f32 = 0.0;
    for (0..5) |_| {
        const f: usize = 1 + rng.random().uintLessThan(usize, clip.frame_count - 3);
        const Variant = struct { moving: bool, feedforward: bool, collide: bool = true };
        const variants = [_]Variant{
            .{ .moving = true, .feedforward = true },
            .{ .moving = true, .feedforward = false },
            .{ .moving = false, .feedforward = false },
            .{ .moving = true, .feedforward = true, .collide = false },
        };
        var misses: [4]struct { worst: f32, mean: f32, body: usize } = undefined;
        for (variants, 0..) |variant, k| {
            const moving: bool = variant.moving;
            run.feedforward = variant.feedforward;
            run.collide = variant.collide;
            try run.start(&clip, f);
            if (!moving) {
                @memset(run.data.vel, 0.0);
            }
            // The reference's next frame, with the same lift onto the floor.
            @memcpy(next.pos, clip.targets[(f + 1) * clip.nq ..][0..clip.nq]);
            next.pos[2] += run.lift;
            next.stage = .stale;
            rbt.forward(m, &next);
            if (moving) {
                // The kinematic known answer: the launch velocity is the backward difference INTO frame f, so
                // one frame of it BACKWARD lands every body on frame f-1 (lifted like f).
                @memcpy(probe.pos, run.data.pos);
                rbt.integratePos(m, probe.pos, run.data.vel, -clip.frame_time);
                probe.stage = .stale;
                rbt.forward(m, &probe);
                @memcpy(before_frame.pos, clip.targets[(f - 1) * clip.nq ..][0..clip.nq]);
                before_frame.pos[2] += run.lift;
                before_frame.stage = .stale;
                rbt.forward(m, &before_frame);
                for (1..m.nbody) |b| {
                    worst_kinematic = @max(worst_kinematic, length3(probe.body_xpos[b] - before_frame.body_xpos[b]));
                }
            }
            // The physical launch: one real step.
            _ = try run.step(&clip, f + 1);
            var worst: f32 = 0.0;
            var sum: f32 = 0.0;
            var worst_body: usize = 0;
            for (1..m.nbody) |b| {
                const miss: f32 = length3(run.data.body_xpos[b] - next.body_xpos[b]);
                sum += miss;
                if (miss > worst) {
                    worst = miss;
                    worst_body = b;
                }
            }
            misses[k] = .{ .worst = worst, .mean = sum / float(m.nbody - 1), .body = worst_body };
        }
        report.print("{s}  dance frame {d}, one real step's miss of the next frame (mean / worst, mm): " ++
            "feedforward {d:.1} / {d:.1} ({s}) | zero-velocity servo {d:.1} / {d:.1} | launched at rest " ++
            "{d:.1} / {d:.1} | feedforward, no contacts {d:.1} / {d:.1} ({s})\n", .{
            if (worst_kinematic == 0.0) "\n" else "",
            f,
            misses[0].mean * 1000.0,
            misses[0].worst * 1000.0,
            imported.names[misses[0].body],
            misses[1].mean * 1000.0,
            misses[1].worst * 1000.0,
            misses[2].mean * 1000.0,
            misses[2].worst * 1000.0,
            misses[3].mean * 1000.0,
            misses[3].worst * 1000.0,
            imported.names[misses[3].body],
        });
    }
    report.print("  the launch velocities, integrated one frame BACKWARD, land every body within {d:.4} mm " ++
        "of the frame before\n", .{
        worst_kinematic * 1000.0,
    });
    try expect(worst_kinematic < 1.0e-4);
}

test "robot_geno: the whole 30 s dance - the servo alone, strong joints, with and without feedforward" {
    // With standing armature and clean starts (rested on the floor, launched with the reference's velocity),
    // the servo alone keeps up with the dance's first 5 s from every start - a ceiling that hides whether the
    // servo's velocity feedforward helps. So the whole 30 s, a start every 2 s, each run capped by the clip's
    // end: how long it keeps up (hips within 35 cm), and the fraction of starts that reach the end.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    for ([_]bool{ false, true }) |feedforward| {
        run.feedforward = feedforward;
        var total: f32 = 0.0;
        var starts: usize = 0;
        var to_the_end: usize = 0;
        var from: usize = 0;
        while (from + 60 < clip.frame_count) : (from += 120) {
            const frames: usize = try run.survive(&clip, from);
            total += float(frames) * clip.frame_time;
            starts += 1;
            if (from + frames + 1 >= clip.frame_count) {
                to_the_end += 1;
            }
        }
        report.print("{s}  the whole dance, {s}: keeps up {d:.2} s on average; {d} of {d} starts reach the end\n", .{
            if (feedforward) "" else "\n",
            if (feedforward) "feedforward" else "zero-velocity damping",
            total / float(starts),
            to_the_end,
            starts,
        });
        try expect(total == total);
    }
}

test "robot_geno: the dance's contacts - which pairs collide, beyond the feet on the floor" {
    // One real step can throw a limb 20 mm at some dance frames, and 6.7 without contacts - contacts do it.
    // Only pairs overlapping AT REST are excluded, so a dance that crosses an arm over the body collides
    // where the capture's actor did not. Launch at 60 frames across the whole dance, step once, and tally:
    // robot-robot pairs (how often, how deep), and any body but a foot or toe touching the floor.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    const nbody: usize = run.model.nbody;
    const counts: []u32 = try gpa.alloc(u32, nbody * nbody);
    defer gpa.free(counts);
    @memset(counts, 0);
    const deepest: []f32 = try gpa.alloc(f32, nbody * nbody);
    defer gpa.free(deepest);
    @memset(deepest, 0.0);
    const floor_touch: []u32 = try gpa.alloc(u32, nbody);
    defer gpa.free(floor_touch);
    @memset(floor_touch, 0);
    var frames: usize = 0;
    var f: usize = 0;
    while (f + 1 < clip.frame_count) : (f += 30) {
        try run.start(&clip, f);
        _ = try run.step(&clip, f + 1);
        frames += 1;
        for (run.bridge.events[0..run.bridge.event_count]) |event| {
            const a: usize = event.robot_body;
            const b: usize = event.other_body;
            if (b == rbt.world_body) {
                const name: []const u8 = imported.names[a];
                const foot: bool = std.mem.indexOf(u8, name, "Foot") != null or
                    std.mem.indexOf(u8, name, "Toe") != null;
                if (!foot) {
                    floor_touch[a] += 1;
                }
                continue;
            }
            const lo: usize = @min(a, b);
            const hi: usize = @max(a, b);
            counts[lo * nbody + hi] += 1;
            deepest[lo * nbody + hi] = @max(deepest[lo * nbody + hi], event.depth);
        }
    }
    report.print("\n  the dance's self-contacts over {d} launched frames " ++
        "(pair: contact points, deepest mm):\n", .{frames});
    var any: bool = false;
    for (0..nbody) |lo| {
        for (lo + 1..nbody) |hi| {
            const n: u32 = counts[lo * nbody + hi];
            if (n > 0) {
                any = true;
                report.print("    {s} - {s}: {d}, {d:.1} mm\n", .{
                    imported.names[lo],
                    imported.names[hi],
                    n,
                    deepest[lo * nbody + hi] * 1000.0,
                });
            }
        }
    }
    for (0..nbody) |b| {
        if (floor_touch[b] > 0) {
            report.print("    floor - {s}: {d}\n", .{ imported.names[b], floor_touch[b] });
        }
    }
    // What excluding them buys: the servo alone over the whole dance, with the model's exclusions (pairs
    // overlapping at rest) and with every pair found above added (pairs the REFERENCE makes overlap).
    var found: std.ArrayList([2]u32) = .empty;
    defer found.deinit(gpa);
    try found.appendSlice(gpa, imported.model.exclude_pairs);
    for (0..nbody) |lo| {
        for (lo + 1..nbody) |hi| {
            if (counts[lo * nbody + hi] > 0) {
                try found.append(gpa, .{ @intCast(lo), @intCast(hi) });
            }
        }
    }
    const original: []const [2]u32 = imported.model.exclude_pairs;
    defer imported.model.exclude_pairs = original;
    for ([_]bool{ false, true }) |widened| {
        imported.model.exclude_pairs = if (widened) found.items else original;
        var trial: ServoRun = undefined;
        try trial.init(gpa, &imported, floor_friction);
        defer trial.deinit();
        var total: f32 = 0.0;
        var starts: usize = 0;
        var from: usize = 0;
        while (from + 60 < clip.frame_count) : (from += 120) {
            total += float(try trial.survive(&clip, from)) * clip.frame_time;
            starts += 1;
        }
        report.print("  the whole dance, servo alone, {d} excluded pairs: keeps up {d:.2} s on average\n", .{
            imported.model.exclude_pairs.len,
            total / float(starts),
        });
    }
    try expect(frames > 0 and (any or !any));
}

test "robot_geno: the clip's per-frame lift - frames resting on the floor, not in it" {
    // R8a part 5. Known answers: after the lift no frame of the dance pierces the floor; and what it buys - the
    // servo alone over the whole dance (standing armature, clean starts), raw copy against lifted.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer probe.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    for ([_]bool{ false, true }) |lifted| {
        var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
        defer clip.deinit();
        if (lifted) {
            const raise: Raise = restClipOnFloor(m, &probe, &clip, 0.001);
            var deepest: f32 = 1.0;
            for (0..clip.frame_count) |f| {
                @memcpy(probe.pos, clip.targets[f * clip.nq ..][0..clip.nq]);
                probe.stage = .stale;
                rbt.kinematics(m, &probe);
                deepest = @min(deepest, rbt.lowestPoint(m, &probe));
            }
            report.print("  lifted {d} of {d} frames, by up to {d:.1} mm; now the lowest point of any frame " ++
                "is {d:.2} mm above the floor\n", .{
                raise.frames,
                clip.frame_count,
                raise.most * 1000.0,
                deepest * 1000.0,
            });
            try expect(deepest > 0.0009);
        }
        var total: f32 = 0.0;
        var starts: usize = 0;
        var from: usize = 0;
        while (from + 60 < clip.frame_count) : (from += 120) {
            total += float(try run.survive(&clip, from)) * clip.frame_time;
            starts += 1;
        }
        report.print("{s}  the whole dance, servo alone, {s}: keeps up {d:.2} s on average\n", .{
            if (lifted) "" else "\n",
            if (lifted) "clip lifted onto the floor" else "clip as copied",
            total / float(starts),
        });
    }
}

test "robot_geno: D1 - predictive sampling over the true simulator, against the servo alone" {
    // The teacher that cannot exploit: every candidate played out in the real physics. Known answer to beat:
    // the servo alone, from the same starts in the dance, each run capped at `planner_cap` frames.
    // Measured (Sep 24, release): from frames 360/720/1080/1440, capped at 5 s - sigma 0.1: 3.21 s on average,
    // sigma 0.2: 4.43 s, sigma 0.3: all four reach the cap (servo alone 0.92 s). The whole dance from frame 0,
    // one unbroken run: planned 17.05 s, servo alone 6.65 s (about 73 s of CPU) - scored in world positions it
    // ENDED lost (heading 31 deg off, shape 547 mm off); scored shape-first (root frame) + 0.3 x the root's miss:
    // 15.05 s, ending with heading 4 deg off and shape 148 mm off - far truer to the dance, kept.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var lift_probe: rbt.Data = try rbt.Data.init(gpa, &imported.model);
    defer lift_probe.deinit();
    _ = restClipOnFloor(&imported.model, &lift_probe, &clip, 0.001);
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    // One sweep over the offset LIMIT - the reach a policy would need to imitate this teacher.
    for (planner_variants) |variant| {
        const limit: f32 = variant.limit;
        var limited: Planner.Options = planner_options;
        limited.limit = limit;
        limited.mppi = variant.mppi;
        limited.temperature = variant.temperature;
        limited.filter = variant.filter;
        limited.sigma = variant.sigma;
        limited.decimation = variant.decimation;
        limited.markov = variant.markov;
        limited.iterations = variant.iterations;
        limited.height_weight = variant.height_weight;
        limited.up_weight = variant.up_weight;
        limited.height_tolerance = variant.height_tolerance;
        limited.up_tolerance = variant.up_tolerance;
        limited.root_height_weight = variant.root_height_weight;
        if (variant.axis) {
            limited.height_bodies = &axis_bodies;
        }
        limited.posture_gate = variant.posture;
        var planner: Planner = try .init(gpa, &run, &imported, limited);
        defer planner.deinit();
        var servo_total: f32 = 0.0;
        var planned_total: f32 = 0.0;
        for (planner_starts) |from| {
            const servo: usize = @min(try run.survive(&clip, from), planner_cap);
            const planned: usize = try planner.survive(&clip, from, planner_cap);
            servo_total += float(servo) * clip.frame_time;
            planned_total += float(planned) * clip.frame_time;
            // How the planned run ENDED: wandered (the hips far across the floor, the body upright and in shape)
            // or fell (the hips dropped, the shape lost)? Against the clip's frame at the end.
            {
                const m: *const rbt.Model = run.model;
                const g: usize = @min(from + planned, clip.frame_count - 1);
                @memcpy(lift_probe.pos, clip.targets[g * m.nq ..][0..m.nq]);
                lift_probe.stage = .stale;
                rbt.kinematics(m, &lift_probe);
                const hips_off: Vec = run.data.body_xpos[run.hips] - lift_probe.body_xpos[run.hips];
                // The pose in each root's OWN frame - heading removed - and the heading difference itself.
                const sim_root: Quat = run.data.body_xrot[run.hips];
                const ref_root: Quat = lift_probe.body_xrot[run.hips];
                var shape: f32 = 0.0;
                for (1..m.nbody) |b| {
                    const here: Vec = rotate(conjugate(sim_root), run.data.body_xpos[b] - run.data.body_xpos[run.hips]);
                    const there: Vec = rotate(
                        conjugate(ref_root),
                        lift_probe.body_xpos[b] - lift_probe.body_xpos[run.hips],
                    );
                    shape += length3(here - there);
                }
                // Heading: the angle between the two roots' forward directions, projected on the floor (Geno's
                // forward is -y in the engine's z-up world).
                const sim_forward: Vec = rotate(sim_root, vec(0, -1, 0));
                const ref_forward: Vec = rotate(ref_root, vec(0, -1, 0));
                // The yaw of each forward direction on the floor, and their difference folded into [0, 180].
                const sim_yaw: f32 = atan2Rad(sim_forward[1], sim_forward[0]);
                const ref_yaw: f32 = atan2Rad(ref_forward[1], ref_forward[0]);
                var turn: f32 = @abs(sim_yaw - ref_yaw);
                if (turn > pi) {
                    turn = 2.0 * pi - turn;
                }
                const heading: f32 = turn * 180.0 / pi;
                report.print("    at its end (frame {d}): hips {d:.2} m off across the floor, {d:.2} m up/down, " ++
                    "heading {d:.0} deg off; the pose in its own root's frame {d:.0} mm off on average\n", .{
                    g,
                    length3(vec(hips_off[0], hips_off[1], 0.0)),
                    hips_off[2],
                    heading,
                    shape / float(m.nbody - 1) * 1000.0,
                });
            }
            report.print("{s}  D1 from dance frame {d}: servo alone {d:.2} s, planned {d:.2} s (cap {d:.1} s)\n", .{
                if (from == planner_starts[0]) "\n" else "",
                from,
                float(servo) * clip.frame_time,
                float(planned) * clip.frame_time,
                float(planner_cap) * clip.frame_time,
            });
        }
        report.print("  D1 {s}, filter {d:.1}, raw sigma {d:.1}, memoryless {}, iterations {d}, gravity {d:.1} " ++
            "({d} samples x {d} steps, {d} knots, " ++
            "limited to {d:.2} rad): " ++
            "servo alone {d:.2} s on average, planned {d:.2} s\n", .{
            if (variant.mppi) "MPPI" else "predictive sampling",
            variant.filter,
            variant.sigma,
            variant.markov,
            variant.iterations,
            variant.height_weight,
            planner_options.samples,
            planner_options.horizon,
            planner_options.knots,
            @min(limit, 99.0),
            servo_total / float(planner_starts.len),
            planned_total / float(planner_starts.len),
        });
        // What the teacher's actions ask of a student: raw offsets per freedom at its decisions, and applied ones.
        {
            const n: f64 = @floatFromInt(@max(planner.offsets_counted, 1));
            report.print("    its actions, decimation {d}: raw |offset| {d:.3} rad on average " ++
                "(largest {d:.2}), applied " ++
                "{d:.3}; raw past 0.2 / 0.6 / 1.0 rad: {d:.1}% / {d:.1}% / {d:.1}%\n", .{
                variant.decimation,
                planner.raw_sum / n,
                planner.raw_largest,
                planner.applied_sum / n,
                100.0 * @as(f64, @floatFromInt(planner.raw_past[0])) / n,
                100.0 * @as(f64, @floatFromInt(planner.raw_past[1])) / n,
                100.0 * @as(f64, @floatFromInt(planner.raw_past[2])) / n,
            });
        }
        try expect(planned_total == planned_total);
    }
}

/// D1's trial: where in the dance it starts (where the servo alone falls - the first 5 s it already keeps up
/// with), how long a run may last, and the planner's budget.
const planner_starts = [_]usize{ 360, 720, 1080, 1440 };
const planner_cap: usize = 300;
const planner_options: Planner.Options = .{ .samples = 16, .horizon = 15, .knots = 3, .sigma = 0.3 };
/// The planners swept: the offset limit (radians per degree of freedom) and whether MPPI averages the candidates.
/// Measured before (predictive sampling): unlimited 4.74 s, 0.6 rad 4.45 s, 0.3 rad 2.46 s.
/// MPPI at temperature 0.1 (Sep 25): 3.19 s against predictive sampling's 4.67 - averaging 16 DIFFERENT good
/// plans blurs them. The temperature is the dial toward the argmax: at 0.03 MPPI is the best controller yet,
/// 4.88 s - the few best candidates averaged, the lone sample's noise gone.
/// With DReCon's filter (0.2) at the same raw sigma and reach, both halve (Sep 25): predictive sampling 2.05 s,
/// MPPI 2.31 - the filter passes a fifth of each change, so candidates barely differ in what the body receives.
/// A planner acting through the filter must push its RAW offsets harder, as a DReCon policy learns to.
const PlannerVariant = struct {
    limit: f32,
    mppi: bool,
    temperature: f32 = 0.1,
    filter: f32 = 1.0,
    sigma: f32 = 0.3,
    decimation: u32 = 1,
    markov: bool = false,
    iterations: u32 = 1,
    height_weight: f32 = 0.0,
    up_weight: f32 = 0.0,
    height_tolerance: f32 = 0.0,
    up_tolerance: f32 = 0.0,
    root_height_weight: f32 = 0.0,
    axis: bool = false,
    posture: bool = false,
};
/// Pushed twice as hard (raw sigma 0.6, reach 1.2): **5.01 s - the best controller measured**, smooth AND strong;
/// at sigma 1.0 / reach 2.0: 4.12 s. The teacher from here on.
/// On DReCon's clock (a decision every 2 steps): 3.48 s at reach 1.2 - its raw offsets 0.34 rad on average, 56%
/// past 0.2, 21% past 0.6. Simon (Sep 25): the student's scale goes to 0.6 rad a unit (actions in [-1, 1]); so
/// the teacher is capped at 0.6 too, every label expressible.
/// Capped at 0.6 it collapses: 1.34 s (sigma 0.6), 1.46 s (0.4) - through a 0.2 filter at 30 Hz a strong
/// correction NEEDS a large raw command. So the student's raw reach is 1.2 rad (scale 1.2, actions in [-1, 1]).
/// The MEMORYLESS teacher (plans from the filter's state, not a carried plan), 1 and 2 MPPI iterations a decision -
/// against the carried-plan teacher's 3.48 s. Measured (Sep 25): 1 iteration 1.52 s; **2 iterations 3.65 s** - the
/// best teacher on DReCon's clock, and every label a function of what the student observes. D5's teacher.
/// ONE teacher for every clip (Simon, Sep 26): gravity on the body's AXIS only - hips, spine, neck, head - at full
/// weight, unhinged, the task's own model (standing armature). Every body's height halved the dance (1.87 s).
const planner_variants = [_]PlannerVariant{
    .{
        .limit = 1.2,
        .mppi = true,
        .temperature = 0.03,
        .filter = 0.2,
        .sigma = 0.6,
        .decimation = 2,
        .markov = true,
        .iterations = 2,
        .height_weight = 1.0,
        .up_weight = 0.3,
        .axis = true,
        .posture = true,
    },
};

test "robot_geno: D3 data - the planner's steps, recorded in the task's own format" {
    // The planner's real steps into a `robot_track.Replay`, as the fleet records its own. Known answer: a
    // recorded (state, action), restored and stepped with the FLEET's `applyAction`, reproduces the next
    // recorded state - which holds only if the planner's offsets and the task's actions are the same thing.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer probe.deinit();
    _ = restClipOnFloor(m, &probe, &clip, 0.001);
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &imported, planner_options);
    defer planner.deinit();
    var replay: robot_track.Replay = try .init(gpa, m, 1, 256);
    defer replay.deinit();
    const size: usize = robot_track.actionSize(m);
    const action: []f32 = try gpa.alloc(f32, size);
    defer gpa.free(action);
    // One radian per unit of action while recording: the planner's offsets, as they are.
    const scale: f32 = 1.0;
    const recording: Planner.Recording = try planner.record(&clip, 360, 120, &replay, 0, 0, scale, action);
    // Reproduce four recorded steps through the fleet's own action.
    var moment: ServoRun.Snapshot = try .init(gpa, m);
    defer moment.deinit(gpa);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const target: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(target);
    var worst: f32 = 0.0;
    for ([_]u64{ 0, 30, 60, 90 }) |i| {
        if (i + 1 >= recording.frames) {
            continue;
        }
        @memcpy(moment.pos, replay.poseAt(0, i));
        @memcpy(moment.vel, replay.velocityAt(0, i));
        run.restore(&moment);
        const at: usize = replay.frameAt(0, i);
        robot_track.applyAction(m, clip.pose(at + 1), replay.actionAt(0, i), scale, scratch, target);
        _ = try run.stepToward(target, clip.frame_time);
        for (run.data.pos, replay.poseAt(0, i + 1)) |here, recorded| {
            worst = @max(worst, @abs(here - recorded));
        }
    }
    report.print("\n  D3 data: {d} planned steps recorded from dance frame 360; the planner's largest offset " ++
        "{d:.2} rad; four recorded steps reproduced through the task's own action to {e:.1}\n", .{
        recording.frames,
        recording.largest_offset,
        worst,
    });
    try expect(worst < 1.0e-4);
}

test "robot_geno: D3 - does a world model trained on the teacher's data know what actions do?" {
    // D3's claim, tested: a world model trained on the TEACHER's trajectories (the planner - deliberate actions
    // where balance is decided, nothing exploited) knows what an action does better than one trained on the
    // servo's noisy flailing. The yardstick - the action RESPONSE, where exploitation lives: from a state where
    // the teacher acts, its recorded action and the same with one freedom nudged, each stepped in the TRUE
    // simulator; the change the model predicts against the change the simulator shows, in the model's own
    // feature space - relative error, and direction (cosine).
    // FIRST RESULT (Sep 24; ~214 s: teacher recording 68 s, training 106 s): trained on the servo + noise, the
    // action response is off by 0.89 of its size, cosine 0.43, state error 0.254; on the teacher's recordings,
    // off by 0.99, cosine 0.20 - WORSE - though its state error is better (0.177). The teacher picks its action
    // FROM the state, so in its data the action is nearly implied by the state and a model need not learn what
    // the action does; the servo's noise, independent of the state, forces it to. Expert data alone cannot teach
    // the action response - next: the planner's REJECTED candidates too (diverse actions around the teacher's,
    // from the true simulator, exactly where balance is decided).
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var lift_probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer lift_probe.deinit();
    _ = restClipOnFloor(m, &lift_probe, &clip, 0.001);

    const scale: f32 = teacher_scale;
    const fleet_options: robot_track.Fleet.Options = .{
        .envs = 8,
        .capacity = 512,
        .action_scale = scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    };
    const size: usize = robot_track.actionSize(m);
    const io: std.Io = threaded.io();
    const began: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    // The servo's data: the servo with noise on its actions, as the SuperTrack trials were fed.
    const servo_fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, fleet_options);
    defer servo_fleet.deinit();
    const noise: []f32 = try gpa.alloc(f32, fleet_options.envs * size);
    defer gpa.free(noise);
    var rng: std.Random.DefaultPrng = .init(5);
    for (0..400) |_| {
        for (noise) |*a| {
            a.* = 0.5 * rng.random().floatNorm(f32);
        }
        _ = servo_fleet.step(noise);
    }
    const servo_done: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    // The teacher's data: the planner, limited to the policy's reach, recorded from starts across the dance.
    const teacher_fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, fleet_options);
    defer teacher_fleet.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var teacher_options: Planner.Options = planner_options;
    teacher_options.limit = scale;
    var planner: Planner = try .init(gpa, &run, &imported, teacher_options);
    defer planner.deinit();
    const action: []f32 = try gpa.alloc(f32, size);
    defer gpa.free(action);
    // The teacher's CANDIDATES - every rollout, rejected ones too - into a fleet of their own.
    var candidate_options: robot_track.Fleet.Options = fleet_options;
    candidate_options.capacity = 4096;
    const candidate_fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, candidate_options);
    defer candidate_fleet.deinit();
    planner.candidates = &candidate_fleet.replay;
    planner.candidate_scale = scale;
    // DART-style: the candidates' steps jittered independently of the state - the servo trials' noise size.
    planner.candidate_jitter = 0.5;
    var recorded: usize = 0;
    for (0..fleet_options.envs) |env| {
        planner.candidate_env = env;
        const from: usize = 60 + env * 210;
        const recording: Planner.Recording = try planner.record(
            &clip,
            from,
            teacher_cap,
            &teacher_fleet.replay,
            env,
            @intCast(env),
            scale,
            action,
        );
        recorded += recording.frames;
    }
    const teacher_done: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    // Two world models, the same in everything but their data.
    const world_options: latent.WorldOptions = .{ .hidden = 64, .steps = 8, .batch = 16, .rate = 3.0e-4 };
    const servo_world: *latent.LatentWorld = try .init(gpa, servo_fleet, world_options);
    defer servo_world.deinit(gpa);
    const teacher_world: *latent.LatentWorld = try .init(gpa, teacher_fleet, world_options);
    defer teacher_world.deinit(gpa);
    const candidate_world: *latent.LatentWorld = try .init(gpa, candidate_fleet, world_options);
    defer candidate_world.deinit(gpa);

    const trained: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    report.print("\n  D3 timing: servo data {d} ms, teacher data {d} ms, training {d} ms\n", .{
        @divTrunc(servo_done.nanoseconds - began.nanoseconds, 1_000_000),
        @divTrunc(teacher_done.nanoseconds - servo_done.nanoseconds, 1_000_000),
        @divTrunc(trained.nanoseconds - teacher_done.nanoseconds, 1_000_000),
    });
    // The yardstick. A probe fleet only to ENCODE the simulator's outcome states (its replay holds them).
    const probe_fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, .{
        .envs = 1,
        .capacity = 64,
        .action_scale = scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    });
    defer probe_fleet.deinit();
    var moment: ServoRun.Snapshot = try .init(gpa, m);
    defer moment.deinit(gpa);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const target: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(target);
    const nudged: []f32 = try gpa.alloc(f32, size);
    defer gpa.free(nudged);
    const features: usize = teacher_world.features;
    const buffers: []f32 = try gpa.alloc(f32, 5 * features + teacher_world.references);
    defer gpa.free(buffers);
    const z: []f32 = buffers[0..features];
    const z_a: []f32 = buffers[features..][0..features];
    const z_b: []f32 = buffers[2 * features ..][0..features];
    const f_a: []f32 = buffers[3 * features ..][0..features];
    const f_b: []f32 = buffers[4 * features ..][0..features];
    const ref: []f32 = buffers[5 * features ..][0..teacher_world.references];
    // Three freedoms to nudge: a hip, a knee and a shoulder (the x of LeftUpLeg, RightLeg and LeftArm).
    const nudges = [_]usize{ planner.joint_dof[2], planner.joint_dof[6], planner.joint_dof[8] };
    const nudge: f32 = 0.5;
    // Measured at checkpoints of training: if the action response keeps improving it is the BUDGET; if it
    // stalls, it is the DATA.
    var trained_steps: usize = 0;
    for (world_checkpoints) |checkpoint| {
        while (trained_steps < checkpoint) : (trained_steps += 1) {
            _ = try servo_world.trainStep(servo_fleet);
            _ = try teacher_world.trainStep(teacher_fleet);
            _ = try candidate_world.trainStep(candidate_fleet);
        }
        report.print("  after {d} training steps:\n", .{checkpoint});
        const worlds = [_]*latent.LatentWorld{ servo_world, teacher_world, candidate_world };
        const names = [_][]const u8{ "the servo's data", "the teacher's data", "the teacher's JITTERED candidates" };
        for (worlds, names) |world, name| {
            var relative: f32 = 0.0;
            var cosine: f32 = 0.0;
            var state_error: f32 = 0.0;
            var samples: usize = 0;
            for (0..fleet_options.envs) |env| {
                for ([_]u64{ 10, 30, 50 }) |i| {
                    if (i + 1 >= teacher_fleet.replay.written[env]) {
                        continue;
                    }
                    @memcpy(action, teacher_fleet.replay.actionAt(env, i));
                    const at: usize = teacher_fleet.replay.frameAt(env, i);
                    world.featuresAt(teacher_fleet, env, i, z);
                    world.referenceAt(teacher_fleet, env, i, ref);
                    for (nudges) |k| {
                        @memcpy(nudged, action);
                        nudged[k] += nudge;
                        // The simulator: the recorded state, stepped with the action and with the nudged one.
                        for ([_][]const f32{ action, nudged }, [_][]f32{ f_a, f_b }) |taken, encoded| {
                            @memcpy(moment.pos, teacher_fleet.replay.poseAt(env, i));
                            @memcpy(moment.vel, teacher_fleet.replay.velocityAt(env, i));
                            run.restore(&moment);
                            robot_track.applyAction(m, clip.pose(at + 1), taken, scale, scratch, target);
                            _ = try run.stepToward(target, clip.frame_time);
                            probe_fleet.replay.append(0, run.data.pos, run.data.vel, taken, @intCast(at + 1), 0, 0);
                            world.featuresAt(probe_fleet, 0, probe_fleet.replay.written[0] - 1, encoded);
                        }
                        // The model: the same state, the same two actions.
                        @memcpy(z_a, z);
                        world.stepRow(z_a, ref, action);
                        @memcpy(z_b, z);
                        world.stepRow(z_b, ref, nudged);
                        var err: f32 = 0.0;
                        var sim_size: f32 = 0.0;
                        var model_size: f32 = 0.0;
                        var agreement: f32 = 0.0;
                        var miss: f32 = 0.0;
                        for (0..features) |c| {
                            const sim_change: f32 = f_b[c] - f_a[c];
                            const model_change: f32 = z_b[c] - z_a[c];
                            err += (model_change - sim_change) * (model_change - sim_change);
                            sim_size += sim_change * sim_change;
                            model_size += model_change * model_change;
                            agreement += model_change * sim_change;
                            miss += (z_a[c] - f_a[c]) * (z_a[c] - f_a[c]);
                        }
                        relative += @sqrt(err) / @max(@sqrt(sim_size), 1.0e-9);
                        cosine += agreement / @max(@sqrt(sim_size) * @sqrt(model_size), 1.0e-9);
                        state_error += @sqrt(miss / float(features));
                        samples += 1;
                    }
                }
            }
            report.print("{s}  D3, world model on {s}: action response off by {d:.2} of its size, direction " ++
                "cosine {d:.2}; one-step state error {d:.3} (normalised) - {d} probes\n", .{
                if (world == servo_world) "" else "",
                name,
                relative / float(samples),
                cosine / float(samples),
                state_error / float(samples),
                samples,
            });
        }
    }
    var candidate_records: u64 = 0;
    for (candidate_fleet.replay.written) |n| {
        candidate_records += n;
    }
    report.print("  (the teacher recorded {d} steps and {d} candidate steps; each model trained {d} steps)\n", .{
        recorded,
        candidate_records,
        trained_steps,
    });
}

/// D3's teacher: the policy's measured reach (0.6 rad a freedom holds 94% of the planner's unlimited result),
/// how long each recording may run, and how long each world model trains.
const teacher_scale: f32 = 0.6;
const teacher_cap: usize = 100;
const world_checkpoints = [_]usize{ 400, 800, 1600 };

test "robot_geno: geno_train's clip - the dance from 5 s to 15 s, lifted onto the floor, baked" {
    // The GPU page trains SuperTrack on Geno over the stretch where the servo alone falls within a second or so
    // (its first 5 s it already keeps up with) - so learning has room to show. Copied, cut, lifted onto the
    // floor frame by frame, and baked as the page embeds it. Held byte-equal like the model fixture: when
    // missing or stale it is rewritten here and the test fails once, so a changed clip arrives as a diff.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = 1.0 / 60.0,
        .max_contacts = 256,
    });
    defer imported.deinit();
    const m: *const rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var whole: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer whole.deinit();
    // The cut: frames [first, first + count).
    const first: usize = train_clip_first;
    const count: usize = train_clip_frames;
    const nq: usize = whole.nq;
    const targets: []f32 = try gpa.alloc(f32, count * nq);
    @memcpy(targets, whole.targets[first * nq ..][0 .. count * nq]);
    const residual: []f32 = try gpa.alloc(f32, count);
    @memcpy(residual, whole.residual[first..][0..count]);
    const residual_body: []u32 = try gpa.alloc(u32, count);
    @memcpy(residual_body, whole.residual_body[first..][0..count]);
    var cut: dance.Clip = .{
        .gpa = gpa,
        .frame_count = count,
        .frame_time = whole.frame_time,
        .nq = nq,
        .targets = targets,
        .residual = residual,
        .residual_body = residual_body,
    };
    defer cut.deinit();
    var probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer probe.deinit();
    _ = restClipOnFloor(m, &probe, &cut, 0.001);
    const baked: []u8 = try cut.toBytes(gpa);
    defer gpa.free(baked);
    const stored: ?[]u8 = readAsset(gpa, threaded.io(), train_clip_path) catch null;
    defer if (stored) |bytes| gpa.free(bytes);
    const current: bool = if (stored) |bytes| std.mem.eql(u8, bytes, baked) else false;
    if (!current) {
        const file: std.Io.File = try std.Io.Dir.cwd().createFile(threaded.io(), train_clip_path, .{});
        defer file.close(threaded.io());
        try file.writeStreamingAll(threaded.io(), baked);
        report.print("\n  {s} was {s} - rebaked ({d} bytes); review the diff and run again\n", .{
            train_clip_path,
            if (stored == null) "missing" else "stale",
            baked.len,
        });
    }
    try expect(current);
}

/// The GPU page's clip: the dance from 5 s, for 10 s.
const train_clip_first: usize = 300;
const train_clip_frames: usize = 600;
const train_clip_path: []const u8 = "examples/geno_train/dance.zclip";

test "robot_geno: the GPU page's SuperTrack, on its CPU twin - how jittery is the policy?" {
    // Simon, on the phone: `geno_train`'s policy "looks like it is exploding - extremely jittery and broken".
    // Reproduced headless on the resident learner's CPU twin with the page's setup - Geno with standing armature,
    // the dance 5 s -> 15 s, action reach 0.6 rad, the page's small networks - and MEASURED: how big the policy's
    // actions are, and how much they jump frame to frame (the servo alone: zero), with falls and reward.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    for ([_]f32{ 0.0, 1.0 }) |smooth| {
        var recipe: HoldRecipe = page_recipe;
        recipe.w_smooth = smooth;
        const result: HoldResult = try trackTrial(gpa, model_text, recipe, 1, .{
            .capture = dance_bytes,
            .from_seconds = 5.0,
            .seconds = 10.0,
            .armature = standing_armature,
            .action_scale = 0.6,
        });
        report.print("\n  the page's SuperTrack on its CPU twin, smoothness {d:.1}: " ++
            "world loss {d:.3}, policy loss {d:.3};\n" ++
            "  real simulator, {d} steps x 8: servo {d} falls, reward {d:.3} | policy {d} falls, reward {d:.3};\n" ++
            "  the policy's actions: mean |a| {d:.3}, mean frame-to-frame jump {d:.3} " ++
            "(action units; reach 0.6 rad)\n", .{
            smooth,
            result.world_loss,
            result.policy_loss,
            judge_steps,
            result.servo_falls,
            result.servo_reward,
            result.policy_falls,
            result.policy_reward,
            result.policy_action,
            result.policy_jitter,
        });
        try expect(result.world_loss == result.world_loss);
    }
}

/// The page's learner, as a recipe: its window, its small networks, SuperTrack's own collection.
const page_recipe: HoldRecipe = .{
    .prefill_steps = 200,
    .prefill_noise = 0.1,
    .world_rate = 1.0e-3,
    .world_pretrain = 400,
    .rounds = 40,
    .world_per_round = 8,
    .policy_per_round = 8,
    .policy_rate = 3.0e-4,
    .explore = 1.0,
    .window = 8,
    .w_action = 0.01,
};

test "robot_geno: D4 - a policy cloned from the teacher, judged in the real simulator" {
    // RESULT (Sep 25, 401 s): servo 98 falls / reward 0.781; cloned 118 / 0.644; DAgger rounds 1-3: 126 / 0.619,
    // 126 / 0.613, 124 / 0.629 - no better, and the student's frame-to-frame jump DOUBLES (0.064 -> 0.123) as labels
    // grow. The labels are the fault: predictive sampling's argmax of 16 perturbed plans is mostly noise as ONE
    // decision (it works as a trajectory, re-planned each step). Next: MPPI's cost-weighted average as the label.
    // D4's first half: the planner - the teacher that holds the dance's hard stretches with no model - IMITATED by
    // plain supervision: SuperTrack's own policy network (`Learner.cloneStep`), its output against the action the
    // teacher took in each recorded state. Then judged where it counts, in the real simulator against the servo.
    // A clone that beats the servo is a start every learner can fine-tune instead of learning from nothing; one
    // that does not shows how far imitation alone carries (states the teacher never visited are the classic gap).
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    // The dance from 5 s, for 10 s, lifted onto the floor - geno_train's and geno_ppo's stretch.
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    {
        const skip: usize = train_clip_first;
        const nq: usize = clip.nq;
        const keep: usize = train_clip_frames;
        std.mem.copyForwards(f32, clip.targets[0 .. keep * nq], clip.targets[skip * nq ..][0 .. keep * nq]);
        std.mem.copyForwards(f32, clip.residual[0..keep], clip.residual[skip..][0..keep]);
        std.mem.copyForwards(u32, clip.residual_body[0..keep], clip.residual_body[skip..][0..keep]);
        clip.frame_count = keep;
    }
    var lift_probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer lift_probe.deinit();
    _ = restClipOnFloor(m, &lift_probe, &clip, 0.001);

    const envs: usize = 8;
    const fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, .{
        .envs = envs,
        .capacity = 2048,
        .action_scale = clone_scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    });
    defer fleet.deinit();
    // The teacher: the planner, limited to its measured reach (0.6 rad a freedom - 3 action units here).
    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var teacher_options: Planner.Options = planner_options;
    teacher_options.limit = 0.6;
    // MEASURED with this teacher (Sep 25, 330 s): clone 160 falls / 0.459 (loss 0.017 - easier to fit), DAgger 177 ->
    // 198 falls, jitter 0.074 -> 0.178 - WORSE than the predictive-sampling teacher's clone (118 / 0.644). Not
    // noise, then: the teacher is NOT a function of the state (both planners warm-start from their last plan;
    // DAgger's labels from the student's action) and it sees 15 frames ahead where the student sees one - a
    // function the student cannot represent. Next: cold-start (Markovian) labels; goals further ahead.
    // Sharp MPPI: the best controller measured (4.88 s on D1's yardstick) and a low-variance label - one argmax
    // of perturbed plans is mostly perturbation, and a student regressing on it learned the noise as jitter.
    teacher_options.mppi = true;
    teacher_options.temperature = 0.03;
    var planner: Planner = try .init(gpa, &run, &imported, teacher_options);
    defer planner.deinit();
    const size: usize = robot_track.actionSize(m);
    const action: []f32 = try gpa.alloc(f32, size);
    defer gpa.free(action);
    var recorded: usize = 0;
    for (0..envs) |env| {
        const from: usize = 30 + env * 70;
        const recording: Planner.Recording = try planner.record(
            &clip,
            from,
            clone_record_cap,
            &fleet.replay,
            env,
            @intCast(env),
            clone_scale,
            action,
        );
        recorded += recording.frames;
    }
    // The student: SuperTrack's learner, its normaliser measured on the teacher's states.
    const learner: *latent.Learner = try .init(gpa, fleet, .{
        .hidden = 64,
        .window = 8,
        .batch = 32,
        .rate = 1.0e-3,
        .seed = 1,
        .world = .{ .hidden = 64, .steps = 8, .batch = 16 },
    });
    defer learner.deinit();
    // The dataset, as steps: every teacher record with a successor in its recording...
    var dataset: std.ArrayList(latent.Learner.Step) = .empty;
    defer dataset.deinit(gpa);
    for (0..envs) |env| {
        const written: u64 = fleet.replay.written[env];
        if (written < 2) {
            continue;
        }
        for (0..written - 1) |index| {
            try dataset.append(gpa, .{ .env = env, .index = index });
        }
    }
    var steps: [32]latent.Learner.Step = undefined;
    var rng: std.Random.DefaultPrng = .init(11);
    var first_loss: f32 = 0.0;
    var last_loss: f32 = 0.0;
    for (0..clone_updates) |u| {
        for (&steps) |*step| {
            step.* = dataset.items[rng.random().uintLessThan(usize, dataset.items.len)];
        }
        last_loss = try learner.cloneStep(&steps);
        if (u == 0) {
            first_loss = last_loss;
        }
    }
    const servo: Quality = try judgeQuality(learner, judge_steps, true);
    const student: Quality = try judgeQuality(learner, judge_steps, false);
    report.print("\n  D4 clone: the teacher recorded {d} steps; cloning loss {d:.4} -> {d:.4} over {d} updates;\n" ++
        "  real simulator, {d} steps x {d}: servo {d} falls, reward {d:.3} | clone {d} falls, reward {d:.3};\n" ++
        "  the clone's actions: mean |a| {d:.3}, frame-to-frame jump {d:.3} (units of {d:.1} rad)\n", .{
        recorded,
        first_loss,
        last_loss,
        clone_updates,
        judge_steps,
        envs,
        servo.falls,
        servo.reward,
        student.falls,
        student.reward,
        student.action,
        student.jitter,
        clone_scale,
    });
    try expect(last_loss == last_loss and last_loss < first_loss);

    // DAgger: the STUDENT drives (a fleet of its own, so its actions never become labels); the TEACHER labels
    // states the student reached - each restored into the planner's run, the plan warm-started from the
    // student's own action, the planner's first step the label; the dataset grows by them; retrain; judge.
    var moment: ServoRun.Snapshot = try .init(gpa, m);
    defer moment.deinit(gpa);
    const label: []f32 = try gpa.alloc(f32, size);
    defer gpa.free(label);
    var next_slot: usize = 0;
    for (0..dagger_rounds) |round| {
        const trained: *robot_track.Fleet = learner.fleet;
        var drive_options: robot_track.Fleet.Options = trained.options;
        drive_options.seed = 1000 + round;
        const drive: *robot_track.Fleet = try .init(gpa, m, trained.clips, drive_options);
        defer drive.deinit();
        learner.fleet = drive;
        learner.act(dagger_drive, 0.0);
        learner.fleet = trained;
        var labelled: usize = 0;
        var tries: usize = 0;
        while (labelled < dagger_labels and tries < 4 * dagger_labels) : (tries += 1) {
            const env: usize = rng.random().uintLessThan(usize, envs);
            const written: u64 = drive.replay.written[env];
            if (written < 2) {
                continue;
            }
            const index: u64 = rng.random().uintLessThan(u64, @min(written, drive.replay.capacity) - 1) +
                (written -| drive.replay.capacity);
            const frame: u32 = drive.replay.frameAt(env, index);
            if (frame + 1 >= clip.frame_count) {
                continue;
            }
            @memcpy(moment.pos, drive.replay.poseAt(env, index));
            @memcpy(moment.vel, drive.replay.velocityAt(env, index));
            run.restore(&moment);
            // Warm start: the student's own action, as the plan's every knot (radians).
            const student_action: []const f32 = drive.replay.actionAt(env, index);
            const joints: usize = planner.joint_dof.len;
            for (0..planner.options.knots) |knot| {
                for (planner.joint_dof, 0..) |dof, j| {
                    for (0..3) |axis| {
                        planner.nominal[(knot * joints + j) * 3 + axis] = student_action[dof + axis] * clone_scale;
                    }
                }
            }
            try planner.choose(&clip, frame + 1);
            _ = planner.actionOf(clone_scale, label);
            const slot: usize = next_slot % envs;
            next_slot += 1;
            fleet.replay.append(slot, moment.pos, moment.vel, label, frame, 0, @intCast(2000 + round));
            try dataset.append(gpa, .{ .env = slot, .index = fleet.replay.written[slot] - 1, .goal_frame = frame + 1 });
            labelled += 1;
        }
        for (0..clone_updates) |_| {
            for (&steps) |*step| {
                step.* = dataset.items[rng.random().uintLessThan(usize, dataset.items.len)];
            }
            last_loss = try learner.cloneStep(&steps);
        }
        const judged: Quality = try judgeQuality(learner, judge_steps, false);
        report.print("  DAgger round {d}: +{d} labels ({d} steps in all), loss {d:.4}; " ++
            "clone {d} falls, reward {d:.3}, |a| {d:.3}, jump {d:.3}\n", .{
            round + 1,
            labelled,
            dataset.items.len,
            last_loss,
            judged.falls,
            judged.reward,
            judged.action,
            judged.jitter,
        });
    }
}

/// D4's student: the fleet's action scale (radians a unit - geno_ppo's), how long each teacher recording may
/// run, and how many cloning updates.
const clone_scale: f32 = 0.2;
const clone_record_cap: usize = 120;
const clone_updates: usize = 3000;
/// DAgger: rounds, the student's driving steps a round (x 8 characters), and the states the teacher labels.
const dagger_rounds: usize = 3;
const dagger_drive: usize = 150;
const dagger_labels: usize = 300;

/// Which motion a task tracks, and which stretch of it.
pub const Motion = enum {
    /// The dance from 5 s to 15 s - the stretch `geno_train` and D5's first trials used.
    dance_5_15,
    /// The whole dance, as copied.
    dance,
    /// The whole fall-and-get-up: standing, falling, lying on the floor, and rising again.
    getup,

    /// The capture the motion is copied from.
    fn capturePath(motion: Motion) []const u8 {
        return switch (motion) {
            .dance_5_15, .dance => "assets/lafan1/dance1_subject2.bvh",
            .getup => "assets/lafan1/fallAndGetUp2_subject2.bvh",
        };
    }

    /// The frames kept, when not all of them: where the stretch starts, and how long it is.
    fn stretch(motion: Motion) ?struct { first: usize, frames: usize } {
        return switch (motion) {
            .dance_5_15 => .{ .first = train_clip_first, .frames = train_clip_frames },
            .dance, .getup => null,
        };
    }
};

/// A TASK, as code: Geno (standing armature on every ball joint, the Newton solver, 60 Hz), and one motion
/// copied onto it and lifted onto the floor frame by frame - what a learner learns and is judged on (D5.0 used
/// the dance's 5 s to 15 s; the overnight run, ON, the whole dance and the whole get-up). Heap-allocated so
/// the model's address stays put for everything that borrows it (runs, fleets, trainers).
pub const GenoTask = struct {
    gpa: Allocator,
    /// The model's XML text, OWNED: the parsed document - and through it every body and joint name the robot
    /// and the model hand out - are slices into it, not copies. Freed last.
    model_text: []u8,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    clip: dance.Clip,

    /// Null when the model or the motion's capture is not on disk (the tests skip then).
    pub fn init(gpa: Allocator, io: std.Io, motion: Motion) !?*GenoTask {
        const model_text: []u8 = readAsset(gpa, io, model_fixture_path) catch return null;
        errdefer gpa.free(model_text);
        const capture_bytes: []u8 = readAsset(gpa, io, motion.capturePath()) catch return null;
        defer gpa.free(capture_bytes);
        const self: *GenoTask = try gpa.create(GenoTask);
        errdefer gpa.destroy(self);
        var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
        errdefer doc.deinit();
        var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
        errdefer robot.deinit();
        for (robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = standing_armature;
            }
        }
        var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
        build_options.solver.algorithm = .newton;
        self.* = .{
            .gpa = gpa,
            .model_text = model_text,
            .doc = doc,
            .robot = robot,
            .imported = undefined,
            .clip = undefined,
        };
        // Built from the task's OWN robot, not the local it was copied from: whatever `Imported` keeps a
        // hold of must live as long as the task does.
        self.imported = try robot_mjcf.build(gpa, &self.robot, build_options);
        errdefer self.imported.deinit();
        const m: *rbt.Model = &self.imported.model;
        var bind: Posed = try readPose(gpa, bind_bvh);
        defer bind.deinit(gpa);
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, capture_bytes, null);
        defer capture.deinit();
        self.clip = try copyClip(gpa, &self.imported, bind, capture);
        errdefer self.clip.deinit();
        if (motion.stretch()) |kept| {
            // Slide the stretch down to frame 0 and forget the rest.
            const nq: usize = self.clip.nq;
            const from: usize = kept.first;
            const keep: usize = kept.frames;
            const targets: []f32 = self.clip.targets;
            std.mem.copyForwards(f32, targets[0 .. keep * nq], targets[from * nq ..][0 .. keep * nq]);
            std.mem.copyForwards(f32, self.clip.residual[0..keep], self.clip.residual[from..][0..keep]);
            std.mem.copyForwards(u32, self.clip.residual_body[0..keep], self.clip.residual_body[from..][0..keep]);
            self.clip.frame_count = keep;
        }
        var probe: rbt.Data = try rbt.Data.init(gpa, m);
        defer probe.deinit();
        _ = restClipOnFloor(m, &probe, &self.clip, 0.001);
        return self;
    }

    pub fn deinit(self: *GenoTask) void {
        const gpa: Allocator = self.gpa;
        self.clip.deinit();
        self.imported.deinit();
        self.robot.deinit();
        self.doc.deinit();
        gpa.free(self.model_text);
        gpa.destroy(self);
    }
};

/// D5's teacher, in one place: sharp MPPI on DReCon's clock and filter, allowed the student's full raw reach
/// (1.2 rad - capped at 0.6 it collapses to 1.4 s; allowed 1.2 it holds 3.48 s on D1's hard starts).
pub const d5_teacher: Planner.Options = blk: {
    var o: Planner.Options = planner_options;
    o.mppi = true;
    o.temperature = 0.03;
    o.sigma = 0.6;
    o.limit = 1.2;
    o.filter = 0.2;
    o.decimation = 2;
    // Memoryless, two MPPI iterations a decision (Sep 25): 3.65 s on D1's hard starts (the carried-plan teacher
    // 3.48) - and a label that depends only on what the student observes. With the carried plan, half of every
    // label was plan memory the student cannot see, and the clone could only memorise.
    o.markov = true;
    o.iterations = 2;
    // GRAVITY - one cost for EVERY clip (Simon, Sep 26: ~100 clips, get-ups hidden in some; no per-motion
    // switch). Without it the teacher never rises: its shape is measured from the root's own pose, so lying with
    // the right joint angles costs what kneeling with them costs. Measured on D1's dance yardstick and the
    // get-up's floor starts (509 / 530 / 554; the reference's head reaches 0.99 / 1.24 / 1.43 m):
    //
    //   gravity in the cost                     dance    get-up head          mean shortfall
    //   none                                    3.65 s   0.46 / 0.58 / 0.55    ~0.4 m
    //   every body's height (1.0) + up (0.3)    1.87 s   0.69 / 1.12 / 1.26    ~0.3 m
    //   the same, hinged at 10 cm / 11 deg      3.27 s   0.84 / 0.70 / 0.73    0.36 m
    //   only the root's height and tilt         2.49 s   0.34 / 0.65 / 0.64    0.41 m
    //   the AXIS's heights (hips..head) + up    2.18 s   0.98 / 1.23 / 0.91    0.26 m
    //   the axis, gated by the reference's pose 3.43 s   0.75 / 0.91 / 1.19    0.24 m   <- this
    //
    // A rise is led by the torso and head (pushed up by the arms, hips low): the axis's heights lift it, the
    // limbs' do not. And any height term taxes a dance's balance dips (dropping the centre of mass to recover),
    // so it is GATED by how low the REFERENCE is: nothing while its head is near standing height, everything
    // when it lies - a property of each frame's pose, so a get-up hidden in any clip turns it on by going low.
    o.height_weight = 1.0;
    o.up_weight = 0.3;
    o.height_bodies = &axis_bodies;
    o.posture_gate = true;
    break :blk o;
};
/// ONE FAILURE CRITERION (ON.0b, Sep 26) - used by the teacher's fall penalty, every survival loop, the recorder,
/// every test and the page: has a character lost the clean reference at clip frame `f`? The task's own rule -
/// `robot_track.terminated` with `termination` (Geno's `task_termination`: tracking error, and the bodies' height
/// RELATIVE to the reference's, so lying is no failure while the reference lies) - through the very functions
/// training and judging use. It replaced a hips-35-cm rule that the teacher, the tests and the page each applied
/// their own way: with ~100 clips and get-ups hidden in some, a teacher avoiding one kind of failure while the
/// learner is punished for another is exactly where a night would go wrong.
pub const FailureCheck = struct {
    termination: robot_track.Termination = task_termination,
    /// The clean reference, posed at the frame asked about.
    judge: rbt.Data,
    /// Both characters as the task sees them, and the root they are measured from.
    sim_state: robot_track.State,
    ref_state: robot_track.State,
    root: usize,
    /// The error behind the latest verdict - which limit it crossed, for anyone asking why.
    last: robot_track.TrackingError = undefined,

    pub fn init(gpa: Allocator, m: *const rbt.Model) !FailureCheck {
        var judge: rbt.Data = try .init(gpa, m);
        errdefer judge.deinit();
        var sim_state: robot_track.State = try .init(gpa, m.nbody);
        errdefer sim_state.deinit(gpa);
        const ref_state: robot_track.State = try .init(gpa, m.nbody);
        return .{
            .judge = judge,
            .sim_state = sim_state,
            .ref_state = ref_state,
            .root = robot_track.rootBody(m),
        };
    }

    pub fn deinit(self: *FailureCheck, gpa: Allocator) void {
        self.ref_state.deinit(gpa);
        self.sim_state.deinit(gpa);
        self.judge.deinit();
    }

    pub fn lost(
        self: *FailureCheck,
        m: *const rbt.Model,
        data: *const rbt.Data,
        clip: *const dance.Clip,
        f: usize,
    ) bool {
        return self.within(m, data, clip, f, 1.0);
    }

    /// The same criterion with every limit scaled by `fraction` - an EARLY WARNING for anyone who must steer
    /// away before the end (the teacher's fall penalty): the one rule, with a margin, never a rule of its own.
    pub fn within(
        self: *FailureCheck,
        m: *const rbt.Model,
        data: *const rbt.Data,
        clip: *const dance.Clip,
        f: usize,
        fraction: f32,
    ) bool {
        // Posed EXACTLY as the fleet poses its reference (`Fleet.referenceStateInto`) - positions, and velocities
        // by differencing from the frame before - so the error is the task's to the last field. (Until Sep 26 only
        // positions were posed: the velocity terms read whatever the judge last held.)
        const at: usize = @min(f, clip.frame_count - 1);
        const previous: usize = if (at == 0) 0 else at - 1;
        const skip: usize = clip.nq - m.nq;
        @memcpy(self.judge.pos, clip.pose(at)[skip..]);
        rbt.differentiatePos(m, self.judge.vel, clip.pose(previous)[skip..], clip.pose(at)[skip..], clip.frame_time);
        self.judge.stage = .stale;
        rbt.forward(m, &self.judge);
        robot_track.stateOf(m, data, &self.sim_state);
        robot_track.stateOf(m, &self.judge, &self.ref_state);
        self.last = robot_track.trackingError(self.sim_state, self.ref_state, self.root);
        return robot_track.terminated(self.last, self.termination.scaled(fraction));
    }
};

/// Geno's REWARD: DReCon's terms, GATED by gravity - the body's heights and its tilt against gravity must match
/// the reference's, or the whole reward sinks. Ungated, a body lying on the floor with the right joint angles
/// scored 0.80 while its reference stood (robot_track's "gravity gate" test); the teacher, whose cost had the
/// same blind spot, never rose from the floor until gravity was in it (ON.2.1d). 5 cm of mean height error keeps
/// 78% of the reward, lying 0.8 m low keeps 2%; an 11-degree tilt keeps 67%, lying flat 6%.
pub const task_weights: robot_track.RewardWeights = .{ .height_scale = 0.2, .up_scale = 0.5 };
/// Geno's TERMINATION: the reference lost by tracking error as before, and by HEIGHT - the bodies' mean height off
/// the reference's (relative, so lying is fine while the reference lies too). The limit is set by what it must
/// tell apart, not by any clip (Sep 26): lying while the reference stands is a ~0.8 m gap; a dancer dropping to
/// recover balance, 0.2-0.3 m. At 0.2 m (first try) it cut those recoveries - the servo's failures crossed it at
/// 0.17-0.19 m mean with the pose itself near perfect (0.01 m, 0.05 rad), and the teacher's dance fell from
/// 3.43 s to 1.24 s. At 0.4 m a crouch survives and staying down fails once the reference is halfway up.
///
/// And NOT by drifting or turning (Sep 26). With the root's world limits in (0.6 m, 1.5 rad) the teacher's dance
/// collapsed to 1.0-1.6 s: at every "loss" its hips were 0.44-0.58 m off ACROSS THE FLOOR and its heading
/// 5-144 degrees off, while its pose, seen from its own root, was 55-120 mm off - it had wandered, not fallen.
/// On flat ground SuperTrack terminates on the head's height only (root limits only for rough terrain, where the
/// reference's place matters). So the rule is "fallen, or lost the pose": the pose limits, the height relative to
/// the reference's, and the TILT against gravity (~47 degrees) - no root position, no heading. The reward keeps
/// its root terms: staying on the reference's path is encouraged, just not fatal.
///
/// CORRECTED the same day (Simon: "we want the robot to follow the reference root motion, or else it can never
/// learn to really turn on the spot and go somewhere reliably"). MimicKit's DeepMimic humanoid DOES hold the
/// root to the reference's - `track_root` with `global_obs`: the reward's root term is the GLOBAL position and
/// rotation, its observation places the targets relative to the character, and its termination fails once the
/// root is 1 m from the reference's (it was SuperTrack's FLAT-ground rule that ignores drift - its rough-terrain
/// one adds 1 m / 90 degrees). The teacher's wandering was the teacher's to fix (its cost barely weighs drift), not
/// the task's to forgive. So: 1 m for the root's place, 90 degrees for its rotation (relative to the reference's,
/// so lying is fine while the reference lies) - and the observation now SHOWS the policy where the reference is.
pub const task_termination: robot_track.Termination = .{
    .root_position = 1.0,
    .root_rotation = 1.57,
    .height = 0.4,
    .up = 0.8,
};

/// D5.5's calibrated start perturbation (Sep 25): where the SERVO ALONE lasts 1 s from about half of the starts
/// (13 of 30 across the task's dance; unperturbed 21 of 30; twice this, 5 of 30) - hard, but recoverable.
pub const d5_start_noise: robot_track.StartNoise = .{ .pose = 0.05, .velocity = 0.25 };
/// Geno's AXIS: the chain from the hips to the head (names this robot lacks are skipped where they are used).
pub const axis_bodies = [_][]const u8{ "Hips", "Spine", "Spine1", "Spine2", "Spine3", "Neck", "Neck1", "Head" };

/// The student's action scale: radians of raw offset per unit, actions in [-1, 1] (D5.0).
pub const student_scale: f32 = 1.2;

/// D5's demonstrations: the teacher's decisions as DReCon's policy would see and make them - rows of an
/// observation (`robot_policy.observe`, built exactly as PPO's trainer builds one) and a label (the raw first
/// offset / the student's scale, in the subset's order).
pub const Demo = struct {
    width: usize,
    dofs: usize,
    observations: std.ArrayList(f32) = .empty,
    labels: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *Demo, gpa: Allocator) void {
        self.observations.deinit(gpa);
        self.labels.deinit(gpa);
    }

    pub fn rows(self: Demo) usize {
        return self.labels.items.len / self.dofs;
    }

    pub fn observation(self: Demo, row: usize) []const f32 {
        return self.observations.items[row * self.width ..][0..self.width];
    }

    pub fn label(self: Demo, row: usize) []const f32 {
        return self.labels.items[row * self.dofs ..][0..self.dofs];
    }
};

/// Records the teacher's decisions into a `Demo`. Owns what the planner does not: DReCon's subset, the map
/// from its joints (MODEL order) to the planner's (`drecon_actuated` order, by qpos address), and the scratch
/// states an observation is built from.
pub const DemoRecorder = struct {
    gpa: Allocator,
    subset: robot_policy.Subset,
    to_planner: []usize,
    sim: robot_track.State,
    /// The reference now and further ahead (`robot_policy.observeFrom`).
    views: robot_policy.Views,
    last: []f32,
    scratch: []f32,

    pub fn init(
        gpa: Allocator,
        imported: *const robot_mjcf.Imported,
        planner: *const Planner,
    ) !DemoRecorder {
        const m: *const rbt.Model = &imported.model;
        const subset: robot_policy.Subset = try robot_policy.subsetFor(
            gpa,
            m,
            imported.names,
            &drecon_watched,
            &drecon_actuated,
        );
        errdefer subset.deinit(gpa);
        const to_planner: []usize = try gpa.alloc(usize, subset.joints.len);
        errdefer gpa.free(to_planner);
        for (subset.joints, 0..) |joint, i| {
            const adr: usize = m.jnt_qpos_adr[joint];
            to_planner[i] = for (planner.joint_adr, 0..) |planned, j| {
                if (planned == adr) {
                    break j;
                }
            } else return error.JointNotPlanned;
        }
        var sim: robot_track.State = try .init(gpa, m.nbody);
        errdefer sim.deinit(gpa);
        var views: robot_policy.Views = try .init(gpa, m);
        errdefer views.deinit(gpa);
        const last: []f32 = try gpa.alloc(f32, subset.dofs);
        errdefer gpa.free(last);
        const scratch: []f32 = try gpa.alloc(f32, m.nv);
        return .{
            .gpa = gpa,
            .subset = subset,
            .to_planner = to_planner,
            .sim = sim,
            .views = views,
            .last = last,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *DemoRecorder) void {
        const gpa: Allocator = self.gpa;
        gpa.free(self.scratch);
        gpa.free(self.last);
        self.views.deinit(gpa);
        self.sim.deinit(gpa);
        gpa.free(self.to_planner);
        self.subset.deinit(gpa);
    }

    pub fn newDemo(self: DemoRecorder) Demo {
        return .{ .width = robot_policy.observationSize(self.subset), .dofs = self.subset.dofs };
    }

    /// The teacher dances from `from` for up to `cap` frames; every DECISION becomes a row. The observation is
    /// PPO's: the simulated state, the reference at the frame the coming action aims at (the fleet's frame + 1 -
    /// here `f`, since the state is frame f - 1's), DReCon's root, and the last applied action - the teacher's
    /// filter state / the student's scale. Returns how many frames the teacher kept up.
    pub fn record(
        self: *DemoRecorder,
        planner: *Planner,
        fleet: *robot_track.Fleet,
        clip: *const dance.Clip,
        from: usize,
        cap: usize,
        noise: robot_track.StartNoise,
        seed: u64,
        demo: *Demo,
    ) !usize {
        const m: *const rbt.Model = planner.run.model;
        const gpa: Allocator = self.gpa;
        try planner.run.start(clip, from);
        // D5.5: the teacher may start PERTURBED - its demonstrations then include recoveries.
        var rng: std.Random.DefaultPrng = .init(seed);
        robot_track.perturbStart(m, &planner.run.data, noise, rng.random(), self.scratch);
        @memset(planner.applied, 0.0);
        planner.phase = 0;
        @memset(planner.nominal, 0.0);
        const every: u64 = @max(planner.options.decimation, 1);
        const last_frame: usize = @min(clip.frame_count, from + 1 + cap);
        var f: usize = from + 1;
        while (f < last_frame) : (f += 1) {
            if (planner.phase % every == 0) {
                try planner.choose(clip, f);
                robot_track.stateOf(m, &planner.run.data, &self.sim);
                for (self.to_planner, 0..) |j, i| {
                    for (0..3) |axis| {
                        self.last[i * 3 + axis] = planner.applied[j * 3 + axis] / student_scale;
                    }
                }
                const row: []f32 = try demo.observations.addManyAsSlice(gpa, demo.width);
                // The state is frame f - 1's: the reference lands at f, the lookahead beyond.
                const at: u32 = @intCast(f - 1);
                robot_policy.observeFrom(m, self.subset, fleet, clip, at, self.sim, &self.views, self.last, row);
                const label: []f32 = try demo.labels.addManyAsSlice(gpa, demo.dofs);
                for (self.to_planner, 0..) |j, i| {
                    const raw: Vec = planner.offsetAt(planner.best, 0.0, j);
                    label[i * 3 + 0] = raw[0] / student_scale;
                    label[i * 3 + 1] = raw[1] / student_scale;
                    label[i * 3 + 2] = raw[2] / student_scale;
                }
            }
            _ = try planner.act(clip, f);
            if (planner.run.lost(clip, f)) {
                return f - from;
            }
        }
        // Frames stepped (from + 1 .. last_frame - 1) - a loss at f returns f - from, the same count.
        return last_frame - from - 1;
    }
};

test "robot_geno: D5 recorder - each observation's last action is what DReCon's controller holds" {
    // The recorder's own contract: an observation's LAST-ACTION slot (its final `dofs` numbers - the only part
    // that carries history) must be exactly what DReCon's controller would hold at that decision after the
    // recorded labels so far - the first one zero, the filter's rest after a reset.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var lift_probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer lift_probe.deinit();
    _ = restClipOnFloor(m, &lift_probe, &clip, 0.001);
    const fleet: *robot_track.Fleet = try .init(gpa, m, &.{&clip}, .{
        .envs = 1,
        .capacity = 16,
        .action_scale = student_scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    });
    defer fleet.deinit();

    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &imported, d5_teacher);
    defer planner.deinit();
    var recorder: DemoRecorder = try .init(gpa, &imported, &planner);
    defer recorder.deinit();
    var demo: Demo = recorder.newDemo();
    defer demo.deinit(gpa);
    const kept: usize = try recorder.record(&planner, fleet, &clip, 360, 60, .{}, 0, &demo);

    var controller: robot_policy.Controller = try .init(gpa, m, recorder.subset, 1, .{ .beta = 0.2, .decimation = 2 });
    defer controller.deinit();
    const dofs: usize = demo.dofs;
    var worst: f32 = 0.0;
    var largest_label: f32 = 0.0;
    for (0..demo.rows()) |row| {
        const slot: []const f32 = demo.observation(row)[demo.width - dofs ..];
        for (slot, controller.lastAction(0)) |recorded, held| {
            worst = @max(worst, @abs(recorded - held));
        }
        for (demo.label(row)) |value| {
            largest_label = @max(largest_label, @abs(value));
        }
        // A decision, then its held step: the controller consumes the label once.
        _ = controller.apply(demo.label(row));
        _ = controller.apply(demo.label(row));
    }
    report.print("\n  D5 recorder: kept up {d} frames, {d} rows of {d} + {d}; last-action slot vs DReCon's " ++
        "controller: at most {e:.2} apart; largest label {d:.2}\n", .{
        kept,
        demo.rows(),
        demo.width,
        dofs,
        worst,
        largest_label,
    });
    try expect(demo.width == robot_policy.observationSize(recorder.subset));
    // One row a decision, a decision every 2nd frame from the first: exactly ceil(kept / 2).
    try expect(demo.rows() == (kept + 1) / 2);
    try expect(worst < 1.0e-6);
    try expect(largest_label <= 1.0 + 1.0e-5);
}

test "robot_geno: D5 step 2 - the teacher's decisions replayed through DReCon's controller give its own targets" {
    // The recorder's contract (D5.3 step 2). The teacher decides on DReCon's clock through DReCon's filter; a
    // decision's LABEL is its raw first offset / the student's scale. If those labels are what a DReCon policy
    // should output, then feeding them to DReCon's own `Controller` (filter, hold between decisions, expansion
    // to the model's action) and `applyAction` must rebuild the teacher's targets - every physics step, decision
    // or held. Any disagreement in the filter's formula, the hold's timing, the joint order (the subset lists
    // freedoms in MODEL order; the planner in `drecon_actuated`'s) or the rotation convention shows up here.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const model_text: []u8 = readAsset(gpa, threaded.io(), model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const dance_bytes: []u8 = readAsset(gpa, threaded.io(), "assets/lafan1/dance1_subject2.bvh") catch
        return error.SkipZigTest;
    defer gpa.free(dance_bytes);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = standing_armature;
        }
    }
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var bind: Posed = try readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var clip: dance.Clip = try copyClip(gpa, &imported, bind, capture);
    defer clip.deinit();
    var lift_probe: rbt.Data = try rbt.Data.init(gpa, m);
    defer lift_probe.deinit();
    _ = restClipOnFloor(m, &lift_probe, &clip, 0.001);

    var run: ServoRun = undefined;
    try run.init(gpa, &imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &imported, d5_teacher);
    defer planner.deinit();
    var subset: robot_policy.Subset = try robot_policy.subsetFor(
        gpa,
        m,
        imported.names,
        &drecon_watched,
        &drecon_actuated,
    );
    defer subset.deinit(gpa);
    var controller: robot_policy.Controller = try .init(gpa, m, subset, 1, .{ .beta = 0.2, .decimation = 2 });
    defer controller.deinit();
    // The subset's joints (model order) -> the planner's (drecon_actuated order), by qpos address.
    const to_planner: []usize = try gpa.alloc(usize, subset.joints.len);
    defer gpa.free(to_planner);
    for (subset.joints, 0..) |joint, i| {
        const adr: usize = m.jnt_qpos_adr[joint];
        to_planner[i] = for (planner.joint_adr, 0..) |planned, j| {
            if (planned == adr) {
                break j;
            }
        } else return error.JointNotPlanned;
    }
    try expect(subset.dofs == planner.joint_adr.len * 3);

    const nq: usize = m.nq;
    const label: []f32 = try gpa.alloc(f32, subset.dofs);
    defer gpa.free(label);
    @memset(label, 0.0);
    const replayed: []f32 = try gpa.alloc(f32, nq);
    defer gpa.free(replayed);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);

    const from: usize = 360;
    try run.start(&clip, from);
    @memset(planner.applied, 0.0);
    planner.phase = 0;
    @memset(planner.nominal, 0.0);
    var worst: f32 = 0.0;
    var decisions: usize = 0;
    var largest_label: f32 = 0.0;
    var f: usize = from + 1;
    while (f < from + 1 + 60) : (f += 1) {
        if (planner.phase % 2 == 0) {
            try planner.choose(&clip, f);
            // The decision's label, in the SUBSET's order: the raw first offset / the student's scale.
            for (to_planner, 0..) |j, i| {
                const raw: Vec = planner.offsetAt(planner.best, 0.0, j);
                label[i * 3 + 0] = raw[0] / student_scale;
                label[i * 3 + 1] = raw[1] / student_scale;
                label[i * 3 + 2] = raw[2] / student_scale;
            }
            for (label) |value| {
                largest_label = @max(largest_label, @abs(value));
            }
            decisions += 1;
        }
        _ = try planner.act(&clip, f);
        // DReCon's path: the controller filters (at its decisions) and holds; the task applies the offsets.
        const full: []const f32 = controller.apply(label);
        robot_track.applyAction(m, clip.targets[f * nq ..][0..nq], full, student_scale, scratch, replayed);
        for (planner.joint_adr) |adr| {
            for (0..4) |c| {
                const a: f32 = planner.target[adr + c];
                const b: f32 = replayed[adr + c];
                // A quaternion and its negative are the same turn.
                const same: f32 = @min(@abs(a - b), @abs(a + b));
                worst = @max(worst, same);
            }
        }
    }
    report.print("\n  D5 step 2: {d} decisions over 60 steps; teacher vs DReCon's controller targets " ++
        "differ by at most {e:.2} (largest label {d:.2} units)\n", .{ decisions, worst, largest_label });
    try expect(decisions == 30);
    try expect(worst < 1.0e-5);
    // Labels the student can express: the teacher's reach is the student's scale.
    try expect(largest_label <= 1.0 + 1.0e-5);
}

test "robot_geno: D5 (i) - the teacher's decisions replayed in the trainer's fleet track the teacher's own run" {
    // Do the demonstrations TRANSFER? The teacher acts through `ServoRun`; the student lives in a
    // `robot_track.Fleet`, stepped by `driveOnce`. If those were different physics, the clone would be taught
    // right answers to the wrong world - which alone would explain a clone that fits its teacher and falls.
    // So: one fleet character is placed in the teacher's exact starting state (its data copied, not reset -
    // any difference in reset order is taken out), and the teacher's labels are replayed OPEN-LOOP through
    // DReCon's controller, exactly as the trainer steps it. Same physics diverges only by chaos from rounding;
    // different physics shows millimetres within a few steps.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const fleet: *robot_track.Fleet = try .init(gpa, m, &.{&task.clip}, .{
        .envs = 1,
        .capacity = 16,
        .action_scale = student_scale,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    });
    defer fleet.deinit();
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &task.imported, d5_teacher);
    defer planner.deinit();
    var recorder: DemoRecorder = try .init(gpa, &task.imported, &planner);
    defer recorder.deinit();
    var controller: robot_policy.Controller = try .init(gpa, m, recorder.subset, 1, .{ .beta = 0.2, .decimation = 2 });
    defer controller.deinit();
    const label: []f32 = try gpa.alloc(f32, recorder.subset.dofs);
    defer gpa.free(label);
    @memset(label, 0.0);
    var teacher_state: robot_track.State = try .init(gpa, m.nbody);
    defer teacher_state.deinit(gpa);
    var fleet_state: robot_track.State = try .init(gpa, m.nbody);
    defer fleet_state.deinit(gpa);

    const from: usize = 360;
    const frames: usize = 60;
    try run.start(&task.clip, from);
    @memset(planner.applied, 0.0);
    planner.phase = 0;
    @memset(planner.nominal, 0.0);
    // The fleet's character: the teacher's starting state, exactly.
    @memcpy(fleet.data[0].pos, run.data.pos);
    @memcpy(fleet.data[0].vel, run.data.vel);
    // Placing a state is a SHOVE: the fleet skips `forward` while the data's stage watermark says its derived
    // quantities are current, so they must be recomputed here - or the first step collides and servos with the
    // body poses of the fleet's own random reset (measured: a 10 mm jolt at step 1).
    rbt.forward(m, &fleet.data[0]);
    fleet.frame[0] = @intCast(from);
    fleet.steps[0] = 0;

    var apart: [frames]f32 = undefined;
    var compared: usize = 0;
    var teacher_fell: bool = false;
    var f: usize = from + 1;
    while (f < from + 1 + frames) : (f += 1) {
        if (planner.phase % 2 == 0) {
            try planner.choose(&task.clip, f);
            for (recorder.to_planner, 0..) |j, i| {
                const raw: Vec = planner.offsetAt(planner.best, 0.0, j);
                label[i * 3 + 0] = raw[0] / student_scale;
                label[i * 3 + 1] = raw[1] / student_scale;
                label[i * 3 + 2] = raw[2] / student_scale;
            }
        }
        _ = try planner.act(&task.clip, f);
        if (planner.run.lost(&task.clip, f)) {
            teacher_fell = true;
        }
        _ = fleet.step(controller.apply(label));
        if (fleet.dones[0]) {
            break;
        }
        robot_track.stateOf(m, &run.data, &teacher_state);
        robot_track.stateOf(m, &fleet.data[0], &fleet_state);
        var worst: f32 = 0.0;
        for (teacher_state.positions, fleet_state.positions) |a, b| {
            worst = @max(worst, length3(a - b));
        }
        apart[compared] = worst;
        compared += 1;
        if (teacher_fell) {
            break;
        }
    }
    report.print("\n  D5 (i): teacher (ServoRun) vs its labels replayed in the fleet, from frame {d}: {d} steps " ++
        "compared (teacher fell: {}, fleet done early: {});\n  worst body apart (mm) at step", .{
        from,
        compared,
        teacher_fell,
        compared < frames and !teacher_fell,
    });
    for ([_]usize{ 1, 2, 5, 10, 20, 30, 45, 60 }) |at| {
        if (at <= compared) {
            report.print(" {d}: {d:.6}", .{ at, apart[at - 1] * 1000.0 });
        }
    }
    report.print("\n", .{});
    // MEASURED (Sep 25): 89 nm after one step, under 0.6 um through step 45 - the same physics to rounding; by
    // step 60, 29 mm (a sub-micron difference flips a contact: the sensitivity of contact, not a mismatch).
    try expect(compared >= 30);
    try expect(apart[29] < 1.0e-5);
}

test "robot_geno: D5 (ii) - the teacher's label at a state: how much is signal, how much sampling noise?" {
    // The clone memorised its demonstrations and predicts unseen starts WORSE than a constant (held-out error
    // 0.0199 vs always-zero 0.0111). Either the labels are mostly noise - MPPI's choice at a state carries its
    // sampling randomness, so a state has no single answer, only an EXPECTED one - or they are consistent and the
    // observation lacks what they depend on. Measured directly: at 20 of the teacher's own decisions it re-plans
    // K times from the IDENTICAL state (physics, plan, filter, clock) with different seeds; the labels' spread
    // across seeds is the noise, the spread of their means across states the signal.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &task.imported, d5_teacher);
    defer planner.deinit();
    var recorder: DemoRecorder = try .init(gpa, &task.imported, &planner);
    defer recorder.deinit();
    var moment: ServoRun.Snapshot = try .init(gpa, m);
    defer moment.deinit(gpa);
    const dofs: usize = recorder.subset.dofs;
    const nominal: []f32 = try gpa.dupe(f32, planner.nominal);
    defer gpa.free(nominal);
    const applied: []f32 = try gpa.dupe(f32, planner.applied);
    defer gpa.free(applied);
    const seeds: usize = 4;
    const decisions: usize = 20;
    const labels: []f32 = try gpa.alloc(f32, decisions * seeds * dofs);
    defer gpa.free(labels);

    try run.start(&task.clip, 360);
    @memset(planner.applied, 0.0);
    planner.phase = 0;
    @memset(planner.nominal, 0.0);
    var decided: usize = 0;
    var f: usize = 361;
    while (decided < decisions and f < task.clip.frame_count) : (f += 1) {
        if (planner.phase % 2 == 0) {
            run.save(&moment);
            @memcpy(nominal, planner.nominal);
            @memcpy(applied, planner.applied);
            const kept_rng = planner.rng;
            for (0..seeds) |k| {
                run.restore(&moment);
                @memcpy(planner.nominal, nominal);
                @memcpy(planner.applied, applied);
                planner.rng = .init(7000 + 31 * decided + k);
                try planner.choose(&task.clip, f);
                const label: []f32 = labels[(decided * seeds + k) * dofs ..][0..dofs];
                for (recorder.to_planner, 0..) |j, i| {
                    const raw: Vec = planner.offsetAt(planner.best, 0.0, j);
                    label[i * 3 + 0] = raw[0] / student_scale;
                    label[i * 3 + 1] = raw[1] / student_scale;
                    label[i * 3 + 2] = raw[2] / student_scale;
                }
            }
            // Then the real decision, exactly as if nothing had been tried.
            run.restore(&moment);
            @memcpy(planner.nominal, nominal);
            @memcpy(planner.applied, applied);
            planner.rng = kept_rng;
            try planner.choose(&task.clip, f);
            decided += 1;
        }
        _ = try planner.act(&task.clip, f);
        if (planner.run.lost(&task.clip, f)) {
            break;
        }
    }
    // Noise: each label's distance from its state's mean over seeds. Signal: the state means' spread.
    var noise: f64 = 0.0;
    var signal: f64 = 0.0;
    var square: f64 = 0.0;
    const grand: []f64 = try gpa.alloc(f64, dofs);
    defer gpa.free(grand);
    @memset(grand, 0.0);
    const means: []f64 = try gpa.alloc(f64, decided * dofs);
    defer gpa.free(means);
    for (0..decided) |d| {
        for (0..dofs) |i| {
            var mean: f64 = 0.0;
            for (0..seeds) |k| {
                const value: f64 = labels[(d * seeds + k) * dofs + i];
                mean += value;
                square += value * value;
            }
            mean /= @floatFromInt(seeds);
            means[d * dofs + i] = mean;
            grand[i] += mean / float64(decided);
            for (0..seeds) |k| {
                const gap: f64 = labels[(d * seeds + k) * dofs + i] - mean;
                noise += gap * gap;
            }
        }
    }
    for (0..decided) |d| {
        for (0..dofs) |i| {
            const gap: f64 = means[d * dofs + i] - grand[i];
            signal += gap * gap;
        }
    }
    const cells: f64 = @floatFromInt(decided * dofs);
    // Unbiased within-state variance (seeds - 1), and the between-state variance of the means.
    noise /= cells * float64(seeds - 1);
    signal /= cells;
    square /= cells * float64(seeds);
    report.print("\n  D5 (ii): {d} decisions x {d} seeds - labels' mean square {d:.4}; sampling noise (within a " ++
        "state) {d:.4}, signal (between states) {d:.4}; signal / noise {d:.2}\n", .{
        decided,
        seeds,
        square,
        noise,
        signal,
        signal / @max(noise, 1.0e-12),
    });
    try expect(decided == decisions);
}

test "robot_geno: D5 (ii-b) - how much does the teacher's label depend on the plan it carries?" {
    // (ii) held the plan fixed and found the labels 4x more signal than sampling noise. But the student never
    // sees the plan the teacher carries from one decision to the next - so how much of a label is THAT memory?
    // At 20 of the teacher's decisions it re-plans twice from the identical state (physics, filter, clock) with
    // the SAME seed - its warm plan, then a cold (zero) one: with the random draws identical, their difference
    // is the plan memory alone. Compared with the signal between states: comparable means the teacher's answer
    // hangs on something the student cannot see, and labels must come from a teacher without that memory.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &task.imported, d5_teacher);
    defer planner.deinit();
    var recorder: DemoRecorder = try .init(gpa, &task.imported, &planner);
    defer recorder.deinit();
    var moment: ServoRun.Snapshot = try .init(gpa, m);
    defer moment.deinit(gpa);
    const dofs: usize = recorder.subset.dofs;
    const nominal: []f32 = try gpa.dupe(f32, planner.nominal);
    defer gpa.free(nominal);
    const applied: []f32 = try gpa.dupe(f32, planner.applied);
    defer gpa.free(applied);
    const decisions: usize = 20;
    const warm: []f32 = try gpa.alloc(f32, decisions * dofs);
    defer gpa.free(warm);
    const cold: []f32 = try gpa.alloc(f32, decisions * dofs);
    defer gpa.free(cold);

    try run.start(&task.clip, 360);
    @memset(planner.applied, 0.0);
    planner.phase = 0;
    @memset(planner.nominal, 0.0);
    var decided: usize = 0;
    var f: usize = 361;
    while (decided < decisions and f < task.clip.frame_count) : (f += 1) {
        if (planner.phase % 2 == 0) {
            run.save(&moment);
            @memcpy(nominal, planner.nominal);
            @memcpy(applied, planner.applied);
            const kept_rng = planner.rng;
            for ([_][]f32{ warm, cold }, 0..) |into, variant| {
                run.restore(&moment);
                @memcpy(planner.nominal, nominal);
                if (variant == 1) {
                    @memset(planner.nominal, 0.0);
                }
                @memcpy(planner.applied, applied);
                planner.rng = .init(9000 + decided);
                try planner.choose(&task.clip, f);
                const label: []f32 = into[decided * dofs ..][0..dofs];
                for (recorder.to_planner, 0..) |j, i| {
                    const raw: Vec = planner.offsetAt(planner.best, 0.0, j);
                    label[i * 3 + 0] = raw[0] / student_scale;
                    label[i * 3 + 1] = raw[1] / student_scale;
                    label[i * 3 + 2] = raw[2] / student_scale;
                }
            }
            run.restore(&moment);
            @memcpy(planner.nominal, nominal);
            @memcpy(planner.applied, applied);
            planner.rng = kept_rng;
            try planner.choose(&task.clip, f);
            decided += 1;
        }
        _ = try planner.act(&task.clip, f);
        if (planner.run.lost(&task.clip, f)) {
            break;
        }
    }
    var memory: f64 = 0.0;
    var signal: f64 = 0.0;
    var cold_square: f64 = 0.0;
    for (0..dofs) |i| {
        var mean: f64 = 0.0;
        for (0..decided) |d| {
            mean += warm[d * dofs + i];
        }
        mean /= float64(decided);
        for (0..decided) |d| {
            const w: f64 = warm[d * dofs + i];
            const c: f64 = cold[d * dofs + i];
            memory += (w - c) * (w - c);
            signal += (w - mean) * (w - mean);
            cold_square += c * c;
        }
    }
    const cells: f64 = float64(decided * dofs);
    memory /= cells;
    signal /= cells;
    cold_square /= cells;
    report.print("\n  D5 (ii-b): {d} decisions - warm vs cold plan, same seed: apart {d:.4} per number; " ++
        "signal between states {d:.4} (memory / signal {d:.2}); cold labels' mean square {d:.4}\n", .{
        decided,
        memory,
        signal,
        memory / @max(signal, 1.0e-12),
        cold_square,
    });
    try expect(decided == decisions);
}

test "robot_geno: D5.5 - calibrating perturbed starts: how often the servo alone survives them" {
    // D5.5's calibration: perturbations should be HARD BUT RECOVERABLE - set where the servo alone survives about
    // half the time. From 30 starts across the task's dance, each perturbed (`robot_track.perturbStart`), the
    // servo alone for up to 60 frames (1 s): the share that last it, and the mean frames kept.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const levels = [_]robot_track.StartNoise{
        .{},
        .{ .pose = 0.05, .velocity = 0.25 },
        .{ .pose = 0.1, .velocity = 0.5 },
        .{ .pose = 0.2, .velocity = 1.0 },
    };
    const starts: usize = 30;
    const cap: usize = 60;
    for (levels) |noise| {
        var rng: std.Random.DefaultPrng = .init(77);
        var lasted: usize = 0;
        var frames_kept: usize = 0;
        for (0..starts) |s| {
            const from: usize = 10 + s * ((task.clip.frame_count - cap - 20) / starts);
            try run.start(&task.clip, from);
            robot_track.perturbStart(m, &run.data, noise, rng.random(), scratch);
            var f: usize = from + 1;
            while (f <= from + cap) : (f += 1) {
                _ = try run.step(&task.clip, f);
                if (run.lost(&task.clip, f)) {
                    break;
                }
            }
            frames_kept += f - from - 1;
            if (f > from + cap) {
                lasted += 1;
            }
        }
        report.print("\n  D5.5 calibration: pose {d:.2} rad, kick {d:.2} m/s - the servo alone lasts 1 s from " ++
            "{d} of {d} perturbed starts (mean {d:.1} frames)", .{
            noise.pose,
            noise.velocity,
            lasted,
            starts,
            float(frames_kept) / float(starts),
        });
    }
    report.print("\n", .{});
}

test "robot_geno: ON.2.1 - feasibility: can the servo alone, or the teacher, track the whole dance and get up?" {
    // The overnight run's first question, asked before any GPU time is spent: is each motion PHYSICALLY within
    // reach? The teacher plays every candidate out in the true simulator - it cannot be fooled by a model - so if
    // even it cannot get Geno's head back up off the floor, no learner will, however long it trains, and the
    // physics (servo authority, contacts, 60 Hz) is the work. If it can, the task is feasible and a learner's job
    // is to amortise it. For the get-up, the starts run from just before the lying pose through the rise; the
    // number that decides is the highest the head gets, against the reference's highest over the same frames.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const cap: usize = 240;
    for ([_]Motion{ .getup, .dance }) |motion| {
        const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), motion)) orelse return error.SkipZigTest;
        defer task.deinit();
        const m: *rbt.Model = &task.imported.model;
        const clip: *const dance.Clip = &task.clip;
        const head: usize = for (task.imported.names, 0..) |name, body| {
            if (std.mem.eql(u8, name, "Head")) {
                break body;
            }
        } else return error.NoHead;
        // The reference's head height at every frame, and where it is lowest (lying on the floor).
        var probe: rbt.Data = try .init(gpa, m);
        defer probe.deinit();
        const heights: []f32 = try gpa.alloc(f32, clip.frame_count);
        defer gpa.free(heights);
        var lowest: usize = 0;
        for (heights, 0..) |*height, f| {
            @memcpy(probe.pos, clip.pose(f)[clip.nq - m.nq ..]);
            probe.stage = .stale;
            rbt.kinematics(m, &probe);
            height.* = probe.body_xpos[head][2];
            if (height.* < heights[lowest]) {
                lowest = f;
            }
        }
        // The starts: for the get-up, from just before the lowest pose on through the rise; for the dance, spread.
        var starts: [6]usize = undefined;
        for (&starts, 0..) |*start, k| {
            const spread: usize = switch (motion) {
                .getup => (lowest -| 30) + k * 45,
                else => 30 + k * ((clip.frame_count - cap - 60) / starts.len),
            };
            start.* = @min(spread, clip.frame_count - cap - 2);
        }
        var run: ServoRun = undefined;
        try run.init(gpa, &task.imported, floor_friction);
        defer run.deinit();
        var planner: Planner = try .init(gpa, &run, &task.imported, d5_teacher);
        defer planner.deinit();
        report.print("\n  ON.2.1 {s}: {d} frames ({d:.1} s); the reference's head lowest {d:.2} m at frame {d}, " ++
            "highest {d:.2} m\n", .{
            @tagName(motion),
            clip.frame_count,
            float(clip.frame_count) / 60.0,
            heights[lowest],
            lowest,
            std.mem.max(f32, heights),
        });
        for (starts) |from| {
            var kept: [2]usize = undefined;
            var head_best: [2]f32 = .{ 0.0, 0.0 };
            for (0..2) |who| {
                try run.start(clip, from);
                @memset(planner.applied, 0.0);
                planner.phase = 0;
                @memset(planner.nominal, 0.0);
                var f: usize = from + 1;
                while (f <= from + cap) : (f += 1) {
                    _ = if (who == 0) try run.step(clip, f) else try planner.step(clip, f);
                    head_best[who] = @max(head_best[who], run.data.body_xpos[head][2]);
                    if (run.lost(clip, f)) {
                        break;
                    }
                }
                kept[who] = f - from - 1;
            }
            const reference_best: f32 = std.mem.max(f32, heights[from .. from + cap]);
            report.print("    from {d}: servo {d} frames (head up to {d:.2} m) | teacher {d} frames " ++
                "(head up to {d:.2} m) | the reference's head up to {d:.2} m\n", .{
                from,
                kept[0],
                head_best[0],
                kept[1],
                head_best[1],
                reference_best,
            });
        }
    }
}

test "robot_geno: ON.2.1b - the floor-to-crouch lift: a search problem or a physics problem?" {
    // ON.2.1 found the teacher cannot lift Geno off the floor (from the get-up's lying frames its head stays at
    // ~0.5 m while the reference's climbs past 1 m). Two causes need different cures, so they are separated here:
    // SEARCH - a 0.25 s horizon may be too short to find the push-up - against PHYSICS - the standing armature
    // (2.0, which multiplies every joint's inertia) makes fast movement sluggish, and the servo's acceleration
    // cap bounds its authority. Judged by the head: the highest it gets, how far below the reference's it stays
    // on average, and when the paper's rule (head 25 cm off the reference's, after 48 frames) would end it.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .getup)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clip: *const dance.Clip = &task.clip;
    const head: usize = for (task.imported.names, 0..) |name, body| {
        if (std.mem.eql(u8, name, "Head")) {
            break body;
        }
    } else return error.NoHead;
    var probe: rbt.Data = try .init(gpa, m);
    defer probe.deinit();
    const heights: []f32 = try gpa.alloc(f32, clip.frame_count);
    defer gpa.free(heights);
    for (heights, 0..) |*height, f| {
        @memcpy(probe.pos, clip.pose(f)[clip.nq - m.nq ..]);
        probe.stage = .stale;
        rbt.kinematics(m, &probe);
        height.* = probe.body_xpos[head][2];
    }
    // The armature each freedom was built with, restored at the end.
    const built: []f32 = try gpa.dupe(f32, m.dof_armature);
    defer gpa.free(built);
    defer @memcpy(m.dof_armature, built);

    const Variant = struct {
        name: []const u8,
        horizon: usize,
        samples: usize,
        armature: f32,
        max_acceleration: f32,
    };
    const variants = [_]Variant{
        .{
            .name = "A baseline",
            .horizon = d5_teacher.horizon,
            .samples = d5_teacher.samples,
            .armature = standing_armature,
            .max_acceleration = servo_gains.max_acceleration,
        },
        .{
            .name = "B more search (30 steps x 32 samples)",
            .horizon = 30,
            .samples = 32,
            .armature = standing_armature,
            .max_acceleration = servo_gains.max_acceleration,
        },
        .{
            .name = "C agile (armature 0.5)",
            .horizon = d5_teacher.horizon,
            .samples = d5_teacher.samples,
            .armature = 0.5,
            .max_acceleration = servo_gains.max_acceleration,
        },
        .{
            .name = "D agile + strong (cap 6000)",
            .horizon = d5_teacher.horizon,
            .samples = d5_teacher.samples,
            .armature = 0.5,
            .max_acceleration = 6000.0,
        },
    };
    const starts = [_]usize{ 509, 554 };
    const cap: usize = 240;
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    for (variants) |variant| {
        for (m.dof_armature, built) |*armature, original| {
            armature.* = if (original == standing_armature) variant.armature else original;
        }
        run.gains.max_acceleration = variant.max_acceleration;
        var teacher: Planner.Options = d5_teacher;
        teacher.horizon = variant.horizon;
        teacher.samples = variant.samples;
        var planner: Planner = try .init(gpa, &run, &task.imported, teacher);
        defer planner.deinit();
        report.print("\n  ON.2.1b {s}:", .{variant.name});
        for (starts) |from| {
            try run.start(clip, from);
            @memset(planner.applied, 0.0);
            planner.phase = 0;
            @memset(planner.nominal, 0.0);
            var head_best: f32 = 0.0;
            var deficit: f32 = 0.0;
            var head_rule_ends: ?usize = null;
            var f: usize = from + 1;
            while (f <= from + cap) : (f += 1) {
                _ = try planner.step(clip, f);
                const height: f32 = run.data.body_xpos[head][2];
                head_best = @max(head_best, height);
                deficit += @max(0.0, heights[f] - height);
                if (head_rule_ends == null and f - from > 48 and @abs(height - heights[f]) > 0.25) {
                    head_rule_ends = f - from;
                }
            }
            const reference_best: f32 = std.mem.max(f32, heights[from .. from + cap]);
            report.print("\n    from {d}: head up to {d:.2} m (reference {d:.2}), on average {d:.2} m below it; " ++
                "the head rule ends it at frame {?d}", .{
                from,
                head_best,
                reference_best,
                deficit / float(cap),
                head_rule_ends,
            });
        }
    }
    report.print("\n", .{});
}

/// One variant of the floor-lift trial (ON.2.1c, 2.1d): which joints the teacher plans, the ball joints'
/// armature, and how much gravity counts in its cost (`Planner.Options.height_weight`, `up_weight`).
const LiftVariant = struct {
    name: []const u8,
    /// Every ball joint in the plan, or DReCon's ten.
    every_joint: bool,
    armature: f32,
    height_weight: f32 = 0.0,
    up_weight: f32 = 0.0,
    height_tolerance: f32 = 0.0,
    up_tolerance: f32 = 0.0,
    root_height_weight: f32 = 0.0,
    /// Heights counted on the body's axis only (`axis_bodies`).
    axis: bool = false,
    /// Gravity gated by the reference's posture (`Planner.Options.posture_gate`).
    posture: bool = false,
};

/// ON.2.1's floor-lift trial: from three floor starts of the get-up (509 lying, 530, 554 the rise beginning),
/// the teacher under each variant for 4 s - the highest the head gets, against the reference's highest over the
/// same frames, and how far below the reference's head it runs on average.
fn floorLift(
    gpa: Allocator,
    io: std.Io,
    label: []const u8,
    variants: []const LiftVariant,
) !void {
    const task: *GenoTask = (try GenoTask.init(gpa, io, .getup)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clip: *const dance.Clip = &task.clip;
    const head: usize = for (task.imported.names, 0..) |name, body| {
        if (std.mem.eql(u8, name, "Head")) {
            break body;
        }
    } else return error.NoHead;
    // The reference's head height at every frame.
    var probe: rbt.Data = try .init(gpa, m);
    defer probe.deinit();
    const heights: []f32 = try gpa.alloc(f32, clip.frame_count);
    defer gpa.free(heights);
    for (heights, 0..) |*height, f| {
        @memcpy(probe.pos, clip.pose(f)[clip.nq - m.nq ..]);
        probe.stage = .stale;
        rbt.kinematics(m, &probe);
        height.* = probe.body_xpos[head][2];
    }
    // Every ball joint, for the variants that plan them all.
    var every: std.ArrayList([]const u8) = .empty;
    defer every.deinit(gpa);
    for (m.jnt_type, m.jnt_body) |kind, body| {
        if (kind == .ball) {
            try every.append(gpa, task.imported.names[body]);
        }
    }
    // The armature is changed in the built model and put back afterwards.
    const built: []f32 = try gpa.dupe(f32, m.dof_armature);
    defer gpa.free(built);
    defer @memcpy(m.dof_armature, built);
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    const starts = [_]usize{ 509, 530, 554 };
    const cap: usize = 240;
    for (variants) |variant| {
        for (m.dof_armature, built) |*value, original| {
            value.* = if (original == standing_armature) variant.armature else original;
        }
        var teacher: Planner.Options = d5_teacher;
        if (variant.every_joint) {
            teacher.actuated = every.items;
        }
        teacher.height_weight = variant.height_weight;
        teacher.up_weight = variant.up_weight;
        teacher.height_tolerance = variant.height_tolerance;
        teacher.up_tolerance = variant.up_tolerance;
        teacher.root_height_weight = variant.root_height_weight;
        if (variant.axis) {
            teacher.height_bodies = &axis_bodies;
        }
        teacher.posture_gate = variant.posture;
        var planner: Planner = try .init(gpa, &run, &task.imported, teacher);
        defer planner.deinit();
        report.print("\n  {s} {s} ({d} joints):", .{ label, variant.name, planner.joint_adr.len });
        for (starts) |from| {
            try run.start(clip, from);
            @memset(planner.applied, 0.0);
            planner.phase = 0;
            @memset(planner.nominal, 0.0);
            var head_best: f32 = 0.0;
            var deficit: f32 = 0.0;
            var f: usize = from + 1;
            while (f <= from + cap) : (f += 1) {
                _ = try planner.step(clip, f);
                const height: f32 = run.data.body_xpos[head][2];
                head_best = @max(head_best, height);
                deficit += @max(0.0, heights[f] - height);
            }
            report.print("\n    from {d}: head up to {d:.2} m (reference {d:.2}), on average {d:.2} m below it", .{
                from,
                head_best,
                std.mem.max(f32, heights[from .. from + cap]),
                deficit / float(cap),
            });
        }
    }
    report.print("\n", .{});
}

test "robot_geno: ON.2.1c - the floor lift with EVERY joint in the plan" {
    // ON.2.1b: more search changed nothing; lighter joints (armature 0.5) helped once. A search that finds
    // nothing however wide suggests the wrong SPACE: the teacher moves only DReCon's ten joints - no elbows,
    // shoulders, upper spine or neck, exactly what pushes a body off the floor. So: every ball joint in the
    // plan (E), and with armature 0.5 as well (F), from three floor starts (single runs are noisy).
    // Every ball joint, by the name of the body it moves.
    // MEASURED (Sep 26): E - 0.46 / 0.58 / 0.55 m (references 0.99 / 1.24 / 1.43); F - 0.41 / 0.52 / 0.75 m.
    // Every joint barely helps: the search space was not the problem.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1c", &.{
        .{ .name = "E every joint", .every_joint = true, .armature = standing_armature },
        .{ .name = "F every joint + armature 0.5", .every_joint = true, .armature = 0.5 },
    });
}

test "robot_geno: ON.2.1d - the floor lift with GRAVITY in the teacher's cost" {
    // Search (2.1b), agility, authority and every joint (2.1c) all failed the same way - so suspect what the
    // teacher is ASKED to do. Its cost measured the shape from the root's own position and rotation, so the
    // body's height and its tilt against gravity dropped out: lying with the right joint angles cost what
    // kneeling upright with them costs, and the only vertical signal was the fall rule's cliff. Now with
    // SuperTrack's own gravity terms (every body's height, and the up vector in the root's frame).
    // MEASURED (Sep 26): G - 0.69 / 1.12 / 1.26 m (references 0.99 / 1.24 / 1.43), H - 0.77 / 0.92 / 1.28 m with
    // the head 0.21 m below the reference's on average (G 0.32-0.34). The teacher GETS UP: gravity was missing
    // from its cost, not search, agility, authority or joints. `d5_teacher` carries the gravity terms since.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1d", &.{
        .{
            .name = "G DReCon's joints + gravity",
            .every_joint = false,
            .armature = standing_armature,
            .height_weight = 1.0,
            .up_weight = 0.3,
        },
        .{
            .name = "H every joint, armature 0.5 + gravity",
            .every_joint = true,
            .armature = 0.5,
            .height_weight = 1.0,
            .up_weight = 0.3,
        },
    });
}

test "robot_geno: ON.2.1e - the floor lift with gravity HINGED (as the teacher now plans)" {
    // Gravity at full weight got Geno off the floor (2.1d: 0.69 / 1.12 / 1.26 m) but halved the dance; counted
    // only beyond 10 cm and ~11 degrees it keeps 3.27 s of the dance's 3.65. Does the lift survive the hinge?
    // MEASURED (Sep 26): G' 0.84 / 0.70 / 0.73 m, H' 0.86 / 0.91 / 0.85 m - the rise is lost. See `d5_teacher`.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1e", &.{
        .{
            .name = "G' DReCon's joints + hinged gravity",
            .every_joint = false,
            .armature = standing_armature,
            .height_weight = 1.0,
            .up_weight = 0.3,
            .height_tolerance = 0.1,
            .up_tolerance = 0.2,
        },
        .{
            .name = "H' every joint, armature 0.5 + hinged gravity",
            .every_joint = true,
            .armature = 0.5,
            .height_weight = 1.0,
            .up_weight = 0.3,
            .height_tolerance = 0.1,
            .up_tolerance = 0.2,
        },
    });
}

test "robot_geno: ON.2.1f - the floor lift with gravity only where the shape is blind (the root's height and tilt)" {
    // 2.1e: hinging every body's height kept the dance but cost the rise (0.70-0.91 m where full weight reached
    // 1.12-1.28). The shape already holds the limbs' heights relative to the root; what it drops is the root's own
    // height and tilt - so gravity goes exactly there, unhinged.
    // MEASURED (Sep 26): G'' 0.34 / 0.65 / 0.64 m, H'' 0.36 / 0.58 / 0.99 m, and the dance 2.49 s - no: the rise is
    // led by the torso and head, not the hips. See `d5_teacher`.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1f", &.{
        .{
            .name = "G'' DReCon's joints + the root's height and tilt",
            .every_joint = false,
            .armature = standing_armature,
            .up_weight = 0.3,
            .root_height_weight = 1.0,
        },
        .{
            .name = "H'' every joint, armature 0.5 + the root's height and tilt",
            .every_joint = true,
            .armature = 0.5,
            .up_weight = 0.3,
            .root_height_weight = 1.0,
        },
    });
}

test "robot_geno: ON.2.1g - the floor lift with gravity on the body's AXIS (one cost for every clip)" {
    // One cost must serve every clip (the real set: ~100, get-ups hidden in some). The rise is led by the torso and
    // head; the dance was hurt by chasing LIMB heights. So heights on the axis only - hips, spine, neck, head - with
    // the task's own model (standing armature: the model is no per-clip switch either).
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1g", &.{
        .{
            .name = "DReCon's joints + axis gravity",
            .every_joint = false,
            .armature = standing_armature,
            .height_weight = 1.0,
            .up_weight = 0.3,
            .axis = true,
        },
        .{
            .name = "every joint + axis gravity",
            .every_joint = true,
            .armature = standing_armature,
            .height_weight = 1.0,
            .up_weight = 0.3,
            .axis = true,
        },
    });
}

test "robot_geno: ON.2.1h - the floor lift with axis gravity GATED by the reference's posture (one cost, every clip)" {
    // Axis gravity lifted Geno best yet (2.1g: 0.98 / 1.23 m from 509 / 530, the reference's 0.99 / 1.24) but taxed the
    // dance's balance dips (2.18 s of 3.65). Gated by how low the REFERENCE is, it should cost a standing dance
    // nothing and a get-up nothing of its lift.
    // MEASURED (Sep 26): 0.75 / 0.91 / 1.19 m (mean shortfall 0.24 m, ungated 0.26) and the dance 3.43 s - one cost
    // for every clip. `d5_teacher` carries it.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try floorLift(std.testing.allocator, threaded.io(), "ON.2.1h", &.{
        .{
            .name = "DReCon's joints + axis gravity, posture-gated",
            .every_joint = false,
            .armature = standing_armature,
            .height_weight = 1.0,
            .up_weight = 0.3,
            .axis = true,
            .posture = true,
        },
    });
}

test "robot_geno: ON.0b - which limit of the one failure criterion ends the servo's runs?" {
    // Under the task's own termination the teacher's dance fell from 3.43 s (the old hips-35-cm rule) to 1.24 s, so
    // the task's rule is much stricter. If one of its limits fires during NORMAL tracking, every learner's episodes
    // end for nothing. The servo alone from 12 starts in each clip, run until the reference is lost: at that
    // moment, which limits are crossed, and by how much (the limits: pose 0.35 m / 1.2 rad, root 0.6 m / 1.5 rad,
    // height 0.2 m).
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    for ([_]Motion{ .dance, .getup }) |motion| {
        const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), motion)) orelse return error.SkipZigTest;
        defer task.deinit();
        const clip: *const dance.Clip = &task.clip;
        var run: ServoRun = undefined;
        try run.init(gpa, &task.imported, floor_friction);
        defer run.deinit();
        const limits: robot_track.Termination = run.check.termination;
        const names = [_][]const u8{ "pose position", "pose rotation", "root position", "root rotation", "height" };
        var crossed: [5]usize = @splat(0);
        var sums: [5]f32 = @splat(0.0);
        var ended: usize = 0;
        var frames: usize = 0;
        const starts: usize = 12;
        for (0..starts) |k| {
            const from: usize = 20 + k * ((clip.frame_count - 340) / starts);
            try run.start(clip, from);
            var f: usize = from + 1;
            while (f <= from + 300) : (f += 1) {
                _ = try run.step(clip, f);
                if (run.lost(clip, f)) {
                    const e: robot_track.TrackingError = run.check.last;
                    const values = [_]f32{
                        e.pose_position,
                        e.pose_rotation,
                        e.root_position,
                        e.root_rotation,
                        e.height,
                    };
                    const caps = [_]f32{
                        limits.pose_position,
                        limits.pose_rotation,
                        limits.root_position,
                        limits.root_rotation,
                        limits.height,
                    };
                    for (values, caps, 0..) |value, cap, i| {
                        sums[i] += value;
                        if (value > cap) {
                            crossed[i] += 1;
                        }
                    }
                    ended += 1;
                    break;
                }
            }
            frames += f - from - 1;
        }
        report.print("\n  ON.0b {s}: the servo alone lost the reference in {d} of {d} runs (mean {d:.2} s); " ++
            "at that moment -", .{ @tagName(motion), ended, starts, float(frames) / float(starts) / 60.0 });
        for (names, crossed, sums) |name, count, sum| {
            report.print(" {s}: crossed {d}x (mean {d:.2});", .{ name, count, sum / float(@max(ended, 1)) });
        }
    }
    report.print("\n", .{});
}

test "robot_geno: ON.0b - which limit ends the TEACHER's dance runs?" {
    // The task's height limit at 0.2 or 0.4 m changed the teacher's dance little (1.24 -> 1.30 s; 3.43 s under the
    // old hips-35-cm rule) - so the teacher fails some other way than the servo. From D1's four dance starts, the
    // teacher until the reference is lost: which limits are crossed then, and the old rule's hips distance.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance)) orelse return error.SkipZigTest;
    defer task.deinit();
    const clip: *const dance.Clip = &task.clip;
    var run: ServoRun = undefined;
    try run.init(gpa, &task.imported, floor_friction);
    defer run.deinit();
    var planner: Planner = try .init(gpa, &run, &task.imported, d5_teacher);
    defer planner.deinit();
    for ([_]usize{ 360, 720, 1080, 1440 }) |from| {
        try run.start(clip, from);
        @memset(planner.applied, 0.0);
        planner.phase = 0;
        @memset(planner.nominal, 0.0);
        var f: usize = from + 1;
        var hips: f32 = 0.0;
        while (f <= from + 300) : (f += 1) {
            hips = try planner.step(clip, f);
            if (run.lost(clip, f)) {
                break;
            }
        }
        const e: robot_track.TrackingError = run.check.last;
        report.print("\n  ON.0b teacher from {d}: lost after {d:.2} s - pose {d:.2} m / {d:.2} rad, " ++
            "root {d:.2} m / {d:.2} rad, height {d:.2} m; the old rule's hips distance {d:.2} m", .{
            from,
            float(f - from - 1) / 60.0,
            e.pose_position,
            e.pose_rotation,
            e.root_position,
            e.root_rotation,
            e.height,
            hips,
        });
    }
    report.print("\n", .{});
}

test "robot_geno: FailureCheck's error IS the fleet's - every field, velocities included" {
    // "One failure criterion through one function" is only true if FailureCheck measures exactly what the fleet
    // measures. A fleet character stepped a few frames; the error computed as the fleet computes it (its state,
    // its reference at the state's frame) and through FailureCheck must agree in EVERY field. Until Sep 26 the
    // check posed only the reference's positions, so its velocity terms read whatever the judge last held.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const fleet: *robot_track.Fleet = try .init(gpa, m, &.{&task.clip}, .{
        .envs = 1,
        .capacity = 16,
        .gains = servo_gains,
        .floor_friction = floor_friction,
        .rest_on_floor = true,
    });
    defer fleet.deinit();
    const idle: []f32 = try gpa.alloc(f32, robot_track.actionSize(m));
    defer gpa.free(idle);
    @memset(idle, 0.0);
    for (0..5) |_| {
        _ = fleet.step(idle);
    }
    var sim: robot_track.State = try .init(gpa, m.nbody);
    defer sim.deinit(gpa);
    var reference: robot_track.State = try .init(gpa, m.nbody);
    defer reference.deinit(gpa);
    var probe: rbt.Data = try .init(gpa, m);
    defer probe.deinit();
    robot_track.stateOf(m, &fleet.data[0], &sim);
    fleet.referenceStateInto(&task.clip, fleet.frame[0], &probe, &reference);
    const fleets: robot_track.TrackingError = robot_track.trackingError(sim, reference, fleet.root);
    var check: FailureCheck = try .init(gpa, m);
    defer check.deinit(gpa);
    _ = check.lost(m, &fleet.data[0], &task.clip, fleet.frame[0]);
    const mine: robot_track.TrackingError = check.last;
    const pairs = [_][2]f32{
        .{ fleets.pose_position, mine.pose_position },
        .{ fleets.pose_rotation, mine.pose_rotation },
        .{ fleets.velocity, mine.velocity },
        .{ fleets.angular, mine.angular },
        .{ fleets.root_position, mine.root_position },
        .{ fleets.root_rotation, mine.root_rotation },
        .{ fleets.height, mine.height },
        .{ fleets.up, mine.up },
    };
    var worst: f32 = 0.0;
    for (pairs) |pair| {
        worst = @max(worst, @abs(pair[0] - pair[1]));
    }
    report.print("\n  FailureCheck vs the fleet: every field of the error at most {e:.2} apart " ++
        "(velocity {d:.4} vs {d:.4})\n", .{
        worst,
        fleets.velocity,
        mine.velocity,
    });
    try expect(worst < 1.0e-5);
}
