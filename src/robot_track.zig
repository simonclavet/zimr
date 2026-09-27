//! robot_track - what a tracker sees, and how a predicted state moves forward.
//!
//! A tracking controller compares two characters: the SIMULATED one, and the KINEMATIC one the
//! reference clip describes. Both are the same eighteen rigid bodies, and both are described here
//! the same way - by a `State`: where each body is, how it is turned, and how fast it is going,
//! all in world space. That is what the simulator hands us and what a clip turns into.
//!
//! World space is the wrong thing to hand a network, though. A walk at the origin facing north and
//! the same walk twenty metres away facing south are the same motion, and a network fed world
//! coordinates has to learn that twice. So everything a network sees goes through `local`: the
//! same state, expressed in the root's own frame. What survives is the shape of the pose and how
//! it is moving; what disappears is where the character stands and which way it faces.
//!
//! Two things deliberately do NOT disappear, because they are not arbitrary:
//!
//!   * **heights** - how high each body is above the floor, kept in world z. A pose is a different
//!     pose lying down than standing up, and the floor is a real thing at a fixed height.
//!   * **the up vector** - the world's up, written in the root's frame, which says how the
//!     character is tilted. Without it, stripping the root's rotation would throw away the
//!     difference between upright and face-down.
//!
//! So `local` is invariant under a yaw (a turn about the world's up axis) and a horizontal move,
//! and nothing else - which is exactly the set of changes that leave a motion the same motion.
//!
//! Rotations are written as TWO AXES - the first two columns of the rotation matrix, six numbers -
//! rather than as quaternions. A quaternion is a bad thing for a network to predict: q and -q are
//! the same rotation, so the target is discontinuous, and normalising afterwards doesn't remove the
//! jump. Two axes vary smoothly with the rotation and are turned back into one by orthonormalising
//! (Zhou et al., 2019).
//!
//! And `integrate` is the other half: a world model predicts each body's ACCELERATION, and this
//! turns those accelerations into the next state - velocity first, then position, the same
//! semi-implicit order robot.zig steps in. Each body moves on its own here, so the result drifts
//! from what the articulated simulator would do by the usual O(dt^2) of any explicit step; over one
//! frame at 60 Hz that is a millimetre or two, and it is the same drift whether the accelerations
//! come from a network or from the simulator itself.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const rbt = @import("robot.zig");
const dance = @import("robot_dance.zig");
const zimrphysics = @import("zimrphysics.zig");
const robot_physics = @import("robot_physics.zig");
const rmx = @import("robot_maximal.zig");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const splat = zm.splat;
const vec_zero = zm.vec_zero;
const clamp = zm.clamp;
const asinRad = zm.asinRad;
const isFinite = zm.isFinite;
const float = zm.float;
const float64 = zm.float64;
const pi = zm.pi;
const qmul = zm.qmul;
const conjugate = zm.conjugate;
const rotate = zm.rotate;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const qidentity = zm.qidentity;
const cross = zm.cross;
const dot3 = zm.dot3;
const length3 = zm.length3;
const normalize3 = zm.normalize3;
const normalize4 = zm.normalize4;
const quatFromNormAxisAngle = zm.quatFromNormAxisAngle;
const assertf = zm.assertf;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

/// Every body's world pose and velocity: the whole state a tracker cares about.
///
/// Slices are `bodies` long and indexed the way the model indexes bodies, so body 0 is the world
/// and body `root` is the character's root. `positions` are body FRAME origins (not centres of
/// mass) and `velocities` are the velocities of those same points, so the two are consistent -
/// which matters, because a state is differentiated and integrated all over this file.
pub const State = struct {
    positions: []Vec,
    rotations: []Quat,
    velocities: []Vec,
    /// Angular velocities in WORLD axes (robot.zig's `cvel.ang` already is; a body's own frame
    /// would need a rotation, and every formula below wants world).
    angular: []Vec,
    /// Each body's LOWEST POINT above the floor (world z of its collision shapes' lowest point,
    /// `rbt.bodyLowestPoints`) - which body touches the floor, for `TrackingError.unexpected_contact`.
    /// Only `stateOf` knows the geometry, so `init` fills `rbt.no_shape_height`: a state built any other
    /// way (a world model's prediction has frames but no shapes) never reads as touching anything.
    lowest: []f32,

    pub fn init(gpa: Allocator, count: usize) !State {
        const positions: []Vec = try gpa.alloc(Vec, count);
        errdefer gpa.free(positions);
        const rotations: []Quat = try gpa.alloc(Quat, count);
        errdefer gpa.free(rotations);
        const velocities: []Vec = try gpa.alloc(Vec, count);
        errdefer gpa.free(velocities);
        const angular: []Vec = try gpa.alloc(Vec, count);
        errdefer gpa.free(angular);
        const lowest: []f32 = try gpa.alloc(f32, count);
        @memset(lowest, rbt.no_shape_height);
        return .{
            .positions = positions,
            .rotations = rotations,
            .velocities = velocities,
            .angular = angular,
            .lowest = lowest,
        };
    }

    pub fn deinit(self: *State, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.rotations);
        gpa.free(self.velocities);
        gpa.free(self.angular);
        gpa.free(self.lowest);
    }

    pub fn bodies(self: State) usize {
        return self.positions.len;
    }

    pub fn copyFrom(self: *State, other: State) void {
        @memcpy(self.positions, other.positions);
        @memcpy(self.rotations, other.rotations);
        @memcpy(self.velocities, other.velocities);
        @memcpy(self.angular, other.angular);
        @memcpy(self.lowest, other.lowest);
    }
};

/// Read the state out of a forward-current `Data` - the simulator's, or a clip frame's after
/// `rbt.forward`.
/// Which bodies are exempt from `unexpected_contact`: `exempt` names resolved against `body_names` (indexed like the
/// model's bodies). A name that is not a body is an ERROR - a typo in a robot's exempt list would otherwise
/// silently exempt nothing, and its feet would end every stance's swing. The empty name never matches (it is the
/// world's, and every anonymous body's).
pub fn contactExemptMask(
    gpa: Allocator,
    body_count: usize,
    exempt: []const []const u8,
    body_names: []const []const u8,
) ![]bool {
    const mask: []bool = try gpa.alloc(bool, body_count);
    errdefer gpa.free(mask); // a typo returns an error - without leaking the half-built mask
    @memset(mask, false);
    if (exempt.len == 0) {
        return mask;
    }
    assertf(body_names.len == body_count, @src(), "{d} body names for {d} bodies", .{ body_names.len, body_count });
    for (exempt) |wanted| {
        const found: usize = bodyIndexByName(body_names, wanted) orelse return error.UnknownExemptBody;
        mask[found] = true;
    }
    return mask;
}

/// The robot's head (`Task.head_body`) as a body index, or null when the task names none. A name that is not a body is
/// an ERROR - the head rule would otherwise silently judge nothing.
pub fn headBody(head_body: []const u8, body_names: []const []const u8) !?usize {
    if (head_body.len == 0) {
        return null;
    }
    return bodyIndexByName(body_names, head_body) orelse error.UnknownHeadBody;
}

/// A body's index by name. The empty name never matches (it is the world's, and every anonymous body's). One
/// search for every per-robot name a task carries (`contact_exempt`, `head_body`).
fn bodyIndexByName(body_names: []const []const u8, wanted: []const u8) ?usize {
    for (body_names, 0..) |name, b| {
        if (name.len > 0 and std.mem.eql(u8, name, wanted)) {
            return b;
        }
    }
    return null;
}

/// Take the exempt bodies out of contact judgement: their lowest point reads as "no shape", which never touches.
/// Applied to the CHARACTER's state only - the reference's heights stay, for the bodies that are judged.
pub fn exemptFromContact(state: *State, exempt: []const bool) void {
    for (exempt, 0..) |is_exempt, b| {
        if (is_exempt) {
            state.lowest[b] = rbt.no_shape_height;
        }
    }
}

pub fn stateOf(m: *const rbt.Model, d: *const rbt.Data, out: *State) void {
    assertf(out.bodies() == m.nbody, @src(), "state has {d} bodies, model has {d}", .{ out.bodies(), m.nbody });
    for (0..m.nbody) |b| {
        out.positions[b] = d.body_xpos[b];
        out.rotations[b] = d.body_xrot[b];
        out.velocities[b] = dance.pointVelocity(m, d, b, d.body_xpos[b]);
        out.angular[b] = d.cvel[b].ang;
    }
    rbt.bodyLowestPoints(m, d, out.lowest);
}

/// How many numbers `local` writes for a model with `bodies` bodies.
///
/// Per body: 3 position + 6 rotation + 3 velocity + 3 angular + 1 height, and 3 more for the up
/// vector at the end - counted over the CHARACTER's bodies, which is all of them except the world.
/// The world body is not part of the character, and including it would quietly smuggle the
/// character's absolute position back in: the world's origin, seen from the root, is exactly where
/// the character is standing. The root's own position and rotation stay in (always zero and
/// identity) so that every body sits at the same offset, which is worth more than the sixteen
/// numbers it costs once this is being sliced up inside a kernel.
pub fn localSize(bodies: usize) usize {
    return (bodies - 1) * (3 + 6 + 3 + 3 + 1) + 3;
}

/// The state as a network sees it: everything in the root's frame, heights and up kept in world.
///
/// `root` is the character's root body. `out` must be `localSize(bodies)` long.
pub fn local(state: State, root: usize, out: []f32) void {
    assertf(out.len == localSize(state.bodies()), @src(), "local wants {d} numbers, got {d}", .{
        localSize(state.bodies()),
        out.len,
    });
    // Body 0 is the world. Rooting at it would leave every position in world space - the
    // representation would look fine and quietly carry the character's absolute position.
    assertf(root > 0 and root < state.bodies(), @src(), "root body {d} is not a character body", .{root});
    const bodies: usize = state.bodies();
    const to_local: Quat = conjugate(state.rotations[root]);
    const origin: Vec = state.positions[root];
    var at: usize = 0;
    for (1..bodies) |b| {
        writeVec(out, &at, rotate(to_local, state.positions[b] - origin));
    }
    for (1..bodies) |b| {
        writeTwoAxis(out, &at, qmul(to_local, state.rotations[b]));
    }
    for (1..bodies) |b| {
        writeVec(out, &at, rotate(to_local, state.velocities[b]));
    }
    for (1..bodies) |b| {
        writeVec(out, &at, rotate(to_local, state.angular[b]));
    }
    for (1..bodies) |b| {
        out[at] = state.positions[b][2];
        at += 1;
    }
    // The world's up, in the root's frame: everything else here is blind to how the character is
    // tilted, and this is what tells it.
    writeVec(out, &at, rotate(to_local, vec(0, 0, 1)));
}

fn writeVec(out: []f32, at: *usize, v: Vec) void {
    out[at.*] = v[0];
    out[at.* + 1] = v[1];
    out[at.* + 2] = v[2];
    at.* += 3;
}

fn writeTwoAxis(out: []f32, at: *usize, q: Quat) void {
    const axes: [6]f32 = twoAxis(q);
    @memcpy(out[at.*..][0..6], &axes);
    at.* += 6;
}

/// A rotation as two axes: the first two columns of its matrix, which is what a network should
/// predict instead of a quaternion (continuous, and no sign ambiguity).
pub fn twoAxis(q: Quat) [6]f32 {
    const x: Vec = rotate(q, vec(1, 0, 0));
    const y: Vec = rotate(q, vec(0, 1, 0));
    return .{ x[0], x[1], x[2], y[0], y[1], y[2] };
}

/// Two axes back to a rotation. They needn't be unit or perpendicular - whatever a network hands
/// over gets orthonormalised: the first axis is taken as it is, the second is straightened against
/// it, and the third follows from the cross product.
pub fn fromTwoAxis(axes: [6]f32) Quat {
    // Total, on purpose. The axes come from a network, and early in training a network happily
    // outputs two near-zero vectors, or two parallel ones - either of which would divide by zero
    // here and hand NaN to everything downstream, where it is very hard to trace back. So a
    // degenerate axis falls back to a fixed one, which is wrong but finite, and training moves on.
    const first: Vec = vec(axes[0], axes[1], axes[2]);
    const a: Vec = if (length3(first) > 1.0e-6) normalize3(first) else vec(1, 0, 0);
    const raw: Vec = vec(axes[3], axes[4], axes[5]);
    const across: Vec = raw - a * splat(dot3(raw, a));
    const b: Vec = if (length3(across) > 1.0e-6)
        normalize3(across)
    else
        normalize3(orthogonalTo(a));
    const c: Vec = cross(a, b);
    return quatFromColumns(a, b, c);
}

/// Some unit vector perpendicular to `a` - whichever axis `a` leans on least, crossed with it.
fn orthogonalTo(a: Vec) Vec {
    const axis: Vec = if (@abs(a[0]) < 0.9) vec(1, 0, 0) else vec(0, 1, 0);
    return cross(a, axis);
}

/// The quaternion of the rotation whose matrix has these columns. Shepperd's method: build it from
/// whichever diagonal term is largest, so the square root is never taken of something near zero.
fn quatFromColumns(x: Vec, y: Vec, z: Vec) Quat {
    const trace: f32 = x[0] + y[1] + z[2];
    var q: Quat = undefined;
    if (trace > 0.0) {
        const s: f32 = @sqrt(trace + 1.0) * 2.0;
        q = .{ (y[2] - z[1]) / s, (z[0] - x[2]) / s, (x[1] - y[0]) / s, 0.25 * s };
    } else if (x[0] > y[1] and x[0] > z[2]) {
        const s: f32 = @sqrt(1.0 + x[0] - y[1] - z[2]) * 2.0;
        q = .{ 0.25 * s, (y[0] + x[1]) / s, (z[0] + x[2]) / s, (y[2] - z[1]) / s };
    } else if (y[1] > z[2]) {
        const s: f32 = @sqrt(1.0 + y[1] - x[0] - z[2]) * 2.0;
        q = .{ (y[0] + x[1]) / s, 0.25 * s, (z[1] + y[2]) / s, (z[0] - x[2]) / s };
    } else {
        const s: f32 = @sqrt(1.0 + z[2] - x[0] - y[1]) * 2.0;
        q = .{ (z[0] + x[2]) / s, (z[1] + y[2]) / s, 0.25 * s, (x[1] - y[0]) / s };
    }
    return normalize4(q);
}

/// Move a state forward by `dt` under per-body accelerations, in world axes.
///
/// Velocity first, then position with the NEW velocity - the same semi-implicit order robot.zig
/// steps in, so a state predicted this way and a state the simulator produced can be compared
/// frame for frame. Rotations take the angular velocity on the LEFT (`exp(dt w) * q`) because `w`
/// is in world axes; on the right it would mean the body's own frame, and the two differ by the
/// whole rotation.
///
/// Each body moves independently here - nothing holds the joints together - so a long rollout
/// drifts apart. That is expected: the world model is trained to predict accelerations that keep
/// it together over the window it is rolled out for, and nothing longer.
pub fn integrate(state: *State, linear: []const Vec, angular: []const Vec, dt: f32) void {
    // From 1: body 0 is the world, and a world model that nudged it would move the floor.
    for (1..state.bodies()) |b| {
        state.velocities[b] += linear[b] * splat(dt);
        state.angular[b] += angular[b] * splat(dt);
        state.positions[b] += state.velocities[b] * splat(dt);
        state.rotations[b] = normalize4(qmul(rotationOver(state.angular[b], dt), state.rotations[b]));
    }
}

/// The rotation an angular velocity produces over `dt` (exact for a constant `w`).
fn rotationOver(w: Vec, dt: f32) Quat {
    const speed: f32 = length3(w);
    if (speed < 1.0e-12) {
        return .{ 0, 0, 0, 1 };
    }
    return quatFromNormAxisAngle(w / splat(speed), speed * dt);
}

/// The accelerations that carry `from` to `to` over `dt` - the velocity differences, in world axes.
/// This is what a world model is trained to predict, and what the checks below feed to `integrate`.
pub fn accelerationsBetween(
    from: State,
    to: State,
    dt: f32,
    linear: []Vec,
    angular: []Vec,
) void {
    linear[0] = vec_zero;
    angular[0] = vec_zero;
    for (1..from.bodies()) |b| {
        linear[b] = (to.velocities[b] - from.velocities[b]) * splat(1.0 / dt);
        angular[b] = (to.angular[b] - from.angular[b]) * splat(1.0 / dt);
    }
}

/// The character's root body: the one the free joint moves, or the first body below the world when
/// the root is welded. Everything that speaks of "the root's frame" means this body.
pub fn rootBody(m: *const rbt.Model) usize {
    if (m.njnt > 0 and m.jnt_type[0] == .free) {
        return m.jnt_body[0];
    }
    return 1;
}

/// The degrees of freedom the free root owns, which nothing actuates (0 if the model has no free
/// joint - a welded-root copy of the same robot).
pub fn rootDofs(m: *const rbt.Model) usize {
    return if (m.njnt > 0 and m.jnt_type[0] == .free) 6 else 0;
}

/// How many numbers a policy's action has: one per actuated degree of freedom.
///
/// Every joint DOF except the free root's six. For humanoid_flex2 that is 35 - one per hinge,
/// three per ball.
pub fn actionSize(m: *const rbt.Model) usize {
    return m.nv - rootDofs(m);
}

/// SIMON'S FILTER (DReCon's action smoothing): what the policy asked for, blended into what was applied -
/// `applied = beta * asked + (1 - beta) * applied`, in place. 0.2 is DReCon's: a fifth of the new action, four
/// fifths of the old - so no joint's target ever jumps, and the policy must ask for more than it wants to move one
/// quickly. 1 is no filter (`applied` becomes `asked` exactly). ONE definition: `robot_policy.Controller` and the
/// SuperTrack learner (`robot_latent`, whose training graph writes the same blend with tensors) both use it.
pub fn filterAction(beta: f32, asked: []const f32, applied: []f32) void {
    for (applied, asked) |*y, a| {
        y.* = beta * a + (1.0 - beta) * y.*;
    }
}

/// The servo's targets for one step: the reference pose, nudged by the policy's action.
///
/// The action is a DISPLACEMENT IN VELOCITY SPACE, which is why `integratePos` applies it - that
/// is the function that already knows a hinge's offset is an angle added, and a ball's is
/// `exp(a/2)` composed on the RIGHT, in the child's frame where a ball's degrees of freedom live.
/// Getting either of those by hand is how forearms end up twisted. The root's six numbers are left
/// alone: a policy cannot push on the world.
///
/// `scale` is how far one unit of action reaches, in radians - the action itself is expected in
/// [-1, 1], which is what a squashed policy produces. `scratch` is `m.nv` long, and `out` is
/// `m.nq`; `out` may alias `reference`.
pub fn applyAction(
    m: *const rbt.Model,
    reference: []const f32,
    action: []const f32,
    scale: f32,
    scratch: []f32,
    out: []f32,
) void {
    assertf(action.len == actionSize(m), @src(), "action has {d} numbers, model wants {d}", .{
        action.len,
        actionSize(m),
    });
    assertf(scratch.len == m.nv and out.len == m.nq, @src(), "scratch {d} (wants {d}), out {d} (wants {d})", .{
        scratch.len,
        m.nv,
        out.len,
        m.nq,
    });
    const root: usize = rootDofs(m);
    @memset(scratch[0..root], 0.0);
    for (action, root..) |a, k| {
        scratch[k] = scale * a;
    }
    if (out.ptr != reference.ptr) {
        @memcpy(out, reference);
    }
    rbt.integratePos(m, out, scratch, 1.0);
}

/// Put every hinge back inside its range. A reference is already in range, but a reference plus an
/// offset need not be, and a target outside a limit is a servo pushing against a wall forever.
pub fn clampHinges(m: *const rbt.Model, pose: []f32) void {
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge and m.jnt_type[j] != .slide) {
            continue;
        }
        const range: [2]f32 = m.jnt_range[j] orelse continue;
        const at: usize = m.jnt_qpos_adr[j];
        pose[at] = clamp(pose[at], range[0], range[1]);
    }
}

/// What a joint servo is set to: a spring frequency and a damping ratio - the same two knobs the
/// dance's `Tracker` uses, rather than a gain per joint.
pub const Gains = struct {
    frequency: f32 = 20.0,
    damping: f32 = 1.0,
    /// How hard a joint may be driven, as an acceleration in rad/s^2 (or m/s^2 for a slide).
    ///
    /// A spring asked for a large enough error would demand any torque at all, and a policy that
    /// learns to rely on infinite strength learns something no actuator can do. Limiting the
    /// ACCELERATION rather than the torque keeps the limit model-scaled - the same number means the
    /// same thing for a wrist and for a thigh - and it stays exact through the torque conversion,
    /// which a torque clamp would not.
    max_acceleration: f32 = 400.0,
    /// How much of a helping hand the ROOT gets, from 0 (none - the real task) to 1.
    ///
    /// The root of a floating character has no actuator: everything that keeps it up has to come
    /// through the legs and the floor, which is precisely what a policy has not learned yet at the
    /// start. A hard, contact-rich motion like getting up is then barely learnable - the character
    /// falls before anything useful happens. So early in training the root gets a spring toward
    /// the reference like every joint has, realised as an EXTERNAL wrench: inverse dynamics says
    /// what wrench would hold the root on its spring, and a fraction `assist` of it is applied. The
    /// learner fades it to zero on a schedule (residual force control's idea, with the curriculum
    /// that retires it), and a policy is only ever judged at zero.
    assist: f32 = 0.0,
    /// VELOCITY FEEDFORWARD (plan F3): damp each joint toward the reference's velocity over the step
    /// (`referenceVelocity`) instead of toward zero - a servo following MOTION should not brake it
    /// (`pdTorquesToward`). Off: the zero-velocity spring. SuperTrack's paper used the reference's joint
    /// velocities as targets in PhysX and zero in Havok and Bullet, with "final performance reasonably
    /// similar" (sec. 5.1.3) - and F3 measured +1% survival here - so off is the paper-consistent choice.
    velocity_feedforward: bool = false,
};

/// The reference's velocity over frames `f` -> `f + 1` - `rbt.differentiatePos`, the tangent difference
/// `resetToFrame` launches with (a rotation's rate is a quaternion logarithm, not a subtraction). Zero at the
/// clip's end. The velocity a body should END a step with to land on `f + 1`: semi-implicit Euler moves it by its
/// NEW velocity. One definition for every servo (the fleet's, `robot_geno.ServoRun`'s).
pub fn referenceVelocity(
    m: *const rbt.Model,
    clip: *const dance.Clip,
    f: usize,
    out: []f32,
) void {
    if (f + 1 >= clip.frame_count) {
        @memset(out, 0.0);
        return;
    }
    const root_len: usize = clip.nq - m.nq;
    rbt.differentiatePos(m, out, clip.pose(f)[root_len..], clip.pose(f + 1)[root_len..], clip.frame_time);
}

/// The torques that drive the robot toward `target` - the law the policy acts through.
///
/// It is a spring, and a spring alone: no feedforward, no knowledge of where the reference is
/// going next, only "you are here, you should be there". What the policy adds on top of that is
/// the whole point of the offsets.
///
/// Two steps, and the second one matters more than it looks. First, the acceleration a critically
/// damped spring asks for, evaluated at the END of the step (`robot_maximal.stableSpringAccel`)
/// rather than the start, because an explicit spring stiffer than about 8 Hz explodes at 60 Hz and
/// 20 Hz is where a character servo wants to be. Then the torque that actually PRODUCES that
/// acceleration, through the model - inverse dynamics, or its floating-base cousin when the root
/// is free, since a policy cannot push on the world.
///
/// The obvious shortcut - scale the acceleration by the mass matrix's DIAGONAL and call it a PD
/// gain - does not work here, and fails in an interesting way: for a chain, a given torque buys
/// MORE acceleration than the diagonal predicts, so the damping the spring asked to apply
/// implicitly gets applied explicitly and amplified. At 20 Hz with a 60 Hz step that is
/// unconditionally unstable; measured on a walking clip, the robot passes 100 rad/s within twenty
/// frames. A game engine's per-joint PD avoids this with Tan's stable PD, which solves with the
/// mass matrix anyway - so we may as well use the one the simulator already computes.
///
/// `d` must be forward-current with `rbt.biasForce` already called. `scratch` is `m.nv`, `dense`
/// is `m.nv * m.nv`, `full` is `m.nv` (both are only touched when the root is free).
pub fn pdTorques(
    m: *const rbt.Model,
    d: *rbt.Data,
    target: []const f32,
    gains: Gains,
    dt: f32,
    accel_scratch: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    out: []f32,
) void {
    pdTorquesToward(m, d, target, null, gains, dt, accel_scratch, scratch, dense, full, out);
}

/// `pdTorques` with VELOCITY FEEDFORWARD when `target_velocity` is given (`m.nv` long, the velocity the body
/// should END the step with - for a target at clip frame g, the difference g-1 -> g, since semi-implicit
/// Euler moves a body by its new velocity and that is the one that lands exactly on g): each joint's
/// spring damps toward the reference's velocity instead of zero (`rmx.stableSpringAccelToward`). A servo
/// that follows MOTION should not brake it: damping toward zero treats every moving joint as an error. With
/// `null` it is `pdTorques` to the bit - the zero-velocity spring (DReCon's; SuperTrack's paper used target
/// velocities in PhysX and zero elsewhere, with similar results - see `Gains.velocity_feedforward`).
pub fn pdTorquesToward(
    m: *const rbt.Model,
    d: *rbt.Data,
    target: []const f32,
    target_velocity: ?[]const f32,
    gains: Gains,
    dt: f32,
    accel_scratch: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    out: []f32,
) void {
    rbt.differentiatePos(m, scratch, d.pos, target, 1.0);
    const root: usize = rootDofs(m);
    @memset(accel_scratch[0..root], 0.0);
    for (root..m.nv) |k| {
        const want: f32 = if (target_velocity) |moving|
            rmx.stableSpringAccelToward(scratch[k], d.vel[k], moving[k], gains.frequency, gains.damping, dt)
        else
            rmx.stableSpringAccel(scratch[k], d.vel[k], gains.frequency, gains.damping, dt);
        accel_scratch[k] = clamp(want, -gains.max_acceleration, gains.max_acceleration);
    }
    if (root == 0) {
        rbt.inverseDynamics(m, d, accel_scratch, out);
    } else {
        rmx.floatingBaseTorques(m, d, accel_scratch, dense, full, out);
        @memset(out[0..root], 0.0);
        if (gains.assist > 0.0) {
            rootAssist(m, d, gains, dt, scratch, accel_scratch, dense, out);
        }
    }
}

/// The helping hand, when `gains.assist` asks for one: the root's rows of full-body inverse
/// dynamics, `M a + c`, with the root given a spring toward the reference like every joint - the
/// external wrench that would hold it there - scaled by `assist` into `out`'s root rows.
///
/// Only called with assist > 0, so the unassisted path is untouched to the bit. `scratch` holds the
/// velocity-space error toward the target (the root's six entries included), `accel_scratch` the
/// joints' spring accelerations; `dense` is overwritten with the mass matrix.
fn rootAssist(
    m: *const rbt.Model,
    d: *rbt.Data,
    gains: Gains,
    dt: f32,
    scratch: []const f32,
    accel_scratch: []f32,
    dense: []f32,
    out: []f32,
) void {
    const root: usize = rootDofs(m);
    for (0..root) |k| {
        const want: f32 = rmx.stableSpringAccel(scratch[k], d.vel[k], gains.frequency, gains.damping, dt);
        accel_scratch[k] = clamp(want, -gains.max_acceleration, gains.max_acceleration);
    }
    rbt.massMatrixDense(m, d, dense);
    for (0..root) |row| {
        var wrench: f32 = d.bias_force[row];
        for (0..m.nv) |col| {
            wrench += dense[row * m.nv + col] * accel_scratch[col];
        }
        out[row] = gains.assist * wrench;
    }
}

/// How far the simulated character is from the reference, in the eight ways that matter.
///
/// Split deliberately into POSE and PLACE. The pose terms are measured in the root's own frame, so
/// they answer "is the body making the right shape, moving the right way?" without caring where it
/// is. The root terms answer the rest: "and is it in the right place, facing the right way?" A
/// character that made perfect shapes while drifting across the room would score full marks on the
/// first four and fail the last two, which is exactly the distinction a tracking reward needs.
pub const TrackingError = struct {
    /// Mean over bodies of the distance between them, in the root's frame (metres).
    pose_position: f32,
    /// ...and the WORST single body's distance, same measure (metres). The mean hides one limb far off: an arm
    /// pinned under the body is a metre out while the other bodies are fine, and the mean barely moves. MimicKit
    /// ends an episode on exactly this - its worst body - rather than on an average. Root frame, like the mean:
    /// the body being in the wrong PLACE is the root terms' job, this is the body being the wrong SHAPE.
    worst_body: f32,
    /// Mean over bodies of the angle between them, root-relative (radians).
    pose_rotation: f32,
    /// Mean over bodies of the velocity difference, in the root's frame (m/s).
    velocity: f32,
    /// Mean over bodies of the angular velocity difference, in the root's frame (rad/s).
    angular: f32,
    /// How far the root itself is from where the reference puts it (metres, world).
    root_position: f32,
    /// And how far it is from facing the way the reference faces (radians).
    root_rotation: f32,
    /// GRAVITY, which every term above but the root's two is blind to - they measure the pose from the root's
    /// own frame, so a body lying on the floor with the right joint angles matches a standing reference. The
    /// mean over bodies of the difference in HEIGHT above the floor (metres, world z)...
    height: f32,
    /// ...and how far the UP direction, as each root sees it, differs (the distance between two unit vectors,
    /// 0 to 2): tilt against gravity, what SuperTrack's L_up measures.
    up: f32,
    /// UNEXPECTED CONTACT (metres): of the bodies the character has ON the floor (lowest point within
    /// `contact_band`), the highest the REFERENCE holds its counterpart - 0 when nothing unexpected touches.
    /// A knee down while the reference stands reads the reference knee's height (~0.45 m on Geno); the get-up's
    /// hands and knees on the floor read 0, because the reference's are down too. MimicKit's fastest fall signal
    /// is contact, but through a list of bodies allowed to touch PER MOTION; measured against the reference it
    /// needs no list - only the bodies a robot always stands on are exempt (`Task.contact_exempt`).
    /// Needs `State.lowest` (filled by `stateOf`); a state without geometry never touches, so this reads 0.
    unexpected_contact: f32,
    /// The HEAD's height off the reference head's (metres, world z) - SuperTrack's whole failure rule: an episode
    /// ends when this passes 25 cm (plan F3b). 0 when no head was given (`trackingError`); a judge names the head
    /// per robot (`Task.head_body`) and asks `trackingErrorWithHead`.
    head_height: f32,
};

/// How close to the floor a body's lowest point must be to count as touching it (metres). Resting contact
/// sits within a few millimetres (Geno's soles 4.5 mm into the floor when copied from a capture); a body a
/// centimetre up is clearly not bearing on it.
pub const contact_band: f32 = 0.01;

/// Measure one against the other. Both states are whole-body states in world space (`stateOf`);
/// `root` is the character's root body.
pub fn trackingError(sim: State, reference: State, root: usize) TrackingError {
    return trackingErrorWithHead(sim, reference, root, null);
}

/// `trackingError` with the head's height gap measured too (`TrackingError.head_height`) - what a judge asks, having
/// resolved the robot's head (`Task.head_body`). One implementation: `trackingError` is this with no head.
pub fn trackingErrorWithHead(
    sim: State,
    reference: State,
    root: usize,
    head: ?usize,
) TrackingError {
    const bodies: usize = sim.bodies();
    assertf(bodies > 1 and reference.bodies() == bodies, @src(), "{d} bodies against {d}", .{
        bodies,
        reference.bodies(),
    });
    const to_local: Quat = conjugate(sim.rotations[root]);
    const to_local_ref: Quat = conjugate(reference.rotations[root]);
    var out: TrackingError = .{
        .pose_position = 0.0,
        .worst_body = 0.0,
        .pose_rotation = 0.0,
        .velocity = 0.0,
        .angular = 0.0,
        .root_position = length3(sim.positions[root] - reference.positions[root]),
        .root_rotation = angleBetween(sim.rotations[root], reference.rotations[root]),
        .height = 0.0,
        .up = length3(rotate(to_local, vec(0.0, 0.0, 1.0)) - rotate(to_local_ref, vec(0.0, 0.0, 1.0))),
        .unexpected_contact = 0.0,
        .head_height = if (head) |h| @abs(sim.positions[h][2] - reference.positions[h][2]) else 0.0,
    };
    // Body 0 is the world, and the root's own pose terms are zero by construction; both are still
    // counted so the mean is over the same number of bodies every time, which keeps a reward
    // comparable between models.
    const count: f32 = float(bodies - 1);
    for (1..bodies) |b| {
        const p: Vec = rotate(to_local, sim.positions[b] - sim.positions[root]);
        const p_ref: Vec = rotate(to_local_ref, reference.positions[b] - reference.positions[root]);
        const r: Quat = qmul(to_local, sim.rotations[b]);
        const r_ref: Quat = qmul(to_local_ref, reference.rotations[b]);
        const v: Vec = rotate(to_local, sim.velocities[b]);
        const v_ref: Vec = rotate(to_local_ref, reference.velocities[b]);
        const w: Vec = rotate(to_local, sim.angular[b]);
        const w_ref: Vec = rotate(to_local_ref, reference.angular[b]);
        const body_distance: f32 = length3(p - p_ref);
        out.pose_position += body_distance / count;
        out.worst_body = @max(out.worst_body, body_distance);
        out.height += @abs(sim.positions[b][2] - reference.positions[b][2]) / count;
        out.pose_rotation += angleBetween(r, r_ref) / count;
        out.velocity += length3(v - v_ref) / count;
        out.angular += length3(w - w_ref) / count;
        // A body down that the reference holds up. An unknown reference height (no geometry) cannot accuse
        // anything, so it is skipped rather than read as "very high".
        const touching: bool = sim.lowest[b] < contact_band;
        const reference_known: bool = reference.lowest[b] < rbt.no_shape_height;
        if (touching and reference_known) {
            out.unexpected_contact = @max(out.unexpected_contact, reference.lowest[b]);
        }
    }
    return out;
}

/// The angle between two rotations, taken from the vector part of their difference so that small
/// angles stay accurate in f32 (`acos` of a w near 1 loses half its digits).
fn angleBetween(a: Quat, b: Quat) f32 {
    var rel: Quat = qmul(a, conjugate(b));
    if (rel[3] < 0.0) {
        rel = -rel;
    }
    return 2.0 * asinRad(@min(1.0, length3(vec(rel[0], rel[1], rel[2]))));
}

/// What each part of being wrong costs. Every term is `weight * exp(-error / scale)`, so a term at
/// its scale is worth about a third of its weight, and the whole reward lands in [0, 1] when the
/// weights sum to one.
///
/// A weighted SUM rather than a product, because a product means any single term near zero throws
/// the whole reward away - which is right for a controller that must never fail a term, and wrong
/// for a learner that has to be told which way is better while it is still bad at everything.
pub const RewardWeights = struct {
    pose_position: f32 = 0.3,
    pose_position_scale: f32 = 0.1,
    pose_rotation: f32 = 0.3,
    pose_rotation_scale: f32 = 0.25,
    velocity: f32 = 0.1,
    velocity_scale: f32 = 1.0,
    angular: f32 = 0.1,
    angular_scale: f32 = 5.0,
    root_position: f32 = 0.1,
    root_position_scale: f32 = 0.15,
    root_rotation: f32 = 0.1,
    root_rotation_scale: f32 = 0.3,
    /// THE GRAVITY GATE (Sep 26). The terms above add up, and 80% of them measure the pose from the root's own
    /// frame - so a body lying on the floor with the right joint angles earns about 0.8 while its reference
    /// stands. SuperTrack's reward is ONE exponential of every loss, heights and up included, so any large loss
    /// sinks all of it; here that becomes a gate: when set, the whole reward is multiplied by
    /// exp(-height / height_scale) and exp(-up / up_scale). Perfect tracking still earns exactly 1. Zero - the
    /// default - leaves the reward exactly as it was.
    height_scale: f32 = 0.0,
    up_scale: f32 = 0.0,
};

/// The reward for one step: 1 when the characters coincide, falling smoothly from there.
pub fn reward(err: TrackingError, w: RewardWeights) f32 {
    var total: f32 = w.pose_position * @exp(-err.pose_position / w.pose_position_scale) +
        w.pose_rotation * @exp(-err.pose_rotation / w.pose_rotation_scale) +
        w.velocity * @exp(-err.velocity / w.velocity_scale) +
        w.angular * @exp(-err.angular / w.angular_scale) +
        w.root_position * @exp(-err.root_position / w.root_position_scale) +
        w.root_rotation * @exp(-err.root_rotation / w.root_rotation_scale);
    if (w.height_scale > 0.0) {
        total *= @exp(-err.height / w.height_scale);
    }
    if (w.up_scale > 0.0) {
        total *= @exp(-err.up / w.up_scale);
    }
    return total;
}

/// When to give up on an episode.
///
/// By tracking error, and by nothing else. The obvious test - "has the head dropped below some
/// height?" - is wrong for this set of clips: the get-up spends ten seconds lying on the floor, and
/// a height test would call the best possible tracking a failure. Losing the reference is the only
/// failure there is.
pub const Termination = struct {
    pose_position: f32 = 0.35,
    pose_rotation: f32 = 1.2,
    root_position: f32 = 0.6,
    root_rotation: f32 = 1.5,
    /// The reference is also lost when the bodies' mean HEIGHT differs from its by more than this (metres) -
    /// RELATIVE to the reference, so the get-up's ten seconds on the floor are fine while the reference lies
    /// there too: SuperTrack's rule (the head 25 cm off the reference's), over every body. Off by default.
    height: f32 = 1.0e30,
    /// ...and when the body's TILT against gravity differs from the reference's by more than this (the up
    /// vectors' distance, each in its own root's frame: 0.8 is ~47 degrees) - falling over, whatever the
    /// heading. Off by default.
    up: f32 = 1.0e30,
    /// ...and when any ONE body is further than this from its reference counterpart, in the root's frame (metres)
    /// - the limb the mean cannot see (`TrackingError.worst_body`). Off by default.
    worst_body: f32 = 1.0e30,
    /// ...and when a body touches the floor while the reference holds it higher than this (metres) - a knee, a
    /// hand, the hips going down where the reference's are not (`TrackingError.unexpected_contact`). Off by
    /// default.
    unexpected_contact: f32 = 1.0e30,
    /// ...and when the HEAD's height is further than this from the reference head's (metres) - SuperTrack's rule
    /// (25 cm), clip-agnostic and relative, so a get-up's floor is fine while the reference lies there too
    /// (`TrackingError.head_height`; the head resolved from `Task.head_body`). Off by default.
    head_height: f32 = 1.0e30,

    /// Steps after a reset during which losing the reference does not end the episode. A policy bad enough
    /// to fail within a training window's length leaves NO window in its data - training then stops for
    /// good, and the bad policy never improves (seen on the phone: updates frozen, 0.1 s to failure). A
    /// grace of the window's length guarantees every episode one. 0 for the old robot's fleets.
    grace_steps: u32 = 0,

    // ==== THE STRUCT IS THE LIST ====
    //
    // Every limit here is an `f32` named EXACTLY like the `TrackingError` field it limits, and `scaled`,
    // `terminated` and the tests walk the fields instead of naming them. So adding a limit is adding it HERE and
    // the error it limits THERE - nothing else. Lists written out by hand drifted twice: geno_train's leash
    // dropped the tilt limit when `up` was added (Sep 26), and `scaled` / `terminated` each had to be edited for
    // every new limit. The comptime check below turns a limit with no matching error into a compile error that
    // says so, instead of an `@field` error somewhere else.
    comptime {
        const info = @typeInfo(Termination).@"struct";
        for (info.field_names, info.field_types) |name, field_type| {
            if (field_type == f32 and !@hasField(TrackingError, name)) {
                @compileError("Termination." ++ name ++ " limits nothing: TrackingError has no field of that name");
            }
        }
    }

    /// Every limit scaled by `fraction` (the grace kept) - a looser leash (> 1) or an early warning (< 1).
    pub fn scaled(self: Termination, fraction: f32) Termination {
        var out: Termination = self;
        const info = @typeInfo(Termination).@"struct";
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (field_type == f32) {
                @field(out, name) *= fraction;
            }
        }
        return out;
    }
};

/// Has the reference been lost? True when ANY error exceeds its limit - each `Termination` field against the
/// `TrackingError` field of the same name (see "THE STRUCT IS THE LIST" in `Termination`).
pub fn terminated(err: TrackingError, limits: Termination) bool {
    const info = @typeInfo(Termination).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (field_type == f32 and @field(err, name) > @field(limits, name)) {
            return true;
        }
    }
    return false;
}

/// Put the simulation exactly on the clip at `frame` - the pose, and the velocity the clip has
/// there.
///
/// This is reference-state initialisation: episodes start at a random frame rather than always at
/// the beginning, so a learner sees the middle of a run and the middle of a fall as often as it
/// sees a standing start, instead of having to survive everything before them first. The velocity
/// is the backward difference into `frame`, which is the velocity the discrete trajectory actually
/// has there (the same argument as the servo's) - so frame 0 starts at frame 1 instead, there being
/// nothing before it to difference against.
/// PERTURBED STARTS (D5.5 - DReCon randomised its starts, Simon's ask): how far an episode's first state is pushed
/// off the reference. Zero is the reference itself.
pub const StartNoise = struct {
    /// Radians: every non-root joint turned by a random rotation vector, this spread per axis.
    pose: f32 = 0.0,
    /// m/s: a kick to the root, this spread per horizontal axis (a random direction and size).
    velocity: f32 = 0.0,
};

/// Push a state off its reference by `noise`, then rest it on the floor again - a perturbed pose must not start
/// inside the ground. The pose goes through the model's own `integratePos` (the path `applyAction` turns offsets
/// by); the kick lands on the root's linear velocity, x and y (z is up). With no noise it does nothing at all and
/// draws no random numbers, so a fleet without noise behaves bit for bit as before. `scratch`: at least nv long.
pub fn perturbStart(
    m: *const rbt.Model,
    d: *rbt.Data,
    noise: StartNoise,
    random: std.Random,
    scratch: []f32,
) void {
    if (noise.pose == 0.0 and noise.velocity == 0.0) {
        return;
    }
    const turns: []f32 = scratch[0..m.nv];
    @memset(turns, 0.0);
    if (noise.pose > 0.0) {
        for (turns[rootDofs(m)..]) |*turn| {
            turn.* = noise.pose * random.floatNorm(f32);
        }
        rbt.integratePos(m, d.pos, turns, 1.0);
    }
    if (noise.velocity > 0.0) {
        d.vel[0] += noise.velocity * random.floatNorm(f32);
        d.vel[1] += noise.velocity * random.floatNorm(f32);
    }
    _ = rbt.restOnFloor(m, d, 0.001);
    rbt.forward(m, d);
}

/// How an episode ended: its reference LOST (a failure - no future), the step CAP reached, or its CLIP ran
/// out (both cut short - a future the episode would have had).
pub const End = enum { lost, cap, clip_end };

pub fn resetToFrame(
    m: *const rbt.Model,
    d: *rbt.Data,
    clip: *const dance.Clip,
    frame: usize,
) void {
    const at: usize = @max(frame, 1);
    const root_len: usize = clip.nq - m.nq;
    d.reset(m);
    @memcpy(d.pos, clip.pose(at)[root_len..]);
    rbt.differentiatePos(m, d.vel, clip.pose(at - 1)[root_len..], clip.pose(at)[root_len..], clip.frame_time);
    d.stage = .stale;
    rbt.forward(m, d);
}

/// Experience, kept per environment in a ring: what the simulator was, what was done to it, and
/// which stretch of unbroken motion it belongs to.
///
/// What goes in is the simulator's OWN state - a pose and a velocity - rather than the body-space
/// features a network eventually sees. Two reasons: it is half the memory, and it cannot disagree
/// with the model, because forward kinematics reconstructs the rest on the way out. What a learner
/// wants is windows: eight frames for a world model, thirty-two for a policy, and every frame in
/// one has to follow from the one before it.
///
/// Which is what `segment` is for. It changes at every reset and at every shove - anywhere the
/// motion was interrupted by something no model could have predicted from the state - and
/// `sampleWindow` only ever returns frames that share one. Without that a world model spends part
/// of its capacity trying to predict teleports, and a policy trains through them.
pub const Replay = struct {
    gpa: Allocator,
    envs: usize,
    capacity: usize,
    nq: usize,
    nv: usize,
    action_size: usize,
    poses: []f32,
    velocities: []f32,
    actions: []f32,
    /// The reference frame each record was tracking, so the target can be looked up again - and
    /// WHICH CLIP that frame belongs to, because a ring outlives episodes and an environment picks
    /// a new clip every time it restarts. Without it, a window older than the last restart would be
    /// rebuilt against whatever clip the environment happens to be on now.
    frames: []u32,
    clips: []u16,
    segments: []u32,
    /// How many records this environment has ever written. The ring holds the last `capacity`.
    written: []u64,

    pub fn init(
        gpa: Allocator,
        m: *const rbt.Model,
        envs: usize,
        capacity: usize,
    ) !Replay {
        assertf(envs > 0 and capacity > 1, @src(), "{d} environments of {d} records makes no ring", .{
            envs,
            capacity,
        });
        const slots: usize = envs * capacity;
        const action_size: usize = actionSize(m);
        const poses: []f32 = try gpa.alloc(f32, slots * m.nq);
        errdefer gpa.free(poses);
        const velocities: []f32 = try gpa.alloc(f32, slots * m.nv);
        errdefer gpa.free(velocities);
        const actions: []f32 = try gpa.alloc(f32, slots * action_size);
        errdefer gpa.free(actions);
        const frames: []u32 = try gpa.alloc(u32, slots);
        errdefer gpa.free(frames);
        const clips: []u16 = try gpa.alloc(u16, slots);
        errdefer gpa.free(clips);
        const segments: []u32 = try gpa.alloc(u32, slots);
        errdefer gpa.free(segments);
        const written: []u64 = try gpa.alloc(u64, envs);
        @memset(written, 0);
        return .{
            .gpa = gpa,
            .envs = envs,
            .capacity = capacity,
            .nq = m.nq,
            .nv = m.nv,
            .action_size = action_size,
            .poses = poses,
            .velocities = velocities,
            .actions = actions,
            .frames = frames,
            .clips = clips,
            .segments = segments,
            .written = written,
        };
    }

    pub fn deinit(self: *Replay) void {
        self.gpa.free(self.poses);
        self.gpa.free(self.velocities);
        self.gpa.free(self.actions);
        self.gpa.free(self.frames);
        self.gpa.free(self.clips);
        self.gpa.free(self.segments);
        self.gpa.free(self.written);
    }

    fn slot(self: Replay, env: usize, index: u64) usize {
        return env * self.capacity + @as(usize, @intCast(index % self.capacity));
    }

    /// Append one frame of experience for `env`: the state it was in, the action taken from it, the
    /// reference frame it was tracking, and the segment it belongs to.
    pub fn append(
        self: *Replay,
        env: usize,
        pose: []const f32,
        velocity: []const f32,
        action: []const f32,
        frame: u32,
        clip: u16,
        segment: u32,
    ) void {
        assertf(
            env < self.envs and pose.len == self.nq and velocity.len == self.nv and action.len == self.action_size,
            @src(),
            "env {d} of {d}, pose {d}/{d}, velocity {d}/{d}, action {d}/{d}",
            .{ env, self.envs, pose.len, self.nq, velocity.len, self.nv, action.len, self.action_size },
        );
        const at: usize = self.slot(env, self.written[env]);
        @memcpy(self.poses[at * self.nq ..][0..self.nq], pose);
        @memcpy(self.velocities[at * self.nv ..][0..self.nv], velocity);
        @memcpy(self.actions[at * self.action_size ..][0..self.action_size], action);
        self.frames[at] = frame;
        self.clips[at] = clip;
        self.segments[at] = segment;
        self.written[env] += 1;
    }

    pub fn poseAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.poses[self.slot(env, index) * self.nq ..][0..self.nq];
    }

    pub fn velocityAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.velocities[self.slot(env, index) * self.nv ..][0..self.nv];
    }

    pub fn actionAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.actions[self.slot(env, index) * self.action_size ..][0..self.action_size];
    }

    pub fn frameAt(self: Replay, env: usize, index: u64) u32 {
        return self.frames[self.slot(env, index)];
    }

    /// Which clip that frame belongs to.
    pub fn clipAt(self: Replay, env: usize, index: u64) u16 {
        return self.clips[self.slot(env, index)];
    }

    pub fn segmentAt(self: Replay, env: usize, index: u64) u32 {
        return self.segments[self.slot(env, index)];
    }

    /// A stretch of unbroken motion from one environment: `steps` transitions, which is `steps + 1`
    /// records, all in one segment.
    ///
    /// Counted in TRANSITIONS on purpose. A world model rolled out for eight steps needs nine
    /// states to compare against, and "an eight-frame window" is the kind of phrase that quietly
    /// becomes seven steps somewhere between the plan and the kernel.
    pub const Window = struct {
        env: usize,
        first: u64,
        steps: usize,

        /// The records the window spans: one more than its transitions.
        pub fn frames(self: Window) usize {
            return self.steps + 1;
        }
    };

    /// Draw one, or null if nothing long enough has been recorded yet.
    ///
    /// The candidate is a start that is still IN the ring (not yet overwritten) with `steps + 1`
    /// records after it; it is accepted when the first and last share a segment - which is enough,
    /// since a segment id only ever increases, so equal ends mean an equal middle. A few dozen
    /// tries are plenty: segments are long compared with a window, and a ring full of short
    /// segments deserves to fail rather than to loop.
    pub fn sampleWindow(self: Replay, random: std.Random, steps: usize) ?Window {
        assertf(steps > 0, @src(), "a window of no transitions is not a window", .{});
        const frames: usize = steps + 1;
        for (0..64) |_| {
            const env: usize = random.uintLessThan(usize, self.envs);
            const written: u64 = self.written[env];
            if (written < frames) {
                continue;
            }
            const oldest: u64 = written -| @as(u64, @intCast(self.capacity));
            const newest_start: u64 = written - frames;
            if (newest_start < oldest) {
                continue;
            }
            const first: u64 = oldest + random.uintLessThan(u64, newest_start - oldest + 1);
            if (self.segmentAt(env, first) != self.segmentAt(env, first + frames - 1)) {
                continue;
            }
            return .{ .env = env, .first = first, .steps = steps };
        }
        return null;
    }
};

/// How many numbers a policy sees: the simulated character and the reference it is chasing, both in
/// the root's frame (section  `local`).
pub fn observationSize(m: *const rbt.Model) usize {
    return 2 * localSize(m.nbody);
}

/// The TASK a fleet trains and judges: everything that decides what the character is asked to do and when it
/// has failed - its servo, the floor, how every episode starts, the reward and the failure rule. One value, so a
/// robot's task is defined ONCE (`robot_geno.tracking_task` for Geno) and handed whole to every fleet and trainer
/// that trains or judges it: spelled out field by field at each call site, it drifted (plan T1).
///
/// NOT part of it: the action scale (each learner has its own - DReCon's student and SuperTrack differ), the
/// sizes, the episode cap and the seed. Those are how a run is set up, not what the character is asked to do.
///
/// The defaults are the OLD robot's, whose tests pin its exact behaviour.
pub const Task = struct {
    gains: Gains = .{},
    /// The floor's friction (a contact's is the geometric mean with the robot's shapes'). The old robot's 0.7;
    /// Geno's feet skate at that under its servo, and use `robot_geno.floor_friction`.
    floor_friction: f32 = 0.7,
    /// Rest every reset ON the floor (`rbt.restOnFloor`, 1 mm clear): a pose copied from a capture sinks its feet
    /// into the simulated floor, and the solver kicks the body out of it on the first step - at every episode
    /// start. Off for the old robot; Geno's task sets it.
    rest_on_floor: bool = false,
    weights: RewardWeights = .{},
    termination: Termination = .{},
    /// Bodies whose floor contact is never UNEXPECTED (`TrackingError.unexpected_contact`): the ones the robot
    /// stands on. A foot is down through every stance while the reference lifts it into each swing, and a
    /// character a few frames behind still has it down - that is lag, not a fall. Named per ROBOT, never per
    /// motion; a fleet resolves them through `Fleet.Options.body_names`. Empty by default.
    contact_exempt: []const []const u8 = &.{},
    /// The body that is the robot's HEAD, for `TrackingError.head_height` (SuperTrack's failure rule, plan F3b).
    /// Named per robot, resolved like `contact_exempt`. Empty: no head term.
    head_body: []const u8 = "",
};

/// A fleet of characters tracking clips, stepping together and filling a `Replay`.
///
/// The loop per character per frame: take an action, turn it into PD targets on the reference
/// (`applyAction`), drive the servo (`pdTorques`), step, record, and look at the result - if the
/// reference has been lost, start a new episode somewhere else in a clip; every so often, shove it.
/// Resets and shoves both begin a new segment.
///
/// Actions come from outside, in one flat array for the whole fleet, because that is the shape the
/// GPU version wants and there is no reason to learn a different one here: `observe`, then act,
/// then `step`.
pub const Fleet = struct {
    pub const Options = struct {
        envs: usize = 16,
        capacity: usize = 1024,
        /// How far one unit of action reaches, in radians. The LEARNER's (see `Task` for why it is not the task's).
        action_scale: f32 = 0.2,
        /// What the characters are asked to do and when they have failed - see `Task`.
        task: Task = .{},
        /// The model's body names, indexed like its bodies (`robot_mjcf.Imported.names`) - needed only to resolve
        /// `task.contact_exempt`, which names bodies; a task that exempts nothing needs none.
        body_names: []const []const u8 = &.{},
        /// Every reset pushed off the reference (`perturbStart`) - D5.5's perturbed starts. None by default.
        start_noise: StartNoise = .{},
        /// Frames between shoves (0 never shoves). A shove is an impulse on the root, which is what
        /// "small perturbations" means when it is time to measure robustness.
        shove_every: u32 = 0,
        /// How hard, as a velocity added to the root, in m/s.
        shove_speed: f32 = 0.6,
        /// Episodes end here even when tracking is fine, so no environment sits in one stretch of
        /// clip forever.
        max_steps: u32 = 600,
        seed: u64 = 1,
    };

    gpa: Allocator,
    /// Everything the fleet owns comes from here, and goes back in one call. A dozen buffers
    /// allocated one at a time is a dozen chances to leak the previous eleven when the thirteenth
    /// fails; an arena has one.
    arena: std.heap.ArenaAllocator,
    m: *rbt.Model,
    /// The clips themselves are BORROWED - they must outlive the fleet, and they are read every
    /// step - but the list of them is COPIED into the fleet's own memory. A caller naturally builds
    /// that list as a little local array (`&.{&clip}`), and a fleet that kept the caller's slice
    /// would be holding a pointer into a stack frame that is gone the moment the caller returns.
    /// The first phone page did exactly that, and read garbage for its clips on the first step.
    clips: []const *const dance.Clip,
    /// The character's root body, from the model rather than from an assumption about index 1.
    root: usize,
    options: Options,
    data: []rbt.Data,
    /// A collision world and a bridge PER ENVIRONMENT. In this engine the articulated-body
    /// dynamics (`robot`) and collision (`zimrphysics`) are separate things joined by a bridge:
    /// poses go out, contacts come back. A model with a floor geom in its text collides with
    /// nothing until somebody does that - which is how a fleet can run for thousands of frames in
    /// mid-air and look busy the whole time.
    worlds: []zimrphysics.World,
    bridges: []robot_physics.Bridge,
    clip_of: []usize,
    frame: []u32,
    segment: []u32,
    steps: []u32,
    next_segment: u32,
    rng: std.Random.DefaultPrng,
    replay: Replay,
    /// Per-environment scratch, allocated once.
    reference_data: rbt.Data,
    sim_state: State,
    reference_state: State,
    /// Per body: exempt from `unexpected_contact` (`Task.contact_exempt`, resolved at init).
    contact_exempt: []bool,
    /// The head's body index (`Task.head_body`, resolved at init), or null: no head term.
    head: ?usize,
    targets: []f32,
    /// The reference's velocity over the step, for the servo's feedforward (`Gains.velocity_feedforward`).
    target_velocity: []f32,
    accel: []f32,
    torque: []f32,
    scratch: []f32,
    full: []f32,
    dense: []f32,
    /// Each environment's reward on the last step, and whether its episode ended there - which a
    /// learner needs per environment, not averaged: an advantage is about one trajectory.
    rewards: []f32,
    dones: []bool,
    /// Of those endings, which were FAILURES - the reference lost - rather than the clip running out
    /// or the episode cap arriving. The difference is the whole of how a tracker is judged: running
    /// out of clip while still with the reference is success, and counting it as an ending shortens
    /// every episode to whatever was left of the clip when it started.
    failures: []bool,
    /// WHY each ending happened (valid where `dones` is set), and the state it ended IN - captured before
    /// the restart replaces it. A learner needs both: an episode that was LOST has no future, but one CUT
    /// SHORT - by the step cap, or a clip running out - does, and its value is the critic's value of the
    /// state it ended in, not of the fresh start that took its place (MimicKit bootstraps its timeouts
    /// exactly so; ours treated every end as a death until Sep 26).
    ends: []End,
    terminal: []State,
    terminal_frame: []u32,
    terminal_clip: []usize,
    /// Every failure since the fleet was made, beside `episodes`, which counts every ending.
    failed: u64 = 0,
    /// The last step's reward and how many episodes have ended, for whoever is watching.
    last_reward: f32 = 0.0,
    episodes: u64 = 0,
    steps_total: u64 = 0,

    pub fn init(
        gpa: Allocator,
        m: *rbt.Model,
        clips: []const *const dance.Clip,
        options: Options,
    ) !*Fleet {
        assertf(clips.len > 0 and clips.len <= 0xffff, @src(), "{d} clips", .{clips.len});
        for (clips) |clip| {
            // The servo is driven at the clip's frame time and the simulator steps at the model's:
            // one step per frame is what makes a reference and a simulation the same trajectory,
            // and a clip at another rate would quietly servo at the wrong one.
            assertf(
                @abs(clip.frame_time - m.opt.timestep) < 1.0e-6,
                @src(),
                "clip runs at {d} s a frame, the model steps at {d}",
                .{ clip.frame_time, m.opt.timestep },
            );
            assertf(clip.nq == m.nq, @src(), "clip poses are {d} long, the model wants {d}", .{ clip.nq, m.nq });
            assertf(clip.frame_count > 2, @src(), "a clip of {d} frames is too short to start in", .{clip.frame_count});
        }
        const fleet: *Fleet = try gpa.create(Fleet);
        errdefer gpa.destroy(fleet);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        fleet.* = .{
            .gpa = undefined,
            .arena = undefined,
            .m = undefined,
            .clips = undefined,
            .root = undefined,
            .options = undefined,
            .data = undefined,
            .worlds = undefined,
            .bridges = undefined,
            .clip_of = undefined,
            .frame = undefined,
            .segment = undefined,
            .steps = undefined,
            .next_segment = undefined,
            .rng = undefined,
            .replay = undefined,
            .reference_data = undefined,
            .sim_state = undefined,
            .reference_state = undefined,
            .contact_exempt = undefined,
            .head = undefined,
            .targets = undefined,
            .target_velocity = undefined,
            .accel = undefined,
            .torque = undefined,
            .scratch = undefined,
            .full = undefined,
            .dense = undefined,
            .rewards = undefined,
            .dones = undefined,
            .failures = undefined,
            .ends = undefined,
            .terminal = undefined,
            .terminal_frame = undefined,
            .terminal_clip = undefined,
        };
        fleet.arena = .init(gpa);
        errdefer fleet.arena.deinit();
        const owned: Allocator = fleet.arena.allocator();
        fleet.* = .{
            .gpa = gpa,
            .arena = fleet.arena,
            .m = m,
            .clips = try owned.dupe(*const dance.Clip, clips),
            .root = rootBody(m),
            .options = options,
            .data = try owned.alloc(rbt.Data, options.envs),
            .worlds = try owned.alloc(zimrphysics.World, options.envs),
            .bridges = try owned.alloc(robot_physics.Bridge, options.envs),
            .clip_of = try owned.alloc(usize, options.envs),
            .frame = try owned.alloc(u32, options.envs),
            .segment = try owned.alloc(u32, options.envs),
            .steps = try owned.alloc(u32, options.envs),
            .rewards = try owned.alloc(f32, options.envs),
            .dones = try owned.alloc(bool, options.envs),
            .failures = try owned.alloc(bool, options.envs),
            .ends = try owned.alloc(End, options.envs),
            .terminal = try owned.alloc(State, options.envs),
            .terminal_frame = try owned.alloc(u32, options.envs),
            .terminal_clip = try owned.alloc(usize, options.envs),
            .next_segment = 0,
            .rng = .init(options.seed),
            .replay = try .init(owned, m, options.envs, options.capacity),
            .reference_data = try rbt.Data.init(owned, m),
            .sim_state = try State.init(owned, m.nbody),
            .reference_state = try State.init(owned, m.nbody),
            .contact_exempt = try contactExemptMask(owned, m.nbody, options.task.contact_exempt, options.body_names),
            .head = try headBody(options.task.head_body, options.body_names),
            .targets = try owned.alloc(f32, m.nq),
            .target_velocity = try owned.alloc(f32, m.nv),
            .accel = try owned.alloc(f32, m.nv),
            .torque = try owned.alloc(f32, m.nv),
            .scratch = try owned.alloc(f32, m.nv),
            .full = try owned.alloc(f32, m.nv),
            .dense = try owned.alloc(f32, m.nv * m.nv),
        };
        for (fleet.data) |*d| {
            d.* = try rbt.Data.init(owned, m);
        }
        for (fleet.terminal) |*state| {
            state.* = try State.init(owned, m.nbody);
        }
        for (fleet.worlds, fleet.bridges, fleet.data) |*world, *bridge, *d| {
            world.* = try floorWorld(owned, options.task.floor_friction);
            bridge.* = try robot_physics.Bridge.init(owned, world, m, d, 256);
            bridge.listen(world);
        }
        for (0..options.envs) |env| {
            fleet.restart(env);
        }
        return fleet;
    }

    pub fn deinit(self: *Fleet) void {
        // `rbt.Data` holds its own allocations, so each still gets a `deinit` - it just hands the
        // memory back to the arena, which is about to be thrown away anyway.
        for (self.data) |*d| {
            d.deinit();
        }
        for (self.bridges, self.worlds) |*bridge, *world| {
            bridge.deinit(world);
        }
        self.reference_data.deinit();
        const gpa: Allocator = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Start an environment somewhere new: a random clip, a random frame, a fresh segment.
    /// A new episode for `env` at a RANDOM clip and frame - reference-state initialisation (`startAt`).
    fn restart(self: *Fleet, env: usize) void {
        const random: std.Random = self.rng.random();
        const clip_index: usize = random.uintLessThan(usize, self.clips.len);
        const frame: usize = 1 + random.uintLessThan(usize, self.clips[clip_index].frame_count - 2);
        self.startAt(env, clip_index, frame);
    }

    /// A new episode for `env` EXACTLY at `frame` of clip `clip_index`: the character put on the reference there
    /// (and rested on the floor, and pushed off it by `start_noise`, as the task says), its clock at that frame.
    /// `restart` calls it with a random clip and frame - the random draws in the same order as always, so a fleet's
    /// runs are bit-for-bit what they were; a JUDGE calls it with chosen ones (`judge`).
    pub fn startAt(self: *Fleet, env: usize, clip_index: usize, frame: usize) void {
        const clip: *const dance.Clip = self.clips[clip_index];
        assertf(frame >= 1 and frame + 1 < clip.frame_count, @src(), "start frame {d} of a {d}-frame clip", .{
            frame,
            clip.frame_count,
        });
        self.clip_of[env] = clip_index;
        resetToFrame(self.m, &self.data[env], clip, frame);
        if (self.options.task.rest_on_floor) {
            _ = rbt.restOnFloor(self.m, &self.data[env], 0.001);
        }
        perturbStart(self.m, &self.data[env], self.options.start_noise, self.rng.random(), self.scratch);
        self.frame[env] = @intCast(frame);
        self.steps[env] = 0;
        self.segment[env] = self.next_segment;
        self.next_segment += 1;
    }

    /// What the policy sees for every environment: the simulated character and the reference it is
    /// chasing, each in the root's frame. `out` is `envs * observationSize(m)` long.
    pub fn observe(self: *Fleet, out: []f32) void {
        const size: usize = observationSize(self.m);
        assertf(out.len == self.options.envs * size, @src(), "observations are {d} long, want {d}", .{
            out.len,
            self.options.envs * size,
        });
        const half: usize = size / 2;
        for (0..self.options.envs) |env| {
            const clip: *const dance.Clip = self.clips[self.clip_of[env]];
            rbt.forward(self.m, &self.data[env]);
            stateOf(self.m, &self.data[env], &self.sim_state);
            local(self.sim_state, self.root, out[env * size ..][0..half]);
            self.referenceStateAt(clip, self.frame[env]);
            local(self.reference_state, self.root, out[env * size + half ..][0..half]);
        }
    }

    /// The reference's whole-body state at `frame`, into a caller's `State` with a caller's
    /// scratch `Data` - so a planner can ask about frames ahead without disturbing the fleet's own.
    pub fn referenceStateInto(
        self: *Fleet,
        clip: *const dance.Clip,
        frame: u32,
        d: *rbt.Data,
        out: *State,
    ) void {
        const at: usize = @min(@as(usize, frame), clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.nq;
        @memcpy(d.pos, clip.pose(at)[root_len..]);
        const previous: usize = if (at == 0) 0 else at - 1;
        rbt.differentiatePos(
            self.m,
            d.vel,
            clip.pose(previous)[root_len..],
            clip.pose(at)[root_len..],
            clip.frame_time,
        );
        d.stage = .stale;
        rbt.forward(self.m, d);
        stateOf(self.m, d, out);
    }

    /// The reference's whole-body state at `frame`, into `reference_state`.
    fn referenceStateAt(self: *Fleet, clip: *const dance.Clip, frame: u32) void {
        const at: usize = @min(@as(usize, frame), clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.nq;
        @memcpy(self.reference_data.pos, clip.pose(at)[root_len..]);
        const previous: usize = if (at == 0) 0 else at - 1;
        rbt.differentiatePos(
            self.m,
            self.reference_data.vel,
            clip.pose(previous)[root_len..],
            clip.pose(at)[root_len..],
            clip.frame_time,
        );
        self.reference_data.stage = .stale;
        rbt.forward(self.m, &self.reference_data);
        stateOf(self.m, &self.reference_data, &self.reference_state);
    }

    /// The whole-body state of a recorded frame, rebuilt by forward kinematics. `d` is scratch.
    pub fn stateAt(
        self: *Fleet,
        env: usize,
        index: u64,
        d: *rbt.Data,
        out: *State,
    ) void {
        @memcpy(d.pos, self.replay.poseAt(env, index));
        @memcpy(d.vel, self.replay.velocityAt(env, index));
        d.stage = .stale;
        rbt.forward(self.m, d);
        stateOf(self.m, d, out);
    }

    /// The servo targets a recorded frame was driven toward: its reference pose, nudged by the
    /// action that was taken. `scratch` is `m.nv`, `out` is `m.nq`.
    pub fn targetsAt(
        self: *Fleet,
        env: usize,
        index: u64,
        scratch: []f32,
        out: []f32,
    ) void {
        // The clip this RECORD was tracking, not the one its environment is on now - they differ
        // for anything older than the environment's last restart.
        const clip: *const dance.Clip = self.clips[self.replay.clipAt(env, index)];
        // The targets the servo ACTUALLY used for this record's step: the next frame, clamped - exactly
        // as `driveOnce` aims. (This must change whenever that does: the structured world model learns
        // from these, and a target one frame off what the fleet used would be a quiet lie in its data.)
        const frame: usize = @min(@as(usize, self.replay.frameAt(env, index)) + 1, clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.nq;
        applyAction(
            self.m,
            clip.pose(frame)[root_len..],
            self.replay.actionAt(env, index),
            self.options.action_scale,
            scratch,
            out,
        );
        clampHinges(self.m, out);
    }

    /// Drive one character one frame: turn the action into servo targets on the reference, run the
    /// servo, step, and leave the data forward-current.
    ///
    /// Shared so that a planner imagining a step and the fleet taking one cannot drift apart: an
    /// imagined step that is not the step actually taken is a plan for a different robot.
    pub fn driveOnce(
        self: *Fleet,
        d: *rbt.Data,
        world: *zimrphysics.World,
        bridge: *robot_physics.Bridge,
        clip: *const dance.Clip,
        frame: u32,
        action: []const f32,
    ) !void {
        const root_len: usize = clip.nq - self.m.nq;
        // The servo aims where the reference is GOING: during the step from frame i to i+1 it drives
        // toward pose i+1, as SuperTrack's PD targets do (exp(a/2 o) x k_{i+1}). Aiming at pose i left
        // every step a frame (17 ms) behind the motion it was meant to follow - and the tracking error
        // measured after the step is against pose i+1, so aim and score now agree. Clamped at the end.
        const at: usize = @min(@as(usize, frame) + 1, clip.frame_count - 1);
        applyAction(self.m, clip.pose(at)[root_len..], action, self.options.action_scale, self.scratch, self.targets);
        clampHinges(self.m, self.targets);
        // Only when something made the data stale - a restart, a shove, a reset. Every step ENDS
        // with the stages the next one reads, and nothing writes to the data between that and
        // here, so recomputing them would produce the same numbers from the same inputs:
        // measured, that was 28% of a step (127 of 452 us) spent reproducing what was already
        // there. The stage watermark is what makes skipping it safe rather than hopeful.
        if (!d.stage.atLeast(.velocity)) {
            rbt.forward(self.m, d);
        }
        // Collide first, so the step that follows knows about the ground it is standing on.
        try bridge.sync(world, self.m, d);
        try zimrphysics.step(world, clip.frame_time);
        bridge.harvest(d);
        rbt.biasForce(self.m, d);
        const gains: Gains = self.options.task.gains;
        // With feedforward, the velocity of the step the servo aims along: `frame` -> `frame + 1`. At the clip's end
        // the aim is clamped to the last pose - held still - and `referenceVelocity` is zero there, as it must be.
        // (It once asked for `at - 1`: at the end that was the last MOVING step's velocity, telling a joint that
        // should come to rest to keep going - and a one-frame clip underflowed.)
        const moving: ?[]const f32 = if (gains.velocity_feedforward) blk: {
            referenceVelocity(self.m, clip, frame, self.target_velocity);
            break :blk self.target_velocity;
        } else null;
        pdTorquesToward(
            self.m,
            d,
            self.targets,
            moving,
            gains,
            clip.frame_time,
            self.accel,
            self.scratch,
            self.dense,
            self.full,
            self.torque,
        );
        @memcpy(d.applied_force, self.torque);
        // `step` runs a complete `forward` of its own before it integrates, so a full one here
        // would compute the factorisation, the constraints and the dynamics solve only for the
        // next step's `step` to compute them again. What is READ between now and then is less:
        // body poses and velocities (the fleet's state, the bridge's sync) and the mass matrix
        // (the servo's torques). Exactly those four stages, in `forward`'s own order - which
        // leaves the watermark at `velocity`, and the guard above asks for no more than that.
        rbt.step(self.m, d);
        rbt.kinematics(self.m, d);
        rbt.comPos(self.m, d);
        rbt.crb(self.m, d);
        rbt.comVel(self.m, d);
    }

    /// One frame for every environment: act, drive, step, record, and start again where needed.
    /// `actions` is `envs * actionSize(m)` long, each in [-1, 1]. Returns the mean reward.
    /// A ground to stand on: a large static box with its top face at z = 0, as the dance rungs use.
    pub fn floorWorld(gpa: Allocator, friction: f32) !zimrphysics.World {
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
            .friction = friction,
        });
        return world;
    }

    pub fn step(self: *Fleet, actions: []const f32) f32 {
        const size: usize = actionSize(self.m);
        assertf(actions.len == self.options.envs * size, @src(), "actions are {d} long, want {d}", .{
            actions.len,
            self.options.envs * size,
        });
        const random: std.Random = self.rng.random();
        var reward_total: f32 = 0.0;
        for (0..self.options.envs) |env| {
            const clip: *const dance.Clip = self.clips[self.clip_of[env]];
            const d: *rbt.Data = &self.data[env];
            const action: []const f32 = actions[env * size ..][0..size];
            const at: u32 = self.frame[env];

            // Record the state the action was taken FROM, so a window reads as
            // (state, action) -> the next record's state.
            self.replay.append(env, d.pos, d.vel, action, at, @intCast(self.clip_of[env]), self.segment[env]);

            // Loudly: a collision world that quietly stops working leaves a character quietly
            // falling through the floor, which is exactly the failure this coupling was added for.
            self.driveOnce(d, &self.worlds[env], &self.bridges[env], clip, at, action) catch |err| {
                zm.assertUnreachable(@src(), "the collision world failed mid-step: {s}", .{@errorName(err)});
            };

            self.frame[env] += 1;
            self.steps[env] += 1;
            self.steps_total += 1;
            stateOf(self.m, d, &self.sim_state);
            exemptFromContact(&self.sim_state, self.contact_exempt);
            self.referenceStateAt(clip, self.frame[env]);
            const sim: State = self.sim_state;
            const err: TrackingError = trackingErrorWithHead(sim, self.reference_state, self.root, self.head);
            const earned: f32 = reward(err, self.options.task.weights);
            self.rewards[env] = earned;
            self.dones[env] = false;
            reward_total += earned;

            // A character whose state is no longer finite is broken, grace or not: every comparison
            // with NaN is false, so the limits alone would let it run on - poisoning the world - forever.
            const broken: bool = !(err.pose_position == err.pose_position and err.pose_rotation == err.pose_rotation and
                err.root_position == err.root_position and err.root_rotation == err.root_rotation);
            const graced: bool = self.steps[env] < self.options.task.termination.grace_steps;
            const lost: bool = broken or (!graced and terminated(err, self.options.task.termination));
            const finished: bool = lost or
                self.steps[env] >= self.options.max_steps or
                self.frame[env] + 1 >= clip.frame_count;
            self.failures[env] = false;
            if (finished) {
                self.episodes += 1;
                self.dones[env] = true;
                self.failures[env] = lost;
                // Why it ended, and where - before `restart` replaces the state just measured.
                const capped: bool = self.steps[env] >= self.options.max_steps;
                self.ends[env] = if (lost) .lost else if (capped) .cap else .clip_end;
                self.terminal[env].copyFrom(self.sim_state);
                self.terminal_frame[env] = self.frame[env];
                self.terminal_clip[env] = self.clip_of[env];
                if (lost) {
                    self.failed += 1;
                }
                self.restart(env);
                continue;
            }
            // A shove is an impulse from outside: nothing in the state saw it coming, so the
            // stretch of motion it interrupts ends here and a new segment begins.
            if (self.options.shove_every > 0 and self.steps[env] % self.options.shove_every == 0) {
                const speed: f32 = self.options.shove_speed;
                d.vel[0] += speed * (2.0 * random.float(f32) - 1.0);
                d.vel[1] += speed * (2.0 * random.float(f32) - 1.0);
                d.stage = .stale;
                self.segment[env] = self.next_segment;
                self.next_segment += 1;
            }
        }
        self.last_reward = reward_total / float(self.options.envs);
        return self.last_reward;
    }
};

// -- The world model: what it is asked, what it answers, and how well. --

/// How the servo's targets are written for a network: two numbers a hinge, six a ball.
///
/// A hinge angle goes in as (sin, cos) rather than as the angle, and a ball as its two axes, for
/// the same reason rotations are two axes everywhere else here - a number that wraps, or a
/// quaternion that can be negated, is a discontinuous thing to learn from. The free root has no
/// targets: nothing actuates it.
pub fn targetSize(m: *const rbt.Model) usize {
    var size: usize = 0;
    for (0..m.njnt) |j| {
        size += switch (m.jnt_type[j]) {
            .free => 0,
            .ball => 6,
            .hinge, .slide => 2,
        };
    }
    return size;
}

pub fn encodeTargets(m: *const rbt.Model, targets: []const f32, out: []f32) void {
    assertf(out.len == targetSize(m), @src(), "targets encode to {d} numbers, got {d}", .{ targetSize(m), out.len });
    var at: usize = 0;
    for (0..m.njnt) |j| {
        const q: usize = m.jnt_qpos_adr[j];
        switch (m.jnt_type[j]) {
            .free => {},
            .ball => {
                const axes: [6]f32 = twoAxis(.{ targets[q], targets[q + 1], targets[q + 2], targets[q + 3] });
                @memcpy(out[at..][0..6], &axes);
                at += 6;
            },
            .hinge, .slide => {
                out[at] = @sin(targets[q]);
                out[at + 1] = @cos(targets[q]);
                at += 2;
            },
        }
    }
}

/// What a world model sees: the character in its own frame, and what the servo has been told to
/// reach for.
///
/// Not the servo's ERROR, tempting as that is - the error depends on the state, and during a
/// rollout the state is the model's own guess, so feeding the error would quietly mix the model's
/// drift into its input. The targets are known for the whole window whatever the model predicts.
pub fn worldInputSize(m: *const rbt.Model) usize {
    return localSize(m.nbody) + targetSize(m);
}

pub fn encodeWorldInput(
    m: *const rbt.Model,
    state: State,
    root: usize,
    targets: []const f32,
    out: []f32,
) void {
    const split: usize = localSize(m.nbody);
    assertf(out.len == worldInputSize(m), @src(), "world input is {d} numbers, got {d}", .{
        worldInputSize(m),
        out.len,
    });
    local(state, root, out[0..split]);
    encodeTargets(m, targets, out[split..]);
}

/// What it answers: every body's linear and angular acceleration, in the ROOT's frame and divided
/// by `acceleration_scale`.
///
/// In the root's frame because that is where the rest of the representation lives, and divided
/// because a network whose outputs sit near one learns faster than a network asked to produce a
/// hundred - the same reason the cartpole's world model divides by ten. A humanoid's bodies see
/// about ten g in a hard landing, so thirty is a scale that keeps ordinary motion inside one.
pub const acceleration_scale: f32 = 30.0;

pub fn worldOutputSize(m: *const rbt.Model) usize {
    return (m.nbody - 1) * 6;
}

/// World-frame accelerations into the model's units.
pub fn encodeAccelerations(
    state: State,
    root: usize,
    linear: []const Vec,
    angular: []const Vec,
    out: []f32,
) void {
    const to_local: Quat = conjugate(state.rotations[root]);
    var at: usize = 0;
    for (1..state.bodies()) |b| {
        writeVec(out, &at, rotate(to_local, linear[b]) * splat(1.0 / acceleration_scale));
    }
    for (1..state.bodies()) |b| {
        writeVec(out, &at, rotate(to_local, angular[b]) * splat(1.0 / acceleration_scale));
    }
}

/// And back out, into the world, ready for `integrate`.
pub fn decodeAccelerations(
    state: State,
    root: usize,
    in: []const f32,
    linear: []Vec,
    angular: []Vec,
) void {
    const to_world: Quat = state.rotations[root];
    const bodies: usize = state.bodies();
    linear[0] = vec_zero;
    angular[0] = vec_zero;
    for (1..bodies) |b| {
        const at: usize = (b - 1) * 3;
        linear[b] = rotate(to_world, vec(in[at], in[at + 1], in[at + 2])) * splat(acceleration_scale);
    }
    const half: usize = (bodies - 1) * 3;
    for (1..bodies) |b| {
        const at: usize = half + (b - 1) * 3;
        angular[b] = rotate(to_world, vec(in[at], in[at + 1], in[at + 2])) * splat(acceleration_scale);
    }
}

/// Anything that can answer the world model's question, so that the same harness can measure a
/// network, an oracle, or a baseline that barely thinks at all.
pub const Predictor = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, input: []const f32, out: []f32) void,

    pub fn predict(self: Predictor, input: []const f32, out: []f32) void {
        self.call(self.context, input, out);
    }
};

/// How far a predictor's rollout has drifted after each number of steps.
pub const Drift = struct {
    /// Mean over bodies and windows of the distance to where the simulator actually was (metres).
    position: []f32,
    /// The same for orientation (radians).
    rotation: []f32,
    /// And the POSE: each body's distance from where the simulator had it, measured in each
    /// character's own root frame (`TrackingError.pose_position`) - what a tracking policy is
    /// scored on, and the quantity a model predicting root-frame features is compared by.
    pose: []f32,
    /// How many rollouts went into it.
    windows: usize,
};

/// Where a rollout's accelerations come from.
///
/// The two reference sources live here rather than behind `Predictor` because neither is a model:
/// both are properties of the RECORD, and a harness that cannot measure them cannot be trusted to
/// measure a network either.
///
///   * `oracle` - the accelerations the simulator actually produced at each step. Its drift is the
///     floor: whatever an explicit integrator costs, nothing can do better.
///   * `hold_first` - the window's first real acceleration, held for the whole rollout. A model
///     that cannot beat this has learned nothing about how a humanoid moves.
pub const Source = union(enum) {
    learned: Predictor,
    oracle,
    hold_first,
};

/// Roll a source forward through recorded windows and measure how fast it drifts.
///
/// This is the diagnostic that says whether a world model is worth training a policy through: a
/// model that is excellent for one step and hopeless by eight is no use to a policy unrolled for
/// thirty-two. Each rollout starts on a recorded state, then feeds the model its OWN predictions
/// while the targets come from the record - which is exactly how it will be used.
///
/// `steps` is the horizon; `drift.position[k]` is the error after k + 1 steps.
pub fn measureDrift(
    gpa: Allocator,
    fleet: *Fleet,
    source: Source,
    draws: usize,
    steps: usize,
    random: std.Random,
) !Drift {
    const m: *rbt.Model = fleet.m;
    const position: []f32 = try gpa.alloc(f32, steps);
    errdefer gpa.free(position);
    const rotation: []f32 = try gpa.alloc(f32, steps);
    errdefer gpa.free(rotation);
    const pose: []f32 = try gpa.alloc(f32, steps);
    errdefer gpa.free(pose);
    @memset(position, 0.0);
    @memset(rotation, 0.0);
    @memset(pose, 0.0);

    var predicted: State = try State.init(gpa, m.nbody);
    defer predicted.deinit(gpa);
    var actual: State = try State.init(gpa, m.nbody);
    defer actual.deinit(gpa);
    const input: []f32 = try gpa.alloc(f32, worldInputSize(m));
    defer gpa.free(input);
    const output: []f32 = try gpa.alloc(f32, worldOutputSize(m));
    defer gpa.free(output);
    const linear: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(linear);
    const angular: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(angular);
    const targets: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(targets);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();

    var held: State = try State.init(gpa, m.nbody);
    defer held.deinit(gpa);
    const held_linear: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(held_linear);
    const held_angular: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(held_angular);
    const dt: f32 = m.opt.timestep;

    var windows: usize = 0;
    for (0..draws) |_| {
        const window: Replay.Window = fleet.replay.sampleWindow(random, steps) orelse continue;
        windows += 1;
        fleet.stateAt(window.env, window.first, &scratch_data, &predicted);
        if (source == .hold_first) {
            // The window's first real transition, kept for the whole rollout.
            fleet.stateAt(window.env, window.first + 1, &scratch_data, &held);
            accelerationsBetween(predicted, held, dt, held_linear, held_angular);
        }
        for (0..steps) |k| {
            const index: u64 = window.first + k;
            switch (source) {
                .learned => |predictor| {
                    fleet.targetsAt(window.env, index, scratch, targets);
                    encodeWorldInput(m, predicted, fleet.root, targets, input);
                    predictor.predict(input, output);
                    decodeAccelerations(predicted, fleet.root, output, linear, angular);
                },
                .oracle => {
                    // What the simulator did between these two records, in the world - the floor.
                    fleet.stateAt(window.env, index, &scratch_data, &held);
                    fleet.stateAt(window.env, index + 1, &scratch_data, &actual);
                    accelerationsBetween(held, actual, dt, linear, angular);
                },
                .hold_first => {
                    @memcpy(linear, held_linear);
                    @memcpy(angular, held_angular);
                },
            }
            integrate(&predicted, linear, angular, dt);
            fleet.stateAt(window.env, index + 1, &scratch_data, &actual);
            pose[k] += trackingError(predicted, actual, fleet.root).pose_position;
            for (1..m.nbody) |b| {
                position[k] += length3(predicted.positions[b] - actual.positions[b]) / float(m.nbody - 1);
                rotation[k] += angleBetween(predicted.rotations[b], actual.rotations[b]) / float(m.nbody - 1);
            }
        }
    }
    for (position, rotation, pose) |*p, *r, *q| {
        p.* /= float(@max(windows, 1));
        r.* /= float(@max(windows, 1));
        q.* /= float(@max(windows, 1));
    }
    return .{ .position = position, .rotation = rotation, .pose = pose, .windows = windows };
}

pub fn freeDrift(gpa: Allocator, drift: Drift) void {
    gpa.free(drift.position);
    gpa.free(drift.rotation);
    gpa.free(drift.pose);
}

// -- The checks. Everything above is a convention, and a convention is only worth what it can be
// caught getting wrong. --

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

/// A model and a place to put its state, for the tests below.
const Rig = struct {
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    data: rbt.Data,

    fn init(rig: *Rig, gpa: Allocator, timestep: f32) !void {
        return rig.initAs(gpa, timestep, false);
    }

    /// `weld_root` bolts the root down by leaving the free joint out of the text, as the fixed-base
    /// rungs do.
    fn initAs(rig: *Rig, gpa: Allocator, timestep: f32, weld_root: bool) !void {
        const free_joint: []const u8 = "<freejoint name=\"root\"/>";
        const text: []const u8 = if (weld_root)
            try std.mem.replaceOwned(u8, gpa, flex2_xml, free_joint, "")
        else
            flex2_xml;
        defer if (weld_root) gpa.free(@constCast(text));
        // whole-init-first: the whole struct first - defaults applied, every field named.
        rig.* = .{
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .data = undefined,
        };
        rig.doc = try codecs.xml.parse(gpa, text, null);
        errdefer rig.doc.deinit();
        rig.robot = try mjcf.readRobot(gpa, &rig.doc);
        errdefer rig.robot.deinit();
        var options: rbt.Options = .{ .timestep = timestep, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
        options.solver.algorithm = .newton;
        rig.imported = try robot_mjcf.build(gpa, &rig.robot, options);
        errdefer rig.imported.deinit();
        rig.data = try rbt.Data.init(gpa, &rig.imported.model);
    }

    fn deinit(rig: *Rig) void {
        rig.data.deinit();
        rig.imported.deinit();
        rig.robot.deinit();
        rig.doc.deinit();
    }

    fn model(rig: *Rig) *rbt.Model {
        return &rig.imported.model;
    }

    /// A pose and velocity that are nothing special: off the rest pose, moving, in the air.
    fn scatter(rig: *Rig, random: std.Random, reach: f32) void {
        const m: *rbt.Model = rig.model();
        const d: *rbt.Data = &rig.data;
        d.reset(m);
        var shift: [128]f32 = undefined;
        for (shift[0..m.nv], 0..) |*s, k| {
            s.* = reach * (2.0 * random.float(f32) - 1.0);
            d.vel[k] = reach * (2.0 * random.float(f32) - 1.0);
        }
        rbt.integratePos(m, d.pos, shift[0..m.nv], 1.0);
        rbt.normalizeQuats(m, d.pos);
        d.pos[2] += 1.5; // up in the air, so nothing touches the floor
        d.stage = .stale;
        rbt.forward(m, d);
    }
};

// ==== THE JUDGE (plan F1) ====
//
// One way to say how good a controller is, used for every learner: fixed starts spread over a clip, the controller's
// MEAN action (no exploration), each start run until the task's rule loses the reference or the clip ends - and the
// servo alone on the same starts, in the same units, beside it.
//
// Why not the training fleet's own numbers: its starts are random, so two evaluations differ by where the starts
// happened to land, and a change that "helped" may only have drawn easier stretches. Here the starts are the same
// every time and nothing is random, so two calls give identical numbers - a difference between two runs is the
// controller's.

/// Whoever acts during a judgement: fill `actions` (one row of `actionSize` per environment) for the fleet's current
/// state - the controller's MEAN action, no exploration. A context pointer and a function, so any learner can be
/// judged without the judge knowing its type.
pub const Actor = struct {
    context: *anyopaque,
    act: *const fn (context: *anyopaque, fleet: *Fleet, actions: []f32) void,
};

/// What a judgement found. Every start's FIRST episode is counted, to its end.
pub const Judgement = struct {
    starts: usize,
    /// Starts whose episode the task's rule ended - the reference lost.
    failures: usize,
    /// Starts that ran to the clip's end still with the reference.
    reached_end: usize,
    /// Steps watched, over every start's episode.
    watched_steps: usize,
    reward_sum: f64,
    frame_time: f32,

    /// Mean time to failure (seconds): the time watched per failure - the number that says how long a character
    /// keeps the reference. With no failure at all it is the whole time watched: a lower bound.
    pub fn meanTimeToFailure(self: Judgement) f32 {
        const seconds: f32 = float(self.watched_steps) * self.frame_time;
        return seconds / float(@max(self.failures, 1));
    }

    /// The share of starts that reached the clip's end.
    pub fn shareToEnd(self: Judgement) f32 {
        return float(self.reached_end) / float(@max(self.starts, 1));
    }

    /// The task's reward per watched step.
    pub fn meanReward(self: Judgement) f32 {
        return @floatCast(self.reward_sum / float64(@max(self.watched_steps, 1)));
    }
};

/// A judgement IN PROGRESS - so a page can spread one over frames (`advance` with a step budget each frame) instead of
/// stalling for the second or more a whole judgement takes on a phone. `judge` is the same thing run to the end.
///
/// Its fleet is `judgeOptions`'s; `options` supplies the task, the action scale and the body names, as the controller
/// was trained with.
pub const Judging = struct {
    gpa: Allocator,
    fleet: *Fleet,
    actions: []f32,
    finished: []bool,
    remaining: usize,
    result: Judgement,

    pub fn init(
        gpa: Allocator,
        m: *rbt.Model,
        clip: *const dance.Clip,
        options: Fleet.Options,
        starts: []const usize,
    ) !Judging {
        const fleet: *Fleet = try Fleet.init(gpa, m, &.{clip}, judgeOptions(options, starts.len, clip));
        errdefer fleet.deinit();
        for (starts, 0..) |frame, env| {
            fleet.startAt(env, 0, frame);
        }
        const actions: []f32 = try gpa.alloc(f32, starts.len * actionSize(m));
        errdefer gpa.free(actions);
        @memset(actions, 0.0);
        const finished: []bool = try gpa.alloc(bool, starts.len);
        @memset(finished, false);
        return .{
            .gpa = gpa,
            .fleet = fleet,
            .actions = actions,
            .finished = finished,
            .remaining = starts.len,
            .result = .{
                .starts = starts.len,
                .failures = 0,
                .reached_end = 0,
                .watched_steps = 0,
                .reward_sum = 0.0,
                .frame_time = clip.frame_time,
            },
        };
    }

    pub fn deinit(self: *Judging) void {
        self.gpa.free(self.finished);
        self.gpa.free(self.actions);
        self.fleet.deinit();
    }

    /// Step the judged fleet up to `budget` times with `actor` acting (null: the servo alone). True once every
    /// start's first episode has ended - `result` is then final.
    pub fn advance(self: *Judging, actor: ?Actor, budget: usize) bool {
        var left: usize = budget;
        while (self.remaining > 0 and left > 0) : (left -= 1) {
            if (actor) |who| {
                who.act(who.context, self.fleet, self.actions);
            }
            _ = self.fleet.step(self.actions);
            // After its first ending an environment restarts somewhere random; it keeps being stepped (the
            // fleet steps them all) but is no longer counted.
            for (self.finished, 0..) |*done, env| {
                if (done.*) {
                    continue;
                }
                self.result.watched_steps += 1;
                self.result.reward_sum += self.fleet.rewards[env];
                if (!self.fleet.dones[env]) {
                    continue;
                }
                done.* = true;
                self.remaining -= 1;
                switch (self.fleet.ends[env]) {
                    .lost => self.result.failures += 1,
                    .clip_end => self.result.reached_end += 1,
                    .cap => {},
                }
            }
        }
        return self.remaining == 0;
    }
};

/// The judge's fleet options: the caller's task, action scale and body names; one environment per start, no
/// perturbation, no shoves, no grace (the task's rule from the first step - a training window's grace is a learner's
/// aid, not part of the rule), no step cap before the clip's end. One definition, so every judged fleet - `Judging`'s
/// and a learner's diagnostics' - is the same fleet.
pub fn judgeOptions(
    options: Fleet.Options,
    envs: usize,
    clip: *const dance.Clip,
) Fleet.Options {
    var judged: Fleet.Options = options;
    judged.envs = envs;
    judged.capacity = 16;
    judged.start_noise = .{};
    judged.shove_every = 0;
    judged.max_steps = @intCast(clip.frame_count);
    judged.task.termination.grace_steps = 0;
    return judged;
}

/// Judge `actor` - or, with `actor` null, the SERVO ALONE (zero offsets) - on `clip` from `starts` (frames), start to
/// finish (`Judging`, run to the end).
pub fn judge(
    gpa: Allocator,
    m: *rbt.Model,
    clip: *const dance.Clip,
    options: Fleet.Options,
    starts: []const usize,
    actor: ?Actor,
) !Judgement {
    var judging: Judging = try .init(gpa, m, clip, options, starts);
    defer judging.deinit();
    // Every start's episode ends within the clip's length (the judge caps nothing before it), so one clip's worth of
    // steps finishes any judgement.
    const done: bool = judging.advance(actor, clip.frame_count);
    assertf(done, @src(), "a judgement unfinished after {d} steps", .{clip.frame_count});
    return judging.result;
}

/// Starts every `every` frames across `clip`, from its first startable frame, while a step remains after them -
/// the judge's usual starts (every 0.5 s: `every` = 30 at 60 Hz).
pub fn evenStarts(gpa: Allocator, clip: *const dance.Clip, every: usize) ![]usize {
    assertf(every > 0 and clip.frame_count > 2, @src(), "every {d} frames of {d}", .{ every, clip.frame_count });
    const count: usize = (clip.frame_count - 3) / every + 1;
    const starts: []usize = try gpa.alloc(usize, count);
    for (starts, 0..) |*start, i| {
        start.* = 1 + i * every;
    }
    return starts;
}

test "robot_track: the judge - the same starts every time, identical twice, every start counted once" {
    // Plan F1's known answers, on the rig and the walk. Evenly spaced starts land where they should; two judgements
    // of the same controller are IDENTICAL (nothing in the judge is random); every start's first episode is counted
    // exactly once, ended by the rule or by the clip (the judge caps nothing before the clip's end); and the servo
    // alone (no actor) is exactly an actor that asks for no offsets.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);

    const starts: []usize = try evenStarts(gpa, &walk, 60);
    defer gpa.free(starts);
    try expect(starts[0] == 1 and starts[1] == 61);
    try expect(starts[starts.len - 1] + 1 < walk.frame_count);
    try expect(starts[starts.len - 1] + 60 + 1 >= walk.frame_count); // and no room for one more

    const servo: Judgement = try judge(gpa, m, &walk, .{}, starts, null);
    const again: Judgement = try judge(gpa, m, &walk, .{}, starts, null);
    try expect(std.meta.eql(servo, again));
    try expect(servo.failures + servo.reached_end == servo.starts);

    const NoOffsets = struct {
        fn act(context: *anyopaque, fleet: *Fleet, actions: []f32) void {
            _ = context;
            _ = fleet;
            @memset(actions, 0.0);
        }
    };
    var unused: u8 = 0;
    const zero: Judgement = try judge(gpa, m, &walk, .{}, starts, .{ .context = &unused, .act = NoOffsets.act });
    try expect(std.meta.eql(servo, zero));

    // Spread over "frames" - 7 steps at a time, as a page would - it is the same judgement.
    var judging: Judging = try .init(gpa, m, &walk, .{}, starts);
    defer judging.deinit();
    var calls: usize = 0;
    while (!judging.advance(null, 7)) {
        calls += 1;
    }
    try expect(calls > 1);
    try expect(std.meta.eql(judging.result, servo));
}

test "robot_track: two axes and back" {
    var rng: std.Random.DefaultPrng = .init(4);
    const random: std.Random = rng.random();
    var worst: f32 = 0.0;
    for (0..2000) |_| {
        const axis: Vec = normalize3(vec(random.floatNorm(f32), random.floatNorm(f32), random.floatNorm(f32)));
        const q: Quat = quatFromNormAxisAngle(axis, (2.0 * random.float(f32) - 1.0) * pi);
        var back: Quat = fromTwoAxis(twoAxis(q));
        if (dot3(vec(back[0], back[1], back[2]), vec(q[0], q[1], q[2])) + back[3] * q[3] < 0.0) {
            back = -back; // q and -q are the same rotation; compare the nearer one
        }
        worst = @max(worst, length3(vec(back[0] - q[0], back[1] - q[1], back[2] - q[2])) + @abs(back[3] - q[3]));
    }
    try expect(worst < 1.0e-6);
}

test "robot_track: local is blind to where you stand and which way you face - and to nothing else" {
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const root: usize = 1; // the first body below the world is the character's root
    var state: State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    var moved: State = try .init(gpa, m.nbody);
    defer moved.deinit(gpa);
    const before: []f32 = try gpa.alloc(f32, localSize(m.nbody));
    defer gpa.free(before);
    const after: []f32 = try gpa.alloc(f32, localSize(m.nbody));
    defer gpa.free(after);
    var rng: std.Random.DefaultPrng = .init(11);
    const random: std.Random = rng.random();

    var worst_invariant: f32 = 0.0;
    var weakest_control: f32 = 1.0e9;
    for (0..16) |_| {
        rig.scatter(random, 0.6);
        stateOf(m, &rig.data, &state);
        local(state, root, before);

        // Turn the whole character about the world's up axis and walk it somewhere else. The free
        // root carries a position, a quaternion, a world linear velocity and an angular velocity in
        // its own frame - so the first three turn, and the last one doesn't.
        const yaw: Quat = quatFromNormAxisAngle(vec(0, 0, 1), 2.0 * random.float(f32) - 1.0);
        const move: Vec = vec(10.0 * random.float(f32), -4.0 * random.float(f32), 0.0);
        const saved_pos: [7]f32 = rig.data.pos[0..7].*;
        const saved_vel: [6]f32 = rig.data.vel[0..6].*;
        const p: Vec = rotate(yaw, vec(saved_pos[0], saved_pos[1], saved_pos[2])) + move;
        const q: Quat = qmul(yaw, .{ saved_pos[3], saved_pos[4], saved_pos[5], saved_pos[6] });
        const v: Vec = rotate(yaw, vec(saved_vel[0], saved_vel[1], saved_vel[2]));
        rig.data.pos[0..3].* = .{ p[0], p[1], p[2] };
        rig.data.pos[3..7].* = .{ q[0], q[1], q[2], q[3] };
        rig.data.vel[0..3].* = .{ v[0], v[1], v[2] };
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &moved);
        local(moved, root, after);
        for (before, after) |a, b| {
            worst_invariant = @max(worst_invariant, @abs(a - b));
        }

        // ...and the controls. A representation blind to everything would be useless: lifting the
        // character must change its heights, and tipping it must change the up vector.
        rig.data.pos[2] += 0.25;
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &moved);
        local(moved, root, after);
        var lifted: f32 = 0.0;
        for (before, after) |a, b| {
            lifted = @max(lifted, @abs(a - b));
        }
        rig.data.pos[0..7].* = saved_pos;
        const pitch: Quat = quatFromNormAxisAngle(vec(1, 0, 0), 0.3);
        const tipped: Quat = qmul(pitch, .{ saved_pos[3], saved_pos[4], saved_pos[5], saved_pos[6] });
        rig.data.pos[3..7].* = .{ tipped[0], tipped[1], tipped[2], tipped[3] };
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &moved);
        local(moved, root, after);
        var tilted: f32 = 0.0;
        for (before, after) |a, b| {
            tilted = @max(tilted, @abs(a - b));
        }
        weakest_control = @min(weakest_control, @min(lifted, tilted));
    }
    report.print("\n  local: worst change under a yaw and a walk {e:.2}; " ++
        "weakest change under a lift or a tilt {d:.3}\n", .{
        worst_invariant,
        weakest_control,
    });
    try expect(worst_invariant < 1.0e-5);
    try expect(weakest_control > 0.1);
}

test "robot_track: the integrator reproduces the simulator's next state" {
    const gpa: Allocator = std.testing.allocator;
    var coarse: f32 = 0.0;
    var fine: f32 = 0.0;
    for ([_]f32{ 1.0 / 60.0, 1.0 / 120.0 }, 0..) |dt, pass| {
        var rig: Rig = undefined;
        try rig.init(gpa, dt);
        defer rig.deinit();
        const m: *rbt.Model = rig.model();
        var before: State = try .init(gpa, m.nbody);
        defer before.deinit(gpa);
        var after: State = try .init(gpa, m.nbody);
        defer after.deinit(gpa);
        var predicted: State = try .init(gpa, m.nbody);
        defer predicted.deinit(gpa);
        const linear: []Vec = try gpa.alloc(Vec, m.nbody);
        defer gpa.free(linear);
        const angular: []Vec = try gpa.alloc(Vec, m.nbody);
        defer gpa.free(angular);
        var rng: std.Random.DefaultPrng = .init(23);
        const random: std.Random = rng.random();
        var worst_position: f32 = 0.0;
        var worst_rotation: f32 = 0.0;
        var worst_velocity: f32 = 0.0;
        var mean_position: f32 = 0.0;
        var counted: f32 = 0.0;
        for (0..16) |_| {
            rig.scatter(random, 0.6);
            stateOf(m, &rig.data, &before);
            rbt.step(m, &rig.data);
            rbt.forward(m, &rig.data);
            stateOf(m, &rig.data, &after);

            // The accelerations the simulator actually produced, fed back through the integrator:
            // the velocities then match exactly, and the positions and rotations differ only by
            // what an explicit step costs.
            accelerationsBetween(before, after, dt, linear, angular);
            predicted.copyFrom(before);
            integrate(&predicted, linear, angular, dt);
            for (1..m.nbody) |b| {
                const off: f32 = length3(predicted.positions[b] - after.positions[b]);
                worst_position = @max(worst_position, off);
                mean_position += off;
                counted += 1.0;
                worst_velocity = @max(worst_velocity, length3(predicted.velocities[b] - after.velocities[b]));
                var rel: Quat = qmul(predicted.rotations[b], conjugate(after.rotations[b]));
                if (rel[3] < 0.0) {
                    rel = -rel;
                }
                // Small angles from the VECTOR part: acos of a w near 1 loses half its digits in
                // f32, and would report its own precision floor (about 1e-3 rad) as the error.
                worst_rotation = @max(worst_rotation, 2.0 * length3(vec(rel[0], rel[1], rel[2])));
            }
        }
        mean_position /= counted;
        report.print("  integrator at {d:.0} Hz: worst position {d:.5} m (mean {d:.6}), " ++
            "rotation {d:.6} rad, velocity {e:.2}\n", .{
            1.0 / dt,
            worst_position,
            mean_position,
            worst_rotation,
            worst_velocity,
        });
        try expect(worst_velocity < 1.0e-5);
        if (pass == 0) {
            coarse = mean_position;
        } else {
            fine = mean_position;
        }
    }
    // One frame at 60 Hz costs a couple of millimetres, and halving the step quarters it - the
    // signature of an O(dt^2) local error, which is what an explicit step is allowed.
    try expect(coarse < 0.005);
    try expect(fine < 0.35 * coarse);
}

test "robot_track: a zero action is the reference, exactly" {
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    try expect(actionSize(m) == m.nv - 6);
    var rng: std.Random.DefaultPrng = .init(5);
    rig.scatter(rng.random(), 0.5);
    const reference: []f32 = try gpa.dupe(f32, rig.data.pos);
    defer gpa.free(reference);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const target: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(target);
    const zero: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(zero);
    @memset(zero, 0.0);
    applyAction(m, reference, zero, 0.25, scratch, target);
    // Not "close": the same numbers. A tracker's policy starts at zero, and its first step must be
    // the reference itself, not the reference plus a rounding error.
    for (reference, target) |a, b| {
        try expect(a == b);
    }
}

test "robot_track: a bounded action moves every body a bounded amount" {
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const reference_pose: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(reference_pose);
    const reference_xpos: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(reference_xpos);
    var moved: rbt.Data = try rbt.Data.init(gpa, m);
    defer moved.deinit();
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    var rng: std.Random.DefaultPrng = .init(9);
    const random: std.Random = rng.random();
    var worst: [2]f32 = .{ 0.0, 0.0 };
    for ([_]f32{ 0.2, 0.1 }, 0..) |scale, pass| {
        var inner: std.Random.DefaultPrng = .init(17);
        const inner_random: std.Random = inner.random();
        for (0..32) |_| {
            rig.scatter(random, 0.5);
            @memcpy(reference_pose, rig.data.pos);
            @memcpy(reference_xpos, rig.data.body_xpos);
            for (action) |*a| {
                a.* = 2.0 * inner_random.float(f32) - 1.0;
            }
            applyAction(m, reference_pose, action, scale, scratch, moved.pos);
            clampHinges(m, moved.pos);
            moved.stage = .stale;
            rbt.kinematics(m, &moved);
            for (1..m.nbody) |b| {
                worst[pass] = @max(worst[pass], length3(moved.body_xpos[b] - reference_xpos[b]));
            }
        }
    }
    report.print("\n  action reach: worst body moved {d:.3} m at 0.2 rad, {d:.3} m at 0.1 rad\n", .{
        worst[0],
        worst[1],
    });
    // The offsets have to be small enough that a policy nudges the reference rather than replacing
    // it, and the reach has to be roughly proportional to the scale - no joint amplifying it.
    try expect(worst[0] < 0.5);
    try expect(worst[1] < 0.62 * worst[0]);
}

test "robot_track: the servo on a fixed base - computed torque against the PD law" {
    // What the policy inherits. Same walk, same targets, two ways of turning them into torque:
    // exact computed torque (which knows the whole model and follows the clip to a hundredth of a
    // degree), and the joint PD servo a policy actually acts through (which knows a spring and a
    // damping ratio, and sags under gravity). The gap between them is the policy's job.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var clip: dance.Clip = loadWalk(gpa, io) catch return error.SkipZigTest;
    defer clip.deinit();

    var rig: Rig = undefined;
    try rig.initAs(gpa, 1.0 / 60.0, true);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    dance.limpKeepArmature(m);
    const root_len: usize = clip.nq - m.nq;
    try expect(root_len == 7);
    var target: rbt.Data = try rbt.Data.init(gpa, m);
    defer target.deinit();
    var tracker: dance.Tracker = try .init(gpa, m.nv);
    defer tracker.deinit();
    const accel: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(accel);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const full: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(full);
    const dense: []f32 = try gpa.alloc(f32, m.nv * m.nv);
    defer gpa.free(dense);
    const dt: f32 = clip.frame_time;

    const Law = struct { name: []const u8, gains: ?Gains };
    const laws = [_]Law{
        .{ .name = "computed torque (feedforward)", .gains = null },
        .{ .name = "spring at 20 Hz             ", .gains = .{ .frequency = 20.0 } },
        .{ .name = "spring at 10 Hz             ", .gains = .{ .frequency = 10.0 } },
        .{ .name = "spring at 40 Hz             ", .gains = .{ .frequency = 40.0 } },
    };
    var worst: [laws.len]f32 = @splat(0.0);
    var mean: [laws.len]f32 = @splat(0.0);
    for (laws, 0..) |law_spec, law| {
        rig.data.reset(m);
        @memcpy(rig.data.pos, clip.pose(1)[root_len..]);
        rbt.differentiatePos(m, rig.data.vel, clip.pose(0)[root_len..], clip.pose(1)[root_len..], dt);
        rig.data.stage = .stale;
        for (1..clip.frame_count - 1) |f| {
            const before: []const f32 = clip.pose(f - 1)[root_len..];
            const now: []const f32 = clip.pose(f)[root_len..];
            const next: []const f32 = clip.pose(f + 1)[root_len..];
            rbt.forward(m, &rig.data);
            rbt.biasForce(m, &rig.data);
            if (law_spec.gains) |gains| {
                pdTorques(m, &rig.data, now, gains, dt, accel, scratch, dense, full, torque);
            } else {
                tracker.accelerations(m, &rig.data, .{ before, now, next }, 20.0, dt, accel);
                rbt.inverseDynamics(m, &rig.data, accel, torque);
            }
            @memcpy(rig.data.applied_force, torque);
            rbt.step(m, &rig.data);
            rbt.forward(m, &rig.data);
            @memcpy(target.pos, next);
            target.stage = .stale;
            rbt.kinematics(m, &target);
            const off: f32 = dance.worstBodyErrorDeg(m, rig.data.body_xrot, target.body_xrot);
            worst[law] = @max(worst[law], off);
            mean[law] += off / float(clip.frame_count - 2);
        }
    }
    for (laws, 0..) |law_spec, law| {
        report.print("  walk, fixed base, {s}: {d:8.3} deg mean, {d:8.3} worst\n", .{
            law_spec.name,
            mean[law],
            worst[law],
        });
    }
    // Computed torque knows where the clip is going next and follows it to a hundredth of a
    // degree. The spring only knows where the clip is NOW, so it lags by a few degrees - and it
    // had better, because a spring that tracked as well as computed torque would mean something is
    // feeding the reference's velocity in behind our backs, and the policy's offsets would have
    // nothing left to do.
    try expect(mean[0] < 0.1);
    try expect(mean[1] > 1.0 and mean[1] < 6.0);
}

test "robot_track: the reward is 1 on the reference and falls from there" {
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const root: usize = 1;
    var reference: State = try .init(gpa, m.nbody);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, m.nbody);
    defer sim.deinit(gpa);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    var rng: std.Random.DefaultPrng = .init(31);
    const random: std.Random = rng.random();
    rig.scatter(random, 0.5);
    stateOf(m, &rig.data, &reference);
    const reference_pose: []f32 = try gpa.dupe(f32, rig.data.pos);
    defer gpa.free(reference_pose);

    // On the reference itself: every term zero, the reward exactly the weights' sum.
    const perfect: TrackingError = trackingError(reference, reference, root);
    try expect(perfect.pose_position == 0.0 and perfect.pose_rotation == 0.0);
    try expect(perfect.root_position == 0.0 and perfect.root_rotation == 0.0);
    try expect(@abs(reward(perfect, .{}) - 1.0) < 1.0e-6);

    // Drifting away from it: every step worse, and the reward monotonically lower.
    var previous: f32 = 1.0;
    var previous_error: f32 = 0.0;
    for ([_]f32{ 0.05, 0.1, 0.2, 0.4, 0.8 }) |scale| {
        for (action, 0..) |*a, k| {
            a.* = if (k % 2 == 0) 1.0 else -1.0;
        }
        applyAction(m, reference_pose, action, scale, scratch, rig.data.pos);
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &sim);
        const err: TrackingError = trackingError(sim, reference, root);
        const value: f32 = reward(err, .{});
        try expect(err.pose_position > previous_error);
        try expect(value < previous);
        previous = value;
        previous_error = err.pose_position;
    }
    // And far enough off, the episode is over - by error, with the character still upright.
    try expect(terminated(trackingError(sim, reference, root), .{}));
}

test "robot_track: worst_body - one limb far off, which the mean cannot see, ends the episode at the limit" {
    // The known answer for plan T2, on synthetic states so every number is exact. Six bodies (0 the world, 1 the
    // root, 2..5 limbs), every rotation the identity; the simulation is the reference with ONE body moved 0.8 m
    // along x. In the root's frame that body is 0.8 m off and the rest exact, so the mean is 0.8 / 5 = 0.16 -
    // comfortably inside the default pose limit (0.35) - while the worst body is 0.8. Height and tilt unchanged.
    const gpa: Allocator = std.testing.allocator;
    const bodies: usize = 6;
    var reference: State = try .init(gpa, bodies);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, bodies);
    defer sim.deinit(gpa);
    for (0..bodies) |b| {
        reference.positions[b] = vec(0.1 * float(b), 0.0, 1.0);
        reference.rotations[b] = qidentity();
        reference.velocities[b] = vec(0.0, 0.0, 0.0);
        reference.angular[b] = vec(0.0, 0.0, 0.0);
        sim.positions[b] = reference.positions[b];
        sim.rotations[b] = reference.rotations[b];
        sim.velocities[b] = reference.velocities[b];
        sim.angular[b] = reference.angular[b];
    }
    const displaced: usize = 3;
    const offset: f32 = 0.8;
    sim.positions[displaced] += vec(offset, 0.0, 0.0);

    const root: usize = 1;
    const err: TrackingError = trackingError(sim, reference, root);
    try expect(@abs(err.worst_body - offset) < 1.0e-6);
    try expect(@abs(err.pose_position - offset / float(bodies - 1)) < 1.0e-6);
    try expect(err.height == 0.0 and err.up == 0.0);

    // The mean-based rule lets it through; a worst-body limit catches it - exactly at the limit.
    try expect(!terminated(err, .{}));
    try expect(terminated(err, .{ .worst_body = offset - 0.01 }));
    try expect(!terminated(err, .{ .worst_body = offset + 0.01 }));
    // `scaled` carries the new limit with every other one: halving 0.9 gives 0.45, under the 0.8 error.
    const leash: Termination = .{ .worst_body = 0.9 };
    try expect(terminated(err, leash.scaled(0.5)));
}

test "robot_track: unexpected contact - a knee down while the reference stands, and nothing else" {
    // The known answer for plan T3, on synthetic states so every number is exact. Five bodies: 0 the world, 1 the
    // root (hips), 2 a thigh, 3 a hand, 4 a foot. Standing, the reference holds the thigh's lowest point (its knee
    // end) at 0.45 m, the hand at 0.75 m, the foot on the floor. Frames and rotations match exactly, so every
    // other term is zero and only the floor heights differ between the cases.
    const gpa: Allocator = std.testing.allocator;
    const bodies: usize = 5;
    var reference: State = try .init(gpa, bodies);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, bodies);
    defer sim.deinit(gpa);
    for (0..bodies) |b| {
        reference.positions[b] = vec(0.0, 0.1 * float(b), 1.0);
        reference.rotations[b] = qidentity();
        reference.velocities[b] = vec(0.0, 0.0, 0.0);
        reference.angular[b] = vec(0.0, 0.0, 0.0);
    }
    const standing = [_]f32{ rbt.no_shape_height, 0.80, 0.45, 0.75, 0.0 };
    @memcpy(reference.lowest, &standing);
    sim.copyFrom(reference);
    const root: usize = 1;
    const thigh: usize = 2;
    const foot: usize = 4;

    // Standing like the reference: the foot is down, but so is the reference's - nothing unexpected.
    try expect(trackingError(sim, reference, root).unexpected_contact == 0.0);

    // The character's knee goes down while the reference stands: the reference's knee height is the reading,
    // and the limit catches it - exactly at the limit.
    sim.lowest[thigh] = 0.0;
    const kneeling: TrackingError = trackingError(sim, reference, root);
    try expect(kneeling.unexpected_contact == 0.45);
    try expect(terminated(kneeling, .{ .unexpected_contact = 0.44 }));
    try expect(!terminated(kneeling, .{ .unexpected_contact = 0.46 }));

    // Both kneeling (a get-up's floor phase): the reference's knee is down too - never flagged.
    reference.lowest[thigh] = 0.0;
    try expect(trackingError(sim, reference, root).unexpected_contact == 0.0);
    reference.lowest[thigh] = 0.45;
    sim.lowest[thigh] = 0.45;

    // A swing the character lags: the reference lifts the foot 0.2 m while the character's is still down. Counted
    // when the foot is judged - and nothing once the foot is exempt, as a robot's feet are.
    reference.lowest[foot] = 0.2;
    try expect(trackingError(sim, reference, root).unexpected_contact == 0.2);
    var exempt: [bodies]bool = @splat(false);
    exempt[foot] = true;
    exemptFromContact(&sim, &exempt);
    try expect(trackingError(sim, reference, root).unexpected_contact == 0.0);

    // A reference with no geometry (a world model's prediction has frames, no shapes) accuses nothing.
    sim.lowest[thigh] = 0.0;
    reference.lowest[thigh] = rbt.no_shape_height;
    try expect(trackingError(sim, reference, root).unexpected_contact == 0.0);
}

test "robot_track: filterAction - a fifth of the new, four fifths of the old; 1 is no filter" {
    // Plan F6's formula, exactly: from rest, asking for 1 three times at DReCon's 0.2 applies 0.2, 0.36, 0.488; at 1
    // the applied action IS the asked one, whatever was applied before.
    var applied = [_]f32{ 0.0, 0.0 };
    const asked = [_]f32{ 1.0, -1.0 };
    filterAction(0.2, &asked, &applied);
    try expectApproxEqAbs(@as(f32, 0.2), applied[0], 1.0e-7);
    filterAction(0.2, &asked, &applied);
    try expectApproxEqAbs(@as(f32, 0.36), applied[0], 1.0e-7);
    filterAction(0.2, &asked, &applied);
    try expectApproxEqAbs(@as(f32, 0.488), applied[0], 1.0e-7);
    try expectApproxEqAbs(@as(f32, -0.488), applied[1], 1.0e-7);
    filterAction(1.0, &asked, &applied);
    try expect(applied[0] == 1.0 and applied[1] == -1.0);
}

test "robot_track: head height - SuperTrack's rule, on the head alone" {
    // Plan F3b's known answers, on synthetic states: the head's height gap is exact and flips the verdict at the
    // limit; any OTHER body's height leaves it at zero; without a head (`trackingError`) there is no head term.
    const gpa: Allocator = std.testing.allocator;
    const bodies: usize = 5;
    var reference: State = try .init(gpa, bodies);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, bodies);
    defer sim.deinit(gpa);
    for (0..bodies) |b| {
        reference.positions[b] = vec(0.0, 0.1 * float(b), 1.0);
        reference.rotations[b] = qidentity();
        reference.velocities[b] = vec(0.0, 0.0, 0.0);
        reference.angular[b] = vec(0.0, 0.0, 0.0);
    }
    sim.copyFrom(reference);
    const root: usize = 1;
    const head: usize = 4;
    sim.positions[head][2] = 1.25; // 25 cm up: exact in binary
    const err: TrackingError = trackingErrorWithHead(sim, reference, root, head);
    try expect(err.head_height == 0.25);
    try expect(terminated(err, .{ .head_height = 0.24 }));
    try expect(!terminated(err, .{ .head_height = 0.26 }));
    try expect(trackingError(sim, reference, root).head_height == 0.0);

    sim.positions[head][2] = 1.0;
    sim.positions[2][2] = 0.5; // another body falls; the head does not
    try expect(trackingErrorWithHead(sim, reference, root, head).head_height == 0.0);

    const names = [_][]const u8{ "", "Hips", "Spine", "Neck", "Head" };
    try expect((try headBody("Head", &names)).? == 4);
    try expect((try headBody("", &names)) == null);
    try expectError(error.UnknownHeadBody, headBody("Haed", &names));
}

test "robot_track: contactExemptMask resolves names, refuses a typo, never matches the world's empty name" {
    const gpa: Allocator = std.testing.allocator;
    const names = [_][]const u8{ "", "Hips", "LeftFoot", "RightFoot" };
    const mask: []bool = try contactExemptMask(gpa, names.len, &.{ "LeftFoot", "RightFoot" }, &names);
    defer gpa.free(mask);
    try expect(!mask[0] and !mask[1] and mask[2] and mask[3]);
    // A name that is not a body is an error, not a silent no-op (the feet would then end every swing).
    try expectError(error.UnknownExemptBody, contactExemptMask(gpa, names.len, &.{"LeftFoott"}, &names));
    // The empty name is the world's (and every anonymous body's): it can never be exempted by accident.
    try expectError(error.UnknownExemptBody, contactExemptMask(gpa, names.len, &.{""}, &names));
    // Nothing to exempt needs no names at all.
    const none: []bool = try contactExemptMask(gpa, names.len, &.{}, &.{});
    defer gpa.free(none);
    try expect(std.mem.indexOfScalar(bool, none, true) == null);
}

test "robot_track: stateOf's per-body lowest points agree with the whole body's lowest point" {
    // The geometry is ONE function (`rbt.geomLowestPoint`); the per-body split must not change what the
    // whole-model minimum is, on a real posed model.
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var rng: std.Random.DefaultPrng = .init(7);
    rig.scatter(rng.random(), 0.5);
    var state: State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    stateOf(m, &rig.data, &state);
    var lowest_of_bodies: f32 = rbt.no_shape_height;
    for (state.lowest) |height| {
        lowest_of_bodies = @min(lowest_of_bodies, height);
    }
    try expect(lowest_of_bodies == rbt.lowestPoint(m, &rig.data));
    try expect(state.lowest[0] == rbt.no_shape_height); // the world body is the floor, never "touching" it
}

test "robot_track: Termination.scaled scales EVERY limit and keeps the grace" {
    // The struct is the list: a limit added to `Termination` must be scaled without anyone editing `scaled`.
    const limits: Termination = .{ .height = 0.4, .up = 0.8, .worst_body = 1.0, .grace_steps = 32 };
    const half: Termination = limits.scaled(0.5);
    const info = @typeInfo(Termination).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (field_type == f32) {
            try expect(@field(half, name) == @field(limits, name) * 0.5);
        }
    }
    try expect(half.grace_steps == 32);
}

test "robot_track: reference-state initialisation lands on the clip" {
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var clip: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 4.0) catch
        return error.SkipZigTest;
    defer clip.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const velocity: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(velocity);
    for ([_]usize{ 0, 1, 37, 120 }) |frame| {
        resetToFrame(m, &rig.data, &clip, frame);
        const at: usize = @max(frame, 1);
        // The pose is the clip's, number for number...
        for (rig.data.pos, clip.pose(at)) |got, want| {
            try expect(got == want);
        }
        // ...and the velocity is the one the clip has there.
        rbt.differentiatePos(m, velocity, clip.pose(at - 1), clip.pose(at), clip.frame_time);
        for (rig.data.vel, velocity) |got, want| {
            try expect(@abs(got - want) < 1.0e-6);
        }
    }
}

test "robot_track: D8 - the reference through the floor, left alone or lifted clear" {
    // THE FLOOR DECISION. Grounding shifts a clip by the median lowest FOOT point, which is a fair
    // rule for walking and a poor one for a clip that lies down: the walk ends up 3 cm through the
    // floor at its deepest, the get-up 10. A tracker cannot reproduce a pose that is inside the
    // floor - the contacts push back - so either the clip is lifted until nothing penetrates, or
    // the reward absorbs the difference.
    //
    // Measured with the ROOT HELD on the reference and the joints servoed: balance is taken out of
    // the question on purpose, because with a free root the character loses the reference in a
    // third of a second either way and the floor never gets a chance to matter. Held, what is left
    // is exactly the question being asked - can the simulation reproduce this reference at all?
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var reference_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer reference_data.deinit();
    var sim: State = try .init(gpa, m.nbody);
    defer sim.deinit(gpa);
    var want: State = try .init(gpa, m.nbody);
    defer want.deinit(gpa);
    const accel: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(accel);
    const torque: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(torque);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    const full: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(full);
    const dense: []f32 = try gpa.alloc(f32, m.nv * m.nv);
    defer gpa.free(dense);

    for ([_][]const u8{ "assets/lafan1/walk1_subject2.bvh", "assets/lafan1/fallAndGetUp2_subject2.bvh" }) |path| {
        const names = [_][]const u8{ "as retargeted", "lifted clear ", "lifted per frame" };
        for (0..3) |option| {
            var clip: dance.Clip = loadClip(gpa, io, path, 12.0) catch return error.SkipZigTest;
            defer clip.deinit();
            var lift: f32 = 0.0;
            if (option == 1) {
                lift = liftAboveFloor(m, &clip, &reference_data);
            } else if (option == 2) {
                lift = try liftPerFrame(gpa, m, &clip, &reference_data, 3.0);
            }
            // How the REFERENCE itself sits against the floor, before anything simulates it: how
            // deep its worst frame goes, and how high it floats in the typical one.
            var reference_deepest: f32 = 0.0;
            var floats: []f32 = try gpa.alloc(f32, clip.frame_count);
            defer gpa.free(floats);
            for (0..clip.frame_count) |f| {
                @memcpy(reference_data.pos, clip.pose(f));
                reference_data.stage = .stale;
                rbt.kinematics(m, &reference_data);
                floats[f] = dance.lowestBodyPoint(m, &reference_data);
                reference_deepest = @min(reference_deepest, floats[f]);
            }
            std.mem.sort(f32, floats, {}, std.sort.asc(f32));
            const typical: f32 = floats[floats.len / 2];
            var mean_error: f32 = 0.0;
            var deepest_sim: f32 = 0.0;
            var starts: f32 = 0.0;
            var start: usize = 30;
            while (start + 121 < clip.frame_count) : (start += 90) {
                resetToFrame(m, &rig.data, &clip, start);
                starts += 1.0;
                var frames: usize = 0;
                var total: f32 = 0.0;
                while (frames < 120 and start + frames + 1 < clip.frame_count) : (frames += 1) {
                    const target: []const f32 = clip.pose(start + frames);
                    rbt.forward(m, &rig.data);
                    rbt.biasForce(m, &rig.data);
                    pdTorques(m, &rig.data, target, .{}, clip.frame_time, accel, scratch, dense, full, torque);
                    @memcpy(rig.data.applied_force, torque);
                    rbt.step(m, &rig.data);

                    // The root is a puppet: put it exactly where the reference has it, with the
                    // reference's own velocity, so nothing here is about balance.
                    const next: []const f32 = clip.pose(start + frames + 1);
                    @memcpy(rig.data.pos[0..7], next[0..7]);
                    rbt.differentiatePos(m, scratch, target, next, clip.frame_time);
                    @memcpy(rig.data.vel[0..6], scratch[0..6]);
                    rig.data.stage = .stale;
                    rbt.forward(m, &rig.data);
                    stateOf(m, &rig.data, &sim);
                    deepest_sim = @min(deepest_sim, dance.lowestBodyPoint(m, &rig.data));
                    @memcpy(reference_data.pos, next);
                    reference_data.stage = .stale;
                    rbt.forward(m, &reference_data);
                    stateOf(m, &reference_data, &want);
                    total += trackingError(sim, want, 1).pose_position;
                }
                mean_error += total / float(@max(frames, 1));
            }
            report.print("\n  D8 {s}, {s}: reference deepest {d:.3} m, typical frame {d:.3} m; " ++
                "sim reaches {d:.3} m; pose error {d:.4} m (lift {d:.3} m)\n", .{
                std.fs.path.basename(path),
                names[option],
                reference_deepest,
                typical,
                deepest_sim,
                mean_error / starts,
                lift,
            });
            // The decision, asserted rather than admired: per-frame lifting is the only option
            // right on BOTH sides - the typical frame on the floor and the deepest one clear of
            // it. Leaving the clip alone buries it; one offset for the whole clip floats it.
            switch (option) {
                0 => try expect(reference_deepest < -0.02),
                1 => try expect(typical > 0.01 and reference_deepest > -0.001),
                else => {
                    try expect(@abs(typical) < 0.01);
                    try expect(reference_deepest > -0.01);
                },
            }
        }
    }
}

/// Raise each FRAME by what that frame needs to clear the floor, smoothed in time.
///
/// A clip's grounding puts the feet on the floor in the typical frame, which leaves the deepest
/// frames underneath it. Raising the whole clip by the deepest of them fixes that and breaks the
/// opposite thing: lift a get-up by the eleven centimetres its lying-down frames need, and its
/// standing frames now float eleven centimetres in the air. Neither a simulation can reproduce.
///
/// So each frame is raised by what it needs and no more - and then the sequence of lifts is
/// smoothed (a Gaussian at `smooth_hz`), because a per-frame correction applied raw is a new source
/// of jitter, and jitter in a reference is force in a tracker. Smoothing gives a little penetration
/// back at the sharpest moments, which is the point of measuring both sides afterwards.
///
/// Returns the largest lift applied. `d` is scratch.
pub fn liftPerFrame(
    gpa: Allocator,
    m: *const rbt.Model,
    clip: *dance.Clip,
    d: *rbt.Data,
    smooth_hz: f32,
) !f32 {
    assertf(
        clip.nq == m.nq and m.njnt > 0 and m.jnt_type[0] == .free,
        @src(),
        "lifting moves the root's height, so the clip must be this model's and the model must have a free root",
        .{},
    );
    const frames: usize = clip.frame_count;
    const needed: []f32 = try gpa.alloc(f32, frames);
    defer gpa.free(needed);
    for (0..frames) |f| {
        @memcpy(d.pos, clip.pose(f));
        d.stage = .stale;
        rbt.kinematics(m, d);
        needed[f] = @max(0.0, -dance.lowestBodyPoint(m, d));
    }
    // A Gaussian over time, the same shape `Clip.smoothed` uses on velocities: sigma frames for a
    // cutoff at `smooth_hz`, truncated where the weight stops mattering.
    const sigma: f32 = 1.0 / (2.0 * pi * smooth_hz * clip.frame_time);
    const reach: usize = @ceil(3.0 * sigma);
    var largest: f32 = 0.0;
    for (0..frames) |f| {
        var sum: f32 = 0.0;
        var weight: f32 = 0.0;
        const from: usize = f -| reach;
        const to: usize = @min(frames - 1, f + reach);
        for (from..to + 1) |k| {
            const dx: f32 = float(@as(i64, @intCast(k)) - @as(i64, @intCast(f))) / sigma;
            const w: f32 = @exp(-0.5 * dx * dx);
            sum += w * needed[k];
            weight += w;
        }
        const lift: f32 = sum / weight;
        clip.targets[f * clip.nq + 2] += lift;
        largest = @max(largest, lift);
    }
    return largest;
}

/// Raise a whole clip until no part of the robot is below the floor, and say by how much.
///
/// The clip's own grounding puts the feet on the floor in the TYPICAL frame, which leaves the
/// deepest frames underneath it - a pose a simulation cannot reproduce, because the floor pushes
/// back. `d` is scratch.
pub fn liftAboveFloor(m: *const rbt.Model, clip: *dance.Clip, d: *rbt.Data) f32 {
    assertf(
        clip.nq == m.nq and m.njnt > 0 and m.jnt_type[0] == .free,
        @src(),
        "lifting moves the root's height, so the clip must be this model's and the model must have a free root",
        .{},
    );
    var deepest: f32 = 0.0;
    for (0..clip.frame_count) |f| {
        @memcpy(d.pos, clip.pose(f));
        d.stage = .stale;
        rbt.kinematics(m, d);
        deepest = @min(deepest, dance.lowestBodyPoint(m, d));
    }
    if (deepest >= 0.0) {
        return 0.0;
    }
    const lift: f32 = -deepest;
    for (0..clip.frame_count) |f| {
        clip.targets[f * clip.nq + 2] += lift;
    }
    return lift;
}

test "robot_track: the awkward cases a network will find" {
    // Everything here is something a half-trained network, or a caller in a hurry, will do sooner
    // or later. None of it may produce a NaN, an infinity, or a silently wrong answer.
    const gpa: Allocator = std.testing.allocator;

    // Two axes that are zero, parallel, tiny or enormous: still a unit rotation, every time.
    const nasty = [_][6]f32{
        .{ 0, 0, 0, 0, 0, 0 },
        .{ 1, 0, 0, 1, 0, 0 }, // parallel
        .{ 1, 0, 0, -1, 0, 0 }, // antiparallel
        .{ 1.0e-9, 0, 0, 0, 1.0e-9, 0 },
        .{ 1.0e9, 0, 0, 0, 1.0e9, 0 },
        .{ 0, 0, 0, 0, 1, 0 }, // only the second axis
        .{ 3, 4, 0, 3, 4, 1.0e-12 }, // very nearly parallel
    };
    for (nasty) |axes| {
        const q: Quat = fromTwoAxis(axes);
        const norm: f32 = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
        try expect(isFinite(norm));
        try expect(@abs(norm - 1.0) < 1.0e-4);
        // And it is a rotation, not a reflection: the axes it produces are right-handed.
        const back: [6]f32 = twoAxis(q);
        const x: Vec = vec(back[0], back[1], back[2]);
        const y: Vec = vec(back[3], back[4], back[5]);
        try expect(@abs(dot3(x, y)) < 1.0e-4);
        try expect(@abs(length3(cross(x, y)) - 1.0) < 1.0e-4);
    }

    // A window's length is its TRANSITIONS, and it spans one more record than that.
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var replay: Replay = try .init(gpa, m, 2, 64);
    defer replay.deinit();
    const pose: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(pose);
    const velocity: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(velocity);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    @memset(pose, 0.0);
    @memset(velocity, 0.0);
    @memset(action, 0.0);
    for (0..40) |k| {
        replay.append(0, pose, velocity, action, @intCast(k), 0, 0);
    }
    var rng: std.Random.DefaultPrng = .init(2);
    const window: Replay.Window = replay.sampleWindow(rng.random(), 8) orelse return error.NoWindow;
    try expect(window.steps == 8);
    try expect(window.frames() == 9);
    // The last frame of the window is a real record, and its predecessor is the one before it -
    // so the window really does hold eight transitions to train on.
    try expect(replay.frameAt(0, window.first + window.steps) == replay.frameAt(0, window.first) + 8);

    // And the world does not move, whatever a world model predicts for it.
    var state: State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    rig.scatter(rng.random(), 0.3);
    stateOf(m, &rig.data, &state);
    const before_position: Vec = state.positions[0];
    const before_rotation: Quat = state.rotations[0];
    const linear: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(linear);
    const angular: []Vec = try gpa.alloc(Vec, m.nbody);
    defer gpa.free(angular);
    for (linear, angular) |*a, *b| {
        a.* = vec(50, -50, 50);
        b.* = vec(50, 50, -50);
    }
    integrate(&state, linear, angular, 1.0 / 60.0);
    try expect(length3(state.positions[0] - before_position) == 0.0);
    try expect(state.rotations[0][3] == before_rotation[3]);
}

test "robot_track: a sampled window never crosses a segment" {
    // THE PROPERTY, drawn ten thousand times. The ring is filled with deliberately awkward
    // material - segments of one frame, of two, of a hundred, wrapping the ring several times over
    // - and every window that comes back has to be one unbroken stretch: the same segment
    // throughout, and consecutive frames, which is what a learner assumes when it rolls a model
    // forward through one.
    const gpa: Allocator = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var replay: Replay = try .init(gpa, m, 4, 128);
    defer replay.deinit();
    const pose: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(pose);
    const velocity: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(velocity);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    @memset(pose, 0.0);
    @memset(velocity, 0.0);
    @memset(action, 0.0);

    var rng: std.Random.DefaultPrng = .init(77);
    const random: std.Random = rng.random();
    var segment: u32 = 0;
    for (0..replay.envs) |env| {
        var frame: u32 = 0;
        var written: usize = 0;
        while (written < 600) {
            // A segment of some awkward length, its frames consecutive.
            const run: usize = 1 + random.uintLessThan(usize, 100);
            for (0..run) |_| {
                replay.append(env, pose, velocity, action, frame, 0, segment);
                frame += 1;
                written += 1;
            }
            segment += 1;
            frame = if (random.boolean()) 0 else frame + 7; // a reset, or a jump: both discontinuities
        }
    }

    var drawn: usize = 0;
    for (0..10_000) |_| {
        const want: usize = 2 + random.uintLessThan(usize, 31);
        const window: Replay.Window = replay.sampleWindow(random, want) orelse continue;
        drawn += 1;
        const first_segment: u32 = replay.segmentAt(window.env, window.first);
        var previous: u32 = replay.frameAt(window.env, window.first);
        for (1..window.frames()) |k| {
            const index: u64 = window.first + k;
            try expect(replay.segmentAt(window.env, index) == first_segment);
            try expect(replay.frameAt(window.env, index) == previous + 1);
            previous += 1;
            // And every record is still IN the ring - not one the writer has since overwritten.
            try expect(index + replay.capacity > replay.written[window.env]);
        }
    }
    report.print("\n  window sampler: {d} of 10000 draws returned a window, all unbroken\n", .{drawn});
    try expect(drawn > 5000);
}

test "robot_track: a fleet tracks, falls, is shoved, and records all of it" {
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};

    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 512, .shove_every = 45 });
    defer fleet.deinit();
    const actions: []f32 = try gpa.alloc(f32, 8 * actionSize(m));
    defer gpa.free(actions);
    const observations: []f32 = try gpa.alloc(f32, 8 * observationSize(m));
    defer gpa.free(observations);
    var rng: std.Random.DefaultPrng = .init(3);
    const random: std.Random = rng.random();

    // No policy yet - noise in its place, which is what the first collection of any of these
    // methods looks like anyway.
    var reward_sum: f32 = 0.0;
    const steps: usize = 600;
    for (0..steps) |_| {
        fleet.observe(observations);
        for (actions) |*a| {
            a.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        reward_sum += fleet.step(actions);
    }
    const mean_reward: f32 = reward_sum / float(steps);

    // Windows drawn out of what it recorded reconstruct into states, and the state a window's
    // action was taken from is the one before the next record - which is the whole contract a world
    // model trains against.
    var reconstructed: usize = 0;
    var worst_gap: f32 = 0.0;
    var sampled: State = try .init(gpa, m.nbody);
    defer sampled.deinit(gpa);
    for (0..200) |_| {
        const window: Replay.Window = fleet.replay.sampleWindow(random, 8) orelse continue;
        reconstructed += 1;
        for (0..window.frames()) |k| {
            @memcpy(scratch_data.pos, fleet.replay.poseAt(window.env, window.first + k));
            @memcpy(scratch_data.vel, fleet.replay.velocityAt(window.env, window.first + k));
            scratch_data.stage = .stale;
            rbt.forward(m, &scratch_data);
            stateOf(m, &scratch_data, &sampled);
            // Nothing in a window may be nonsense: a humanoid a kilometre away, or a velocity no
            // servo could have produced.
            worst_gap = @max(worst_gap, length3(sampled.positions[1]));
            try expect(worst_gap < 100.0);
        }
    }
    // How often each window length can be drawn at all. The world model wants eight frames and the
    // policy thirty-two - and with noise for a policy the character loses the reference in about a
    // third of a second, so the long ones are scarce until it gets better at its job.
    var drawn: [3]usize = .{ 0, 0, 0 };
    const lengths = [_]usize{ 8, 16, 32 };
    for (lengths, 0..) |window_length, k| {
        for (0..200) |_| {
            if (fleet.replay.sampleWindow(random, window_length) != null) {
                drawn[k] += 1;
            }
        }
    }
    report.print("\n  fleet: {d} steps x 8 envs, mean reward {d:.3}, {d} episodes, {d} segments, " ++
        "{d} of 200 windows drawn; draws of 200 at length 8 / 16 / 32: {d} / {d} / {d}\n", .{
        steps,
        mean_reward,
        fleet.episodes,
        fleet.next_segment,
        reconstructed,
        drawn[0],
        drawn[1],
        drawn[2],
    });
    // Noise alone tracks badly and falls often - but it tracks SOMETHING: the reward is well above
    // what a ragdoll scores, and episodes end by losing the reference rather than by running out.
    try expect(mean_reward > 0.2);
    try expect(fleet.episodes > 8);
    try expect(fleet.next_segment > fleet.episodes);
    try expect(reconstructed > 150);
}

test "robot_track: a record remembers which clip it was tracking" {
    // A ring outlives episodes, and an environment picks a new clip whenever it restarts - so a
    // record's targets must be rebuilt from the clip THAT RECORD was tracking, not from whatever
    // its environment is on now. Two clips of different lengths make the difference visible: a
    // frame index past the short clip's end can only belong to the long one, and rebuilding it
    // against the short one would silently clamp to a different pose entirely.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var short: dance.Clip = loadClip(gpa, io, "assets/lafan1/walk1_subject2.bvh", 3.0) catch
        return error.SkipZigTest;
    defer short.deinit();
    var long: dance.Clip = loadClip(gpa, io, "assets/lafan1/run1_subject2.bvh", 12.0) catch
        return error.SkipZigTest;
    defer long.deinit();
    try expect(long.frame_count > short.frame_count + 100);
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const clips = [_]*const dance.Clip{ &short, &long };
    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 400 });
    defer fleet.deinit();
    const actions: []f32 = try gpa.alloc(f32, 8 * actionSize(m));
    defer gpa.free(actions);
    var rng: std.Random.DefaultPrng = .init(41);
    const random: std.Random = rng.random();
    for (0..500) |_| {
        for (actions) |*a| {
            a.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        _ = fleet.step(actions);
    }

    const targets: []f32 = try gpa.alloc(f32, m.nq);
    defer gpa.free(targets);
    const scratch: []f32 = try gpa.alloc(f32, m.nv);
    defer gpa.free(scratch);
    var seen: [2]usize = .{ 0, 0 };
    var beyond_short: usize = 0;
    for (0..fleet.options.envs) |env| {
        const written: u64 = fleet.replay.written[env];
        const oldest: u64 = written -| @as(u64, @intCast(fleet.replay.capacity));
        var index: u64 = oldest;
        while (index < written) : (index += 1) {
            const which: u16 = fleet.replay.clipAt(env, index);
            try expect(which < clips.len);
            seen[which] += 1;
            // Every record's frame is inside the clip it says it came from.
            try expect(fleet.replay.frameAt(env, index) < clips[which].frame_count);
            if (fleet.replay.frameAt(env, index) >= short.frame_count) {
                beyond_short += 1;
                try expect(which == 1);
            }
            // And its targets rebuild without reaching past that clip's end.
            fleet.targetsAt(env, index, scratch, targets);
        }
    }
    report.print("\n  records by clip: {d} short, {d} long; {d} of them past the short clip's end\n", .{
        seen[0],
        seen[1],
        beyond_short,
    });
    // Both clips were used, and enough records sit past the short clip's end that rebuilding them
    // against it could not have gone unnoticed.
    try expect(seen[0] > 100 and seen[1] > 100);
    try expect(beyond_short > 50);
}

test "robot_track: the drift harness, checked with sources that need no training" {
    // THE MEASUREMENT, BEFORE ANYTHING IS MEASURED BY IT. A world model will be judged by how fast
    // its rollout drifts from what the simulator did, so the harness is first shown two sources
    // whose answers are known: the accelerations the simulator actually produced (the floor - only
    // the integrator's own cost remains), and the window's first acceleration held throughout (the
    // baseline a model has to beat). If the floor were not near zero, the harness would be
    // measuring itself.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 12.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};
    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 512 });
    defer fleet.deinit();

    const actions: []f32 = try gpa.alloc(f32, 8 * actionSize(m));
    defer gpa.free(actions);
    var rng: std.Random.DefaultPrng = .init(19);
    const random: std.Random = rng.random();
    for (0..400) |_| {
        for (actions) |*a| {
            a.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        _ = fleet.step(actions);
    }

    // The same windows for both sources: seeded identically, so the curves differ because the
    // sources differ and for no other reason. (Sharing one generator would have drawn a different
    // sample for the second - which is how the first-step agreement below stopped holding.)
    const steps: usize = 8;
    var oracle_rng: std.Random.DefaultPrng = .init(101);
    var baseline_rng: std.Random.DefaultPrng = .init(101);
    const oracle: Drift = try measureDrift(gpa, fleet, .oracle, 200, steps, oracle_rng.random());
    defer freeDrift(gpa, oracle);
    const baseline: Drift = try measureDrift(gpa, fleet, .hold_first, 200, steps, baseline_rng.random());
    defer freeDrift(gpa, baseline);
    report.print("\n  drift over {d} windows, mean body position error (m) by step:\n" ++
        "    oracle     ", .{oracle.windows});
    for (oracle.position) |e| {
        report.print("{d:8.5}", .{e});
    }
    report.print("\n    hold first ", .{});
    for (baseline.position) |e| {
        report.print("{d:8.5}", .{e});
    }
    report.print("\n", .{});

    try expect(oracle.windows > 150 and baseline.windows > 150);
    // The two sources must agree on their first step - the baseline's first acceleration IS the
    // oracle's - and if they ever stop agreeing, the harness has grown a seam.
    try expect(@abs(baseline.position[0] - oracle.position[0]) < 1.0e-6);
    // The floor: fed the simulator's own accelerations, eight steps of an explicit integrator cost
    // a millimetre or two, and nothing else.
    try expect(oracle.position[steps - 1] < 0.01);
    // The baseline drifts, and it drifts more the further it goes - a curve, not a number.
    try expect(baseline.position[steps - 1] > 10.0 * oracle.position[steps - 1]);
    for (1..steps) |k| {
        try expect(baseline.position[k] > baseline.position[k - 1]);
    }
}

test "robot_track: skipping a forward pass that is already current changes nothing" {
    // Two fleets from the same seed. One is given the extra `forward` before every step that the
    // fleet used to do itself; the other relies on the stage watermark to skip it. Over a few
    // hundred steps - through restarts, which make the data stale and so must NOT be skipped - the
    // two must agree to the bit. Anything less and the skip was not an optimisation but a change.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 6.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};
    const careful: *Fleet = try .init(gpa, m, &clips, .{ .envs = 4, .capacity = 16, .seed = 12, .shove_every = 40 });
    defer careful.deinit();
    const quick: *Fleet = try .init(gpa, m, &clips, .{ .envs = 4, .capacity = 16, .seed = 12, .shove_every = 40 });
    defer quick.deinit();
    const actions: []f32 = try gpa.alloc(f32, 4 * actionSize(m));
    defer gpa.free(actions);
    var rng: std.Random.DefaultPrng = .init(8);
    const random: std.Random = rng.random();
    for (0..300) |_| {
        for (actions) |*a| {
            a.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        for (careful.data) |*d| {
            rbt.forward(m, d); // the pass the fleet no longer does when it need not
        }
        _ = careful.step(actions);
        _ = quick.step(actions);
    }
    try expect(careful.episodes == quick.episodes and careful.episodes > 0);
    for (careful.data, quick.data) |a, b| {
        for (a.pos, b.pos) |x, y| {
            try expect(x == y);
        }
        for (a.vel, b.vel) |x, y| {
            try expect(x == y);
        }
    }
}

test "robot_track: the root assist holds the character up, and nothing at zero" {
    // The sign check. An assist wrench with its sign wrong would push the character DOWN, and
    // training under it would just quietly get worse - so: the servo alone, with the root assisted
    // fully, must stay with the reference far longer than without; and at zero the fleet must be
    // bitwise the fleet it always was (the assist is bypassed, not multiplied by zero).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 8.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try rbt.Data.init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const zero: []f32 = try gpa.alloc(f32, 4 * actionSize(m));
    defer gpa.free(zero);
    @memset(zero, 0.0);
    var ended: [2]u64 = undefined;
    for ([_]f32{ 0.0, 1.0 }, 0..) |assist, i| {
        const fleet: *Fleet = try .init(gpa, m, &.{&walk}, .{ .envs = 4, .capacity = 16, .seed = 3 });
        defer fleet.deinit();
        fleet.options.task.gains.assist = assist;
        for (0..300) |_| {
            _ = fleet.step(zero);
        }
        ended[i] = fleet.episodes;
    }
    report.print("\n  root assist: servo alone ended {d} episodes unassisted, {d} with the root held\n", .{
        ended[0],
        ended[1],
    });
    // At least halved. Not more is demanded because episodes also end when the clip runs out, and a
    // character held up well reaches the end sooner - what this guards is the DIRECTION: a wrench
    // with its sign wrong would end more episodes, not fewer. (Measured: 25 unassisted, 10 held.)
    try expect(ended[1] * 2 < ended[0]);
}

/// The walk clip, retargeted onto flex2 and filtered, as every tracking test wants it.
fn loadWalk(gpa: Allocator, io: std.Io) !dance.Clip {
    return loadClip(gpa, io, "assets/lafan1/walk1_subject2.bvh", 10.0);
}

/// Any clip in `assets/lafan1/`, retargeted onto a floating flex2 and filtered at 5 Hz.
fn loadClip(gpa: Allocator, io: std.Io, path: []const u8, seconds: f32) !dance.Clip {
    const capture_bytes: []u8 = try readAll(gpa, io, path);
    defer gpa.free(capture_bytes);
    const rest_bytes: []u8 = try readAll(gpa, io, "assets/lafan1/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, capture_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var floating: Rig = undefined;
    try floating.init(gpa, 1.0 / 60.0);
    defer floating.deinit();
    var raw: dance.Clip = try dance.retargetClip(
        gpa,
        floating.model(),
        floating.imported.names,
        &capture,
        &rest,
        .{ .seconds = seconds },
    );
    defer raw.deinit();
    return raw.smoothed(floating.model(), 5.0);
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

test "robot_track: the gravity gate - a body lying with the right joint angles no longer scores like one standing" {
    // Known answer, built so every root-frame term is EXACTLY zero: a standing pose, then the same pose turned
    // 90 degrees as a rigid whole about its root and lowered to the floor. The old reward cannot tell them apart
    // beyond its two root terms (~0.80); the gated one must, and the height limit must end the episode.
    const gpa: Allocator = std.testing.allocator;
    var standing: State = try .init(gpa, 4);
    defer standing.deinit(gpa);
    var lying: State = try .init(gpa, 4);
    defer lying.deinit(gpa);
    const root: usize = 1;
    const offsets = [_]Vec{ vec(0, 0, 0), vec(0, 0, 0), vec(0, 0, 0.5), vec(0.2, 0, -0.5) };
    const turn: Quat = quatFromAxisAngle(vec(1, 0, 0), 0.5 * pi);
    for (0..4) |b| {
        standing.positions[b] = vec(0, 0, 1) + offsets[b];
        standing.rotations[b] = .{ 0, 0, 0, 1 };
        standing.velocities[b] = vec(0, 0, 0);
        standing.angular[b] = vec(0, 0, 0);
        lying.positions[b] = vec(0, 0, 0.2) + rotate(turn, offsets[b]);
        lying.rotations[b] = turn;
        lying.velocities[b] = vec(0, 0, 0);
        lying.angular[b] = vec(0, 0, 0);
    }
    const err: TrackingError = trackingError(lying, standing, root);
    const gate: RewardWeights = .{ .height_scale = 0.1, .up_scale = 0.5 };
    const perfect: f32 = reward(trackingError(standing, standing, root), gate);
    const blind: f32 = reward(err, .{});
    const gated: f32 = reward(err, gate);
    report.print("\n  gravity gate: lying vs standing - pose error {d:.4} m, height {d:.2} m, up {d:.2}; " ++
        "reward {d:.3} ungated, {d:.5} gated (perfect {d:.3})\n", .{
        err.pose_position,
        err.height,
        err.up,
        blind,
        gated,
        perfect,
    });
    try expect(err.pose_position < 1.0e-5 and err.pose_rotation < 1.0e-3);
    try expect(blind > 0.79);
    try expect(gated < 0.01);
    try expect(@abs(perfect - 1.0) < 1.0e-6);
    try expect(terminated(err, .{ .root_position = 100.0, .root_rotation = 100.0, .height = 0.25 }));
    try expect(!terminated(err, .{ .root_position = 100.0, .root_rotation = 100.0 }));
}
