//! robot_dance.zig — a mocap clip retargeted onto a robot, as one target pose per frame.
//!
//! This is `dance_track`'s startup pipeline, moved into the library so that it can be measured
//! headlessly: the capture's forward kinematics, the point samples, the retargeted skeleton, and
//! the point-cloud IK that turns them into the robot's joint coordinates, frame after frame, each
//! solve warm-started from the last. What comes out is exactly what a controller is asked to
//! follow — so the question "can the robot follow a pose that came from a retargeted animation"
//! splits into two that can each be answered alone:
//!
//!   * are the TARGETS any good — does the IK reach them, are they smooth, are they inside the
//!     joint limits (drecon2.md 0as asked all three and never measured them); and
//!   * can the robot TRACK them (the tests at the bottom, both engines, fixed base).
//!
//! ── UNITS AND AXES ──
//!
//! BVH is centimetres and Y-up; the robot is metres and Z-up. Positions are converted as
//! (x, z, y) * 0.01 — the swizzle `dance_track` uses. The root's HORIZONTAL motion is taken
//! relative to the clip's first frame and its height absolute, so the dance starts over the
//! origin. Capture ROTATIONS stay in the BVH frame on purpose: the samples' offsets are built
//! against the T-pose in that same frame, so the two cancel (drecon2.md 0ad, "the frames were
//! mixed", is what happens when only one side is converted).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const rbt = @import("robot.zig");
const codecs = @import("codecs.zig");

const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const qmul = zm.qmul;
const rotate = zm.rotate;
const length3 = zm.length3;
const normalize3 = zm.normalize3;
const splat = zm.splat;
const radFromDeg = zm.radFromDeg;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const quat_identity = zm.quat_identity;
const float = zm.float;
const pi = zm.pi;
const acosRad = zm.acosRad;
const asinRad = zm.asinRad;
const deg_per_rad = zm.deg_per_rad;
const conjugate = zm.conjugate;
const assertf = zm.assertf;
const clamp = zm.clamp;
const dot3 = zm.dot3;
const dot4 = zm.dot4;
const atan2Rad = zm.atan2Rad;
const cross = zm.cross;
const expectEqual = std.testing.expectEqual;

/// Point samples and IK tasks a robot can ask for; the humanoids ask for 40-70.
const max_samples: usize = 256;

/// How a BVH capture's space gets turned into the robot's.
///
/// BVH files are almost always Y-up and in centimetres; our robots are Z-up and in metres. That
/// sounds like a one-liner - swap Y and Z, divide by a hundred - and that's exactly the trap:
/// swapping two axes is a MIRROR, not a rotation. The dancer comes out left-handed, and nothing looks
/// broken, because a mirrored dance is still a perfectly good dance. `.rotate` is the real conversion
/// (a quarter turn about X); `.swizzle` is kept around so you can see the difference for yourself.
pub const FrameConvert = enum {
    /// Positions (x, y, z) -> (x, z, y), rotations left in the BVH frame — `dance_track`'s.
    /// ★★★ Swapping two axes is a REFLECTION (determinant -1), not a rotation: it mirrors the
    /// capture left-for-right while the match table still sends its left leg to the robot's.
    swizzle,
    /// A proper rotation, +90 degrees about X: positions (x, y, z) -> (x, -z, y), and every
    /// rotation conjugated by the same, q' = R q R^-1, so positions and rotations agree.
    rotate,
};

/// The knobs for `retargetClip`: how much of the capture to use, how to convert its axes, and how
/// the IK behaves from one frame to the next. The defaults are what the dance uses - most of the
/// time you only set `seconds`.
pub const RetargetOptions = struct {
    /// How many seconds of the capture to retarget, from its start (capped at its length).
    seconds: f32,
    /// How to bring the capture into the robot's axes. Leave it at `.rotate` (see `FrameConvert`).
    convert: FrameConvert = .rotate,
    /// Extra solves of the first frame, each starting from the answer before. Every later frame
    /// starts from the frame before it, which is already close; the first has nothing to start
    /// from but the rest pose, so it gets a few more goes to settle.
    settle_passes: u32 = 8,
    /// How strongly the IK holds on to the previous frame's pose. A humanoid has more joints than
    /// the capture pins down, and without this pull the spare ones wander from frame to frame; too
    /// strong, and the robot lags behind the performer (`PointCloudOptions.posture_weight`).
    posture_weight: f32 = 0.15,
    /// Raise or lower the whole clip so the feet land on the floor (z = 0) in the typical frame.
    ///
    /// The IK puts the robot's hips where the performer's hips are, but the robot's legs aren't the
    /// performer's legs, so its feet end up floating above the floor or sunk into it - and a real
    /// floor would shove them around every single frame. One vertical offset fixes most of that:
    /// the median, over the clip, of each frame's lowest foot point (the median, because a dancer
    /// spends most of the time with a foot down). A floor-aware IK would be the finer fix. Feet are
    /// the bodies with "foot" in their name.
    ground: bool = true,
};

/// A retargeted clip: one complete robot pose (`qpos`) per frame, plus a note of how well the IK
/// managed on each frame.
///
/// It's plain data on purpose. Everything downstream - the servo, the gym, SuperTrack - just reads
/// poses out of it with `pose(f)` and doesn't care how they were made.
pub const Clip = struct {
    gpa: Allocator,
    frame_count: usize,
    /// Seconds per frame, from the capture.
    frame_time: f32,
    nq: usize,
    /// `frame_count * nq` — frame f's pose is `targets[f * nq ..][0..nq]`.
    targets: []f32,
    /// Per frame: the worst distance, over matched bodies, between where the IK put a body and
    /// where the retargeted skeleton asked for it.
    residual: []f32,
    residual_body: []u32,

    pub fn deinit(self: *Clip) void {
        self.gpa.free(self.targets);
        self.gpa.free(self.residual);
        self.gpa.free(self.residual_body);
    }

    /// The first bytes of a baked clip, with the format's version as its last digit.
    pub const baked_magic: [8]u8 = "ZCLIP001".*;

    const BakedHeader = extern struct {
        magic: [8]u8,
        nq: u32,
        frame_count: u32,
        frame_time: f32,
        reserved: u32 = 0,
    };

    /// This clip as a compact binary: its targets, its per-frame IK residuals and their bodies,
    /// exactly as they are in memory. Retargeting, filtering, windowing and lifting are all done
    /// BEFORE baking, so a page that embeds the result skips them - a few hundred kilobytes
    /// instead of megabytes of capture text, and no inverse kinematics at startup. The caller owns
    /// the bytes.
    pub fn toBytes(self: *const Clip, gpa: Allocator) ![]u8 {
        const header: BakedHeader = .{
            .magic = baked_magic,
            .nq = @intCast(self.nq),
            .frame_count = @intCast(self.frame_count),
            .frame_time = self.frame_time,
        };
        const parts = [_][]const u8{
            std.mem.asBytes(&header),
            std.mem.sliceAsBytes(self.targets),
            std.mem.sliceAsBytes(self.residual),
            std.mem.sliceAsBytes(self.residual_body),
        };
        var total: usize = 0;
        for (parts) |part| {
            total += part.len;
        }
        const bytes: []u8 = try gpa.alloc(u8, total);
        var at: usize = 0;
        for (parts) |part| {
            @memcpy(bytes[at..][0..part.len], part);
            at += part.len;
        }
        return bytes;
    }

    /// And back: a clip from baked bytes, or an error saying why not. Copied into aligned memory -
    /// embedded bytes owe nothing to alignment.
    pub fn fromBytes(gpa: Allocator, bytes: []const u8) !Clip {
        if (bytes.len < @sizeOf(BakedHeader)) {
            return error.NotABakedClip;
        }
        const header: BakedHeader = std.mem.bytesToValue(BakedHeader, bytes[0..@sizeOf(BakedHeader)]);
        if (!std.mem.eql(u8, &header.magic, &baked_magic)) {
            return error.NotABakedClip;
        }
        const frames: usize = header.frame_count;
        const nq: usize = header.nq;
        const expected: usize = @sizeOf(BakedHeader) + frames * nq * 4 + frames * 4 + frames * 4;
        if (bytes.len != expected) {
            return error.NotABakedClip;
        }
        const targets: []f32 = try gpa.alloc(f32, frames * nq);
        errdefer gpa.free(targets);
        const residual: []f32 = try gpa.alloc(f32, frames);
        errdefer gpa.free(residual);
        const residual_body: []u32 = try gpa.alloc(u32, frames);
        var at: usize = @sizeOf(BakedHeader);
        for ([_][]u8{
            std.mem.sliceAsBytes(targets),
            std.mem.sliceAsBytes(residual),
            std.mem.sliceAsBytes(residual_body),
        }) |part| {
            @memcpy(part, bytes[at..][0..part.len]);
            at += part.len;
        }
        return .{
            .gpa = gpa,
            .frame_count = frames,
            .frame_time = header.frame_time,
            .nq = nq,
            .targets = targets,
            .residual = residual,
            .residual_body = residual_body,
        };
    }

    /// A stretch of this clip, `count` frames from `first`, as a clip of its own.
    ///
    /// Learning a skill usually wants only the part of a capture where the skill happens - five
    /// seconds of getting up, not the fall before it and the standing after - and a clip that
    /// starts where the interesting part starts makes reference-state starts land in it too.
    pub fn window(self: *const Clip, first: usize, count: usize) !Clip {
        assertf(count > 1 and first + count <= self.frame_count, @src(), "frames {d}..{d} of {d}", .{
            first,
            first + count,
            self.frame_count,
        });
        const targets: []f32 = try self.gpa.dupe(f32, self.targets[first * self.nq ..][0 .. count * self.nq]);
        errdefer self.gpa.free(targets);
        const residual: []f32 = try self.gpa.dupe(f32, self.residual[first..][0..count]);
        errdefer self.gpa.free(residual);
        const residual_body: []u32 = try self.gpa.dupe(u32, self.residual_body[first..][0..count]);
        return .{
            .gpa = self.gpa,
            .frame_count = count,
            .frame_time = self.frame_time,
            .nq = self.nq,
            .targets = targets,
            .residual = residual,
            .residual_body = residual_body,
        };
    }

    pub fn pose(self: *const Clip, frame: usize) []const f32 {
        return self.targets[frame * self.nq ..][0..self.nq];
    }

    /// A smoothed copy of the clip: its motion low-passed at `cutoff_hz`, with no delay.
    ///
    /// Why bother? Mocap is jittery at the millimetre level. You'd never see it in the poses, but a servo
    /// follows the clip's ACCELERATION, and acceleration is where jitter gets loud: at 60 frames a
    /// second, one millimetre of noise is about 9 m/s^2, and something has to push that hard to follow
    /// it. Around 5 Hz keeps everything a body can actually do.
    ///
    /// Why in velocity space? Because you can't just blur `qpos`: averaging quaternions doesn't give you a
    /// unit quaternion. So the poses are turned into velocities with `differentiatePos`, each DOF's
    /// velocity is smoothed with a Gaussian (sigma = 1 / (2 pi cutoff), about -4.3 dB at the cutoff, and
    /// symmetric, so there's no phase lag), and the clip is integrated back up from its first pose with
    /// `integratePos`. Quaternions stay quaternions, and hinges are clamped back into their ranges at the
    /// end.
    pub fn smoothed(
        self: *const Clip,
        m: *const rbt.Model,
        cutoff_hz: f32,
    ) !Clip {
        const gpa: Allocator = self.gpa;
        const nv: usize = m.nv;
        const steps: usize = self.frame_count - 1;
        const dt: f32 = self.frame_time;
        const raw: []f32 = try gpa.alloc(f32, steps * nv);
        defer gpa.free(raw);
        for (0..steps) |f| {
            rbt.differentiatePos(m, raw[f * nv ..][0..nv], self.pose(f), self.pose(f + 1), dt);
        }
        const sigma_frames: f32 = 1.0 / (2.0 * pi * cutoff_hz * dt);
        const radius: usize = @ceil(3.0 * sigma_frames);
        const filtered: []f32 = try gpa.alloc(f32, steps * nv);
        defer gpa.free(filtered);
        for (0..steps) |f| {
            for (0..nv) |v| {
                var weighted: f32 = 0.0;
                var total: f32 = 0.0;
                var k: isize = -@as(isize, @intCast(radius));
                while (k <= @as(isize, @intCast(radius))) : (k += 1) {
                    const at: isize = @as(isize, @intCast(f)) + k;
                    const last: isize = @intCast(steps - 1);
                    const index: usize = if (at < 0) 0 else if (at > last) @intCast(last) else @intCast(at);
                    const x: f32 = float(k) / sigma_frames;
                    const w: f32 = @exp(-0.5 * x * x);
                    weighted += w * raw[index * nv + v];
                    total += w;
                }
                filtered[f * nv + v] = weighted / total;
            }
        }
        const targets: []f32 = try gpa.dupe(f32, self.targets);
        errdefer gpa.free(targets);
        for (0..steps) |f| {
            const next: []f32 = targets[(f + 1) * self.nq ..][0..self.nq];
            @memcpy(next, targets[f * self.nq ..][0..self.nq]);
            rbt.integratePos(m, next, filtered[f * nv ..][0..nv], dt);
            for (0..m.njnt) |j| {
                if (m.jnt_type[j] != .hinge) {
                    continue;
                }
                if (m.jnt_range[j]) |r| {
                    const q: u32 = m.jnt_qpos_adr[j];
                    next[q] = clamp(next[q], r[0], r[1]);
                }
            }
        }
        const residual: []f32 = try gpa.dupe(f32, self.residual);
        errdefer gpa.free(residual);
        const residual_body: []u32 = try gpa.dupe(u32, self.residual_body);
        return .{
            .gpa = gpa,
            .frame_count = self.frame_count,
            .frame_time = self.frame_time,
            .nq = self.nq,
            .targets = targets,
            .residual = residual,
            .residual_body = residual_body,
        };
    }
};

/// The handful of numbers that say whether a retargeted clip is fit to learn from.
///
/// A learner will happily train on a subtly broken reference - a joint jammed against its limit,
/// a quaternion that flips hemispheres between frames, an elbow that snaps half a radian in one
/// frame - and every one of those still LOOKS like motion. So before anything learns from a clip,
/// `auditClip` measures the four ways a clip goes wrong:
///
///   * how well the IK did at all (the residual - the worst distance between where it put a body
///     and where the capture asked for it);
///   * whether hinges stayed in their ranges;
///   * whether any ball joint's or the root's quaternion flipped sign between frames (the same
///     rotation, but a differencing step would read it as a full turn);
///   * the biggest change of any joint between two consecutive frames - the jumps a servo would
///     have to produce, and the first place a twist flip shows itself.
pub const ClipAudit = struct {
    frames: usize,
    /// The IK residual, metres: the mean over frames, and the worst frame's.
    residual_mean: f32,
    residual_worst: f32,
    residual_worst_frame: usize,
    /// Hinge-frames more than 0.01 rad outside the hinge's range, and the worst excess (rad).
    range_excess_frames: u32,
    range_worst_excess: f32,
    range_worst_joint: usize,
    /// Consecutive frames whose quaternions (ball joints and the root) sit in opposite hemispheres.
    sign_flips: u32,
    /// The largest change of one joint between two frames, radians: a hinge's angle, or the angle
    /// of a ball's relative rotation. The root's rotation counts; its translation doesn't.
    jump_worst: f32,
    jump_worst_joint: usize,
    jump_worst_frame: usize,
};

/// Audit a clip against the model it was retargeted for. Allocation-free: it keeps only totals and
/// worsts, so it's cheap enough to run on every clip, every time.
pub fn auditClip(m: *const rbt.Model, clip: *const Clip) ClipAudit {
    var audit: ClipAudit = .{
        .frames = clip.frame_count,
        .residual_mean = 0.0,
        .residual_worst = 0.0,
        .residual_worst_frame = 0,
        .range_excess_frames = 0,
        .range_worst_excess = 0.0,
        .range_worst_joint = 0,
        .sign_flips = 0,
        .jump_worst = 0.0,
        .jump_worst_joint = 0,
        .jump_worst_frame = 0,
    };
    for (clip.residual, 0..) |r, f| {
        audit.residual_mean += r;
        if (r > audit.residual_worst) {
            audit.residual_worst = r;
            audit.residual_worst_frame = f;
        }
    }
    audit.residual_mean /= float(@max(clip.frame_count, 1));

    for (0..clip.frame_count) |f| {
        const now: []const f32 = clip.pose(f);
        for (0..m.njnt) |j| {
            const q: usize = m.jnt_qpos_adr[j];
            switch (m.jnt_type[j]) {
                .hinge, .slide => {
                    if (m.jnt_range[j]) |range| {
                        const excess: f32 = @max(range[0] - now[q], now[q] - range[1]);
                        if (excess > 0.01) {
                            audit.range_excess_frames += 1;
                        }
                        if (excess > audit.range_worst_excess) {
                            audit.range_worst_excess = excess;
                            audit.range_worst_joint = j;
                        }
                    }
                    if (f > 0) {
                        noteJump(&audit, @abs(now[q] - clip.pose(f - 1)[q]), j, f);
                    }
                },
                .ball, .free => {
                    if (f == 0) {
                        continue;
                    }
                    // The free root's quaternion comes after its position.
                    const at: usize = q + @as(usize, if (m.jnt_type[j] == .free) 3 else 0);
                    const a: Quat = clip.pose(f - 1)[at..][0..4].*;
                    const b: Quat = now[at..][0..4].*;
                    if (dot4(a, b) < 0.0) {
                        audit.sign_flips += 1;
                    }
                    // The relative rotation's angle, whichever hemisphere either quaternion is in -
                    // taken from the VECTOR part rather than from `acos` of the dot product, which
                    // cannot resolve anything below about a thousandth of a radian in f32 and
                    // reports its own noise instead.
                    var rel: Quat = qmul(a, conjugate(b));
                    if (rel[3] < 0.0) {
                        rel = -rel;
                    }
                    noteJump(&audit, 2.0 * asinRad(@min(1.0, length3(vec(rel[0], rel[1], rel[2])))), j, f);
                },
            }
        }
    }
    return audit;
}

fn noteJump(audit: *ClipAudit, jump: f32, joint: usize, frame: usize) void {
    if (jump > audit.jump_worst) {
        audit.jump_worst = jump;
        audit.jump_worst_joint = joint;
        audit.jump_worst_frame = frame;
    }
}

/// Retarget the first `seconds` of a capture onto a robot, one frame at a time.
///
/// `m` has to be a FLOATING-base model: the root is a free joint, and placing it is part of the job.
/// `tpose` is the performer standing still in a known pose (the capture's rest pose) - that's how the
/// retarget learns which part of the robot corresponds to which part of the performer - and the LAFAN
/// match table says which capture joint drives which robot body. `names` are the robot's body names
/// (`robot_mjcf.Imported.names`).
///
/// Each frame is one point-cloud IK solve (`rbt.solvePointCloud`), started from the previous frame's
/// answer and gently held to it, so the clip comes out continuous. Then, if you asked for it, the
/// whole clip is raised or lowered so the feet meet the floor. What you get back is raw: run it
/// through `Clip.smoothed` before you servo it.
pub fn retargetClip(
    gpa: Allocator,
    m: *const rbt.Model,
    names: []const []const u8,
    capture: *const codecs.bvh.Data,
    tpose: *const codecs.bvh.Data,
    opts: RetargetOptions,
) !Clip {
    const seconds: f32 = opts.seconds;
    const convert: FrameConvert = opts.convert;
    const settle_passes: u32 = opts.settle_passes;
    const bodies: usize = m.nbody;
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    const human_joints: usize = capture.joints.len;

    // ── The robot at rest, and which capture joint drives which body. ──
    var rest: rbt.Data = try rbt.Data.init(gpa, m);
    defer rest.deinit();
    @memcpy(rest.pos, m.qpos0);
    rest.stage = .stale;
    rbt.forward(m, &rest);

    const human_names: [][]const u8 = try gpa.alloc([]const u8, human_joints);
    defer gpa.free(human_names);
    const human_parents: []i32 = try gpa.alloc(i32, human_joints);
    defer gpa.free(human_parents);
    for (capture.joints, 0..) |joint, i| {
        human_names[i] = joint.name;
        human_parents[i] = joint.parent;
    }
    const human_of_body: []i32 = try gpa.alloc(i32, bodies);
    defer gpa.free(human_of_body);
    try rbt.resolveMatchTable(&rbt.lafan_to_humanoid, names, human_names, human_of_body);

    // The rest pose has to be the SAME skeleton as the capture - same joints, same order - because
    // every joint here is matched between the two by INDEX. (Cut a capture's joints down, and its
    // rest pose needs the same cut.)
    assertf(
        tpose.joints.len == capture.joints.len,
        @src(),
        "the rest pose has {d} joints and the capture has {d}: they must be the same skeleton",
        .{ tpose.joints.len, capture.joints.len },
    );

    // ── The capture at rest: the T-pose's first frame, in metres, Z-up. ──
    const local: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(local);
    const human_rest_rot: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(human_rest_rot);
    const human_rest_pos: []Vec = try gpa.alloc(Vec, human_joints);
    defer gpa.free(human_rest_pos);
    const bvh_points: []Vec = try gpa.alloc(Vec, human_joints);
    defer gpa.free(bvh_points);
    var root_bvh: Vec = vec_zero;
    globalsAtFrame(tpose, 0, local, human_rest_rot, &root_bvh);
    bvhPoints(tpose, human_rest_rot, bvh_points);
    for (0..human_joints) |i| {
        human_rest_pos[i] = toRobot(convert, to_robot, bvh_points[i]);
        human_rest_rot[i] = rotationToRobot(convert, to_robot, human_rest_rot[i]);
    }

    // ── The samples, once: they depend only on the two rest poses. ──
    const samples: []rbt.PointSample = try gpa.alloc(rbt.PointSample, max_samples);
    defer gpa.free(samples);
    const sample_count: usize = rbt.buildPointSamples(m, .{
        .human_of_body = human_of_body,
        .human_parents = human_parents,
        .rest_positions = human_rest_pos,
        .rest_rotations = human_rest_rot,
        .robot_rest_rotations = rest.body_xrot,
        .body_names = names,
        .rest_positions_robot = rest.body_xpos,
    }, samples);

    // ── Every frame: capture FK, the retargeted skeleton, the IK. ──
    const wanted: usize = @trunc(seconds / capture.frame_time);
    const frame_count: usize = @min(capture.frame_count, wanted);
    const nq: usize = m.nq;
    const targets: []f32 = try gpa.alloc(f32, frame_count * nq);
    errdefer gpa.free(targets);
    const residual: []f32 = try gpa.alloc(f32, frame_count);
    errdefer gpa.free(residual);
    const residual_body: []u32 = try gpa.alloc(u32, frame_count);
    errdefer gpa.free(residual_body);

    var kin: rbt.Data = try rbt.Data.init(gpa, m);
    defer kin.deinit();
    const global: []Quat = try gpa.alloc(Quat, human_joints);
    defer gpa.free(global);
    const positions: []Vec = try gpa.alloc(Vec, human_joints);
    defer gpa.free(positions);
    const retargeted: []Vec = try gpa.alloc(Vec, bodies);
    defer gpa.free(retargeted);
    const tasks: []rbt.IkTask = try gpa.alloc(rbt.IkTask, max_samples);
    defer gpa.free(tasks);
    const scratch: []f32 = try gpa.alloc(f32, rbt.ikScratchSize(m.nv));
    defer gpa.free(scratch);

    var first_root: Vec = vec_zero;
    for (0..frame_count) |frame| {
        var root: Vec = vec_zero;
        globalsAtFrame(capture, frame, local, global, &root);
        if (frame == 0) {
            first_root = root;
        }
        bvhPoints(capture, global, bvh_points);
        // Horizontal root motion relative to the first frame, height absolute.
        const root_delta: Vec = toRobot(convert, to_robot, root - first_root);
        const root_m: Vec = vec(root_delta[0], root_delta[1], root[1] * 0.01);
        for (0..human_joints) |j| {
            positions[j] = root_m + toRobot(convert, to_robot, bvh_points[j]);
            global[j] = rotationToRobot(convert, to_robot, global[j]);
        }
        retargetedSkeleton(m, human_of_body, positions, retargeted);
        const previous: ?[]const f32 = if (frame == 0) null else targets[(frame - 1) * nq ..][0..nq];
        rbt.solvePointCloud(m, &kin, samples[0..sample_count], .{
            .positions = positions,
            .rotations = global,
            .retargeted = retargeted,
            .root_world = retargeted[1],
            .previous_qpos = previous,
            .posture_weight = opts.posture_weight,
            .scratch = scratch,
            .tasks = tasks,
        });
        rbt.forward(m, &kin);
        @memcpy(targets[frame * nq ..][0..nq], kin.pos[0..nq]);
        // ★★ FRAME 0 HAS NO PREVIOUS SOLUTION TO START FROM, so its solve begins at qpos0 and can
        // stop short, in whichever branch the rest pose leads to — and the clip then snaps to the
        // better branch a few frames in (humanoid_flex2's right arm, 1.5 rad at frame 5). Solving
        // frame 0 again from its own answer, a few times, lets it finish converging first.
        if (frame == 0) {
            for (0..settle_passes) |_| {
                rbt.solvePointCloud(m, &kin, samples[0..sample_count], .{
                    .positions = positions,
                    .rotations = global,
                    .retargeted = retargeted,
                    .root_world = retargeted[1],
                    .previous_qpos = targets[0..nq],
                    .posture_weight = opts.posture_weight,
                    .scratch = scratch,
                    .tasks = tasks,
                });
                rbt.forward(m, &kin);
                @memcpy(targets[0..nq], kin.pos[0..nq]);
            }
        }

        var worst: f32 = 0.0;
        var worst_body: u32 = 0;
        for (1..bodies) |b| {
            if (human_of_body[b] < 0) {
                continue;
            }
            const missed: f32 = length3(kin.body_xpos[b] - retargeted[b]);
            if (missed > worst) {
                worst = missed;
                worst_body = @intCast(b);
            }
        }
        residual[frame] = worst;
        residual_body[frame] = worst_body;
    }

    if (opts.ground) {
        const lowest: []f32 = try gpa.alloc(f32, frame_count);
        defer gpa.free(lowest);
        for (0..frame_count) |frame| {
            @memcpy(kin.pos, targets[frame * nq ..][0..nq]);
            kin.stage = .stale;
            rbt.forward(m, &kin);
            lowest[frame] = lowestFootPoint(m, &kin, names);
        }
        std.mem.sort(f32, lowest, {}, std.sort.asc(f32));
        const median: f32 = lowest[frame_count / 2];
        const root_z: usize = m.jnt_qpos_adr[0] + 2;
        assertf(m.jnt_type[0] == .free, @src(), "grounding moves a free root; joint 0 is not free", .{});
        for (0..frame_count) |frame| {
            targets[frame * nq + root_z] -= median;
        }
    }

    return .{
        .gpa = gpa,
        .frame_count = frame_count,
        .frame_time = capture.frame_time,
        .nq = nq,
        .targets = targets,
        .residual = residual,
        .residual_body = residual_body,
    };
}

/// How low the robot's feet reach right now: the lowest point, in world z, of any body with "foot"
/// in its name - capsule ends and sphere bottoms, radius included. `d` must be forward-current.
/// Grounding uses this to decide where the floor should be.
pub fn lowestFootPoint(
    m: *const rbt.Model,
    d: *const rbt.Data,
    names: []const []const u8,
) f32 {
    return lowestGeomZ(m, d, names, "foot");
}

/// The same for the WHOLE robot: how low any part of it reaches.
///
/// A reference clip that dips below zero here is asking the body to be inside the floor - which no
/// simulation will reproduce, and which a tracker would spend its whole effort fighting. Worth
/// knowing before training on a clip where the performer goes to ground.
pub fn lowestBodyPoint(m: *const rbt.Model, d: *const rbt.Data) f32 {
    return lowestGeomZ(m, d, &.{}, null);
}

/// The lowest world z of the bodies whose name contains `want` - a foot, say, or a toe. `d` must be
/// forward-current. Public because a page showing what a reference asks of the robot needs exactly
/// this, one body group at a time.
pub fn lowestGeomNamed(
    m: *const rbt.Model,
    d: *const rbt.Data,
    names: []const []const u8,
    want: []const u8,
) f32 {
    return lowestGeomZ(m, d, names, want);
}

/// The lowest world z of the robot's geometry: all of it, or only the bodies whose name contains
/// `want`. `d` must be forward-current.
fn lowestGeomZ(
    m: *const rbt.Model,
    d: *const rbt.Data,
    names: []const []const u8,
    want: ?[]const u8,
) f32 {
    var lowest: f32 = 1.0e9;
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        if (want) |fragment| {
            if (std.mem.indexOf(u8, names[body], fragment) == null) {
                continue;
            }
        }
        const center: Vec = d.body_xpos[body] + rotate(d.body_xrot[body], m.geom_pos[g]);
        const rot: Quat = qmul(d.body_xrot[body], m.geom_rot[g]);
        switch (m.geom_shape[g]) {
            .sphere => |sph| lowest = @min(lowest, center[2] - sph.radius),
            .capsule => |cap| {
                const axis: Vec = rotate(rot, vec(0, cap.half_height, 0));
                lowest = @min(lowest, @min((center + axis)[2], (center - axis)[2]) - cap.radius);
            },
            else => {},
        }
    }
    return lowest;
}

/// A BVH position (centimetres, Y-up) as the robot sees it (metres, Z-up). With `.rotate` that's
/// the quarter turn `to_robot` and a divide by 100; with `.swizzle` it's the (mirroring!) axis swap.
pub fn toRobot(
    convert: FrameConvert,
    to_robot: Quat,
    p: Vec,
) Vec {
    return switch (convert) {
        .swizzle => vec(p[0] * 0.01, p[2] * 0.01, p[1] * 0.01),
        .rotate => rotate(to_robot, p) * splat(0.01),
    };
}

/// A BVH rotation as the robot sees it. A rotation lives in the axes it was measured in, so moving it
/// to new axes means conjugating: undo the conversion, apply the rotation, redo the conversion
/// (`to_robot * q * to_robot^-1`). `.swizzle` leaves it untouched, which is one more reason not to use it.
pub fn rotationToRobot(
    convert: FrameConvert,
    to_robot: Quat,
    q: Quat,
) Quat {
    return switch (convert) {
        .swizzle => q,
        .rotate => qmul(qmul(to_robot, q), conjugate(to_robot)),
    };
}

/// One frame of the capture, turned into rotations: every joint's GLOBAL rotation (in the capture's
/// world, not relative to its parent), plus the root's translation.
///
/// Each joint's local rotation is built from its own rotation channels, multiplied in the order the
/// file lists them (Z then Y then X gives Rz * Ry * Rx), angles in degrees. Parents always come
/// before their children in the array, so one pass from first to last turns local into global:
/// global = parent's global * local. Only the root's position channels are read.
pub fn globalsAtFrame(
    capture: *const codecs.bvh.Data,
    frame: usize,
    local: []Quat,
    global: []Quat,
    out_root: *Vec,
) void {
    const row: []const f32 = capture.motion[frame * capture.channel_count ..][0..capture.channel_count];
    var cursor: usize = 0;
    for (capture.joints, 0..) |joint, index| {
        const values: []const f32 = row[cursor..][0..joint.channels.len];
        cursor += joint.channels.len;
        var rotation: Quat = quat_identity;
        var translation: Vec = vec_zero;
        for (joint.channels, 0..) |channel, k| {
            switch (channel) {
                .x_position => translation[0] = values[k],
                .y_position => translation[1] = values[k],
                .z_position => translation[2] = values[k],
                .x_rotation => rotation = qmul(rotation, quatFromAxisAngle(vec(1, 0, 0), radFromDeg(values[k]))),
                .y_rotation => rotation = qmul(rotation, quatFromAxisAngle(vec(0, 1, 0), radFromDeg(values[k]))),
                .z_rotation => rotation = qmul(rotation, quatFromAxisAngle(vec(0, 0, 1), radFromDeg(values[k]))),
            }
        }
        if (joint.parent < 0) {
            out_root.* = translation;
        }
        local[index] = rotation;
        global[index] = if (joint.parent < 0) rotation else qmul(global[@intCast(joint.parent)], rotation);
    }
}

/// Where every joint is, relative to the root, from the global rotations `globalsAtFrame` made.
/// Still in the capture's units and axes (centimetres, Y-up): each joint sits at its parent's
/// position plus its OFFSET, turned by the parent's global rotation. Bones never stretch here.
pub fn bvhPoints(
    capture: *const codecs.bvh.Data,
    global: []const Quat,
    out: []Vec,
) void {
    for (capture.joints, 0..) |joint, index| {
        const offset: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        out[index] = if (joint.parent < 0)
            vec_zero
        else
            out[@intCast(joint.parent)] + rotate(global[@intCast(joint.parent)], offset);
    }
}

/// The robot's own bone lengths laid along the capture's bone directions — what the IK is asked
/// to reach. A body whose capture joint (or its parent's) is unmatched keeps its rest offset.
fn retargetedSkeleton(
    m: *const rbt.Model,
    human_of_body: []const i32,
    positions: []const Vec,
    out: []Vec,
) void {
    out[0] = vec_zero;
    for (1..m.nbody) |b| {
        const parent: u32 = m.body_parent[b];
        const own_length: f32 = length3(m.body_pos[b]);
        const hb: i32 = human_of_body[b];
        if (parent == 0) {
            out[b] = if (hb >= 0) positions[@intCast(hb)] else vec_zero;
            continue;
        }
        const hp: i32 = human_of_body[parent];
        const unmatched: bool = hb < 0 or hp < 0 or own_length < 1.0e-6;
        if (unmatched) {
            out[b] = out[parent] + m.body_pos[b];
            continue;
        }
        const bone: Vec = positions[@intCast(hb)] - positions[@intCast(hp)];
        const degenerate: bool = length3(bone) < 1.0e-6;
        out[b] = if (degenerate) out[parent] + m.body_pos[b] else out[parent] + normalize3(bone) * splat(own_length);
    }
}

/// The servo: the acceleration each joint of a FIXED-base robot needs to follow a moving target.
///
/// Every frame you hand it three consecutive poses from the clip - before, now, next - and it works
/// out two things: how the clip itself is moving (its velocity and acceleration, straight from those
/// three poses), and how far off the robot currently is. It asks for the clip's own acceleration,
/// plus an implicit, critically damped spring (`robot_maximal.stableSpringAccel`) that pulls the robot
/// back onto the clip if it has drifted. Hand the result to inverse dynamics and out come the torques.
///
/// Hinges and balls take the same path. Every "difference between two poses" goes through
/// `rbt.differentiatePos`: for a hinge it's an angle, for a ball it's a rotation vector in the CHILD's
/// frame - which is exactly where a ball's DOFs live. So the two classic ball-joint mistakes (an axis
/// that isn't a unit vector, an error in the wrong frame) simply can't happen here:
/// `differentiatePos` is where the model already gets them right.
pub const Tracker = struct {
    gpa: Allocator,
    err: []f32,
    v_ref: []f32,
    v_prev: []f32,

    pub fn init(gpa: Allocator, nv: usize) !Tracker {
        const err: []f32 = try gpa.alloc(f32, nv);
        errdefer gpa.free(err);
        const v_ref: []f32 = try gpa.alloc(f32, nv);
        errdefer gpa.free(v_ref);
        const v_prev: []f32 = try gpa.alloc(f32, nv);
        return .{ .gpa = gpa, .err = err, .v_ref = v_ref, .v_prev = v_prev };
    }

    pub fn deinit(self: *Tracker) void {
        self.gpa.free(self.err);
        self.gpa.free(self.v_ref);
        self.gpa.free(self.v_prev);
    }

    /// `prev`, `now`, `next`: consecutive target poses `dt` apart; `d` forward-current.
    pub fn accelerations(
        self: *const Tracker,
        m: *const rbt.Model,
        d: *const rbt.Data,
        targets: [3][]const f32,
        frequency: f32,
        dt: f32,
        out: []f32,
    ) void {
        const prev: []const f32 = targets[0];
        const now: []const f32 = targets[1];
        const next: []const f32 = targets[2];
        rbt.differentiatePos(m, self.err, d.pos, now, 1.0);
        rbt.differentiatePos(m, self.v_ref, now, next, dt);
        rbt.differentiatePos(m, self.v_prev, prev, now, dt);
        // ── ★ The velocity error is measured against v_prev, not v_ref ──
        //
        // This one's subtle, and it's what makes fast motion work. robot.zig steps with
        // semi-implicit Euler: first v += dt a, then q += dt v using the NEW velocity. So to land
        // exactly on `next` with velocity v_ref = (next - now)/dt, the robot has to ARRIVE at `now`
        // carrying v_ref - dt a_ref, which works out to v_prev = (now - prev)/dt - the backward
        // difference. That's the velocity the discrete trajectory really has at `now`, before the
        // step.
        //
        // Compare against v_ref instead, and a robot sitting perfectly on the clip looks like it's
        // off by -dt a_ref every single step. The spring "corrects" that, pushes the robot off the
        // clip, and settles wherever the position term balances it: a steady error of about
        // dt a_ref / (pi f) per joint, compounding down every chain, and worse the faster the
        // motion. Against v_prev, a robot exactly on the clip sees zero error in both terms, and
        // what comes out is a_ref alone.
        for (0..m.nv) |v| {
            const a_ref: f32 = (self.v_ref[v] - self.v_prev[v]) / dt;
            out[v] = a_ref + rmx.stableSpringAccel(self.err[v], d.vel[v] - self.v_prev[v], frequency, 1.0, dt);
        }
    }
};

/// The most contacts a contact solve will use. A humanoid on a floor touches it at a handful of
/// points, so this is plenty, and it keeps the solves' matrices small and fixed-size.
pub const max_contact_points: usize = 16;
/// Tikhonov weight on the contact forces, in (N of wrench error)^2 per N^2 of force.
const contact_regularisation: f32 = 1.0e-2;
/// No single contact is asked for more than this normal force, in newtons.
const max_normal_force: f32 = 2000.0;
/// Unknowns a contact solve carries at most: a root-acceleration change and three per contact.
const max_unknowns: usize = 6 + 3 * max_contact_points;
/// A square system of up to `max_unknowns`, its right-hand side in the last column.
const Augmented = [max_unknowns][max_unknowns + 1]f32;

/// Scratch memory for the contact solves, sized once for a model so the per-frame solves never
/// allocate.
pub const ContactScratch = struct {
    gpa: Allocator,
    jac: []Vec,
    /// Per basis force (three per contact), its generalized effect J^T e: nv values each.
    columns: []f32,
    /// Friction coefficient of each gathered contact.
    mu: [max_contact_points]f32 = undefined,

    pub fn init(gpa: Allocator, nv: usize) !ContactScratch {
        const jac: []Vec = try gpa.alloc(Vec, nv);
        errdefer gpa.free(jac);
        const columns: []f32 = try gpa.alloc(f32, 3 * max_contact_points * nv);
        return .{ .gpa = gpa, .jac = jac, .columns = columns };
    }

    pub fn deinit(self: *ContactScratch) void {
        self.gpa.free(self.jac);
        self.gpa.free(self.columns);
    }
};

/// The robot's TOUCHING contacts with the world, into `scratch`: each contact's three basis forces
/// (the floor's push along the normal, and the two tangents) as generalized columns J^T e.
fn gatherContacts(
    m: *const rbt.Model,
    d: *const rbt.Data,
    scratch: *ContactScratch,
) usize {
    const nv: usize = m.nv;
    var count: usize = 0;
    for (d.contacts[0..d.contact_count]) |c| {
        if (count == max_contact_points) {
            break;
        }
        // Only contacts actually touching: a speculative one a centimetre away gave the least
        // squares a free lever, and it planned 5,000 N through it.
        if (c.distance > 0.002) {
            continue;
        }
        const robot_is_b: bool = c.body_a == rbt.world_body and c.body_b != rbt.world_body;
        const robot_is_a: bool = c.body_b == rbt.world_body and c.body_a != rbt.world_body;
        if (!robot_is_a and !robot_is_b) {
            continue;
        }
        // The normal points from body_a toward body_b: it pushes b along it and a against it.
        const sign: f32 = if (robot_is_b) 1.0 else -1.0;
        const body: u32 = if (robot_is_b) c.body_b else c.body_a;
        const push: [3]Vec = .{ c.normal * splat(sign), c.tangent[0], c.tangent[1] };
        rbt.jacPoint(m, d, body, c.position, scratch.jac, null);
        for (0..3) |axis| {
            const column: []f32 = scratch.columns[(3 * count + axis) * nv ..][0..nv];
            for (0..nv) |v| {
                column[v] = dot3(scratch.jac[v], push[axis]);
            }
        }
        scratch.mu[count] = c.friction[0];
        count += 1;
    }
    return count;
}

/// Contact k's force from a solve's lambdas, clamped into its friction cone and capped.
fn coneForce(
    lambda: []const f32,
    k: usize,
    mu: f32,
) [3]f32 {
    const normal_force: f32 = clamp(lambda[3 * k], 0.0, max_normal_force);
    var t1: f32 = lambda[3 * k + 1];
    var t2: f32 = lambda[3 * k + 2];
    const tangential: f32 = @sqrt(t1 * t1 + t2 * t2);
    const limit: f32 = mu * normal_force;
    if (tangential > limit and tangential > 0.0) {
        t1 *= limit / tangential;
        t2 *= limit / tangential;
    }
    return .{ normal_force, t1, t2 };
}

/// Split what a motion needs between the floor (through the feet) and the joint motors.
///
/// Here's the problem it solves. Computed torque (`Tracker` + inverse dynamics) knows every force in
/// the system except one: the floor's. With a welded root that doesn't matter - the world holds the
/// root. With a free root, the floor IS what holds the body up, so joint torques worked out as if the
/// root were held don't produce the accelerations they were computed for.
///
/// So this takes the whole required generalized force, `wrench` (= M a + c for the accelerations you
/// want), and asks the contacts for its root rows: a regularised least-squares fit over every
/// touching contact's force, each clamped into its friction cone. A contact that would have to pull
/// is dropped - floors don't pull - and the rest are solved again once.
///
/// Out comes `torque` = wrench - sum J^T f. Its JOINT rows are what the motors must supply; its ROOT
/// rows are the RESIDUAL, the part of the motion the feet simply can't provide, left as a hard demand
/// for someone else. Returns how many contacts carried load. `d` must be forward-current with its
/// contacts harvested, and the root must be joint 0. If you'd rather the root give way than demand
/// the impossible, use `contactConsistentTorques`.
pub fn contactTorques(
    m: *const rbt.Model,
    d: *const rbt.Data,
    wrench: []const f32,
    scratch: *ContactScratch,
    torque: []f32,
) usize {
    const nv: usize = m.nv;
    @memcpy(torque, wrench);
    const count: usize = gatherContacts(m, d, scratch);
    if (count == 0) {
        return 0;
    }
    var active: [max_contact_points]bool = undefined;
    @memset(active[0..count], true);
    var lambda: [max_unknowns]f32 = undefined;
    for (0..2) |_| {
        const n: usize = 3 * count;
        var a: Augmented = undefined;
        for (0..n) |i| {
            for (0..n) |j| {
                var sum: f32 = 0.0;
                if (active[i / 3] and active[j / 3]) {
                    for (0..6) |r| {
                        sum += scratch.columns[i * nv + r] * scratch.columns[j * nv + r];
                    }
                }
                a[i][j] = sum;
            }
            var rhs: f32 = 0.0;
            if (active[i / 3]) {
                for (0..6) |r| {
                    rhs += scratch.columns[i * nv + r] * wrench[r];
                }
            }
            a[i][n] = rhs;
            // ★★ Regularisation strong enough to prefer MODERATE forces: at 1e-4 the solve put
            // 12x body weight through one contact, cancelling its moment with tangential forces,
            // and the friction clamp then broke that balance - a residual larger than the demand.
            a[i][i] += contact_regularisation;
        }
        solveDense(n, &a, lambda[0..n]);
        var dropped: bool = false;
        for (0..count) |k| {
            if (active[k] and lambda[3 * k] <= 0.0) {
                active[k] = false;
                dropped = true;
            }
        }
        if (!dropped) {
            break;
        }
    }
    var loaded: usize = 0;
    for (0..count) |k| {
        if (!active[k]) {
            continue;
        }
        const forces: [3]f32 = coneForce(&lambda, k, scratch.mu[k]);
        if (forces[0] > 0.0) {
            loaded += 1;
        }
        for (0..3) |axis| {
            const column: []const f32 = scratch.columns[(3 * k + axis) * nv ..][0..nv];
            for (0..nv) |v| {
                torque[v] -= forces[axis] * column[v];
            }
        }
    }
    return loaded;
}

/// Like `contactTorques`, but the root's wanted acceleration is a WISH, not a demand.
///
/// With the root's rows as a hard demand, whatever the feet can't supply comes out as a residual that
/// only an invisible helping hand could provide - and without one the body just falls. A real body
/// has no helping hand: its root accelerates however its contacts let it. So this solves for two
/// things at once, the contact forces f AND a change `delta` to the root's acceleration, minimising
///
///     |W_r + M_rr delta - A f|^2  +  root_weight |delta|^2  +  eps |f|^2
///
/// The first term is the root's own equation of motion, the second is "please follow the reference",
/// and the third says "and don't use absurd forces". After the forces are clamped into their friction
/// cones, `delta` is recomputed so the root's rows balance EXACTLY with the forces that were kept. The
/// upshot: the torques are physically consistent, nothing is being faked, and the root goes wherever
/// the feet can actually take it. With no contacts at all this is just the floating-base solution
/// (`robot_maximal.floatingBaseTorques`).
///
/// `dense` is the mass matrix, nv x nv (`rbt.massMatrixDense`). Out: `torque`, whose root rows are ~0.
pub fn contactConsistentTorques(
    m: *const rbt.Model,
    d: *const rbt.Data,
    wrench: []const f32,
    dense: []const f32,
    root_weight: f32,
    scratch: *ContactScratch,
    torque: []f32,
) usize {
    const nv: usize = m.nv;
    const count: usize = gatherContacts(m, d, scratch);
    var active: [max_contact_points]bool = undefined;
    @memset(active[0..count], true);
    var x: [max_unknowns]f32 = undefined;
    for (0..2) |_| {
        const n: usize = 6 + 3 * count;
        var a: Augmented = undefined;
        for (0..n) |i| {
            @memset(a[i][0 .. n + 1], 0.0);
        }
        // The root's six equations of motion, as least-squares rows over [delta; lambda].
        var row: [max_unknowns]f32 = undefined;
        for (0..6) |r| {
            for (0..6) |c| {
                row[c] = dense[r * nv + c];
            }
            for (0..3 * count) |i| {
                row[6 + i] = if (active[i / 3]) -scratch.columns[i * nv + r] else 0.0;
            }
            for (0..n) |i| {
                for (0..n) |j| {
                    a[i][j] += row[i] * row[j];
                }
                a[i][n] -= row[i] * wrench[r];
            }
        }
        for (0..6) |c| {
            a[c][c] += root_weight;
        }
        for (6..n) |i| {
            a[i][i] += contact_regularisation;
        }
        solveDense(n, &a, x[0..n]);
        var dropped: bool = false;
        for (0..count) |k| {
            if (active[k] and x[6 + 3 * k] <= 0.0) {
                active[k] = false;
                dropped = true;
            }
        }
        if (!dropped) {
            break;
        }
    }
    // The forces kept, then the root acceleration change that balances the root EXACTLY with
    // them: M_rr delta = A f - W_r.
    var f: [3 * max_contact_points]f32 = undefined;
    @memset(f[0 .. 3 * count], 0.0);
    var loaded: usize = 0;
    for (0..count) |k| {
        if (!active[k]) {
            continue;
        }
        const forces: [3]f32 = coneForce(x[6..], k, scratch.mu[k]);
        f[3 * k] = forces[0];
        f[3 * k + 1] = forces[1];
        f[3 * k + 2] = forces[2];
        if (forces[0] > 0.0) {
            loaded += 1;
        }
    }
    var root_system: Augmented = undefined;
    for (0..6) |r| {
        for (0..6) |c| {
            root_system[r][c] = dense[r * nv + c];
        }
        var rhs: f32 = -wrench[r];
        for (0..3 * count) |i| {
            rhs += scratch.columns[i * nv + r] * f[i];
        }
        root_system[r][6] = rhs;
    }
    var delta: [max_unknowns]f32 = undefined;
    solveDense(6, &root_system, delta[0..6]);
    for (0..nv) |v| {
        var value: f32 = wrench[v];
        for (0..6) |c| {
            value += dense[v * nv + c] * delta[c];
        }
        for (0..3 * count) |i| {
            value -= scratch.columns[i * nv + v] * f[i];
        }
        torque[v] = value;
    }
    return loaded;
}

/// Solve the n x n system in `a` (augmented with its right-hand side in column n) by Gaussian
/// elimination with partial pivoting. The caller regularises `a`, so it is never singular.
fn solveDense(
    n: usize,
    a: *Augmented,
    out: []f32,
) void {
    for (0..n) |col| {
        var pivot: usize = col;
        for (col + 1..n) |r| {
            if (@abs(a[r][col]) > @abs(a[pivot][col])) {
                pivot = r;
            }
        }
        const swapped: [max_unknowns + 1]f32 = a[col];
        a[col] = a[pivot];
        a[pivot] = swapped;
        for (col + 1..n) |r| {
            const factor: f32 = a[r][col] / a[col][col];
            for (col..n + 1) |c| {
                a[r][c] -= factor * a[col][c];
            }
        }
    }
    var row: usize = n;
    while (row > 0) {
        row -= 1;
        var value: f32 = a[row][n];
        for (row + 1..n) |c| {
            value -= a[row][c] * out[c];
        }
        out[row] = value / a[row][row];
    }
}

/// How fast a point of a body is moving, in the world. `at` is that point in world coordinates,
/// and `d` must be forward-current (`rbt.forward`).
///
/// This is the one place the shift out of robot.zig's shared frame is done, because it is easy to
/// get wrong: `cvel` keeps every body's spatial velocity in ONE frame - world axes, but the origin
/// at the root's subtree centre of mass - since in a shared frame the velocities down a chain
/// simply add up, which is what makes the recursive passes cheap. The price is that `cvel[b].lin`
/// is the velocity of whichever point of body b happens to sit at that shared origin. The point
/// you actually care about moves at `cvel[b].lin + w x (at - origin)`.
pub fn pointVelocity(
    m: *const rbt.Model,
    d: *const rbt.Data,
    body: usize,
    at: Vec,
) Vec {
    const origin: Vec = d.subtree_com[m.body_root[body]];
    const w: Vec = d.cvel[body].ang;
    return d.cvel[body].lin + cross(w, at - origin);
}

/// A body's velocity in the world: how fast it spins, and how fast its centre of mass moves.
/// `d` must be forward-current (`rbt.forward`).
///
/// The angular part needs no shift and is in world axes (not the body's); the linear part is
/// `pointVelocity` at the body's centre of mass, which is NOT what `cvel[b].lin` holds - on a
/// moving humanoid that can be metres a second out.
pub fn bodyVelocity(m: *const rbt.Model, d: *const rbt.Data, body: usize) rbt.Motion {
    return .{
        .ang = d.cvel[body].ang,
        .lin = pointVelocity(m, d, body, d.body_xipos[body]),
    };
}

/// How far apart two poses are, in one number: the worst body's rotation error, in degrees.
///
/// Each body's rotation is taken relative to its parent and compared between `now` and the target,
/// so every joint between two bodies is covered at once, whatever kind it is - a hinge, a stack of
/// hinges, a ball. It doesn't care which engine the rotations came from, so it compares the reduced
/// robot with the maximal ragdoll just as happily as with itself.
pub fn worstBodyErrorDeg(
    m: *const rbt.Model,
    now: []const Quat,
    target: []const Quat,
) f32 {
    var worst: f32 = 0.0;
    for (1..m.nbody) |b| {
        const parent: u32 = m.body_parent[b];
        if (parent == 0) {
            continue; // the root: its placement is not a joint error
        }
        const have: Quat = qmul(conjugate(now[parent]), now[b]);
        const want: Quat = qmul(conjugate(target[parent]), target[b]);
        const alignment: f32 = @abs(@reduce(.Add, have * want));
        worst = @max(worst, 2.0 * acosRad(@min(1.0, alignment)) * 180.0 / pi);
    }
    return worst;
}

// ============================================================================
// The two questions: are the targets good, and can the robot follow them?
// ============================================================================

const robot_mjcf = @import("robot_mjcf.zig");
const mjcf = @import("mjcf.zig");
const zimrphysics = @import("zimrphysics.zig");
const rmx = @import("robot_maximal.zig");
const expect = std.testing.expect;

/// A model loaded from MJCF text, optionally with its root welded to the world.
const Loaded = struct {
    source: []u8,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    data: rbt.Data,

    fn load(
        gpa: Allocator,
        l: *Loaded,
        xml: []const u8,
        fixed_base: bool,
        timestep: f32,
    ) !void {
        l.source = &.{};
        var text: []const u8 = xml;
        if (fixed_base) {
            const free_joint: []const u8 = "<freejoint name=\"root\"/>";
            const at: usize = std.mem.indexOf(u8, xml, free_joint) orelse return error.NoFreeJoint;
            l.source = try gpa.alloc(u8, xml.len - free_joint.len);
            @memcpy(l.source[0..at], xml[0..at]);
            @memcpy(l.source[at..], xml[at + free_joint.len ..]);
            text = l.source;
        }
        errdefer gpa.free(l.source);
        l.doc = try codecs.xml.parse(gpa, text, null);
        errdefer l.doc.deinit();
        l.robot = try mjcf.readRobot(gpa, &l.doc);
        errdefer l.robot.deinit();
        var options: rbt.Options = .{
            .max_contacts = 256, // what a physics bridge can send; smaller trips its asserts
            .timestep = timestep,
            .gravity = vec(0, 0, -9.81),
        };
        options.solver.algorithm = .newton;
        l.imported = try robot_mjcf.build(gpa, &l.robot, options);
        errdefer l.imported.deinit();
        l.data = try rbt.Data.init(gpa, &l.imported.model);
        @memcpy(l.data.pos, l.imported.model.qpos0);
        l.data.stage = .stale;
        rbt.forward(&l.imported.model, &l.data);
    }

    fn deinit(l: *Loaded, gpa: Allocator) void {
        l.data.deinit();
        l.imported.deinit();
        l.robot.deinit();
        l.doc.deinit();
        gpa.free(l.source);
    }
};

const flex_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex.xml");

/// The clip and T-pose the dance examples use, read at test time (skipped when absent).
fn readFile(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

const Dance = struct {
    clip_bytes: []u8,
    tpose_bytes: []u8,
    capture: codecs.bvh.Data,
    tpose: codecs.bvh.Data,

    fn load(
        gpa: Allocator,
        io: std.Io,
        d: *Dance,
    ) !void {
        d.clip_bytes = try readFile(gpa, io, "examples/geno_dance/dance1_20s.bvh");
        errdefer gpa.free(d.clip_bytes);
        d.tpose_bytes = try readFile(gpa, io, "assets/Geno_stance.bvh");
        errdefer gpa.free(d.tpose_bytes);
        d.capture = try codecs.bvh.parse(gpa, d.clip_bytes, null);
        errdefer d.capture.deinit();
        d.tpose = try codecs.bvh.parse(gpa, d.tpose_bytes, null);
    }

    fn deinit(d: *Dance, gpa: Allocator) void {
        d.tpose.deinit();
        d.capture.deinit();
        gpa.free(d.tpose_bytes);
        gpa.free(d.clip_bytes);
    }
};

/// What 0as asked of the targets, per joint: how far past its range a hinge ever went, and the
/// largest single-frame change of any joint (a ball joint's as a rotation angle).
const JointStats = struct {
    worst_excess: f32 = 0.0,
    worst_excess_value: f32 = 0.0,
    worst_jump: f32 = 0.0,
    worst_jump_frame: usize = 0,
    frames_out: u32 = 0,
};

fn measureTargets(
    gpa: Allocator,
    m: *const rbt.Model,
    clip: *const Clip,
    names: []const []const u8,
    label: []const u8,
) !void {
    const stats: []JointStats = try gpa.alloc(JointStats, m.njnt);
    defer gpa.free(stats);
    @memset(stats, .{});
    var mean_residual: f32 = 0.0;
    var worst_residual: f32 = 0.0;
    for (clip.residual) |r| {
        mean_residual += r;
        worst_residual = @max(worst_residual, r);
    }
    mean_residual /= float(clip.frame_count);
    var total_out: u32 = 0;
    for (0..clip.frame_count) |f| {
        const now: []const f32 = clip.pose(f);
        for (0..m.njnt) |j| {
            const q: u32 = m.jnt_qpos_adr[j];
            switch (m.jnt_type[j]) {
                .hinge => {
                    if (f > 0) {
                        const jump: f32 = @abs(now[q] - clip.pose(f - 1)[q]);
                        if (jump > stats[j].worst_jump) {
                            stats[j].worst_jump = jump;
                            stats[j].worst_jump_frame = f;
                        }
                    }
                    if (m.jnt_range[j]) |r| {
                        const excess: f32 = @max(r[0] - now[q], now[q] - r[1]);
                        if (excess > 0.01) {
                            stats[j].frames_out += 1;
                            total_out += 1;
                        }
                        if (excess > stats[j].worst_excess) {
                            stats[j].worst_excess = excess;
                            stats[j].worst_excess_value = now[q];
                        }
                    }
                },
                .ball => {
                    if (f > 0) {
                        const prev: []const f32 = clip.pose(f - 1);
                        const alignment: f32 = @abs(now[q] * prev[q] + now[q + 1] * prev[q + 1] +
                            now[q + 2] * prev[q + 2] + now[q + 3] * prev[q + 3]);
                        const jump: f32 = 2.0 * acosRad(@min(1.0, alignment));
                        if (jump > stats[j].worst_jump) {
                            stats[j].worst_jump = jump;
                            stats[j].worst_jump_frame = f;
                        }
                    }
                },
                else => {},
            }
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  dance targets on {s}, {d} frames at {d:.0} fps: IK residual mean {d:.3} m, worst {d:.3} m; " ++
        "{d} hinge-frames out of range\n", .{
        label, clip.frame_count, 1.0 / clip.frame_time, mean_residual, worst_residual, total_out,
    });
    for (0..m.njnt) |j| {
        const bad: bool = stats[j].worst_excess > 0.01 or stats[j].worst_jump > 0.3;
        if (!bad) {
            continue;
        }
        const range: [2]f32 = m.jnt_range[j] orelse .{ 0, 0 };
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("    {s:<5} joint {d:>2} on {s:<16} range [{d:>6.2}, {d:>5.2}]  " ++
            "worst excess {d:>6.3} (at {d:>7.3})  " ++
            "{d:>4} frames out   worst jump {d:.3} rad at frame {d}\n", .{
            @tagName(m.jnt_type[j]),     j,                   names[m.jnt_body[j]],
            range[0],                    range[1],            stats[j].worst_excess,
            stats[j].worst_excess_value, stats[j].frames_out, stats[j].worst_jump,
            stats[j].worst_jump_frame,
        });
    }
}

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

test "robot_dance: the retargeted dance's TARGETS - does the IK reach them, are they smooth, are they in range" {
    // ★★★ DRECON2 0as's THREE QUESTIONS, ANSWERED FOR THE FIRST TIME. Every tracking failure in
    // that log was measured against these targets without anyone knowing whether they were
    // reachable, smooth or legal. Ten seconds of the dance, on `humanoid_flex` (what `dance_track`
    // uses) and `humanoid_flex2` (what the retarget's WHOLE BODY test validated). Printed per
    // joint wherever a joint leaves its range or jumps more than 0.3 rad in one frame.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    const Case = struct {
        xml: []const u8,
        label: []const u8,
        convert: FrameConvert = .rotate,
        settle: u32 = 8,
        posture: f32 = 0.15,
    };
    const cases = [_]Case{
        .{ .xml = flex_xml, .label = "humanoid_flex, swizzle (dance_track's)", .convert = .swizzle, .settle = 0 },
        .{ .xml = flex_xml, .label = "humanoid_flex, proper rotation" },
        .{ .xml = flex2_xml, .label = "humanoid_flex2, posture 0.15" },
        .{ .xml = flex2_xml, .label = "humanoid_flex2, posture 1", .posture = 1.0 },
        .{ .xml = flex2_xml, .label = "humanoid_flex2, posture 5", .posture = 5.0 },
        .{ .xml = flex2_xml, .label = "humanoid_flex2, posture 25", .posture = 25.0 },
    };
    for (cases) |case| {
        const xml: []const u8 = case.xml;
        const label: []const u8 = case.label;
        var model: Loaded = undefined;
        try Loaded.load(gpa, &model, xml, false, 1.0 / 60.0);
        defer model.deinit(gpa);
        const m: *const rbt.Model = &model.imported.model;
        var clip: Clip = try retargetClip(
            gpa,
            m,
            model.imported.names,
            &dance.capture,
            &dance.tpose,
            .{ .seconds = 10.0, .convert = case.convert, .settle_passes = case.settle, .posture_weight = case.posture },
        );
        defer clip.deinit();
        try measureTargets(gpa, m, &clip, model.imported.names, label);
        try expect(clip.frame_count > 0);
    }
}

test "robot_dance: following the retargeted dance LOCALLY - fixed base, both engines, 60 Hz (B0-B2)" {
    // ★★★ THE STEP THIS PROJECT STALLED ON: follow, joint by joint, a pose that came out of the
    // retarget. Torso welded to the world, so balance is not in it; the targets are the proper-
    // rotation, in-range, continuity-weighted ones measured above. B1: reach dance frame 0 from
    // rest in one second. B2: follow all ten seconds. Reduced: `Tracker` - implicit computed
    // torque with the reference's own velocity and acceleration as feed-forward, hinges and
    // balls alike (B0). Maximal: its motors re-targeted every step, where the converter can
    // build the model. One metric for both: the worst body's rotation error, in degrees.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    const dt: f32 = 1.0 / 60.0;
    const frequency: f32 = 20.0;

    for ([_][]const u8{ flex_xml, flex2_xml }, [_][]const u8{ "humanoid_flex", "humanoid_flex2" }) |xml, label| {
        var floating: Loaded = undefined;
        try Loaded.load(gpa, &floating, xml, false, dt);
        defer floating.deinit(gpa);
        var clip: Clip = try retargetClip(
            gpa,
            &floating.imported.model,
            floating.imported.names,
            &dance.capture,
            &dance.tpose,
            .{ .seconds = 10.0 },
        );
        defer clip.deinit();

        var fixed: Loaded = undefined;
        try Loaded.load(gpa, &fixed, xml, true, dt);
        defer fixed.deinit(gpa);
        const m: *rbt.Model = &fixed.imported.model;
        // Limp the way the comparison needs. Only a model with no ball joints gets a maximal twin,
        // and only then does the armature go too (the ragdoll can't represent it, so both engines
        // should see the same machine). Otherwise it stays: zeroing it gains nothing here, and
        // leaves humanoid_flex2's mass matrix singular in some poses.
        const has_balls: bool = for (0..m.njnt) |j| {
            if (m.jnt_type[j] == .ball) {
                break true;
            }
        } else false;
        if (has_balls) {
            limpKeepArmature(m);
        } else {
            rmx.limpReduced(m);
        }
        const nq: usize = m.nq; // the floating pose is 7 root values, then these
        try expect(clip.nq == nq + 7);

        var target: rbt.Data = try rbt.Data.init(gpa, m);
        defer target.deinit();
        var tracker: Tracker = try .init(gpa, m.nv);
        defer tracker.deinit();
        const a_des: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(a_des);
        const torque: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(torque);
        const rots: []Quat = try gpa.alloc(Quat, m.nbody);
        defer gpa.free(rots);

        var world: zimrphysics.World = try .init(gpa, 64);
        defer world.deinit(gpa);
        world.gravity = vec(0, 0, -9.81);
        world.settings.allow_sleeping = false;
        // Null where the converter cannot build the model yet (ball joints): the maximal side is skipped.
        // lint:off catch-suppression: an unsupported model is a skipped column, not a failed test
        var maybe_ragdoll: ?rmx.Ragdoll = rmx.build(gpa, &world, m, &fixed.data, .{
            .swing_twist_limits = false,
        }) catch null;
        defer if (maybe_ragdoll) |*r| r.deinit();

        const pose = struct {
            fn of(
                c: *const Clip,
                frame: usize,
                count: usize,
            ) []const f32 {
                return c.pose(frame)[7..][0..count];
            }
        }.of;
        const setTarget = struct {
            fn at(
                t: *rbt.Data,
                model: *const rbt.Model,
                q: []const f32,
            ) void {
                @memcpy(t.pos, q);
                t.stage = .stale;
                rbt.forward(model, t);
            }
        }.at;

        // ── B1: reach dance frame 0 from rest, one second, holding it (all three targets equal). ──
        const first: []const f32 = pose(&clip, 0, nq);
        setTarget(&target, m, first);
        if (maybe_ragdoll) |*r| {
            r.driveToPose(&world, m, &target, .{ .frequency = frequency });
        }
        for (0..60) |_| {
            rbt.forward(m, &fixed.data);
            tracker.accelerations(m, &fixed.data, .{ first, first, first }, frequency, dt, a_des);
            rbt.biasForce(m, &fixed.data);
            rbt.inverseDynamics(m, &fixed.data, a_des, torque);
            @memcpy(fixed.data.applied_force, torque);
            rbt.step(m, &fixed.data);
            try zimrphysics.step(&world, dt);
        }
        rbt.forward(m, &fixed.data);
        const b1_reduced: f32 = worstBodyErrorDeg(m, fixed.data.body_xrot, target.body_xrot);
        var b1_maximal: f32 = -1.0;
        if (maybe_ragdoll) |*r| {
            for (1..m.nbody) |b| {
                rots[b] = r.robotBodyFrame(&world, b).rot;
            }
            rots[0] = target.body_xrot[0];
            b1_maximal = worstBodyErrorDeg(m, rots, target.body_xrot);
        }

        // ── B2: follow the clip from frame 0's pose. ──
        var worst: [2]f32 = .{ 0, 0 };
        var worst_frame: [2]usize = .{ 0, 0 };
        var sum: [2]f32 = .{ 0, 0 };
        var over_ten: [2]u32 = .{ 0, 0 };
        for (0..clip.frame_count - 1) |frame| {
            const now: []const f32 = pose(&clip, frame, nq);
            const next: []const f32 = pose(&clip, frame + 1, nq);
            const before: []const f32 = pose(&clip, if (frame == 0) 0 else frame - 1, nq);
            if (maybe_ragdoll) |*r| {
                setTarget(&target, m, now);
                r.driveToPose(&world, m, &target, .{ .frequency = frequency });
            }
            rbt.forward(m, &fixed.data);
            tracker.accelerations(m, &fixed.data, .{ before, now, next }, frequency, dt, a_des);
            rbt.biasForce(m, &fixed.data);
            rbt.inverseDynamics(m, &fixed.data, a_des, torque);
            @memcpy(fixed.data.applied_force, torque);
            rbt.step(m, &fixed.data);
            try zimrphysics.step(&world, dt);

            // Measured against where the clip is NOW - the frame just driven toward.
            setTarget(&target, m, next);
            rbt.forward(m, &fixed.data);
            var errors: [2]f32 = .{ worstBodyErrorDeg(m, fixed.data.body_xrot, target.body_xrot), -1.0 };
            if (maybe_ragdoll) |*r| {
                for (1..m.nbody) |b| {
                    rots[b] = r.robotBodyFrame(&world, b).rot;
                }
                rots[0] = target.body_xrot[0];
                errors[1] = worstBodyErrorDeg(m, rots, target.body_xrot);
            }
            for (0..2) |side| {
                sum[side] += errors[side];
                if (errors[side] > 10.0) {
                    over_ten[side] += 1;
                }
                if (errors[side] > worst[side]) {
                    worst[side] = errors[side];
                    worst_frame[side] = frame + 1;
                }
            }
        }
        const frames: f32 = float(clip.frame_count - 1);
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print(
            "\n  following the dance locally, {s}, fixed base, 60 Hz, {d:.0} Hz springs:\n" ++
                "    B1 reach frame 0 in 1 s:  reduced {d:.2} deg   maximal {d:.2} deg (-1: not built)\n" ++
                "    B2 worst body per frame:  reduced mean {d:.2}, worst {d:.2} at frame {d}, " ++
                "{d} frames over 10 deg\n" ++
                "                              maximal mean {d:.2}, worst {d:.2} at frame {d}, " ++
                "{d} frames over 10 deg\n",
            .{
                label,           frequency,
                b1_reduced,      b1_maximal,
                sum[0] / frames, worst[0],
                worst_frame[0],  over_ten[0],
                sum[1] / frames, worst[1],
                worst_frame[1],  over_ten[1],
            },
        );
        try expect(b1_reduced < 2.0);
    }
}

/// What the floor must supply for the reference motion to happen EXACTLY: the root's rows of
/// the reference's own inverse dynamics, frame by frame — no controller, no tracking error.
const Demand = struct {
    min_vertical: f32 = 1.0e9,
    max_vertical: f32 = 0,
    max_horizontal: f32 = 0,
    mean_torque: f32 = 0,
    max_torque: f32 = 0,
    /// Frames a floor cannot supply: pulling down, or sideways beyond friction 0.7.
    pulling: u32 = 0,
    slipping: u32 = 0,
    frames: u32 = 0,
};

/// ★★★ THE BALANCE DEMAND OF A CLIP, WITH NOTHING ELSE IN IT. Measuring the carrying stick while a
/// controller ran mixed in the controller's own corrections: a few degrees of error times a
/// 20 Hz spring's w^2 is hundreds of rad/s^2 at a joint, and it all reacts through the root —
/// the horizontal demand stayed at 5x body weight whatever the filter. Here each frame's
/// inverse dynamics is taken at the REFERENCE's pose and velocity, for the reference's
/// acceleration: the wrench the environment must supply for the dance itself.
fn referenceDemand(
    gpa: Allocator,
    m: *const rbt.Model,
    d: *rbt.Data,
    clip: *const Clip,
) !Demand {
    const dt: f32 = clip.frame_time;
    const nv: usize = m.nv;
    const v_in: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(v_in);
    const v_out: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(v_out);
    const accel: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(accel);
    const wrench: []f32 = try gpa.alloc(f32, nv);
    defer gpa.free(wrench);
    var demand: Demand = .{};
    for (1..clip.frame_count - 1) |f| {
        rbt.differentiatePos(m, v_in, clip.pose(f - 1), clip.pose(f), dt);
        rbt.differentiatePos(m, v_out, clip.pose(f), clip.pose(f + 1), dt);
        for (0..nv) |v| {
            accel[v] = (v_out[v] - v_in[v]) / dt;
        }
        @memcpy(d.pos, clip.pose(f));
        for (0..nv) |v| {
            d.vel[v] = 0.5 * (v_in[v] + v_out[v]);
        }
        d.stage = .stale;
        rbt.forward(m, d);
        rbt.biasForce(m, d);
        rbt.inverseDynamics(m, d, accel, wrench);
        const horizontal: f32 = @sqrt(wrench[0] * wrench[0] + wrench[1] * wrench[1]);
        const vertical: f32 = wrench[2];
        const twist: f32 = @sqrt(wrench[3] * wrench[3] + wrench[4] * wrench[4] + wrench[5] * wrench[5]);
        demand.min_vertical = @min(demand.min_vertical, vertical);
        demand.max_vertical = @max(demand.max_vertical, vertical);
        demand.max_horizontal = @max(demand.max_horizontal, horizontal);
        demand.max_torque = @max(demand.max_torque, twist);
        demand.mean_torque += twist;
        demand.frames += 1;
        if (vertical < 0.0) {
            demand.pulling += 1;
        } else if (horizontal > 0.7 * vertical) {
            demand.slipping += 1;
        }
    }
    demand.mean_torque /= float(demand.frames);
    return demand;
}

/// Make a model "limp": no joint springs, no joint damping, no tendon springs. Afterwards the only
/// forces on the joints are the ones a servo applies, so inverse dynamics accounts for every one of
/// them and a clip can be followed exactly.
///
/// The ARMATURE stays, because it isn't a force at all: it's extra inertia on each joint (think of a
/// motor's rotor), and it belongs in the mass matrix. Take it out and humanoid_flex2's mass matrix
/// goes singular in some poses. (`robot_maximal.limpReduced` zeroes the armature too, but only for
/// comparisons with a maximal ragdoll, which can't represent it.)
pub fn limpKeepArmature(m: *rbt.Model) void {
    @memset(m.jnt_stiffness, 0.0);
    @memset(m.jnt_damping, 0.0);
    m.has_dof_damping = false;
    @memset(m.tendon_stiffness, 0.0);
    @memset(m.tendon_damping, 0.0);
}

/// What one puppet run measured.
const PuppetStats = struct {
    mean_error: f32 = 0,
    worst_error: f32 = 0,
    max_horizontal: f32 = 0,
    min_vertical: f32 = 1.0e9,
    max_vertical: f32 = 0,
    mean_torque: f32 = 0,
    max_torque: f32 = 0,
    /// Frames the floor could not supply: pulling down, or sideways beyond friction 0.7.
    pulling: u32 = 0,
    slipping: u32 = 0,
    root_accel_mean: f32 = 0,
    root_accel_max: f32 = 0,
};

/// B3: the floating model's root carried along `clip` by a rigid stick (the root's rows of
/// M a + c applied as its wrench), the joints tracked by `Tracker`, no floor.
fn runPuppet(
    gpa: Allocator,
    m: *rbt.Model,
    d: *rbt.Data,
    clip: *const Clip,
    frequency: f32,
) !PuppetStats {
    const dt: f32 = clip.frame_time;
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a_des: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a_des);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    @memcpy(d.pos, clip.pose(0));
    @memset(d.vel, 0);
    d.stage = .stale;

    var stats: PuppetStats = .{};
    const frames: usize = clip.frame_count - 1;
    for (0..frames) |frame| {
        const now: []const f32 = clip.pose(frame);
        const next: []const f32 = clip.pose(frame + 1);
        const before: []const f32 = clip.pose(if (frame == 0) 0 else frame - 1);
        rbt.forward(m, d);
        tracker.accelerations(m, d, .{ before, now, next }, frequency, dt, a_des);
        rbt.biasForce(m, d);
        rbt.inverseDynamics(m, d, a_des, torque);
        // ★★ THE STICK PUSHES, IT DOES NOT JUST TELEPORT: all rows are applied, the root's being
        // the stick's wrench. Joint rows alone left the body free-falling within each step while
        // the torques assumed a held root: 171 degrees from the first frames.
        @memcpy(d.applied_force, torque);
        const horizontal: f32 = @sqrt(torque[0] * torque[0] + torque[1] * torque[1]);
        const vertical: f32 = torque[2];
        const twist: f32 = @sqrt(torque[3] * torque[3] + torque[4] * torque[4] + torque[5] * torque[5]);
        stats.max_horizontal = @max(stats.max_horizontal, horizontal);
        stats.min_vertical = @min(stats.min_vertical, vertical);
        stats.max_vertical = @max(stats.max_vertical, vertical);
        stats.max_torque = @max(stats.max_torque, twist);
        stats.mean_torque += twist;
        if (vertical < 0.0) {
            stats.pulling += 1;
        } else if (horizontal > 0.7 * vertical) {
            stats.slipping += 1;
        }
        rbt.step(m, d);
        @memcpy(d.pos[0..7], next[0..7]);
        @memcpy(d.vel[0..6], tracker.v_ref[0..6]);
        d.stage = .stale;

        @memcpy(target.pos, next);
        target.stage = .stale;
        rbt.forward(m, &target);
        rbt.forward(m, d);
        const err: f32 = worstBodyErrorDeg(m, d.body_xrot, target.body_xrot);
        stats.mean_error += err;
        stats.worst_error = @max(stats.worst_error, err);
        if (frame >= 1) {
            const p0: []const f32 = before[0..3];
            const p2: []const f32 = next[0..3];
            const ik: Vec = vec(p2[0] - 2 * now[0] + p0[0], p2[1] - 2 * now[1] + p0[1], p2[2] - 2 * now[2] + p0[2]);
            const accel: f32 = length3(ik / splat(dt * dt));
            stats.root_accel_mean += accel;
            stats.root_accel_max = @max(stats.root_accel_max, accel);
        }
    }
    const count: f32 = float(frames);
    stats.mean_error /= count;
    stats.mean_torque /= count;
    stats.root_accel_mean /= count;
    return stats;
}

test "robot_dance: B3 the PUPPET - and how much of the balance demand filtering removes" {
    // ★★ B2 WITH THE TORSO MOVING AS THE DANCER'S DOES, and the stick that carries it as the
    // measuring instrument for balance: its wrench is what the feet must supply once there is a
    // floor. Unfiltered it asked for 5x body weight sideways and -1,470 N vertically - mostly
    // capture jitter. Swept here over the reference's low-pass cutoff, with how far each filter
    // bends the dance (the worst body's rotation away from the unfiltered target).
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    const dt: f32 = 1.0 / 60.0;

    for ([_][]const u8{ flex_xml, flex2_xml }, [_][]const u8{ "humanoid_flex", "humanoid_flex2" }) |xml, label| {
        var model: Loaded = undefined;
        try Loaded.load(gpa, &model, xml, false, dt);
        defer model.deinit(gpa);
        const m: *rbt.Model = &model.imported.model;
        limpKeepArmature(m);
        var clip: Clip = try retargetClip(gpa, m, model.imported.names, &dance.capture, &dance.tpose, .{
            .seconds = 10.0,
        });
        defer clip.deinit();
        try expect(m.jnt_type[0] == .free and m.jnt_dof_adr[0] == 0 and m.jnt_qpos_adr[0] == 0);
        var total_mass: f32 = 0.0;
        for (m.body_mass) |mass| {
            total_mass += mass;
        }
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("\n  B3 the puppet, {s}, 60 Hz, 20 Hz springs (weight {d:.0} N; floor-impossible frames " ++
            "of {d}: pulling / beyond friction 0.7):\n", .{ label, total_mass * 9.81, clip.frame_count - 1 });
        var original: rbt.Data = try rbt.Data.init(gpa, m);
        defer original.deinit();
        var filtered_pose: rbt.Data = try rbt.Data.init(gpa, m);
        defer filtered_pose.deinit();
        for ([_]f32{ 0, 12, 8, 5, 3 }) |cutoff| {
            var smooth: Clip = if (cutoff > 0) try clip.smoothed(m, cutoff) else try clip.smoothed(m, 1000);
            defer smooth.deinit();
            // How far the filter bent the dance.
            var bent: f32 = 0.0;
            for (0..clip.frame_count) |f| {
                @memcpy(original.pos, clip.pose(f));
                original.stage = .stale;
                rbt.forward(m, &original);
                @memcpy(filtered_pose.pos, smooth.pose(f));
                filtered_pose.stage = .stale;
                rbt.forward(m, &filtered_pose);
                bent = @max(bent, worstBodyErrorDeg(m, filtered_pose.body_xrot, original.body_xrot));
            }
            const stats: PuppetStats = try runPuppet(gpa, m, &model.data, &smooth, 20.0);
            const demand: Demand = try referenceDemand(gpa, m, &model.data, &smooth);
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    cutoff {d:>3.0} Hz REFERENCE DEMAND: vertical {d:>6.0}..{d:>5.0} N, horizontal <= " ++
                "{d:>5.0} N, torque mean {d:>4.0} max {d:>5.0} Nm | floor-impossible {d} pulling, {d} slipping " ++
                "of {d}\n", .{
                cutoff,             demand.min_vertical, demand.max_vertical, demand.max_horizontal,
                demand.mean_torque, demand.max_torque,   demand.pulling,      demand.slipping,
                demand.frames,
            });
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    cutoff {d:>3.0} Hz (0 = none)  bent <= {d:>5.1} deg | " ++
                "tracking mean {d:>5.2} worst {d:>6.2} deg | " ++
                "root accel mean {d:>5.1} max {d:>5.1} | vertical {d:>6.0}..{d:>5.0} N, horizontal <= {d:>5.0} N, " ++
                "torque mean {d:>4.0} max {d:>5.0} Nm | floor-impossible {d} / {d}\n", .{
                cutoff,                bent,
                stats.mean_error,      stats.worst_error,
                stats.root_accel_mean, stats.root_accel_max,
                stats.min_vertical,    stats.max_vertical,
                stats.max_horizontal,  stats.mean_torque,
                stats.max_torque,      stats.pulling,
                stats.slipping,
            });
            try expect(zm.isFinite(stats.mean_error));
        }
    }
}

test "robot_dance: are the reference's FEET on the floor?" {
    // ★★ A FLOOR PUSHES ONLY ON WHAT TOUCHES IT. The reference's balance demand is feasible in
    // magnitude after light filtering (0 pulling frames at 5 Hz), but the feet must also BE on the
    // floor when the push is needed - not floating above it, not sunk into it. Per frame: the
    // lowest point of either foot, z = 0 the floor; without and with `RetargetOptions.ground`.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    for ([_][]const u8{ flex_xml, flex2_xml }, [_][]const u8{ "humanoid_flex", "humanoid_flex2" }) |xml, label| {
        var model: Loaded = undefined;
        try Loaded.load(gpa, &model, xml, false, 1.0 / 60.0);
        defer model.deinit(gpa);
        const m: *const rbt.Model = &model.imported.model;
        for ([_]bool{ false, true }) |ground| {
            var clip: Clip = try retargetClip(gpa, m, model.imported.names, &dance.capture, &dance.tpose, .{
                .seconds = 10.0,
                .ground = ground,
            });
            defer clip.deinit();
            var deepest: f32 = 1.0e9;
            var highest: f32 = -1.0e9;
            var grounded: u32 = 0;
            var floating: u32 = 0;
            var sunk: u32 = 0;
            for (0..clip.frame_count) |f| {
                @memcpy(model.data.pos, clip.pose(f));
                model.data.stage = .stale;
                rbt.forward(m, &model.data);
                const lowest: f32 = lowestFootPoint(m, &model.data, model.imported.names);
                deepest = @min(deepest, lowest);
                highest = @max(highest, lowest);
                if (lowest < -0.02) {
                    sunk += 1;
                } else if (lowest > 0.05) {
                    floating += 1;
                } else {
                    grounded += 1;
                }
            }
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("\n  lowest foot point, {s}, grounded {}: deepest {d:.3} m, highest {d:.3} m | " ++
                "on the floor (-2..+5 cm) {d}, floating {d}, sunk {d} of {d}\n", .{
                label, ground, deepest, highest, grounded, floating, sunk, clip.frame_count,
            });
        }
    }
}

const robot_physics = @import("robot_physics.zig");

/// A static floor whose top face is z = 0, and a world that never sleeps.
fn floorWorld(gpa: Allocator) !zimrphysics.World {
    var world: zimrphysics.World = try .init(gpa, 64);
    errdefer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    world.settings.allow_sleeping = false;
    world.settings.penetration_slop = 0.005;
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(20, 20, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
        .friction = 0.7,
    });
    return world;
}

/// How one run on the floor went.
const FloorStats = struct {
    survived: f32 = 0,
    mean_error: f32 = 0,
    worst_error: f32 = 0,
    mean_assist_force: f32 = 0,
    mean_assist_torque: f32 = 0,
};

/// How the joint torques account for the floor.
const FloorMode = enum {
    /// Inverse dynamics as if the root were carried; the floor's forces ignored.
    held_root,
    /// `contactTorques`: the root's demand hard, the unsupplied part a residual (assisted by alpha).
    contact_aware,
    /// `contactConsistentTorques`: the root's demand a preference; no assist exists.
    consistent,
};

const FloorRun = struct {
    mode: FloorMode,
    /// Fraction of the residual (root rows) an outside hand supplies. 0: none.
    alpha: f32 = 0,
    /// `contactConsistentTorques`' preference for the reference root acceleration.
    root_weight: f32 = 100,
    /// A forward velocity given to the whole body at the start, as a push at the torso would.
    shove: f32 = 0,
};

/// Play `clip` on a floor from its frame 1, the free root carried by the floor alone (plus the
/// assist, if any), the joints driven by `Tracker` + inverse dynamics split as `run.mode` says.
/// The run ends at a fall: the torso under half its reference height, or 0.5 m off it.
fn runOnFloor(
    gpa: Allocator,
    m: *rbt.Model,
    d: *rbt.Data,
    clip: *const Clip,
    run: FloorRun,
) !FloorStats {
    const dt: f32 = clip.frame_time;
    const frequency: f32 = 20.0;
    var world: zimrphysics.World = try floorWorld(gpa);
    defer world.deinit(gpa);
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    var contact_scratch: ContactScratch = try .init(gpa, m.nv);
    defer contact_scratch.deinit();
    const a_des: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a_des);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const dense: []f32 = try gpa.alloc(f32, @as(usize, m.nv) * m.nv);
    defer gpa.free(dense);

    // ★ Start at frame 1, moving as the clip moves there: at frame 0 "before" is "now", so the
    // reference acceleration came out as v_ref / dt - a ~30 m/s^2 shove that was never in the dance.
    @memcpy(d.pos, clip.pose(1));
    rbt.differentiatePos(m, d.vel, clip.pose(0), clip.pose(1), dt);
    d.vel[0] += run.shove;
    d.stage = .stale;
    rbt.forward(m, d);
    var bridge: robot_physics.Bridge = try .init(gpa, &world, m, d, 256);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    var stats: FloorStats = .{};
    var alive_frames: u32 = 0;
    for (1..clip.frame_count - 1) |frame| {
        const now: []const f32 = clip.pose(frame);
        const next: []const f32 = clip.pose(frame + 1);
        const before: []const f32 = clip.pose(frame - 1);
        rbt.forward(m, d);
        try bridge.sync(&world, m, d);
        try zimrphysics.step(&world, dt);
        bridge.harvest(d);
        tracker.accelerations(m, d, .{ before, now, next }, frequency, dt, a_des);
        rbt.biasForce(m, d);
        rbt.inverseDynamics(m, d, a_des, torque);
        switch (run.mode) {
            .held_root => {},
            .contact_aware => {
                @memcpy(a_des, torque); // a_des is not read again this step: reuse it as the wrench
                _ = contactTorques(m, d, a_des, &contact_scratch, torque);
            },
            .consistent => {
                @memcpy(a_des, torque);
                rbt.massMatrixDense(m, d, dense);
                _ = contactConsistentTorques(m, d, a_des, dense, run.root_weight, &contact_scratch, torque);
            },
        }
        @memset(d.applied_force, 0);
        @memcpy(d.applied_force[6..], torque[6..]);
        for (0..6) |k| {
            d.applied_force[k] = run.alpha * torque[k];
        }
        stats.mean_assist_force += run.alpha * length3(vec(torque[0], torque[1], torque[2]));
        stats.mean_assist_torque += run.alpha * length3(vec(torque[3], torque[4], torque[5]));
        rbt.step(m, d);

        rbt.forward(m, d);
        const off: f32 = length3(vec(d.pos[0] - next[0], d.pos[1] - next[1], 0));
        if (!zm.isFinite(d.pos[2]) or d.pos[2] < 0.5 * next[2] or off > 0.5) {
            break;
        }
        alive_frames += 1;
        @memcpy(target.pos, next);
        target.stage = .stale;
        rbt.forward(m, &target);
        const err: f32 = worstBodyErrorDeg(m, d.body_xrot, target.body_xrot);
        stats.mean_error += err;
        stats.worst_error = @max(stats.worst_error, err);
    }
    const alive: f32 = float(@max(alive_frames, 1));
    stats.survived = float(alive_frames) * dt;
    stats.mean_error /= alive;
    stats.mean_assist_force /= alive;
    stats.mean_assist_torque /= alive;
    return stats;
}

fn modeLabel(mode: FloorMode) []const u8 {
    return switch (mode) {
        .held_root => "held-root ID",
        .contact_aware => "contact-aware",
        .consistent => "consistent",
    };
}

test "robot_dance: R0 - the free root on a FLOOR, assisted, the assist scaled toward zero" {
    // ★★★ THE FIRST FREE-ROOT RUNG. humanoid_flex2, its reference filtered at 5 Hz and grounded,
    // a real floor through the physics bridge, 60 Hz. The joints get the inverse-dynamics torques
    // for the reference motion; the root an ASSIST - alpha times the residual root rows, the
    // wrench a stick would push with. alpha = 0 is no help at all: DReCon's "open-loop playback".
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    limpKeepArmature(m);
    var raw: Clip = try retargetClip(gpa, m, model.imported.names, &dance.capture, &dance.tpose, .{ .seconds = 10.0 });
    defer raw.deinit();
    var clip: Clip = try raw.smoothed(m, 5.0);
    defer clip.deinit();
    var weight: f32 = 0.0;
    for (m.body_mass) |mass| {
        weight += mass * 9.81;
    }
    const runs = [_]FloorRun{
        .{ .mode = .held_root, .alpha = 1.0 },
        .{ .mode = .held_root, .alpha = 0.0 },
        .{ .mode = .contact_aware, .alpha = 1.0 },
        .{ .mode = .contact_aware, .alpha = 0.5 },
        .{ .mode = .contact_aware, .alpha = 0.0 },
        .{ .mode = .consistent, .root_weight = 1.0e2 },
        .{ .mode = .consistent, .root_weight = 1.0e3 },
    };
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  R0, humanoid_flex2 on a floor, 60 Hz, reference " ++
        "filtered 5 Hz and grounded (weight {d:.0} N):\n", .{weight});
    for (runs) |run| {
        const stats: FloorStats = try runOnFloor(gpa, m, &model.data, &clip, run);
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("    {s:<14} assist {d:>4.2}: followed {d:>5.2} s | " ++
            "joints mean {d:>5.2} worst {d:>6.2} deg | " ++
            "assist mean {d:>5.0} N ({d:.2} of weight)\n", .{
            modeLabel(run.mode), run.alpha,               stats.survived,                   stats.mean_error,
            stats.worst_error,   stats.mean_assist_force, stats.mean_assist_force / weight,
        });
    }
}

test "robot_dance: S0-S1 - standing on the floor with the consistent controller, shoved" {
    // ★★ BALANCE BEFORE DANCE. The consistent controller already feeds the torso's error back:
    // `Tracker`'s spring on the root asks for a correcting acceleration, and the feet are asked
    // for the force to make it. The held standing pose fell over in 1.4 s as a statue (floating-
    // base torques, no floor in the split - servo_ladder §8.2). Here: humanoid_flex2's own
    // standing pose, grounded, as a ten-second "clip" that never moves; shoved 0 / 0.5 / 1 m/s.
    const gpa: Allocator = std.testing.allocator;
    const dt: f32 = 1.0 / 60.0;
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, dt);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    limpKeepArmature(m);
    // The standing pose, its lowest foot point put on the floor.
    @memcpy(model.data.pos, m.qpos0);
    model.data.stage = .stale;
    rbt.forward(m, &model.data);
    const stand: []f32 = try gpa.dupe(f32, m.qpos0);
    defer gpa.free(stand);
    stand[m.jnt_qpos_adr[0] + 2] -= lowestFootPoint(m, &model.data, model.imported.names);
    const frames: usize = 600;
    const targets: []f32 = try gpa.alloc(f32, frames * m.nq);
    for (0..frames) |f| {
        @memcpy(targets[f * m.nq ..][0..m.nq], stand);
    }
    var clip: Clip = .{
        .gpa = gpa,
        .frame_count = frames,
        .frame_time = dt,
        .nq = m.nq,
        .targets = targets,
        .residual = try gpa.alloc(f32, 0),
        .residual_body = try gpa.alloc(u32, 0),
    };
    defer clip.deinit();
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  S0/S1, humanoid_flex2 standing on the floor, 60 Hz, no assist:\n", .{});
    // ★★ The torso's corrective wish competes with eps |f|^2 on the TOTAL force: holding the body up
    // already costs ~400 N a foot, so 40 N more of correction costs ~320 against root_weight x 1 for
    // abandoning 1 m/s^2 of it. At 100 the solve dropped the correction and stood 1.47 s - a statue.
    for ([_]f32{ 1.0e2, 1.0e4, 1.0e5, 1.0e6 }) |root_weight| {
        for ([_]f32{ 0.0, 0.5, 1.0 }) |shove| {
            const stats: FloorStats = try runOnFloor(gpa, m, &model.data, &clip, .{
                .mode = .consistent,
                .root_weight = root_weight,
                .shove = shove,
            });
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    consistent, root_weight {e:>7.1}, shove {d:.1} m/s: stood {d:>5.2} s | " ++
                "joints mean {d:>5.2} worst {d:>6.2} deg\n", .{
                root_weight, shove, stats.survived, stats.mean_error, stats.worst_error,
            });
        }
    }
}

// ============================================================================
// W1 (rl_track_journal.md §10): SuperTrack on the dance - verified before anything learns.
// ============================================================================

test "robot_dance: W1.1a - the body-velocity conventions, MEASURED by finite differences" {
    // ★★★ THE CONVENTIONS A SUPERTRACK INTEGRATOR STANDS ON, measured rather than read. The world
    // model predicts each body's accelerations and integrates them (the paper's eqs. 8-12); if its
    // angular velocity is in the wrong frame, or its linear velocity is taken about the wrong
    // point, it still trains - on a subtly wrong target, which is how the last dance attempt
    // failed. So, on humanoid_flex2 (free root, hinges, ball joints): a random configuration and
    // velocity, the forward pass, a tiny `integratePos` step and forward kinematics again, and for
    // every body:
    //   * angular: cvel.ang against log(q2 q1^-1)/h (WORLD frame) and log(q1^-1 q2)/h (BODY frame);
    //   * linear: the COM's (x2 - x1)/h against cvel.lin SHIFTED from the tree's shared origin
    //     (the root's subtree COM) to the COM, v = cvel.lin + w x (c - O), and against it unshifted;
    //   * and `qmul`'s order: rotate(qmul(a, b), v) == rotate(a, rotate(b, v)).
    // The configuration is made THROUGH integratePos from the rest pose - never by writing
    // quaternions into pos by hand, so the test cannot inherit an assumption about their layout.
    const gpa: Allocator = std.testing.allocator;
    const qa: Quat = quatFromAxisAngle(vec(0, 0, 1), 0.7);
    const qb: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.4);
    const probe: Vec = vec(0.3, -0.2, 0.9);
    const composed: Vec = rotate(qmul(qa, qb), probe);
    try expect(length3(composed - rotate(qa, rotate(qb, probe))) < 1.0e-5);
    try expect(length3(composed - rotate(qb, rotate(qa, probe))) > 1.0e-2);

    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    var a: rbt.Data = try rbt.Data.init(gpa, m);
    defer a.deinit();
    var b: rbt.Data = try rbt.Data.init(gpa, m);
    defer b.deinit();
    const shake: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(shake);
    var rng: std.Random.DefaultPrng = .init(4);
    const random: std.Random = rng.random();
    const h: f32 = 1.0e-3;
    var err_world: f32 = 0.0;
    var err_body: f32 = 0.0;
    var err_shifted: f32 = 0.0;
    var err_raw: f32 = 0.0;
    var err_origin: f32 = 0.0;
    var top_w: f32 = 0.0;
    var top_v: f32 = 0.0;
    for (0..5) |_| {
        a.reset(m);
        for (shake) |*x| {
            x.* = 1.2 * random.float(f32) - 0.6;
        }
        rbt.integratePos(m, a.pos, shake, 1.0);
        rbt.normalizeQuats(m, a.pos);
        for (a.vel) |*x| {
            x.* = 4.0 * random.float(f32) - 2.0;
        }
        rbt.forward(m, &a);
        @memcpy(b.pos, a.pos);
        rbt.integratePos(m, b.pos, a.vel, h);
        rbt.kinematics(m, &b);
        for (1..m.nbody) |bi| {
            const q1: Quat = a.body_xrot[bi];
            var dw: Quat = qmul(b.body_xrot[bi], conjugate(q1));
            if (dw[3] < 0.0) {
                dw = -dw;
            }
            var db: Quat = qmul(conjugate(q1), b.body_xrot[bi]);
            if (db[3] < 0.0) {
                db = -db;
            }
            const w_world: Vec = vec(dw[0], dw[1], dw[2]) * splat(2.0 / h);
            const w_body: Vec = vec(db[0], db[1], db[2]) * splat(2.0 / h);
            const w: Vec = a.cvel[bi].ang;
            err_world = @max(err_world, length3(w - w_world));
            err_body = @max(err_body, length3(w - w_body));
            top_w = @max(top_w, length3(w));
            const origin: Vec = a.subtree_com[m.body_root[bi]];
            const com_fd: Vec = (b.body_xipos[bi] - a.body_xipos[bi]) * splat(1.0 / h);
            // `bodyVelocity` is the shift: the helper itself is what this measures.
            const com_shifted: Vec = bodyVelocity(m, &a, bi).lin;
            err_shifted = @max(err_shifted, length3(com_fd - com_shifted));
            err_raw = @max(err_raw, length3(com_fd - a.cvel[bi].lin));
            const frame_fd: Vec = (b.body_xpos[bi] - a.body_xpos[bi]) * splat(1.0 / h);
            const frame_shifted: Vec = a.cvel[bi].lin + cross(w, a.body_xpos[bi] - origin);
            err_origin = @max(err_origin, length3(frame_fd - frame_shifted));
            top_v = @max(top_v, length3(com_fd));
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  W1.1a conventions (flex2, 5 random states, h = 1e-3; " ++
        "largest |w| {d:.2} rad/s, |v| {d:.2} m/s):\n", .{ top_w, top_v });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    angular: cvel.ang vs WORLD-frame fd {d:.4}, vs BODY-frame fd {d:.4} rad/s\n", .{
        err_world,
        err_body,
    });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    linear:  COM fd vs cvel.lin SHIFTED {d:.4}, UNSHIFTED {d:.4}; " ++
        "body origin, shifted {d:.4} m/s\n", .{
        err_shifted,
        err_raw,
        err_origin,
    });
    // O(h) agreement for the right conventions; the wrong ones must be told apart (much worse).
    try expect(err_world < 0.01 * top_w + 1.0e-3);
    try expect(err_shifted < 0.01 * top_v + 1.0e-3);
    try expect(err_origin < 0.01 * top_v + 1.0e-3);
    try expect(err_body > 10.0 * err_world);
    try expect(err_raw > 10.0 * err_shifted);
}

test "robot_dance: W1.0 - the dance reference, audited before anything learns from it" {
    // ★★★ THE REFERENCE, AUDITED. What the learner will track: the 10 s dance retargeted onto
    // humanoid_flex2, filtered at 5 Hz - the servo ladder's validated reference (servo_ladder.md
    // 8.8). Reported, per joint: the joint types (the model's own facts), range excess and the
    // worst single-frame jump (`measureTargets`), quaternion SIGN FLIPS between consecutive
    // frames for every ball joint and the root (a flip makes a naive difference spin 2 pi), and
    // the largest velocity the tracker would demand (`differentiatePos` frame to frame).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    limpKeepArmature(m);
    var raw: Clip = try retargetClip(gpa, m, model.imported.names, &dance.capture, &dance.tpose, .{ .seconds = 10.0 });
    defer raw.deinit();
    var clip: Clip = try raw.smoothed(m, 5.0);
    defer clip.deinit();
    // BODY names (the runtime model carries no joint names): a joint is labelled by its body, as
    // `measureTargets` does - indexing them by joint index mislabels and overruns (24 joints,
    // 19 bodies), which this audit's first run did.
    const names: []const []const u8 = model.imported.names;
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  W1.0 the dance reference on humanoid_flex2 ({d} frames at {d:.1} Hz):\n", .{
        clip.frame_count,
        1.0 / clip.frame_time,
    });
    for (0..m.njnt) |j| {
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("    joint {d:>2} on {s:<16} {t}\n", .{ j, names[m.jnt_body[j]], m.jnt_type[j] });
    }
    try measureTargets(gpa, m, &clip, names, "W1.0 filtered 5 Hz");
    // Sign flips: consecutive frames whose quaternions have a negative dot product.
    var flips_total: u32 = 0;
    for (0..m.njnt) |j| {
        const t: rbt.JointType = m.jnt_type[j];
        if (t != .ball and t != .free) {
            continue;
        }
        const adr: usize = m.jnt_qpos_adr[j] + @as(usize, if (t == .free) 3 else 0);
        var flips: u32 = 0;
        for (1..clip.frame_count) |f| {
            const p: []const f32 = clip.pose(f - 1)[adr..][0..4];
            const q: []const f32 = clip.pose(f)[adr..][0..4];
            if (p[0] * q[0] + p[1] * q[1] + p[2] * q[2] + p[3] * q[3] < 0.0) {
                flips += 1;
            }
        }
        flips_total += flips;
        if (flips > 0) {
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    SIGN FLIPS joint {d} on {s}: {d}\n", .{ j, names[m.jnt_body[j]], flips });
        }
    }
    // The velocities the tracker would demand, frame to frame.
    const vel: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(vel);
    var worst_speed: f32 = 0.0;
    var worst_dof: usize = 0;
    var worst_frame: usize = 0;
    for (1..clip.frame_count) |f| {
        rbt.differentiatePos(m, vel, clip.pose(f - 1), clip.pose(f), clip.frame_time);
        for (vel, 0..) |v, k| {
            if (@abs(v) > worst_speed) {
                worst_speed = @abs(v);
                worst_dof = k;
                worst_frame = f;
            }
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    sign flips in total: {d}; fastest DOF {d}: {d:.2} (rad or m)/s at frame {d}\n", .{
        flips_total,
        worst_dof,
        worst_speed,
        worst_frame,
    });
}

// ============================================================================
// The confidence ladder (rl_track_journal.md §11): small rungs, each with a KNOWN right answer.
// T = retarget, J = joint servo (distinct from servo_ladder.md's B/R/S rungs).
// ============================================================================

/// -1, 0 or 1 by the sign of `x` (std.math is not for engine files; zimrmath has no sign).
fn signOf(x: f32) f32 {
    if (x > 0.0) {
        return 1.0;
    }
    if (x < 0.0) {
        return -1.0;
    }
    return 0.0;
}

/// A body's index by name (the runtime model carries none; `imported.names` does).
/// A capture joint's index by name, or null if the capture has no joint called that.
fn captureJointNamed(capture: *const codecs.bvh.Data, want: []const u8) ?usize {
    for (capture.joints, 0..) |joint, i| {
        if (std.mem.eql(u8, joint.name, want)) {
            return i;
        }
    }
    return null;
}

fn bodyNamed(names: []const []const u8, want: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, want)) {
            return i;
        }
    }
    return null;
}

/// Handedness: (left arm - right arm) x (head - hips) . (toe - foot). A proper rotation
/// keeps its sign; a REFLECTION flips it. Dot products cannot see a mirror (a reflection keeps
/// every one), which is why the T1 rungs use this triple product.
fn handedness(
    left_arm: Vec,
    right_arm: Vec,
    head: Vec,
    hips: Vec,
    toe: Vec,
    foot: Vec,
) f32 {
    return dot3(cross(left_arm - right_arm, head - hips), toe - foot);
}

/// Which capture joint drives each robot body (-1: none), through the retarget's own match table.
/// The caller frees the result.
fn matchHuman(
    gpa: Allocator,
    names: []const []const u8,
    capture: *const codecs.bvh.Data,
) ![]i32 {
    const human_names: [][]const u8 = try gpa.alloc([]const u8, capture.joints.len);
    defer gpa.free(human_names);
    for (capture.joints, 0..) |joint, i| {
        human_names[i] = joint.name;
    }
    const human_of_body: []i32 = try gpa.alloc(i32, names.len);
    errdefer gpa.free(human_of_body);
    try rbt.resolveMatchTable(&rbt.lafan_to_humanoid, names, human_names, human_of_body);
    return human_of_body;
}

/// The six robot bodies the handedness is read from, and the capture joints the match table
/// drives them with.
const ChiralBodies = struct {
    body: [6]usize,
    human: [6]usize,

    const wanted = [6][]const u8{ "upper_arm_left", "upper_arm_right", "head", "pelvis", "toe_left", "foot_left" };

    fn resolve(
        gpa: Allocator,
        names: []const []const u8,
        capture: *const codecs.bvh.Data,
    ) !ChiralBodies {
        const human_of_body: []i32 = try matchHuman(gpa, names, capture);
        defer gpa.free(human_of_body);
        var c: ChiralBodies = undefined;
        for (wanted, 0..) |name, i| {
            c.body[i] = bodyNamed(names, name) orelse return error.MissingBody;
            const h: i32 = human_of_body[c.body[i]];
            if (h < 0) {
                return error.UnmatchedBody;
            }
            c.human[i] = @intCast(h);
        }
        return c;
    }

    fn ofRobot(c: ChiralBodies, d: *const rbt.Data) f32 {
        const p = d.body_xpos;
        return handedness(p[c.body[0]], p[c.body[1]], p[c.body[2]], p[c.body[3]], p[c.body[4]], p[c.body[5]]);
    }

    fn ofCapture(c: ChiralBodies, points: []const Vec) f32 {
        const h = c.human;
        return handedness(points[h[0]], points[h[1]], points[h[2]], points[h[3]], points[h[4]], points[h[5]]);
    }
};

test "robot_dance: T1a - the conversion keeps the capture's handedness in every frame; the old swizzle flips it" {
    // ★★★ THE MIRROR BUG'S TEST, proven on the bug itself. Per frame, the capture's own RAW
    // handedness (the triple product on its Y-up joints, before any conversion) against the
    // same after conversion: `.rotate` (a proper rotation) must keep its sign in EVERY frame,
    // `.swizzle` (dance_track's old mirror) must flip it in every frame. No anatomical
    // assumption: the first version compared against the robot's rest sign and agreed in only 581
    // of 600 frames - a dancer's foot pointing backwards flips the triple product legitimately,
    // so that measured the choreography, not the conversion. Cheap: no retargeting.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const chiral: ChiralBodies = try .resolve(gpa, model.imported.names, &dance.capture);
    const capture: *const codecs.bvh.Data = &dance.capture;
    const n: usize = capture.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    const converted: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(converted);
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    const conversions = [_]FrameConvert{ .rotate, .swizzle };
    var kept: [2]usize = .{ 0, 0 };
    var degenerate: usize = 0;
    for (0..capture.frame_count) |f| {
        var root: Vec = vec_zero;
        globalsAtFrame(capture, f, local, global, &root);
        bvhPoints(capture, global, points);
        const raw: f32 = chiral.ofCapture(points);
        if (raw == 0.0) {
            degenerate += 1;
            continue;
        }
        for (conversions, 0..) |convert, ci| {
            for (points, converted) |p, *c| {
                c.* = toRobot(convert, to_robot, p);
            }
            if (signOf(chiral.ofCapture(converted)) == signOf(raw)) {
                kept[ci] += 1;
            }
        }
    }
    const judged: usize = capture.frame_count - degenerate;
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  T1a over {d} frames: .rotate keeps the raw handedness in {d}, .swizzle in {d}\n", .{
        judged,
        kept[0],
        kept[1],
    });
    try expect(judged > 0);
    try expect(kept[0] == judged);
    try expect(kept[1] == 0);
}

test "robot_dance: T1b - the retarget through the old mirror cannot fit; through the rotation it does" {
    // The retarget end to end, through `.rotate` and through the old swizzle (a mirror). A rigid
    // robot cannot fit a MIRRORED point cloud, so the IK residual is the retarget-level detector:
    // through the rotation it must stay small, through the mirror it must blow up. The first
    // version asserted on the robot's handedness per frame instead - and the robot "followed" the
    // mirror too (547 of 561 frames against 553 through the rotation): on the robot the triple
    // product is built from limb vectors, and a body with ball knees and ankles can contort until
    // even a mirrored cloud gives the "right" sign. Printed for the record, not asserted: it is a
    // pose proxy there, not a chirality measure. Two 10 s retargets.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    const names: []const []const u8 = model.imported.names;
    const chiral: ChiralBodies = try .resolve(gpa, names, &dance.capture);
    const capture: *const codecs.bvh.Data = &dance.capture;
    const n: usize = capture.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    var kin: rbt.Data = try rbt.Data.init(gpa, m);
    defer kin.deinit();
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    const conversions = [_]FrameConvert{ .rotate, .swizzle };
    var agree: [2]usize = .{ 0, 0 };
    var judged: [2]usize = .{ 0, 0 };
    var mean_residual: [2]f32 = .{ 0, 0 };
    for (conversions, 0..) |convert, ci| {
        var clip: Clip = try retargetClip(gpa, m, names, capture, &dance.tpose, .{
            .seconds = 10.0,
            .convert = convert,
            .ground = false,
        });
        defer clip.deinit();
        for (clip.residual) |r| {
            mean_residual[ci] += r;
        }
        mean_residual[ci] /= float(clip.frame_count);
        // The capture's handedness per frame (converted), and its median magnitude.
        const values: []f32 = try gpa.alloc(f32, clip.frame_count);
        defer gpa.free(values);
        for (0..clip.frame_count) |f| {
            var root: Vec = vec_zero;
            globalsAtFrame(capture, f, local, global, &root);
            bvhPoints(capture, global, points);
            for (points) |*p| {
                p.* = toRobot(convert, to_robot, p.*);
            }
            values[f] = chiral.ofCapture(points);
        }
        const sorted: []f32 = try gpa.dupe(f32, values);
        defer gpa.free(sorted);
        for (sorted) |*v| {
            v.* = @abs(v.*);
        }
        std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
        const least: f32 = 0.25 * sorted[sorted.len / 2];
        for (0..clip.frame_count) |f| {
            if (@abs(values[f]) < least) {
                continue;
            }
            @memcpy(kin.pos, clip.pose(f));
            kin.stage = .stale;
            rbt.kinematics(m, &kin);
            judged[ci] += 1;
            if (signOf(chiral.ofRobot(&kin)) == signOf(values[f])) {
                agree[ci] += 1;
            }
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  T1b IK residual, mean over the clip: through the rotation " ++
        "{d:.3} m, through the old mirror {d:.3} m\n" ++
        "      (handedness proxy, not asserted: robot agrees with capture in " ++
        "{d} of {d} frames through the rotation, " ++
        "{d} of {d} through the mirror)\n", .{
        mean_residual[0],
        mean_residual[1],
        agree[0],
        judged[0],
        agree[1],
        judged[1],
    });
    // ★ MEASURED: 0.065 m through the rotation, 0.153 m through the mirror - 2.4x, where the old
    // model (humanoid_flex) showed 35.7 cm. flex2's ball knees and ankles fit a mirrored cloud
    // surprisingly well, so THE RESIDUAL IS A WEAK MIRROR DETECTOR on this robot: a future mirror
    // bug could hide under it. T1a (the conversion's handedness, exact: 600 of 600 and 0) is the
    // guard; this asserts only what holds with margin - the retarget's quality, and a mirror fits
    // clearly worse.
    try expect(mean_residual[0] < 0.10);
    try expect(mean_residual[1] > 1.5 * mean_residual[0]);
}

test "robot_dance: T0 - the capture's rest pose, retargeted, points every limb where the capture does" {
    // The capture's own T-pose (its `Geno_stance`), retargeted onto flex2 as a one-frame clip:
    // each limb segment of the robot - upper arm, forearm, thigh, shin, both sides - must point
    // where the capture's matching segment points (both in robot space, `.rotate`). Directions,
    // not hard-coded angles, so it holds for a T- or an A-pose alike. Plus the handedness of
    // the result (T1's triple product, on the ROBOT this time).
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    const names: []const []const u8 = model.imported.names;
    const tpose: *const codecs.bvh.Data = &dance.tpose;
    var clip: Clip = try retargetClip(gpa, m, names, tpose, tpose, .{ .seconds = tpose.frame_time, .ground = false });
    defer clip.deinit();
    try expect(clip.frame_count == 1);
    var kin: rbt.Data = try rbt.Data.init(gpa, m);
    defer kin.deinit();
    @memcpy(kin.pos, clip.pose(0));
    kin.stage = .stale;
    rbt.forward(m, &kin);
    // The capture's rest joints in robot space, and which joint drives which body.
    const n: usize = tpose.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    var root: Vec = vec_zero;
    globalsAtFrame(tpose, 0, local, global, &root);
    bvhPoints(tpose, global, points);
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    for (points) |*p| {
        p.* = toRobot(.rotate, to_robot, p.*);
    }
    const human_of_body: []i32 = try matchHuman(gpa, names, tpose);
    defer gpa.free(human_of_body);
    const segments = [_][2][]const u8{
        .{ "upper_arm_left", "lower_arm_left" },   .{ "lower_arm_left", "hand_left" },
        .{ "upper_arm_right", "lower_arm_right" }, .{ "lower_arm_right", "hand_right" },
        .{ "thigh_left", "shin_left" },            .{ "shin_left", "foot_left" },
        .{ "thigh_right", "shin_right" },          .{ "shin_right", "foot_right" },
    };
    var worst: f32 = 0.0;
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  T0 the capture's rest pose on flex2 (IK residual {d:.3} " ++
        "m), segment direction errors:\n", .{clip.residual[0]});
    for (segments) |seg| {
        const a: usize = bodyNamed(names, seg[0]) orelse return error.MissingBody;
        const b: usize = bodyNamed(names, seg[1]) orelse return error.MissingBody;
        const ha: i32 = human_of_body[a];
        const hb: i32 = human_of_body[b];
        if (ha < 0 or hb < 0) {
            return error.UnmatchedBody;
        }
        const robot_dir: Vec = normalize3(kin.body_xpos[b] - kin.body_xpos[a]);
        const capture_dir: Vec = normalize3(points[@intCast(hb)] - points[@intCast(ha)]);
        const angle: f32 = acosRad(clamp(dot3(robot_dir, capture_dir), -1.0, 1.0)) * 180.0 / pi;
        worst = @max(worst, angle);
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("    {s:>15} -> {s:<15} {d:>6.2} deg\n", .{ seg[0], seg[1], angle });
    }
    const chiral: ChiralBodies = try .resolve(gpa, names, tpose);
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    handedness: robot {d:.4}, capture {d:.4}\n", .{
        chiral.ofRobot(&kin),
        chiral.ofCapture(points),
    });
    try expect(signOf(chiral.ofRobot(&kin)) == signOf(chiral.ofCapture(points)));
    try expect(worst < 15.0);
}

/// One body (and a hand) on a single joint, no gravity, 60 Hz: the servo rungs' test pieces.
fn singleJointXml(comptime joint: []const u8) []const u8 {
    return
    \\<mujoco model="servo_probe">
    \\  <option timestep="0.0166666667" gravity="0 0 0"/>
    \\  <worldbody>
    \\    <body name="arm" pos="0 0 1">
    \\      
    ++ joint ++
        \\
        \\      <geom type="capsule" fromto="0 0 0 0.4 0 0" size="0.04" mass="1"/>
        \\      <body name="hand" pos="0.4 0 0">
        \\        <geom type="sphere" size="0.05" mass="0.5"/>
        \\      </body>
        \\    </body>
        \\  </worldbody>
        \\</mujoco>
    ;
}

/// The same probe with a WELDED base the arm hangs from: `robot_maximal.build` makes joints only
/// between parts below a root (a free body, or one welded to the world), so a joint straight to
/// the world is not built at all - J3a's first run drove a free-floating arm.
fn weldedJointXml(comptime joint: []const u8) []const u8 {
    return
    \\<mujoco model="servo_probe_welded">
    \\  <option timestep="0.0166666667" gravity="0 0 0"/>
    \\  <worldbody>
    \\    <body name="base" pos="0 0 1">
    \\      <geom type="sphere" size="0.05" mass="1"/>
    \\      <body name="arm" pos="0 0 0">
    \\        
    ++ joint ++
        \\
        \\        <geom type="capsule" fromto="0 0 0 0.4 0 0" size="0.04" mass="1"/>
        \\        <body name="hand" pos="0.4 0 0">
        \\          <geom type="sphere" size="0.05" mass="0.5"/>
        \\        </body>
        \\      </body>
        \\    </body>
        \\  </worldbody>
        \\</mujoco>
    ;
}

/// One servo step, exactly the dance servo's path: forward, the Tracker's accelerations toward
/// a held target, bias forces, inverse dynamics, those torques applied, a step.
fn servoStep(
    m: *const rbt.Model,
    d: *rbt.Data,
    tracker: *const Tracker,
    target: []const f32,
    frequency: f32,
    a: []f32,
    torque: []f32,
) void {
    const dt: f32 = m.opt.timestep;
    rbt.forward(m, d);
    tracker.accelerations(m, d, .{ target, target, target }, frequency, dt, a);
    rbt.biasForce(m, d);
    rbt.inverseDynamics(m, d, a, torque);
    @memcpy(d.applied_force, torque);
    rbt.step(m, d);
}

test "robot_dance: J0 - a hinge servos critically damped: no overshoot, settled when the analysis says" {
    // A hinge stepped 1 rad toward a held target by the dance servo's path. The Tracker's spring
    // is critically damped, so there must be NO overshoot, and the error must fall below 5% near
    // the analytic time: (1 + w t) e^(-w t) = 0.05 at w t = 4.74, w = 2 pi f. The implicit
    // discretisation at 60 Hz is allowed to be somewhat slower, never oscillatory.
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    const hinge_xml: []const u8 = singleJointXml("<joint name=\"hinge\" type=\"hinge\" axis=\"0 1 0\"/>");
    try Loaded.load(gpa, &model, hinge_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const target: []f32 = try gpa.dupe(f32, m.qpos0);
    defer gpa.free(target);
    target[0] += 1.0;
    const frequency: f32 = 2.0;
    const analytic: f32 = 4.74 / (2.0 * pi * frequency);
    var overshoot: f32 = 0.0;
    var settled_at: ?f32 = null;
    d.reset(m);
    for (0..180) |i| {
        servoStep(m, &d, &tracker, target, frequency, a, torque);
        const angle: f32 = d.pos[0] - m.qpos0[0];
        overshoot = @max(overshoot, angle - 1.0);
        if (settled_at == null and @abs(1.0 - angle) < 0.05) {
            settled_at = float(i + 1) * m.opt.timestep;
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  J0 hinge, 1 rad at {d} Hz: overshoot {d:.4} rad; within 5% at {d:.3} s " ++
        "(analytic {d:.3} s); final error {d:.5} rad\n", .{
        frequency,
        overshoot,
        settled_at orelse -1.0,
        analytic,
        @abs(1.0 - (d.pos[0] - m.qpos0[0])),
    });
    try expect(overshoot < 0.01);
    try expect(settled_at != null and settled_at.? < 1.5 * analytic);
}

test "robot_dance: J1 - a ball joint servos along the geodesic, from a rotated start" {
    // ★★★ THE BALL JOINT'S FRAME, TESTED WHERE IT CAN BE WRONG. From a ROTATED start (from
    // identity the child's frame and the world's coincide, and a frame mistake is invisible), a
    // correct servo moves along the GEODESIC: the rotation relative to the start stays about ONE
    // fixed axis, the world axis of R1 R0^-1. An error taken in the wrong frame bends the path by
    // up to the start's own rotation. Per case: the path's worst deviation from that axis, and the
    // final orientation error. Starts and targets are made through integratePos from the rest
    // pose - no quaternion written by hand.
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, singleJointXml("<joint name=\"ball\" type=\"ball\"/>"), false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var goal: rbt.Data = try rbt.Data.init(gpa, m);
    defer goal.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const arm: usize = bodyNamed(model.imported.names, "arm") orelse return error.MissingBody;
    const cases = [_][2][3]f32{
        .{ .{ 0.0, 1.05, 0.0 }, .{ 0.9, 0.3, -0.5 } },
        .{ .{ 0.0, 1.05, 0.0 }, .{ -1.2, 0.0, 1.0 } },
        .{ .{ 0.8, 0.0, 0.6 }, .{ 0.0, -1.4, 0.2 } },
        .{ .{ -0.5, 0.7, 1.1 }, .{ 0.4, 0.4, -1.6 } },
    };
    var worst_deviation: f32 = 0.0;
    var worst_final: f32 = 0.0;
    for (cases) |case| {
        d.reset(m);
        rbt.integratePos(m, d.pos, &case[0], 1.0);
        @memset(d.vel, 0.0);
        d.stage = .stale;
        rbt.forward(m, &d);
        const start: Quat = d.body_xrot[arm];
        goal.reset(m);
        rbt.integratePos(m, goal.pos, &case[1], 1.0);
        goal.stage = .stale;
        rbt.forward(m, &goal);
        var total: Quat = qmul(goal.body_xrot[arm], conjugate(start));
        if (total[3] < 0.0) {
            total = -total;
        }
        const axis: Vec = normalize3(vec(total[0], total[1], total[2]));
        var deviation: f32 = 0.0;
        for (0..240) |_| {
            servoStep(m, &d, &tracker, goal.pos, 2.0, a, torque);
            rbt.forward(m, &d);
            var rel: Quat = qmul(d.body_xrot[arm], conjugate(start));
            if (rel[3] < 0.0) {
                rel = -rel;
            }
            const v: Vec = vec(rel[0], rel[1], rel[2]);
            if (length3(v) > @sin(radFromDeg(1.0))) {
                const cosine: f32 = clamp(dot3(normalize3(v), axis), -1.0, 1.0);
                deviation = @max(deviation, acosRad(cosine) * 180.0 / pi);
            }
        }
        const final: f32 = worstBodyErrorDeg(m, d.body_xrot, goal.body_xrot);
        worst_deviation = @max(worst_deviation, deviation);
        worst_final = @max(worst_final, final);
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("  J1 ball, start ({d:.2}, {d:.2}, {d:.2}) -> ({d:.2}, {d:.2}, {d:.2}): path " ++
            "off the geodesic {d:.3} deg, final {d:.4} deg\n", .{
            case[0][0], case[0][1], case[0][2], case[1][0], case[1][1], case[1][2], deviation, final,
        });
    }
    try expect(worst_deviation < 2.0);
    try expect(worst_final < 0.5);
}

/// A configuration inside the joint ranges, made THROUGH integratePos from the rest pose: each
/// hinge at `reach` of the way from its range's centre toward a random end, each ball turned by
/// a random rotation of up to `ball_angle` rad, the free root (if any) moved by `root` m and rad.
fn configurationInRange(
    m: *const rbt.Model,
    pos: []f32,
    shift: []f32,
    random: std.Random,
    reach: f32,
    ball_angle: f32,
    root: f32,
) void {
    @memset(shift, 0.0);
    for (0..m.njnt) |j| {
        const dof: usize = m.jnt_dof_adr[j];
        const qadr: usize = m.jnt_qpos_adr[j];
        switch (m.jnt_type[j]) {
            .hinge, .slide => {
                const r: [2]f32 = m.jnt_range[j] orelse .{ -1.0, 1.0 };
                const centre: f32 = 0.5 * (r[0] + r[1]);
                const half: f32 = 0.5 * (r[1] - r[0]);
                const value: f32 = centre + reach * half * (2.0 * random.float(f32) - 1.0);
                shift[dof] = value - m.qpos0[qadr];
            },
            .ball => {
                const axis: Vec = normalize3(vec(random.floatNorm(f32), random.floatNorm(f32), random.floatNorm(f32)));
                const angle: f32 = ball_angle * random.float(f32);
                shift[dof] = axis[0] * angle;
                shift[dof + 1] = axis[1] * angle;
                shift[dof + 2] = axis[2] * angle;
            },
            .free => {
                for (0..6) |c| {
                    shift[dof + c] = root * (2.0 * random.float(f32) - 1.0);
                }
            },
        }
    }
    @memcpy(pos, m.qpos0);
    rbt.integratePos(m, pos, shift, 1.0);
    rbt.normalizeQuats(m, pos);
}

test "robot_dance: T2 - the IK recovers flex2's own poses from known configurations" {
    // IK SELF-CONSISTENCY. Targets: every body's world pose (origin AND rotation) from a KNOWN
    // configuration inside the joint ranges; the IK - `ikStep` with joint limits respected, as the
    // retarget runs it - starts from the rest pose and must recover them. Judged by body
    // orientations and positions, not joint values: a 3-hinge shoulder may reach the same pose by
    // an equivalent branch, and that is not an error.
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    var known: rbt.Data = try rbt.Data.init(gpa, m);
    defer known.deinit();
    var solve: rbt.Data = try rbt.Data.init(gpa, m);
    defer solve.deinit();
    const shift: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(shift);
    const tasks: []rbt.IkTask = try gpa.alloc(rbt.IkTask, m.nbody - 1);
    defer gpa.free(tasks);
    const scratch: []f32 = try gpa.alloc(f32, rbt.ikScratchSize(m.nv));
    defer gpa.free(scratch);
    var rng: std.Random.DefaultPrng = .init(12);
    const random: std.Random = rng.random();
    var worst_rot: f32 = 0.0;
    var worst_pos: f32 = 0.0;
    const trials: usize = 8;
    for (0..trials) |trial| {
        configurationInRange(m, known.pos, shift, random, 0.5, 0.5, 0.1);
        known.stage = .stale;
        rbt.forward(m, &known);
        for (tasks, 1..) |*t, b| {
            t.* = .{ .body = b, .target_world = known.body_xpos[b], .target_rotation = known.body_xrot[b] };
        }
        solve.reset(m);
        @memcpy(solve.pos, m.qpos0);
        solve.stage = .stale;
        for (0..300) |_| {
            rbt.forward(m, &solve);
            _ = rbt.ikStep(m, &solve, tasks, .{ .respect_joint_limits = true }, scratch);
        }
        rbt.forward(m, &solve);
        const rot: f32 = worstBodyErrorDeg(m, solve.body_xrot, known.body_xrot);
        var pos: f32 = 0.0;
        for (1..m.nbody) |b| {
            pos = @max(pos, length3(solve.body_xpos[b] - known.body_xpos[b]));
        }
        worst_rot = @max(worst_rot, rot);
        worst_pos = @max(worst_pos, pos);
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("  T2 trial {d}: worst body rotation {d:.4} deg, worst body position {d:.5} m\n", .{
            trial,
            rot,
            pos,
        });
    }
    try expect(worst_rot < 1.0);
    try expect(worst_pos < 0.005);
}

test "robot_dance: J2 - a fixed-base limb tracks a smooth trajectory in its own joint space" {
    // THE CHAIN. flex2 with its base fixed, gravity on; the right arm - the 3-hinge shoulder (non-
    // orthogonal axes) and the ball elbow - follows a smooth trajectory generated in its own joint
    // space through integratePos (each shoulder hinge swinging about its range's centre, the elbow
    // along a sinusoidal rotation vector), every other joint holding its rest angle; the servo is
    // the dance's own path at the B rungs' 20 Hz. Computed torque with the exact model tracks a
    // SMOOTH trajectory to within the 60 Hz discretisation: J0 and J1 bound one joint; anything
    // beyond is the chain - joint coupling, the shoulder's axes, the ball elbow.
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, true, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    const names: []const []const u8 = model.imported.names;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var ref: rbt.Data = try rbt.Data.init(gpa, m);
    defer ref.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const shift: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(shift);
    const dt: f32 = m.opt.timestep;
    const frames: usize = 240;
    const poses: []f32 = try gpa.alloc(f32, (frames + 2) * m.nq);
    defer gpa.free(poses);
    const speeds = [_]f32{ 0.5, 2.0 };
    // [model][speed]: 0 = the STOCK model (joint springs, damping and tendon springs, none of
    // which inverse dynamics cancels), 1 = LIMP (`limpKeepArmature`, what every B rung servos).
    var worst_all: [2][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 } };
    var mean_all: [2][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (0..2) |variant| {
        if (variant == 1) {
            limpKeepArmature(m);
        }
        for (speeds, 0..) |hz, si| {
            // The reference, frame by frame, through integratePos from the rest pose.
            try armReference(m, names, hz, frames, shift, poses);
            // Start ON the reference, with the discrete trajectory's velocity there: the backward
            // difference into frame 1 (what semi-implicit Euler needs to land on frame 2).
            d.reset(m);
            @memcpy(d.pos, poses[m.nq..][0..m.nq]);
            rbt.differentiatePos(m, d.vel, poses[0..m.nq], poses[m.nq..][0..m.nq], dt);
            d.stage = .stale;
            var worst: f32 = 0.0;
            var mean: f32 = 0.0;
            for (1..frames) |k| {
                const before: []const f32 = poses[(k - 1) * m.nq ..][0..m.nq];
                const now: []const f32 = poses[k * m.nq ..][0..m.nq];
                const next: []const f32 = poses[(k + 1) * m.nq ..][0..m.nq];
                rbt.forward(m, &d);
                tracker.accelerations(m, &d, .{ before, now, next }, 20.0, dt, a);
                rbt.biasForce(m, &d);
                rbt.inverseDynamics(m, &d, a, torque);
                @memcpy(d.applied_force, torque);
                rbt.step(m, &d);
                // After the step the robot should be at the NEXT reference frame.
                rbt.forward(m, &d);
                @memcpy(ref.pos, next);
                ref.stage = .stale;
                rbt.kinematics(m, &ref);
                const err: f32 = worstBodyErrorDeg(m, d.body_xrot, ref.body_xrot);
                worst = @max(worst, err);
                mean += err;
            }
            mean /= float(frames - 1);
            worst_all[variant][si] = worst;
            mean_all[variant][si] = mean;
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("  J2 {s} model, right arm at {d:.1} Hz for {d:.1} s: " ++
                "worst body {d:.4} deg, mean {d:.4} deg\n", .{
                if (variant == 0) "STOCK" else "LIMP ",
                hz,
                float(frames) * dt,
                worst,
                mean,
            });
        }
    }
    // The chain's own math (limp): within the discretisation.
    try expect(worst_all[1][0] < 0.5);
    try expect(worst_all[1][1] < 2.0);
    // And the stock model is clearly worse: the passive forces are what the servo cannot see.
    try expect(mean_all[0][0] > 2.0 * mean_all[1][0]);
}

/// A physics world and the maximal ragdoll of `m`, posed as `d`: the B rungs' setup.
const MaximalRig = struct {
    world: zimrphysics.World,
    ragdoll: rmx.Ragdoll,

    fn init(
        self: *MaximalRig,
        gpa: Allocator,
        m: *const rbt.Model,
        d: *const rbt.Data,
        gravity: f32,
    ) !void {
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .world = undefined,
            .ragdoll = undefined,
        };
        self.world = try .init(gpa, 64);
        errdefer self.world.deinit(gpa);
        self.world.gravity = vec(0, 0, gravity);
        self.world.settings.allow_sleeping = false;
        self.ragdoll = try rmx.build(gpa, &self.world, m, d, .{ .swing_twist_limits = false });
    }

    fn deinit(self: *MaximalRig, gpa: Allocator) void {
        self.ragdoll.deinit();
        self.world.deinit(gpa);
    }

    /// One step: every motor toward `target` (a forward-current reduced Data), then physics.
    fn step(
        self: *MaximalRig,
        m: *const rbt.Model,
        target: *const rbt.Data,
        frequency: f32,
        dt: f32,
    ) !void {
        self.ragdoll.driveToPose(&self.world, m, target, .{ .frequency = frequency });
        try zimrphysics.step(&self.world, dt);
    }
};

test "robot_dance: J3a - the maximal ragdoll's hinge motor: J0's step, through zimrphysics" {
    // J0 again on the RAGDOLL: the single hinge built as a zimrphysics hinge, driven by its
    // position motor (2 Hz, damping 1) toward 1 rad. A critically damped motor: no overshoot,
    // settled near J0's time (0.417 s; analytic 0.377 s), no final error.
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    const hinge_xml: []const u8 = weldedJointXml("<joint name=\"hinge\" type=\"hinge\" axis=\"0 1 0\"/>");
    try Loaded.load(gpa, &model, hinge_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    var start: rbt.Data = try rbt.Data.init(gpa, m);
    defer start.deinit();
    start.reset(m);
    rbt.forward(m, &start);
    var goal: rbt.Data = try rbt.Data.init(gpa, m);
    defer goal.deinit();
    goal.reset(m);
    goal.pos[0] += 1.0;
    goal.stage = .stale;
    rbt.forward(m, &goal);
    var rig: MaximalRig = undefined;
    try rig.init(gpa, m, &start, 0.0);
    defer rig.deinit(gpa);
    const arm: usize = bodyNamed(model.imported.names, "arm") orelse return error.MissingBody;
    const dt: f32 = m.opt.timestep;
    const rest_rot: Quat = start.body_xrot[arm];
    const axis: Vec = vec(0, 1, 0);
    var overshoot: f32 = 0.0;
    var settled_at: ?f32 = null;
    var angle: f32 = 0.0;
    for (0..180) |i| {
        try rig.step(m, &goal, 2.0, dt);
        var rel: Quat = qmul(rig.ragdoll.robotBodyFrame(&rig.world, arm).rot, conjugate(rest_rot));
        if (rel[3] < 0.0) {
            rel = -rel;
        }
        // The signed angle about the hinge's axis (world y at rest; the parent is the world).
        angle = 2.0 * atan2Rad(dot3(vec(rel[0], rel[1], rel[2]), axis), rel[3]);
        overshoot = @max(overshoot, angle - 1.0);
        if (settled_at == null and @abs(1.0 - angle) < 0.05) {
            settled_at = float(i + 1) * dt;
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  J3a ragdoll hinge, 1 rad at 2 Hz: overshoot {d:.4} rad; " ++
        "within 5% at {d:.3} s (J0: 0.417 s); " ++
        "final error {d:.5} rad\n", .{ overshoot, settled_at orelse -1.0, @abs(1.0 - angle) });
    try expect(settled_at != null);
    try expect(@abs(1.0 - angle) < 0.01);
}

test "robot_dance: J3b - the maximal ragdoll has NO ball joints: it refuses them, and so refuses flex2" {
    // ★★ A LIMITATION, ASSERTED SO IT CANNOT CHANGE SILENTLY. `robot_maximal.build` supports
    // hinges and the free root only (`error.UnsupportedJoint` for anything else). So the ball
    // probe is refused - and so is humanoid_flex2, with its 6 ball joints: the flex2 dance has only
    // ever run on the reduced model, and B2's "maximal 22.6 deg" is humanoid_flex (all hinges).
    // This rung was meant to be J1 on the ragdoll; it cannot be until the ragdoll has balls.
    const gpa: Allocator = std.testing.allocator;
    // (the probe has no free root to weld; flex2 is loaded fixed-base, as the B rungs load it)
    const Case = struct { xml: []const u8, fixed_base: bool };
    const cases = [_]Case{
        .{ .xml = weldedJointXml("<joint name=\"ball\" type=\"ball\"/>"), .fixed_base = false },
        .{ .xml = flex2_xml, .fixed_base = true },
    };
    for (cases) |case| {
        var model: Loaded = undefined;
        try Loaded.load(gpa, &model, case.xml, case.fixed_base, 1.0 / 60.0);
        defer model.deinit(gpa);
        const m: *rbt.Model = &model.imported.model;
        var d: rbt.Data = try rbt.Data.init(gpa, m);
        defer d.deinit();
        d.reset(m);
        rbt.forward(m, &d);
        var world: zimrphysics.World = try .init(gpa, 64);
        defer world.deinit(gpa);
        if (rmx.build(gpa, &world, m, &d, .{})) |ragdoll| {
            var r: rmx.Ragdoll = ragdoll;
            r.deinit();
            return error.BallJointsNowSupported; // update J3: J1 can run on the ragdoll
        } else |err| {
            try expectEqual(error.UnsupportedJoint, err);
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  J3b the ragdoll refuses ball joints (UnsupportedJoint): " ++
        "the ball probe and humanoid_flex2\n", .{});
}

/// The right arm's smooth reference (J2's): each hinge on upper_arm_right / lower_arm_right
/// swinging about its range's centre, a ball on those bodies along a sinusoidal rotation vector,
/// every other joint at rest; `frames` + 2 poses at the model's step, through integratePos.
fn armReference(
    m: *const rbt.Model,
    names: []const []const u8,
    hz: f32,
    frames: usize,
    shift: []f32,
    poses: []f32,
) !void {
    const upper: usize = bodyNamed(names, "upper_arm_right") orelse return error.MissingBody;
    const lower: usize = bodyNamed(names, "lower_arm_right") orelse return error.MissingBody;
    const dt: f32 = m.opt.timestep;
    for (0..frames + 2) |k| {
        const t: f32 = float(k) * dt;
        const w: f32 = 2.0 * pi * hz;
        @memset(shift, 0.0);
        var phase: f32 = 0.0;
        for (0..m.njnt) |j| {
            const body: usize = m.jnt_body[j];
            if (body != upper and body != lower) {
                continue;
            }
            const dof: usize = m.jnt_dof_adr[j];
            switch (m.jnt_type[j]) {
                .hinge => {
                    const r: [2]f32 = m.jnt_range[j] orelse .{ -1.0, 1.0 };
                    const centre: f32 = 0.5 * (r[0] + r[1]);
                    const value: f32 = centre + 0.3 * 0.5 * (r[1] - r[0]) * @sin(w * t + phase);
                    shift[dof] = value - m.qpos0[m.jnt_qpos_adr[j]];
                    phase += 1.3;
                },
                .ball => {
                    shift[dof] = 0.6 * @sin(w * t);
                    shift[dof + 1] = 0.3 * @sin(w * t + 1.0);
                    shift[dof + 2] = 0.2 * @sin(w * t + 2.0);
                },
                else => {},
            }
        }
        const out: []f32 = poses[k * m.nq ..][0..m.nq];
        @memcpy(out, m.qpos0);
        rbt.integratePos(m, out, shift, 1.0);
        rbt.normalizeQuats(m, out);
    }
}

test "robot_dance: J3c - the ragdoll's arm against the SAME servo law on the reduced model" {
    // ★★★ SAME LAW, SAME TARGETS, TWO ENGINES. humanoid_flex (all hinges: the ragdoll exists),
    // fixed base, limp as the B rungs make it; the right arm - a 3-hinge shoulder, which the
    // ragdoll turns into ONE swing-twist joint, and a hinge elbow - follows J2's smooth
    // trajectory. Three servos, errors after a 0.5 s transient:
    //   * the RAGDOLL: position motors toward the next frame (no feedforward - it has none);
    //   * the reduced model under the ragdoll's LAW: Tracker toward the next frame as a HELD
    //     target (no feedforward either) - the lag alone, from rest like the ragdoll;
    //   * the reduced model with the full Tracker - the floor.
    // The ragdoll against the same law says whether its joints and motors are consistent (a gap
    // the size of J3a's 10% overshoot) or not (the swing-twist mapping of the shoulder, say).
    const gpa: Allocator = std.testing.allocator;
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex_xml, true, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    rmx.limpReduced(m);
    const names: []const []const u8 = model.imported.names;
    const dt: f32 = m.opt.timestep;
    const frames: usize = 240;
    const skip: usize = 30;
    const shift: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(shift);
    const poses: []f32 = try gpa.alloc(f32, (frames + 2) * m.nq);
    defer gpa.free(poses);
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    var ref: rbt.Data = try rbt.Data.init(gpa, m);
    defer ref.deinit();
    var tracker: Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const a: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(a);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const rots: []Quat = try gpa.alloc(Quat, m.nbody);
    defer gpa.free(rots);
    const frequency: f32 = 20.0;
    var ratio_worst: f32 = 0.0;
    var ratio_slow: f32 = 0.0;
    for ([_]f32{ 0.5, 2.0 }) |hz| {
        try armReference(m, names, hz, frames, shift, poses);
        var mean: [3]f32 = .{ 0, 0, 0 };
        var worst: [3]f32 = .{ 0, 0, 0 };
        for (0..3) |servo| {
            d.reset(m);
            @memcpy(d.pos, poses[m.nq..][0..m.nq]);
            @memset(d.vel, 0.0);
            if (servo == 2) {
                rbt.differentiatePos(m, d.vel, poses[0..m.nq], poses[m.nq..][0..m.nq], dt);
            }
            d.stage = .stale;
            rbt.forward(m, &d);
            var rig: MaximalRig = undefined;
            if (servo == 0) {
                try rig.init(gpa, m, &d, 0.0);
                // The ragdoll matches the pose it was built at (built at rest, then posed - the
                // J3c fix in `rmx.build`).
                for (1..m.nbody) |b| {
                    const q: Quat = rig.ragdoll.robotBodyFrame(&rig.world, b).rot;
                    var rel: Quat = qmul(q, conjugate(d.body_xrot[b]));
                    if (rel[3] < 0.0) {
                        rel = -rel;
                    }
                    try expect(2.0 * acosRad(clamp(rel[3], -1.0, 1.0)) * 180.0 / pi < 0.5);
                }
            }
            defer if (servo == 0) rig.deinit(gpa);
            for (1..frames) |k| {
                const before: []const f32 = poses[(k - 1) * m.nq ..][0..m.nq];
                const now: []const f32 = poses[k * m.nq ..][0..m.nq];
                const next: []const f32 = poses[(k + 1) * m.nq ..][0..m.nq];
                @memcpy(ref.pos, next);
                ref.stage = .stale;
                rbt.forward(m, &ref);
                switch (servo) {
                    0 => try rig.step(m, &ref, frequency, dt),
                    else => {
                        rbt.forward(m, &d);
                        const same_law: [3][]const f32 = .{ next, next, next };
                        const full: [3][]const f32 = .{ before, now, next };
                        const targets: [3][]const f32 = if (servo == 1) same_law else full;
                        tracker.accelerations(m, &d, targets, frequency, dt, a);
                        rbt.biasForce(m, &d);
                        rbt.inverseDynamics(m, &d, a, torque);
                        @memcpy(d.applied_force, torque);
                        rbt.step(m, &d);
                        rbt.forward(m, &d);
                    },
                }
                if (k < skip) {
                    continue;
                }
                if (servo == 0) {
                    rots[0] = ref.body_xrot[0];
                    for (1..m.nbody) |b| {
                        rots[b] = rig.ragdoll.robotBodyFrame(&rig.world, b).rot;
                    }
                } else {
                    @memcpy(rots, d.body_xrot);
                }
                const err: f32 = worstBodyErrorDeg(m, rots, ref.body_xrot);
                worst[servo] = @max(worst[servo], err);
                mean[servo] += err;
            }
            mean[servo] /= float(frames - skip);
        }
        ratio_worst = @max(ratio_worst, mean[0] / @max(mean[1], 1.0e-6));
        if (hz == 0.5) {
            ratio_slow = mean[0] / @max(mean[1], 1.0e-6);
        }
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("\n  J3c humanoid_flex right arm at {d:.1} Hz (mean / worst body deg, after 0.5 s):\n" ++
            "    ragdoll (motors, no feedforward)       {d:>7.3} / {d:>7.3}\n" ++
            "    reduced, the SAME law (no feedforward) {d:>7.3} / {d:>7.3}\n" ++
            "    reduced, the full Tracker              {d:>7.3} / {d:>7.3}\n", .{
            hz, mean[0], worst[0], mean[1], worst[1], mean[2], worst[2],
        });
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  J3c ragdoll / same-law mean error: {d:.2}x at 0.5 Hz, worst over speeds {d:.2}x\n", .{
        ratio_slow,
        ratio_worst,
    });
    // ★ MEASURED, before the fix in `rmx.build`: 83.5 deg mean at BOTH speeds - the elbow driven 84
    // deg off (a ragdoll built away from the rest pose). After: 3.3 deg at 0.5 Hz, 1.5x the same
    // law (the motors' J3a overshoot); 24.7 at 2 Hz, 3x - the soft motor effectively softer than
    // its nominal 20 Hz in a 60 Hz world, a dynamics question for the next rung, not joint math.
    try expect(ratio_slow < 2.0);
}

test "robot_dance: D1 - the right elbow, ranged hinge against ball, on the dance" {
    // THE ELBOW DECISION, KEPT HONEST. flex2's elbows are ranged hinges. A ball would let the IK
    // take the capture's full elbow rotation, twist included, and that sounds like a better fit -
    // so this measures it, on the same dance with the same filter: the model as it is, and the
    // same model with the right elbow swapped for a ball. What a ball could buy shows up in the
    // forearm's DIRECTION against the capture's; what it costs shows up in the audit's jumps. The
    // hinge must keep winning on the forearm, or the decision needs revisiting.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var dance: Dance = undefined;
    Dance.load(gpa, threaded.io(), &dance) catch return error.SkipZigTest;
    defer dance.deinit(gpa);
    const hinge: []const u8 = "<joint name=\"elbow_right\" axis=\"0 -1 1\" class=\"elbow\"/>";
    const ball: []const u8 = "<joint name=\"elbow_right\" type=\"ball\"/>";
    const ball_xml: []u8 = try std.mem.replaceOwned(u8, gpa, flex2_xml, hinge, ball);
    defer gpa.free(ball_xml);
    try expect(!std.mem.eql(u8, ball_xml, flex2_xml));
    var forearm_mean: [2]f32 = .{ 0.0, 0.0 };
    const to_robot: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    const n: usize = dance.capture.joints.len;
    const local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(local);
    const global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(global);
    const points: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(points);
    const Segment = struct { from: []const u8, to: []const u8, body_from: []const u8, body_to: []const u8 };
    const segments = [_]Segment{
        .{ .from = "RightArm", .to = "RightForeArm", .body_from = "upper_arm_right", .body_to = "lower_arm_right" },
        .{ .from = "RightForeArm", .to = "RightHand", .body_from = "lower_arm_right", .body_to = "hand_right" },
    };
    for ([_][]const u8{ flex2_xml, ball_xml }, 0..) |xml, variant| {
        var model: Loaded = undefined;
        try Loaded.load(gpa, &model, xml, false, 1.0 / 60.0);
        defer model.deinit(gpa);
        const m: *rbt.Model = &model.imported.model;
        const names: []const []const u8 = model.imported.names;
        var raw: Clip = try retargetClip(gpa, m, names, &dance.capture, &dance.tpose, .{ .seconds = 10.0 });
        defer raw.deinit();
        var clip: Clip = try raw.smoothed(m, 5.0);
        defer clip.deinit();
        const audit: ClipAudit = auditClip(m, &clip);
        var d: rbt.Data = try rbt.Data.init(gpa, m);
        defer d.deinit();
        var mean: [segments.len]f32 = @splat(0.0);
        var worst: [segments.len]f32 = @splat(0.0);
        for (0..clip.frame_count) |f| {
            @memcpy(d.pos, clip.pose(f));
            d.stage = .stale;
            rbt.kinematics(m, &d);
            globalsAtFrame(&dance.capture, f, local, global, &points[0]);
            bvhPoints(&dance.capture, global, points);
            for (segments, 0..) |seg, s| {
                const a: usize = captureJointNamed(&dance.capture, seg.from) orelse return error.MissingJoint;
                const b: usize = captureJointNamed(&dance.capture, seg.to) orelse return error.MissingJoint;
                const ba: usize = bodyNamed(names, seg.body_from) orelse return error.MissingBody;
                const bb: usize = bodyNamed(names, seg.body_to) orelse return error.MissingBody;
                const want: Vec = normalize3(rotate(to_robot, points[b] - points[a]));
                const got: Vec = normalize3(d.body_xpos[bb] - d.body_xpos[ba]);
                const deg: f32 = acosRad(clamp(dot3(want, got), -1.0, 1.0)) * 180.0 / pi;
                mean[s] += deg / float(clip.frame_count);
                worst[s] = @max(worst[s], deg);
            }
        }
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("\n  D1 right elbow as a {s}: residual mean {d:.3} m, worst {d:.3} m; range excess {d} " ++
            "frames; sign flips {d}; worst jump {d:.3} rad ({s}, frame {d})\n" ++
            "     upper arm direction mean {d:.2} deg, worst {d:.2}; forearm mean {d:.2} deg, worst {d:.2}\n", .{
            if (variant == 0) "HINGE" else "BALL ",
            audit.residual_mean,
            audit.residual_worst,
            audit.range_excess_frames,
            audit.sign_flips,
            audit.jump_worst,
            names[m.jnt_body[audit.jump_worst_joint]],
            audit.jump_worst_frame,
            mean[0],
            worst[0],
            mean[1],
            worst[1],
        });
        forearm_mean[variant] = mean[1];
    }
    // The basis of the decision: the hinge's forearm follows the capture better than a ball's.
    try expect(forearm_mean[0] < forearm_mean[1]);
}

test "robot_dance: the reference set - four clips retargeted onto flex2 and audited" {
    // THE CLIPS WE ARE GOING TO TRACK, checked before anything learns from them: a walk, a run, a
    // dance and a fall-and-get-up (LAFAN1 on Geno, in `assets/lafan1/`), plus the old dance as the
    // baseline the earlier rungs measured. Each is retargeted and filtered exactly as a tracker
    // will see it, then audited: how well the IK did, whether hinges stayed in range, whether any
    // quaternion flipped, the worst single-frame jump - and how deep the reference puts the body
    // through the floor, which only matters once a clip goes to ground, and matters a lot there.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const clips = [_][]const u8{
        "assets/lafan1/walk1_subject2.bvh",
        "assets/lafan1/run1_subject2.bvh",
        "assets/lafan1/dance2_subject2.bvh",
        "assets/lafan1/fallAndGetUp2_subject2.bvh",
    };
    // The stance cut the same way the clips were (fingers dropped), because the rest pose has to be
    // the capture's own skeleton.
    const rest_bytes: []u8 = readFile(gpa, io, "assets/lafan1/Geno_stance.bvh") catch return error.SkipZigTest;
    defer gpa.free(rest_bytes);
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var model: Loaded = undefined;
    try Loaded.load(gpa, &model, flex2_xml, false, 1.0 / 60.0);
    defer model.deinit(gpa);
    const m: *rbt.Model = &model.imported.model;
    const names: []const []const u8 = model.imported.names;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();
    for (clips) |path| {
        const bytes: []u8 = readFile(gpa, io, path) catch return error.SkipZigTest;
        defer gpa.free(bytes);
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
        defer capture.deinit();
        var raw: Clip = try retargetClip(gpa, m, names, &capture, &rest, .{ .seconds = 20.0 });
        defer raw.deinit();
        var clip: Clip = try raw.smoothed(m, 5.0);
        defer clip.deinit();
        const audit: ClipAudit = auditClip(m, &clip);
        var deepest: f32 = 0.0;
        for (0..clip.frame_count) |f| {
            @memcpy(d.pos, clip.pose(f));
            d.stage = .stale;
            rbt.kinematics(m, &d);
            deepest = @min(deepest, lowestBodyPoint(m, &d));
        }
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("\n  {s}: {d} frames; residual mean {d:.3} m, worst {d:.3}; range excess {d}; " ++
            "sign flips {d}; worst jump {d:.3} rad ({s}); deepest below the floor {d:.3} m\n", .{
            std.fs.path.basename(path),
            audit.frames,
            audit.residual_mean,
            audit.residual_worst,
            audit.range_excess_frames,
            audit.sign_flips,
            audit.jump_worst,
            names[m.jnt_body[audit.jump_worst_joint]],
            deepest,
        });
        try expect(audit.range_excess_frames == 0);
        try expect(audit.sign_flips == 0);
        try expect(audit.residual_mean < 0.12);
        try expect(audit.jump_worst < 0.4);
    }
}

test "robot_dance: the get-up reference on the robot - are its feet flat when they are down?" {
    // WHAT THIS MEASURES. The servo and the policy are both asked to follow this clip; nothing can
    // track a pose the robot cannot hold. A foot that is DOWN but TILTED is exactly that: the capture
    // had it flat on the floor, and after retargeting the robot stands on an edge. So, per frame: how
    // low the feet reach, and - when they are down - how far from flat they are.
    //
    // The model's own notes already say the ankle range was widened once for this (its worst frame was
    // 30.3 degrees of foot error, and 11-13 remains on good frames). This says what that leaves in the
    // clip the training page actually uses: the BAKED get-up, lift and all.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var file: std.Io.File = std.Io.Dir.cwd().openFile(io, "examples/getup_train/getup.zclip", .{}) catch
        return error.SkipZigTest;
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    var clip: Clip = try Clip.fromBytes(gpa, bytes);
    defer clip.deinit();

    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, flex2_xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81) };
    options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    var d: rbt.Data = try rbt.Data.init(gpa, m);
    defer d.deinit();

    // A foot is DOWN when its lowest point is within a centimetre of the floor - the clip is lifted so
    // that the deepest point of the whole body just clears it, so this is "carrying weight" in spirit.
    const down_height: f32 = 0.01;
    var down_frames: usize = 0;
    var tilt_sum: f32 = 0.0;
    var tilt_worst: f32 = 0.0;
    var lowest_seen: f32 = 1.0e9;
    var gap_sum: f32 = 0.0;
    var feet_deepest: usize = 0;
    var highest_low: f32 = -1.0e9;
    for (0..clip.frame_count) |frame| {
        @memcpy(d.pos, clip.pose(frame));
        d.stage = .stale;
        rbt.kinematics(m, &d);
        // What is actually deepest on this frame: if it is never a foot, the per-frame lift is
        // raising the whole body off the floor by whatever part IS deepest, and the feet hang.
        const body_low: f32 = lowestBodyPoint(m, &d);
        // A foot is TWO bodies here - the foot and its toe - and the toe is usually the lowest part
        // of it, so a measurement that leaves the toe out says the feet hover when they do not.
        const feet_low: f32 = @min(
            @min(lowestGeomZ(m, &d, imported.names, "foot_left"), lowestGeomZ(m, &d, imported.names, "toe_left")),
            @min(lowestGeomZ(m, &d, imported.names, "foot_right"), lowestGeomZ(m, &d, imported.names, "toe_right")),
        );
        gap_sum += feet_low - body_low;
        if (feet_low - body_low < 0.005) {
            feet_deepest += 1;
        }
        for ([_][2][]const u8{ .{ "foot_left", "toe_left" }, .{ "foot_right", "toe_right" } }) |pair| {
            const foot: []const u8 = pair[0];
            const low: f32 = @min(
                lowestGeomZ(m, &d, imported.names, foot),
                lowestGeomZ(m, &d, imported.names, pair[1]),
            );
            lowest_seen = @min(lowest_seen, low);
            highest_low = @max(highest_low, low);
            if (low > down_height) {
                continue;
            }
            // How far from flat, without assuming which way a foot's own axes point: the line from the
            // foot to ITS TOE lies along the sole, so the angle that line makes with the floor is the
            // angle the sole makes with it. Zero is flat; ninety is standing on the toe.
            const body: usize = bodyNamed(imported.names, foot) orelse continue;
            const toe: usize = bodyNamed(imported.names, pair[1]) orelse continue;
            const along: Vec = d.body_xpos[toe] - d.body_xpos[body];
            const span: f32 = length3(along);
            if (span < 1.0e-6) {
                continue;
            }
            const tilt: f32 = @abs(asinRad(clamp(along[2] / span, -1.0, 1.0))) * deg_per_rad;
            down_frames += 1;
            tilt_sum += tilt;
            tilt_worst = @max(tilt_worst, tilt);
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  get-up reference, {d} frames: feet down on {d} of {d} foot-frames; " ++
        "tilt when down {d:.1} deg on average, {d:.1} worst; lowest foot {d:.3} m, highest low {d:.3} m\n", .{
        clip.frame_count,
        down_frames,
        clip.frame_count * 2,
        if (down_frames == 0) 0.0 else tilt_sum / float(down_frames),
        tilt_worst,
        lowest_seen,
        highest_low,
    });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  the feet are the deepest part on {d} of {d} frames; on average they sit " ++
        "{d:.3} m above whatever is deepest\n", .{
        feet_deepest,
        clip.frame_count,
        gap_sum / float(clip.frame_count),
    });
    try expect(clip.frame_count > 0);
}
