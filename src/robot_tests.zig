//! robot_tests.zig - the robot family's tests, compiled once and run once.
//!
//! Every robot file is its own fast test root, so `zig build zn-<stem>` iterates on one of them.
//! But a root runs the tests of everything it imports: `robot_control` reaches robot,
//! robot_physics, robot_mjcf, robot_scene, mjcf and codecs, and `robot_mpc` reaches most of that
//! again. As separate `test-fast` members, eleven roots compiled overlapping closures and ran the
//! same few hundred tests several times each.
//!
//! This root imports every one of them, so `test-fast` compiles the union once and runs each
//! test once, and the per-file roots drop out of `test-fast` while keeping their `zn-` steps.
//! * The imports below ARE the list: build.zig reads this file to decide which roots it stands
//! in for, so a robot file that is not imported here stays a `test-fast` member of its own.

const std = @import("std");

pub const robot = @import("robot.zig");
pub const robot_scene = @import("robot_scene.zig");
pub const robot_physics = @import("robot_physics.zig");
pub const robot_control = @import("robot_control.zig");
pub const robot_mpc = @import("robot_mpc.zig");
pub const robot_mjcf = @import("robot_mjcf.zig");
pub const robot_maximal = @import("robot_maximal.zig");
pub const robot_dance = @import("robot_dance.zig");
pub const robot_gym = @import("robot_gym.zig");
/// The GPU kit's proofs: kept out of the zimr module (they import `gpu/zn_mlp.zig` by path).
pub const gpu_learn_tests = @import("gpu_learn_tests.zig");
pub const kit_mlp = @import("kit_mlp.zig");
pub const robot_track = @import("robot_track.zig");
pub const robot_world = @import("robot_world.zig");
pub const robot_supertrack = @import("robot_supertrack.zig");
pub const robot_latent = @import("robot_latent.zig");

pub const robot_geno = @import("robot_geno.zig");
pub const robot_latent_kit_tests = @import("robot_latent_kit_tests.zig");
pub const robot_track_resident_tests = @import("robot_track_resident_tests.zig");
pub const robot_policy = @import("robot_policy.zig");
pub const robot_ppo_track = @import("robot_ppo_track.zig");
/// Its proofs, outside the zimr module for the same reason as `gpu_learn_tests`.
pub const robot_ppo_track_tests = @import("robot_ppo_track_tests.zig");
pub const robot_mocap_tutorial = @import("robot_mocap_tutorial.zig");
pub const robot_urdf = @import("robot_urdf.zig");
pub const mjcf = @import("mjcf.zig");
pub const urdf = @import("urdf.zig");

test {
    std.testing.refAllDecls(@This());
}
