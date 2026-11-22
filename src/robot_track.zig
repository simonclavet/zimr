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
const rbt = @import("robot");
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
const isFinite = zm.isFinite;
const float = zm.float;
const float64 = zm.float64;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const expectEqual = std.testing.expectEqual;
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
const assertUnreachable = zm.assertUnreachable;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const Io = std.Io;
const Random = std.Random;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const indexOfScalar = std.mem.indexOfScalar;
const sortSlice = std.mem.sort;
const eql = std.mem.eql;
const ArrayList = std.ArrayList;
const expectEqualSlices = std.testing.expectEqualSlices;

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

/// A body's index by name. The empty name never matches (it is the world's, and every anonymous body's). One
/// search for every per-robot name a task carries (`contact_exempt`, `head_body`).
fn bodyIndexByName(body_names: []const []const u8, wanted: []const u8) ?usize {
    for (body_names, 0..) |name, b| {
        if (name.len > 0 and eql(u8, name, wanted)) {
            return b;
        }
    }
    return null;
}

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

/// Take the exempt bodies out of contact judgement: their lowest point reads as "no shape", which never touches.
/// Applied to the CHARACTER's state only - the reference's heights stay, for the bodies that are judged.
pub fn exemptFromContact(state: *State, exempt: []const bool) void {
    for (exempt, 0..) |is_exempt, b| {
        if (is_exempt) {
            state.lowest[b] = rbt.no_shape_height;
        }
    }
}

/// Read the state out of a forward-current `Data` - the simulator's, or a clip frame's after
/// `rbt.forward`.
pub fn stateOf(m: *const rbt.Model, d: *const rbt.Data, out: *State) void {
    // The state is read from the bodies' poses and velocities: refused if they are not current (a velocity written
    // behind the simulator's back with nothing recomputed), rather than read from before the change.
    d.requireStage(.velocity, "stateOf");
    assertf(
        out.bodies() == m.body_count,
        @src(),
        "state has {d} bodies, model has {d}",
        .{ out.bodies(), m.body_count },
    );
    for (0..m.body_count) |b| {
        out.positions[b] = d.body_positions[b];
        out.rotations[b] = d.body_orientations[b];
        out.velocities[b] = dance.pointVelocity(m, d, b, d.body_positions[b]);
        out.angular[b] = d.body_velocities[b].ang;
    }
    rbt.bodyLowestPoints(m, d, out.lowest);
}

/// How many numbers `local` writes (`rbt.localSize`, in robot.zig so the device's observation shares it).
pub const localSize = rbt.localSize;

/// Where body `body`'s height sits in `local`'s output, for a model of `bodies` bodies (the world, body 0, among them):
/// the blocks in `local`'s own order are every character body's position (3 numbers), its rotation's two axes (6), its
/// velocity (3), its angular velocity (3), its height (1), then the world's up (3).
pub fn localHeightColumn(bodies: usize, body: usize) usize {
    return (bodies - 1) * (3 + 6 + 3 + 3) + (body - 1);
}

/// The world's up's first column (`localHeightColumn`).
pub fn localUpColumn(bodies: usize) usize {
    return (bodies - 1) * (3 + 6 + 3 + 3 + 1);
}

/// Where body `body`'s position's first number sits in `local`'s output (`localHeightColumn`'s blocks): the first
/// block.
pub fn localPositionColumn(bodies: usize, body: usize) usize {
    assertf(body > 0 and body < bodies, @src(), "body {d} of {d}: a character body", .{ body, bodies });
    return (body - 1) * 3;
}

/// Where body `body`'s rotation's two axes begin (`localHeightColumn`'s blocks): after every body's position.
pub fn localRotationColumn(bodies: usize, body: usize) usize {
    return (bodies - 1) * 3 + (body - 1) * 6;
}

/// Where body `body`'s velocity's first number sits in `local`'s output (`localHeightColumn`'s blocks): after every
/// body's position and two axes. In the root's frame, as every block is - for the root itself, its own velocity in its
/// own frame, which the root in imagination integrates (robot_latent_kit's `ImaginedRoot`).
pub fn localVelocityColumn(bodies: usize, body: usize) usize {
    return (bodies - 1) * (3 + 6) + (body - 1) * 3;
}

/// Where body `body`'s angular velocity's first number sits (`localVelocityColumn`): after every body's velocity.
pub fn localAngularColumn(bodies: usize, body: usize) usize {
    return (bodies - 1) * (3 + 6 + 3) + (body - 1) * 3;
}

/// How the ROOT's COST in the policy's loss weighs against the bodies' features, each a share of the bodies' weight:
/// the root's position against the bodies' positions, its rotation against theirs.
pub const RootCostShares = extern struct {
    /// SuperMimic's reward weighs its root's two terms at half its body terms (`rbt.SuperMimicScales`: a root weight
    /// of 0.5 against a body weight of 1, at the same scales, 0.3 m and 0.4 rad).
    position: f32 = 0.5,
    rotation: f32 = 0.5,
};

/// The root's cost's two weights (`rootCostWeights`): per m^2 of the roots' squared distance, and per unit of the
/// squared change of the root's two axes.
pub const RootCostWeights = struct {
    position: f32,
    rotation: f32,
};

/// THE ROOT's COST's WEIGHTS (robot_latent_kit's `ImaginedRoot`): the weight on the squared distance between the
/// imagined root and the reference's (per m^2), and on the squared change of the root's two axes (`zm.poseSeenFrom`'s
/// last six numbers), set so that the root weighs against the bodies in the policy's loss as SuperMimic's reward
/// weighs its root against its bodies (`RootCostShares`).
///
/// SuperMimic's terms are w exp(-e / s^2), so near the reference each costs w / s^2 for each unit of its squared error
/// e: the bodies' positions 1 / 0.3^2 per m^2 of their mean squared distance, the root's 0.5 / 0.3^2 per m^2 - a half.
/// Our loss is a mean over the F normalised features, (1 / F) sum (dx / spread)^2, and the bodies' positions are 3 of
/// them a body. With each number's error in proportion to its spread - errors as large as the motion the number shows
/// - the N character bodies other than the root cost (N / F) / v per m^2 of their mean squared distance, v the mean
/// variance (spread^2) of their position numbers. So the root's position costs `shares.position` of that:
///
///     w_position = share x (N / F) / mean variance of the bodies' position numbers
///
/// The rotations alike: a small turn of angle t about an axis at random moves a rotation's two axes by 4/3 t^2 on
/// average (squared and summed), so the bodies' rotations cost (4/3)(N / F) / v per rad^2, the root's six numbers
/// 4/3 t^2 w_rotation, and
///
///     w_rotation = share x (N / F) / mean variance of the bodies' rotation numbers
///
/// The root's own position and two axes are left out: in its own frame they never move, their spreads floored. A
/// mean of variances, not of their inverses, so the bodies whose numbers move least - near the root - do not decide
/// it. `spreads` is a feature normaliser's (`localSize(bodies)` of them).
pub fn rootCostWeights(
    spreads: []const f32,
    bodies: usize,
    root: usize,
    shares: RootCostShares,
) RootCostWeights {
    assertf(spreads.len == localSize(bodies), @src(), "{d} spreads for {d} features", .{
        spreads.len,
        localSize(bodies),
    });
    var position_variance_sum: f64 = 0;
    var rotation_variance_sum: f64 = 0;
    var measured_bodies: usize = 0;
    for (1..bodies) |body| {
        if (body == root) {
            continue;
        }
        const position_at: usize = localPositionColumn(bodies, body);
        const rotation_at: usize = localRotationColumn(bodies, body);
        for (spreads[position_at..][0..3]) |spread| {
            position_variance_sum += @as(f64, spread) * @as(f64, spread);
        }
        for (spreads[rotation_at..][0..6]) |spread| {
            rotation_variance_sum += @as(f64, spread) * @as(f64, spread);
        }
        measured_bodies += 1;
    }
    assertf(measured_bodies > 0, @src(), "a model of {d} bodies: none beside the root to weigh it against", .{bodies});
    const body_count: f64 = @floatFromInt(measured_bodies);
    const feature_count: f64 = @floatFromInt(spreads.len);
    const position_variance: f64 = position_variance_sum / (3.0 * body_count);
    const rotation_variance: f64 = rotation_variance_sum / (6.0 * body_count);
    const bodies_per_feature: f64 = body_count / feature_count;
    const weights: RootCostWeights = .{
        .position = @floatCast(shares.position * bodies_per_feature / position_variance),
        .rotation = @floatCast(shares.rotation * bodies_per_feature / rotation_variance),
    };
    return weights;
}

fn writeVec(out: []f32, at: *usize, v: Vec) void {
    out[at.*] = v[0];
    out[at.* + 1] = v[1];
    out[at.* + 2] = v[2];
    at.* += 3;
}

/// A vector's three numbers into `out` from `at`.
fn writeVecAt(out: []f32, at: usize, v: Vec) void {
    out[at] = v[0];
    out[at + 1] = v[1];
    out[at + 2] = v[2];
}

/// A rotation as two axes (`zm.twoAxis`, where the device's observation and the kit's kernels share it).
pub const twoAxis = zm.twoAxis;

/// The state as a network sees it: everything in the root's frame, heights and up kept in world - each body's
/// features by `rbt.localBody`, laid out by kind, every body's position first, then every body's rotation, velocity,
/// angular velocity and height, and last the world's up seen from the root:
///
///     positions    3 per body     the body's position less the root's, in the root's frame
///     rotations    6 per body     the body's rotation in the root's frame, as two axes
///     velocities   3 per body     the velocity of the body's frame origin, in the root's frame
///     angular      3 per body     the body's angular velocity, in the root's frame
///     heights      1 per body     the body's height, in world
///     up           3              the world's up, in the root's frame
///
/// over the character's bodies - all but the world. `root` is the character's root body. `out` must be
/// `localSize(bodies)` long. The device writes the same layout from the same functions (robotgpu's
/// `observe_character`).
pub fn local(state: State, root: usize, out: []f32) void {
    assertf(out.len == localSize(state.bodies()), @src(), "local wants {d} numbers, got {d}", .{
        localSize(state.bodies()),
        out.len,
    });
    // Body 0 is the world. Rooting at it would leave every position in world space - the
    // representation would look fine and quietly carry the character's absolute position.
    assertf(root > 0 and root < state.bodies(), @src(), "root body {d} is not a character body", .{root});
    const to_local: Quat = conjugate(state.rotations[root]);
    const origin: Vec = state.positions[root];
    const layout: rbt.LocalLayout = .of(@intCast(state.bodies()));
    const rotations_at: usize = layout.rotations_at;
    const velocities_at: usize = layout.velocities_at;
    const angular_at: usize = layout.angular_at;
    const heights_at: usize = layout.heights_at;
    const up_at: usize = layout.up_at;
    for (1..state.bodies()) |b| {
        const features: rbt.LocalBody = rbt.localBody(
            to_local,
            origin,
            state.positions[b],
            state.rotations[b],
            state.velocities[b],
            state.angular[b],
        );
        const index: usize = b - 1;
        writeVecAt(out, 3 * index, features.position);
        @memcpy(out[rotations_at + 6 * index ..][0..6], &features.rotation);
        writeVecAt(out, velocities_at + 3 * index, features.velocity);
        writeVecAt(out, angular_at + 3 * index, features.angular);
        out[heights_at + index] = features.height;
    }
    // The world's up, in the root's frame: everything else here is blind to how the character is
    // tilted, and this is what tells it.
    writeVecAt(out, up_at, rotate(to_local, vec(0, 0, 1)));
}

/// Two axes back to a rotation (`zm.fromTwoAxis`): one definition for the learners and the device.
pub const fromTwoAxis = zm.fromTwoAxis;

/// The rotation an angular velocity produces over `dt` (exact for a constant `w`).
fn rotationOver(w: Vec, dt: f32) Quat {
    const speed: f32 = length3(w);
    if (speed < 1.0e-12) {
        return .{ 0, 0, 0, 1 };
    }
    return quatFromNormAxisAngle(w / splat(speed), speed * dt);
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

/// The character's root body (`rbt.rootBody`, in robot.zig so the device's observation shares it).
pub const rootBody = rbt.rootBody;

/// The degrees of freedom the free root owns, which nothing actuates (0 if the model has no free
/// joint - a welded-root copy of the same robot).
pub fn rootDofs(m: *const rbt.Model) usize {
    return rbt.rootDofCount(m);
}

/// How many numbers a policy's action has (`rbt.actionSize`, in robot.zig beside the action's use).
pub const actionSize = rbt.actionSize;

/// HOW MANY NUMBERS A FLEET's ACTION HAS: the joints' target offsets (`actionSize`), then - with its limbs' stiffness
/// on - one per limb (`rbt.Model.limb_count`), each limb's stiffness s in [-1, 1] (`rbt.limbSpringFrequency`). The
/// device's action has the same layout (robotgpu's `action_count`).
pub fn actionWidth(m: *const rbt.Model, limb_stiffness: bool) usize {
    const joint_numbers: usize = actionSize(m);
    const limb_numbers: usize = if (limb_stiffness) m.limb_count else 0;
    return joint_numbers + limb_numbers;
}

/// The action filter (`rbt.filterAction`, in robot.zig so the device's kernel shares it).
pub const filterAction = rbt.filterAction;

/// The servo's targets for one step: the reference pose, nudged by the policy's action (`rbt.applyAction`, in
/// robot.zig so the device's kernel shares it).
pub const applyAction = rbt.applyAction;

/// Every hinge put back inside its range (`rbt.clampHinges`, in robot.zig so the device's kernel shares it).
pub const clampHinges = rbt.clampHinges;

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

    /// The servo's law these gains give (`rbt.ServoLaw`) - the spring and its bound, which robot.zig's servo and the
    /// device's take; the root's assist and the feedforward are the CPU tracker's own.
    pub fn law(gains: Gains) rbt.ServoLaw {
        const servo_law: rbt.ServoLaw = .{
            .frequency = gains.frequency,
            .damping = gains.damping,
            .max_acceleration = gains.max_acceleration,
        };
        return servo_law;
    }
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
    const root_len: usize = clip.nq - m.coordinate_count;
    rbt.differentiatePos(m, out, clip.pose(f)[root_len..], clip.pose(f + 1)[root_len..], clip.frame_time);
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
        const want: f32 = rmx.stableSpringAccel(scratch[k], d.joint_velocities[k], gains.frequency, gains.damping, dt);
        accel_scratch[k] = clamp(want, -gains.max_acceleration, gains.max_acceleration);
    }
    rbt.massMatrixDense(m, d, dense);
    for (0..root) |row| {
        var wrench: f32 = d.bias_joint_forces[row];
        for (0..m.dof_count) |col| {
            wrench += dense[row * m.dof_count + col] * accel_scratch[col];
        }
        out[row] = gains.assist * wrench;
    }
}

/// `pdTorques` with VELOCITY FEEDFORWARD when `target_velocity` is given (`m.dof_count` long, the velocity the body
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
    limbs: ?rbt.LimbStiffness,
    dt: f32,
    accel_scratch: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    out: []f32,
) void {
    // The servo's law is robot.zig's (`rbt.servoTorques`), the one robotgpu's kernels run - each limb's spring at its
    // own stiffness where `limbs` gives one; the root's assist is the CPU tracker's own.
    rbt.servoTorques(m, d, target, target_velocity, gains.law(), limbs, dt, accel_scratch, scratch, dense, full, out);
    const has_free_root: bool = rootDofs(m) > 0;
    if (has_free_root and gains.assist > 0.0) {
        rootAssist(m, d, gains, dt, scratch, accel_scratch, dense, out);
    }
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
/// `d` must be forward-current with `rbt.biasForce` already called. `scratch` is `m.dof_count`, `dense`
/// is `m.dof_count * m.dof_count`, `full` is `m.dof_count` (both are only touched when the root is free).
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
    pdTorquesToward(m, d, target, null, gains, null, dt, accel_scratch, scratch, dense, full, out);
}

/// THE TRACKER's JUDGEMENT, in robot.zig so the device judges with the same definition: the tracking error, the
/// rewards, SuperMimic's terms and the termination rule (robot.zig's section "THE TRACKER's JUDGEMENT"), each body
/// read through `rbt.BodySlices` - a `State`'s slices.
pub const TrackingError = rbt.TrackingError;
pub const contact_band = rbt.contact_band;
pub const RewardWeights = rbt.RewardWeights;
pub const reward = rbt.reward;
pub const SuperMimicScales = rbt.SuperMimicScales;
pub const SuperMimicTracking = rbt.SuperMimicTracking;
pub const superMimicActionRate = rbt.superMimicActionRate;
pub const superMimicJointLimitExcess = rbt.superMimicJointLimitExcess;
pub const Termination = rbt.Termination;
pub const terminated = rbt.terminated;
const angleBetween = rbt.angleBetween;

/// A `State` as the judgement reads bodies.
fn bodiesOf(state: State) rbt.BodySlices {
    const slices: rbt.BodySlices = .{
        .positions = state.positions,
        .rotations = state.rotations,
        .velocities = state.velocities,
        .angular_velocities = state.angular,
        .lowest_points = state.lowest,
    };
    return slices;
}

/// The tracking error of `sim` against `reference` (`rbt.trackingErrorOver`), with the head's height where `head`
/// names it.
pub fn trackingErrorWithHead(
    sim: State,
    reference: State,
    root: usize,
    head: ?usize,
) TrackingError {
    return rbt.trackingErrorOver(rbt.BodySlices, bodiesOf(sim), bodiesOf(reference), root, head);
}

/// SuperMimic's tracking reward of `sim` against `reference` (`rbt.superMimicTrackingOver`).
pub fn superMimicTracking(
    sim: State,
    reference: State,
    root: usize,
    scales: SuperMimicScales,
) SuperMimicTracking {
    return rbt.superMimicTrackingOver(rbt.BodySlices, bodiesOf(sim), bodiesOf(reference), root, scales);
}

/// HOW TRACKING QUALITY IS JUDGED - BlinkMimic's measures (its `tools/eval_metrics.py`), on our robot's geometry.
/// BlinkMimic counts its robot's ankle link as touching the floor when the link's origin is within 12 mm of its
/// flat-foot height; we read each foot body's own lowest point (`State.lowest`), so the same 12 mm is measured from
/// the floor itself, whatever the robot's feet.
pub const QualityRule = struct {
    /// A foot body touches the floor while its lowest point is below this height, in m.
    contact_height: f32 = 0.012,
};

/// ONE DECISION's TRACKING QUALITY for one character (`measureQuality`), the character and its reference after the
/// decision. The feet are the task's floor-touching bodies (`Task.contact_exempt`).
pub const QualityStep = struct {
    /// SuperMimic's errors: the bodies' re-anchored positions (m^2) and rotations (rad^2), the mean over the bodies;
    /// the root's distance from the reference's (m), drift and all.
    body_position_error: f32 = 0,
    body_rotation_error: f32 = 0,
    root_distance: f32 = 0,
    /// The joints' mean error, in radians: a hinge's angle difference, a ball's angle between the two rotations.
    joint_error: f32 = 0,
    /// The foot bodies looked at, and those whose contact - touching the floor, or not - is the reference's.
    feet: u32 = 0,
    contacts_agreeing: u32 = 0,
    /// The feet touching the floor, and their horizontal speeds summed (m/s): a foot that slides while it stands.
    /// The same for the reference, whose own slip - from its capture and retargeting - is the floor no policy can
    /// be asked to go below.
    contacts: u32 = 0,
    slip_speed_sum: f32 = 0,
    reference_contacts: u32 = 0,
    reference_slip_speed_sum: f32 = 0,
    /// How deep the feet are below the floor, in m: the mean over the feet of each one's depth, 0 above it.
    penetration: f32 = 0,
};

/// THE QUALITY OF ONE DECISION (`QualityStep`) but its joints' (`jointError`): `sim` and `reference` whole-body
/// states after it - `sim` read before any body is exempted from contact, so its feet's lowest points are their own -
/// the feet as the task's floor-touching bodies (`feet`, one flag a body), and the rule.
pub fn measureQuality(
    sim: State,
    reference: State,
    root: usize,
    feet: []const bool,
    rule: QualityRule,
) QualityStep {
    const scales: SuperMimicScales = .{};
    const tracking: SuperMimicTracking = superMimicTracking(sim, reference, root, scales);
    var step: QualityStep = .{
        .body_position_error = tracking.body_position_error,
        .body_rotation_error = tracking.body_rotation_error,
        .root_distance = @sqrt(tracking.root_position_error),
    };
    // The feet.
    var penetration_sum: f32 = 0;
    for (feet, 0..) |is_foot, body| {
        if (!is_foot) {
            continue;
        }
        step.feet += 1;
        const touches: bool = sim.lowest[body] < rule.contact_height;
        const reference_touches: bool = reference.lowest[body] < rule.contact_height;
        step.contacts_agreeing += @intFromBool(touches == reference_touches);
        if (touches) {
            const velocity: Vec = sim.velocities[body];
            step.contacts += 1;
            step.slip_speed_sum += @sqrt(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
        }
        if (reference_touches) {
            const reference_velocity: Vec = reference.velocities[body];
            step.reference_contacts += 1;
            const reference_speed_squared: f32 =
                reference_velocity[0] * reference_velocity[0] + reference_velocity[1] * reference_velocity[1];
            step.reference_slip_speed_sum += @sqrt(reference_speed_squared);
        }
        penetration_sum += @max(-sim.lowest[body], 0);
    }
    step.penetration = penetration_sum / float(@max(step.feet, 1));
    return step;
}

/// THE JOINTS' MEAN ERROR, in radians, over every joint but the free root: a hinge's angle difference (a slide's
/// distance, in m), a ball's angle between its rotation and the reference's.
pub fn jointError(
    m: *const rbt.Model,
    joint_positions: []const f32,
    reference_joint_positions: []const f32,
) f32 {
    var joint_error_sum: f32 = 0;
    var joints_measured: u32 = 0;
    for (0..m.joint_count) |joint| {
        const first: usize = m.joint_first_coordinate[joint];
        const joint_error: f32 = switch (m.joint_type[joint]) {
            .free => continue,
            .ball => ball: {
                const own: Quat = joint_positions[first..][0..4].*;
                const wanted: Quat = reference_joint_positions[first..][0..4].*;
                break :ball angleBetween(own, wanted);
            },
            .hinge, .slide => @abs(joint_positions[first] - reference_joint_positions[first]),
        };
        joint_error_sum += joint_error;
        joints_measured += 1;
    }
    return joint_error_sum / float(@max(joints_measured, 1));
}

/// Degrees in a radian, for the quality's reports.
const degrees_per_radian: f64 = 180.0 / pi;

/// A JUDGEMENT's TRACKING QUALITY: its decisions' `QualityStep`s summed, over every start's first episode while it
/// lasted - and the means BlinkMimic reports, in its units.
pub const QualitySums = struct {
    steps: usize = 0,
    body_position_error_sum: f64 = 0,
    body_rotation_error_sum: f64 = 0,
    root_distance_sum: f64 = 0,
    joint_error_sum: f64 = 0,
    foot_steps: usize = 0,
    contacts_agreeing: usize = 0,
    contacts: usize = 0,
    slip_speed_sum: f64 = 0,
    reference_contacts: usize = 0,
    reference_slip_speed_sum: f64 = 0,
    penetration_sum: f64 = 0,

    pub fn add(sums: *QualitySums, step: QualityStep) void {
        sums.steps += 1;
        sums.body_position_error_sum += step.body_position_error;
        sums.body_rotation_error_sum += step.body_rotation_error;
        sums.root_distance_sum += step.root_distance;
        sums.joint_error_sum += step.joint_error;
        sums.foot_steps += step.feet;
        sums.contacts_agreeing += step.contacts_agreeing;
        sums.contacts += step.contacts;
        sums.slip_speed_sum += step.slip_speed_sum;
        sums.reference_contacts += step.reference_contacts;
        sums.reference_slip_speed_sum += step.reference_slip_speed_sum;
        sums.penetration_sum += step.penetration;
    }

    /// The bodies' position error, the root mean square over the decisions, in cm.
    pub fn bodyPositionCm(sums: QualitySums) f32 {
        return @floatCast(100 * @sqrt(sums.body_position_error_sum / float64(@max(sums.steps, 1))));
    }

    /// The bodies' rotation error, the root mean square over the decisions, in degrees.
    pub fn bodyRotationDegrees(sums: QualitySums) f32 {
        return @floatCast(degrees_per_radian * @sqrt(sums.body_rotation_error_sum / float64(@max(sums.steps, 1))));
    }

    /// The root's mean distance from the reference's, in cm.
    pub fn rootDistanceCm(sums: QualitySums) f32 {
        return @floatCast(100 * sums.root_distance_sum / float64(@max(sums.steps, 1)));
    }

    /// The joints' mean error, in degrees.
    pub fn jointDegrees(sums: QualitySums) f32 {
        return @floatCast(degrees_per_radian * sums.joint_error_sum / float64(@max(sums.steps, 1)));
    }

    /// The feet's mean horizontal speed while touching the floor, in cm/s.
    pub fn footSlipCmPerSecond(sums: QualitySums) f32 {
        return @floatCast(100 * sums.slip_speed_sum / float64(@max(sums.contacts, 1)));
    }

    /// The reference's own foot slip, in cm/s.
    pub fn referenceFootSlipCmPerSecond(sums: QualitySums) f32 {
        return @floatCast(100 * sums.reference_slip_speed_sum / float64(@max(sums.reference_contacts, 1)));
    }

    /// The share of feet, decision by decision, touching the floor exactly when the reference's do.
    pub fn contactAgreement(sums: QualitySums) f32 {
        return float(sums.contacts_agreeing) / float(@max(sums.foot_steps, 1));
    }

    /// The feet's mean depth below the floor, in mm.
    pub fn penetrationMm(sums: QualitySums) f32 {
        return @floatCast(1000 * sums.penetration_sum / float64(@max(sums.steps, 1)));
    }
};

/// Measure one against the other. Both states are whole-body states in world space (`stateOf`);
/// `root` is the character's root body.
pub fn trackingError(sim: State, reference: State, root: usize) TrackingError {
    return trackingErrorWithHead(sim, reference, root, null);
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
/// PERTURBED STARTS (D5.5 - DReCon randomised its starts): how far an episode's first state is pushed
/// off the reference. Zero is the reference itself.
pub const StartNoise = struct {
    /// Radians: every non-root joint turned by a random rotation vector, this spread per axis.
    pose: f32 = 0.0,
    /// m/s: a kick to the root, this spread per horizontal axis (a random direction and size).
    velocity: f32 = 0.0,
};

/// WHERE A START's NOISE COMES FROM (`perturbStart`): its `index`th standard normal number - counter-based (`drawn`:
/// the fleet's, and the device's, the start's own draws) or a stream (`stream`: robot_geno's planners, bit for bit as
/// before; the index unused).
pub const NoiseSource = union(enum) {
    drawn: struct { seed: u32, world: u32, episode: u32 },
    stream: Random,

    /// The source's `index`th standard normal number.
    pub fn normal(source: NoiseSource, index: u32) f32 {
        switch (source) {
            .drawn => |drawn| return rbt.drawNormal(drawn.seed, drawn.world, drawn.episode, .start_noise, index),
            .stream => |random| return random.floatNorm(f32),
        }
    }
};

/// Push a state off its reference by `noise`, then rest it on the floor again - a perturbed pose must not start
/// inside the ground. The pose goes through the model's own `integratePos` (the path `applyAction` turns offsets
/// by); the kick lands on the root's linear velocity, x and y (z is up). With no noise it does nothing at all and
/// draws no random numbers, so a fleet without noise behaves bit for bit as before. It rests `clearance` above the
/// floor afterwards (the task's `rest_clearance`, as the device's rest after noise). Its normal numbers from `source`:
/// each actuated dof's turn its dof's index, the two kicks the next two. `scratch`: at least nv long.
pub fn perturbStart(
    m: *const rbt.Model,
    d: *rbt.Data,
    noise: StartNoise,
    source: NoiseSource,
    clearance: f32,
    scratch: []f32,
) void {
    if (noise.pose == 0.0 and noise.velocity == 0.0) {
        return;
    }
    const turns: []f32 = scratch[0..m.dof_count];
    @memset(turns, 0.0);
    if (noise.pose > 0.0) {
        for (turns[rootDofs(m)..], rootDofs(m)..) |*turn, dof| {
            turn.* = noise.pose * source.normal(@intCast(dof));
        }
        rbt.integratePos(m, d.joint_positions, turns, 1.0);
    }
    if (noise.velocity > 0.0) {
        const kicks_at: u32 = @intCast(m.dof_count);
        d.joint_velocities[0] += noise.velocity * source.normal(kicks_at);
        d.joint_velocities[1] += noise.velocity * source.normal(kicks_at + 1);
    }
    // The turned pose's kinematics first: the rest measures the lowest point from the bodies' and geoms' frames,
    // which the turns have moved - resting on the old frames would leave a turned foot in the floor, or lift too far.
    d.stage = .stale;
    rbt.forward(m, d);
    _ = rbt.restOnFloor(m, d, clearance);
    rbt.forward(m, d);
}

/// How an episode ended: its reference LOST (a failure - no future), the step CAP reached, or its CLIP ran
/// out (both cut short - a future the episode would have had), or its AFTERMATH over: the reference was lost some
/// steps before, and the character lived on through its fall (`Fleet.Options.aftermath_steps`) until now - a failure
/// that is over, and an episode cut, since the steps after the loss are in the data.
pub const End = enum { lost, cap, clip_end, aftermath };

pub fn resetToFrame(
    m: *const rbt.Model,
    d: *rbt.Data,
    clip: *const dance.Clip,
    frame: usize,
) void {
    const at: usize = @max(frame, 1);
    const root_len: usize = clip.nq - m.coordinate_count;
    d.reset(m);
    @memcpy(d.joint_positions, clip.pose(at)[root_len..]);
    rbt.differentiatePos(
        m,
        d.joint_velocities,
        clip.pose(at - 1)[root_len..],
        clip.pose(at)[root_len..],
        clip.frame_time,
    );
    d.stage = .stale;
    rbt.forward(m, d);
}

/// Where a window drawn from a `Replay` may start (`Replay.sampleWindowStarting`).
pub const WindowStart = enum {
    /// Anywhere in a segment - the world model's windows: it learns from every step, falls included.
    anywhere,
    /// Only on a step taken before its episode lost the reference - a pathwise policy loss's windows, which start
    /// where tracking still means something (they may run on into the loss).
    before_loss,
    /// Only on a step taken AFTER its episode lost the reference - inside an aftermath, where a character with returns
    /// on (`Fleet.Options.return_steps`) is on its way back to a reference still running: the policy's windows over
    /// returns.
    after_loss,
};

/// WHAT WAS APPLIED JUST BEFORE A RECORD (`Replay.Books.appliedBeforeAt`): rest - every episode opens from it - or the
/// action recorded one step earlier.
pub const AppliedBefore = enum { rest, previous_record };

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
    action_width: usize,
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
    /// How far into its EPISODE each record's step was - 0 on an episode's first step - or null for a record that
    /// is not a step of a rollout at all (a teacher's label, a probe's state: `append`). The segment cannot stand in
    /// for it: a segment ends at a SHOVE as well as at a restart, and a shove ends neither the episode nor what the
    /// controller is applying. This can say what was being applied before a record: rest on an episode's first
    /// step, otherwise the action recorded one step earlier, shove or no shove.
    episode_steps: []?u32,
    /// Whether each record's step came AFTER its episode lost the reference - in the aftermath its fleet lets a lost
    /// character live through (`Fleet.Options.aftermath_steps`). A world model learns from these rows (how a body falls
    /// is knowledge); a pathwise policy loss does not start a window on one (`WindowStart.before_loss`): its tracking
    /// gradients through a fall saturate to nothing.
    after_loss: []bool,
    /// How many records this environment has ever written. The ring holds the last `capacity`.
    written: []u64,

    /// `envs` rings of `capacity` records each, every record an action of `action_width` numbers (its fleet's,
    /// `actionWidth`) beside the model's pose and velocity.
    pub fn init(
        gpa: Allocator,
        m: *const rbt.Model,
        envs: usize,
        capacity: usize,
        action_width: usize,
    ) !Replay {
        assertf(envs > 0 and capacity > 1, @src(), "{d} environments of {d} records makes no ring", .{
            envs,
            capacity,
        });
        const slots: usize = envs * capacity;
        const poses: []f32 = try gpa.alloc(f32, slots * m.coordinate_count);
        errdefer gpa.free(poses);
        const velocities: []f32 = try gpa.alloc(f32, slots * m.dof_count);
        errdefer gpa.free(velocities);
        const actions: []f32 = try gpa.alloc(f32, slots * action_width);
        errdefer gpa.free(actions);
        const frames: []u32 = try gpa.alloc(u32, slots);
        errdefer gpa.free(frames);
        const clips: []u16 = try gpa.alloc(u16, slots);
        errdefer gpa.free(clips);
        const segments: []u32 = try gpa.alloc(u32, slots);
        errdefer gpa.free(segments);
        const episode_steps: []?u32 = try gpa.alloc(?u32, slots);
        errdefer gpa.free(episode_steps);
        const after_loss: []bool = try gpa.alloc(bool, slots);
        errdefer gpa.free(after_loss);
        @memset(after_loss, false);
        const written: []u64 = try gpa.alloc(u64, envs);
        @memset(written, 0);
        return .{
            .gpa = gpa,
            .envs = envs,
            .capacity = capacity,
            .nq = m.coordinate_count,
            .nv = m.dof_count,
            .action_width = action_width,
            .poses = poses,
            .velocities = velocities,
            .actions = actions,
            .frames = frames,
            .clips = clips,
            .segments = segments,
            .episode_steps = episode_steps,
            .after_loss = after_loss,
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
        self.gpa.free(self.episode_steps);
        self.gpa.free(self.after_loss);
        self.gpa.free(self.written);
    }

    fn slot(self: Replay, env: usize, index: u64) usize {
        return self.books().slot(env, index);
    }

    /// THE REPLAY's BOOKS: what drawing a window reads of the rings - per record its segment, its step in its episode
    /// and whether that step came after the loss, per environment how many records it has written - as a view of
    /// slices, owning nothing. A replay's books are its own fields (`books`). A learner whose records are kept on a
    /// device keeps the same arrays on the host, advanced from what the device reports at each decision, and draws
    /// its windows by this same rule (`sampleWindowStarting`), so the two cannot draw differently.
    pub const Books = struct {
        envs: usize,
        capacity: usize,
        segments: []const u32,
        episode_steps: []const ?u32,
        after_loss: []const bool,
        written: []const u64,
        /// Per record, the reference frame it tracks and its clip - and each clip's frames, which the learner drawing
        /// starts gives (`sampleStart`): how much of its clip follows a record. Empty: no start can be drawn.
        frames: []const u32 = &.{},
        clips: []const u16 = &.{},
        clip_frames: []const u32 = &.{},

        /// Where environment `env`'s record `index` sits: its ring, then the record's place in it.
        pub fn slot(view: Books, env: usize, index: u64) usize {
            const place_in_ring: usize = @intCast(index % view.capacity);
            return env * view.capacity + place_in_ring;
        }

        pub fn segmentAt(view: Books, env: usize, index: u64) u32 {
            return view.segments[view.slot(env, index)];
        }

        /// WHETHER environment `env`'s record `index` CONTINUES THE RECORD BEFORE IT: the two in one segment - no
        /// restart and no push between them - so the step from one to the other is one transition of the simulation
        /// alone, which a world model can be taught. False for an environment's first record, and when the books no
        /// longer hold the record before.
        pub fn continuesAt(view: Books, env: usize, index: u64) bool {
            if (index == 0) {
                return false;
            }
            const ring_capacity: u64 = @intCast(view.capacity);
            const oldest_held: u64 = view.written[env] -| ring_capacity;
            const previous_index: u64 = index - 1;
            if (previous_index < oldest_held) {
                return false;
            }
            return view.segmentAt(env, previous_index) == view.segmentAt(env, index);
        }

        /// Whether the record's step came after its episode lost the reference.
        pub fn afterLossAt(view: Books, env: usize, index: u64) bool {
            return view.after_loss[view.slot(env, index)];
        }

        /// WHAT WAS APPLIED JUST BEFORE environment `env`'s record `index` - what a window starting there blends its
        /// first decision into, and what a policy that sees its applied action reads first:
        ///
        ///     rest              the record is its episode's first step: every episode opens from rest
        ///     previous_record   any later step: the action recorded one step earlier - ACROSS A PUSH TOO, which
        ///                       ends a segment but never an episode, so what the controller applies carries
        ///                       straight through it
        ///     null              the books cannot say: the record is no step of a rollout (`Replay.append`), or the
        ///                       record before it has left the ring
        ///
        /// The CPU learner's rule (robot_latent's `Learner.appliedBefore`), on the books. Where a window's records
        /// live in a ring of their own - a learner's on a device - that ring must hold the record before as well.
        pub fn appliedBeforeAt(view: Books, env: usize, index: u64) ?AppliedBefore {
            const episode_step: u32 = view.episode_steps[view.slot(env, index)] orelse return null;
            if (episode_step == 0) {
                return .rest;
            }
            const ring_capacity: u64 = @intCast(view.capacity);
            const oldest_held: u64 = view.written[env] -| ring_capacity;
            const previous_held: bool = index > oldest_held;
            if (!previous_held) {
                return null;
            }
            return .previous_record;
        }

        /// A window of `steps` transitions, its first record chosen as `start` says: anywhere in a segment, or only
        /// on a step taken before (or after) its episode lost the reference - or null.
        ///
        /// REJECTION SAMPLING. A candidate is drawn - a character uniformly, then a first record uniformly among
        /// those its ring still holds - and kept only if it is a window at all (every record in one segment) and
        /// starts where `start` allows; otherwise another is drawn. Keeping only the draws that pass a test, from a
        /// uniform draw, gives a uniform draw over the candidates that pass it: every acceptable window of a
        /// character stays equally likely. It also makes the rules agree exactly when no record follows a loss (a
        /// fleet with no aftermath): no draw is ever rejected for where it starts, so all consume the random stream
        /// identically and return the same windows. After 64 rejected draws the books are taken to have no window to
        /// give (null), which happens only while the rings are nearly empty.
        pub fn sampleWindowStarting(
            view: Books,
            random: Random,
            steps: usize,
            start: WindowStart,
        ) ?Window {
            assertf(steps > 0, @src(), "a window of no transitions is not a window", .{});
            // A window of `steps` transitions spans steps + 1 records: each step's state, and the one it led to.
            const records_per_window: usize = steps + 1;
            const most_draws: usize = 64;
            for (0..most_draws) |_| {
                const env: usize = random.uintLessThan(usize, view.envs);
                const records_written: u64 = view.written[env];
                if (records_written < records_per_window) {
                    continue;
                }
                // The ring holds the newest `capacity` records; a window must start late enough to lie inside it
                // and early enough to end at the newest record or before.
                const ring_capacity: u64 = @intCast(view.capacity);
                const oldest_held: u64 = records_written -| ring_capacity;
                const newest_start: u64 = records_written - records_per_window;
                if (newest_start < oldest_held) {
                    continue;
                }
                const start_choices: u64 = newest_start - oldest_held + 1;
                const first_record: u64 = oldest_held + random.uintLessThan(u64, start_choices);
                const last_record: u64 = first_record + records_per_window - 1;
                // One segment from the first record to the last: no reset and no push inside the window.
                const is_unbroken: bool = view.segmentAt(env, first_record) == view.segmentAt(env, last_record);
                if (!is_unbroken) {
                    continue;
                }
                const starts_after_loss: bool = view.afterLossAt(env, first_record);
                if (start == .before_loss and starts_after_loss) {
                    continue;
                }
                if (start == .after_loss and !starts_after_loss) {
                    continue;
                }
                return .{ .env = env, .first = first_record, .steps = steps };
            }
            return null;
        }

        /// THE FRAMES OF ITS CLIP AFTER environment `env`'s record `index` - its clip's last frame less its own - or
        /// null where the books hold no frames or clips (`frames`, `clip_frames`).
        pub fn framesLeftAt(view: Books, env: usize, index: u64) ?u32 {
            const knows_frames: bool = view.frames.len > 0 and view.clips.len > 0 and view.clip_frames.len > 0;
            if (!knows_frames) {
                return null;
            }
            const record_slot: usize = view.slot(env, index);
            const clip: usize = view.clips[record_slot];
            const frame: u32 = view.frames[record_slot];
            const last_frame: u32 = view.clip_frames[clip] - 1;
            return last_frame -| frame;
        }

        /// A POLICY's START: one record, its first state - the rollout from it is imagined, its references read from
        /// the clip's tables - chosen as `start` says (`WindowStart`: before a loss, or inside a return), or null.
        /// Any record the books hold whose clip has at least `frames_needed` frames after its own - the policy's
        /// horizon in its clip's frames - so no start runs past its clip; a record a decision before a fall is a start
        /// like any other, where a window had to end before it (XMimic's `sample_valid_starts`). REJECTION SAMPLING
        /// as `sampleWindowStarting`: a character uniformly, then one of the records its ring holds uniformly, kept
        /// when it passes - so every acceptable start is equally likely; null after 64 rejected draws.
        pub fn sampleStart(
            view: Books,
            random: Random,
            frames_needed: u32,
            start: WindowStart,
        ) ?Window {
            const knows_frames: bool = view.clip_frames.len > 0;
            assertf(knows_frames, @src(), "a start is drawn from books that know their records' frames", .{});
            const most_draws: usize = 64;
            for (0..most_draws) |_| {
                const env: usize = random.uintLessThan(usize, view.envs);
                const records_written: u64 = view.written[env];
                if (records_written == 0) {
                    continue;
                }
                const ring_capacity: u64 = @intCast(view.capacity);
                const oldest_held: u64 = records_written -| ring_capacity;
                const record_choices: u64 = records_written - oldest_held;
                const record: u64 = oldest_held + random.uintLessThan(u64, record_choices);
                const frames_left: u32 = view.framesLeftAt(env, record) orelse continue;
                if (frames_left < frames_needed) {
                    continue;
                }
                const is_after_loss: bool = view.afterLossAt(env, record);
                if (start == .before_loss and is_after_loss) {
                    continue;
                }
                if (start == .after_loss and !is_after_loss) {
                    continue;
                }
                return .{ .env = env, .first = record, .steps = 0 };
            }
            return null;
        }
    };

    /// This replay's books (`Books`): a view of its own fields - its records' frames and clips among them; the clips'
    /// lengths are its fleet's, given by whoever draws starts.
    pub fn books(self: Replay) Books {
        return .{
            .envs = self.envs,
            .capacity = self.capacity,
            .segments = self.segments,
            .episode_steps = self.episode_steps,
            .after_loss = self.after_loss,
            .written = self.written,
            .frames = self.frames,
            .clips = self.clips,
        };
    }

    /// Append one frame of experience for `env` that is NOT a step of a rollout - a teacher's label, a probe's
    /// state: the state, the action taken from it, the reference frame it was tracking, and its segment. What was
    /// being applied before it is unknown, and `episodeStepAt` says so (null). A fleet's own steps go through
    /// `appendStep`, which knows.
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
        self.appendStep(env, pose, velocity, action, frame, clip, segment, null, false);
    }

    /// Append one STEP of a rollout for `env`, `episode_step` steps into its episode (0 on its first step): the
    /// state it was in, the action applied from it, the reference frame it was tracking, its segment, and whether
    /// the step came after its episode lost the reference (`after_loss`).
    pub fn appendStep(
        self: *Replay,
        env: usize,
        pose: []const f32,
        velocity: []const f32,
        action: []const f32,
        frame: u32,
        clip: u16,
        segment: u32,
        episode_step: ?u32,
        after_loss: bool,
    ) void {
        assertf(
            env < self.envs and pose.len == self.nq and velocity.len == self.nv and action.len == self.action_width,
            @src(),
            "env {d} of {d}, pose {d}/{d}, velocity {d}/{d}, action {d}/{d}",
            .{ env, self.envs, pose.len, self.nq, velocity.len, self.nv, action.len, self.action_width },
        );
        const at: usize = self.slot(env, self.written[env]);
        @memcpy(self.poses[at * self.nq ..][0..self.nq], pose);
        @memcpy(self.velocities[at * self.nv ..][0..self.nv], velocity);
        @memcpy(self.actions[at * self.action_width ..][0..self.action_width], action);
        self.frames[at] = frame;
        self.clips[at] = clip;
        self.segments[at] = segment;
        self.episode_steps[at] = episode_step;
        self.after_loss[at] = after_loss;
        self.written[env] += 1;
    }

    pub fn poseAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.poses[self.slot(env, index) * self.nq ..][0..self.nq];
    }

    pub fn velocityAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.velocities[self.slot(env, index) * self.nv ..][0..self.nv];
    }

    pub fn actionAt(self: Replay, env: usize, index: u64) []const f32 {
        return self.actions[self.slot(env, index) * self.action_width ..][0..self.action_width];
    }

    pub fn frameAt(self: Replay, env: usize, index: u64) u32 {
        return self.frames[self.slot(env, index)];
    }

    /// Which clip that frame belongs to.
    pub fn clipAt(self: Replay, env: usize, index: u64) u16 {
        return self.clips[self.slot(env, index)];
    }

    pub fn segmentAt(self: Replay, env: usize, index: u64) u32 {
        return self.books().segmentAt(env, index);
    }

    /// Whether the record's step came after its episode lost the reference (`after_loss`).
    pub fn afterLossAt(self: Replay, env: usize, index: u64) bool {
        return self.books().afterLossAt(env, index);
    }

    /// How far into its episode the record's step was (0 on an episode's first step), or null when the record is
    /// not a step of a rollout (`append`).
    pub fn episodeStepAt(self: Replay, env: usize, index: u64) ?u32 {
        return self.episode_steps[self.slot(env, index)];
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
    pub fn sampleWindow(self: Replay, random: Random, steps: usize) ?Window {
        return self.sampleWindowStarting(random, steps, .anywhere);
    }

    /// `sampleWindow`, its first record chosen as `start` says - by the replay's books' rule
    /// (`Books.sampleWindowStarting`), on this replay's own books.
    pub fn sampleWindowStarting(
        self: Replay,
        random: Random,
        steps: usize,
        start: WindowStart,
    ) ?Window {
        return self.books().sampleWindowStarting(random, steps, start);
    }
};

/// A LABEL: a record whose action was a planner's, kept for the policy to learn from (`LabelBooks`) - its world, and
/// the record's index in the world's books.
pub const Label = struct {
    env: u32,
    index: u64,
};

/// THE LABELS A POLICY MAY LEARN FROM: records whose action was a planner's (`rbt.RecordMoment.labelled`), kept once
/// the stretch of plan they belong to has ended well. A STRETCH is a run of one world's labelled records from its
/// plan's first decision on (`rbt.RecordMoment.begins_plan`) - the plan followed decision after decision - until the
/// world stops following it: at the next replan, where a new plan begins, or where its policy acts again. A plan
/// followed is a plan lived exactly - the planner's lookahead ran the same physics from the same state with the same
/// actions - so every label of a stretch is the planner's answer for a state that really happened.
///
/// A stretch is SETTLED when the record after its last arrives, whose moment says how that last decision went:
///
///     a decision of the stretch failed        the plan failed: every label of it is dropped
///       (it lost the reference, or ended
///       its episode at a loss)
///     a decision of it came after a loss      dropped too: its states are a fall's, far from the reference, and its
///       (its episode living on through an     plan the best of a few drawn from a falling or fallen body
///       aftermath, `after_loss`)
///     the episode ended after the stretch     kept but for its last record, whose goal - read from the record after
///       (the next record opens another)       it, as the gather reads every goal - would be another episode's frame
///     otherwise                               kept whole: at a replan, after a push, or where the policy acts again
///
/// The labels teach the policy to keep the reference from states near it, as the policy's own windows mostly do (they
/// are drawn before a loss). A planner lives through an aftermath as every character does, and replans there as
/// anywhere: in a run whose characters live on after a loss, its stretches there would otherwise be a large share of
/// the labels.
///
/// A push ends a world's following on the device (`robotgpu.push_worlds`): the stretch before it is kept whole, its
/// plan having answered every state of it, and the record after it - the same episode's - still holding its last goal.
///
/// The kept labels live as long as the learner's ring holds their records: the newest `capacity` records of each world.
/// Each step forgets the labels whose records the ring is letting go, so at most `envs x capacity` are ever kept. The
/// books own their arrays: `init` allocates them from `gpa`, `deinit` frees them.
pub const LabelBooks = struct {
    envs: usize,
    capacity: usize,
    /// Each world's open stretch: its first record, how many records it holds (0: none open), whether a decision
    /// of it has failed, and whether one was taken after its episode lost the reference.
    stretch_first: []u64,
    stretch_length: []u32,
    stretch_failed: []bool,
    stretch_after_loss: []bool,
    /// The kept labels, in the order they were settled: the first `kept_count`.
    kept: []Label,
    kept_count: usize,
    /// Counts since the books began, for the log: the labels kept, and those dropped - with a failed plan, as a
    /// stretch's decisions after a loss, or as a stretch's last record where its episode ended.
    labels_kept: u64,
    labels_dropped_with_failed_plans: u64,
    labels_dropped_after_losses: u64,
    labels_dropped_at_episode_ends: u64,

    pub fn init(gpa: Allocator, envs: usize, capacity: usize) !LabelBooks {
        const stretch_first: []u64 = try gpa.alloc(u64, envs);
        errdefer gpa.free(stretch_first);
        const stretch_length: []u32 = try gpa.alloc(u32, envs);
        errdefer gpa.free(stretch_length);
        const stretch_failed: []bool = try gpa.alloc(bool, envs);
        errdefer gpa.free(stretch_failed);
        const stretch_after_loss: []bool = try gpa.alloc(bool, envs);
        errdefer gpa.free(stretch_after_loss);
        const most_kept: usize = envs * capacity;
        const kept: []Label = try gpa.alloc(Label, most_kept);
        @memset(stretch_first, 0);
        @memset(stretch_length, 0);
        @memset(stretch_failed, false);
        @memset(stretch_after_loss, false);
        return .{
            .envs = envs,
            .capacity = capacity,
            .stretch_first = stretch_first,
            .stretch_length = stretch_length,
            .stretch_failed = stretch_failed,
            .stretch_after_loss = stretch_after_loss,
            .kept = kept,
            .kept_count = 0,
            .labels_kept = 0,
            .labels_dropped_with_failed_plans = 0,
            .labels_dropped_after_losses = 0,
            .labels_dropped_at_episode_ends = 0,
        };
    }

    pub fn deinit(labels: LabelBooks, gpa: Allocator) void {
        gpa.free(labels.stretch_first);
        gpa.free(labels.stretch_length);
        gpa.free(labels.stretch_failed);
        gpa.free(labels.stretch_after_loss);
        gpa.free(labels.kept);
    }

    /// ONE STEP's RECORDS - record `record_index` of every world - with their moments, one a world (`moments[env]`, as
    /// the simulator stood when the record was packed): the labels whose records the ring is letting go forgotten,
    /// then each world's open stretch extended by its plan's next decision, or settled by anything else, and a new
    /// stretch opened at each label that does not extend one.
    pub fn appendStep(
        labels: *LabelBooks,
        moments: []const rbt.RecordMoment,
        record_index: u64,
    ) void {
        assertf(moments.len == labels.envs, @src(), "{d} moments for {d} worlds", .{ moments.len, labels.envs });
        // Once this step's records are in, the ring holds each world's newest `capacity`: from `oldest_held` on.
        const records_after_step: u64 = record_index + 1;
        const ring_capacity: u64 = @intCast(labels.capacity);
        const oldest_held: u64 = records_after_step -| ring_capacity;
        labels.forgetBefore(oldest_held);
        for (moments, 0..) |moment, env| {
            const plan_goes_on: bool = moment.labelled and !moment.begins_plan;
            // A push and a new episode end a world's following on the device: no plan goes on across them.
            const across_a_break: bool = plan_goes_on and moment.starts_segment;
            assertf(!across_a_break, @src(), "world {d}'s record {d} goes on with a plan across a push or a new " ++
                "episode", .{ env, record_index });
            const has_stretch: bool = labels.stretch_length[env] > 0;
            if (has_stretch) {
                // How the stretch's last decision went - this record's moment says.
                if (moment.previous_decision_failed) {
                    labels.stretch_failed[env] = true;
                }
                if (plan_goes_on) {
                    labels.stretch_length[env] += 1;
                    // This record's decision joins the stretch: taken after a loss, it drops the stretch.
                    if (moment.after_loss) {
                        labels.stretch_after_loss[env] = true;
                    }
                    continue;
                }
                const episode_ended: bool = moment.episode_step == 0;
                labels.settle(env, episode_ended, oldest_held);
            }
            // A label that does not extend a stretch opens one: a plan's first decision - or a later one where these
            // books began in the middle of its stretch, a plan lived exactly all the same.
            if (moment.labelled) {
                labels.stretch_first[env] = record_index;
                labels.stretch_length[env] = 1;
                labels.stretch_failed[env] = false;
                labels.stretch_after_loss[env] = moment.after_loss;
            }
        }
    }

    /// THE OPEN STRETCH OF WORLD `env`, SETTLED: dropped whole where a decision of it failed, or was taken after a
    /// loss; otherwise kept - all but its last record where its episode ended after it (`episode_ended`) - each label
    /// whose record the ring still holds (from `oldest_held` on; a stretch is far shorter than the ring, so all of them
    /// in practice).
    fn settle(
        labels: *LabelBooks,
        env: usize,
        episode_ended: bool,
        oldest_held: u64,
    ) void {
        const first: u64 = labels.stretch_first[env];
        const stretch_records: u32 = labels.stretch_length[env];
        labels.stretch_length[env] = 0;
        if (labels.stretch_failed[env]) {
            labels.labels_dropped_with_failed_plans += stretch_records;
            return;
        }
        if (labels.stretch_after_loss[env]) {
            labels.labels_dropped_after_losses += stretch_records;
            return;
        }
        var kept_length: u32 = stretch_records;
        if (episode_ended) {
            kept_length -= 1;
            labels.labels_dropped_at_episode_ends += 1;
        }
        var offset: u32 = 0;
        while (offset < kept_length) : (offset += 1) {
            const index: u64 = first + offset;
            if (index < oldest_held) {
                continue;
            }
            labels.keep(env, index);
        }
    }

    fn keep(labels: *LabelBooks, env: usize, index: u64) void {
        const room_left: bool = labels.kept_count < labels.kept.len;
        assertf(room_left, @src(), "{d} labels kept already, one a record the ring holds", .{labels.kept_count});
        labels.kept[labels.kept_count] = .{ .env = @intCast(env), .index = index };
        labels.kept_count += 1;
        labels.labels_kept += 1;
    }

    /// The labels whose records the ring no longer holds - those before `oldest_held` - forgotten, the rest kept in
    /// their order.
    fn forgetBefore(labels: *LabelBooks, oldest_held: u64) void {
        var still_kept: usize = 0;
        for (labels.kept[0..labels.kept_count]) |label| {
            if (label.index < oldest_held) {
                continue;
            }
            labels.kept[still_kept] = label;
            still_kept += 1;
        }
        labels.kept_count = still_kept;
    }

    /// THESE LABELS' BOOKS MADE A COPY OF `source`, of the same shape: every open stretch, every kept label in its
    /// order, every count - so the copy settles, forgets and draws exactly as its source would.
    pub fn copyFrom(labels: *LabelBooks, source: LabelBooks) void {
        const same_shape: bool = labels.envs == source.envs and labels.capacity == source.capacity;
        assertf(same_shape, @src(), "labels of {d} worlds x {d} records copied into {d} x {d}", .{
            source.envs,
            source.capacity,
            labels.envs,
            labels.capacity,
        });
        @memcpy(labels.stretch_first, source.stretch_first);
        @memcpy(labels.stretch_length, source.stretch_length);
        @memcpy(labels.stretch_failed, source.stretch_failed);
        @memcpy(labels.stretch_after_loss, source.stretch_after_loss);
        @memcpy(labels.kept[0..source.kept_count], source.keptLabels());
        labels.kept_count = source.kept_count;
        labels.labels_kept = source.labels_kept;
        labels.labels_dropped_with_failed_plans = source.labels_dropped_with_failed_plans;
        labels.labels_dropped_after_losses = source.labels_dropped_after_losses;
        labels.labels_dropped_at_episode_ends = source.labels_dropped_at_episode_ends;
    }

    /// The labels kept now, in the order they were settled.
    pub fn keptLabels(labels: LabelBooks) []const Label {
        return labels.kept[0..labels.kept_count];
    }

    /// A kept label drawn uniformly - each as likely - or null while none is kept.
    pub fn drawLabel(labels: LabelBooks, random: Random) ?Label {
        if (labels.kept_count == 0) {
            return null;
        }
        const drawn: usize = random.uintLessThan(usize, labels.kept_count);
        return labels.kept[drawn];
    }
};

/// BOOKS KEPT FOR RECORDS STORED ELSEWHERE - a learner's ring on a device, filled there by one copy a step - in the
/// layout of a replay's (`Replay.Books`), so windows are drawn from them by the same rule. Each step the host gives one
/// `rbt.RecordMoment` a world, read from the simulator after the decision before (`robotgpu.recordMomentOf`), and the
/// books advance by one record a world, in lockstep:
///
///     moment      starts_segment   episode_step   after_loss   labelled
///     record          segment          step       after_loss   labelled     a new segment id where a stretch starts
///
/// A world's first record starts its first stretch whatever its moment says. Segment ids only grow and are shared by
/// no two stretches, so two records are in one stretch exactly when their ids are equal - the property the rule reads.
/// The labels a policy may learn from are kept beside, settled from the same moments (`LabelBooks`). The books own
/// their arrays: `init` allocates them from `gpa`, `deinit` frees them.
pub const KeptBooks = struct {
    envs: usize,
    capacity: usize,
    /// Per record, as a replay keeps them: [env][slot]. Every record here is a step of a rollout, so every episode
    /// step is known; it is kept optional as a replay keeps it, so the two hand out one view (`Replay.Books`).
    segments: []u32,
    episode_steps: []?u32,
    after_loss: []bool,
    /// Whether the record's action was a planner's (`rbt.RecordMoment.labelled`): a label for the policy.
    labelled: []bool,
    /// The reference frame each record tracks, and its clip (`rbt.RecordMoment.frame`, `.clip`).
    frames: []u32,
    clips: []u16,
    /// How many records each world has ever written. The rings hold the last `capacity`.
    written: []u64,
    /// Each world's current stretch, and the next unused id.
    current_segment: []u32,
    next_segment: u32,
    /// The labels kept from the planners' stretches of plan that ended well.
    labels: LabelBooks,

    pub fn init(gpa: Allocator, envs: usize, capacity: usize) !KeptBooks {
        const record_count: usize = envs * capacity;
        const segments: []u32 = try gpa.alloc(u32, record_count);
        errdefer gpa.free(segments);
        const episode_steps: []?u32 = try gpa.alloc(?u32, record_count);
        errdefer gpa.free(episode_steps);
        const after_loss: []bool = try gpa.alloc(bool, record_count);
        errdefer gpa.free(after_loss);
        const labelled: []bool = try gpa.alloc(bool, record_count);
        errdefer gpa.free(labelled);
        const frames: []u32 = try gpa.alloc(u32, record_count);
        errdefer gpa.free(frames);
        const clips: []u16 = try gpa.alloc(u16, record_count);
        errdefer gpa.free(clips);
        const written: []u64 = try gpa.alloc(u64, envs);
        errdefer gpa.free(written);
        const current_segment: []u32 = try gpa.alloc(u32, envs);
        errdefer gpa.free(current_segment);
        const labels: LabelBooks = try .init(gpa, envs, capacity);
        @memset(segments, 0);
        @memset(episode_steps, null);
        @memset(after_loss, false);
        @memset(labelled, false);
        @memset(frames, 0);
        @memset(clips, 0);
        @memset(written, 0);
        // Every world in a stretch of its own: ids 0 to envs - 1, the next one after them.
        for (current_segment, 0..) |*segment, env| {
            segment.* = @intCast(env);
        }
        return .{
            .envs = envs,
            .capacity = capacity,
            .segments = segments,
            .episode_steps = episode_steps,
            .after_loss = after_loss,
            .labelled = labelled,
            .frames = frames,
            .clips = clips,
            .written = written,
            .current_segment = current_segment,
            .next_segment = @intCast(envs),
            .labels = labels,
        };
    }

    pub fn deinit(books: KeptBooks, gpa: Allocator) void {
        gpa.free(books.segments);
        gpa.free(books.episode_steps);
        gpa.free(books.after_loss);
        gpa.free(books.labelled);
        gpa.free(books.frames);
        gpa.free(books.clips);
        gpa.free(books.written);
        gpa.free(books.current_segment);
        books.labels.deinit(gpa);
    }

    /// One step's records, one a world: `moments[env]` is world `env`'s, as the simulator stood when the record was
    /// packed. Every world records every step, so every world's record has the same index; the labels' books advance
    /// with them (`LabelBooks.appendStep`).
    pub fn appendStep(books: *KeptBooks, moments: []const rbt.RecordMoment) void {
        assertf(moments.len == books.envs, @src(), "{d} moments for {d} worlds", .{ moments.len, books.envs });
        const step_index: u64 = books.written[0];
        for (moments, 0..) |moment, world| {
            const records_written: u64 = books.written[world];
            const in_lockstep: bool = records_written == step_index;
            assertf(in_lockstep, @src(), "world {d} has {d} records, world 0 {d}", .{
                world,
                records_written,
                step_index,
            });
            // A world's first record already has its segment (`init`): only a later record can begin a new one.
            const world_has_records: bool = records_written > 0;
            const starts_new_segment: bool = world_has_records and moment.starts_segment;
            if (starts_new_segment) {
                books.current_segment[world] = books.next_segment;
                books.next_segment += 1;
            }
            const record_index: u64 = records_written;
            const record_slot: usize = books.view().slot(world, record_index);
            books.segments[record_slot] = books.current_segment[world];
            books.episode_steps[record_slot] = moment.episode_step;
            books.after_loss[record_slot] = moment.after_loss;
            books.labelled[record_slot] = moment.labelled;
            books.frames[record_slot] = moment.frame;
            books.clips[record_slot] = moment.clip;
            books.written[world] = records_written + 1;
        }
        books.labels.appendStep(moments, step_index);
    }

    /// THESE BOOKS MADE A COPY OF `source`, of the same shape: every record's entries, every world's count and stretch,
    /// the labels' books with them - so the copy draws windows and labels exactly as its source would.
    pub fn copyFrom(books: *KeptBooks, source: KeptBooks) void {
        const same_shape: bool = books.envs == source.envs and books.capacity == source.capacity;
        assertf(same_shape, @src(), "books of {d} worlds x {d} records copied into {d} x {d}", .{
            source.envs,
            source.capacity,
            books.envs,
            books.capacity,
        });
        @memcpy(books.segments, source.segments);
        @memcpy(books.episode_steps, source.episode_steps);
        @memcpy(books.after_loss, source.after_loss);
        @memcpy(books.labelled, source.labelled);
        @memcpy(books.frames, source.frames);
        @memcpy(books.clips, source.clips);
        @memcpy(books.written, source.written);
        @memcpy(books.current_segment, source.current_segment);
        books.next_segment = source.next_segment;
        books.labels.copyFrom(source.labels);
    }

    /// How far into its episode a record's step was (0 on an episode's first step); null for a slot never written.
    pub fn episodeStepAt(books: KeptBooks, env: usize, index: u64) ?u32 {
        return books.episode_steps[books.view().slot(env, index)];
    }

    /// Whether a record's action was a planner's: a label for the policy.
    pub fn labelledAt(books: KeptBooks, env: usize, index: u64) bool {
        return books.labelled[books.view().slot(env, index)];
    }

    /// The books as a replay's (`Replay.Books`): what windows are drawn from - and, with the clips' lengths the learner
    /// gives, starts.
    pub fn view(books: KeptBooks) Replay.Books {
        return .{
            .envs = books.envs,
            .capacity = books.capacity,
            .segments = books.segments,
            .episode_steps = books.episode_steps,
            .after_loss = books.after_loss,
            .written = books.written,
            .frames = books.frames,
            .clips = books.clips,
        };
    }
};

/// How many numbers a policy sees: the simulated character and the reference it is chasing, both in
/// the root's frame (section  `local`).
pub fn observationSize(m: *const rbt.Model) usize {
    return 2 * localSize(m.body_count);
}

/// WHERE A STEP'S CONTACTS COME FROM. robot.zig's own floor contacts (`rbt.pushFloorContacts`): MuJoCo's plane
/// functions on every geom, the floor alone - the contacts robotgpu's device makes, so a policy trained on the CPU or
/// on the device stands on the same floor. Or the physics engine's collision (`zimrphysics`, through the bridge): the
/// floor, and a robot's bodies against each other where the model lets them touch. Measured on Geno's servo over the
/// 10-second dance, robot.zig's floor at equal friction doubles its time to failure, and none of the physics engine's
/// contacts there is between his own bodies.
pub const ContactSource = enum { robot_floor, physics_engine };

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
    /// The floor's friction - a contact's combined with its shape's by the contact source's own rule (`contacts`):
    /// robot.zig's floor takes the larger of the two, MuJoCo's; the physics engine their geometric mean. The old
    /// robot's 0.7; Geno's feet skate at that under its servo, and use `robot_geno.floor_friction`.
    floor_friction: f32 = 0.7,
    /// Where a step's contacts come from (`ContactSource`); the floor's friction is `floor_friction` either way,
    /// combined with each geom's by the source's own rule - robot.zig's MuJoCo's, the larger of the two.
    contacts: ContactSource = .robot_floor,
    /// Rest every reset ON the floor (`rbt.restOnFloor`, 1 mm clear): a pose copied from a capture sinks its feet
    /// into the simulated floor, and the solver kicks the body out of it on the first step - at every episode
    /// start. Off for the old robot; Geno's task sets it.
    rest_on_floor: bool = false,
    /// How far above the floor a start rests its lowest point (`rbt.restOnFloor`), in metres.
    rest_clearance: f32 = 0.001,
    weights: RewardWeights = .{},
    /// SuperMimic's reward, scored beside this task's own for the judge's measure (`Fleet.super_mimic_rewards`).
    super_mimic: SuperMimicScales = .{},
    termination: Termination = .{},
    /// Bodies whose floor contact is never UNEXPECTED (`TrackingError.unexpected_contact`): the ones the robot
    /// stands on. A foot is down through every stance while the reference lifts it into each swing, and a
    /// character a few frames behind still has it down - that is lag, not a fall. Named per ROBOT, never per
    /// motion; a fleet resolves them through `Fleet.Options.body_names`. Empty by default.
    contact_exempt: []const []const u8 = &.{},
    /// The body that is the robot's HEAD, for `TrackingError.head_height` (SuperTrack's failure rule).
    /// Named per robot, resolved like `contact_exempt`. Empty: no head term.
    head_body: []const u8 = "",
};

/// `seconds` in steps of `step_seconds`, rounded to the nearest.
fn stepsIn(seconds: f32, step_seconds: f32) u32 {
    const steps: u32 = @round(seconds / step_seconds);
    return steps;
}

/// How a fleet pushes its characters from outside - the perturbations a policy must come back from.
///
/// A PUSH is a sudden change of the whole body's velocity: a speed, in a horizontal direction drawn uniformly round the
/// vertical, added to the root's linear velocity, so every body of the character moves with it (an impulse of the
/// character's mass times the speed, through its centre of mass). Nothing in the state saw it coming, so the stretch
/// of motion it interrupts ends there and a new segment begins (`Fleet.segment`).
///
/// Pushes come on a fixed schedule (`every` steps, for measuring robustness at a known rhythm), at random moments
/// (`rate_per_second`: each step a push with probability rate x dt - a Poisson process, the training's), or both.
/// Each push's speed is drawn uniformly between `speed_min` and the range's TOP: a small push is taken in stride, a
/// large one needs a step, a larger one is a fall - a range teaches all three.
///
/// THE RAMP (`rbt.PushTop`), in training hours (told by the program that trains - `Fleet.tellTrainingHours` - so it
/// holds whatever the machine's speed and across a resume). The RATE is full from the first minute: early pushes are
/// small, not rare, so the characters are carried off their reference from the start. The TOP opens along a straight
/// line from `speed_min` at the start to `speed_max` at `full_hours`, and holds wherever the characters stop coming
/// back from the pushes near it (`brake`, `rbt.PushBrake`). A run of eight hours, its line full at the sixth -
/// three quarters of the run, while the learning rates are still well above their floor:
///
///     hours          0        1        2        3        4        5        6      7, 8
///     rate (1/s)     0.5      0.5      0.5      0.5      0.5      0.5      0.5    0.5
///     speeds (m/s)   0.5   0.5-1.25  0.5-2.0  0.5-2.75 0.5-3.5  0.5-4.25  0.5-5  0.5-5     (full 0.5 to 5)
pub const Pushes = struct {
    /// Steps between scheduled pushes; 0 schedules none.
    every: u32 = 0,
    /// Pushes per second at random moments, from the first minute on; 0 gives none.
    rate_per_second: f32 = 0,
    /// The range each push's speed is drawn from when fully open, in m/s.
    speed_min: f32 = 0.6,
    speed_max: f32 = 0.6,
    /// The training hours at which the top's line reaches `speed_max`. 0: the full range from the start.
    full_hours: f32 = 0,
    /// The brake on the top (`rbt.PushBrake`): off unless it is given a bar.
    brake: rbt.PushBrake = .{},
    /// STARTS IN TROUBLE: the share of new episodes that begin with a push at the top of the range - as far as the
    /// top has opened, so a growing share of ever harder starts. A character starting in trouble must recover
    /// before it can track at all. 0: none.
    start_share: f32 = 0,

    /// The decisions a watched push that loses nothing is watched (`rbt.PushBrake.watch_seconds`), one at least, in
    /// decisions of `decision_seconds`.
    pub fn watchDecisions(pushes: Pushes, decision_seconds: f32) u32 {
        const decisions: u32 = stepsIn(pushes.brake.watch_seconds, decision_seconds);
        return @max(decisions, 1);
    }

    /// The top share of the open range whose pushes are watched: the brake's, and none without a brake.
    pub fn watchedShare(pushes: Pushes) f32 {
        return if (pushes.brake.isOn()) pushes.brake.watched_share else 0;
    }
};

/// THE RESET CURRICULUM - SUPERMIMIC's (their `manager_terms.py`): every clip cut into bins of `bin_seconds`, each with
/// a RETURN ESTIMATE G, the discounted return of the episodes started in it. A finished episode moves its start bin's G
/// towards its return (`rbt.updateStartBinReturn`; an episode cut short rather than failed adds the tail it would have
/// earned). A start draws its clip's bin from SuperMimic's mixture (`rbt.startBinProbabilities`): part uniform, part a
/// softmax towards the bins of LOW return - the hard ones - and part that softmax's long-run average; then a frame
/// uniform within the bin. Low return, not failure alone: a section the character survives but tracks badly is hard
/// too. `bin_seconds` 0 turns the curriculum off (starts uniform over the clip).
pub const ResetCurriculum = struct {
    bin_seconds: f32 = 0,
    /// SuperMimic's shares, sharpness and memories (`rbt.StartCurriculumRule`).
    rule: rbt.StartCurriculumRule = .{},
    /// The discount of the episode returns the bins keep.
    discount: f32 = 0.99,
    /// The largest reward one decision can earn - SuperMimic's tracking terms' weights summed (four of 1, two of 0.5):
    /// over 1 - `discount`, the largest return, the scale the softmax compares returns at.
    largest_step_reward: f32 = 5.0,

    /// The largest return: the largest step reward over 1 - the discount, the scale the softmax compares returns at
    /// (`rbt.startBinSoftmax`).
    pub fn returnScale(curriculum: ResetCurriculum) f32 {
        return curriculum.largest_step_reward / (1 - curriculum.discount);
    }
};

/// A curriculum bin's length on `clip`, in whole frames: `bin_seconds` over the frame time, rounded, at least one -
/// counting in frames keeps a bin's frames, a frame's bin and the clip's bin count exact (a 5 s clip at 60 Hz is 300
/// frames: five bins of 60, where 300 x a frame time stored as 0.016667 is 5.0001 seconds, and six bins).
pub fn binFrames(clip: *const dance.Clip, curriculum: ResetCurriculum) usize {
    const frames: usize = @round(curriculum.bin_seconds / clip.frame_time);
    return @max(frames, 1);
}

/// Where each clip's curriculum bins begin among all the clips' bins in a row, one more entry than the clips - the
/// last the total; each clip cut into bins of `bin_seconds`, the last perhaps shorter. Empty without a curriculum.
/// Memory: `owned`, the fleet's.
fn curriculumBinStarts(
    owned: Allocator,
    clips: []const *const dance.Clip,
    curriculum: ResetCurriculum,
) ![]usize {
    if (curriculum.bin_seconds <= 0) {
        return &.{};
    }
    const starts: []usize = try owned.alloc(usize, clips.len + 1);
    var total: usize = 0;
    for (clips, starts[0..clips.len]) |clip, *start| {
        start.* = total;
        const bin_frames: usize = binFrames(clip, curriculum);
        const bins: usize = (clip.frame_count + bin_frames - 1) / bin_frames;
        total += @max(bins, 1);
    }
    starts[clips.len] = total;
    return starts;
}

/// THE SCRATCH ONE CHARACTER'S PHYSICS STEP WORKS IN (`Fleet.driveOnce`): the servo's targets and the reference's
/// velocity, the joint accelerations, the dense mass matrix and its factor's row, and the torques. One per task that
/// steps characters. A step reads the model and the clips, which nothing writes while it runs; writes its character's
/// own data, collision world and bridge, allocating only from its character's own arena (`Fleet.character_arenas`);
/// and works in this - so characters stepped at once on different threads share nothing, and each comes out the
/// number it would have alone.
pub const DriveScratch = struct {
    targets: []f32,
    target_velocity: []f32,
    accel: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    torque: []f32,
    /// A pull's point Jacobian (`rbt.addPullForce`), a column per dof.
    pull_jacobian: []Vec,

    /// Scratch for model `m`. Memory: `owned`, the fleet's.
    pub fn init(owned: Allocator, m: *const rbt.Model) !DriveScratch {
        const drive: DriveScratch = .{
            .targets = try owned.alloc(f32, m.coordinate_count),
            .target_velocity = try owned.alloc(f32, m.dof_count),
            .accel = try owned.alloc(f32, m.dof_count),
            .scratch = try owned.alloc(f32, m.dof_count),
            .dense = try owned.alloc(f32, m.dof_count * m.dof_count),
            .full = try owned.alloc(f32, m.dof_count),
            .torque = try owned.alloc(f32, m.dof_count),
            .pull_jacobian = try owned.alloc(Vec, m.dof_count),
        };
        return drive;
    }
};

/// Which clip a character's new episode is on, when a fleet holds several.
///
///     random         a clip drawn anew at every restart - each clip's share of the TIME then follows how long its
///                    episodes last, so a harder clip, whose episodes end sooner, quietly gets less of it
///     by_character   character i always on clip i mod the clips - each clip the same share of the characters, so
///                    the same share of the time, however hard it is
pub const ClipAssignment = enum {
    random,
    by_character,
};

/// How long one decision lasts: `decide_every` physics steps of `timestep` seconds - the one definition every count of
/// a fleet's steps becomes time through (`Fleet.decisionSeconds`, the judge, the recovery probe).
pub fn secondsPerDecision(timestep: f32, decide_every: u32) f32 {
    const physics_steps: f32 = float(decide_every);
    return timestep * physics_steps;
}

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
        /// THE ACTION FILTER AT THE PHYSICS RATE (`rbt.filterAction`), FOR THE JOINTS' OFFSETS: before each physics
        /// step a character's applied offsets move this share of the way to what its policy asked, and the servo's
        /// targets are formed from the applied ones. 1 is no filter - the asked action applied exactly - and the
        /// default: no learner models this filter yet (its world model learns from the decisions' asked actions, blind
        /// to how far each physics step has moved them - with it on, a skip model's loss stops falling). The smoothing
        /// training uses is the decision-rate filter (the trainer's `filter`, the kit's `filter` and
        /// `stiffness_filter`), modelled exactly. A run parameter, as `stiffness_filter` is.
        action_filter: f32 = 1.0,
        /// THE LIMBS' STIFFNESS FILTER: the share for each limb's stiffness, at the physics rate as `action_filter` is
        /// for the joints' offsets, set on its own - a stiffness may want to move faster or slower than a pose. 1, no
        /// filter, by default, for the reason `action_filter` gives. A run parameter, as `action_filter` is.
        stiffness_filter: f32 = 1.0,
        /// A STIFFNESS PER LIMB in the action (variable-stiffness locomotion, after Spoljaric, Yan & Lee 2025): with it
        /// on, the action has one more number per limb after the joints' offsets (`actionWidth`) - each limb's
        /// stiffness s, which sets its servo's spring to the law's frequency times 3^(s/4), filtered with the offsets.
        /// Off, the action is the offsets alone and every spring is at the law's frequency.
        limb_stiffness: bool = false,
        /// How far each ball's rotation box reaches past its captures, per rotation-vector component, in radians
        /// (`rbt.rotationBoxes`): the clamp's and the soft limit's margin.
        rotation_box_margin: f32 = 0.1745,
        /// What the characters are asked to do and when they have failed - see `Task`.
        task: Task = .{},
        /// Whether each decision's TRACKING QUALITY is measured (`quality`, `measureQuality`): the judge's fleets
        /// (`judgeOptions`) - a training fleet has no use for it.
        measures_quality: bool = false,
        /// Which clip each new episode is on (`ClipAssignment`).
        clip_assignment: ClipAssignment = .random,
        /// THE PHYSICS' TASKS: how many parts the characters are split into for their physics steps, each part on a
        /// thread of `Fleet.physics_io` when the fleet is given one - 1 is one loop on the calling thread, as on the
        /// web. Only the integration runs apart: recording, measuring, ending, restarting and pushing - every random
        /// draw - stay on the calling thread in the characters' order, so the fleet's numbers are the same, to the
        /// bit, whatever this is.
        physics_threads: u32 = 1,
        /// Where each new episode starts along its clip (`ResetCurriculum`): uniform, unless a curriculum is given.
        curriculum: ResetCurriculum = .{},
        /// The model's body names, indexed like its bodies (`robot_mjcf.Imported.names`) - needed only to resolve
        /// `task.contact_exempt`, which names bodies; a task that exempts nothing needs none.
        body_names: []const []const u8 = &.{},
        /// Every reset pushed off the reference (`perturbStart`) - D5.5's perturbed starts. None by default.
        start_noise: StartNoise = .{},
        /// Pushes from outside (`Pushes`): none by default.
        pushes: Pushes = .{},
        /// Episodes end here even when tracking is fine, so no environment sits in one stretch of
        /// clip forever.
        max_steps: u32 = 600,
        /// WHETHER AN ENDED EPISODE RESTARTS its character (`restartEnded`): every learner's and judge's fleet does.
        /// Off - a viewer that restarts a character only when asked (`restart`) - an episode never ends: a lost
        /// reference is still judged and counted (`failures`) at every step it stays lost, the character lives on
        /// wherever it is, and the reference holds its clip's last frame once it gets there
        /// (`advanceReferenceFrame`). Read at every step, so a viewer may turn it on and off as it runs.
        restarts_episodes: bool = true,
        /// THE CLOCK: physics steps per DECISION. One `step` is one decision: the targets it is given are held for this
        /// many physics steps, the reference advancing by a frame each, and the record, the reward, the termination
        /// and the episode's end come once, at the decision's end. Every count of steps in these options
        /// (`max_steps`, `aftermath_steps`, `return_steps`, the termination's grace, the replay's capacity) then counts
        /// decisions. 1: a decision every physics step; 2: the policy at 30 Hz over 60 Hz physics.
        decide_every: u32 = 1,
        seed: u64 = 1,
        /// Physics steps a character lives on after its reference is LOST before its episode ends (`End.aftermath`).
        /// The step the failure rule fires is the failure, counted once; the character is then simulated and
        /// rewarded as usual - its fall, under the task's reward - and only after that is the episode cut and the
        /// character restarted. A learner that values a state by what follows it then sees in its own data what
        /// losing the reference leads to, with no notion of termination. Zero ends the episode at the loss itself,
        /// as every fleet always has: the judge and the learners that terminate keep it.
        aftermath_steps: u32 = 0,
        /// The share of the fleet's characters that keep that aftermath: the first round(share x envs) of them. The
        /// others end their episodes at the loss, as a fleet with no aftermath does - a POPULATION in one fleet, the
        /// resetting ones keeping the data near the reference, the living-on ones bringing falls and what follows.
        aftermath_share: f32 = 1.0,
        /// THE RETURN: steps in a row a character in its aftermath must track within the failure rule again to have
        /// RETURNED to the reference - its aftermath ends there and its EPISODE GOES ON, a later loss counting as a new
        /// failure; an aftermath that runs out first ends its episode, a failure to return. Each step of an aftermath
        /// asks the rule the other way round: not "is the reference lost?" but "is it held again?" - the reference
        /// running on all the while, so a return is to where the motion has got to, not to where it was lost. 0: no
        /// returns, every aftermath ending its episode as it always has.
        return_steps: u32 = 0,
    };

    gpa: Allocator,
    /// Everything the fleet owns comes from here, and goes back in one call. A dozen buffers
    /// allocated one at a time is a dozen chances to leak the previous eleven when the thirteenth
    /// fails; an arena has one.
    arena: ArenaAllocator,
    /// ONE ARENA PER CHARACTER, for everything its physics step can allocate from - its data, its collision world (and
    /// that world's per-step scratch arena), its bridge - each backed by the fleet's `gpa` directly. Characters step on
    /// several threads at once (`Options.physics_threads`), and an arena is not safe to allocate from on two threads:
    /// with every character's allocations in an arena of its own, the only allocator two steps can reach at once is
    /// `gpa`, which must therefore be thread-safe (Zig's general-purpose allocators are) whenever the fleet has
    /// threads.
    character_arenas: []ArenaAllocator,
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
    /// The reset curriculum's bins (`ResetCurriculum`), every clip's in a row: where each clip's bins begin
    /// (`bins_start`, one more than the clips - the last the total), each bin's running failure rate, and its long-run
    /// weight. Empty without a curriculum.
    bins_start: []usize,
    bin_returns: []f32,
    /// Scratch for one clip's bin probabilities at a start (`rbt.startBinMixture`), as long as `bin_returns`.
    bin_probabilities: []f32,
    /// Each bin's share of the hard draws (`rbt.startBinSoftmax`), refreshed once per decision with any start, after
    /// every finished episode is folded (`refreshStartBins`) - what every start of that decision reads.
    bin_softmax: []f32,
    /// Each character whose episode ended this decision, restarted once all of them are folded (`step`).
    ended_this_decision: []bool,
    /// EACH CHARACTER's EPISODE, for the curriculum: the bin it started in, its discounted return so far, the
    /// discount's power at its next decision, its rewards' sum and its decisions - folded into its start bin when it
    /// ends.
    start_bins: []usize,
    episode_discounted_returns: []f32,
    episode_discount_powers: []f32,
    episode_reward_sums: []f32,
    episode_decisions: []u32,
    bin_history_weights: []f32,
    frame: []u32,
    segment: []u32,
    steps: []u32,
    next_segment: u32,
    /// The hours this fleet's training has run, told each round by the program that trains (`tellTrainingHours`:
    /// the trainer's clock, saved with its run). 0 for a fleet nobody trains with.
    training_hours: f32 = 0,
    /// THE PUSHES' TOP (`rbt.PushTop`): how far the range of push speeds has opened - along the training clock,
    /// held by the brake. Fully open for a fleet whose pushes have no line (`Pushes.full_hours` 0).
    push_top: rbt.PushTop = .{},
    /// The pushes given at random or on the schedule, and their speeds' sum - what a run's log reads the
    /// perturbations it met from.
    pushes_given: u64,
    push_speed_sum: f64,
    /// The watched pushes ended so far - kept, returned or failed - and those of them the characters came back from
    /// (`rbt.PushBrake`): the fleet's own, or a device's as its host reports them (`noteWatchedPush`).
    watched_pushes_settled: u64 = 0,
    watched_pushes_came_back: u64 = 0,
    rng: Random.DefaultPrng,
    replay: Replay,
    /// Per-environment scratch, allocated once.
    reference_data: rbt.Data,
    sim_state: State,
    reference_state: State,
    /// Per body: exempt from `unexpected_contact` (`Task.contact_exempt`, resolved at init).
    contact_exempt: []bool,
    /// The head's body index (`Task.head_body`, resolved at init), or null: no head term.
    head: ?usize,
    /// Scratch for a start's perturbation (`startAt`), on the calling thread.
    scratch: []f32,
    /// One physics scratch per task (`Options.physics_threads`, `DriveScratch`), and each character's flag of a
    /// collision world that failed in its step - raised on whichever thread, reported after they all finish.
    drive_scratches: []DriveScratch,
    drive_failed: []bool,
    /// A HAND ON EACH CHARACTER (`rbt.Pull`), or null: set by a viewer between steps - a mouse that has grabbed one
    /// of the character's bodies - and added to its joints' forces at each physics step, after the servo's
    /// (`driveOnce`). The fleet never sets one itself; every learner's fleet leaves them null.
    pulls: []?rbt.Pull,
    /// The threads the physics' tasks run on, given by the program that owns them (`Options.physics_threads`); null:
    /// every character's step on the calling thread.
    physics_io: ?Io = null,
    /// Each environment's reward on the last step, and whether its episode ended there - which a
    /// learner needs per environment, not averaged: an advantage is about one trajectory.
    rewards: []f32,
    /// Each environment's SUPERMIMIC REWARD for the step just taken (`SuperMimicScales`): the tracking terms' total
    /// and the two penalties - beside `rewards`, for the judge's measure of a run on SuperMimic's scale.
    super_mimic_rewards: []f32,
    /// Each environment's tracking quality after the step just taken (`QualityStep`), when the fleet measures it
    /// (`Options.measures_quality`).
    quality: []QualityStep,
    /// How many numbers each environment's action has (`actionWidth`): the joints' offsets, then each limb's
    /// stiffness where `Options.limb_stiffness` is on.
    action_width: usize,
    /// The action each environment was given at its previous step (`action_width` numbers each), for SuperMimic's
    /// action rate; zero at an episode's start (`startAt`).
    previous_actions: []f32,
    /// The action each environment's servo is driven by (`action_width` numbers each): the filter's state
    /// (`Options.action_filter`), moved toward the policy's action before each physics step; zero at an episode's
    /// start.
    applied_actions: []f32,
    /// EACH CHARACTER's EFFORT through the current decision (`rbt.EffortSums`), zeroed at each decision's start.
    effort_sums: []rbt.EffortSums,
    /// The character's weight, its effort's torque scale (`rbt.characterWeight`).
    character_weight: f32,
    /// EACH BALL's ROTATION BOX over all the fleet's clips (`rbt.rotationBoxes`): its servo's targets clamped into it,
    /// its pose charged past it by SuperMimic's soft limit. Null for a joint that is not a ball.
    rotation_boxes: []?rbt.RotationBox,
    /// THE COUNTER-BASED DRAWS' STATE (`rbt.drawWord`): the run's seed folded to 32 bits; each character's episode
    /// number, advanced at each restart - the counter of every draw its start makes; the decision number, advanced at
    /// each step - the counter of a decision's pushes. No stream to carry: the device draws the same numbers.
    draw_seed: u32,
    episode_numbers: []u32,
    decision_number: u32,
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
    /// Physics steps left in each environment's aftermath (`Options.aftermath_steps`), zero when it is in none, and
    /// whether its last step was one of them: after its failure, so not time at risk - a learner counting exposure
    /// for a time to failure leaves such steps out.
    aftermath_steps_left: []u32,
    in_aftermath: []bool,
    /// Each character's steps in a row of its aftermath holding the reference again (`Options.return_steps`), its
    /// steps since its last loss, and whether the last step was the one it RETURNED on - that return's length being
    /// `steps_since_loss`, where `returned` is set: what a learner counts returns and their time from.
    return_streaks: []u32,
    steps_since_loss: []u32,
    returned: []bool,
    /// The decisions left of each character's watched push (`rbt.PushBrake`), 0 for none: while it lasts the
    /// character takes no other push.
    watched_push_left: []u32,
    /// Every return since the fleet was made, and their lengths' sum in steps.
    returns: u64 = 0,
    return_steps_sum: u64 = 0,
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
        const clock: u32 = options.decide_every;
        assertf(clock >= 1, @src(), "a clock of {d} physics steps a decision", .{clock});
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
            assertf(
                clip.nq == m.coordinate_count,
                @src(),
                "clip poses are {d} long, the model wants {d}",
                .{ clip.nq, m.coordinate_count },
            );
            assertf(clip.frame_count > 2, @src(), "a clip of {d} frames is too short to start in", .{clip.frame_count});
        }
        const action_width: usize = actionWidth(m, options.limb_stiffness);
        const fleet: *Fleet = try gpa.create(Fleet);
        errdefer gpa.destroy(fleet);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        fleet.* = .{
            .gpa = undefined,
            .arena = undefined,
            .character_arenas = &.{},
            .m = undefined,
            .clips = undefined,
            .root = undefined,
            .options = undefined,
            .data = undefined,
            .worlds = undefined,
            .bridges = undefined,
            .clip_of = undefined,
            .bins_start = &.{},
            .bin_returns = &.{},
            .bin_probabilities = &.{},
            .bin_softmax = &.{},
            .ended_this_decision = &.{},
            .start_bins = &.{},
            .episode_discounted_returns = &.{},
            .episode_discount_powers = &.{},
            .episode_reward_sums = &.{},
            .episode_decisions = &.{},
            .bin_history_weights = &.{},
            .frame = undefined,
            .segment = undefined,
            .steps = undefined,
            .next_segment = undefined,
            .pushes_given = undefined,
            .push_speed_sum = undefined,
            .rng = undefined,
            .replay = undefined,
            .reference_data = undefined,
            .sim_state = undefined,
            .reference_state = undefined,
            .contact_exempt = undefined,
            .head = undefined,
            .drive_scratches = undefined,
            .drive_failed = undefined,
            .pulls = undefined,
            .scratch = undefined,
            .rewards = undefined,
            .super_mimic_rewards = undefined,
            .quality = undefined,
            .action_width = action_width,
            .previous_actions = undefined,
            .applied_actions = undefined,
            .effort_sums = undefined,
            .character_weight = undefined,
            .rotation_boxes = undefined,
            .draw_seed = undefined,
            .episode_numbers = undefined,
            .decision_number = 0,
            .dones = undefined,
            .failures = undefined,
            .ends = undefined,
            .terminal = undefined,
            .terminal_frame = undefined,
            .terminal_clip = undefined,
            .aftermath_steps_left = undefined,
            .in_aftermath = undefined,
            .return_streaks = undefined,
            .steps_since_loss = undefined,
            .returned = undefined,
            .watched_push_left = undefined,
        };
        fleet.arena = ArenaAllocator.init(gpa);
        errdefer fleet.arena.deinit();
        const owned: Allocator = fleet.arena.allocator();
        fleet.* = .{
            .gpa = gpa,
            .arena = fleet.arena,
            .character_arenas = try owned.alloc(ArenaAllocator, options.envs),
            .m = m,
            .clips = try owned.dupe(*const dance.Clip, clips),
            .root = rootBody(m),
            .options = options,
            .data = try owned.alloc(rbt.Data, options.envs),
            .worlds = try owned.alloc(zimrphysics.World, options.envs),
            .bridges = try owned.alloc(robot_physics.Bridge, options.envs),
            .clip_of = try owned.alloc(usize, options.envs),
            .bins_start = try curriculumBinStarts(owned, clips, options.curriculum),
            .bin_returns = &.{},
            .bin_probabilities = &.{},
            .bin_softmax = &.{},
            .start_bins = &.{},
            .episode_discounted_returns = &.{},
            .episode_discount_powers = &.{},
            .episode_reward_sums = &.{},
            .episode_decisions = &.{},
            .bin_history_weights = &.{},
            .frame = try owned.alloc(u32, options.envs),
            .segment = try owned.alloc(u32, options.envs),
            .steps = try owned.alloc(u32, options.envs),
            .rewards = try owned.alloc(f32, options.envs),
            .super_mimic_rewards = try owned.alloc(f32, options.envs),
            .quality = try owned.alloc(QualityStep, options.envs),
            .action_width = action_width,
            .previous_actions = try owned.alloc(f32, options.envs * action_width),
            .applied_actions = try owned.alloc(f32, options.envs * action_width),
            .effort_sums = try owned.alloc(rbt.EffortSums, options.envs),
            .character_weight = rbt.characterWeight(m),
            .rotation_boxes = try owned.alloc(?rbt.RotationBox, m.joint_count),
            .ended_this_decision = try owned.alloc(bool, options.envs),
            .draw_seed = rbt.drawSeed(options.seed),
            .episode_numbers = try owned.alloc(u32, options.envs),
            .decision_number = 0,
            .dones = try owned.alloc(bool, options.envs),
            .failures = try owned.alloc(bool, options.envs),
            .ends = try owned.alloc(End, options.envs),
            .terminal = try owned.alloc(State, options.envs),
            .terminal_frame = try owned.alloc(u32, options.envs),
            .terminal_clip = try owned.alloc(usize, options.envs),
            .aftermath_steps_left = try owned.alloc(u32, options.envs),
            .in_aftermath = try owned.alloc(bool, options.envs),
            .return_streaks = try owned.alloc(u32, options.envs),
            .steps_since_loss = try owned.alloc(u32, options.envs),
            .returned = try owned.alloc(bool, options.envs),
            .watched_push_left = try owned.alloc(u32, options.envs),
            .next_segment = 0,
            .push_top = .startingWith(options.pushes.full_hours),
            .pushes_given = 0,
            .push_speed_sum = 0,
            .rng = Random.DefaultPrng.init(options.seed),
            .replay = try Replay.init(owned, m, options.envs, options.capacity, action_width),
            .reference_data = try rbt.Data.init(owned, m),
            .sim_state = try State.init(owned, m.body_count),
            .reference_state = try State.init(owned, m.body_count),
            .contact_exempt = try contactExemptMask(
                owned,
                m.body_count,
                options.task.contact_exempt,
                options.body_names,
            ),
            .head = try headBody(options.task.head_body, options.body_names),
            .scratch = try owned.alloc(f32, m.dof_count),
            .drive_scratches = try owned.alloc(DriveScratch, @max(options.physics_threads, 1)),
            .drive_failed = try owned.alloc(bool, options.envs),
            .pulls = try owned.alloc(?rbt.Pull, options.envs),
        };
        @memset(fleet.pulls, null);
        @memset(fleet.episode_numbers, 0);
        @memset(fleet.ended_this_decision, false);
        // Each ball's rotation box over every frame of every clip (`rbt.rotationBoxes`).
        var frame_total: usize = 0;
        for (clips) |box_clip| {
            frame_total += box_clip.frame_count;
        }
        const captured: []f32 = try gpa.alloc(f32, frame_total * m.coordinate_count);
        defer gpa.free(captured);
        var captured_frame: usize = 0;
        for (clips) |box_clip| {
            const root_len: usize = box_clip.nq - m.coordinate_count;
            for (0..box_clip.frame_count) |frame| {
                const pose: []const f32 = box_clip.pose(frame)[root_len..];
                @memcpy(captured[captured_frame * m.coordinate_count ..][0..m.coordinate_count], pose);
                captured_frame += 1;
            }
        }
        rbt.rotationBoxes(m, captured, frame_total, options.rotation_box_margin, fleet.rotation_boxes);
        // Every physics task's scratch, and no collision world failed yet.
        for (fleet.drive_scratches) |*drive| {
            drive.* = try DriveScratch.init(owned, m);
        }
        @memset(fleet.drive_failed, false);
        // The curriculum's running failure rates and long-run weights, one per bin, none yet.
        const bin_count: usize = if (fleet.bins_start.len > 0) fleet.bins_start[fleet.bins_start.len - 1] else 0;
        fleet.bin_returns = try owned.alloc(f32, bin_count);
        @memset(fleet.bin_returns, 0);
        fleet.bin_probabilities = try owned.alloc(f32, bin_count);
        fleet.bin_softmax = try owned.alloc(f32, bin_count);

        fleet.start_bins = try owned.alloc(usize, options.envs);
        @memset(fleet.start_bins, 0);
        fleet.episode_discounted_returns = try owned.alloc(f32, options.envs);
        @memset(fleet.episode_discounted_returns, 0);
        fleet.episode_discount_powers = try owned.alloc(f32, options.envs);
        @memset(fleet.episode_discount_powers, 1);
        fleet.episode_reward_sums = try owned.alloc(f32, options.envs);
        @memset(fleet.episode_reward_sums, 0);
        fleet.episode_decisions = try owned.alloc(u32, options.envs);
        @memset(fleet.episode_decisions, 0);
        fleet.bin_history_weights = try owned.alloc(f32, bin_count);
        // Each character's data, collision world and bridge in its own arena (`character_arenas`): its physics
        // step allocates from nothing another character's can reach at the same time.
        for (fleet.character_arenas) |*character_arena| {
            character_arena.* = ArenaAllocator.init(gpa);
        }
        // They hold `gpa`'s memory, not the fleet arena's: a later failure must free them too.
        errdefer for (fleet.character_arenas) |*character_arena| {
            character_arena.deinit();
        };
        for (fleet.data, fleet.character_arenas) |*d, *character_arena| {
            d.* = try rbt.Data.init(character_arena.allocator(), m);
        }
        for (fleet.terminal) |*state| {
            state.* = try State.init(owned, m.body_count);
        }
        for (fleet.worlds, fleet.bridges, fleet.data, fleet.character_arenas) |*world, *bridge, *d, *character_arena| {
            const character_owned: Allocator = character_arena.allocator();
            world.* = try floorWorld(character_owned, options.task.floor_friction);
            bridge.* = try robot_physics.Bridge.init(character_owned, world, m, d, 256);
            bridge.listen(world);
        }
        @memset(fleet.in_aftermath, false);
        @memset(fleet.return_streaks, 0);
        @memset(fleet.steps_since_loss, 0);
        @memset(fleet.returned, false);
        @memset(fleet.watched_push_left, 0);
        // The curriculum's first round, before the first starts read it (`refreshStartBins`) - its long-run averages
        // first set uniform within each clip, so a mixture never divides by an empty history.
        if (fleet.bins_start.len > 0) {
            for (0..clips.len) |clip_index| {
                const clip_bins_first: usize = fleet.bins_start[clip_index];
                const clip_bins_end: usize = fleet.bins_start[clip_index + 1];
                const clip_bins: []f32 = fleet.bin_history_weights[clip_bins_first..clip_bins_end];
                @memset(clip_bins, 1.0 / float(clip_bins.len));
            }
            fleet.refreshStartBins();
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
        // Every character's arena - its world's memory with it.
        for (self.character_arenas) |*character_arena| {
            character_arena.deinit();
        }
        self.reference_data.deinit();
        const gpa: Allocator = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Start an environment somewhere new: a random clip, a random frame, a fresh segment.
    /// A new episode for `env` at a RANDOM clip and frame - reference-state initialisation (`startAt`).
    pub fn restart(self: *Fleet, env: usize) void {
        self.beginEpisode(env);
        const episode: u32 = self.episode_numbers[env];
        const world: u32 = @intCast(env);
        const clip_count: u32 = @intCast(self.clips.len);
        const clip_index: usize = switch (self.options.clip_assignment) {
            .random => rbt.drawBelow(self.draw_seed, world, episode, .start_clip, 0, clip_count),
            .by_character => env % self.clips.len,
        };
        const frame: usize = self.drawStartFrame(env, clip_index);
        self.startEpisodeAt(env, clip_index, frame);
        // A start in trouble (`Pushes.start_share`): drawn only when the fleet asks for them, so a fleet without any
        // consumes its random stream as it always has.
        const pushes: Pushes = self.options.pushes;
        if (pushes.start_share > 0) {
            const top_share: f32 = self.pushTopShare();
            const trouble_draw: f32 = rbt.drawUniform(self.draw_seed, world, episode, .start_in_trouble, 0);
            const starts_in_trouble: bool = trouble_draw < pushes.start_share * top_share;
            if (starts_in_trouble) {
                const top_speed: f32 = self.pushTopSpeed();
                const direction_draw: f32 = rbt.drawUniform(self.draw_seed, world, episode, .start_push_direction, 0);
                const push_direction_rad: f32 = 2.0 * pi * direction_draw;
                self.push(env, top_speed, push_direction_rad);
                self.pushes_given += 1;
                self.push_speed_sum += top_speed;
            }
        }
    }

    /// How long one of this fleet's steps lasts: one DECISION, `Options.decide_every` physics steps of the model's
    /// timestep. Every count of the fleet's steps becomes time through this.
    pub fn decisionSeconds(self: *const Fleet) f32 {
        return secondsPerDecision(self.m.opt.timestep, self.options.decide_every);
    }

    /// The last frame an episode may start at on `clip`: frame 1 is the first (a reference velocity needs the frame
    /// before it), and a start must leave a whole decision's frames before the clip's last.
    fn lastStartFrame(self: *const Fleet, clip: *const dance.Clip) usize {
        const decision_frames: usize = self.options.decide_every;
        return clip.frame_count - 1 - decision_frames;
    }

    /// A FINISHED EPISODE INTO ITS START BIN (`rbt.foldEndedEpisode`): what the character's arrays hold of it - its
    /// start bin, its discounted return, its rewards' sum and its decisions; `ended_by_failure` false for an episode
    /// cut short, whose remaining return is then estimated. A device's host folds a device's episodes by the same
    /// function, from what the device kept of each.
    fn foldEpisodeIntoStartBin(self: *Fleet, env: usize, ended_by_failure: bool) void {
        const curriculum: ResetCurriculum = self.options.curriculum;
        const ended: rbt.EndedEpisode = .{
            .start_bin = @intCast(self.start_bins[env]),
            .discounted_return = self.episode_discounted_returns[env],
            .reward_sum = self.episode_reward_sums[env],
            .decisions = self.episode_decisions[env],
            .ended_by_failure = ended_by_failure,
        };
        rbt.foldEndedEpisode(curriculum.rule, curriculum.discount, self.bin_returns, ended);
    }

    /// The frame a new episode on clip `clip_index` starts at: uniform over the clip without a curriculum - one draw
    /// from the fleet's stream, as always - and with one, from its mixture (`ResetCurriculum`): uniform, toward the
    /// bins failing most now, or by the bins' long-run weights. Never the clip's first or last frame: a start needs a
    /// frame before it (its velocity) and one after (its first target).
    pub fn drawStartFrame(self: *Fleet, env: usize, clip_index: usize) usize {
        const clip: *const dance.Clip = self.clips[clip_index];
        const curriculum: ResetCurriculum = self.options.curriculum;
        const uniform_frame: bool = curriculum.bin_seconds <= 0;
        if (uniform_frame) {
            const world: u32 = @intCast(env);
            const last: u32 = @intCast(self.lastStartFrame(clip));
            return 1 + rbt.drawBelow(self.draw_seed, world, self.episode_numbers[env], .start_frame, 0, last);
        }
        const bins_first: usize = self.bins_start[clip_index];
        const bins_end: usize = self.bins_start[clip_index + 1];
        // SuperMimic's mixture over this clip's bins, then a bin by one draw against its running sums, then a frame
        // within the bin by another - the character's own draws for this episode (`rbt.drawWord`).
        const softmax: []const f32 = self.bin_softmax[bins_first..bins_end];
        const long_run: []const f32 = self.bin_history_weights[bins_first..bins_end];
        const probabilities: []f32 = self.bin_probabilities[bins_first..bins_end];
        rbt.startBinMixture(curriculum.rule, softmax, long_run, probabilities);
        const world: u32 = @intCast(env);
        const episode: u32 = self.episode_numbers[env];
        const bin_draw: f32 = rbt.drawUniform(self.draw_seed, world, episode, .start_frame, 1);
        var running_total: f32 = 0;
        const bin: usize = for (probabilities, 0..) |probability, bin_index| {
            running_total += probability;
            if (bin_draw < running_total) {
                break bin_index;
            }
        } else probabilities.len - 1;
        const bin_frames: usize = binFrames(clip, curriculum);
        const bin_first: usize = bin * bin_frames;
        const bin_end: usize = @min(bin_first + bin_frames, clip.frame_count);
        const bin_width: u32 = @intCast(@max(bin_end -| bin_first, 1));
        const within: usize = rbt.drawBelow(self.draw_seed, world, episode, .start_frame, 2, bin_width);
        const last_start: usize = self.lastStartFrame(clip);
        return clamp(bin_first + within, 1, last_start);
    }

    /// SuperMimic's reward for environment `env`'s step just taken (`SuperMimicScales`): its tracking terms for `sim`
    /// against the reference state at the step's frame, the action rate of `actions` (every environment's, as the
    /// step was given them) against the environment's previous ones, and the joints' excess past their soft range -
    /// and the previous action brought up to date.
    fn superMimicReward(self: *Fleet, env: usize, actions: []const f32, sim: State) f32 {
        const scales: SuperMimicScales = self.options.task.super_mimic;
        const action_size: usize = self.action_width;
        const action: []const f32 = actions[env * action_size ..][0..action_size];
        const previous_action: []f32 = self.previous_actions[env * action_size ..][0..action_size];
        const tracking: SuperMimicTracking = superMimicTracking(sim, self.reference_state, self.root, scales);
        const action_rate: f32 = superMimicActionRate(action, previous_action);
        const joint_positions: []const f32 = self.data[env].joint_positions;
        const boxes: []const ?rbt.RotationBox = self.rotation_boxes;
        const joint_excess: f32 = superMimicJointLimitExcess(self.m, boxes, joint_positions, scales.soft_limit_share);
        @memcpy(previous_action, action);
        // The servo's effort through the decision just taken (`rbt.EffortSums`), as means: the torque's over the
        // actuated dofs and the physics steps, the energy's per unit of mass.
        const effort: rbt.EffortSums = self.effort_sums[env];
        const actuated: f32 = float(self.m.dof_count - rbt.rootDofCount(self.m));
        const steps_taken: f32 = float(self.options.decide_every);
        const effort_cost: f32 = rbt.effortCost(effort, scales, actuated, steps_taken, rbt.characterMass(self.m));
        const penalties: f32 = scales.action_rate_weight * action_rate + scales.joint_limit_weight * joint_excess +
            effort_cost;
        return tracking.total + penalties;
    }

    /// A NEW EPISODE FOR CHARACTER `env` at `clip_index`'s `frame`: its episode number advanced (`beginEpisode`), then
    /// its start (`startEpisodeAt`). Every start advances the number, so no two starts of a character share their
    /// draws.
    pub fn startAt(self: *Fleet, env: usize, clip_index: usize, frame: usize) void {
        self.beginEpisode(env);
        self.startEpisodeAt(env, clip_index, frame);
    }

    /// The character's next episode number: the counter of every draw its start makes (`rbt.drawWord`) - its clip, its
    /// frame, its start noise, a start in trouble. Advanced once per start, before any of them is drawn.
    fn beginEpisode(self: *Fleet, env: usize) void {
        self.episode_numbers[env] +%= 1;
    }

    /// EVERY CHARACTER WHOSE EPISODE ENDED THIS DECISION, restarted together - after every finished episode is folded
    /// into its start bin, with the curriculum refreshed once for the round (`refreshStartBins`), as SuperMimic's
    /// sampler draws every start of a step in one call. No character's start depends on another's place in the step's
    /// loop, and the device, resetting its worlds in parallel, can match it.
    fn restartEnded(self: *Fleet) void {
        const any_ended: bool = for (self.ended_this_decision) |ended| {
            if (ended) {
                break true;
            }
        } else false;
        if (!any_ended) {
            return;
        }
        if (self.bins_start.len > 0) {
            self.refreshStartBins();
        }
        for (self.ended_this_decision, 0..) |*ended, env| {
            if (!ended.*) {
                continue;
            }
            ended.* = false;
            self.restart(env);
        }
    }

    /// THE CURRICULUM's ROUND, once per decision with any start: each clip's softmax over its bins' returns
    /// (`rbt.startBinSoftmax`), folded into its long-run average (`rbt.foldStartBinHistory`). Every start of the round
    /// reads both, unchanged, through `rbt.startBinMixture`.
    pub fn refreshStartBins(self: *Fleet) void {
        const curriculum: ResetCurriculum = self.options.curriculum;
        const return_scale: f32 = curriculum.returnScale();
        for (0..self.clips.len) |clip_index| {
            const bins_first: usize = self.bins_start[clip_index];
            const bins_end: usize = self.bins_start[clip_index + 1];
            const returns: []const f32 = self.bin_returns[bins_first..bins_end];
            const softmax: []f32 = self.bin_softmax[bins_first..bins_end];
            const long_run: []f32 = self.bin_history_weights[bins_first..bins_end];
            rbt.startBinSoftmax(curriculum.rule, returns, return_scale, softmax);
            rbt.foldStartBinHistory(curriculum.rule, long_run, softmax);
        }
    }

    /// EVERY CLIP's MIXTURE AS RUNNING SUMS, into `out_sums`, one per bin of every clip: within each clip the bins'
    /// probabilities as they stand now (`rbt.startBinMixture` of the clip's softmax and long-run weights), summed in
    /// order - the first bin's probability, the first two's, up to 1 at the clip's last - restarting at each clip. A
    /// start's bin is the first whose sum passes its draw (`drawStartFrame`); a device draws against these sums
    /// (robotgpu's `begin_reset`), and is given them with the bins before its first decision.
    pub fn startBinRunningSums(self: *const Fleet, out_sums: []f32) void {
        // A fleet without a curriculum has no bins, and no sums.
        if (self.bins_start.len == 0) {
            return;
        }
        const rule: rbt.StartCurriculumRule = self.options.curriculum.rule;
        for (0..self.clips.len) |clip_index| {
            const bins_first: usize = self.bins_start[clip_index];
            const bins_end: usize = self.bins_start[clip_index + 1];
            const softmax: []const f32 = self.bin_softmax[bins_first..bins_end];
            const long_run: []const f32 = self.bin_history_weights[bins_first..bins_end];
            const clip_sums: []f32 = out_sums[bins_first..bins_end];
            rbt.startBinMixture(rule, softmax, long_run, clip_sums);
            var running_sum: f32 = 0;
            for (clip_sums) |*probability_then_sum| {
                running_sum += probability_then_sum.*;
                probability_then_sum.* = running_sum;
            }
        }
    }

    /// A new episode for `env` EXACTLY at `frame` of clip `clip_index`: the character put on the reference there
    /// (and rested on the floor, and pushed off it by `start_noise`, as the task says), its clock at that frame.
    /// `restart` calls it with a random clip and frame - the random draws in the same order as always, so a fleet's
    /// runs are bit-for-bit what they were; a JUDGE calls it with chosen ones (`judge`).
    fn startEpisodeAt(self: *Fleet, env: usize, clip_index: usize, frame: usize) void {
        // The curriculum's view of the new episode: the bin it starts in, nothing earned yet.
        if (self.bins_start.len > 0) {
            const bin_in_clip: usize = frame / binFrames(self.clips[clip_index], self.options.curriculum);
            const bins_first: usize = self.bins_start[clip_index];
            const bins_end: usize = self.bins_start[clip_index + 1];
            self.start_bins[env] = @min(bins_first + bin_in_clip, bins_end - 1);
            self.episode_discounted_returns[env] = 0;
            self.episode_discount_powers[env] = 1;
            self.episode_reward_sums[env] = 0;
            self.episode_decisions[env] = 0;
        }
        const clip: *const dance.Clip = self.clips[clip_index];
        const decision_frames: usize = self.options.decide_every;
        const leaves_a_decision: bool = frame + decision_frames < clip.frame_count;
        assertf(frame >= 1 and leaves_a_decision, @src(), "start frame {d} of a {d}-frame clip", .{
            frame,
            clip.frame_count,
        });
        self.clip_of[env] = clip_index;
        resetToFrame(self.m, &self.data[env], clip, frame);
        if (self.options.task.rest_on_floor) {
            _ = rbt.restOnFloor(self.m, &self.data[env], self.options.task.rest_clearance);
        }
        // The start's noise from its own draws: the character, its episode (`rbt.drawNormal`).
        const world: u32 = @intCast(env);
        const episode: u32 = self.episode_numbers[env];
        const source: NoiseSource = .{ .drawn = .{ .seed = self.draw_seed, .world = world, .episode = episode } };
        const clearance: f32 = self.options.task.rest_clearance;
        perturbStart(self.m, &self.data[env], self.options.start_noise, source, clearance, self.scratch);
        self.frame[env] = @intCast(frame);
        self.steps[env] = 0;
        // No aftermath in a fresh episode. `in_aftermath` is left alone: it describes the step just taken, and the step
        // that ends an aftermath is one of its steps, even though the episode it ended is replaced here.
        self.aftermath_steps_left[env] = 0;
        self.return_streaks[env] = 0;
        // Nor a watched push: one that was pending ended with the episode before (`rbt.settleWatchedPush`).
        self.watched_push_left[env] = 0;
        const action_size: usize = self.action_width;
        @memset(self.previous_actions[env * action_size ..][0..action_size], 0);
        // The filter starts at rest: the servo aims at the reference until the policy has spoken.
        @memset(self.applied_actions[env * action_size ..][0..action_size], 0);
        self.effort_sums[env] = .{};
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
        const root_len: usize = clip.nq - self.m.coordinate_count;
        @memcpy(d.joint_positions, clip.pose(at)[root_len..]);
        const previous: usize = if (at == 0) 0 else at - 1;
        rbt.differentiatePos(
            self.m,
            d.joint_velocities,
            clip.pose(previous)[root_len..],
            clip.pose(at)[root_len..],
            clip.frame_time,
        );
        d.stage = .stale;
        rbt.forward(self.m, d);
        stateOf(self.m, d, out);
    }

    /// THE REFERENCE's BODIES at every frame of `clip`, for the device's judgement: the reference's state
    /// (`referenceStateInto`, with the caller's scratch `d` and `state`), each body as `rbt.reference_body_numbers`
    /// numbers - its position, rotation, velocity and angular velocity, then its lowest point - frame after frame.
    /// `out` is `clip.frame_count * m.body_count * rbt.reference_body_numbers` long.
    pub fn clipReferenceBodies(
        self: *Fleet,
        clip: *const dance.Clip,
        d: *rbt.Data,
        state: *State,
        out: []f32,
    ) void {
        const body_count: usize = self.m.body_count;
        const per_body: usize = rbt.reference_body_numbers;
        const frame_size: usize = body_count * per_body;
        assertf(out.len == clip.frame_count * frame_size, @src(), "clipReferenceBodies: {d} numbers, want {d}", .{
            out.len,
            clip.frame_count * frame_size,
        });
        for (0..clip.frame_count) |frame| {
            self.referenceStateInto(clip, @intCast(frame), d, state);
            for (0..body_count) |body| {
                const at: []f32 = out[frame * frame_size + body * per_body ..][0..per_body];
                at[0..4].* = state.positions[body];
                at[4..8].* = state.rotations[body];
                at[8..12].* = state.velocities[body];
                at[12..16].* = state.angular[body];
                at[16..20].* = .{ state.lowest[body], 0, 0, 0 };
            }
        }
    }

    /// THE REFERENCE's HALF OF THE OBSERVATION at every frame of `clip` - what `observe` writes second, computed once
    /// for a clip rather than at every decision: frame after frame, `localSize` numbers each, the reference's state
    /// (`referenceStateInto`, with the caller's scratch `d` and `state`) in the root's frame (`local`). `out` is
    /// `clip.frame_count * localSize(m.body_count)` long. The device's observation reads these rows.
    pub fn clipReferenceFeatures(
        self: *Fleet,
        clip: *const dance.Clip,
        d: *rbt.Data,
        state: *State,
        out: []f32,
    ) void {
        const row_size: usize = localSize(self.m.body_count);
        assertf(out.len == clip.frame_count * row_size, @src(), "clipReferenceFeatures: {d} numbers, want {d}", .{
            out.len,
            clip.frame_count * row_size,
        });
        for (0..clip.frame_count) |frame| {
            self.referenceStateInto(clip, @intCast(frame), d, state);
            local(state.*, self.root, out[frame * row_size ..][0..row_size]);
        }
    }

    /// The reference's whole-body state at `frame`, into `reference_state`.
    fn referenceStateAt(self: *Fleet, clip: *const dance.Clip, frame: u32) void {
        const at: usize = @min(@as(usize, frame), clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.coordinate_count;
        @memcpy(self.reference_data.joint_positions, clip.pose(at)[root_len..]);
        const previous: usize = if (at == 0) 0 else at - 1;
        rbt.differentiatePos(
            self.m,
            self.reference_data.joint_velocities,
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
        @memcpy(d.joint_positions, self.replay.poseAt(env, index));
        @memcpy(d.joint_velocities, self.replay.velocityAt(env, index));
        d.stage = .stale;
        rbt.forward(self.m, d);
        stateOf(self.m, d, out);
    }

    /// The servo targets a recorded frame was driven toward: its reference pose, nudged by the
    /// action that was taken. `scratch` is `m.dof_count`, `out` is `m.coordinate_count`.
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
        const root_len: usize = clip.nq - self.m.coordinate_count;
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

    /// Drive one character one frame: the action filtered into `applied` (the character's filter state,
    /// `Options.action_filter`), turned into servo targets on the reference, the servo run, the step taken, and the
    /// data left forward-current.
    ///
    /// Shared so that a planner imagining a step and the fleet taking one cannot drift apart: an
    /// imagined step that is not the step actually taken is a plan for a different robot.
    pub fn driveOnce(
        self: *const Fleet,
        d: *rbt.Data,
        world: *zimrphysics.World,
        bridge: *robot_physics.Bridge,
        clip: *const dance.Clip,
        frame: u32,
        action: []const f32,
        applied: []f32,
        effort: *rbt.EffortSums,
        drive: *DriveScratch,
        pull: ?rbt.Pull,
    ) !void {
        const root_len: usize = clip.nq - self.m.coordinate_count;
        // The servo aims where the reference is GOING: during the step from frame i to i+1 it drives
        // toward pose i+1, as SuperTrack's PD targets do (exp(a/2 o) x k_{i+1}). Aiming at pose i left
        // every step a frame (17 ms) behind the motion it was meant to follow - and the tracking error
        // measured after the step is against pose i+1, so aim and score now agree. Clamped at the end.
        const at: usize = @min(@as(usize, frame) + 1, clip.frame_count - 1);
        // The action filtered in its two parts, each at its own share: the joints' offsets (onto the reference) at
        // `action_filter`, each limb's stiffness (into its spring) at `stiffness_filter` (`actionWidth`).
        const joint_numbers: usize = actionSize(self.m);
        const asked_offsets: []const f32 = action[0..joint_numbers];
        const asked_stiffnesses: []const f32 = action[joint_numbers..];
        const filtered_offsets: []f32 = applied[0..joint_numbers];
        const filtered_stiffnesses: []f32 = applied[joint_numbers..];
        filterAction(self.options.action_filter, asked_offsets, filtered_offsets);
        filterAction(self.options.stiffness_filter, asked_stiffnesses, filtered_stiffnesses);
        const applied_offsets: []const f32 = filtered_offsets;
        const reference_pose: []const f32 = clip.pose(at)[root_len..];
        const scale: f32 = self.options.action_scale;
        applyAction(self.m, reference_pose, applied_offsets, scale, drive.scratch, drive.targets);
        // The balls' targets clamped into their boxes: the servo never aims where no capture went.
        rbt.clampBalls(self.m, self.rotation_boxes, drive.targets);
        const stiffness_of_limbs: rbt.LimbStiffness = .{
            .limb_of_dof = self.m.dof_limb,
            .stiffness = applied[joint_numbers..],
        };
        const limbs: ?rbt.LimbStiffness = if (self.options.limb_stiffness) stiffness_of_limbs else null;
        clampHinges(self.m, drive.targets);
        // Only when something made the data stale - a restart, a shove, a reset. Every step ENDS
        // with the stages the next one reads, and nothing writes to the data between that and
        // here, so recomputing them would produce the same numbers from the same inputs:
        // measured, that was 28% of a step (127 of 452 us) spent reproducing what was already
        // there. The stage watermark is what makes skipping it safe rather than hopeful.
        if (!d.stage.atLeast(.velocity)) {
            rbt.forward(self.m, d);
        }
        // Collide first, so the step that follows knows about the ground it is standing on.
        switch (self.options.task.contacts) {
            .robot_floor => {
                d.clearContacts();
                const ground: rbt.Floor = .{ .friction = self.options.task.floor_friction };
                try rbt.pushFloorContacts(self.m, d, ground);
            },
            .physics_engine => {
                try bridge.sync(world, self.m, d);
                try zimrphysics.step(world, clip.frame_time);
                bridge.harvest(d);
            },
        }
        rbt.biasForce(self.m, d);
        const gains: Gains = self.options.task.gains;
        // With feedforward, the velocity of the step the servo aims along: `frame` -> `frame + 1`. At the clip's end
        // the aim is clamped to the last pose - held still - and `referenceVelocity` is zero there, as it must be.
        // (It once asked for `at - 1`: at the end that was the last MOVING step's velocity, telling a joint that
        // should come to rest to keep going - and a one-frame clip underflowed.)
        const moving: ?[]const f32 = if (gains.velocity_feedforward) blk: {
            referenceVelocity(self.m, clip, frame, drive.target_velocity);
            break :blk drive.target_velocity;
        } else null;
        pdTorquesToward(
            self.m,
            d,
            drive.targets,
            moving,
            gains,
            limbs,
            clip.frame_time,
            drive.accel,
            drive.scratch,
            drive.dense,
            drive.full,
            drive.torque,
        );
        @memcpy(d.applied_joint_forces, drive.torque);
        // A hand pulling the character, when someone holds one (`pulls`): its force at this state, on the servo's.
        if (pull) |held| {
            _ = rbt.addPullForce(self.m, d, held, drive.pull_jacobian, d.applied_joint_forces);
        }
        // The servo's effort this physics step, dof after dof (`rbt.addDofEffort`): its torques, at the velocities they
        // act through.
        for (rbt.rootDofCount(self.m)..self.m.dof_count) |dof| {
            const timestep: f32 = self.m.opt.timestep;
            const velocity: f32 = d.joint_velocities[dof];
            const weight: f32 = self.character_weight;
            rbt.addDofEffort(effort, drive.torque[dof], velocity, timestep, weight);
        }
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

    /// Every character's physics step (`driveOnce`): split into `drive_scratches.len` tasks of consecutive characters
    /// run on `physics_io`'s threads and waited for, or - without threads, or with one task - in one loop here. A
    /// character's collision world failing is flagged (`drive_failed`) for the step to report.
    fn driveEveryCharacter(self: *Fleet, actions: []const f32) void {
        const envs: usize = self.options.envs;
        const task_count: usize = self.drive_scratches.len;
        const io: Io = self.physics_io orelse {
            driveCharacters(self, 0, envs, actions, 0);
            return;
        };
        if (task_count <= 1) {
            driveCharacters(self, 0, envs, actions, 0);
            return;
        }
        var group: Io.Group = .init;
        for (0..task_count) |task| {
            const first: usize = task * envs / task_count;
            const end: usize = (task + 1) * envs / task_count;
            group.async(io, driveCharacters, .{ self, first, end, actions, task });
        }
        group.await(io) catch |err| {
            assertUnreachable(@src(), "the physics' tasks were canceled: {s}", .{@errorName(err)});
        };
    }

    /// Characters [`first`, `end`)'s physics steps, in `task`'s scratch - one of `driveEveryCharacter`'s tasks.
    fn driveCharacters(
        self: *Fleet,
        first: usize,
        end: usize,
        actions: []const f32,
        task: usize,
    ) void {
        const size: usize = self.action_width;
        const drive: *DriveScratch = &self.drive_scratches[task];
        for (first..end) |env| {
            const clip: *const dance.Clip = self.clips[self.clip_of[env]];
            const action: []const f32 = actions[env * size ..][0..size];
            const at: u32 = self.frame[env];
            const applied: []f32 = self.applied_actions[env * size ..][0..size];
            self.drive_failed[env] = false;
            const character: *rbt.Data = &self.data[env];
            const world: *zimrphysics.World = &self.worlds[env];
            const bridge: *robot_physics.Bridge = &self.bridges[env];
            const effort: *rbt.EffortSums = &self.effort_sums[env];
            const pull: ?rbt.Pull = self.pulls[env];
            self.driveOnce(character, world, bridge, clip, at, action, applied, effort, drive, pull) catch {
                self.drive_failed[env] = true;
            };
        }
    }

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

    /// Whether character `env` lives on through an aftermath after a loss (`Options.aftermath_share`).
    ///
    /// The living-on characters are the first ones by index, so the split is fixed for the fleet's whole life: a
    /// character is either one that resets at a loss or one that lives on, never one, then the other. That keeps the
    /// population's two kinds of data in fixed proportion - the share asked for - whatever the order in which the
    /// characters happen to fail.
    pub fn keepsAftermath(self: *const Fleet, env: usize) bool {
        const character_count: f32 = float(self.options.envs);
        const living_on_count: usize = @round(self.options.aftermath_share * character_count);
        const is_among_living_on: bool = env < living_on_count;
        return is_among_living_on;
    }

    /// THIS FLEET's TRACKING TASK AS ONE VALUE (`rbt.TrackingSettings`): its floor, its servo's law, its action's scale
    /// and filters, the limbs' stiffness, its head, its episode's rules, its judgement's weights, its starts' rest and
    /// noise, its pushes and its curriculum - everything a simulator on a device needs to run this fleet's task
    /// (robotgpu's `CpuTwin.setTracking`, the host's `Sim.setTracking`). A device mirrors a fleet in two calls, this
    /// one and its setter, and the trainer and every check build the value here: one definition.
    /// `decision_filter` is the trainer's filter at each decision; a fleet has none of its own at that rate, so EVERY
    /// CALL STATES IT (`.{}` for none) - a setter writes every setting it is given, and shares left unsaid would
    /// switch a trainer's filter off. Built again whenever an option changes (a push schedule, an aftermath's
    /// length). The rotation boxes are the fleet's own slice: the value is used while the fleet lives.
    pub fn trackingSettings(self: *const Fleet, decision_filter: rbt.DecisionFilterShares) rbt.TrackingSettings {
        const task: Task = self.options.task;
        // What a device's simulator does not have: contacts other than the robot's own against the floor, a servo
        // damped toward the reference's velocity, the assist. A fleet with any of them is refused, not half-mirrored.
        const floor_contacts_only: bool = task.contacts == .robot_floor;
        assertf(floor_contacts_only, @src(), "trackingSettings: a device takes the robot's floor contacts only", .{});
        const plain_servo: bool = !task.gains.velocity_feedforward and task.gains.assist == 0.0;
        assertf(plain_servo, @src(), "trackingSettings: a device's servo has no velocity feedforward, no assist", .{});
        // The characters that live on through an aftermath are the first ones (`keepsAftermath`): their count.
        var living_on: u32 = 0;
        for (0..self.options.envs) |env| {
            if (self.keepsAftermath(env)) {
                living_on += 1;
            }
        }
        const curriculum: ResetCurriculum = self.options.curriculum;
        const settings: rbt.TrackingSettings = .{
            .floor = .{ .friction = task.floor_friction },
            .law = task.gains.law(),
            .servo_mode = .toward_rest,
            .action_scale = self.options.action_scale,
            .action_filter = self.options.action_filter,
            .stiffness_filter = self.options.stiffness_filter,
            .decision_filter = decision_filter.offsets,
            .decision_stiffness_filter = decision_filter.stiffness,
            .limb_stiffness = if (self.options.limb_stiffness) .enabled else .disabled,
            .head = self.head,
            .episode = .{
                .grace_steps = task.termination.grace_steps,
                .aftermath_steps = self.options.aftermath_steps,
                .return_steps = self.options.return_steps,
                .max_steps = self.options.max_steps,
                .aftermath_world_count = living_on,
                .decision_physics_steps = self.options.decide_every,
            },
            .judgement = .{
                .reward_weights = task.weights,
                .scales = task.super_mimic,
                .termination = task.termination,
            },
            .draw_seed = self.draw_seed,
            .clip_assignment = switch (self.options.clip_assignment) {
                .random => .random,
                .by_character => .by_character,
            },
            .rest_on_floor = if (task.rest_on_floor) .enabled else .disabled,
            .rest_clearance = task.rest_clearance,
            .start_noise_pose = self.options.start_noise.pose,
            .start_noise_velocity = self.options.start_noise.velocity,
            .push_every = self.options.pushes.every,
            .push_rate_per_second = self.options.pushes.rate_per_second,
            .push_speed_min = self.options.pushes.speed_min,
            .push_speed_max = self.options.pushes.speed_max,
            .push_start_share = self.options.pushes.start_share,
            .push_watched_share = self.options.pushes.watchedShare(),
            .push_watch_decisions = self.options.pushes.watchDecisions(self.decisionSeconds()),
            .decision_seconds = self.decisionSeconds(),
            .curriculum = if (curriculum.bin_seconds > 0) .enabled else .disabled,
            .curriculum_discount = curriculum.discount,
            .curriculum_rule = curriculum.rule,
            .curriculum_return_scale = curriculum.returnScale(),
            .rotation_boxes = self.rotation_boxes,
        };
        return settings;
    }

    /// THE TRAINING HOURS TOLD (`training_hours`), and the pushes' top advanced to them (`rbt.PushTop.advanceTo`):
    /// along the clock's line, where the last window's watched pushes allow it.
    pub fn tellTrainingHours(self: *Fleet, hours: f32) void {
        self.training_hours = hours;
        const pushes: Pushes = self.options.pushes;
        self.push_top.advanceTo(pushes.brake, pushes.full_hours, hours);
    }

    /// How far the range of push speeds has opened, from 0 to 1 (`rbt.PushTop`).
    pub fn pushTopShare(self: *const Fleet) f32 {
        return self.push_top.share;
    }

    /// The top of the range open now, in m/s: the speed the hardest push drawn can have, and a start in trouble's.
    pub fn pushTopSpeed(self: *const Fleet) f32 {
        const pushes: Pushes = self.options.pushes;
        return rbt.pushSpeed(pushes.speed_min, pushes.speed_max, self.push_top.share, 1.0);
    }

    /// The top's speed where the clock's line stands at the hours told - what the top would be had no window held
    /// it.
    pub fn pushLineSpeed(self: *const Fleet) f32 {
        const pushes: Pushes = self.options.pushes;
        const line_share: f32 = rbt.PushTop.lineShare(pushes.full_hours, self.training_hours);
        return rbt.pushSpeed(pushes.speed_min, pushes.speed_max, line_share, 1.0);
    }

    /// A WATCHED PUSH ENDED - kept, returned or failed - counted for the brake's window and the run's log. The
    /// fleet's step calls it for its own characters; a device's host for the worlds it reads back
    /// (`robotgpu_host.countTrainerDecisions`).
    pub fn noteWatchedPush(self: *Fleet, came_back: bool) void {
        self.watched_pushes_settled += 1;
        if (came_back) {
            self.watched_pushes_came_back += 1;
        }
        self.push_top.noteSettled(came_back);
    }

    /// The pushes as a decision draws them (`rbt.drawPush`): the settings, the top as far as it has opened, and the
    /// brake's watch in decisions.
    pub fn pushRule(self: *const Fleet) rbt.PushRule {
        const pushes: Pushes = self.options.pushes;
        const decision_seconds: f32 = self.decisionSeconds();
        const rule: rbt.PushRule = .{
            .every = pushes.every,
            .rate_per_second = pushes.rate_per_second,
            .speed_min = pushes.speed_min,
            .speed_max = pushes.speed_max,
            .top_share = self.push_top.share,
            .watched_share = pushes.watchedShare(),
            .watch_decisions = pushes.watchDecisions(decision_seconds),
            .decision_seconds = decision_seconds,
            .grace_steps = self.options.task.termination.grace_steps,
        };
        return rule;
    }

    /// Push character `env` (`Pushes`): its whole body's velocity changed by `speed` m/s in the horizontal direction
    /// `direction_rad` (0 along x, a quarter turn along y), and a new segment begun. What the random pushes, the
    /// scheduled ones and the recovery probe all do.
    ///
    /// WHY ONLY THE ROOT'S VELOCITY CHANGES. The character is a floating-base chain: its generalised velocity is the
    /// root's linear and angular velocity, then every joint's rate relative to its parent. Adding to the root's linear
    /// velocity alone moves every body by the same amount - the joints' relative rates are untouched - which is
    /// exactly an impulse of (total mass x speed) applied at the centre of mass: a push that shoves the whole body
    /// without twisting it. The first two numbers of the generalised velocity are the root's x and y.
    ///
    /// WHY A NEW SEGMENT. The replay's windows must be unbroken stretches of motion that a world model can predict
    /// from the state alone. A push comes from outside the state - nothing in the step before it could have seen it
    /// coming - so the stretch before it and the stretch after it are two segments, and no window spans the push.
    pub fn push(self: *Fleet, env: usize, speed: f32, direction_rad: f32) void {
        const character_data: *rbt.Data = &self.data[env];
        const velocity_change_x: f32 = speed * @cos(direction_rad);
        const velocity_change_y: f32 = speed * @sin(direction_rad);
        character_data.joint_velocities[0] += velocity_change_x;
        character_data.joint_velocities[1] += velocity_change_y;
        // The velocity changed behind the simulator's back: everything derived from it - the bodies' velocities a
        // policy's features read before the next step - is recomputed at once, so no reader sees the motion from
        // before the push (the device observes before it acts, to the same end).
        rbt.forward(self.m, character_data);
        self.segment[env] = self.next_segment;
        self.next_segment += 1;
    }

    /// Character `env`'s reference a frame on - except, where episodes do not restart (`Options.restarts_episodes`),
    /// at its clip's last frame with a goal after it: there the reference holds still and the character goes on
    /// tracking its last pose, until someone restarts it.
    fn advanceReferenceFrame(self: *Fleet, env: usize) void {
        const clip: *const dance.Clip = self.clips[self.clip_of[env]];
        const last_held_frame: usize = clip.frame_count - 2;
        const holds: bool = !self.options.restarts_episodes and self.frame[env] >= last_held_frame;
        if (holds) {
            return;
        }
        self.frame[env] += 1;
    }

    /// One PHYSICS STEP for every character, in tasks when the fleet has threads (`Options.physics_threads`) - each
    /// task touches only its character's own data, world and bridge, and its own scratch - and checked LOUDLY: a
    /// collision world that quietly stops working leaves a character quietly falling through the floor, which is
    /// exactly the failure this coupling was added for.
    fn physicsStep(self: *Fleet, actions: []const f32) void {
        self.driveEveryCharacter(actions);
        for (self.drive_failed[0..self.options.envs], 0..) |failed, env| {
            if (failed) {
                assertUnreachable(@src(), "the collision world failed mid-step: character {d}", .{env});
            }
        }
    }

    /// One DECISION for every environment: record, drive the physics (`Options.decide_every` physics steps, the targets
    /// held), measure, and start again where needed. `actions` is `envs * action_width` long, each in [-1, 1].
    /// Returns the mean reward.
    pub fn step(self: *Fleet, actions: []const f32) f32 {
        const size: usize = self.action_width;
        // This decision's number: the counter of its pushes' draws (`rbt.drawWord`).
        self.decision_number +%= 1;
        const decision: u32 = self.decision_number;
        // The pushes as this decision draws them: the top where the training clock and the brake have brought it.
        const push_rule: rbt.PushRule = self.pushRule();
        assertf(actions.len == self.options.envs * size, @src(), "actions are {d} long, want {d}", .{
            actions.len,
            self.options.envs * size,
        });
        var reward_total: f32 = 0.0;
        // Each character's effort counted afresh for this decision.
        @memset(self.effort_sums, .{});
        // Every character's state recorded, in order.
        for (0..self.options.envs) |env| {
            const d: *rbt.Data = &self.data[env];
            const action: []const f32 = actions[env * size ..][0..size];
            const at: u32 = self.frame[env];

            // Record the state the action was taken FROM, so a window reads as
            // (state, action) -> the next record's state.
            // And how far into its episode this step is, which is what says what was being applied before it.
            self.replay.appendStep(
                env,
                d.joint_positions,
                d.joint_velocities,
                action,
                at,
                @intCast(self.clip_of[env]),
                self.segment[env],
                self.steps[env],
                self.aftermath_steps_left[env] > 0,
            );
        }
        // THE CLOCK (`Options.decide_every`): the decision's targets held for each of its physics steps, every
        // character's reference advancing a frame after each but the last, so the servo follows the moving reference
        // within the decision; the last physics step is the one measured below, its frame counted with the decision's.
        // With a clock of 1 the loop never runs.
        const physics_steps: u32 = self.options.decide_every;
        var physics_step: u32 = 1;
        while (physics_step < physics_steps) : (physics_step += 1) {
            self.physicsStep(actions);
            for (0..self.options.envs) |env| {
                self.advanceReferenceFrame(env);
            }
        }
        self.physicsStep(actions);
        for (0..self.options.envs) |env| {
            const clip: *const dance.Clip = self.clips[self.clip_of[env]];
            const d: *rbt.Data = &self.data[env];
            self.advanceReferenceFrame(env);
            self.steps[env] += 1;
            self.steps_total += 1;
            stateOf(self.m, d, &self.sim_state);
            self.referenceStateAt(clip, self.frame[env]);
            // The quality before the feet are exempted from contact: their lowest points are what it reads.
            self.quality[env] = .{};
            if (self.options.measures_quality) {
                const quality_rule: QualityRule = .{};
                var quality: QualityStep =
                    measureQuality(self.sim_state, self.reference_state, self.root, self.contact_exempt, quality_rule);
                quality.joint_error = jointError(self.m, d.joint_positions, self.reference_data.joint_positions);
                self.quality[env] = quality;
            }
            exemptFromContact(&self.sim_state, self.contact_exempt);
            const sim: State = self.sim_state;
            const err: TrackingError = trackingErrorWithHead(sim, self.reference_state, self.root, self.head);
            const earned: f32 = reward(err, self.options.task.weights);
            self.rewards[env] = earned;
            self.super_mimic_rewards[env] = self.superMimicReward(env, actions, sim);
            self.dones[env] = false;
            reward_total += earned;

            // The episode judged by robot.zig's one rule (`rbt.judgeEpisode`), the device's too: grace, failure,
            // aftermath, return, end - the fleet's counters carried in and out of it.
            var counters: rbt.EpisodeCounters = .{
                .steps = self.steps[env],
                .aftermath_steps_left = self.aftermath_steps_left[env],
                .return_streak = self.return_streaks[env],
                .steps_since_loss = self.steps_since_loss[env],
            };
            const rules: rbt.EpisodeRules = .{
                .grace_steps = self.options.task.termination.grace_steps,
                .aftermath_steps = self.options.aftermath_steps,
                .return_steps = self.options.return_steps,
                .max_steps = self.options.max_steps,
                .keeps_aftermath = self.keepsAftermath(env),
            };
            // Over when another decision would run past the clip's last frame.
            const clip_over: bool = self.frame[env] + physics_steps >= clip.frame_count;
            const limits: Termination = self.options.task.termination;
            const verdict: rbt.EpisodeVerdict = rbt.judgeEpisode(&counters, rules, err, limits, clip_over);
            self.aftermath_steps_left[env] = counters.aftermath_steps_left;
            self.return_streaks[env] = counters.return_streak;
            self.steps_since_loss[env] = counters.steps_since_loss;
            self.in_aftermath[env] = verdict.in_aftermath;
            self.returned[env] = verdict.returned;
            if (verdict.returned) {
                self.returns += 1;
                self.return_steps_sum += verdict.return_length;
            }
            // A watched push, after the judgement (`rbt.settleWatchedPush`): one that ends counted is the brake's.
            const watched_end: rbt.WatchedPushEnd = rbt.settleWatchedPush(&self.watched_push_left[env], verdict);
            if (watched_end.isCounted()) {
                self.noteWatchedPush(watched_end.cameBack());
            }
            const lost: bool = verdict.lost;
            // An episode ends only where ended episodes restart (`Options.restarts_episodes`): a viewer's character
            // lives on, its losses still counted.
            const finished: bool = verdict.finished and self.options.restarts_episodes;
            const was_in_aftermath: bool = verdict.in_aftermath;
            const aftermath_begins: bool = verdict.aftermath_begins;
            const ends_at_loss: bool = verdict.ends_at_loss;
            const capped: bool = verdict.capped;
            // The failure is the step the reference was lost, whether the episode ends there or lives on.
            self.failures[env] = lost;
            // The curriculum's episode return: this decision's SuperMimic reward, discounted from the episode's start.
            if (self.bins_start.len > 0) {
                const curriculum: ResetCurriculum = self.options.curriculum;
                const reward_now: f32 = self.super_mimic_rewards[env];
                self.episode_discounted_returns[env] += self.episode_discount_powers[env] * reward_now;
                self.episode_discount_powers[env] *= curriculum.discount;
                self.episode_reward_sums[env] += reward_now;
                self.episode_decisions[env] += 1;
            }
            if (lost) {
                self.failed += 1;
            }
            if (finished) {
                self.episodes += 1;
                self.dones[env] = true;
                // Why it ended, and where - before `restart` replaces the state just measured. An episode that ends
                // during its aftermath - by its end, the cap or the clip - ended because its reference was lost.
                const ended_in_aftermath: bool = was_in_aftermath or aftermath_begins;
                self.ends[env] = if (ends_at_loss)
                    .lost
                else if (ended_in_aftermath)
                    .aftermath
                else if (capped)
                    .cap
                else
                    .clip_end;
                self.terminal[env].copyFrom(self.sim_state);
                self.terminal_frame[env] = self.frame[env];
                self.terminal_clip[env] = self.clip_of[env];
                // The finished episode into its start bin: a failure, unless it was cut short at the cap.
                if (self.bins_start.len > 0) {
                    const ended_by_failure: bool = rbt.episodeEndedByFailure(capped, ends_at_loss, was_in_aftermath);
                    self.foldEpisodeIntoStartBin(env, ended_by_failure);
                }
                self.ended_this_decision[env] = true;
                continue;
            }
            // A push from outside (`Pushes`): on the schedule, or at a random moment - robot.zig's one rule
            // (`rbt.drawPush`), the device's too.
            //
            // The random moments are a POISSON PROCESS of `rate_per_second`, made one step at a time: each step pushes
            // with probability rate x dt, independently of every other step. Over a second that is about `rate`
            // pushes, with the gaps between them exponentially distributed - no rhythm a policy could learn to expect.
            // (A Bernoulli draw per step is the Poisson process exactly in the limit of small rate x dt; at 60 Hz and a
            // push every few seconds, rate x dt is below 0.01, and two pushes in one step never matter.)
            const push_world: u32 = @intCast(env);
            const still_in_aftermath: bool = self.aftermath_steps_left[env] > 0;
            const drawn: rbt.DrawnPush = rbt.drawPush(
                push_rule,
                self.draw_seed,
                push_world,
                decision,
                self.steps[env],
                self.watched_push_left[env],
                still_in_aftermath,
            );
            if (drawn.is_pushed) {
                self.push(env, drawn.speed, drawn.direction_rad);
                self.pushes_given += 1;
                self.push_speed_sum += drawn.speed;
                self.watched_push_left[env] = drawn.watch_decisions;
            }
        }
        // EVERY ENDED EPISODE RESTARTS TOGETHER, once all are folded into their start bins (`restartEnded`).
        self.restartEnded();
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
    for (0..m.joint_count) |j| {
        size += switch (m.joint_type[j]) {
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
    for (0..m.joint_count) |j| {
        const q: usize = m.joint_first_coordinate[j];
        switch (m.joint_type[j]) {
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
    return localSize(m.body_count) + targetSize(m);
}

pub fn encodeWorldInput(
    m: *const rbt.Model,
    state: State,
    root: usize,
    targets: []const f32,
    out: []f32,
) void {
    const split: usize = localSize(m.body_count);
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
    return (m.body_count - 1) * 6;
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
    random: Random,
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

    var predicted: State = try .init(gpa, m.body_count);
    defer predicted.deinit(gpa);
    var actual: State = try .init(gpa, m.body_count);
    defer actual.deinit(gpa);
    const input: []f32 = try gpa.alloc(f32, worldInputSize(m));
    defer gpa.free(input);
    const output: []f32 = try gpa.alloc(f32, worldOutputSize(m));
    defer gpa.free(output);
    const linear: []Vec = try gpa.alloc(Vec, m.body_count);
    defer gpa.free(linear);
    const angular: []Vec = try gpa.alloc(Vec, m.body_count);
    defer gpa.free(angular);
    const targets: []f32 = try gpa.alloc(f32, m.coordinate_count);
    defer gpa.free(targets);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    var scratch_data: rbt.Data = try .init(gpa, m);
    defer scratch_data.deinit();

    var held: State = try .init(gpa, m.body_count);
    defer held.deinit(gpa);
    const held_linear: []Vec = try gpa.alloc(Vec, m.body_count);
    defer gpa.free(held_linear);
    const held_angular: []Vec = try gpa.alloc(Vec, m.body_count);
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
            for (1..m.body_count) |b| {
                position[k] += length3(predicted.positions[b] - actual.positions[b]) / float(m.body_count - 1);
                rotation[k] += angleBetween(predicted.rotations[b], actual.rotations[b]) / float(m.body_count - 1);
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
    fn scatter(rig: *Rig, random: Random, reach: f32) void {
        const m: *rbt.Model = rig.model();
        const d: *rbt.Data = &rig.data;
        d.reset(m);
        var shift: [128]f32 = undefined;
        for (shift[0..m.dof_count], 0..) |*s, k| {
            s.* = reach * (2.0 * random.float(f32) - 1.0);
            d.joint_velocities[k] = reach * (2.0 * random.float(f32) - 1.0);
        }
        rbt.integratePos(m, d.joint_positions, shift[0..m.dof_count], 1.0);
        rbt.normalizeQuats(m, d.joint_positions);
        d.joint_positions[2] += 1.5; // up in the air, so nothing touches the floor
        d.stage = .stale;
        rbt.forward(m, d);
    }
};

// ==== THE JUDGE ====
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
    /// Steps watched, over every start's episode: the sum, over the starts, of each first episode's length.
    watched_steps: usize,
    reward_sum: f64,
    frame_time: f32,
    /// SuperMimic's reward summed over every start's first episode (`Fleet.super_mimic_rewards`), and the steps the
    /// starts had available - each from its frame to the clip's end - which with a step's maximum make its normaliser
    /// (`superMimicNormalisedReturn`).
    super_mimic_return_sum: f64 = 0.0,
    super_mimic_available_steps: usize = 0,
    /// What the standard errors need beyond the sums above, a start's first episode lasting t steps and its failing
    /// counted f (1 when the rule ended it, else 0): the sum of every t squared, and the sum of t over the starts that
    /// failed (`meanTimeToFailureError`).
    tracked_steps_squares: f64 = 0.0,
    failed_starts_steps: f64 = 0.0,
    /// Per start, the share of the clip from its frame to the clip's end that it tracked before losing the reference
    /// (1 when it reached the end): their sum, and the sum of their squares (`meanTrackedShare`).
    tracked_share_sum: f64 = 0.0,
    tracked_share_squares: f64 = 0.0,
    /// The tracking quality over every start's first episode (`QualitySums`, BlinkMimic's measures).
    quality: QualitySums = .{},

    /// Mean time to failure (seconds): the time watched per failure - the number that says how long a character
    /// keeps the reference. With no failure at all it is the whole time watched: a lower bound.
    pub fn meanTimeToFailure(self: Judgement) f32 {
        const seconds: f32 = float(self.watched_steps) * self.frame_time;
        return seconds / float(@max(self.failures, 1));
    }

    /// The STANDARD ERROR of the mean time to failure (seconds): how far the number would move between two
    /// judgements of the same controller on other starts, so that a difference between two runs can be told from
    /// noise. The mean time to failure is a RATIO of two sums over the starts - steps watched over failures, R =
    /// sum(t) / sum(f) - and its error is the delta method's for a ratio: with n starts and the mean failure f-bar,
    ///
    ///     se(R) = sqrt( sum((t - R f)^2) / (n - 1) ) / (sqrt(n) f-bar)
    ///
    /// the spread of what each start adds beyond the ratio, scaled to the mean. The sum expands to sum(t^2) -
    /// 2 R sum(t f) + R^2 sum(f) (f^2 is f), which the judgement keeps. Null with fewer than two starts or no failure:
    /// the mean time to failure is then only a lower bound.
    pub fn meanTimeToFailureError(self: Judgement) ?f32 {
        const start_count: f64 = float64(self.starts);
        const failure_count: f64 = float64(self.failures);
        if (self.starts < 2 or self.failures == 0) {
            return null;
        }
        const steps_sum: f64 = float64(self.watched_steps);
        const ratio: f64 = steps_sum / failure_count;
        const squared_residual_sum: f64 = self.tracked_steps_squares - 2.0 * ratio * self.failed_starts_steps +
            ratio * ratio * failure_count;
        const residual_variance: f64 = @max(squared_residual_sum, 0.0) / (start_count - 1.0);
        const mean_failure: f64 = failure_count / start_count;
        const error_in_steps: f64 = @sqrt(residual_variance) / (@sqrt(start_count) * mean_failure);
        return @floatCast(error_in_steps * self.frame_time);
    }

    /// The mean share of the clip a start tracked, from its frame to the clip's end, before it lost the reference:
    /// 1 for a controller that never loses it. Unlike the mean time to failure, it weighs every start alike.
    pub fn meanTrackedShare(self: Judgement) f32 {
        return @floatCast(self.tracked_share_sum / float64(@max(self.starts, 1)));
    }

    /// The standard error of the mean tracked share: the shares' sample deviation over the square root of the number
    /// of starts. Null with fewer than two starts.
    pub fn meanTrackedShareError(self: Judgement) ?f32 {
        if (self.starts < 2) {
            return null;
        }
        const start_count: f64 = float64(self.starts);
        const mean_share: f64 = self.tracked_share_sum / start_count;
        const squared_deviation_sum: f64 = self.tracked_share_squares - start_count * mean_share * mean_share;
        const sample_variance: f64 = @max(squared_deviation_sum, 0.0) / (start_count - 1.0);
        return @floatCast(@sqrt(sample_variance / start_count));
    }

    /// SUPERMIMIC'S NORMALISED RETURN, its evaluation's measure: the SuperMimic reward earned over every start's first
    /// episode, divided by the most those starts could have earned - a step's maximum (`maxStepTracking`) for every
    /// step from each start's frame to the clip's end. 1 for a character that coincides with its reference all the
    /// way; a start that loses the reference stops earning, so its unearned steps count against it.
    pub fn superMimicNormalisedReturn(self: Judgement, scales: SuperMimicScales) f32 {
        const step_maximum: f64 = scales.maxStepTracking();
        const most_earnable: f64 = step_maximum * float64(@max(self.super_mimic_available_steps, 1));
        return @floatCast(self.super_mimic_return_sum / most_earnable);
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
    judged.pushes = .{};
    judged.max_steps = @intCast(clip.frame_count);
    judged.task.termination.grace_steps = 0;
    judged.measures_quality = true;
    return judged;
}

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
    /// Per start: the steps its first episode has lasted so far, and the steps from its frame to the clip's end.
    first_episode_steps: []usize,
    available_steps: []usize,
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
        // An action of the fleet's own width per start: the joints' offsets, and the limbs' stiffnesses where the
        // judged fleet's action carries them (`Fleet.Options.limb_stiffness`).
        const actions: []f32 = try gpa.alloc(f32, starts.len * fleet.action_width);
        errdefer gpa.free(actions);
        @memset(actions, 0.0);
        const finished: []bool = try gpa.alloc(bool, starts.len);
        errdefer gpa.free(finished);
        @memset(finished, false);
        const first_episode_steps: []usize = try gpa.alloc(usize, starts.len);
        errdefer gpa.free(first_episode_steps);
        @memset(first_episode_steps, 0);
        // An episode reaches the clip's end at its last frame: from frame f, the frames after it.
        const available_steps: []usize = try gpa.alloc(usize, starts.len);
        // In decisions: the frames after the start, a decision's frames at a time.
        const decision_frames: usize = options.decide_every;
        var available_steps_sum: usize = 0;
        for (available_steps, starts) |*available, frame| {
            available.* = (clip.frame_count - 1 - frame) / decision_frames;
            available_steps_sum += available.*;
        }
        return .{
            .gpa = gpa,
            .fleet = fleet,
            .actions = actions,
            .finished = finished,
            .first_episode_steps = first_episode_steps,
            .available_steps = available_steps,
            .remaining = starts.len,
            .result = .{
                .starts = starts.len,
                .failures = 0,
                .reached_end = 0,
                .watched_steps = 0,
                .reward_sum = 0.0,
                .frame_time = secondsPerDecision(clip.frame_time, options.decide_every),
                .super_mimic_available_steps = available_steps_sum,
            },
        };
    }

    pub fn deinit(self: *Judging) void {
        self.gpa.free(self.available_steps);
        self.gpa.free(self.first_episode_steps);
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
                self.first_episode_steps[env] += 1;
                self.result.reward_sum += self.fleet.rewards[env];
                self.result.super_mimic_return_sum += self.fleet.super_mimic_rewards[env];
                self.result.quality.add(self.fleet.quality[env]);
                if (!self.fleet.dones[env]) {
                    continue;
                }
                done.* = true;
                self.remaining -= 1;
                self.recordStart(env);
                switch (self.fleet.ends[env]) {
                    // Lost at once, or lost and lived on: either way the start's first episode lost the reference.
                    .lost, .aftermath => self.result.failures += 1,
                    .clip_end => self.result.reached_end += 1,
                    .cap => {},
                }
            }
        }
        return self.remaining == 0;
    }

    /// A start's first episode, ended: its length, squared, into the sums the standard errors need, the share of the
    /// clip it tracked, and - when the rule ended it - its length among the failed starts' (`Judgement`).
    fn recordStart(self: *Judging, env: usize) void {
        const episode_steps: f64 = float64(self.first_episode_steps[env]);
        const available: f64 = float64(@max(self.available_steps[env], 1));
        const tracked_share: f64 = episode_steps / available;
        self.result.tracked_steps_squares += episode_steps * episode_steps;
        self.result.tracked_share_sum += tracked_share;
        self.result.tracked_share_squares += tracked_share * tracked_share;
        if (self.fleet.ends[env] == .lost) {
            self.result.failed_starts_steps += episode_steps;
        }
    }
};

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

/// A recovery probe's durations in its fleet's steps (`RecoveryProbe.stepsAt`).
pub const ProbeSteps = struct {
    settle: u32,
    watch: u32,
    average: u32,
    return_limit: u32,
    return_hold: u32,
};

/// How the recovery probe pushes and watches (`probeRecovery`).
pub const RecoveryProbe = struct {
    /// The push speeds probed, one band each, in m/s: a nudge, a push that needs a step, harder ones.
    speeds: []const f32 = &.{ 0.5, 1.0, 1.5, 2.0 },
    /// How long the character tracks before the push - the reward's level over it is what recovery is measured
    /// against - and how long it is watched after it, in seconds. Every duration of the probe is in seconds and counted
    /// in its fleet's steps, decisions, by `stepsAt`.
    settle_seconds: f32 = 1.0,
    watch_seconds: f32 = 3.0,
    /// Tracking RECOVERED: the reward's running mean over `average_seconds` back to this share of its level before the
    /// push.
    recovered_share: f32 = 0.9,
    average_seconds: f32 = 0.25,
    /// The push directions' seed: the same seed pushes every learner the same way.
    seed: u64 = 1,
    /// Pushes only where the reference STANDS: at a start's push, the reference's head at least this share of its
    /// highest anywhere in the clip (`probeRecovery`).
    standing_share: f32 = 0.8,
    /// RETURNS: how long a pushed character that lost the reference is followed for a return to it, in seconds - the
    /// probe's fleet then keeps an aftermath that long with returns after `return_hold_seconds` holding the reference
    /// again (`Fleet.Options.return_steps`), the watch extended to cover it. 0: no returns - a loss ends its start's
    /// probe, as it always has.
    return_seconds: f32 = 0,
    return_hold_seconds: f32 = 8.0 / 60.0,

    /// The probe's durations counted in steps of `step_seconds` - its fleet's decisions (`secondsPerDecision`) - each
    /// rounded to the nearest, the running mean at least one step long.
    pub fn stepsAt(probe: RecoveryProbe, step_seconds: f32) ProbeSteps {
        const average: u32 = stepsIn(probe.average_seconds, step_seconds);
        return .{
            .settle = stepsIn(probe.settle_seconds, step_seconds),
            .watch = stepsIn(probe.watch_seconds, step_seconds),
            .average = @max(average, 1),
            .return_limit = stepsIn(probe.return_seconds, step_seconds),
            .return_hold = stepsIn(probe.return_hold_seconds, step_seconds),
        };
    }
};

/// One band of the recovery probe: how its pushes ended.
pub const RecoveryBand = struct {
    speed: f32,
    /// Starts pushed - the ones still tracking when the push came.
    pushes: usize = 0,
    /// Pushes after which the task's failure rule did not fire within the watch.
    survived: usize = 0,
    /// Of those, the pushes after which tracking came back within the watch, and the steps each took, summed.
    recovered: usize = 0,
    /// How long one of the probe's steps lasts - a decision of its fleet's - which its step sums become seconds by.
    step_seconds: f32 = 0,
    recovery_steps_sum: usize = 0,
    /// Pushes after which the reference was lost within the watch - `pushes - survived` - and, with returns probed
    /// (`RecoveryProbe.return_seconds`), how each loss ended: RETURNED within the limit (with the steps each took from
    /// its loss, summed), NOT RETURNED when the limit ran out first; the rest are unresolved - the clip ended before
    /// either, which says nothing about returning.
    lost: usize = 0,
    returned: usize = 0,
    return_steps_sum: usize = 0,
    not_returned: usize = 0,
    /// HOW THE RETURNS MOVED - fluid, or snapping back - over the decisions from each loss to its return, for the
    /// losses that returned: how many decisions were measured, the action's rate of change summed over them
    /// (`actionChangeRate`), and the root's jerk summed (`rootJerk`). A decision is measured once two decisions have
    /// passed since the push, so that the push itself - a jump of velocity from outside - is in no jerk.
    return_fluid_steps: usize = 0,
    return_action_rate_sum: f32 = 0,
    return_jerk_sum: f32 = 0,

    /// The share of pushes survived.
    pub fn survivalRate(band: RecoveryBand) f32 {
        return float(band.survived) / float(@max(band.pushes, 1));
    }

    /// The share of pushes after which tracking came back.
    pub fn recoveryRate(band: RecoveryBand) f32 {
        return float(band.recovered) / float(@max(band.pushes, 1));
    }

    /// The mean time tracking took to come back, in seconds, over the pushes it came back from.
    pub fn meanRecoverySeconds(band: RecoveryBand) f32 {
        const mean_steps: f32 = float(band.recovery_steps_sum) / float(@max(band.recovered, 1));
        return mean_steps * band.step_seconds;
    }

    /// The share of resolved losses - returned or not - followed by a return.
    pub fn returnRate(band: RecoveryBand) f32 {
        const resolved: usize = band.returned + band.not_returned;
        return float(band.returned) / float(@max(resolved, 1));
    }

    /// The mean time from a loss to its return, in seconds, over the returns.
    pub fn meanReturnSeconds(band: RecoveryBand) f32 {
        const mean_steps: f32 = float(band.return_steps_sum) / float(@max(band.returned, 1));
        return mean_steps * band.step_seconds;
    }

    /// The action's mean rate of change during the returns, in action units per second.
    pub fn meanReturnActionRate(band: RecoveryBand) f32 {
        return band.return_action_rate_sum / float(@max(band.return_fluid_steps, 1));
    }

    /// The root's mean jerk during the returns, in m/s^3.
    pub fn meanReturnJerk(band: RecoveryBand) f32 {
        return band.return_jerk_sum / float(@max(band.return_fluid_steps, 1));
    }
};

/// THE ACTION's RATE OF CHANGE from one decision to the next, in action units per second: the root mean square of
/// the change over the action's numbers, over the decision's seconds. A policy that holds its action scores 0; one
/// that flips every number by 0.2 each decision at 30 decisions a second scores 6.
pub fn actionChangeRate(
    previous_action: []const f32,
    action: []const f32,
    decision_seconds: f32,
) f32 {
    assertf(previous_action.len == action.len and action.len > 0, @src(), "actions of {d} and {d} numbers", .{
        previous_action.len,
        action.len,
    });
    var square_sum: f32 = 0;
    for (previous_action, action) |before, now| {
        const change: f32 = now - before;
        square_sum += change * change;
    }
    const root_mean_square: f32 = @sqrt(square_sum / float(action.len));
    return root_mean_square / decision_seconds;
}

/// THE ROOT's JERK, in m/s^3: the length of the second difference of three successive decisions' root velocities,
/// over the decision's seconds squared - the rate at which the root's acceleration changes. Steady motion and steady
/// acceleration score 0; a body yanked about scores high.
///
///     jerk  =  | v_now - 2 v_last + v_before_last |  /  dt^2
pub fn rootJerk(
    velocity_before_last: Vec,
    velocity_last: Vec,
    velocity_now: Vec,
    decision_seconds: f32,
) f32 {
    const second_difference: Vec = velocity_now - velocity_last - velocity_last + velocity_before_last;
    return length3(second_difference) / (decision_seconds * decision_seconds);
}

/// HOW ONE START's RETURN MOVES (`RecoveryBand`'s fluid numbers): its root's velocity at the last two decisions, and
/// the sums over the decisions measured so far.
pub const ReturnMotion = struct {
    velocity_before_last: Vec = @splat(0),
    velocity_last: Vec = @splat(0),
    measured_steps: usize = 0,
    action_rate_sum: f32 = 0,
    jerk_sum: f32 = 0,

    /// Whether a decision is measured: while the reference is lost, and once two decisions since the push stand
    /// behind it - the push, a jump of velocity from outside, then lies in no jerk. `decisions_since_push` is 1 at
    /// the decision the push begins.
    pub fn isMeasured(is_lost: bool, decisions_since_push: usize) bool {
        return is_lost and decisions_since_push >= 3;
    }

    /// One decision: its root `velocity` kept for the next two jerks - and, when `is_measured`, the decision measured:
    /// the action's rate from `action_before` to `action`, and the root's jerk over the three velocities.
    pub fn note(
        motion: *ReturnMotion,
        velocity: Vec,
        action_before: []const f32,
        action: []const f32,
        decision_seconds: f32,
        is_measured: bool,
    ) void {
        if (is_measured) {
            motion.measured_steps += 1;
            motion.action_rate_sum += actionChangeRate(action_before, action, decision_seconds);
            const jerk: f32 = rootJerk(motion.velocity_before_last, motion.velocity_last, velocity, decision_seconds);
            motion.jerk_sum += jerk;
        }
        motion.velocity_before_last = motion.velocity_last;
        motion.velocity_last = velocity;
    }
};

/// One band of `probeRecovery`: every start tracked, pushed once at the band's speed, watched, and counted.
///
/// THE PROTOCOL, per start, in physics steps:
///
///     0 ............ settle_steps ............ settle_steps + watch_steps
///     tracking, its reward summed     | push |  watching: lost? its reward's running mean back to the level?
///
/// A start lost DURING the settle was never pushed, so it says nothing about recovery and leaves the count. A start
/// lost during the watch did not survive. A start whose running mean came back to `recovered_share` of its level
/// before the push RECOVERED - unless it was lost later in the watch, which makes it neither: coming back for a moment
/// is not recovering.
///
/// THE RUNNING MEAN. The last `average_steps` rewards of each start sit in a small ring of its own, written at the
/// watch step's index modulo the ring's length; once the watch is that many steps old the ring is full, and its mean
/// is the reward averaged over the last `average_steps` steps. Averaging matters: one good step in the middle of a
/// stumble is not tracking come back.
fn probeBand(
    gpa: Allocator,
    m: *rbt.Model,
    clip: *const dance.Clip,
    options: Fleet.Options,
    starts: []const usize,
    actor: ?Actor,
    probe: RecoveryProbe,
    band_index: usize,
    band: *RecoveryBand,
) !void {
    const start_count: usize = starts.len;
    // With returns probed, an aftermath of the return limit, every character keeping it, returns after the hold.
    var probe_options: Fleet.Options = judgeOptions(options, start_count, clip);
    // The probe's durations in its fleet's steps, decisions at the fleet's clock; the band's seconds count in them.
    const decision_seconds: f32 = secondsPerDecision(clip.frame_time, probe_options.decide_every);
    const probe_steps: ProbeSteps = probe.stepsAt(decision_seconds);
    band.step_seconds = decision_seconds;
    const return_limit_steps: u32 = probe_steps.return_limit;
    if (return_limit_steps > 0) {
        probe_options.aftermath_steps = return_limit_steps;
        probe_options.aftermath_share = 1;
        probe_options.return_steps = probe_steps.return_hold;
    }
    const probe_fleet: *Fleet = try Fleet.init(gpa, m, &.{clip}, probe_options);
    defer probe_fleet.deinit();
    for (starts, 0..) |start_frame, env| {
        probe_fleet.startAt(env, 0, start_frame);
    }
    // With no actor every action stays zero: the servo alone, tracking the reference by PD. Each action is of the
    // probed fleet's own width - the limbs' stiffnesses after the offsets where its action carries them.
    const actions: []f32 = try gpa.alloc(f32, start_count * probe_fleet.action_width);
    defer gpa.free(actions);
    @memset(actions, 0.0);
    // Per start: whether it still counts, its reward summed over the settle, the ring of its latest rewards, and
    // whether - and after how many watch steps - its tracking came back.
    const still_counted: []bool = try gpa.alloc(bool, start_count);
    defer gpa.free(still_counted);
    @memset(still_counted, true);
    const settle_reward_sums: []f32 = try gpa.alloc(f32, start_count);
    defer gpa.free(settle_reward_sums);
    @memset(settle_reward_sums, 0);
    const ring_length: usize = probe_steps.average;
    const recent_reward_rings: []f32 = try gpa.alloc(f32, start_count * ring_length);
    defer gpa.free(recent_reward_rings);
    @memset(recent_reward_rings, 0);
    const tracking_came_back: []bool = try gpa.alloc(bool, start_count);
    defer gpa.free(tracking_came_back);
    @memset(tracking_came_back, false);
    const steps_until_back: []usize = try gpa.alloc(usize, start_count);
    defer gpa.free(steps_until_back);
    @memset(steps_until_back, 0);
    // Whether each start lost the reference within the watch - and, with returns probed, it is followed until it
    // returns or its aftermath runs out.
    const was_lost: []bool = try gpa.alloc(bool, start_count);
    defer gpa.free(was_lost);
    @memset(was_lost, false);
    // THE RETURN's FLUIDITY, measured while a start is lost and kept until it returns (`RecoveryBand`): the actions
    // given the decision before, each start's root velocity at the last two decisions, and its sums so far.
    const previous_actions: []f32 = try gpa.alloc(f32, actions.len);
    defer gpa.free(previous_actions);
    const motions: []ReturnMotion = try gpa.alloc(ReturnMotion, start_count);
    defer gpa.free(motions);
    @memset(motions, .{});
    const action_width: usize = probe_fleet.action_width;
    // The push directions: one generator per band, from the probe's seed, so every controller probed with the same
    // seed is pushed in the same directions.
    var direction_generator: Random.DefaultPrng = .init(probe.seed +% band_index);
    const direction_random: Random = direction_generator.random();
    // The watch, and after it - with returns probed - long enough for a loss at its last step to run its course.
    const total_probe_steps: usize = probe_steps.settle + probe_steps.watch + return_limit_steps;
    for (0..total_probe_steps) |probe_step| {
        // The push, at the end of the settle, for every start still tracking.
        if (probe_step == probe_steps.settle) {
            for (still_counted, 0..) |is_counted, env| {
                if (!is_counted) {
                    continue;
                }
                const push_direction_rad: f32 = 2.0 * pi * direction_random.float(f32);
                probe_fleet.push(env, band.speed, push_direction_rad);
                band.pushes += 1;
            }
        }
        @memcpy(previous_actions, actions);
        if (actor) |controller| {
            controller.act(controller.context, probe_fleet, actions);
        }
        _ = probe_fleet.step(actions);
        const is_watching: bool = probe_step >= probe_steps.settle;
        for (still_counted, 0..) |*is_counted, env| {
            if (!is_counted.*) {
                continue;
            }
            const step_reward: f32 = probe_fleet.rewards[env];
            const lost_the_reference: bool = probe_fleet.failures[env];
            // The attempt over: the loss itself without returns, the aftermath run out with them.
            const episode_ended: bool = probe_fleet.dones[env];
            if (!is_watching) {
                // Lost before the push: nothing to recover, so the start leaves the count.
                if (lost_the_reference or episode_ended) {
                    is_counted.* = false;
                }
                settle_reward_sums[env] += step_reward;
                continue;
            }
            const steps_since_push: usize = probe_step - probe_steps.settle + 1;
            const is_within_watch: bool = steps_since_push <= probe_steps.watch;
            if (lost_the_reference and is_within_watch and !was_lost[env]) {
                was_lost[env] = true;
                band.lost += 1;
            }
            // How it moves: measured while lost, once two decisions since the push stand behind this one.
            const root_velocity: []const f32 = probe_fleet.data[env].joint_velocities[0..3];
            const velocity: Vec = vec(root_velocity[0], root_velocity[1], root_velocity[2]);
            const action_now: []const f32 = actions[env * action_width ..][0..action_width];
            const action_before: []const f32 = previous_actions[env * action_width ..][0..action_width];
            const is_measured: bool = ReturnMotion.isMeasured(was_lost[env], steps_since_push);
            motions[env].note(velocity, action_before, action_now, decision_seconds, is_measured);
            // Back with the reference after its loss: the return, its time and how it moved, and the start is done.
            if (probe_fleet.returned[env] and was_lost[env]) {
                band.returned += 1;
                band.return_steps_sum += probe_fleet.steps_since_loss[env];
                band.return_fluid_steps += motions[env].measured_steps;
                band.return_action_rate_sum += motions[env].action_rate_sum;
                band.return_jerk_sum += motions[env].jerk_sum;
                is_counted.* = false;
                continue;
            }
            if (episode_ended or was_lost[env]) {
                if (episode_ended) {
                    is_counted.* = false;
                    // A loss whose aftermath ran out: not returned. Its clip ending first leaves it unresolved.
                    const limit_ran_out: bool = probe_fleet.ends[env] == .aftermath;
                    if (was_lost[env] and limit_ran_out) {
                        band.not_returned += 1;
                    }
                }
                continue;
            }
            // Past the watch, a start never lost has nothing more to show.
            if (!is_within_watch) {
                continue;
            }
            const reward_ring: []f32 = recent_reward_rings[env * ring_length ..][0..ring_length];
            reward_ring[steps_since_push % ring_length] = step_reward;
            const ring_is_full: bool = steps_since_push >= ring_length;
            if (ring_is_full and !tracking_came_back[env]) {
                var recent_reward_sum: f32 = 0;
                for (reward_ring) |recent_reward| {
                    recent_reward_sum += recent_reward;
                }
                const running_mean_reward: f32 = recent_reward_sum / float(ring_length);
                const reward_level_before_push: f32 = settle_reward_sums[env] / float(probe_steps.settle);
                const recovered_level: f32 = probe.recovered_share * reward_level_before_push;
                if (running_mean_reward >= recovered_level) {
                    tracking_came_back[env] = true;
                    steps_until_back[env] = steps_since_push;
                }
            }
        }
    }
    // Survived: pushed, and not lost within the watch. Recovered: and came back; a start that came back and was lost
    // later in the watch is neither.
    for (still_counted, tracking_came_back, steps_until_back, was_lost) |is_counted, came_back, steps_taken, lost| {
        if (!is_counted or lost) {
            continue;
        }
        band.survived += 1;
        if (came_back) {
            band.recovered += 1;
            band.recovery_steps_sum += steps_taken;
        }
    }
}

/// The reference's head height at every frame of `clip` - the clip's pose put on the model (`resetToFrame`) and read
/// as tracking reads a state (`stateOf`) - or null when the task names no head (`Task.head_body`). Memory: `gpa`, the
/// caller's to free.
pub fn referenceHeadHeights(
    gpa: Allocator,
    m: *rbt.Model,
    clip: *const dance.Clip,
    options: Fleet.Options,
) !?[]f32 {
    const head: usize = try headBody(options.task.head_body, options.body_names) orelse return null;
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    var state: State = try .init(gpa, m.body_count);
    defer state.deinit(gpa);
    const heights: []f32 = try gpa.alloc(f32, clip.frame_count);
    errdefer gpa.free(heights);
    for (heights, 0..) |*height, frame| {
        resetToFrame(m, &data, clip, frame);
        stateOf(m, &data, &state);
        height.* = state.positions[head][2];
    }
    return heights;
}

/// THE RECOVERY PROBE: how well a controller comes back from being pushed, band by band of push speed. For each band,
/// every start of `starts` tracks for `settle_steps` - its reward's level over them recorded - is pushed once
/// (`Fleet.push`, the band's speed, a direction drawn from the probe's seed), then watched for `watch_steps`: SURVIVED
/// when the failure rule does not fire in the watch, RECOVERED when the reward's running mean also comes back to
/// `recovered_share` of its level before the push, with the time it took. A start that loses the reference before its
/// push is not counted - there was nothing to recover. Starts too near the clip's end for a whole settle and watch are
/// skipped. `options` is the task's fleet, judged as `judge` judges it (no pushes but the probe's, no grace); one
/// `RecoveryBand` per speed into `bands`.
pub fn probeRecovery(
    gpa: Allocator,
    m: *rbt.Model,
    clip: *const dance.Clip,
    options: Fleet.Options,
    starts: []const usize,
    actor: ?Actor,
    probe: RecoveryProbe,
    bands: []RecoveryBand,
) !void {
    assertf(bands.len == probe.speeds.len, @src(), "{d} bands for {d} speeds", .{ bands.len, probe.speeds.len });
    // The probe in its fleet's steps, decisions, and those in the reference's frames: a decision is `decide_every`.
    const decision_frames: usize = options.decide_every;
    const decision_seconds: f32 = secondsPerDecision(clip.frame_time, options.decide_every);
    const probe_steps: ProbeSteps = probe.stepsAt(decision_seconds);
    const total_probe_frames: usize = (probe_steps.settle + probe_steps.watch) * decision_frames;
    // The starts with room for a whole settle and watch, and a decision more, before the clip's end: a start whose
    // clip ran out during the watch would end its episode there, which the probe would misread as a loss.
    //
    // And pushes only where the reference STANDS. The probe asks whether a character comes back when pushed - a
    // question about balance. A push landing while the reference lies on the floor would count a body already down
    // as having "survived", though it had no balance to keep. So a start is kept only when, at its push, the
    // reference's head is at least `standing_share` of its highest anywhere in the clip - a share of the clip's own
    // height, so the same rule holds for any clip and any robot. With no head named by the task, every start with
    // room is kept.
    const head_heights: []f32 = try referenceHeadHeights(gpa, m, clip, options) orelse &.{};
    defer gpa.free(head_heights);
    var highest_head: f32 = 0;
    for (head_heights) |height| {
        highest_head = @max(highest_head, height);
    }
    var starts_with_room: ArrayList(usize) = .empty;
    defer starts_with_room.deinit(gpa);
    for (starts) |start_frame| {
        const last_frame_needed: usize = start_frame + total_probe_frames + decision_frames;
        if (last_frame_needed >= clip.frame_count) {
            continue;
        }
        const push_frame: usize = start_frame + probe_steps.settle * decision_frames;
        const is_standing: bool = head_heights.len == 0 or
            head_heights[push_frame] >= probe.standing_share * highest_head;
        if (is_standing) {
            try starts_with_room.append(gpa, start_frame);
        }
    }
    // Every band from the same starts, each with its own fleet and its own push directions.
    for (probe.speeds, bands, 0..) |push_speed, *band, band_index| {
        band.* = .{ .speed = push_speed };
        if (starts_with_room.items.len == 0) {
            continue;
        }
        try probeBand(gpa, m, clip, options, starts_with_room.items, actor, probe, band_index, band);
    }
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

fn readAll(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    var file: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

/// Any clip in `assets/lafan1/`, retargeted onto a floating flex2 and filtered at 5 Hz.
fn loadClip(gpa: Allocator, io: Io, path: []const u8, seconds: f32) !dance.Clip {
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
        clip.nq == m.coordinate_count and m.joint_count > 0 and m.joint_type[0] == .free,
        @src(),
        "lifting moves the root's height, so the clip must be this model's and the model must have a free root",
        .{},
    );
    const frames: usize = clip.frame_count;
    const needed: []f32 = try gpa.alloc(f32, frames);
    defer gpa.free(needed);
    for (0..frames) |f| {
        @memcpy(d.joint_positions, clip.pose(f));
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

test "robot_track: a planner's labels are kept once its stretch of plan ends well - dropped where it failed" {
    // FIVE WORLDS, twelve records each, into a ring of eight - so the labels of records 0 to 3 are forgotten by the
    // end. Each world's records, one character a record, and what each record's moment says of the decision before:
    //
    //     B   a plan's first decision            F   that decision failed: it lost the reference
    //     L   a plan's later decision            E   it ended the episode, capped: this record opens another
    //     .   the policy's                       P   it pushed the world: a new stretch of motion, the same episode
    //
    //              record   0 1 2 3 4 5 6 7 8 9 10 11
    //     world 0           B L L L B L L L B L L  L       follows every plan whole
    //     world 1           B . . . B . . . B . .  .       takes each plan's first action alone
    //     world 2           B L L L B L L L B L L  L       its decision 5 fails (F at record 6)
    //     world 3           B L L . B L L . B L L  L       its episode ends after 2 (E at 3); pushed after 6 (P at 7)
    //     world 4           B L L L B L L L B L L  L       its decision 1 fails (F at record 2), and the world lives on
    //                                                      in its aftermath: every record from 2 on is after the loss
    //
    // SETTLED, step by step:
    //     step 1   world 1's [0] kept                 step 7   world 3's [4 5 6] kept whole: the push ends it well
    //     step 3   world 3's [0 1] kept, 2 dropped:   step 8   world 0's [4 5 6 7] kept; world 2's [4 5 6 7]
    //              its goal is the next episode's              dropped with its failed plan; world 4's [4 5 6 7]
    //     step 4   worlds 0 and 2's [0 1 2 3] kept;            dropped, every decision of it after the loss
    //              world 4's [0 1 2 3] dropped        step 9   world 1's [8] kept
    //              with its failed plan
    //     step 5   world 1's [4] kept
    // and the stretches begun at 8 still open at the end. After record 11 the ring holds 4 to 11.
    const gpa: Allocator = testing_allocator;
    const world_count: usize = 5;
    const record_count: usize = 12;
    const ring_capacity: usize = 8;
    const actions = [world_count]*const [record_count]u8{
        "BLLLBLLLBLLL",
        "B...B...B...",
        "BLLLBLLLBLLL",
        "BLL.BLL.BLLL",
        "BLLLBLLLBLLL",
    };
    const events = [world_count]*const [record_count]u8{
        "............",
        "............",
        "......F.....",
        "...E...P....",
        "..F.........",
    };
    // The first record after a loss in each world that lives on after one, or none.
    const aftermath_from = [world_count]?usize{ null, null, null, null, 2 };
    var labels: LabelBooks = try .init(gpa, world_count, ring_capacity);
    defer labels.deinit(gpa);
    var episode_steps: [world_count]u32 = @splat(10);
    var moments: [world_count]rbt.RecordMoment = undefined;
    for (0..record_count) |record| {
        for (0..world_count) |world| {
            const event: u8 = events[world][record];
            const action: u8 = actions[world][record];
            const opens_episode: bool = event == 'E';
            if (opens_episode) {
                episode_steps[world] = 0;
            }
            const after_loss: bool = if (aftermath_from[world]) |first| record >= first else false;
            moments[world] = .{
                .starts_segment = opens_episode or event == 'P',
                .episode_step = episode_steps[world],
                .after_loss = after_loss,
                .labelled = action != '.',
                .begins_plan = action == 'B',
                .previous_decision_failed = event == 'F',
            };
            episode_steps[world] += 1;
        }
        labels.appendStep(&moments, record);
    }
    // KEPT, in the order settled, records 0 to 3 forgotten.
    const expected = [_]Label{
        .{ .env = 1, .index = 4 },
        .{ .env = 3, .index = 4 },
        .{ .env = 3, .index = 5 },
        .{ .env = 3, .index = 6 },
        .{ .env = 0, .index = 4 },
        .{ .env = 0, .index = 5 },
        .{ .env = 0, .index = 6 },
        .{ .env = 0, .index = 7 },
        .{ .env = 1, .index = 8 },
    };
    try expectEqualSlices(Label, &expected, labels.keptLabels());
    // The counts since the beginning: 8 + 3 + 4 + 5 kept, forgotten ones among them; world 2's four and world 4's
    // first four dropped with their failed plans, world 4's next four for their decisions after its loss; world 3's
    // record 2 dropped where its episode ended.
    try expectEqual(@as(u64, 20), labels.labels_kept);
    try expectEqual(@as(u64, 8), labels.labels_dropped_with_failed_plans);
    try expectEqual(@as(u64, 4), labels.labels_dropped_after_losses);
    try expectEqual(@as(u64, 1), labels.labels_dropped_at_episode_ends);
    // The stretches begun at record 8 still open - world 1 took its plan's first action alone, and that one is kept.
    const open_lengths = [world_count]u32{ 4, 0, 4, 4, 4 };
    try expectEqualSlices(u32, &open_lengths, labels.stretch_length);
    // DRAWN UNIFORMLY: every kept label drawn, each about as often as the others.
    var prng: Random.DefaultPrng = .init(5);
    const random: Random = prng.random();
    var draws_of: [expected.len]u32 = @splat(0);
    const draw_count: u32 = 9000;
    for (0..draw_count) |_| {
        const drawn: Label = labels.drawLabel(random) orelse return error.NothingKept;
        const at: usize = for (expected, 0..) |label, place| {
            if (label.env == drawn.env and label.index == drawn.index) {
                break place;
            }
        } else return error.DrawnLabelNotKept;
        draws_of[at] += 1;
    }
    const mean_draws: f32 = float(draw_count) / float(expected.len);
    for (draws_of) |draws| {
        try expect(@abs(float(draws) - mean_draws) < 0.2 * mean_draws);
    }
}

test "robot_track: a judgement's standard errors are the per-start formulas, worked from its sums" {
    // Four starts: their first episodes lasted 100, 50, 200 and 30 steps, the third reaching the clip's end and the
    // others losing the reference, with 200, 100, 200 and 300 steps of the clip before them. The judgement keeps only
    // sums; its errors must be the formulas worked from the starts themselves - the delta method's residuals t - R f
    // for the ratio, the shares' sample deviation for the mean share.
    const episode_steps = [4]f64{ 100, 50, 200, 30 };
    const failed = [4]f64{ 1, 1, 0, 1 };
    const available = [4]f64{ 200, 100, 200, 300 };
    var judgement: Judgement = .{
        .starts = 4,
        .failures = 3,
        .reached_end = 1,
        .watched_steps = 380,
        .reward_sum = 0,
        .frame_time = 1.0 / 60.0,
    };
    for (episode_steps, failed, available) |steps, failure, steps_available| {
        const share: f64 = steps / steps_available;
        judgement.tracked_steps_squares += steps * steps;
        judgement.failed_starts_steps += steps * failure;
        judgement.tracked_share_sum += share;
        judgement.tracked_share_squares += share * share;
    }
    // The delta method from the starts: R = 380 / 3 steps per failure, the residuals t - R f.
    const ratio: f64 = 380.0 / 3.0;
    var residual_squares: f64 = 0;
    for (episode_steps, failed) |steps, failure| {
        const residual: f64 = steps - ratio * failure;
        residual_squares += residual * residual;
    }
    const expected_steps_error: f64 = @sqrt(residual_squares / 3.0) / (@sqrt(4.0) * 0.75);
    const expected_error: f32 = @floatCast(expected_steps_error / 60.0);
    try expectApproxEqRel(expected_error, judgement.meanTimeToFailureError().?, 1.0e-5);
    // The mean share and its error from the shares 0.5, 0.5, 1 and 0.1.
    const shares = [4]f64{ 0.5, 0.5, 1.0, 0.1 };
    var share_deviation_squares: f64 = 0;
    for (shares) |share| {
        share_deviation_squares += (share - 0.525) * (share - 0.525);
    }
    const expected_share_error: f32 = @floatCast(@sqrt(share_deviation_squares / 3.0 / 4.0));
    try expectApproxEqRel(@as(f32, 0.525), judgement.meanTrackedShare(), 1.0e-6);
    try expectApproxEqRel(expected_share_error, judgement.meanTrackedShareError().?, 1.0e-5);
    // No failure: the mean time to failure is a lower bound, without an error; one start: no spread to measure.
    var never_failed: Judgement = judgement;
    never_failed.failures = 0;
    try expectEqual(@as(?f32, null), never_failed.meanTimeToFailureError());
    var one_start: Judgement = judgement;
    one_start.starts = 1;
    try expectEqual(@as(?f32, null), one_start.meanTrackedShareError());
}

test "robot_track: the judge - the same starts every time, identical twice, every start counted once" {
    // Plan F1's known answers, on the rig and the walk. Evenly spaced starts land where they should; two judgements
    // of the same controller are IDENTICAL (nothing in the judge is random); every start's first episode is counted
    // exactly once, ended by the rule or by the clip (the judge caps nothing before the clip's end); and the servo
    // alone (no actor) is exactly an actor that asks for no offsets.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
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
    var rng: Random.DefaultPrng = .init(4);
    const random: Random = rng.random();
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

test "robot_track: the root's cost weighs against the bodies as SuperMimic's root against its bodies" {
    // A world and three character bodies, the first the root: 51 features. The two bodies beside the root move their
    // positions' numbers by 0.2 and their axes' by 0.5; the root's never move - floored at 0.001, and left out, else
    // they alone would decide. Half the bodies' weight: 0.5 x (2 / 51) / 0.2^2 per m^2 and 0.5 x (2 / 51) / 0.5^2.
    const gpa: Allocator = testing_allocator;
    const bodies: usize = 4;
    const root: usize = 1;
    const spreads: []f32 = try gpa.alloc(f32, localSize(bodies));
    defer gpa.free(spreads);
    @memset(spreads, 1.0);
    for (1..bodies) |body| {
        const is_root: bool = body == root;
        @memset(spreads[localPositionColumn(bodies, body)..][0..3], if (is_root) 1.0e-3 else 0.2);
        @memset(spreads[localRotationColumn(bodies, body)..][0..6], if (is_root) 1.0e-3 else 0.5);
    }
    const weights: RootCostWeights = rootCostWeights(spreads, bodies, root, .{});
    try expectApproxEqRel(0.5 * (2.0 / 51.0) / (0.2 * 0.2), weights.position, 1.0e-5);
    try expectApproxEqRel(0.5 * (2.0 / 51.0) / (0.5 * 0.5), weights.rotation, 1.0e-5);
    // The shares scale the weights, and a share of 0 turns a term off.
    const position_only: RootCostWeights = rootCostWeights(spreads, bodies, root, .{ .position = 1.0, .rotation = 0 });
    try expectApproxEqRel(2.0 * weights.position, position_only.position, 1.0e-5);
    try expect(position_only.rotation == 0);
}

test "robot_track: local is blind to where you stand and which way you face - and to nothing else" {
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const root: usize = 1; // the first body below the world is the character's root
    var state: State = try .init(gpa, m.body_count);
    defer state.deinit(gpa);
    var moved: State = try .init(gpa, m.body_count);
    defer moved.deinit(gpa);
    const before: []f32 = try gpa.alloc(f32, localSize(m.body_count));
    defer gpa.free(before);
    const after: []f32 = try gpa.alloc(f32, localSize(m.body_count));
    defer gpa.free(after);
    var rng: Random.DefaultPrng = .init(11);
    const random: Random = rng.random();

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
        const saved_pos: [7]f32 = rig.data.joint_positions[0..7].*;
        const saved_vel: [6]f32 = rig.data.joint_velocities[0..6].*;
        const p: Vec = rotate(yaw, vec(saved_pos[0], saved_pos[1], saved_pos[2])) + move;
        const q: Quat = qmul(yaw, .{ saved_pos[3], saved_pos[4], saved_pos[5], saved_pos[6] });
        const v: Vec = rotate(yaw, vec(saved_vel[0], saved_vel[1], saved_vel[2]));
        rig.data.joint_positions[0..3].* = .{ p[0], p[1], p[2] };
        rig.data.joint_positions[3..7].* = .{ q[0], q[1], q[2], q[3] };
        rig.data.joint_velocities[0..3].* = .{ v[0], v[1], v[2] };
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &moved);
        local(moved, root, after);
        for (before, after) |a, b| {
            worst_invariant = @max(worst_invariant, @abs(a - b));
        }

        // ...and the controls. A representation blind to everything would be useless: lifting the
        // character must change its heights, and tipping it must change the up vector.
        rig.data.joint_positions[2] += 0.25;
        rig.data.stage = .stale;
        rbt.forward(m, &rig.data);
        stateOf(m, &rig.data, &moved);
        local(moved, root, after);
        var lifted: f32 = 0.0;
        for (before, after) |a, b| {
            lifted = @max(lifted, @abs(a - b));
        }
        rig.data.joint_positions[0..7].* = saved_pos;
        const pitch: Quat = quatFromNormAxisAngle(vec(1, 0, 0), 0.3);
        const tipped: Quat = qmul(pitch, .{ saved_pos[3], saved_pos[4], saved_pos[5], saved_pos[6] });
        rig.data.joint_positions[3..7].* = .{ tipped[0], tipped[1], tipped[2], tipped[3] };
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
    const gpa: Allocator = testing_allocator;
    var coarse: f32 = 0.0;
    var fine: f32 = 0.0;
    for ([_]f32{ 1.0 / 60.0, 1.0 / 120.0 }, 0..) |dt, pass| {
        var rig: Rig = undefined;
        try rig.init(gpa, dt);
        defer rig.deinit();
        const m: *rbt.Model = rig.model();
        var before: State = try .init(gpa, m.body_count);
        defer before.deinit(gpa);
        var after: State = try .init(gpa, m.body_count);
        defer after.deinit(gpa);
        var predicted: State = try .init(gpa, m.body_count);
        defer predicted.deinit(gpa);
        const linear: []Vec = try gpa.alloc(Vec, m.body_count);
        defer gpa.free(linear);
        const angular: []Vec = try gpa.alloc(Vec, m.body_count);
        defer gpa.free(angular);
        var rng: Random.DefaultPrng = .init(23);
        const random: Random = rng.random();
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
            for (1..m.body_count) |b| {
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
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    try expect(actionSize(m) == m.dof_count - 6);
    var rng: Random.DefaultPrng = .init(5);
    rig.scatter(rng.random(), 0.5);
    const reference: []f32 = try gpa.dupe(f32, rig.data.joint_positions);
    defer gpa.free(reference);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    const target: []f32 = try gpa.alloc(f32, m.coordinate_count);
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
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const reference_pose: []f32 = try gpa.alloc(f32, m.coordinate_count);
    defer gpa.free(reference_pose);
    const reference_xpos: []Vec = try gpa.alloc(Vec, m.body_count);
    defer gpa.free(reference_xpos);
    var moved: rbt.Data = try .init(gpa, m);
    defer moved.deinit();
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    var rng: Random.DefaultPrng = .init(9);
    const random: Random = rng.random();
    var worst: [2]f32 = .{ 0.0, 0.0 };
    for ([_]f32{ 0.2, 0.1 }, 0..) |scale, pass| {
        var inner: Random.DefaultPrng = .init(17);
        const inner_random: Random = inner.random();
        for (0..32) |_| {
            rig.scatter(random, 0.5);
            @memcpy(reference_pose, rig.data.joint_positions);
            @memcpy(reference_xpos, rig.data.body_positions);
            for (action) |*a| {
                a.* = 2.0 * inner_random.float(f32) - 1.0;
            }
            applyAction(m, reference_pose, action, scale, scratch, moved.joint_positions);
            clampHinges(m, moved.joint_positions);
            moved.stage = .stale;
            rbt.kinematics(m, &moved);
            for (1..m.body_count) |b| {
                worst[pass] = @max(worst[pass], length3(moved.body_positions[b] - reference_xpos[b]));
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

/// The walk clip, retargeted onto flex2 and filtered, as every tracking test wants it.
fn loadWalk(gpa: Allocator, io: Io) !dance.Clip {
    return loadClip(gpa, io, "assets/lafan1/walk1_subject2.bvh", 10.0);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    var clip: dance.Clip = loadWalk(gpa, io) catch return error.SkipZigTest;
    defer clip.deinit();

    var rig: Rig = undefined;
    try rig.initAs(gpa, 1.0 / 60.0, true);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    dance.limpKeepArmature(m);
    const root_len: usize = clip.nq - m.coordinate_count;
    try expect(root_len == 7);
    var target: rbt.Data = try .init(gpa, m);
    defer target.deinit();
    var tracker: dance.Tracker = try .init(gpa, m.dof_count);
    defer tracker.deinit();
    const accel: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(accel);
    const torque: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(torque);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    const full: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(full);
    const dense: []f32 = try gpa.alloc(f32, m.dof_count * m.dof_count);
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
        @memcpy(rig.data.joint_positions, clip.pose(1)[root_len..]);
        rbt.differentiatePos(m, rig.data.joint_velocities, clip.pose(0)[root_len..], clip.pose(1)[root_len..], dt);
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
            @memcpy(rig.data.applied_joint_forces, torque);
            rbt.step(m, &rig.data);
            rbt.forward(m, &rig.data);
            @memcpy(target.joint_positions, next);
            target.stage = .stale;
            rbt.kinematics(m, &target);
            const off: f32 = dance.worstBodyErrorDeg(m, rig.data.body_orientations, target.body_orientations);
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
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const root: usize = 1;
    var reference: State = try .init(gpa, m.body_count);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, m.body_count);
    defer sim.deinit(gpa);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    var rng: Random.DefaultPrng = .init(31);
    const random: Random = rng.random();
    rig.scatter(random, 0.5);
    stateOf(m, &rig.data, &reference);
    const reference_pose: []f32 = try gpa.dupe(f32, rig.data.joint_positions);
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
        applyAction(m, reference_pose, action, scale, scratch, rig.data.joint_positions);
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
    const gpa: Allocator = testing_allocator;
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
    const gpa: Allocator = testing_allocator;
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

test "robot_track: head height - SuperTrack's rule, on the head alone" {
    // Plan F3b's known answers, on synthetic states: the head's height gap is exact and flips the verdict at the
    // limit; any OTHER body's height leaves it at zero; without a head (`trackingError`) there is no head term.
    const gpa: Allocator = testing_allocator;
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
    const gpa: Allocator = testing_allocator;
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
    try expect(indexOfScalar(bool, none, true) == null);
}

test "robot_track: stateOf's per-body lowest points agree with the whole body's lowest point" {
    // The geometry is ONE function (`rbt.geomLowestPoint`); the per-body split must not change what the
    // whole-model minimum is, on a real posed model.
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var rng: Random.DefaultPrng = .init(7);
    rig.scatter(rng.random(), 0.5);
    var state: State = try .init(gpa, m.body_count);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var clip: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 4.0) catch
        return error.SkipZigTest;
    defer clip.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const velocity: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(velocity);
    for ([_]usize{ 0, 1, 37, 120 }) |frame| {
        resetToFrame(m, &rig.data, &clip, frame);
        const at: usize = @max(frame, 1);
        // The pose is the clip's, number for number...
        for (rig.data.joint_positions, clip.pose(at)) |got, want| {
            try expect(got == want);
        }
        // ...and the velocity is the one the clip has there.
        rbt.differentiatePos(m, velocity, clip.pose(at - 1), clip.pose(at), clip.frame_time);
        for (rig.data.joint_velocities, velocity) |got, want| {
            try expect(@abs(got - want) < 1.0e-6);
        }
    }
}

/// Raise a whole clip until no part of the robot is below the floor, and say by how much.
///
/// The clip's own grounding puts the feet on the floor in the TYPICAL frame, which leaves the
/// deepest frames underneath it - a pose a simulation cannot reproduce, because the floor pushes
/// back. `d` is scratch.
pub fn liftAboveFloor(m: *const rbt.Model, clip: *dance.Clip, d: *rbt.Data) f32 {
    assertf(
        clip.nq == m.coordinate_count and m.joint_count > 0 and m.joint_type[0] == .free,
        @src(),
        "lifting moves the root's height, so the clip must be this model's and the model must have a free root",
        .{},
    );
    var deepest: f32 = 0.0;
    for (0..clip.frame_count) |f| {
        @memcpy(d.joint_positions, clip.pose(f));
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

test "robot_track: D8 - the reference through the floor, left alone or lifted clear" {
    // THE FLOOR DECISION. Grounding shifts a clip by the median lowest FOOT point, which is a fair
    // rule for walking and a poor one for a clip that lies down: the walk ends up 2 cm through the
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var reference_data: rbt.Data = try .init(gpa, m);
    defer reference_data.deinit();
    var sim: State = try .init(gpa, m.body_count);
    defer sim.deinit(gpa);
    var want: State = try .init(gpa, m.body_count);
    defer want.deinit(gpa);
    const accel: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(accel);
    const torque: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(torque);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(scratch);
    const full: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(full);
    const dense: []f32 = try gpa.alloc(f32, m.dof_count * m.dof_count);
    defer gpa.free(dense);

    const walk_path: []const u8 = "assets/lafan1/walk1_subject2.bvh";
    const get_up_path: []const u8 = "assets/lafan1/fallAndGetUp2_subject2.bvh";
    for ([_][]const u8{ walk_path, get_up_path }) |path| {
        // The decision's premises - left alone the clip is buried, one offset floats it - are the get-up's: it
        // lies on the floor for seconds, so its deepest frames sit far below its typical one. A walk's frames all
        // sit within a centimetre of each other, so one offset lifts it clear without floating it far, and how
        // deep or how far is a fact about the capture, not about lifting.
        const lies_down: bool = eql(u8, path, get_up_path);
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
                @memcpy(reference_data.joint_positions, clip.pose(f));
                reference_data.stage = .stale;
                rbt.kinematics(m, &reference_data);
                floats[f] = dance.lowestBodyPoint(m, &reference_data);
                reference_deepest = @min(reference_deepest, floats[f]);
            }
            sortSlice(f32, floats, {}, std.sort.asc(f32));
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
                    @memcpy(rig.data.applied_joint_forces, torque);
                    rbt.step(m, &rig.data);

                    // The root is a puppet: put it exactly where the reference has it, with the
                    // reference's own velocity, so nothing here is about balance.
                    const next: []const f32 = clip.pose(start + frames + 1);
                    @memcpy(rig.data.joint_positions[0..7], next[0..7]);
                    rbt.differentiatePos(m, scratch, target, next, clip.frame_time);
                    @memcpy(rig.data.joint_velocities[0..6], scratch[0..6]);
                    rig.data.stage = .stale;
                    rbt.forward(m, &rig.data);
                    stateOf(m, &rig.data, &sim);
                    deepest_sim = @min(deepest_sim, dance.lowestBodyPoint(m, &rig.data));
                    @memcpy(reference_data.joint_positions, next);
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
            // it. Leaving the get-up alone buries it; one offset for the whole of it floats it.
            // On every clip, lifting clear leaves nothing under the floor.
            switch (option) {
                0 => {
                    if (lies_down) {
                        try expect(reference_deepest < -0.02);
                    }
                },
                1 => {
                    try expect(reference_deepest > -0.001);
                    if (lies_down) {
                        try expect(typical > 0.01);
                    }
                },
                else => {
                    try expect(@abs(typical) < 0.01);
                    try expect(reference_deepest > -0.01);
                },
            }
        }
    }
}

test "robot_track: the awkward cases a network will find" {
    // Everything here is something a half-trained network, or a caller in a hurry, will do sooner
    // or later. None of it may produce a NaN, an infinity, or a silently wrong answer.
    const gpa: Allocator = testing_allocator;

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
    var replay: Replay = try .init(gpa, m, 2, 64, actionSize(m));
    defer replay.deinit();
    const pose: []f32 = try gpa.alloc(f32, m.coordinate_count);
    defer gpa.free(pose);
    const velocity: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(velocity);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    @memset(pose, 0.0);
    @memset(velocity, 0.0);
    @memset(action, 0.0);
    for (0..40) |k| {
        replay.append(0, pose, velocity, action, @intCast(k), 0, 0);
    }
    var rng: Random.DefaultPrng = .init(2);
    const window: Replay.Window = replay.sampleWindow(rng.random(), 8) orelse return error.NoWindow;
    try expect(window.steps == 8);
    try expect(window.frames() == 9);
    // The last frame of the window is a real record, and its predecessor is the one before it -
    // so the window really does hold eight transitions to train on.
    try expect(replay.frameAt(0, window.first + window.steps) == replay.frameAt(0, window.first) + 8);

    // And the world does not move, whatever a world model predicts for it.
    var state: State = try .init(gpa, m.body_count);
    defer state.deinit(gpa);
    rig.scatter(rng.random(), 0.3);
    stateOf(m, &rig.data, &state);
    const before_position: Vec = state.positions[0];
    const before_rotation: Quat = state.rotations[0];
    const linear: []Vec = try gpa.alloc(Vec, m.body_count);
    defer gpa.free(linear);
    const angular: []Vec = try gpa.alloc(Vec, m.body_count);
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
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var replay: Replay = try .init(gpa, m, 4, 128, actionSize(m));
    defer replay.deinit();
    const pose: []f32 = try gpa.alloc(f32, m.coordinate_count);
    defer gpa.free(pose);
    const velocity: []f32 = try gpa.alloc(f32, m.dof_count);
    defer gpa.free(velocity);
    const action: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(action);
    @memset(pose, 0.0);
    @memset(velocity, 0.0);
    @memset(action, 0.0);

    var rng: Random.DefaultPrng = .init(77);
    const random: Random = rng.random();
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};

    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 512, .pushes = .{ .every = 45 } });
    defer fleet.deinit();
    const actions: []f32 = try gpa.alloc(f32, 8 * actionSize(m));
    defer gpa.free(actions);
    const observations: []f32 = try gpa.alloc(f32, 8 * observationSize(m));
    defer gpa.free(observations);
    var rng: Random.DefaultPrng = .init(3);
    const random: Random = rng.random();

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
    var sampled: State = try .init(gpa, m.body_count);
    defer sampled.deinit(gpa);
    for (0..200) |_| {
        const window: Replay.Window = fleet.replay.sampleWindow(random, 8) orelse continue;
        reconstructed += 1;
        for (0..window.frames()) |k| {
            @memcpy(scratch_data.joint_positions, fleet.replay.poseAt(window.env, window.first + k));
            @memcpy(scratch_data.joint_velocities, fleet.replay.velocityAt(window.env, window.first + k));
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
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
    var rng: Random.DefaultPrng = .init(41);
    const random: Random = rng.random();
    for (0..500) |_| {
        for (actions) |*a| {
            a.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        _ = fleet.step(actions);
    }

    const targets: []f32 = try gpa.alloc(f32, m.coordinate_count);
    defer gpa.free(targets);
    const scratch: []f32 = try gpa.alloc(f32, m.dof_count);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 12.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};
    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 512 });
    defer fleet.deinit();

    const actions: []f32 = try gpa.alloc(f32, 8 * actionSize(m));
    defer gpa.free(actions);
    var rng: Random.DefaultPrng = .init(19);
    const random: Random = rng.random();
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
    var oracle_rng: Random.DefaultPrng = .init(101);
    var baseline_rng: Random.DefaultPrng = .init(101);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 6.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const clips = [_]*const dance.Clip{&walk};
    const pushed_every_40: Fleet.Options = .{ .envs = 4, .capacity = 16, .seed = 12, .pushes = .{ .every = 40 } };
    const careful: *Fleet = try .init(gpa, m, &clips, pushed_every_40);
    defer careful.deinit();
    const quick: *Fleet = try .init(gpa, m, &clips, pushed_every_40);
    defer quick.deinit();
    const actions: []f32 = try gpa.alloc(f32, 4 * actionSize(m));
    defer gpa.free(actions);
    var rng: Random.DefaultPrng = .init(8);
    const random: Random = rng.random();
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
        for (a.joint_positions, b.joint_positions) |x, y| {
            try expect(x == y);
        }
        for (a.joint_velocities, b.joint_velocities) |x, y| {
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 8.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
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

test "robot_track: the gravity gate - a body lying with the right joint angles no longer scores like one standing" {
    // Known answer, built so every root-frame term is EXACTLY zero: a standing pose, then the same pose turned
    // 90 degrees as a rigid whole about its root and lowered to the floor. The old reward cannot tell them apart
    // beyond its two root terms (~0.80); the gated one must, and the height limit must end the episode.
    const gpa: Allocator = testing_allocator;
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

test "robot_track: a push changes the whole body's velocity by its speed, in its direction; zero changes nothing" {
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 4.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const clips = [_]*const dance.Clip{&walk};
    const fleet: *Fleet = try .init(gpa, m, &clips, .{ .envs = 1, .capacity = 16 });
    defer fleet.deinit();
    fleet.startAt(0, 0, 10);
    const before: []f32 = try gpa.dupe(f32, fleet.data[0].joint_velocities);
    defer gpa.free(before);
    const segment_before: u32 = fleet.segment[0];
    // Zero: nothing moves.
    fleet.push(0, 0, 1.0);
    try expectEqualSlices(f32, before, fleet.data[0].joint_velocities);
    // 1.5 m/s a quarter turn round: along y, the whole body - only the root's linear velocity changes.
    fleet.push(0, 1.5, pi / 2.0);
    try expectApproxEqAbs(before[0], fleet.data[0].joint_velocities[0], 1e-6);
    try expectApproxEqAbs(before[1] + 1.5, fleet.data[0].joint_velocities[1], 1e-6);
    try expectEqualSlices(f32, before[2..], fleet.data[0].joint_velocities[2..]);
    // Each push begins a new segment.
    try expect(fleet.segment[0] != segment_before);
}

test "robot_track: the recovery probe - a nudge survived more often than a hard push; every loss accounted for" {
    // The probe on the servo with no policy (every action zero: PD toward the reference), on a walk: a push of 0 m/s
    // and one of 1.5 m/s. Harder pushes cannot be survived more often - the probe's one sanity check - and the
    // table is logged. Every pushed start is survived or lost, and without returns nothing returns. Then the same
    // probe with returns followed for two seconds: every loss returned, not returned or unresolved - and none twice.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    var scratch_data: rbt.Data = try .init(gpa, m);
    defer scratch_data.deinit();
    _ = try liftPerFrame(gpa, m, &walk, &scratch_data, 3.0);
    const starts: []usize = try evenStarts(gpa, &walk, 60);
    defer gpa.free(starts);
    const probe: RecoveryProbe = .{ .speeds = &.{ 0.0, 1.5 } };
    var bands: [2]RecoveryBand = undefined;
    try probeRecovery(gpa, m, &walk, .{ .envs = 1, .capacity = 16 }, starts, null, probe, &bands);
    for (bands) |band| {
        std.log.warn("recovery probe, the servo alone: {d:.1} m/s - {d} pushes, survived {d:.2}, recovered {d:.2}, " ++
            "in {d:.2} s", .{
            band.speed,
            band.pushes,
            band.survivalRate(),
            band.recoveryRate(),
            band.meanRecoverySeconds(),
        });
    }
    try expect(bands[0].pushes > 0);
    try expect(bands[0].survivalRate() >= bands[1].survivalRate());
    for (bands) |band| {
        try expectEqual(band.pushes, band.survived + band.lost);
        try expectEqual(@as(usize, 0), band.returned + band.not_returned);
    }
    const probe_with_returns: RecoveryProbe = .{ .speeds = &.{ 0.0, 1.5 }, .return_seconds = 2 };
    var return_bands: [2]RecoveryBand = undefined;
    try probeRecovery(gpa, m, &walk, .{ .envs = 1, .capacity = 16 }, starts, null, probe_with_returns, &return_bands);
    for (return_bands) |band| {
        std.log.warn("return probe, the servo alone: {d:.1} m/s - {d} pushes, lost {d}, returned {d}, not {d}", .{
            band.speed,
            band.pushes,
            band.lost,
            band.returned,
            band.not_returned,
        });
        try expectEqual(band.pushes, band.survived + band.lost);
        try expect(band.returned + band.not_returned <= band.lost);
    }
}

test "robot_track: a fleet that restarts nothing lives on after its losses, and a hand lifts a character" {
    // The servo alone loses the walk within a second. A fleet told not to restart its episodes
    // (`Options.restarts_episodes` off) ends none in 700 decisions - past the ten-second clip's end - while its losses
    // are still judged; its reference holds the clip's last frame with a goal after it. Beside it, a fleet that
    // restarts ends many. A third character, pulled by a hand at his root toward a point two metres above where he
    // started (`pulls`), stands higher after a second than his twin left alone.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const clips = [_]*const dance.Clip{&walk};
    const lives_on: *Fleet = try .init(gpa, m, &clips, .{ .envs = 1, .capacity = 16, .restarts_episodes = false });
    defer lives_on.deinit();
    const restarting: *Fleet = try .init(gpa, m, &clips, .{ .envs = 1, .capacity = 16 });
    defer restarting.deinit();
    const actions: []f32 = try gpa.alloc(f32, actionSize(m));
    defer gpa.free(actions);
    @memset(actions, 0.0);
    var losses_judged: usize = 0;
    for (0..700) |_| {
        _ = lives_on.step(actions);
        _ = restarting.step(actions);
        try expect(!lives_on.dones[0]);
        losses_judged += @intFromBool(lives_on.failures[0]);
    }
    try expectEqual(@as(usize, 0), lives_on.episodes);
    try expect(losses_judged > 0);
    try expectEqual(walk.frame_count - 2, @as(usize, lives_on.frame[0]));
    try expect(restarting.episodes > 3);
    // The hand: two characters from the same start, one pulled at his root.
    const pulled: *Fleet = try .init(gpa, m, &clips, .{ .envs = 1, .capacity = 16, .restarts_episodes = false });
    defer pulled.deinit();
    const alone: *Fleet = try .init(gpa, m, &clips, .{ .envs = 1, .capacity = 16, .restarts_episodes = false });
    defer alone.deinit();
    const root_body: u32 = 1;
    const start_root: Vec = pulled.data[0].body_positions[root_body];
    pulled.pulls[0] = .{
        .body = root_body,
        .point_local = vec(0, 0, 0),
        .target = start_root + vec(0, 0, 2),
        .mass = m.body_subtree_mass[root_body],
    };
    for (0..60) |_| {
        _ = pulled.step(actions);
        _ = alone.step(actions);
    }
    const pulled_height: f32 = pulled.data[0].body_positions[root_body][2];
    const alone_height: f32 = alone.data[0].body_positions[root_body][2];
    try expect(pulled_height > alone_height + 0.5);
}

test "robot_track: rows after a loss are flagged, policy windows never start on one; no aftermath changes nothing" {
    // The servo alone (every action zero) loses the walk within a second, so losses are certain. A fleet whose first
    // half lives on 30 steps after a loss (`aftermath_share` 0.5): only that half records rows after a loss, and a
    // window drawn to start before a loss never starts on one. A fleet with no aftermath: no row is flagged, and
    // the two ways of drawing - anywhere, before a loss - give the very same windows from the same seed: today's
    // trainer, row for row.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var walk: dance.Clip = loadClip(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", 10.0) catch
        return error.SkipZigTest;
    defer walk.deinit();
    var rig: Rig = undefined;
    try rig.init(gpa, 1.0 / 60.0);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const clips = [_]*const dance.Clip{&walk};
    const env_count: usize = 4;
    const living_on: Fleet.Options = .{
        .envs = env_count,
        .capacity = 256,
        .aftermath_steps = 30,
        .aftermath_share = 0.5,
    };
    const resetting: Fleet.Options = .{ .envs = env_count, .capacity = 256 };
    const with_aftermath: *Fleet = try .init(gpa, m, &clips, living_on);
    defer with_aftermath.deinit();
    const without_aftermath: *Fleet = try .init(gpa, m, &clips, resetting);
    defer without_aftermath.deinit();
    const actions: []f32 = try gpa.alloc(f32, env_count * actionSize(m));
    defer gpa.free(actions);
    @memset(actions, 0.0);
    for (0..240) |_| {
        _ = with_aftermath.step(actions);
        _ = without_aftermath.step(actions);
    }
    // With an aftermath: rows after a loss in the living-on half only.
    for (0..env_count) |env| {
        var flagged: usize = 0;
        const written: u64 = with_aftermath.replay.written[env];
        for (0..written) |index| {
            flagged += @intFromBool(with_aftermath.replay.afterLossAt(env, index));
        }
        const lives_on: bool = with_aftermath.keepsAftermath(env);
        try expect(lives_on == (env < 2));
        if (lives_on) {
            try expect(flagged > 0);
        } else {
            try expectEqual(@as(usize, 0), flagged);
        }
    }
    var draws: Random.DefaultPrng = .init(5);
    for (0..200) |_| {
        const window: Replay.Window = with_aftermath.replay.sampleWindowStarting(draws.random(), 8, .before_loss) orelse
            continue;
        try expect(!with_aftermath.replay.afterLossAt(window.env, window.first));
    }
    // Without one: nothing flagged, and both ways of drawing draw the same windows.
    for (0..env_count) |env| {
        for (0..without_aftermath.replay.written[env]) |index| {
            try expect(!without_aftermath.replay.afterLossAt(env, index));
        }
    }
    var anywhere_draws: Random.DefaultPrng = .init(9);
    var before_loss_draws: Random.DefaultPrng = .init(9);
    for (0..100) |_| {
        const anywhere: ?Replay.Window =
            without_aftermath.replay.sampleWindowStarting(anywhere_draws.random(), 8, .anywhere);
        const before_loss: ?Replay.Window =
            without_aftermath.replay.sampleWindowStarting(before_loss_draws.random(), 8, .before_loss);
        try expectEqual(anywhere, before_loss);
    }
}

/// A reference of six bodies in a varied pose - each its own position, rotation and velocities - for SuperMimic's
/// terms to be measured against; body 0 is the world, body 1 the root.
fn superMimicTestReference(gpa: Allocator) !State {
    const bodies: usize = 6;
    var reference: State = try .init(gpa, bodies);
    for (0..bodies) |body| {
        const index: f32 = float(body);
        reference.positions[body] = vec(0.1 * index, -0.05 * index, 1.0 - 0.1 * index);
        reference.rotations[body] = quatFromAxisAngle(normalize3(vec(1, index, 2)), 0.3 * index);
        reference.velocities[body] = vec(0.2 * index, 0.1, -0.1 * index);
        reference.angular[body] = vec(0.0, 0.3 * index, 0.1);
    }
    return reference;
}

/// A check of a measured number against its value by hand, within `tolerance`, named for the failure's line.
fn holdsNear(
    checks: *report.Checks,
    name: []const u8,
    found: f32,
    expected: f32,
    tolerance: f32,
) void {
    checks.holds(@abs(found - expected) <= tolerance, "{s}: {d}, {d} expected\n", .{ name, found, expected });
}

/// A check of a count against its value by hand, named for the failure's line.
fn holdsCount(
    checks: *report.Checks,
    name: []const u8,
    found: u32,
    expected: u32,
) void {
    checks.holds(found == expected, "{s}: {d}, {d} expected\n", .{ name, found, expected });
}

test "tracking quality by hand: re-anchored errors, the feet's contacts, slip and depth, and the means' units" {
    // The test reference's six bodies, bodies 4 and 5 the feet: foot 4 on the floor (5 mm), foot 5 in the air.
    //   step 1  the character is the reference lifted 5 cm and still: every body 5 cm off (re-anchoring keeps the
    //           height),
    //           the root 5 cm off; foot 4 now in the air - one foot of two agrees - and nothing touches, so
    //           nothing slips; the reference's foot 4 slips at |(0.8, 0.1)| = 0.806 m/s.
    //   step 2  the character is the reference, but foot 5 sinks 4 mm into the floor: both its feet touch, one
    //           agrees; both slip, at 0.806 and |(1.0, 0.1)| = 1.005 m/s; the depth 4 mm over two feet.
    const gpa: Allocator = testing_allocator;
    var reference: State = try superMimicTestReference(gpa);
    defer reference.deinit(gpa);
    reference.lowest[4] = 0.005;
    reference.lowest[5] = 0.3;
    var lifted: State = try superMimicTestReference(gpa);
    defer lifted.deinit(gpa);
    for (lifted.positions, lifted.lowest, reference.lowest) |*position, *lowest, reference_lowest| {
        position.* += vec(0, 0, 0.05);
        lowest.* = reference_lowest + 0.05;
    }
    // Lifted and still: the reference's slip is its own velocity's, never the character's.
    @memset(lifted.velocities, @splat(0));
    var sinking: State = try superMimicTestReference(gpa);
    defer sinking.deinit(gpa);
    @memcpy(sinking.lowest, reference.lowest);
    sinking.lowest[5] = -0.004;
    const feet = [6]bool{ false, false, false, false, true, true };
    const root: usize = 1;
    const rule: QualityRule = .{};
    const first: QualityStep = measureQuality(lifted, reference, root, &feet, rule);
    const second: QualityStep = measureQuality(sinking, reference, root, &feet, rule);
    const tolerance: f32 = 1e-5;
    var checks: report.Checks = .{};
    holdsNear(&checks, "first.body_position_error", first.body_position_error, @as(f32, 0.0025), tolerance);
    holdsNear(&checks, "first.body_rotation_error", first.body_rotation_error, @as(f32, 0), tolerance);
    holdsNear(&checks, "first.root_distance", first.root_distance, @as(f32, 0.05), tolerance);
    holdsCount(&checks, "first.feet", first.feet, 2);
    holdsCount(&checks, "first.contacts_agreeing", first.contacts_agreeing, 1);
    holdsCount(&checks, "first.contacts", first.contacts, 0);
    holdsCount(&checks, "first.reference_contacts", first.reference_contacts, 1);
    const foot_4_speed: f32 = @sqrt(0.8 * 0.8 + 0.1 * 0.1);
    const foot_5_speed: f32 = @sqrt(1.0 * 1.0 + 0.1 * 0.1);
    holdsNear(&checks, "first.reference_slip_speed_sum", first.reference_slip_speed_sum, foot_4_speed, tolerance);
    holdsNear(&checks, "first.penetration", first.penetration, @as(f32, 0), tolerance);
    holdsCount(&checks, "second.contacts", second.contacts, 2);
    holdsCount(&checks, "second.contacts_agreeing", second.contacts_agreeing, 1);
    holdsNear(&checks, "second.slip_speed_sum", second.slip_speed_sum, foot_4_speed + foot_5_speed, tolerance);
    holdsNear(&checks, "second.penetration", second.penetration, @as(f32, 0.002), tolerance);
    // The means, in BlinkMimic's units.
    var sums: QualitySums = .{};
    sums.add(first);
    sums.add(second);
    holdsNear(&checks, "sums.bodyPositionCm()", sums.bodyPositionCm(), @as(f32, 100 * @sqrt(0.0025 / 2.0)), 1e-3);
    holdsNear(&checks, "sums.rootDistanceCm()", sums.rootDistanceCm(), @as(f32, 2.5), 1e-3);
    holdsNear(
        &checks,
        "sums.footSlipCmPerSecond()",
        sums.footSlipCmPerSecond(),
        100 * (foot_4_speed + foot_5_speed) / 2,
        1e-2,
    );
    holdsNear(
        &checks,
        "sums.referenceFootSlipCmPerSecond()",
        sums.referenceFootSlipCmPerSecond(),
        100 * foot_4_speed,
        1e-2,
    );
    holdsNear(&checks, "sums.contactAgreement()", sums.contactAgreement(), @as(f32, 0.5), 1e-6);
    holdsNear(&checks, "sums.penetrationMm()", sums.penetrationMm(), @as(f32, 1.0), 1e-3);
    try checks.finish();
}

test "SuperMimic's tracking: the reference itself earns every term, 5 in all" {
    const gpa: Allocator = testing_allocator;
    var reference: State = try superMimicTestReference(gpa);
    defer reference.deinit(gpa);
    const scales: SuperMimicScales = .{};
    const root: usize = 1;
    const terms: SuperMimicTracking = superMimicTracking(reference, reference, root, scales);
    try expect(@abs(terms.total - scales.maxStepTracking()) < 1.0e-5);
    try expect(@abs(scales.maxStepTracking() - 5.0) < 1.0e-6);
}

test "SuperMimic's tracking: drift and heading forgiven in the pose, not at the root" {
    // The character is the reference turned half a radian about the vertical through its root and moved across the
    // floor: the re-anchored pose matches exactly, while the root's own position and rotation do not.
    const gpa: Allocator = testing_allocator;
    var reference: State = try superMimicTestReference(gpa);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, reference.positions.len);
    defer sim.deinit(gpa);
    const root: usize = 1;
    const heading_turn: f32 = 0.5;
    const drift: Vec = vec(0.3, -0.2, 0.0);
    const turn: Quat = quatFromAxisAngle(vec(0, 0, 1), heading_turn);
    const reference_root: Vec = reference.positions[root];
    for (0..reference.positions.len) |body| {
        sim.positions[body] = reference_root + drift + rotate(turn, reference.positions[body] - reference_root);
        sim.rotations[body] = qmul(turn, reference.rotations[body]);
        sim.velocities[body] = reference.velocities[body];
        sim.angular[body] = reference.angular[body];
    }
    const scales: SuperMimicScales = .{};
    const terms: SuperMimicTracking = superMimicTracking(sim, reference, root, scales);
    try expect(@abs(terms.body_position - 1.0) < 1.0e-5);
    try expect(@abs(terms.body_rotation - 1.0) < 1.0e-5);
    const drift_squared: f32 = dot3(drift, drift);
    const expected_root_position: f32 = @exp(-drift_squared / (scales.root_position * scales.root_position));
    const heading_turn_squared: f32 = heading_turn * heading_turn;
    const root_rotation_scale_squared: f32 = scales.root_rotation * scales.root_rotation;
    const expected_root_rotation: f32 = @exp(-heading_turn_squared / root_rotation_scale_squared);
    try expect(@abs(terms.root_position - expected_root_position) < 1.0e-5);
    try expect(@abs(terms.root_rotation - expected_root_rotation) < 1.0e-4);
}

test "SuperMimic's tracking: a velocity error costs what its scale says" {
    const gpa: Allocator = testing_allocator;
    var reference: State = try superMimicTestReference(gpa);
    defer reference.deinit(gpa);
    var sim: State = try .init(gpa, reference.positions.len);
    defer sim.deinit(gpa);
    const velocity_error: Vec = vec(0.5, 0.0, 0.0);
    for (0..reference.positions.len) |body| {
        sim.positions[body] = reference.positions[body];
        sim.rotations[body] = reference.rotations[body];
        sim.velocities[body] = reference.velocities[body] + velocity_error;
        sim.angular[body] = reference.angular[body];
    }
    const scales: SuperMimicScales = .{};
    const root: usize = 1;
    const terms: SuperMimicTracking = superMimicTracking(sim, reference, root, scales);
    const expected: f32 = @exp(-dot3(velocity_error, velocity_error) / (scales.body_velocity * scales.body_velocity));
    try expect(@abs(terms.body_velocity - expected) < 1.0e-6);
    try expect(@abs(terms.body_position - 1.0) < 1.0e-6);
}

test "SuperMimic's action rate: the squared change of the action" {
    const action = [_]f32{ 1.0, 2.0, -0.5 };
    const previous_action = [_]f32{ 0.0, 0.0, -0.5 };
    try expect(@abs(superMimicActionRate(&action, &previous_action) - 5.0) < 1.0e-6);
    try expect(superMimicActionRate(&action, &action) == 0.0);
}

test "SuperMimic's joint limits: only past the soft range - a hinge and a slide; a ball by its box" {
    // A hinge limited to [-1, 1] (soft range [-0.9, 0.9]) and a slide to [0, 2] (soft [0.1, 1.9]), each by its one
    // coordinate; a ball by its rotation box.
    const soft_limit_share: f32 = 0.9;
    const hinge_range: [2]f32 = .{ -1.0, 1.0 };
    const slide_range: [2]f32 = .{ 0.0, 2.0 };
    try expect(rbt.jointLimitExcess(.ofSingle(0.5), .hinge, hinge_range, soft_limit_share) == 0.0);
    try expect(rbt.jointLimitExcess(.ofSingle(1.0), .slide, slide_range, soft_limit_share) == 0.0);
    // The hinge 0.1 past its soft high, the slide 0.05 below its soft low.
    try expect(@abs(rbt.jointLimitExcess(.ofSingle(1.0), .hinge, hinge_range, soft_limit_share) - 0.1) < 1.0e-6);
    try expect(@abs(rbt.jointLimitExcess(.ofSingle(0.05), .slide, slide_range, soft_limit_share) - 0.05) < 1.0e-6);
    // A ball's box [-0.2, 1.4] about x (a knee's bend), [-0.3, 0.3] about y and z: bent 1.0 inside it; bent backward
    // to -0.5, 0.3 below its low - and the rotation vector round-trips.
    const box: rbt.RotationBox = .{ .low = vec(-0.2, -0.3, -0.3), .high = vec(1.4, 0.3, 0.3) };
    try expect(rbt.ballBoxExcess(rbt.rotationOfVector(vec(1.0, 0.0, 0.0)), box) < 1.0e-6);
    const backward: f32 = rbt.ballBoxExcess(rbt.rotationOfVector(vec(-0.5, 0.0, 0.0)), box);
    try expect(@abs(backward - 0.3) < 1.0e-5);
    const round_trip: Vec = rbt.rotationVectorOf(rbt.rotationOfVector(vec(0.7, -0.2, 0.1)));
    try expect(@abs(round_trip[0] - 0.7) < 1.0e-5 and @abs(round_trip[1] + 0.2) < 1.0e-5);
}

test "the recovery probe's durations: the same seconds at either clock" {
    // At 60 decisions a second the probe counts what it always counted; at 30, half - the same seconds.
    const probe: RecoveryProbe = .{ .return_seconds = 2.0 };
    const at_sixty: ProbeSteps = probe.stepsAt(1.0 / 60.0);
    const expected_at_sixty: ProbeSteps = .{
        .settle = 60,
        .watch = 180,
        .average = 15,
        .return_limit = 120,
        .return_hold = 8,
    };
    try expectEqual(expected_at_sixty, at_sixty);
    // A quarter of a second is seven and a half decisions at 30 a second. 1/60 has no exact binary form, so the
    // quotient in f32 falls just short of the half, 7.4999995, and rounds to 7 - the same on every machine, as
    // division is correctly rounded.
    const at_thirty: ProbeSteps = probe.stepsAt(secondsPerDecision(1.0 / 60.0, 2));
    const expected_at_thirty: ProbeSteps = .{
        .settle = 30,
        .watch = 90,
        .average = 7,
        .return_limit = 60,
        .return_hold = 4,
    };
    try expectEqual(expected_at_thirty, at_thirty);
}
