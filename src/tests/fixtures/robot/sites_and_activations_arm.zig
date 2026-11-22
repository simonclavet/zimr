//! AN ARM FOR WHAT THE OTHER TEST ROBOTS LEAVE OUT: sites, and actuators that carry an internal state.
//!
//! Three links hang from the world on hinges about three different axes - the shoulder swings the arm sideways, the
//! elbow forward and back, the wrist twists the hand about its own length - each link a shape with a site at its far
//! end. The forearm's site is turned 30 degrees about the link, so a site's orientation is not its body's.
//!
//! Four actuators: a position servo on the shoulder with no state, then one of each activation the engine has - an
//! integrator on the shoulder (its control clamped to a range), a filter integrated by Euler on the elbow, and a
//! filter integrated exactly on the wrist, its time constant shorter than the timestep, where only the exact form is
//! stable. The first has no activation, so each of the others' activations sits one index below its actuator's.
//!
//! Small enough to read whole. robotgpu's twin is checked against robot.zig on it - every site placed and every
//! activation carried to the bit - and a device against the twin.

const rbt = @import("robot");
const zm = @import("zm");
const vec = zm.vec;

pub const spec: rbt.ModelSpec = .{
    .bodies = &.{
        .{
            .name = "upper_arm",
            .pos = vec(0, 2.0, 0),
            .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1), .damping = 0.2 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.04 } },
                .pos = vec(0, -0.15, 0),
            }},
            .sites = &.{.{ .name = "elbow_mark", .pos = vec(0, -0.3, 0) }},
        },
        .{
            .name = "forearm",
            .parent = "upper_arm",
            .pos = vec(0, -0.3, 0),
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(1, 0, 0), .damping = 0.1 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.125, .radius = 0.035 } },
                .pos = vec(0, -0.125, 0),
            }},
            // Turned 30 degrees about the forearm's own length (its y): the quaternion (0, sin 15, 0, cos 15).
            .sites = &.{.{ .name = "wrist_mark", .pos = vec(0, -0.25, 0), .rot = .{ 0, 0.25881904, 0, 0.96592583 } }},
        },
        .{
            .name = "hand",
            .parent = "forearm",
            .pos = vec(0, -0.25, 0),
            .joints = &.{.{ .name = "wrist", .kind = .hinge, .axis = vec(0, 1, 0) }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.04, 0.05, 0.015) } }, .pos = vec(0, -0.05, 0) }},
            .sites = &.{.{ .name = "fingertip", .pos = vec(0.02, -0.1, 0.01) }},
        },
    },
    .actuators = &.{
        .{
            .name = "shoulder_servo",
            .on = .{ .joint = .{ .name = "shoulder" } },
            .kind = .{ .position = .{ .kp = 20, .kv = 1 } },
        },
        .{
            .name = "shoulder_integrator",
            .on = .{ .joint = .{ .name = "shoulder" } },
            .activation = .integrator,
            .ctrl_range = .{ -1, 1 },
        },
        .{
            .name = "elbow_filter",
            .on = .{ .joint = .{ .name = "elbow" } },
            .activation = .{ .filter = .{ .time_const_s = 0.05 } },
        },
        .{
            .name = "wrist_exact_filter",
            .on = .{ .joint = .{ .name = "wrist" } },
            .activation = .{ .filter_exact = .{ .time_const_s = 0.004 } },
        },
    },
    .options = .{ .timestep = 1.0 / 60.0 },
};

pub const Model = rbt.Spec(spec);
