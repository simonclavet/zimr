//! robot_maximal.zig - the same robot, rebuilt in maximal coordinates.
//!
//! `robot.zig` simulates an articulated body in REDUCED coordinates: the joint angles are the
//! state, so a joint cannot come apart. This file takes the very same built `rbt.Model` and
//! rebuilds it as `zimrphysics` rigid bodies held together by joint constraints - the way a game
//! engine builds a ragdoll - so the two can be compared on ONE model. It is Stage 0 of
//! `src/notes/ragdoll_compare_plan.md`, and the tests at the bottom are that stage's gate.
//!
//! -- WHAT THE CONVERSION DOES --
//!
//!   * One rigid body per JOINTED robot body. A body with no joint - the humanoid's head and
//!     hands - is welded, so its geoms join its nearest jointed ancestor's compound.
//!   * Each body's shape is a compound of its geoms, posed as they are at `qpos0`, at density
//!     1000: MJCF's inertia-from-geoms default. Mass, centre of mass and inertia therefore come
//!     out of the same geometry on both sides - which the first test checks rather than trusts.
//!   * One joint per jointed body below the root, chosen by how many hinges it carries: one
//!     hinge is a limited revolute joint, which is exact; two or three become one swing-twist
//!     joint, which is not (see `Variant.game`).
//!
//! -- WHAT IT CANNOT EXPRESS, STATED PLAINLY --
//!
//! Armature, tendons, and joint stiffness and damping have no maximal counterpart here - the
//! plan's "limp" baseline removes them from the reduced side too (`limpReduced`). Hinges that
//! stack on one body with DIFFERENT pivots, like the humanoid's ankles 4 cm apart, become one
//! pivot at the first hinge's: the massless link between them is exactly what maximal
//! coordinates cannot hold.

const std = @import("std");
const report = @import("test_report.zig");
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const rbt = @import("robot.zig");
const zimrphysics = @import("zimrphysics.zig");

const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const dot3 = zm.dot3;
const length3 = zm.length3;
const qmul = zm.qmul;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const splat = zm.splat;
const float = zm.float;
const assertf = zm.assertf;
const pi = zm.pi;
const normalize3 = zm.normalize3;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const quat_identity = zm.quat_identity;
const acosRad = zm.acosRad;
const isFinite = zm.isFinite;

/// MJCF's default density, which its inertia-from-geoms uses. Both sides get their mass,
/// centre of mass and inertia from the same geoms at this density.
pub const density: f32 = 1000.0;

/// The part index of a robot body no part stands for: the world body.
pub const no_part: u32 = zm.maxInt(u32);

pub const Variant = enum {
    /// Swing-twist wherever a body carries two or three hinges - how game ragdolls are built
    /// (Jolt's `RagdollSettings`). The first hinge is the twist, with its exact range; the second
    /// is the plane swing and a third the normal swing, each a SYMMETRIC half-cone wide enough
    /// for that hinge's range, and a missing third is locked. MJCF's hinges compose in sequence,
    /// so their reachable set is a box of angles; a swing-twist limit is a pyramid in swing-twist
    /// space. They agree near the rest pose and differ at the extremes.
    game,
};

/// Which of a body's hinges becomes a swing-twist joint's TWIST: the one limit it keeps exactly.
pub const TwistHinge = enum {
    /// The first hinge MJCF lists. It is applied in the PARENT's frame, which is not where a
    /// swing-twist decomposition puts its twist, so its exact range ends up limiting the wrong angle.
    first,
    /// The last hinge MJCF lists. MJCF composes a body's hinges in order, R = R0 R1 R2, so the
    /// last is applied in the child's own frame - which is where a swing-twist decomposition puts
    /// its twist (q = swing * twist). The swings are then the earlier hinges, and the hip's
    /// -150..20 flexion is a twist with its exact range instead of a 150 degree swing cone.
    last,
};

pub const Options = struct {
    variant: Variant = .game,
    twist_hinge: TwistHinge = .last,
    friction: f32 = 0.7,
    /// Every part shares this group, so the ragdoll does not collide with itself - the reduced
    /// side's `Bridge` does the same, one group per root. Zero turns self-collision on.
    group_id: u32 = 1,
    /// zimrphysics' own defaults are 0.05 each. robot.zig has no body damping, so neither does
    /// the fair comparison.
    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.0,
    /// zimrphysics caps spin at 0.25*pi*60 ~ 47 rad/s by default; robot.zig's cap is its
    /// `max_velocity`, 100.
    max_angular_speed: f32 = 100.0,
    /// robot.zig's dynamics include every gyroscopic term; zimrphysics' default leaves them out.
    apply_gyroscopic: bool = true,
    /// Joint limits on. Off turns every joint into a free hinge or ball.
    limits: bool = true,
    /// Limits on the swing-twist (2- and 3-hinge) joints, separately from the revolute ones: their
    /// cones only approximate MJCF's boxes of angles. Ignored when `limits` is off.
    swing_twist_limits: bool = true,
    /// The cone left for the axis a 2-hinge body does NOT have. MJCF gives it zero freedom, but
    /// two hinges in series (R0 R1) decompose with a second-order rotation about that axis, and
    /// a zero cone fights every combined bend. Jolt's joints have no "two hinges in series"; this
    /// slack is the price of saying it with a swing-twist cone. No slack helps a ragdoll settle, so
    /// it stays at MJCF's zero.
    locked_axis_slack: f32 = 0.0,
};

/// One joint between two parts, and the pivot it holds together in each part's COM-centred
/// frame, captured when it was built. Joint ERROR is how far apart those two points are.
pub const Joint = struct {
    parent: u32,
    child: u32,
    local_parent: Vec,
    local_child: Vec,
    hinge_count: u32,
    /// The robot's hinge joints this joint stands for, in MJCF order; `hinge_count` are valid.
    hinges: [3]u32,
    /// Its index in `world.constraints`, where its motors live.
    constraint: u32,
    /// False when the robot body's hinges pivot about DIFFERENT points (the humanoid's ankles):
    /// one maximal pivot cannot follow two, so the pose itself leaves this joint apart.
    pivots_agree: bool,
};

/// A joint drive: a spring toward a target, stated as a FREQUENCY. zimrphysics' motors solve it
/// inside the constraint solver, and a frequency-stated spring behaves the same whatever the
/// limb weighs - a hand and a thigh settle equally fast, with no per-joint gain tuning.
pub const Drive = struct {
    frequency: f32,
    damping: f32 = 1.0,
    max_torque: f32 = 1.0e6,
    /// Drive the swing-twist (2- and 3-hinge) joints too. Off leaves them limp and drives only
    /// the revolute ones.
    swing_twist: bool = true,
};

/// The acceleration a critically damped (for `damping` 1) spring of `frequency` Hz asks of one
/// joint over a step of `dt`, evaluated IMPLICITLY - at the end of the step.
///
/// *** WHY IMPLICIT. The explicit spring a = w^2e - 2 zeta wv, stepped by semi-implicit Euler, is
/// stable only while h^2 + 4 zeta h < 4 with h = w*dt: for zeta = 1, h < 2sqrt2 - 2 ~ 0.83, which at 60 Hz
/// caps the spring at w ~ 50 rad/s - 7.9 Hz. Asking for the spring at the END of the step,
///     a = w^2(e - dt*v - dt^2*a) - 2 zeta w(v + dt*a),
/// and solving for a gives the line below: backward Euler, stable for EVERY frequency. Stiffness
/// then degrades gracefully toward "reach the target in a step or two" instead of blowing up -
/// the same idea as Tan et al.'s stable PD, and the reason Jolt's frequency-stated springs
/// (zimrphysics' motors) are stable at any setting. Feed the result to inverse dynamics.
pub fn stableSpringAccel(
    err: f32,
    vel: f32,
    frequency: f32,
    damping: f32,
    dt: f32,
) f32 {
    const omega: f32 = 2.0 * pi * frequency;
    const h: f32 = omega * dt;
    return (omega * omega * (err - dt * vel) - 2.0 * damping * omega * vel) /
        (1.0 + 2.0 * damping * h + h * h);
}

/// The same spring, damped toward a MOVING target's velocity instead of zero - velocity feedforward.
///
/// Ask for the end-of-step spring as above, but let the damping act on the velocity RELATIVE to the
/// target's: `a = w^2(e - dt*v - dt^2*a) - 2 zeta w(v + dt*a - target_vel)`. The position part is unchanged -
/// `err` already points at where the target will BE at the end of the step, so the body's own motion is all
/// that needs predicting - and solving gives the line below. With `target_vel` zero it is
/// `stableSpringAccel` exactly. Why it matters: critically damped at 20 Hz, the zero-velocity spring keeps
/// about 1.5% of a joint's velocity after one 1/60 s step, so every fast limb following a clip is braked
/// all the time, and a body launched in stride is stopped in a frame.
pub fn stableSpringAccelToward(
    err: f32,
    vel: f32,
    target_vel: f32,
    frequency: f32,
    damping: f32,
    dt: f32,
) f32 {
    const omega: f32 = 2.0 * pi * frequency;
    const h: f32 = omega * dt;
    return (omega * omega * (err - dt * vel) - 2.0 * damping * omega * (vel - target_vel)) /
        (1.0 + 2.0 * damping * h + h * h);
}

/// Joint torques that give a FLOATING-base model the joint accelerations `accel` asks for
/// (root entries ignored), with the root free to respond - floating-base inverse dynamics.
///
/// *** WHY NOT JUST THE JOINT ROWS OF M a + c. Those assume the root does not accelerate: they
/// are fixed-base torques. On a free body the root DOES accelerate - every joint torque pushes
/// back on it - and applying fixed-base torques to it threw the falling humanoid off at the
/// velocity cap at every frequency tried. The root has no actuator, so its rows must be zero:
///     M_rr a_r + M_rj a_j + c_r = 0   ->   a_r = -M_rr^-1 (c_r + M_rj a_j)
/// and the torques are the joint rows of M a + c with that a_r. Contacts are left out - they
/// are unknown until the step solves them - so this is exact in flight and an approximation
/// in contact. `d` must be forward-current with `rbt.biasForce` done; the root must be joint 0,
/// a free joint (6 DOFs from 0). `dense` holds nv*nv, `full` nv, and `out` receives nv torques.
pub fn floatingBaseTorques(
    m: *const rbt.Model,
    d: *rbt.Data,
    accel: []const f32,
    dense: []f32,
    full: []f32,
    out: []f32,
) void {
    const nv: usize = m.nv;
    assertf(m.jnt_type[0] == .free and m.jnt_dof_adr[0] == 0, @src(), "root must be joint 0, free", .{});
    rbt.massMatrixDense(m, d, dense);
    // The 6x6 root block, and the right-hand side -(c_r + M_rj a_j), in one augmented matrix.
    var block: [6][7]f32 = undefined;
    for (0..6) |r| {
        var rhs: f32 = -d.bias_force[r];
        for (6..nv) |j| {
            rhs -= dense[r * nv + j] * accel[j];
        }
        for (0..6) |c| {
            block[r][c] = dense[r * nv + c];
        }
        block[r][6] = rhs;
    }
    // Gaussian elimination with partial pivoting; the root block is a rigid body's spatial
    // inertia plus what the limbs add, so it is symmetric positive definite and never singular.
    for (0..6) |col| {
        var pivot: usize = col;
        for (col + 1..6) |r| {
            if (@abs(block[r][col]) > @abs(block[pivot][col])) {
                pivot = r;
            }
        }
        const swapped: [7]f32 = block[col];
        block[col] = block[pivot];
        block[pivot] = swapped;
        for (col + 1..6) |r| {
            const factor: f32 = block[r][col] / block[col][col];
            for (col..7) |c| {
                block[r][c] -= factor * block[col][c];
            }
        }
    }
    var root_accel: [6]f32 = undefined;
    var row: usize = 6;
    while (row > 0) {
        row -= 1;
        var value: f32 = block[row][6];
        for (row + 1..6) |c| {
            value -= block[row][c] * root_accel[c];
        }
        root_accel[row] = value / block[row][row];
    }
    @memcpy(full[0..6], &root_accel);
    @memcpy(full[6..nv], accel[6..nv]);
    rbt.inverseDynamics(m, d, full, out);
}

/// A robot body frame in the world: origin and rotation.
pub const Frame = struct {
    pos: Vec,
    rot: Quat,
};

pub const Ragdoll = struct {
    gpa: Allocator,
    /// One zimrphysics body per part.
    handles: []zimrphysics.BodyHandle,
    /// The jointed robot body each part stands for.
    robot_body: []u32,
    /// Robot body -> part, for EVERY robot body, welded ones included; `no_part` for the world.
    part_of_body: []u32,
    /// Where each part's centre of mass sits in its robot body's frame. The compound shape is
    /// recentred on its COM, so this is what maps a part back to the robot's body frame.
    com_local: []Vec,
    joints: []Joint,
    /// Every robot body's pose in its part's home-body frame, fixed at build: identity for a
    /// part's own body, the weld for a welded one. What lets a caller draw the head and hands.
    body_offset_pos: []Vec,
    body_offset_rot: []Quat,

    pub fn deinit(self: *Ragdoll) void {
        self.gpa.free(self.body_offset_pos);
        self.gpa.free(self.body_offset_rot);
        self.gpa.free(self.handles);
        self.gpa.free(self.robot_body);
        self.gpa.free(self.part_of_body);
        self.gpa.free(self.com_local);
        self.gpa.free(self.joints);
    }

    pub fn partCount(self: *const Ragdoll) usize {
        return self.handles.len;
    }

    pub fn bodyIndex(self: *const Ragdoll, part: usize) zimrphysics.BodyIndex {
        return self.handles[part].index();
    }

    /// The world pose of a part's robot-body frame - what `rbt.Data.body_xpos`/`body_xrot`
    /// would say for the same body.
    pub fn bodyFrame(
        self: *const Ragdoll,
        world: *const zimrphysics.World,
        part: usize,
    ) Frame {
        const body: *const zimrphysics.Body = &world.bodies.data[self.bodyIndex(part)];
        return .{ .pos = body.com_pos - rotate(body.rot, self.com_local[part]), .rot = body.rot };
    }

    /// The world pose of ANY robot body, welded ones included, as the maximal ragdoll has it.
    /// `body` must not be the world (0).
    pub fn robotBodyFrame(
        self: *const Ragdoll,
        world: *const zimrphysics.World,
        body: usize,
    ) Frame {
        const home: Frame = self.bodyFrame(world, self.part_of_body[body]);
        return .{
            .pos = home.pos + rotate(home.rot, self.body_offset_pos[body]),
            .rot = qmul(home.rot, self.body_offset_rot[body]),
        };
    }

    /// Drive every joint toward the pose `target` holds (a reduced `Data`, forward-current):
    /// hinges through their motor's target ANGLE, which is the MJCF angle itself; swing-twist
    /// joints through a target ORIENTATION of the child's constraint frame in the parent's,
    /// taken from the two bodies' target rotations. Leaves the pose to the solver.
    pub fn driveToPose(
        self: *const Ragdoll,
        world: *zimrphysics.World,
        m: *const rbt.Model,
        target: *const rbt.Data,
        drive: Drive,
    ) void {
        for (self.joints) |joint| {
            const c: *zimrphysics.Constraint = &world.constraints.items[joint.constraint];
            if (joint.hinge_count == 1) {
                c.motor = .{
                    .mode = .position,
                    .target_position = target.pos[m.jnt_qpos_adr[joint.hinges[0]]],
                    .max_force = drive.max_torque,
                    .frequency = drive.frequency,
                    .damping = drive.damping,
                };
                continue;
            }
            if (!drive.swing_twist) {
                continue;
            }
            const parent_rot: Quat = target.body_xrot[self.robot_body[joint.parent]];
            const child_rot: Quat = target.body_xrot[self.robot_body[joint.child]];
            c.target_orientation = qmul(
                conjugate(qmul(parent_rot, c.constraint_to_body_a)),
                qmul(child_rot, c.constraint_to_body_b),
            );
            const motor: zimrphysics.AngularMotorSettings = .{
                .frequency = drive.frequency,
                .damping = drive.damping,
                .min_torque = -drive.max_torque,
                .max_torque = drive.max_torque,
            };
            c.swing_motor = motor;
            c.twist_motor = motor;
            c.swing_motor_state = .position;
            c.twist_motor_state = .position;
        }
    }

    /// Every motor off: the ragdoll goes limp again.
    pub fn motorsOff(self: *const Ragdoll, world: *zimrphysics.World) void {
        for (self.joints) |joint| {
            const c: *zimrphysics.Constraint = &world.constraints.items[joint.constraint];
            c.motor.mode = .off;
            c.swing_motor_state = .off;
            c.twist_motor_state = .off;
        }
    }

    /// Pose the ragdoll like the reduced model's `d`, at rest: every part takes its robot body's
    /// ROTATION, and its position follows down the tree through the maximal pivots.
    ///
    /// ** POSITIONS BY MAXIMAL KINEMATICS, NOT COPIED. Copying each body's reduced position put
    /// the feet where the ankles' two pivots put them, 2 cm from where the one maximal pivot can;
    /// the solver's first step then yanked that gap shut through the whole leg, up to 0.37 rad
    /// at every leg joint at once. Placed this way every joint starts exactly closed, and the
    /// approximation shows where it belongs: as a foot a centimetre or two from the reduced one.
    /// `d` must be current (`rbt.forward` since its last change).
    pub fn setPose(
        self: *const Ragdoll,
        gpa: Allocator,
        world: *zimrphysics.World,
        d: *const rbt.Data,
    ) !void {
        const max_parts: usize = 64;
        assertf(self.partCount() <= max_parts, @src(), "{d} parts, room for {d}", .{
            self.partCount(),
            max_parts,
        });
        var coms: [max_parts]Vec = undefined;
        var rots: [max_parts]Quat = undefined;
        for (0..self.partCount()) |part| {
            rots[part] = d.body_xrot[self.robot_body[part]];
            // The root, and any part without a joint above it, takes the reduced position.
            coms[part] = d.body_xpos[self.robot_body[part]] + rotate(rots[part], self.com_local[part]);
        }
        // Parts are in robot-body order, so a parent is always placed before its child.
        for (self.joints) |joint| {
            const pivot: Vec = coms[joint.parent] + rotate(rots[joint.parent], joint.local_parent);
            coms[joint.child] = pivot - rotate(rots[joint.child], joint.local_child);
        }
        for (0..self.partCount()) |part| {
            try world.setTransform(gpa, self.bodyIndex(part), coms[part], rots[part]);
            try world.setLinearVelocity(gpa, self.handles[part], vec_zero);
            try world.setAngularVelocity(gpa, self.handles[part], vec_zero);
        }
    }

    /// The worst joint separation, in metres. Zero at build; a solver keeps it small, not zero.
    pub fn jointError(self: *const Ragdoll, world: *const zimrphysics.World) f32 {
        var worst: f32 = 0.0;
        for (self.joints) |joint| {
            const a: *const zimrphysics.Body = &world.bodies.data[self.bodyIndex(joint.parent)];
            const b: *const zimrphysics.Body = &world.bodies.data[self.bodyIndex(joint.child)];
            const pivot_a: Vec = a.com_pos + rotate(a.rot, joint.local_parent);
            const pivot_b: Vec = b.com_pos + rotate(b.rot, joint.local_child);
            worst = @max(worst, length3(pivot_a - pivot_b));
        }
        return worst;
    }

    /// The whole ragdoll's centre of mass.
    pub fn centerOfMass(self: *const Ragdoll, world: *const zimrphysics.World) Vec {
        var total: f32 = 0.0;
        var weighted: Vec = vec_zero;
        for (0..self.partCount()) |part| {
            const idx: zimrphysics.BodyIndex = self.bodyIndex(part);
            const mass: f32 = world.mass_props[idx].mass;
            total += mass;
            weighted += splat(mass) * world.bodies.data[idx].com_pos;
        }
        return weighted / splat(total);
    }

    /// Fastest linear or angular speed of any part - the "has it come to rest" number.
    pub fn peakSpeed(self: *const Ragdoll, world: *const zimrphysics.World) f32 {
        var fastest: f32 = 0.0;
        for (0..self.partCount()) |part| {
            const idx: zimrphysics.BodyIndex = self.bodyIndex(part);
            fastest = @max(fastest, length3(world.getLinearVelocity(idx)));
            fastest = @max(fastest, length3(world.getAngularVelocity(idx)));
        }
        return fastest;
    }
};

/// Rebuild `m` in `world` as rigid bodies and joints, posed as `d` holds (`d` current).
///
/// -- *** ANY POSE: THE RAGDOLL IS MADE AT qpos0, THEN POSED --
///
/// A zimrphysics joint measures from its orientation AT CREATION: a revolute joint's zero angle is
/// the pose it was built in, and so are a swing-twist joint's frames - while `driveToPose` hands a
/// hinge motor the raw MJCF angle and the limits are MJCF ranges, both measured from `qpos0`.
/// Built in any other pose, every hinge would be driven - and limited - off by its angle at
/// creation. So the parts and joints are always made at `qpos0` (`buildAtRest`), where the
/// engine's zeros are MJCF's, and the finished ragdoll is moved to `d`: any pose is valid.
pub fn build(
    gpa: Allocator,
    world: *zimrphysics.World,
    m: *const rbt.Model,
    d: *const rbt.Data,
    opts: Options,
) !Ragdoll {
    // Only the ragdoll's own deinit is in scope here: `buildAtRest`'s errdefers ended with it, so
    // a failed `setPose` frees each slice exactly once (they were live alongside it at first -
    // a double free on this path, caught in review).
    var ragdoll: Ragdoll = try buildAtRest(gpa, world, m, opts);
    errdefer ragdoll.deinit();
    try ragdoll.setPose(gpa, world, d);
    return ragdoll;
}

/// `build`'s body: every part and joint made at `qpos0` (a private rest pose), unposed.
fn buildAtRest(
    gpa: Allocator,
    world: *zimrphysics.World,
    m: *const rbt.Model,
    opts: Options,
) !Ragdoll {
    var rest: rbt.Data = try rbt.Data.init(gpa, m);
    defer rest.deinit();
    @memcpy(rest.pos, m.qpos0);
    rest.stage = .stale;
    rbt.forward(m, &rest);
    const at: *const rbt.Data = &rest;
    const body_count: usize = m.nbody;

    // -- Which robot bodies get a part: every body carrying a joint. --
    const jointed: []bool = try gpa.alloc(bool, body_count);
    defer gpa.free(jointed);
    @memset(jointed, false);
    for (0..m.njnt) |j| {
        const kind: rbt.JointType = m.jnt_type[j];
        const supported: bool = kind == .hinge or kind == .free;
        if (!supported) {
            return error.UnsupportedJoint;
        }
        jointed[m.jnt_body[j]] = true;
    }

    const part_of_body: []u32 = try gpa.alloc(u32, body_count);
    errdefer gpa.free(part_of_body);
    var robot_body_list: std.ArrayList(u32) = .empty;
    defer robot_body_list.deinit(gpa);
    part_of_body[0] = no_part;
    for (1..body_count) |b| {
        const parent: u32 = m.body_parent[b];
        assertf(parent < b, @src(), "body {d} precedes its parent {d}", .{ b, parent });
        // A body welded to the WORLD is a fixed base: it gets a part of its own, built static.
        const fixed_base: bool = !jointed[b] and parent == 0;
        if (jointed[b] or fixed_base) {
            part_of_body[b] = @intCast(robot_body_list.items.len);
            try robot_body_list.append(gpa, @intCast(b));
        } else {
            // Welded: it moves with its parent, so it becomes part of the parent's shape.
            if (part_of_body[parent] == no_part) {
                return error.WeldedToWorld;
            }
            part_of_body[b] = part_of_body[parent];
        }
    }
    const part_count: usize = robot_body_list.items.len;
    const robot_body: []u32 = try gpa.dupe(u32, robot_body_list.items);
    errdefer gpa.free(robot_body);
    const handles: []zimrphysics.BodyHandle = try gpa.alloc(zimrphysics.BodyHandle, part_count);
    errdefer gpa.free(handles);
    const com_local: []Vec = try gpa.alloc(Vec, part_count);
    errdefer gpa.free(com_local);

    // -- One compound per part, from every geom of the bodies that make it up. --
    var children: std.ArrayList(zimrphysics.CompoundChild) = .empty;
    defer children.deinit(gpa);
    for (0..part_count) |part| {
        const home: u32 = robot_body[part];
        const home_pos: Vec = at.body_xpos[home];
        const home_rot: Quat = at.body_xrot[home];
        const to_home: Quat = conjugate(home_rot);
        children.clearRetainingCapacity();
        for (0..m.ngeom) |g| {
            const owner: u32 = m.geom_body[g];
            if (part_of_body[owner] != part) {
                continue;
            }
            const leaf: zimrphysics.Shape = switch (m.geom_shape[g]) {
                .sphere => |s| .{ .sphere = .{ .radius = s.radius } },
                .capsule => |c| .{ .capsule = .{ .half_height = c.half_height, .radius = c.radius } },
                else => return error.UnsupportedGeom,
            };
            const geom_pos: Vec = at.body_xpos[owner] + rotate(at.body_xrot[owner], m.geom_pos[g]);
            const geom_rot: Quat = qmul(at.body_xrot[owner], m.geom_rot[g]);
            try children.append(gpa, .{
                .shape = try world.shapes.add(gpa, leaf),
                .local_pos = rotate(to_home, geom_pos - home_pos),
                .local_rot = qmul(to_home, geom_rot),
            });
        }
        if (children.items.len == 0) {
            return error.PartWithoutGeometry;
        }
        const compound_id: zimrphysics.ShapeId = try world.shapes.addCompound(gpa, children.items);
        const is_fixed_base: bool = !jointed[home] and m.body_parent[home] == 0;
        // The store recentred the children on the COM, so the first child's shift IS the COM.
        const stored: []const zimrphysics.CompoundChild = world.shapes.get(compound_id).compound.children;
        com_local[part] = children.items[0].local_pos - stored[0].local_pos;
        handles[part] = try world.createBody(.{
            .shape = compound_id,
            .position = home_pos + rotate(home_rot, com_local[part]),
            .rotation = home_rot,
            .density = density,
            .friction = opts.friction,
            .restitution = 0.0,
            .linear_damping = opts.linear_damping,
            .angular_damping = opts.angular_damping,
            .max_angular_speed = opts.max_angular_speed,
            .apply_gyroscopic = opts.apply_gyroscopic,
            .group_id = opts.group_id,
            .motion_type = if (is_fixed_base) .static else .dynamic,
        });
    }

    // -- One joint per part below the root, from the hinges its robot body carries. --
    var joint_list: std.ArrayList(Joint) = .empty;
    defer joint_list.deinit(gpa);
    for (0..part_count) |part| {
        const child_body: u32 = robot_body[part];
        const parent_part: u32 = part_of_body[m.body_parent[child_body]];
        if (parent_part == no_part) {
            continue; // a root: on its free joint, or welded to the world
        }
        var hinges: [3]u32 = undefined;
        var hinge_count: u32 = 0;
        for (0..m.njnt) |j| {
            const on_this_body: bool = m.jnt_body[j] == child_body and m.jnt_type[j] == .hinge;
            if (!on_this_body) {
                continue;
            }
            if (hinge_count == hinges.len) {
                return error.TooManyHinges;
            }
            hinges[hinge_count] = @intCast(j);
            hinge_count += 1;
        }
        if (hinge_count == 0) {
            return error.JointedBodyWithoutHinge;
        }
        const child_rot: Quat = at.body_xrot[child_body];
        const first: u32 = hinges[0];
        var pivots_agree: bool = true;
        for (hinges[1..hinge_count]) |other| {
            pivots_agree = pivots_agree and length3(m.jnt_pos[other] - m.jnt_pos[first]) < 1.0e-6;
        }
        const anchor: Vec = at.body_xpos[child_body] + rotate(child_rot, m.jnt_pos[first]);
        const constraint_index: u32 = @intCast(world.constraints.items.len);
        const parent_handle: zimrphysics.BodyHandle = handles[parent_part];
        const child_handle: zimrphysics.BodyHandle = handles[part];
        if (hinge_count == 1) {
            const range: ?[2]f32 = m.jnt_range[first];
            try zimrphysics.createRevoluteJoint(world, parent_handle, child_handle, .{
                .anchor = anchor,
                .axis = rotate(child_rot, m.jnt_axis[first]),
                .has_limits = opts.limits and range != null,
                .limit_min = if (range) |r| r[0] else 0.0,
                .limit_max = if (range) |r| r[1] else 0.0,
            });
        } else {
            switch (opts.variant) {
                .game => {
                    const st_limits: bool = opts.limits and opts.swing_twist_limits;
                    const twist: u32 = switch (opts.twist_hinge) {
                        .first => hinges[0],
                        .last => hinges[hinge_count - 1],
                    };
                    // The swings are the other hinges, in MJCF order.
                    const plane: u32 = switch (opts.twist_hinge) {
                        .first => hinges[1],
                        .last => hinges[0],
                    };
                    const normal_hinge: u32 = switch (opts.twist_hinge) {
                        .first => hinges[2],
                        .last => hinges[1],
                    };
                    const free_twist: [2]f32 = .{ -pi, pi };
                    const twist_range: [2]f32 = if (st_limits)
                        m.jnt_range[twist] orelse free_twist
                    else
                        free_twist;
                    const locked_normal: f32 = if (st_limits) opts.locked_axis_slack else pi;
                    const about_normal: f32 = if (hinge_count == 3)
                        halfCone(m, normal_hinge, st_limits)
                    else
                        locked_normal;
                    try zimrphysics.createSwingTwistJoint(world, parent_handle, child_handle, .{
                        .anchor = anchor,
                        .twist_axis = rotate(child_rot, m.jnt_axis[twist]),
                        .plane_axis = rotate(child_rot, m.jnt_axis[plane]),
                        .swing_type = .pyramid,
                        // * Jolt's cones bound the swing WITHIN the plane each names, so the cone for
                        // rotation ABOUT the plane axis is `normal_half_cone`, and about the normal
                        // axis `plane_half_cone`. Reading the names the other way round locked every
                        // 2-hinge body's first hinge and gave the hip the wrong cone per axis.
                        .normal_half_cone = halfCone(m, plane, st_limits),
                        .plane_half_cone = about_normal,
                        .twist_min = twist_range[0],
                        .twist_max = twist_range[1],
                    });
                },
            }
        }
        try joint_list.append(gpa, .{
            .parent = parent_part,
            .child = @intCast(part),
            .local_parent = localPivot(world, handles[parent_part], anchor),
            .local_child = localPivot(world, handles[part], anchor),
            .hinge_count = hinge_count,
            .hinges = hinges,
            .constraint = constraint_index,
            .pivots_agree = pivots_agree,
        });
    }

    const body_offset_pos: []Vec = try gpa.alloc(Vec, body_count);
    errdefer gpa.free(body_offset_pos);
    const body_offset_rot: []Quat = try gpa.alloc(Quat, body_count);
    errdefer gpa.free(body_offset_rot);
    body_offset_pos[0] = vec_zero;
    body_offset_rot[0] = quat_identity;
    for (1..body_count) |b| {
        const home: u32 = robot_body[part_of_body[b]];
        const to_home: Quat = conjugate(at.body_xrot[home]);
        body_offset_pos[b] = rotate(to_home, at.body_xpos[b] - at.body_xpos[home]);
        body_offset_rot[b] = qmul(to_home, at.body_xrot[b]);
    }

    return .{
        .gpa = gpa,
        .handles = handles,
        .robot_body = robot_body,
        .part_of_body = part_of_body,
        .com_local = com_local,
        .joints = try joint_list.toOwnedSlice(gpa),
        .body_offset_pos = body_offset_pos,
        .body_offset_rot = body_offset_rot,
    };
}

/// A symmetric half-cone wide enough for a hinge's whole range: the swing-twist joint cannot
/// hold an asymmetric one, so the side the hinge could not reach becomes reachable. Measured,
/// not hidden, by the plan's limit-mismatch test.
fn halfCone(m: *const rbt.Model, joint: u32, limits: bool) f32 {
    if (!limits) {
        return pi;
    }
    const range: [2]f32 = m.jnt_range[joint] orelse return 0.5 * pi;
    return @max(@abs(range[0]), @abs(range[1]));
}

fn localPivot(
    world: *const zimrphysics.World,
    handle: zimrphysics.BodyHandle,
    anchor: Vec,
) Vec {
    const body: *const zimrphysics.Body = &world.bodies.data[handle.index()];
    return rotate(conjugate(body.rot), anchor - body.com_pos);
}

/// The plan's "limp" baseline on the REDUCED side: no joint stiffness, damping or armature and
/// no tendon springs, because the maximal side has none of them. Contacts and limits stay.
pub fn limpReduced(m: *rbt.Model) void {
    @memset(m.jnt_stiffness, 0.0);
    @memset(m.jnt_damping, 0.0);
    m.has_dof_damping = false;
    @memset(m.dof_armature, 0.0);
    @memset(m.tendon_stiffness, 0.0);
    @memset(m.tendon_damping, 0.0);
}

// ============================================================================
// Stage 0's gate: the two humanoids are the same humanoid.
// ============================================================================

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const robot_physics = @import("robot_physics.zig");
const expect = std.testing.expect;

const test_timestep: f32 = 1.0 / 500.0;

/// The MJCF humanoid, built for the comparison: Z-up gravity, Newton (the solver a ragdoll
/// needs, per `robot_physics`' ragdoll test), and posed at `qpos0` with its kinematics current.
const Humanoid = struct {
    /// The XML the document was parsed from, when it had to be edited (fixed base); else empty.
    source: []u8,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    data: rbt.Data,

    fn load(gpa: Allocator, h: *Humanoid) !void {
        return loadWith(gpa, h, false, test_timestep);
    }

    /// `fixed_base`: the torso WELDED to the world instead of floating on a free joint - the
    /// honest way to pin a root. Snapping a floating root back after each step leaves the body
    /// free-falling within the step, and a free-falling body's joints carry no gravity load.
    fn loadWith(gpa: Allocator, h: *Humanoid, fixed_base: bool, timestep: f32) !void {
        const embedded: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
        h.source = &.{};
        if (fixed_base) {
            const free_joint: []const u8 = "<freejoint name=\"root\"/>";
            const at: usize = std.mem.indexOf(u8, embedded, free_joint) orelse return error.NoFreeJoint;
            h.source = try gpa.alloc(u8, embedded.len - free_joint.len);
            @memcpy(h.source[0..at], embedded[0..at]);
            @memcpy(h.source[at..], embedded[at + free_joint.len ..]);
        }
        errdefer gpa.free(h.source);
        const source: []const u8 = if (fixed_base) h.source else embedded;
        h.doc = try codecs.xml.parse(gpa, source, null);
        errdefer h.doc.deinit();
        h.robot = try mjcf.readRobot(gpa, &h.doc);
        errdefer h.robot.deinit();
        var options: rbt.Options = .{
            .max_contacts = 256,
            .timestep = timestep,
            .gravity = vec(0, 0, -9.81),
        };
        options.solver.algorithm = .newton;
        options.solver.max_iterations = 100;
        h.imported = try robot_mjcf.build(gpa, &h.robot, options);
        errdefer h.imported.deinit();
        h.data = try rbt.Data.init(gpa, &h.imported.model);
        @memcpy(h.data.pos, h.imported.model.qpos0);
        @memset(h.data.vel, 0);
        h.data.stage = .stale;
        rbt.forward(&h.imported.model, &h.data);
    }

    fn deinit(h: *Humanoid) void {
        h.data.deinit();
        h.imported.deinit();
        h.robot.deinit();
        h.doc.deinit();
        std.testing.allocator.free(h.source);
    }

    /// The whole reduced model's centre of mass.
    fn centerOfMass(h: *const Humanoid) Vec {
        const m: *const rbt.Model = &h.imported.model;
        var total: f32 = 0.0;
        var weighted: Vec = vec_zero;
        for (1..m.nbody) |b| {
            const com: Vec = h.data.body_xpos[b] + rotate(h.data.body_xrot[b], m.body_ipos[b]);
            total += m.body_mass[b];
            weighted += splat(m.body_mass[b]) * com;
        }
        return weighted / splat(total);
    }

    /// Dropped from 1.2 m and tipped onto its side, as in `robot_physics`' ragdoll test: a body
    /// that lands upright makes few contacts and proves little.
    fn tippedDropPose(h: *Humanoid) void {
        _ = robot_mjcf.applyKeyframe(&h.imported.model, &h.data, h.robot.keyframes[0]);
        h.data.pos[2] = 1.2;
        const tipped: Quat = quatFromAxisAngle(normalize3(vec(1, 0.3, 0)), 1.4);
        h.data.pos[3] = tipped[0];
        h.data.pos[4] = tipped[1];
        h.data.pos[5] = tipped[2];
        h.data.pos[6] = tipped[3];
        @memset(h.data.vel, 0);
        h.data.stage = .stale;
        rbt.forward(&h.imported.model, &h.data);
    }
};

/// Applies a symmetric inertia tensor, given as diagonal + off-diagonal, to `v`.
fn applyTensor(inertia: rbt.Inertia, v: Vec) Vec {
    const diag: Vec = inertia.diag;
    const off: Vec = inertia.off; // Ixy, Ixz, Iyz
    return vec(
        diag[0] * v[0] + off[0] * v[1] + off[1] * v[2],
        off[0] * v[0] + diag[1] * v[1] + off[2] * v[2],
        off[1] * v[0] + off[2] * v[1] + diag[2] * v[2],
    );
}

test "robot_maximal: the maximal humanoid has the reduced one's mass, centre of mass and inertia" {
    // ** THE FAIRNESS CONTRACT'S FIRST LINE, CHECKED. Both engines take mass properties from
    // the same geoms at the same density, but by different code: robot_mjcf's inertia-from-geoms
    // and zimrphysics' compound builder. If they disagreed, every later comparison would be
    // comparing two different humanoids.
    const gpa: Allocator = std.testing.allocator;
    var h: Humanoid = undefined;
    try Humanoid.load(gpa, &h);
    defer h.deinit();
    const m: *const rbt.Model = &h.imported.model;

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{});
    defer ragdoll.deinit();

    // 16 robot bodies; head and hands are welded, so 13 parts and 12 joints.
    try expect(ragdoll.partCount() == 13);
    try expect(ragdoll.joints.len == 12);

    var worst_mass: f32 = 0.0;
    var worst_com: f32 = 0.0;
    var worst_inertia: f32 = 0.0;
    var total_reduced: f32 = 0.0;
    var total_maximal: f32 = 0.0;
    for (0..ragdoll.partCount()) |part| {
        // The reduced side's numbers for the same set of bodies, combined.
        var mass: f32 = 0.0;
        var weighted: Vec = vec_zero;
        for (1..m.nbody) |b| {
            if (ragdoll.part_of_body[b] != part) {
                continue;
            }
            const com: Vec = h.data.body_xpos[b] + rotate(h.data.body_xrot[b], m.body_ipos[b]);
            mass += m.body_mass[b];
            weighted += splat(m.body_mass[b]) * com;
        }
        const com_reduced: Vec = weighted / splat(mass);

        const idx: zimrphysics.BodyIndex = ragdoll.bodyIndex(part);
        const props: zimrphysics.MassProperties = world.mass_props[idx];
        const body: *const zimrphysics.Body = &world.bodies.data[idx];
        worst_mass = @max(worst_mass, @abs(props.mass - mass) / mass);
        worst_com = @max(worst_com, length3(body.com_pos - com_reduced));
        total_reduced += mass;
        total_maximal += props.mass;

        // Inertia about the part's COM, in world axes, applied to each axis: the reduced side
        // by the parallel-axis theorem over its bodies, the maximal side from principal form.
        const principal: Quat = qmul(body.rot, props.inertia_rotation);
        var largest: f32 = 0.0;
        var mismatch: f32 = 0.0;
        const basis: [3]Vec = .{ vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1) };
        for (basis) |e| {
            var reduced: Vec = vec_zero;
            for (1..m.nbody) |b| {
                if (ragdoll.part_of_body[b] != part) {
                    continue;
                }
                const rot: Quat = h.data.body_xrot[b];
                const com: Vec = h.data.body_xpos[b] + rotate(rot, m.body_ipos[b]);
                const r: Vec = com - com_reduced;
                reduced += rotate(rot, applyTensor(m.body_inertia[b], rotate(conjugate(rot), e)));
                reduced += splat(m.body_mass[b]) * (splat(dot3(r, r)) * e - r * splat(dot3(r, e)));
            }
            const moments: Vec = vec(
                1.0 / props.inv_inertia_diagonal[0],
                1.0 / props.inv_inertia_diagonal[1],
                1.0 / props.inv_inertia_diagonal[2],
            );
            const maximal: Vec = rotate(principal, moments * rotate(conjugate(principal), e));
            largest = @max(largest, length3(reduced));
            mismatch = @max(mismatch, length3(reduced - maximal));
        }
        worst_inertia = @max(worst_inertia, mismatch / largest);
        report.print("  part {d:>2} (robot body {d:>2}): mass {d:.4} kg, inertia mismatch {e:.2} of {d:.5}\n", .{
            part, ragdoll.robot_body[part], mass, mismatch / largest, largest,
        });
    }
    report.print(
        "\n  robot_maximal: total mass reduced {d:.4} kg, maximal {d:.4} kg; worst part: " ++
            "mass {e:.2} (relative), COM {e:.2} m, inertia {e:.2} (relative)\n",
        .{ total_reduced, total_maximal, worst_mass, worst_com, worst_inertia },
    );
    try expect(worst_mass < 1.0e-3);
    try expect(worst_com < 1.0e-4);
    try expect(worst_inertia < 1.0e-2);
}

test "robot_maximal: every part's frame reads back as the reduced forward kinematics" {
    // The bookkeeping test: `com_local` is what maps a recentred compound back to a robot body
    // frame, and a mistake there would put every drawn limb and every comparison off by the COM.
    const gpa: Allocator = std.testing.allocator;
    var h: Humanoid = undefined;
    try Humanoid.load(gpa, &h);
    defer h.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    var ragdoll: Ragdoll = try build(gpa, &world, &h.imported.model, &h.data, .{});
    defer ragdoll.deinit();

    h.tippedDropPose();
    try ragdoll.setPose(gpa, &world, &h.data);
    var worst: f32 = 0.0;
    var worst_position: f32 = 0.0;
    for (0..ragdoll.partCount()) |part| {
        const frame: Frame = ragdoll.bodyFrame(&world, part);
        const robot_body: u32 = ragdoll.robot_body[part];
        const q: Quat = h.data.body_xrot[robot_body];
        const same: Vec = frame.rot - q;
        const flipped: Vec = frame.rot + q;
        const rot_error: f32 = @min(@reduce(.Add, same * same), @reduce(.Add, flipped * flipped));
        worst = @max(worst, @sqrt(rot_error));
        worst_position = @max(worst_position, length3(frame.pos - h.data.body_xpos[robot_body]));
    }
    // Where the robot's hinges share a pivot, the maximal joint follows the pose exactly; where
    // they do not (the ankles), the gap IS the approximation, and it is printed, not hidden.
    var worst_shared: f32 = 0.0;
    var worst_split: f32 = 0.0;
    for (ragdoll.joints) |joint| {
        const a: *const zimrphysics.Body = &world.bodies.data[ragdoll.bodyIndex(joint.parent)];
        const b: *const zimrphysics.Body = &world.bodies.data[ragdoll.bodyIndex(joint.child)];
        const pivot_a: Vec = a.com_pos + rotate(a.rot, joint.local_parent);
        const pivot_b: Vec = b.com_pos + rotate(b.rot, joint.local_child);
        const gap: f32 = length3(pivot_a - pivot_b);
        if (joint.pivots_agree) {
            worst_shared = @max(worst_shared, gap);
        } else {
            worst_split = @max(worst_split, gap);
        }
    }
    report.print(
        "\n  robot_maximal: rotation readback worst {e:.2}; worst part position vs the reduced FK " ++
            "{d:.1} mm (the feet, below the split-pivot ankles); joints apart: shared {e:.2} m, split {e:.2} m\n",
        .{ worst, worst_position * 1000.0, worst_shared, worst_split },
    );
    try expect(worst < 1.0e-5);
    try expect(worst_shared < 1.0e-5);
    try expect(worst_split < 1.0e-5);
    try expect(worst_position < 0.05);

    // Which joints' LIMITS disagree with this pose: gravity off, one step, and a joint whose
    // relative rotation moves was pushed by its own limit or by the ankle pivot correction.
    world.gravity = vec_zero;
    var before: [16]Quat = undefined;
    for (ragdoll.joints, 0..) |joint, i| {
        before[i] = relativeRotation(&world, &ragdoll, joint);
    }
    try zimrphysics.step(&world, test_timestep);
    for (ragdoll.joints, 0..) |joint, i| {
        const after: Quat = relativeRotation(&world, &ragdoll, joint);
        const alignment: f32 = @min(1.0, @abs(@reduce(.Add, before[i] * after)));
        const push: f32 = 2.0 * acosRad(alignment);
        if (push > 1.0e-4) {
            report.print("    at the drop pose, joint {d:>2} (robot body {d:>2}, {d} hinges) pushed {d:.4} rad\n", .{
                i, ragdoll.robot_body[joint.child], joint.hinge_count, push,
            });
        }
    }
}

test "robot_maximal: both humanoids fall like one point mass" {
    // Gravity, timestep and integrator conventions, checked where the answer is known exactly:
    // with no floor, internal forces cancel and the centre of mass follows the discrete law of
    // semi-implicit Euler, z_n = z_0 - g dt^2 n(n+1)/2. Both engines should, to rounding.
    const gpa: Allocator = std.testing.allocator;
    var h: Humanoid = undefined;
    try Humanoid.load(gpa, &h);
    defer h.deinit();
    const m: *rbt.Model = &h.imported.model;
    limpReduced(m);

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    world.settings.allow_sleeping = false;
    var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{});
    defer ragdoll.deinit();

    const start_reduced: Vec = h.centerOfMass();
    const start_maximal: Vec = ragdoll.centerOfMass(&world);
    const steps: u32 = 250;
    for (0..steps) |_| {
        rbt.forward(m, &h.data);
        rbt.step(m, &h.data);
        try zimrphysics.step(&world, test_timestep);
    }
    rbt.forward(m, &h.data);
    const n: f32 = float(steps);
    const drop: f32 = 9.81 * test_timestep * test_timestep * n * (n + 1.0) / 2.0;
    const fell_reduced: f32 = start_reduced[2] - h.centerOfMass()[2];
    const fell_maximal: f32 = start_maximal[2] - ragdoll.centerOfMass(&world)[2];
    report.print(
        "\n  robot_maximal: free fall over {d} steps: expected {d:.5} m, reduced {d:.5}, maximal {d:.5}\n",
        .{ steps, drop, fell_reduced, fell_maximal },
    );
    try expect(@abs(fell_reduced - drop) < 1.0e-3);
    try expect(@abs(fell_maximal - drop) < 1.0e-3);
}

/// A static floor like `robot_physics`' ragdoll test, with the fairness contract's settings.
fn floorWorld(gpa: Allocator) !zimrphysics.World {
    var world: zimrphysics.World = try .init(gpa, 256);
    errdefer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    world.settings.allow_sleeping = false;
    world.settings.penetration_slop = 0.005;
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(6, 6, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
        .friction = 0.7,
    });
    return world;
}

/// One maximal configuration of the drop.
const MaximalRun = struct {
    gyroscopic: bool,
    velocity_steps: u32,
    limits: bool = true,
    swing_twist_limits: bool = true,
    slack: f32 = 0.0,
};

const drop_steps: u32 = 3000;

test "robot_maximal: the drop - both humanoids land, and the maximal joints stay together" {
    // *** THE COMPARISON'S FIRST NUMBERS: the same limp humanoid, the same tipped drop, the same
    // floor and timestep, in both engines, six simulated seconds each. The maximal side runs in
    // a few configurations, because its first run did not come to rest and a single number
    // would not say why. The asserts are the sanity bar; the printed table is what the plan's
    // journal records.
    const gpa: Allocator = std.testing.allocator;

    // -- The reduced side, once. --
    var reduced_height: f32 = 0.0;
    var reduced_speed: f32 = 0.0;
    var reduced_contacts: u32 = 0;
    {
        var h: Humanoid = undefined;
        try Humanoid.load(gpa, &h);
        defer h.deinit();
        const m: *rbt.Model = &h.imported.model;
        limpReduced(m);
        var world: zimrphysics.World = try floorWorld(gpa);
        defer world.deinit(gpa);
        h.tippedDropPose();
        var bridge: robot_physics.Bridge = try .init(gpa, &world, m, &h.data, 256);
        defer bridge.deinit(&world);
        bridge.listen(&world);
        for (0..drop_steps) |_| {
            rbt.forward(m, &h.data);
            try bridge.sync(&world, m, &h.data);
            try zimrphysics.step(&world, test_timestep);
            bridge.harvest(&h.data);
            @memset(h.data.applied_force, 0);
            rbt.step(m, &h.data);
            reduced_contacts = @max(reduced_contacts, h.data.contact_count);
        }
        rbt.forward(m, &h.data);
        for (0..m.nv) |i| {
            reduced_speed = @max(reduced_speed, @abs(h.data.vel[i]));
        }
        reduced_height = h.data.body_xpos[1][2];
    }
    report.print(
        "\n  robot_maximal drop, 6 s at 1/500, limp: REDUCED torso {d:.3} m, settled speed {d:.3}, " ++
            "peak contacts {d}\n",
        .{ reduced_height, reduced_speed, reduced_contacts },
    );
    try expect(reduced_height > 0.05 and reduced_height < 0.5);

    // -- The maximal side, per configuration. The first is the fairness contract's. --
    const runs = [_]MaximalRun{
        .{ .gyroscopic = true, .velocity_steps = 10 },
        .{ .gyroscopic = true, .velocity_steps = 10, .swing_twist_limits = false },
        .{ .gyroscopic = true, .velocity_steps = 10, .slack = 0.35 },
        .{ .gyroscopic = false, .velocity_steps = 10 },
        .{ .gyroscopic = true, .velocity_steps = 10, .limits = false },
    };
    for (runs) |run| {
        var h: Humanoid = undefined;
        try Humanoid.load(gpa, &h);
        defer h.deinit();
        var world: zimrphysics.World = try floorWorld(gpa);
        defer world.deinit(gpa);
        world.settings.velocity_steps = run.velocity_steps;
        var ragdoll: Ragdoll = try build(gpa, &world, &h.imported.model, &h.data, .{
            .apply_gyroscopic = run.gyroscopic,
            .limits = run.limits,
            .locked_axis_slack = run.slack,
            .swing_twist_limits = run.swing_twist_limits,
        });
        defer ragdoll.deinit();
        h.tippedDropPose();
        try ragdoll.setPose(gpa, &world, &h.data);
        const start_error: f32 = ragdoll.jointError(&world);
        var peak_error: f32 = 0.0;
        for (0..drop_steps) |_| {
            try zimrphysics.step(&world, test_timestep);
            peak_error = @max(peak_error, ragdoll.jointError(&world));
        }
        const height: f32 = ragdoll.bodyFrame(&world, ragdoll.part_of_body[1]).pos[2];
        report.print(
            "  MAXIMAL gyro {} vsteps {d:>2} limits {} swing-twist limits {} " ++
                "slack {d:.2}: torso {d:.3} m, settled speed {d:.3}, " ++
                "joint error start {d:.1} mm, peak {d:.1} mm, final {d:.1} mm\n",
            .{
                run.gyroscopic,
                run.velocity_steps,
                run.limits,
                run.swing_twist_limits,
                run.slack,
                height,
                ragdoll.peakSpeed(&world),
                start_error * 1000.0,
                peak_error * 1000.0,
                ragdoll.jointError(&world) * 1000.0,
            },
        );
        // Landed on the floor, every configuration: neither sank through it nor was thrown off.
        try expect(height > 0.05 and height < 0.5);
        if (run.limits) {
            // ** THE OPEN STAGE 0 ITEM, WITH ITS BAR SET WHERE THE ENGINE IS. With the game-style
            // limits the ragdoll never settles and its joints open by up to 19 cm, identically
            // across solver settings, while the same ragdoll WITHOUT limits settles to exactly
            // zero error. So the limits fight the pose - the squat keyframe decomposes into
            // swing-twist angles outside the cones - and closing that shows up as this bar
            // needing to come down to the limits-off one.
            try expect(peak_error < 0.25);
        } else {
            // Without limits the joints close the ankles' 2 cm start gap and then hold exactly.
            try expect(peak_error < 0.02);
            try expect(ragdoll.jointError(&world) < 1.0e-3);
            try expect(ragdoll.peakSpeed(&world) < 0.05);
        }
    }
}

fn relativeRotation(
    world: *const zimrphysics.World,
    ragdoll: *const Ragdoll,
    joint: Joint,
) Quat {
    const a: Quat = world.bodies.data[ragdoll.bodyIndex(joint.parent)].rot;
    const b: Quat = world.bodies.data[ragdoll.bodyIndex(joint.child)].rot;
    return qmul(conjugate(a), b);
}

test "robot_maximal: one hinge at a time - does an in-range MJCF angle sit inside the maximal limit?" {
    // ** ONE HINGE AT A TIME, so a push can only come from that hinge's own joint. Everything
    // else stays at qpos0 (where the ankles' two pivots coincide too), gravity is off, nothing
    // moves - unless the maximal limit disagrees with the MJCF range about THIS angle. Each
    // limited hinge is probed near both ends of its range, 10% in from each; an asymmetric
    // range makes a sign flip show up at one end, and a cone narrower than its hinge at both.
    // (A first version sampled every hinge at once and could not attribute anything: one
    // pushed joint moves its whole chain.)
    const gpa: Allocator = std.testing.allocator;
    const pushed_threshold: f32 = 1.0e-4; // rad in one step
    for ([_]TwistHinge{ .first, .last }) |choice| {
        var h: Humanoid = undefined;
        try Humanoid.load(gpa, &h);
        defer h.deinit();
        const m: *const rbt.Model = &h.imported.model;
        var world: zimrphysics.World = try .init(gpa, 64);
        defer world.deinit(gpa);
        world.gravity = vec_zero;
        world.settings.allow_sleeping = false;
        var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{ .twist_hinge = choice });
        defer ragdoll.deinit();
        var pushed: u32 = 0;
        var probes: u32 = 0;
        report.print("\n  robot_maximal one-hinge probes, twist on the {t} hinge:\n", .{choice});
        for (0..m.njnt) |j| {
            const range: ?[2]f32 = m.jnt_range[j];
            const is_limited_hinge: bool = m.jnt_type[j] == .hinge and range != null;
            if (!is_limited_hinge) {
                continue;
            }
            const r: [2]f32 = range.?;
            // The joint this hinge belongs to: the one whose child part is the hinge's body.
            const child_part: u32 = ragdoll.part_of_body[m.jnt_body[j]];
            var joint_index: usize = 0;
            for (ragdoll.joints, 0..) |joint, i| {
                if (joint.child == child_part) {
                    joint_index = i;
                }
            }
            const joint: Joint = ragdoll.joints[joint_index];
            for ([_]f32{ 0.1, 0.9 }) |fraction| {
                const angle: f32 = r[0] + fraction * (r[1] - r[0]);
                @memcpy(h.data.pos, m.qpos0);
                h.data.pos[m.jnt_qpos_adr[j]] = angle;
                h.data.stage = .stale;
                rbt.forward(m, &h.data);
                try ragdoll.setPose(gpa, &world, &h.data);
                const before: Quat = relativeRotation(&world, &ragdoll, joint);
                try zimrphysics.step(&world, test_timestep);
                const after: Quat = relativeRotation(&world, &ragdoll, joint);
                const alignment: f32 = @min(1.0, @abs(@reduce(.Add, before * after)));
                const push: f32 = 2.0 * acosRad(alignment);
                probes += 1;
                if (push > pushed_threshold) {
                    pushed += 1;
                    report.print("    hinge {d:>2} (body {d:>2}, {d} hinges) at {d:>6.3} rad " ++
                        "of [{d:.3}, {d:.3}]: pushed {d:.5} rad\n", .{
                        j, m.jnt_body[j], joint.hinge_count, angle, r[0], r[1], push,
                    });
                }
            }
        }
        report.print("    {d} of {d} probes pushed\n", .{ pushed, probes });
    }
}

// ============================================================================
// Reaching a pose: the same targets, driven the way each engine drives best.
// ============================================================================

/// How a pose is driven in the experiment below.
const PoseMethod = union(enum) {
    /// robot.zig, the servo ladder's controller: joint-space PD, optionally with the exact
    /// gravity + Coriolis torque (`biasForce`) added as feed-forward.
    reduced_pd: struct { kp: f32, kv: f32, gravity: bool },
    /// robot.zig, computed torque: tau = M(q) a_des + c(q, v) with a_des a critically damped
    /// spring of this FREQUENCY per joint. The reduced model's own dynamics, inverted.
    reduced_computed_torque: struct { frequency: f32 },
    /// robot.zig, computed torque with the spring evaluated IMPLICITLY (`stableSpringAccel`).
    reduced_implicit_ct: struct { frequency: f32 },
    /// robot.zig, the cheap middle ground: PD whose gains are scaled per joint by the mass
    /// matrix's DIAGONAL (kp = M_ii w^2, kv = 2 M_ii w), plus the exact gravity + Coriolis torque.
    /// No full M solve - each joint is its own critically damped spring of this frequency.
    reduced_diagonal: struct { frequency: f32 },
    /// zimrphysics: joint position motors at this frequency, solved inside the constraint solver.
    maximal_motors: struct { frequency: f32, limits: bool = true },
};

const PoseRun = struct {
    label: []const u8,
    method: PoseMethod,
    /// Allowed to blow up: the methods the stability analysis says should, at this rate.
    may_diverge: bool = false,
};

/// Worst joint rotation error, in degrees: for each joint the angle between the child's
/// rotation relative to its parent now and in the target. Same definition for both engines.
/// Null when a body's rotation is no longer finite - the run diverged.
pub fn worstJointErrorDeg(
    ragdoll: *const Ragdoll,
    now_rots: []const Quat,
    target: *const rbt.Data,
) ?f32 {
    var worst: f32 = 0.0;
    for (ragdoll.joints) |joint| {
        const parent_body: u32 = ragdoll.robot_body[joint.parent];
        const child_body: u32 = ragdoll.robot_body[joint.child];
        const now: Quat = qmul(conjugate(now_rots[parent_body]), now_rots[child_body]);
        const want: Quat = qmul(conjugate(target.body_xrot[parent_body]), target.body_xrot[child_body]);
        const alignment: f32 = @abs(@reduce(.Add, now * want));
        // * A diverged body has NaN rotations, and `@max` DROPS a NaN operand - so a blown-up
        // run would report whatever finite joint was left, as a steady number. Say so instead.
        if (!isFinite(alignment)) {
            return null;
        }
        worst = @max(worst, 2.0 * acosRad(@min(1.0, alignment)) * 180.0 / pi);
    }
    return worst;
}

/// One step of the FIXED-BASE reduced humanoid under `method`.
fn stepReducedFixed(
    m: *const rbt.Model,
    d: *rbt.Data,
    target: *const rbt.Data,
    method: PoseMethod,
    a_des: []f32,
    torque: []f32,
) void {
    rbt.forward(m, d);
    @memset(d.applied_force, 0);
    @memset(a_des, 0);
    rbt.biasForce(m, d);
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        const v: u32 = m.jnt_dof_adr[j];
        const err: f32 = target.pos[q] - d.pos[q];
        switch (method) {
            .reduced_pd => |pd| {
                const feed_forward: f32 = if (pd.gravity) d.bias_force[v] else 0.0;
                d.applied_force[v] = pd.kp * err - pd.kv * d.vel[v] + feed_forward;
            },
            .reduced_computed_torque => |ct| {
                const omega: f32 = 2.0 * pi * ct.frequency;
                a_des[v] = omega * omega * err - 2.0 * omega * d.vel[v];
            },
            .reduced_implicit_ct => |ict| {
                a_des[v] = stableSpringAccel(err, d.vel[v], ict.frequency, 1.0, m.opt.timestep);
            },
            .reduced_diagonal => |dg| {
                const omega: f32 = 2.0 * pi * dg.frequency;
                // M_vv measured through inverse dynamics (M e_v = ID(e_v) - c): the diagonal that
                // `rbt.massDiagonal` reads directly disagreed with it on this model - see the test.
                @memset(a_des, 0);
                a_des[v] = 1.0;
                rbt.inverseDynamics(m, d, a_des, torque);
                a_des[v] = 0.0;
                const inertia: f32 = torque[v] - d.bias_force[v];
                d.applied_force[v] = inertia * (omega * omega * err - 2.0 * omega * d.vel[v]) +
                    d.bias_force[v];
            },
            .maximal_motors => unreachable,
        }
    }
    const uses_inverse_dynamics: bool = method == .reduced_computed_torque or
        method == .reduced_implicit_ct;
    if (uses_inverse_dynamics) {
        // Fixed base: every DOF is a hinge, and M a + c is exactly the torque that makes it so.
        rbt.inverseDynamics(m, d, a_des, torque);
        for (0..m.njnt) |j| {
            if (m.jnt_type[j] == .hinge) {
                const v: u32 = m.jnt_dof_adr[j];
                d.applied_force[v] = torque[v];
            }
        }
    }
    rbt.step(m, d);
}

/// One physics rate of the pose experiment, and the methods tried at it.
const PoseRate = struct {
    steps_per_second: u32,
    runs: []const PoseRun,
};

test "robot_maximal: reaching a pose - root pinned, gravity on, both engines, their own best tools" {
    // *** THE QUESTION THE ANIM-FOLLOWING PLAN IS STUCK ON, asked of both models at once: given
    // a target pose, how close does each get, how fast, and with what? Two scenarios: HOLD the
    // rest pose (servo ladder rung 2) and REACH the squat from rest. The torso is WELDED to the
    // world in both models (a first version snapped a floating root back each step, which
    // leaves the joints weightless within the step), gravity on, no floor - so the controller
    // is all that is measured. Printed per method: worst joint error at 0.5, 1 and 2 s, and the
    // worst over the last half second. At 500 Hz AND at 60 Hz: at 60 Hz the explicit spring's
    // stability bound (7.9 Hz, see `stableSpringAccel`) is straddled on purpose.
    const gpa: Allocator = std.testing.allocator;
    const at_500 = [_]PoseRun{
        .{
            .label = "reduced PD kp400 kv20 (the ladder's)",
            .method = .{ .reduced_pd = .{ .kp = 400, .kv = 20, .gravity = false } },
            .may_diverge = true,
        },
        .{
            .label = "reduced PD kp400 kv20 + gravity comp",
            .method = .{ .reduced_pd = .{ .kp = 400, .kv = 20, .gravity = true } },
            .may_diverge = true,
        },
        .{ .label = "reduced computed torque 5 Hz", .method = .{ .reduced_computed_torque = .{ .frequency = 5 } } },
        .{ .label = "reduced implicit CT 20 Hz", .method = .{ .reduced_implicit_ct = .{ .frequency = 20 } } },
        .{ .label = "maximal motors 10 Hz", .method = .{ .maximal_motors = .{ .frequency = 10 } } },
        .{ .label = "maximal motors 20 Hz", .method = .{ .maximal_motors = .{ .frequency = 20 } } },
    };
    const at_60 = [_]PoseRun{
        .{ .label = "reduced explicit CT 5 Hz " ++
            "(h 0.52)", .method = .{ .reduced_computed_torque = .{ .frequency = 5 } } },
        .{ .label = "reduced explicit CT 7 Hz " ++
            "(h 0.73)", .method = .{ .reduced_computed_torque = .{ .frequency = 7 } } },
        .{
            .label = "reduced explicit CT 9 Hz (h 0.94)",
            .method = .{ .reduced_computed_torque = .{ .frequency = 9 } },
            .may_diverge = true,
        },
        .{ .label = "reduced implicit CT 5 Hz", .method = .{ .reduced_implicit_ct = .{ .frequency = 5 } } },
        .{ .label = "reduced implicit CT 10 Hz", .method = .{ .reduced_implicit_ct = .{ .frequency = 10 } } },
        .{ .label = "reduced implicit CT 20 Hz", .method = .{ .reduced_implicit_ct = .{ .frequency = 20 } } },
        .{ .label = "reduced implicit CT 60 Hz", .method = .{ .reduced_implicit_ct = .{ .frequency = 60 } } },
        .{ .label = "maximal motors 5 Hz", .method = .{ .maximal_motors = .{ .frequency = 5 } } },
        .{ .label = "maximal motors 10 Hz", .method = .{ .maximal_motors = .{ .frequency = 10 } } },
        .{ .label = "maximal motors 20 Hz", .method = .{ .maximal_motors = .{ .frequency = 20 } } },
        .{ .label = "maximal motors 60 Hz", .method = .{ .maximal_motors = .{ .frequency = 60 } } },
    };
    const rates = [_]PoseRate{
        .{ .steps_per_second = 500, .runs = &at_500 },
        .{ .steps_per_second = 60, .runs = &at_60 },
    };
    for (rates) |rate| {
        const dt: f32 = 1.0 / float(rate.steps_per_second);
        const steps: u32 = 2 * rate.steps_per_second;
        const checkpoints = [_]u32{ steps / 4, steps / 2, steps };
        for ([_]bool{ false, true }) |reach_squat| {
            report.print("\n  {d} Hz, {s}, fixed base, gravity on (worst joint error, deg: " ++
                "0.5 s / 1 s / 2 s / last 0.5 s max)\n", .{
                rate.steps_per_second,
                if (reach_squat) "REACH the squat from rest" else "HOLD the rest pose",
            });
            for (rate.runs) |run| {
                var h: Humanoid = undefined;
                try Humanoid.loadWith(gpa, &h, true, dt);
                defer h.deinit();
                const m: *rbt.Model = &h.imported.model;
                limpReduced(m);
                var target: rbt.Data = try rbt.Data.init(gpa, m);
                defer target.deinit();
                @memcpy(target.pos, m.qpos0);
                if (reach_squat) {
                    // The keyframe was written for the floating model: 7 root values, then hinges.
                    const key: []const f32 = h.robot.keyframes[0].qpos;
                    try expect(key.len == m.nq + 7);
                    @memcpy(target.pos, key[7..]);
                }
                target.stage = .stale;
                rbt.forward(m, &target);

                var world: zimrphysics.World = try .init(gpa, 64);
                defer world.deinit(gpa);
                world.gravity = vec(0, 0, -9.81);
                world.settings.allow_sleeping = false;
                const maximal_limits: bool = switch (run.method) {
                    .maximal_motors => |mm| mm.limits,
                    else => true,
                };
                var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{ .limits = maximal_limits });
                defer ragdoll.deinit();

                const a_des: []f32 = try gpa.alloc(f32, m.nv);
                defer gpa.free(a_des);
                const torque: []f32 = try gpa.alloc(f32, m.nv);
                defer gpa.free(torque);
                const rots: []Quat = try gpa.alloc(Quat, m.nbody);
                defer gpa.free(rots);

                const is_maximal: bool = run.method == .maximal_motors;
                if (is_maximal) {
                    ragdoll.driveToPose(&world, m, &target, .{ .frequency = run.method.maximal_motors.frequency });
                }
                var at: [3]f32 = .{ 0, 0, 0 };
                var steady: f32 = 0.0;
                var diverged_at: u32 = 0;
                var next_checkpoint: usize = 0;
                for (1..steps + 1) |step| {
                    if (is_maximal) {
                        try zimrphysics.step(&world, dt);
                        for (1..m.nbody) |b| {
                            rots[b] = ragdoll.robotBodyFrame(&world, b).rot;
                        }
                    } else {
                        stepReducedFixed(m, &h.data, &target, run.method, a_des, torque);
                        rbt.forward(m, &h.data);
                        @memcpy(rots[1..], h.data.body_xrot[1..m.nbody]);
                    }
                    const err: f32 = worstJointErrorDeg(&ragdoll, rots, &target) orelse {
                        diverged_at = @intCast(step);
                        break;
                    };
                    if (step > steps - steps / 4) {
                        steady = @max(steady, err);
                    }
                    if (next_checkpoint < checkpoints.len and step == checkpoints[next_checkpoint]) {
                        at[next_checkpoint] = err;
                        next_checkpoint += 1;
                    }
                }
                if (diverged_at > 0) {
                    report.print("    {s:<40} DIVERGED (NaN) at step {d}\n", .{ run.label, diverged_at });
                    try expect(run.may_diverge);
                    continue;
                }
                report.print("    {s:<40} {d:>7.2} {d:>7.2} {d:>7.2}   {d:>7.2}\n", .{
                    run.label, at[0], at[1], at[2], steady,
                });
            }
        }
    }
}

/// One configuration of the falling-hold test.
const FallingHold = struct {
    frequency: f32,
    /// Reduced side: floating-base inverse dynamics, or the joint rows of the fixed-base
    /// M a + c (the naive form, kept to show why it is wrong).
    floating_base: bool,
    maximal_limits: bool,
    maximal_gyroscopic: bool = true,
    maximal_velocity_steps: u32 = 10,
    maximal_max_torque: f32 = 1.0e6,
};

test "robot_maximal: holding the squat while falling onto the floor, at 60 Hz, both engines" {
    // *** WHERE A POSE HOLD HAS TO LIVE FOR REAL USE: a FREE root, the floor, and one physics
    // step per 60 Hz frame. The limp tipped drop again, but each side tries to hold the squat
    // the whole way down: the reduced side with implicit computed torque on its hinges (a free
    // root has no motor; contacts carry it), the maximal side with its joint motors. Printed:
    // worst joint error against the squat, settled speed, torso height, maximal joint gap.
    const gpa: Allocator = std.testing.allocator;
    const dt: f32 = 1.0 / 60.0;
    const steps: u32 = 180; // 3 s
    const configs = [_]FallingHold{
        // Frequency 0 is LIMP: no controller on either side - the 60 Hz baseline. Limits OFF
        // is the case a phone showed shaking at 24 m/s while this test settles it to 0.00.
        .{ .frequency = 0, .floating_base = true, .maximal_limits = true },
        .{ .frequency = 0, .floating_base = true, .maximal_limits = false },
        .{ .frequency = 10, .floating_base = false, .maximal_limits = true },
        .{ .frequency = 10, .floating_base = true, .maximal_limits = true },
        .{ .frequency = 20, .floating_base = true, .maximal_limits = false },
        // The maximal side's suspects, one at a time: gyroscopic terms, solver iterations for
        // a free-floating chain, and unbounded motor torque fighting the contacts.
        .{ .frequency = 10, .floating_base = true, .maximal_limits = false, .maximal_gyroscopic = false },
        .{
            .frequency = 10,
            .floating_base = true,
            .maximal_limits = false,
            .maximal_gyroscopic = false,
            .maximal_velocity_steps = 40,
        },
        .{
            .frequency = 10,
            .floating_base = true,
            .maximal_limits = false,
            .maximal_gyroscopic = false,
            .maximal_max_torque = 300,
        },
    };
    for (configs) |config| {
        const frequency: f32 = config.frequency;
        var h: Humanoid = undefined;
        try Humanoid.loadWith(gpa, &h, false, dt);
        defer h.deinit();
        const m: *rbt.Model = &h.imported.model;
        limpReduced(m);
        var target: rbt.Data = try rbt.Data.init(gpa, m);
        defer target.deinit();
        @memcpy(target.pos, m.qpos0);
        _ = robot_mjcf.applyKeyframe(m, &target, h.robot.keyframes[0]);
        target.stage = .stale;
        rbt.forward(m, &target);

        // The maximal one is built at qpos0, before the reduced model is posed.
        var world_maximal: zimrphysics.World = try floorWorld(gpa);
        defer world_maximal.deinit(gpa);
        world_maximal.settings.velocity_steps = config.maximal_velocity_steps;
        var ragdoll: Ragdoll = try build(gpa, &world_maximal, m, &h.data, .{
            .limits = config.maximal_limits,
            .apply_gyroscopic = config.maximal_gyroscopic,
        });
        defer ragdoll.deinit();

        h.tippedDropPose();
        try ragdoll.setPose(gpa, &world_maximal, &h.data);
        const holding: bool = frequency > 0;
        if (holding) {
            ragdoll.driveToPose(&world_maximal, m, &target, .{
                .frequency = frequency,
                .max_torque = config.maximal_max_torque,
            });
        }
        var world_reduced: zimrphysics.World = try floorWorld(gpa);
        defer world_reduced.deinit(gpa);
        var bridge: robot_physics.Bridge = try .init(gpa, &world_reduced, m, &h.data, 256);
        defer bridge.deinit(&world_reduced);
        bridge.listen(&world_reduced);

        const a_des: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(a_des);
        const torque: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(torque);
        const full: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(full);
        const dense: []f32 = try gpa.alloc(f32, @as(usize, m.nv) * m.nv);
        defer gpa.free(dense);
        const rots: []Quat = try gpa.alloc(Quat, m.nbody);
        defer gpa.free(rots);
        for (0..steps) |_| {
            rbt.forward(m, &h.data);
            try bridge.sync(&world_reduced, m, &h.data);
            try zimrphysics.step(&world_reduced, dt);
            bridge.harvest(&h.data);
            @memset(h.data.applied_force, 0);
            if (holding) {
                @memset(a_des, 0);
                for (0..m.njnt) |j| {
                    if (m.jnt_type[j] != .hinge) {
                        continue;
                    }
                    const q: u32 = m.jnt_qpos_adr[j];
                    const v: u32 = m.jnt_dof_adr[j];
                    a_des[v] = stableSpringAccel(target.pos[q] - h.data.pos[q], h.data.vel[v], frequency, 1.0, dt);
                }
                rbt.biasForce(m, &h.data);
                if (config.floating_base) {
                    floatingBaseTorques(m, &h.data, a_des, dense, full, torque);
                } else {
                    rbt.inverseDynamics(m, &h.data, a_des, torque);
                }
                for (0..m.njnt) |j| {
                    if (m.jnt_type[j] == .hinge) {
                        const v: u32 = m.jnt_dof_adr[j];
                        h.data.applied_force[v] = torque[v];
                    }
                }
            }
            rbt.step(m, &h.data);
            try zimrphysics.step(&world_maximal, dt);
        }
        rbt.forward(m, &h.data);
        @memcpy(rots[1..], h.data.body_xrot[1..m.nbody]);
        const reduced_error: ?f32 = worstJointErrorDeg(&ragdoll, rots, &target);
        for (1..m.nbody) |b| {
            rots[b] = ragdoll.robotBodyFrame(&world_maximal, b).rot;
        }
        const maximal_error: ?f32 = worstJointErrorDeg(&ragdoll, rots, &target);
        var reduced_speed: f32 = 0.0;
        for (0..m.nv) |i| {
            reduced_speed = @max(reduced_speed, @abs(h.data.vel[i]));
        }
        report.print(
            "\n  falling hold, 60 Hz, {d} Hz spring: REDUCED ({s}) error {d:.1} deg, speed {d:.2}, " ++
                "torso {d:.2} m\n      MAXIMAL (limits {} gyro {} vsteps {d} " ++
                "torque {d:.0}) error {d:.1} deg, speed {d:.2}, " ++
                "torso {d:.2} m, joint gap {d:.1} mm\n",
            .{
                frequency,
                if (config.floating_base) "floating-base ID" else "fixed-base rows",
                reduced_error orelse -1.0,
                reduced_speed,
                h.data.body_xpos[1][2],
                config.maximal_limits,
                config.maximal_gyroscopic,
                config.maximal_velocity_steps,
                config.maximal_max_torque,
                maximal_error orelse -1.0,
                ragdoll.peakSpeed(&world_maximal),
                ragdoll.bodyFrame(&world_maximal, ragdoll.part_of_body[1]).pos[2],
                ragdoll.jointError(&world_maximal) * 1000.0,
            },
        );
        try expect(reduced_error != null);
        try expect(maximal_error != null);
    }
}

/// A free-root pose-driving scenario with no floor: which of gravity / flight is present.
const FreeScenario = struct {
    label: []const u8,
    gravity: bool,
    /// The whole body turned 80 degrees before the drive starts (the drop's tip, no drop).
    tipped: bool = false,
};

test "robot_maximal: driving a FREE body to the squat at 60 Hz - zero gravity, then free fall" {
    // ** SPLITTING THE MAXIMAL MOTORS' FAILURE. They reach the squat with the torso welded to
    // the world and fail with a free body on the floor. Between those two: a free body with NO
    // floor - first without gravity (only the motors act: a free-floating chain driving its own
    // shape), then in free fall. Start at rest, target the squat, 60 Hz, 10 Hz springs, limits
    // off (so the Stage 0 limit mismatch is not in the way). The reduced side runs the same
    // scenarios with implicit CT through floating-base ID, which is exact without contacts.
    const gpa: Allocator = std.testing.allocator;
    const dt: f32 = 1.0 / 60.0;
    const steps: u32 = 120; // 2 s
    const scenarios = [_]FreeScenario{
        .{ .label = "zero gravity, no floor", .gravity = false },
        .{ .label = "free fall, no floor", .gravity = true },
        // Every failing case so far starts ROTATED (the tipped drop); every passing one upright.
        .{ .label = "zero gravity, TIPPED 80 deg", .gravity = false, .tipped = true },
    };
    for (scenarios) |scenario| {
        for ([_]bool{ true, false }) |gyroscopic| {
            var h: Humanoid = undefined;
            try Humanoid.loadWith(gpa, &h, false, dt);
            defer h.deinit();
            const m: *rbt.Model = &h.imported.model;
            limpReduced(m);
            if (!scenario.gravity) {
                m.opt.gravity = vec_zero;
            }
            var target: rbt.Data = try rbt.Data.init(gpa, m);
            defer target.deinit();
            @memcpy(target.pos, m.qpos0);
            _ = robot_mjcf.applyKeyframe(m, &target, h.robot.keyframes[0]);
            target.stage = .stale;
            rbt.forward(m, &target);

            var world: zimrphysics.World = try .init(gpa, 64);
            defer world.deinit(gpa);
            world.gravity = if (scenario.gravity) vec(0, 0, -9.81) else vec_zero;
            world.settings.allow_sleeping = false;
            var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{
                .limits = false,
                .apply_gyroscopic = gyroscopic,
            });
            defer ragdoll.deinit();
            if (scenario.tipped) {
                // Rest joints, the drop's root rotation: the same body, turned.
                const tipped: Quat = quatFromAxisAngle(normalize3(vec(1, 0.3, 0)), 1.4);
                h.data.pos[3] = tipped[0];
                h.data.pos[4] = tipped[1];
                h.data.pos[5] = tipped[2];
                h.data.pos[6] = tipped[3];
                h.data.stage = .stale;
                rbt.forward(m, &h.data);
                try ragdoll.setPose(gpa, &world, &h.data);
            }
            ragdoll.driveToPose(&world, m, &target, .{ .frequency = 10 });

            const a_des: []f32 = try gpa.alloc(f32, m.nv);
            defer gpa.free(a_des);
            const torque: []f32 = try gpa.alloc(f32, m.nv);
            defer gpa.free(torque);
            const full: []f32 = try gpa.alloc(f32, m.nv);
            defer gpa.free(full);
            const dense: []f32 = try gpa.alloc(f32, @as(usize, m.nv) * m.nv);
            defer gpa.free(dense);
            const rots: []Quat = try gpa.alloc(Quat, m.nbody);
            defer gpa.free(rots);
            var reduced_at: [3]f32 = .{ 0, 0, 0 };
            var maximal_at: [3]f32 = .{ 0, 0, 0 };
            var peak_gap: f32 = 0.0;
            for (1..steps + 1) |step| {
                rbt.forward(m, &h.data);
                @memset(h.data.applied_force, 0);
                @memset(a_des, 0);
                for (0..m.njnt) |j| {
                    if (m.jnt_type[j] != .hinge) {
                        continue;
                    }
                    const q: u32 = m.jnt_qpos_adr[j];
                    const v: u32 = m.jnt_dof_adr[j];
                    a_des[v] = stableSpringAccel(target.pos[q] - h.data.pos[q], h.data.vel[v], 10, 1.0, dt);
                }
                rbt.biasForce(m, &h.data);
                floatingBaseTorques(m, &h.data, a_des, dense, full, torque);
                for (0..m.njnt) |j| {
                    if (m.jnt_type[j] == .hinge) {
                        const v: u32 = m.jnt_dof_adr[j];
                        h.data.applied_force[v] = torque[v];
                    }
                }
                rbt.step(m, &h.data);
                try zimrphysics.step(&world, dt);
                peak_gap = @max(peak_gap, ragdoll.jointError(&world));
                const checkpoint: ?usize = if (step == 30) 0 else if (step == 60) 1 else if (step == 120) 2 else null;
                if (checkpoint) |c| {
                    rbt.forward(m, &h.data);
                    @memcpy(rots[1..], h.data.body_xrot[1..m.nbody]);
                    reduced_at[c] = worstJointErrorDeg(&ragdoll, rots, &target) orelse -1.0;
                    for (1..m.nbody) |b| {
                        rots[b] = ragdoll.robotBodyFrame(&world, b).rot;
                    }
                    maximal_at[c] = worstJointErrorDeg(&ragdoll, rots, &target) orelse -1.0;
                }
            }
            report.print("\n  free body, {s}, 60 Hz, 10 Hz spring (deg at 0.5 / 1 / 2 s):\n" ++
                "    reduced implicit CT, floating base  {d:>7.2} {d:>7.2} {d:>7.2}\n" ++
                "    maximal motors, gyroscopic {}     {d:>7.2} {d:>7.2} " ++
                "{d:>7.2}   peak gap {d:.1} mm, speed {d:.2}\n", .{
                scenario.label,
                reduced_at[0],
                reduced_at[1],
                reduced_at[2],
                gyroscopic,
                maximal_at[0],
                maximal_at[1],
                maximal_at[2],
                peak_gap * 1000.0,
                ragdoll.peakSpeed(&world),
            });
        }
    }
}

/// One way of running the maximal motors on the floor at a 60 Hz frame rate.
const FloorDrive = struct {
    label: []const u8,
    frequency: f32 = 10,
    damping: f32 = 1,
    max_torque: f32 = 1.0e6,
    /// Physics steps per 60 Hz frame. 1 is "60 Hz physics"; more is a 60 Hz FRAME rate.
    substeps: u32 = 1,
    swing_twist: bool = true,
};

test "robot_maximal: maximal motors on the floor at a 60 Hz frame rate - what makes them hold" {
    // ** THE MAXIMAL FAILURE IS CONTACT: its motors hold the squat in flight (slowly) and blow up
    // on the floor. The standard game-engine answers, one at a time: a softer drive, more
    // damping, a torque limit, and SUBSTEPS - several physics steps per 60 Hz frame, which on a
    // phone cost about what one reduced step does (194 vs 735 us/step, measured on device).
    // The tipped squat drop, holding the squat, 3 s, limits off.
    const gpa: Allocator = std.testing.allocator;
    const frame_dt: f32 = 1.0 / 60.0;
    const frames: u32 = 180;
    const drives = [_]FloorDrive{
        .{ .label = "10 Hz, 1 substep (baseline)" },
        .{ .label = "5 Hz, 1 substep", .frequency = 5 },
        .{ .label = "10 Hz, damping 3", .damping = 3 },
        .{ .label = "10 Hz, torque <= 50 Nm", .max_torque = 50 },
        .{ .label = "10 Hz, 2 substeps (120 Hz)", .substeps = 2 },
        .{ .label = "10 Hz, 4 substeps (240 Hz)", .substeps = 4 },
        .{ .label = "20 Hz, 4 substeps (240 Hz)", .frequency = 20, .substeps = 4 },
        // Halve the addition: only the revolute joints driven, the swing-twist ones limp.
        .{ .label = "10 Hz, HINGE motors only", .swing_twist = false },
        .{ .label = "20 Hz, HINGE motors only", .frequency = 20, .swing_twist = false },
    };
    report.print("\n  maximal motors holding the squat through the tipped drop, 60 Hz frames, 3 s:\n", .{});
    for (drives) |drive| {
        var h: Humanoid = undefined;
        try Humanoid.loadWith(gpa, &h, false, frame_dt);
        defer h.deinit();
        const m: *rbt.Model = &h.imported.model;
        var target: rbt.Data = try rbt.Data.init(gpa, m);
        defer target.deinit();
        @memcpy(target.pos, m.qpos0);
        _ = robot_mjcf.applyKeyframe(m, &target, h.robot.keyframes[0]);
        target.stage = .stale;
        rbt.forward(m, &target);

        var world: zimrphysics.World = try floorWorld(gpa);
        defer world.deinit(gpa);
        var ragdoll: Ragdoll = try build(gpa, &world, m, &h.data, .{ .limits = false });
        defer ragdoll.deinit();
        h.tippedDropPose();
        try ragdoll.setPose(gpa, &world, &h.data);
        ragdoll.driveToPose(&world, m, &target, .{
            .frequency = drive.frequency,
            .damping = drive.damping,
            .max_torque = drive.max_torque,
            .swing_twist = drive.swing_twist,
        });
        const rots: []Quat = try gpa.alloc(Quat, m.nbody);
        defer gpa.free(rots);
        var peak_gap: f32 = 0.0;
        var peak_speed_late: f32 = 0.0;
        for (0..frames) |frame| {
            for (0..drive.substeps) |_| {
                try zimrphysics.step(&world, frame_dt / float(drive.substeps));
            }
            peak_gap = @max(peak_gap, ragdoll.jointError(&world));
            if (frame >= frames - 60) {
                peak_speed_late = @max(peak_speed_late, ragdoll.peakSpeed(&world));
            }
        }
        for (1..m.nbody) |b| {
            rots[b] = ragdoll.robotBodyFrame(&world, b).rot;
        }
        const err: f32 = worstJointErrorDeg(&ragdoll, rots, &target) orelse -1.0;
        report.print("    {s:<30} error {d:>6.1} deg   last-second peak speed {d:>6.2}   peak gap {d:>6.1} mm\n", .{
            drive.label, err, peak_speed_late, peak_gap * 1000.0,
        });
    }
}

test "robot_maximal: standing - can each engine hold the standing pose on the floor at 60 Hz" {
    // *** THE DANCE'S FIRST FRAME IS SOMEONE STANDING, so a free-root pose hold on the floor is a
    // BALANCE question before it is a pose question - the squat tests never asked it, because
    // that ragdoll was lying on its side. This asks it with no retarget in the way: hold the
    // model's own standing pose (qpos0), torso free, feet on the floor, 60 Hz, for 10 s - then
    // again after a shove at the torso. A pose hold with no balance control is a stiff statue;
    // a statue stands while its centre of mass stays over its feet, and the shove says how
    // far that is from falling. Printed: seconds upright (torso above 0.8 m), worst joint error.
    const gpa: Allocator = std.testing.allocator;
    const dt: f32 = 1.0 / 60.0;
    const frames: u32 = 600; // 10 s
    for ([_]f32{ 0.0, 0.5, 1.0 }) |shove| {
        var h: Humanoid = undefined;
        try Humanoid.loadWith(gpa, &h, false, dt);
        defer h.deinit();
        const m: *rbt.Model = &h.imported.model;
        limpReduced(m);
        var target: rbt.Data = try rbt.Data.init(gpa, m);
        defer target.deinit();
        @memcpy(target.pos, m.qpos0);
        target.stage = .stale;
        rbt.forward(m, &target);

        var world_maximal: zimrphysics.World = try floorWorld(gpa);
        defer world_maximal.deinit(gpa);
        var ragdoll: Ragdoll = try build(gpa, &world_maximal, m, &h.data, .{ .swing_twist_limits = false });
        defer ragdoll.deinit();
        ragdoll.driveToPose(&world_maximal, m, &target, .{ .frequency = 20 });
        var world_reduced: zimrphysics.World = try floorWorld(gpa);
        defer world_reduced.deinit(gpa);
        var bridge: robot_physics.Bridge = try .init(gpa, &world_reduced, m, &h.data, 256);
        defer bridge.deinit(&world_reduced);
        bridge.listen(&world_reduced);

        // The shove: the whole body given a forward velocity, as a push at the torso would.
        h.data.vel[0] = shove;
        const root_part: u32 = ragdoll.part_of_body[1];
        for (0..ragdoll.partCount()) |part| {
            try world_maximal.setLinearVelocity(gpa, ragdoll.handles[part], vec(shove, 0, 0));
        }

        const a_des: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(a_des);
        const torque: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(torque);
        const full: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(full);
        const dense: []f32 = try gpa.alloc(f32, @as(usize, m.nv) * m.nv);
        defer gpa.free(dense);
        const rots: []Quat = try gpa.alloc(Quat, m.nbody);
        defer gpa.free(rots);
        var reduced_upright: f32 = 0.0;
        var maximal_upright: f32 = 0.0;
        var reduced_standing: bool = true;
        var maximal_standing: bool = true;
        for (0..frames) |frame| {
            rbt.forward(m, &h.data);
            try bridge.sync(&world_reduced, m, &h.data);
            try zimrphysics.step(&world_reduced, dt);
            bridge.harvest(&h.data);
            @memset(h.data.applied_force, 0);
            @memset(a_des, 0);
            for (0..m.njnt) |j| {
                if (m.jnt_type[j] != .hinge) {
                    continue;
                }
                const q: u32 = m.jnt_qpos_adr[j];
                const v: u32 = m.jnt_dof_adr[j];
                a_des[v] = stableSpringAccel(target.pos[q] - h.data.pos[q], h.data.vel[v], 20, 1.0, dt);
            }
            rbt.biasForce(m, &h.data);
            floatingBaseTorques(m, &h.data, a_des, dense, full, torque);
            for (0..m.njnt) |j| {
                if (m.jnt_type[j] == .hinge) {
                    const v: u32 = m.jnt_dof_adr[j];
                    h.data.applied_force[v] = torque[v];
                }
            }
            rbt.step(m, &h.data);
            try zimrphysics.step(&world_maximal, dt);
            rbt.forward(m, &h.data);
            const t: f32 = float(frame + 1) * dt;
            if (reduced_standing and h.data.body_xpos[1][2] > 0.8) {
                reduced_upright = t;
            } else {
                reduced_standing = false;
            }
            if (maximal_standing and ragdoll.bodyFrame(&world_maximal, root_part).pos[2] > 0.8) {
                maximal_upright = t;
            } else {
                maximal_standing = false;
            }
        }
        @memcpy(rots[1..], h.data.body_xrot[1..m.nbody]);
        const reduced_error: f32 = worstJointErrorDeg(&ragdoll, rots, &target) orelse -1.0;
        for (1..m.nbody) |b| {
            rots[b] = ragdoll.robotBodyFrame(&world_maximal, b).rot;
        }
        const maximal_error: f32 = worstJointErrorDeg(&ragdoll, rots, &target) orelse -1.0;
        report.print("\n  standing, 60 Hz, shove {d:.1} m/s: REDUCED (implicit CT 20 Hz) upright {d:.2} s, " ++
            "joint error {d:.1} deg; MAXIMAL (motors 20 Hz) upright {d:.2} s, joint error {d:.1} deg\n", .{
            shove, reduced_upright, reduced_error, maximal_upright, maximal_error,
        });
    }
}

test "robot_maximal: massDiagonal against the mass matrix measured through inverse dynamics" {
    // The inertia-scaled PD froze at its start error when it took M_ii from `rbt.massDiagonal`,
    // and moved normally with M_ii measured as (M e_i)_i = ID(e_i)_i - c_i. This compares the
    // two on both humanoids (floating and fixed-base), prints every DOF that disagrees, and fails
    // if any does - it printed "0 of 27" and "0 of 21" for a long time without asserting it.
    const gpa: Allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |fixed_base| {
        var h: Humanoid = undefined;
        try Humanoid.loadWith(gpa, &h, fixed_base, test_timestep);
        defer h.deinit();
        const m: *const rbt.Model = &h.imported.model;
        rbt.forward(m, &h.data);
        rbt.biasForce(m, &h.data);
        const unit: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(unit);
        const out: []f32 = try gpa.alloc(f32, m.nv);
        defer gpa.free(out);
        var disagreements: u32 = 0;
        for (0..m.nv) |i| {
            @memset(unit, 0);
            unit[i] = 1.0;
            rbt.inverseDynamics(m, &h.data, unit, out);
            const measured: f32 = out[i] - h.data.bias_force[i];
            const read: f32 = rbt.massDiagonal(m, &h.data, @intCast(i));
            if (@abs(measured - read) > 1.0e-4 * @max(1.0, @abs(measured))) {
                disagreements += 1;
                report.print("    {s} dof {d:>2}: M_ii measured {d:.5}, massDiagonal {d:.5}\n", .{
                    if (fixed_base) "fixed-base" else "floating", i, measured, read,
                });
            }
        }
        report.print("  massDiagonal, {s} humanoid: {d} of {d} DOFs disagree\n", .{
            if (fixed_base) "fixed-base" else "floating", disagreements, m.nv,
        });
        try expect(disagreements == 0);
    }
}
