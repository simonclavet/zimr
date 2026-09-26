//! robot_mocap_tutorial - every example in robot-mocap-tutorial.html, as real code that runs.
//!
//! The deal is simple: the tutorial never shows code that isn't in here. Each example is a test,
//! so if one stops compiling - or stops doing what the text says it does - the build fails, rather
//! than the tutorial quietly teaching something that isn't true anymore.
//!
//! The page doesn't even keep copies. Each of its code blocks names the test or helper it shows
//! (`data-src` and `data-decl`), and `zig build doc-folds` fills it in from this file - the gate
//! does the same - so editing an example here IS editing the tutorial, and the two can't drift.
//!
//! Run them from the repository root, where the capture files are found by relative path:
//! `zig build zn-robot_mocap_tutorial -Dtest-filter="tutorial"`.

const std = @import("std");
const zm = @import("zm");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const rbt = @import("robot.zig");
const dance = @import("robot_dance.zig");
const zimrphysics = @import("zimrphysics.zig");
const rmx = @import("robot_maximal.zig");
const gym = @import("robot_gym.zig");
const supertrack = @import("robot_supertrack.zig");
const zn = @import("zn");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const cross = zm.cross;
const dot3 = zm.dot3;
const length3 = zm.length3;
const splat = zm.splat;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const pi = zm.pi;
const float = zm.float;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

/// The humanoid the dance is retargeted onto.
const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");
/// An older humanoid with hinge joints only - what the maximal ragdoll can build.
const flex_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex.xml");

/// Read a whole file into memory. The captures are a few megabytes at most, so there's no point
/// streaming them.
fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

/// A robot, read from MJCF. Every model goes through the same three steps: parse the XML, read it
/// as an MJCF robot description, then build the simulator's model from that description.
///
/// The model steps at 60 Hz, the capture's frame rate, so one simulator step is one frame of the
/// clip - the servo relies on that. `weld_root` bolts the root down where the model puts it, the
/// low-tech way: it leaves the free joint out of the text before parsing it.
const Robot = struct {
    text: []u8,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,

    fn load(r: *Robot, gpa: Allocator, xml: []const u8, weld_root: bool) !void {
        const free_joint: []const u8 = "<freejoint name=\"root\"/>";
        const cut: usize = if (weld_root) free_joint.len else 0;
        const at: usize = if (weld_root) std.mem.indexOf(u8, xml, free_joint) orelse return error.NoFreeJoint else 0;
        r.text = try gpa.alloc(u8, xml.len - cut);
        errdefer gpa.free(r.text);
        @memcpy(r.text[0..at], xml[0..at]);
        @memcpy(r.text[at..], xml[at + cut ..]);
        r.doc = try codecs.xml.parse(gpa, r.text, null);
        errdefer r.doc.deinit();
        r.robot = try mjcf.readRobot(gpa, &r.doc);
        errdefer r.robot.deinit();
        var options: rbt.Options = .{
            .timestep = 1.0 / 60.0,
            .gravity = vec(0, 0, -9.81),
            .max_contacts = 256,
        };
        options.solver.algorithm = .newton;
        r.imported = try robot_mjcf.build(gpa, &r.robot, options);
    }

    fn deinit(r: *Robot, gpa: Allocator) void {
        r.imported.deinit();
        r.robot.deinit();
        r.doc.deinit();
        gpa.free(r.text);
    }

    fn model(r: *Robot) *rbt.Model {
        return &r.imported.model;
    }
};

/// Find a capture joint by name, or null if the capture has no joint called that.
fn jointNamed(capture: *const codecs.bvh.Data, name: []const u8) ?usize {
    for (capture.joints, 0..) |joint, i| {
        if (std.mem.eql(u8, joint.name, name)) {
            return i;
        }
    }
    return null;
}

test "tutorial 2: a dance, retargeted onto a humanoid and servoed along" {
    const gpa: Allocator = std.testing.allocator;
    const io: std.Io = std.testing.io;

    // The capture: a dance, and the performer standing in the pose the skeleton was built in.
    const dance_bytes: []u8 = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
    defer gpa.free(dance_bytes);
    const rest_bytes: []u8 = try readFile(gpa, io, "assets/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();

    // The robot, floating: what the dance is retargeted onto.
    var floating: Robot = undefined;
    try floating.load(gpa, flex2_xml, false);
    defer floating.deinit(gpa);
    const fm: *rbt.Model = floating.model();

    // Retarget two seconds of the dance, then keep only what a body can follow (5 Hz).
    const names: []const []const u8 = floating.imported.names;
    var raw: dance.Clip = try dance.retargetClip(gpa, fm, names, &capture, &rest, .{ .seconds = 2.0 });
    defer raw.deinit();
    var clip: dance.Clip = try raw.smoothed(fm, 5.0);
    defer clip.deinit();

    // The same robot with its root welded where the model puts it, its joints limp: the servo's
    // torques are the only ones acting on them.
    var welded: Robot = undefined;
    try welded.load(gpa, flex2_xml, true);
    defer welded.deinit(gpa);
    const m: *rbt.Model = welded.model();
    dance.limpKeepArmature(m);
    // A floating pose is the root's 7 numbers, then the joints: the welded robot takes the joints.
    const root_len: usize = clip.nq - m.nq;
    const dt: f32 = clip.frame_time;
    try expect(root_len == 7 and @abs(dt - m.opt.timestep) < 1.0e-6);

    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    var tracker: dance.Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);

    // Start on the clip's second frame, moving as the clip moves into it.
    @memcpy(d.pos, clip.pose(1)[root_len..]);
    rbt.differentiatePos(m, d.vel, clip.pose(0)[root_len..], clip.pose(1)[root_len..], dt);
    d.stage = .stale;

    var worst: f32 = 0.0;
    for (1..clip.frame_count - 1) |f| {
        const before: []const f32 = clip.pose(f - 1)[root_len..];
        const now: []const f32 = clip.pose(f)[root_len..];
        const next: []const f32 = clip.pose(f + 1)[root_len..];
        // The servo: the accelerations that follow the clip, then the torques that produce them.
        rbt.forward(m, &d);
        tracker.accelerations(m, &d, .{ before, now, next }, 20.0, dt, a);
        rbt.biasForce(m, &d);
        rbt.inverseDynamics(m, &d, a, torque);
        @memcpy(d.applied_force, torque);
        rbt.step(m, &d);
        // How far every body is from where the clip's next frame puts it.
        rbt.forward(m, &d);
        @memcpy(target.pos, next);
        target.stage = .stale;
        rbt.kinematics(m, &target);
        worst = @max(worst, dance.worstBodyErrorDeg(m, d.body_xrot, target.body_xrot));
    }
    try expect(worst < 0.5);
}

test "tutorial 3: a capture - its skeleton, its channels, one frame's joints" {
    const gpa: Allocator = std.testing.allocator;
    const io: std.Io = std.testing.io;
    const bytes: []u8 = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
    defer gpa.free(bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer capture.deinit();

    // Ten seconds at 60 frames a second.
    try expect(capture.frame_count == 600);
    try expect(@abs(capture.frame_time - 1.0 / 60.0) < 1.0e-5);

    // A tree whose parents come before their children: the root is joint 0, with no parent.
    const hips: usize = jointNamed(&capture, "Hips") orelse return error.NoHips;
    const head: usize = jointNamed(&capture, "Head") orelse return error.NoHead;
    try expect(hips == 0 and capture.joints[hips].parent == -1);
    for (capture.joints, 0..) |joint, i| {
        try expect(joint.parent < @as(i32, @intCast(i)));
    }
    // Each joint lists its own channels, in the order the frame's numbers come in. In this capture
    // every joint has six: a position, then a rotation applied Z, then Y, then X. End sites - the
    // tips of the chains, kept as joints so a bone can be drawn to them - have none.
    const expected = [_]codecs.bvh.Channel{
        .x_position, .y_position, .z_position,
        .z_rotation, .y_rotation, .x_rotation,
    };
    var channels: usize = 0;
    for (capture.joints) |joint| {
        if (joint.end_site) {
            try expect(joint.channels.len == 0);
            continue;
        }
        try expect(std.mem.eql(codecs.bvh.Channel, joint.channels, &expected));
        channels += joint.channels.len;
    }
    // A frame is every joint's channels, one after another.
    try expect(capture.channel_count == channels and capture.frame(0).len == channels);

    // One frame's forward kinematics: every joint's rotation in the capture's world, then every
    // joint's position relative to the root.
    const n: usize = capture.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    var root: Vec = vec_zero;
    dance.globalsAtFrame(&capture, 0, local, global, &root);
    dance.bvhPoints(&capture, global, points);

    // In the capture's own axes Y is up, and positions are in centimetres: the head is well
    // above the hips.
    try expect(points[head][1] - points[hips][1] > 40.0);
}

test "tutorial 4: into the robot's frame - a rotation, never a swizzle" {
    const gpa: Allocator = std.testing.allocator;
    const io: std.Io = std.testing.io;

    // The capture's Y-up space becomes the robot's Z-up one by a quarter turn about X, and
    // centimetres become metres: a capture's "one metre up" is the robot's.
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    const up: Vec = dance.toRobot(.rotate, to_robot, vec(0, 100, 0));
    try expect(length3(up - vec(0, 0, 1)) < 1.0e-6);

    // Handedness: (left arm - right arm) x (head - hips) . (left toe - left foot). A rotation
    // keeps its sign; a swizzle - swapping Y and Z - is a reflection, and flips it.
    const bytes: []u8 = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
    defer gpa.free(bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer capture.deinit();
    const n: usize = capture.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    var root: Vec = vec_zero;
    dance.globalsAtFrame(&capture, 0, local, global, &root);
    dance.bvhPoints(&capture, global, points);
    const names = [_][]const u8{ "LeftArm", "RightArm", "Head", "Hips", "LeftToeBase", "LeftFoot" };
    var at: [6]Vec = undefined;
    var rotated: [6]Vec = undefined;
    var swizzled: [6]Vec = undefined;
    for (names, 0..) |name, i| {
        const j: usize = jointNamed(&capture, name) orelse return error.MissingJoint;
        at[i] = points[j];
        rotated[i] = dance.toRobot(.rotate, to_robot, points[j]);
        swizzled[i] = dance.toRobot(.swizzle, to_robot, points[j]);
    }
    const hand = struct {
        fn of(p: [6]Vec) f32 {
            return dot3(cross(p[0] - p[1], p[2] - p[3]), p[4] - p[5]);
        }
    };
    try expect(hand.of(at) * hand.of(rotated) > 0.0);
    try expect(hand.of(at) * hand.of(swizzled) < 0.0);
}

test "tutorial 5: the robot's coordinates - joints, poses and velocities" {
    const gpa: Allocator = std.testing.allocator;
    var r: Robot = undefined;
    try r.load(gpa, flex2_xml, false);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();

    // Each joint owns a run of `pos` and a run of `vel`: the free root 7 and 6, a ball 4 and 3 (a
    // quaternion, and an angular velocity), a hinge 1 and 1.
    for (0..m.njnt) |j| {
        const sizes: [2]u32 = switch (m.jnt_type[j]) {
            .free => .{ 7, 6 },
            .ball => .{ 4, 3 },
            .hinge, .slide => .{ 1, 1 },
        };
        const pos_end: u32 = if (j + 1 < m.njnt) m.jnt_qpos_adr[j + 1] else m.nq;
        const vel_end: u32 = if (j + 1 < m.njnt) m.jnt_dof_adr[j + 1] else m.nv;
        try expect(pos_end - m.jnt_qpos_adr[j] == sizes[0]);
        try expect(vel_end - m.jnt_dof_adr[j] == sizes[1]);
    }

    // A pose moved along a velocity for a time, and the velocity recovered from the two poses:
    // `integratePos` and `differentiatePos` are each other's inverse, quaternions included.
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    d.reset(m);
    for (d.vel, 0..) |*v, k| {
        v.* = 0.3 * (float(k % 5) - 2.0);
    }
    const moved: []f32 = try gpa.dupe(f32, d.pos);
    defer gpa.free(moved);
    rbt.integratePos(m, moved, d.vel, 0.1);
    const recovered: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(recovered);
    rbt.differentiatePos(m, recovered, d.pos, moved, 0.1);
    for (recovered, d.vel) |got, want| {
        try expect(@abs(got - want) < 1.0e-3);
    }

    // A body's velocity, from the forward pass: `bodyVelocity`, checked against the body's own
    // centre of mass moved a millisecond along the same velocity.
    rbt.forward(m, &d);
    const hand: usize = for (r.imported.names, 0..) |name, b| {
        if (std.mem.eql(u8, name, "hand_right")) {
            break b;
        }
    } else return error.NoHand;
    const velocity: rbt.Motion = dance.bodyVelocity(m, &d, hand);
    var later: rbt.Data = try rbt.Data.init(gpa, m);
    defer later.deinit();
    @memcpy(later.pos, d.pos);
    rbt.integratePos(m, later.pos, d.vel, 1.0e-3);
    later.stage = .stale;
    rbt.kinematics(m, &later);
    const moved_by: Vec = (later.body_xipos[hand] - d.body_xipos[hand]) * splat(1.0 / 1.0e-3);
    try expect(length3(moved_by - velocity.lin) < 0.01 * length3(velocity.lin) + 1.0e-3);
}

/// Find a robot body by name, or null if there isn't one.
fn bodyNamed(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, b| {
        if (std.mem.eql(u8, candidate, name)) {
            return b;
        }
    }
    return null;
}

/// The biggest acceleration any DOF of the clip asks for, from second differences of its poses.
/// A blunt instrument, but it's exactly where mocap jitter shows up.
fn peakAcceleration(gpa: Allocator, m: *const rbt.Model, clip: *const dance.Clip) !f32 {
    const v0: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(v0);
    const v1: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(v1);
    var peak: f32 = 0.0;
    for (1..clip.frame_count - 1) |f| {
        rbt.differentiatePos(m, v0, clip.pose(f - 1), clip.pose(f), clip.frame_time);
        rbt.differentiatePos(m, v1, clip.pose(f), clip.pose(f + 1), clip.frame_time);
        for (v0, v1) |a, b| {
            peak = @max(peak, @abs(b - a) / clip.frame_time);
        }
    }
    return peak;
}

test "tutorial 6: retargeting - one second of the dance, and what the IK achieved" {
    const gpa: Allocator = std.testing.allocator;
    const io: std.Io = std.testing.io;
    const dance_bytes: []u8 = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
    defer gpa.free(dance_bytes);
    const rest_bytes: []u8 = try readFile(gpa, io, "assets/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var r: Robot = undefined;
    try r.load(gpa, flex2_xml, false);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();
    const names: []const []const u8 = r.imported.names;

    // The match table: which capture joint drives each robot body, by name.
    const human_names: [][]const u8 = try gpa.alloc([]const u8, capture.joints.len);
    defer gpa.free(human_names);
    for (capture.joints, 0..) |joint, i| {
        human_names[i] = joint.name;
    }
    const human_of_body: []i32 = try gpa.alloc(i32, names.len);
    defer gpa.free(human_of_body);
    try rbt.resolveMatchTable(&rbt.lafan_to_humanoid, names, human_names, human_of_body);
    const thigh: usize = bodyNamed(names, "thigh_left") orelse return error.NoThigh;
    try expect(std.mem.eql(u8, human_names[@intCast(human_of_body[thigh])], "LeftUpLeg"));

    // One second of the dance.
    var clip: dance.Clip = try dance.retargetClip(gpa, m, names, &capture, &rest, .{ .seconds = 1.0 });
    defer clip.deinit();

    // Every frame: each matched body within centimetres of where the skeleton asked for it, and
    // every hinge inside its range.
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    const lowest: []f32 = try gpa.alloc(f32, clip.frame_count);
    defer gpa.free(lowest);
    for (0..clip.frame_count) |f| {
        try expect(clip.residual[f] < 0.15);
        const pose: []const f32 = clip.pose(f);
        for (0..m.njnt) |j| {
            const range: [2]f32 = m.jnt_range[j] orelse continue;
            if (m.jnt_type[j] == .hinge) {
                const angle: f32 = pose[m.jnt_qpos_adr[j]];
                try expect(angle >= range[0] - 1.0e-3 and angle <= range[1] + 1.0e-3);
            }
        }
        @memcpy(d.pos, pose);
        d.stage = .stale;
        rbt.forward(m, &d);
        lowest[f] = dance.lowestFootPoint(m, &d, names);
    }
    // Grounded: in the typical frame, the lowest point of the feet is on the floor.
    std.mem.sort(f32, lowest, {}, std.sort.asc(f32));
    try expect(@abs(lowest[lowest.len / 2]) < 0.005);

    // Filtered: the capture's jitter shows as acceleration, and the 5 Hz low-pass removes it.
    var smooth: dance.Clip = try clip.smoothed(m, 5.0);
    defer smooth.deinit();
    try expect(try peakAcceleration(gpa, m, &smooth) < try peakAcceleration(gpa, m, &clip));
}

/// One arm on one hinge, hanging from the world: a servo with nothing else going on.
const arm_xml: []const u8 =
    \\<mujoco model="arm">
    \\  <worldbody>
    \\    <body name="arm" pos="0 0 1">
    \\      <joint name="hinge" type="hinge" axis="0 1 0"/>
    \\      <geom type="capsule" fromto="0 0 0 0.4 0 0" size="0.04" mass="1"/>
    \\    </body>
    \\  </worldbody>
    \\</mujoco>
;

test "tutorial 7a: a held target - the spring alone" {
    const gpa: Allocator = std.testing.allocator;
    var r: Robot = undefined;
    try r.load(gpa, arm_xml, false);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var tracker: dance.Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);

    // The same pose three times: no motion to follow, so the reference's velocity and acceleration
    // are zero and what is left is the spring - critically damped at 2 Hz, toward 1 rad.
    const goal = [_]f32{1.0};
    d.reset(m);
    var overshoot: f32 = 0.0;
    for (0..60) |_| {
        rbt.forward(m, &d);
        tracker.accelerations(m, &d, .{ &goal, &goal, &goal }, 2.0, m.opt.timestep, a);
        rbt.biasForce(m, &d);
        rbt.inverseDynamics(m, &d, a, torque);
        @memcpy(d.applied_force, torque);
        rbt.step(m, &d);
        overshoot = @max(overshoot, d.pos[0] - 1.0);
    }
    // One second later: there, without ever going past.
    try expect(@abs(d.pos[0] - 1.0) < 0.01);
    try expect(overshoot < 1.0e-4);
}

test "tutorial 7b: a moving target followed exactly - and what passive forces do to it" {
    const gpa: Allocator = std.testing.allocator;
    var r: Robot = undefined;
    try r.load(gpa, flex2_xml, true);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();
    const shoulder: usize = for (0..m.njnt) |j| {
        if (std.mem.eql(u8, r.robot.joints[j].name, "shoulder1_right")) {
            break j;
        }
    } else return error.NoShoulder;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    var tracker: dance.Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const dt: f32 = m.opt.timestep;
    // Three consecutive reference poses: the rest pose, with the shoulder swinging at 1 Hz.
    var poses: [3][]f32 = undefined;
    for (&poses) |*p| {
        p.* = try gpa.dupe(f32, m.qpos0);
    }
    defer for (poses) |p| gpa.free(p);
    const angleAt = struct {
        fn at(t: f32) f32 {
            return 0.5 * @sin(2.0 * pi * t);
        }
    }.at;

    // Twice: the model as written, then limp.
    var worst: [2]f32 = .{ 0.0, 0.0 };
    for (0..2) |pass| {
        if (pass == 1) {
            dance.limpKeepArmature(m);
        }
        d.reset(m);
        d.pos[m.jnt_qpos_adr[shoulder]] = angleAt(dt);
        d.vel[m.jnt_dof_adr[shoulder]] = (angleAt(dt) - angleAt(0.0)) / dt;
        for (1..120) |k| {
            for (&poses, 0..) |p, i| {
                p[m.jnt_qpos_adr[shoulder]] = angleAt(float(k + i - 1) * dt);
            }
            d.stage = .stale;
            rbt.forward(m, &d);
            tracker.accelerations(m, &d, .{ poses[0], poses[1], poses[2] }, 20.0, dt, a);
            rbt.biasForce(m, &d);
            rbt.inverseDynamics(m, &d, a, torque);
            @memcpy(d.applied_force, torque);
            rbt.step(m, &d);
            rbt.forward(m, &d);
            @memcpy(target.pos, poses[2]);
            target.stage = .stale;
            rbt.kinematics(m, &target);
            worst[pass] = @max(worst[pass], dance.worstBodyErrorDeg(m, d.body_xrot, target.body_xrot));
        }
    }
    // Limp, the arm follows within a tenth of a degree; as written, the model's own joint springs
    // and dampers - forces inverse dynamics never saw - pull it off by several times as much.
    try expect(worst[1] < 0.1);
    try expect(worst[0] > 5.0 * worst[1]);
}

test "tutorial 8: what the floor must supply to perform a clip" {
    const gpa: Allocator = std.testing.allocator;
    const io: std.Io = std.testing.io;
    const dance_bytes: []u8 = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
    defer gpa.free(dance_bytes);
    const rest_bytes: []u8 = try readFile(gpa, io, "assets/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, dance_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var r: Robot = undefined;
    try r.load(gpa, flex2_xml, false);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();
    var raw: dance.Clip = try dance.retargetClip(gpa, m, r.imported.names, &capture, &rest, .{ .seconds = 1.0 });
    defer raw.deinit();
    var clip: dance.Clip = try raw.smoothed(m, 5.0);
    defer clip.deinit();

    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    const v_next: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(v_next);
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const force: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(force);
    var mass: f32 = 0.0;
    for (m.body_mass) |body_mass| {
        mass += body_mass;
    }
    const weight: f32 = mass * 9.81;

    // Inverse dynamics of the clip itself, on the FLOATING body: the generalized force that
    // performs each frame exactly. Its first six rows belong to the free root - which nothing
    // actuates - so they are what the world must apply: the floor, through the feet. Rows 0-2 are
    // a force in world axes.
    const dt: f32 = clip.frame_time;
    var vertical_sum: f32 = 0.0;
    var pulling: usize = 0;
    var slipping: usize = 0;
    for (1..clip.frame_count - 1) |f| {
        @memcpy(d.pos, clip.pose(f));
        rbt.differentiatePos(m, d.vel, clip.pose(f - 1), clip.pose(f), dt);
        rbt.differentiatePos(m, v_next, clip.pose(f), clip.pose(f + 1), dt);
        for (a, d.vel, v_next) |*acc, v0, v1| {
            acc.* = (v1 - v0) / dt;
        }
        d.stage = .stale;
        rbt.forward(m, &d);
        rbt.biasForce(m, &d);
        rbt.inverseDynamics(m, &d, a, force);
        const vertical: f32 = force[2];
        const horizontal: f32 = @sqrt(force[0] * force[0] + force[1] * force[1]);
        vertical_sum += vertical;
        // A floor can only push (vertical > 0), and only so far sideways (friction 0.7).
        if (vertical < 0.0) {
            pulling += 1;
        } else if (horizontal > 0.7 * vertical) {
            slipping += 1;
        }
    }
    // On average the floor carries the body's weight; frame by frame it would have to do more
    // than a floor can.
    const mean_vertical: f32 = vertical_sum / float(clip.frame_count - 2);
    try expect(@abs(mean_vertical - weight) < 0.25 * weight);
    try expect(pulling + slipping < clip.frame_count);
}

test "tutorial 9: a ragdoll - the same humanoid as rigid bodies, joints and motors" {
    const gpa: Allocator = std.testing.allocator;
    var r: Robot = undefined;
    try r.load(gpa, flex_xml, true);
    defer r.deinit(gpa);
    const m: *rbt.Model = r.model();
    var rest: rbt.Data = try rbt.Data.init(gpa, m);
    defer rest.deinit();
    rest.reset(m);
    rbt.forward(m, &rest);

    // A physics world, and the humanoid rebuilt in it: a rigid body per jointed body, a revolute
    // joint per hinge, a swing-twist joint where a body carries two or three hinges.
    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, 0);
    world.settings.allow_sleeping = false;
    var ragdoll: rmx.Ragdoll = try rmx.build(gpa, &world, m, &rest, .{});
    defer ragdoll.deinit();

    // A target: the rest pose with the right elbow bent. The motors drive every joint toward it.
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    target.reset(m);
    const elbow: usize = for (0..m.njnt) |j| {
        if (std.mem.eql(u8, r.robot.joints[j].name, "elbow_right")) {
            break j;
        }
    } else return error.NoElbow;
    target.pos[m.jnt_qpos_adr[elbow]] = -0.8;
    rbt.forward(m, &target);
    for (0..240) |_| {
        ragdoll.driveToPose(&world, m, &target, .{ .frequency = 4.0 });
        try zimrphysics.step(&world, 1.0 / 60.0);
    }

    // Four seconds later every body is where the target pose puts it. (A chain of soft motors
    // settles more slowly than one spring would: at two seconds the arm is still a degree off.)
    const rotations: []Quat = try gpa.alloc(Quat, m.nbody);
    defer gpa.free(rotations);
    rotations[0] = target.body_xrot[0];
    for (1..m.nbody) |b| {
        rotations[b] = ragdoll.robotBodyFrame(&world, b).rot;
    }
    try expect(dance.worstBodyErrorDeg(m, rotations, target.body_xrot) < 0.5);

    // humanoid_flex2 has ball joints, which the ragdoll does not build.
    var ball: Robot = undefined;
    try ball.load(gpa, flex2_xml, true);
    defer ball.deinit(gpa);
    var ball_rest: rbt.Data = try rbt.Data.init(gpa, ball.model());
    defer ball_rest.deinit();
    ball_rest.reset(ball.model());
    rbt.forward(ball.model(), &ball_rest);
    var other: zimrphysics.World = try .init(gpa, 64);
    defer other.deinit(gpa);
    try expectError(error.UnsupportedJoint, rmx.build(gpa, &other, ball.model(), &ball_rest, .{}));
}

test "tutorial 10a: the humanoid gym, and one iteration of PPO" {
    const gpa: Allocator = std.testing.allocator;
    const env: *gym.HumanoidEnv = try .init(gpa, flex2_xml, .{});
    defer env.deinit();
    const observation: []f32 = try gpa.alloc(f32, env.observationSize());
    defer gpa.free(observation);
    const action: []f32 = try gpa.alloc(f32, env.actionSize());
    defer gpa.free(action);

    // An episode starts near the reference pose. An action offsets the pose the joints are servoed
    // toward; the reward pays for staying up and moving forward.
    try env.reset(1, observation);
    @memset(action, 0.0);
    const result: gym.StepResult = try env.step(action, observation);
    try expect(!result.terminated and result.reward > 0.0);

    // PPO: fill a rollout with the current policy, then update on it one minibatch at a time -
    // the unit a frame can afford.
    const trainer: *gym.PpoTrainer = try .init(gpa, env, .{ .horizon = 256, .minibatch = 64, .epochs = 2 });
    defer trainer.deinit();
    while (!trainer.rolloutFull()) {
        _ = try trainer.collect(64);
    }
    while (!try trainer.updateSlice()) {}
    try expect(trainer.last.samples == 256);
}

test "tutorial 10b: SAC - act, remember, update" {
    const gpa: Allocator = std.testing.allocator;
    const agent: *gym.SacAgent = try .init(gpa, zn.cartpole_state_dim, zn.cartpole_action_dim, .{
        .warmup = 64,
        .batch = 32,
    });
    defer agent.deinit();
    var obs: [4]f32 = undefined;
    var next_obs: [4]f32 = undefined;
    var action: [1]f32 = undefined;
    var episode: u32 = 0;
    var state = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode, .hold);
    try zn.cartpoleObserve(f32, state, &obs);
    const alpha_before: f64 = agent.temperature.alpha();

    // Every step: act with the stochastic policy, remember the transition, update from the replay.
    for (0..400) |_| {
        agent.act(&obs, &action, false);
        const stepped = zn.cartpoleTaskStep(f32, state, 10.0 * action[0], .hold);
        try zn.cartpoleObserve(f32, stepped.state, &next_obs);
        try agent.remember(&obs, &action, stepped.reward, &next_obs, stepped.failed);
        try agent.update();
        state = stepped.state;
        obs = next_obs;
        if (stepped.failed) {
            episode += 1;
            state = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode, .hold);
            try zn.cartpoleObserve(f32, state, &obs);
        }
    }
    // The squashed actions stay in [-1, 1]; after the warmup every step updated; and the
    // temperature has moved toward the entropy it targets.
    try expect(@abs(action[0]) <= 1.0);
    try expect(agent.updates == 400 - 64 + 1);
    try expect(agent.temperature.alpha() != alpha_before);
}

test "tutorial 11: SuperTrack on the cartpole - supervised, with no reward and no critic" {
    const gpa: Allocator = std.testing.allocator;
    const st: *supertrack.SuperTrack = try .init(gpa, .{});
    defer st.deinit();
    const envs: usize = 8;
    var states: [envs]zn.CartpoleState(f32) = undefined;
    var steps: [envs]u32 = @splat(0);
    var segments: [envs]u32 = undefined;
    var next_segment: u32 = 0;
    var episode: u32 = 0;
    for (0..envs) |e| {
        states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
        episode += 1;
        segments[e] = next_segment;
        next_segment += 1;
    }

    var first_loss: ?f32 = null;
    var last_loss: f32 = 0.0;
    for (0..150) |_| {
        // Gather: the current policy with noise, a push to each pole every so often. A push or a
        // reset starts a new SEGMENT, so no training window spans one.
        for (0..4) |_| {
            for (0..envs) |e| {
                if (steps[e] > 0 and steps[e] % supertrack.push_every == 0) {
                    states[e].pole_rate_rad += supertrack.push_size * (2.0 * st.rng.random().float(f32) - 1.0);
                    segments[e] = next_segment;
                    next_segment += 1;
                }
                const force: f32 = st.act(supertrack.fromCartpole(states[e]), true);
                st.remember(e, supertrack.fromCartpole(states[e]), force, segments[e]);
                const stepped = zn.cartpoleContinuousStep(f32, states[e], force);
                steps[e] += 1;
                if (stepped.failed or steps[e] >= supertrack.episode_cap) {
                    states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
                    episode += 1;
                    steps[e] = 0;
                    segments[e] = next_segment;
                    next_segment += 1;
                } else {
                    states[e] = stepped.state;
                }
            }
        }
        // Learn: the world model from real windows, then the policy through the world model.
        if (try st.trainWorld()) |loss| {
            first_loss = first_loss orelse loss;
            last_loss = loss;
        }
        _ = try st.trainPolicy();
    }
    // The world model has learned the cartpole's dynamics well enough to halve its error.
    try expect(last_loss < 0.5 * (first_loss orelse return error.NeverTrained));
}
