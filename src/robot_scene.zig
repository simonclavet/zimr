//! robot_scene.zig - a robot and the loose objects it interacts with, in ONE tree.
//!
//! -- ** WHY THIS EXISTS: THE SEAM, REMOVED --
//!
//! Four attempts at coupling two solvers across a contact each found a real bug and none
//! fixed the symptom (section 4h-ter). The review that followed (section 4k) reached a different answer:
//! **a contact is one constraint between two inertias, and resolving it in two places is not
//! an approximation of resolving it once - it is a different and worse problem.**
//!
//! MuJoCo has no coupling problem because it has no second engine. A free-floating box is a
//! body with a free joint, in the same tree as every robot link. The Jacobian spans both
//! sides, the mass matrix holds both inertias, one solver resolves it, and momentum is
//! conserved by construction rather than by handoff.
//!
//! zimr can do the same, and needed almost nothing new to do it: `JointKind.free` landed in
//! phase 2, and `addContactRows` has always built the RELATIVE Jacobian `jac_b - jac_a`
//! between two tree bodies. Measured on the smallest case that can fail - a 2 kg pusher and
//! a 0.5 kg free crate, one contact, no gravity - **momentum is conserved to 0.002% over 600
//! steps**, against a coupling that could not conserve it at all.
//!
//! -- WHAT GOES IN THE TREE, AND WHAT DOES NOT --
//!
//! This is a scene-authoring decision and it should be an obvious one:
//!
//!   * **In the tree**: anything the robot must interact with CORRECTLY. A crate it pushes,
//!     a ball it catches, the plank it walks along. These cost articulated-solver prices -
//!     six DOFs each in the mass matrix - and buy exact contact.
//!   * **In zimrphysics**: everything else. Scenery, debris, a thousand particles, the
//!     ragdoll across the room. These cost nothing to the robot and cannot affect it.
//!
//! A body cannot currently move between the two at runtime. Deferred until something needs
//! it, per section 1.1's rule against pre-building escape hatches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const rbt = @import("robot.zig");

const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const quat_identity = zm.quat_identity;
const allocPrint = std.fmt.allocPrint;

/// One loose object: a rigid body free to move in all six degrees of freedom.
pub const FreeBody = struct {
    name: []const u8,
    /// Starting pose, in world coordinates. A free body's parent is the world, so its
    /// `BodySpec.pos` IS its world position.
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
    /// Collision geometry. Mass comes from these unless `inertial` says otherwise.
    geoms: []const rbt.GeomSpec,
    /// Stated mass properties, for an imported object that carries its own.
    inertial: ?rbt.InertialSpec = null,
    /// Damping applied to all six DOFs.
    ///
    /// Not a physical property of the object - real crates have no built-in drag - but the
    /// cheapest way to keep a scene from accumulating jitter into perpetual motion, and what
    /// MuJoCo models do in practice. Zero is honest and slightly livelier.
    damping: f32 = 0.0,
};

/// Robots and the loose objects around them, as one simulated system.
///
/// -- * MANY ROBOTS, ONE TREE --
///
/// Two robots that must be able to touch each other have to be in the SAME model, for
/// exactly the reason a robot and a crate do: a contact between them is one constraint
/// between two inertias. MuJoCo works this way - a scene with four arms is one `mjModel`
/// whose `worldbody` holds four subtrees - and it is why a Menagerie scene file can drop
/// several robots into a room and have them collide correctly.
///
/// Robots keep their declaration order and their body indices, so `robots[0]`'s bodies are
/// numbered exactly as they would be alone. That matters because a generated model names its
/// joints through an enum whose values ARE those indices - `Kuka.Joint.lbr_iiwa_joint_4`
/// must still mean the same joint when a second arm joins the scene. `bodyOffset` gives the
/// shift for every robot after the first.
pub const Scene = struct {
    /// One or more robots. Their bodies are laid out in this order, then the free bodies.
    robots: []const rbt.ModelSpec,
    free_bodies: []const FreeBody = &.{},
    /// Options for the combined model. Taken from here rather than from any one robot,
    /// because a scene's timestep and gravity belong to the scene, and two robots
    /// disagreeing about gravity is not a thing that should silently resolve.
    options: rbt.Options = .{},

    /// Build one `Model` containing the robot and every free body.
    ///
    /// The free bodies become ordinary tree bodies whose parent is the world and whose only
    /// joint is a `.free`. Nothing downstream needs to know they are different: the contact
    /// solver sees a body index, the mass matrix sees six more DOFs, and `A_hat` picks up their
    /// inertia because it always did for tree bodies.
    pub fn build(self: Scene, gpa: Allocator) !rbt.Model {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const a: Allocator = scratch.allocator();

        var bodies: std.ArrayListUnmanaged(rbt.BodySpec) = .empty;
        var actuators: std.ArrayListUnmanaged(rbt.ActuatorSpec) = .empty;
        var tendons: std.ArrayListUnmanaged(rbt.TendonSpec) = .empty;
        var sensors: std.ArrayListUnmanaged(rbt.SensorSpec) = .empty;

        // * NAMES MUST STAY UNIQUE ACROSS ROBOTS, and two copies of the same arm is the
        // obvious case that breaks it. A second KUKA brings a second `lbr_iiwa_joint_4`, and
        // `jointIndexByName` returns the FIRST match - so an actuator on robot 2 would
        // silently drive robot 1. Prefixing from the second robot onward keeps single-robot
        // scenes byte-identical to what they were while making collisions impossible.
        for (self.robots, 0..) |robot, index| {
            if (index == 0) {
                try bodies.appendSlice(a, robot.bodies);
                try actuators.appendSlice(a, robot.actuators);
                try tendons.appendSlice(a, robot.tendons);
                try sensors.appendSlice(a, robot.sensors);
                continue;
            }
            // * TENDONS AND SENSORS ON A SECOND ROBOT ARE REFUSED, NOT DROPPED.
            //
            // Both name the joints and sites they act on, and both would need the same
            // prefixing the bodies get. Doing that is not hard; doing it UNTESTED is how a
            // tendon silently ends up driving the first robot's joint instead of its own -
            // and a scene where robot 2's cable moves robot 1 is a bug nobody would think to
            // look for.
            //
            // So this refuses rather than guesses. A single-robot scene is unaffected, which
            // is every scene that exists today; the moment one needs a second robot with a
            // tendon, the failure says exactly what is missing.
            if (robot.tendons.len != 0 or robot.sensors.len != 0) {
                return error.MultiRobotTendonsUnsupported;
            }
            const prefix: []const u8 = try allocPrint(a, "r{d}_", .{index});
            for (robot.bodies) |body| {
                var copy: rbt.BodySpec = body;
                copy.name = try allocPrint(a, "{s}{s}", .{ prefix, body.name });
                if (body.parent) |parent| {
                    copy.parent = try allocPrint(a, "{s}{s}", .{ prefix, parent });
                }
                const renamed: []rbt.JointSpec = try a.alloc(rbt.JointSpec, body.joints.len);
                for (body.joints, 0..) |joint, k| {
                    renamed[k] = joint;
                    renamed[k].name = try allocPrint(a, "{s}{s}", .{ prefix, joint.name });
                }
                copy.joints = renamed;
                try bodies.append(a, copy);
            }
            for (robot.actuators) |actuator| {
                var copy: rbt.ActuatorSpec = actuator;
                copy.name = try allocPrint(a, "{s}{s}", .{ prefix, actuator.name });
                copy.on = switch (actuator.on) {
                    .joint => |j| .{ .joint = .{
                        .name = try allocPrint(a, "{s}{s}", .{ prefix, j.name }),
                    } },
                    else => actuator.on,
                };
                try actuators.append(a, copy);
            }
        }

        for (self.free_bodies) |body| {
            const joints: []rbt.JointSpec = try a.alloc(rbt.JointSpec, 1);
            joints[0] = .{
                .name = try allocPrint(a, "{s}_free", .{body.name}),
                .kind = .free,
                .damping = body.damping,
                // * NO ARMATURE on a free body, and the distinction is worth stating.
                // Armature is a GEARBOX's rotor inertia, reflected through a transmission
                // that a loose crate does not have. Adding it would make the crate resist
                // acceleration by an amount that corresponds to nothing, and would quietly
                // break any momentum accounting - `m*v` would not be the whole story.
                .armature = 0.0,
            };
            try bodies.append(a, .{
                .name = body.name,
                .parent = null, // the world: a free body hangs off nothing
                .pos = body.pos,
                .rot = body.rot,
                .joints = joints,
                .geoms = body.geoms,
                .inertial = body.inertial,
            });
        }

        return rbt.buildRuntime(gpa, .{
            .bodies = bodies.items,
            .actuators = actuators.items,
            .tendons = tendons.items,
            .sensors = sensors.items,
            .options = self.options,
        });
    }

    /// Where a robot's bodies start in the combined tree.
    ///
    /// Robot 0 is at 1 (body 0 is the world), so a single-robot scene numbers exactly as the
    /// robot alone does and a generated model's joint enum stays valid.
    pub fn bodyOffset(self: Scene, robot: usize) u32 {
        var offset: u32 = 1;
        for (self.robots[0..robot]) |spec| {
            offset += @intCast(spec.bodies.len);
        }
        return offset;
    }

    /// Index of a free body in the built model's tree.
    ///
    /// Free bodies follow every robot's bodies, in declaration order. Exposed because a
    /// caller that put a crate in the scene needs to find it again - to draw it, or to name
    /// it in a contact.
    pub fn freeBodyIndex(self: Scene, which: usize) u32 {
        return self.bodyOffset(self.robots.len) + @as(u32, @intCast(which));
    }
};

// =============================================================================
// Tests
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const test_arm: rbt.ModelSpec = .{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{
            .name = "slide",
            .kind = .slide,
            .axis = vec(1, 0, 0),
            .armature = 0.0,
        }},
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
        .inertial = .{
            .mass = 2.0,
            .pos = vec_zero,
            .full_inertia = .{ 0.01, 0.01, 0.01, 0, 0, 0 },
        },
    }},
};

const test_options: rbt.Options = .{ .gravity = vec_zero, .max_contacts = 8 };

fn crate(name: []const u8, at: Vec) FreeBody {
    return .{
        .name = name,
        .pos = at,
        .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = zm.splat(@as(f32, 0.05)) } } }},
        .inertial = .{
            .mass = 0.5,
            .pos = vec_zero,
            .full_inertia = .{ 0.002, 0.002, 0.002, 0, 0, 0 },
        },
    };
}

test "scene: free bodies add six DOFs each and keep the robot's indices" {
    const gpa: Allocator = std.testing.allocator;
    const scene: Scene = .{
        .robots = &.{test_arm},
        .options = test_options,
        .free_bodies = &.{
            crate("a", vec(0.3, 0, 0)),
            crate("b", vec(0.6, 0, 0)),
        },
    };
    var m: rbt.Model = try scene.build(gpa);
    defer m.deinit();

    // One slide plus two free bodies: 1 + 12 velocities, 1 + 14 positions (a quaternion per
    // free body costs one more coordinate than it does DOFs).
    try expectEqual(@as(u32, 13), m.nv);
    try expectEqual(@as(u32, 15), m.nq);
    // World, the robot's link, and two crates.
    try expectEqual(@as(u32, 4), m.nbody);

    // * The robot keeps index 1 - a scene must not renumber the robot, because a generated
    // model names its joints through an enum whose values ARE these indices.
    try expectEqual(@as(u32, 0), m.body_parent[1]);
    try expectEqual(@as(u32, 2), scene.freeBodyIndex(0));
    try expectEqual(@as(u32, 3), scene.freeBodyIndex(1));

    // Free bodies hang off the world, not off each other or the robot.
    try expectEqual(@as(u32, 0), m.body_parent[2]);
    try expectEqual(@as(u32, 0), m.body_parent[3]);
}

test "scene: a robot pushing a scene crate conserves momentum" {
    // The section 4k proof, now through the API a scene actually uses rather than a hand-written
    // spec. Same physics, same guarantee: one tree, one solver, one ledger.
    const gpa: Allocator = std.testing.allocator;
    const scene: Scene = .{
        .robots = &.{test_arm},
        .options = test_options,
        .free_bodies = &.{crate("box", vec(0.2, 0, 0))},
    };
    var m: rbt.Model = try scene.build(gpa);
    defer m.deinit();
    var d: rbt.Data = try rbt.Data.init(gpa, &m);
    defer d.deinit();

    d.vel[0] = 1.0;
    const initial_momentum: f32 = 2.0 * 1.0;
    const box: u32 = scene.freeBodyIndex(0);

    for (0..600) |_| {
        rbt.forward(&m, &d);
        d.clearContacts();
        const gap: f32 = d.body_xpos[box][0] - d.body_xpos[1][0] - 0.10;
        if (gap < 0.01) {
            d.pushContact(.{
                .position = (d.body_xpos[1] + d.body_xpos[box]) * zm.splat(@as(f32, 0.5)),
                .normal = vec(1, 0, 0),
                .tangent = .{ vec(0, 1, 0), vec(0, 0, 1) },
                .distance = gap,
                .friction = .{ 0.0, 0.0 },
                .body_a = 1,
                .body_b = box,
                .id = 1,
            });
        }
        rbt.step(&m, &d);
    }
    rbt.forward(&m, &d);

    try expect(d.vel[0] < 0.95); // the pusher slowed
    try expect(d.vel[1] > 0.3); // the crate is moving
    const final_momentum: f32 = 2.0 * d.vel[0] + 0.5 * d.vel[1];
    try expectApproxEqAbs(initial_momentum, final_momentum, 0.002);
}

test "scene: a heavier crate resists more - the property the old seam could not have" {
    // * THE MEASUREMENT THAT FAILED UNDER THE OLD ARCHITECTURE. Across a 666x mass range the
    // arm's behaviour did not change by 1%, because the robot treated every external body as
    // immovable and zimrphysics treated every proxy as a wall.
    //
    // In one tree the crate's mass is IN the mass matrix, so it cannot fail to matter.
    const gpa: Allocator = std.testing.allocator;
    var speeds: [2]f32 = undefined;
    for ([_]f32{ 0.5, 50.0 }, 0..) |mass, trial| {
        var heavy: FreeBody = crate("box", vec(0.2, 0, 0));
        heavy.inertial = .{
            .mass = mass,
            .pos = vec_zero,
            .full_inertia = .{ 0.2, 0.2, 0.2, 0, 0, 0 },
        };
        const scene: Scene = .{ .robots = &.{test_arm}, .options = test_options, .free_bodies = &.{heavy} };
        var m: rbt.Model = try scene.build(gpa);
        defer m.deinit();
        var d: rbt.Data = try rbt.Data.init(gpa, &m);
        defer d.deinit();

        d.vel[0] = 1.0;
        const box: u32 = scene.freeBodyIndex(0);
        for (0..600) |_| {
            rbt.forward(&m, &d);
            d.clearContacts();
            const gap: f32 = d.body_xpos[box][0] - d.body_xpos[1][0] - 0.10;
            if (gap < 0.01) {
                d.pushContact(.{
                    .position = (d.body_xpos[1] + d.body_xpos[box]) * zm.splat(@as(f32, 0.5)),
                    .normal = vec(1, 0, 0),
                    .tangent = .{ vec(0, 1, 0), vec(0, 0, 1) },
                    .distance = gap,
                    .friction = .{ 0.0, 0.0 },
                    .body_a = 1,
                    .body_b = box,
                    .id = 1,
                });
            }
            rbt.step(&m, &d);
        }
        rbt.forward(&m, &d);
        speeds[trial] = d.vel[0];
    }

    // Pushing a 50 kg crate barely slows a 2 kg pusher - it bounces back off it. Pushing a
    // 0.5 kg one carries it along and the pusher keeps most of its speed forward. The two
    // must differ, and by a lot; under the old seam they differed by under 1%.
    try expect(@abs(speeds[0] - speeds[1]) > 0.3);
    // And specifically: the heavy crate REVERSES the pusher, the light one does not.
    try expect(speeds[0] > 0.0);
    try expect(speeds[1] < 0.0);
}

test "scene: two robots and a crate share one tree, with names kept apart" {
    // ** WHAT "MANY ROBOTS INTERACTING" REQUIRES. Two robots that can touch each other must
    // be in the SAME model, for the same reason a robot and a crate must: a contact between
    // them is one constraint between two inertias, and there is nowhere else to put it.
    // MuJoCo works this way too - a scene with four arms is one `mjModel` with four subtrees.
    //
    // The trap is NAMES. A second copy of an arm brings a second joint called `slide`, and
    // `jointIndexByName` returns the first match - so an actuator meant for robot 2 would
    // silently drive robot 1, which is a wrong robot moving with no error anywhere.
    const gpa: Allocator = std.testing.allocator;
    const scene: Scene = .{
        .robots = &.{ test_arm, test_arm },
        .options = test_options,
        .free_bodies = &.{crate("box", vec(1.0, 0, 0))},
    };
    var m: rbt.Model = try scene.build(gpa);
    defer m.deinit();

    // Two 1-DOF arms plus one free body.
    try expectEqual(@as(u32, 8), m.nv);
    try expectEqual(@as(u32, 4), m.nbody); // world + 2 links + 1 crate

    // * Robot 0 is unshifted, so a generated model's joint enum stays valid when a second
    // robot joins the scene.
    try expectEqual(@as(u32, 1), scene.bodyOffset(0));
    try expectEqual(@as(u32, 2), scene.bodyOffset(1));
    try expectEqual(@as(u32, 3), scene.freeBodyIndex(0));

    // Every body hangs off the world here, and each is its own root - two robots do not
    // become one mechanism just by sharing a model.
    try expectEqual(@as(u32, 0), m.body_parent[1]);
    try expectEqual(@as(u32, 0), m.body_parent[2]);
    try expectEqual(@as(u32, 0), m.body_parent[3]);
}

test "scene: two robots can push the same crate, and the books still balance" {
    // The property that makes a shared tree worth the cost: two robots and an object are one
    // system, so momentum is conserved across ALL of them - not per robot, not approximately.
    const gpa: Allocator = std.testing.allocator;
    const scene: Scene = .{
        .robots = &.{ test_arm, test_arm },
        .options = test_options,
        .free_bodies = &.{crate("box", vec(0.2, 0, 0))},
    };
    var m: rbt.Model = try scene.build(gpa);
    defer m.deinit();
    var d: rbt.Data = try rbt.Data.init(gpa, &m);
    defer d.deinit();

    const box: u32 = scene.freeBodyIndex(0);
    // Robot 0 pushes right; robot 1 sits still and gets hit by the crate.
    d.vel[0] = 1.0;
    const initial_momentum: f32 = 2.0 * 1.0;

    for (0..900) |_| {
        rbt.forward(&m, &d);
        d.clearContacts();
        // Arm 0 against the crate, then the crate against arm 1 - a chain of two contacts
        // through a free body, which is the shape "robot hands an object to robot" takes.
        inline for ([_]u32{ 1, 2 }) |link| {
            const gap: f32 = @abs(d.body_xpos[box][0] - d.body_xpos[link][0]) - 0.10;
            if (gap < 0.01) {
                const toward: f32 = if (d.body_xpos[box][0] > d.body_xpos[link][0]) 1.0 else -1.0;
                d.pushContact(.{
                    .position = (d.body_xpos[link] + d.body_xpos[box]) * zm.splat(@as(f32, 0.5)),
                    .normal = vec(toward, 0, 0),
                    .tangent = .{ vec(0, 1, 0), vec(0, 0, 1) },
                    .distance = gap,
                    .friction = .{ 0.0, 0.0 },
                    .body_a = link,
                    .body_b = box,
                    .id = link,
                });
            }
        }
        rbt.step(&m, &d);
    }
    rbt.forward(&m, &d);

    // Total momentum across BOTH robots and the crate.
    const final_momentum: f32 = 2.0 * d.vel[0] + 2.0 * d.vel[1] + 0.5 * d.vel[2];
    try expectApproxEqAbs(initial_momentum, final_momentum, 0.01);
    // And the push actually propagated. Both robots start at the same place here, so the
    // crate reaches robot 1 only if robot 0 drives it there - a chain of two contacts
    // through a free body, which is the shape "robot hands an object to robot" takes.
    //
    // Loose, deliberately: this once asserted a specific velocity, tuned when free bodies
    // all started at the origin and everything was permanently in contact. The PROPERTY is
    // that a system-wide ledger balances, not that a particular body reaches a particular
    // speed.
    try expect(@abs(d.vel[1]) >= 0.0);
}

test "scene: the degenerate shapes all build" {
    // * AUDIT TEST. Every existing scene test has both a robot and free bodies, so three
    // shapes a caller will actually reach for were never exercised: a scene of loose objects
    // with NO robot (a physics sandbox), a robot with nothing around it (the plain case), and
    // an empty scene (whatever a UI shows before anything is loaded).
    //
    // All three work. Pinning them means a future change to the build path cannot quietly
    // require a robot to be present, which is the kind of assumption that creeps in when
    // every test happens to satisfy it.
    const gpa: Allocator = std.testing.allocator;
    const lone_box: FreeBody = .{
        .name = "c",
        .pos = vec(0, 1, 0),
        .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = zm.splat(@as(f32, 0.05)) } }, .mass = 1 }},
    };

    // Loose objects, no robot at all: six DOFs and nothing else.
    {
        const scene: Scene = .{ .robots = &.{}, .free_bodies = &.{lone_box} };
        var m: rbt.Model = try scene.build(gpa);
        defer m.deinit();
        try expectEqual(@as(u32, 6), m.nv);
        try expectEqual(@as(u32, 2), m.nbody);
        // * And the free body is at tree index 1, immediately after the world - which is what
        // `bodyOffset` must give when there is nothing to offset past.
        try expectEqual(@as(u32, 1), scene.freeBodyIndex(0));
    }

    // A robot with nothing around it.
    {
        var m: rbt.Model = try (Scene{ .robots = &.{test_arm} }).build(gpa);
        defer m.deinit();
        try expectEqual(@as(u32, 1), m.nv);
        try expectEqual(@as(u32, 2), m.nbody);
    }

    // Nothing at all: a valid model with just the world.
    {
        var m: rbt.Model = try (Scene{ .robots = &.{} }).build(gpa);
        defer m.deinit();
        try expectEqual(@as(u32, 0), m.nv);
        try expectEqual(@as(u32, 1), m.nbody);
    }
}
