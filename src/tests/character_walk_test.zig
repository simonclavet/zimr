// src/tests/character_walk_test.zig - regression guard for the CharacterVirtual
// "walks in the air, freezes on landing" bug.
//
// `cvGetFirstContactForSweep` clamps a solved displacement to the first real
// contact. It accepted ANY hit, including the floor the character is already
// resting on: standing still on flat ground, a horizontal sweep hits that floor
// at fraction 0 with normal (0,1,0) - perpendicular to the motion - and the
// whole step was multiplied by zero. The character moved normally while
// airborne and stopped dead the instant it touched down, which reads as
// "movement doesn't work" rather than as a collision bug.
//
// Jolt's GetFirstContactForSweep only treats a hit as blocking when its normal
// OPPOSES the motion (`normal * displacement < 0`); this port had dropped that
// check. Both halves are pinned here, because either one alone is easy to
// satisfy wrongly: a character that walks but cannot be stopped is no better
// than one that cannot walk.

const std = @import("std");
const zimrphysics = @import("../zimrphysics.zig");
const zm = @import("zm");

const vec = zm.vec;
const Vec = zm.Vec;
const expect = std.testing.expect;

const speed: f32 = 5.0; // m/s, the fps_playground walk speed
const dt: f32 = 1.0 / 60.0;

/// Build a world with a large flat floor, and optionally a wall across z = 4.
fn makeWorld(gpa: std.mem.Allocator, with_wall: bool) !zimrphysics.World {
    var world: zimrphysics.World = try zimrphysics.World.init(gpa, 256);
    errdefer world.deinit(gpa);

    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(40.0, 0.5, 40.0), .convex_radius = 0.0 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0.0, -0.5, 0.0),
        .motion_type = .static,
    });

    if (with_wall) {
        const wall: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(10.0, 2.0, 0.5), .convex_radius = 0.0 },
        });
        _ = try world.createBody(.{
            .shape = wall,
            .position = vec(0.0, 2.0, 4.0),
            .motion_type = .static,
        });
    }
    return world;
}

/// Walk a capsule character along -Z for `frames`, exactly as fps_playground
/// drives it: caller-owned vertical velocity, engine-owned horizontal slide.
fn walk(gpa: std.mem.Allocator, world: *zimrphysics.World, frames: u32) !Vec {
    const cap: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .capsule = .{ .half_height = 0.6, .radius = 0.35 },
    });
    var player: zimrphysics.CharacterVirtual = .{
        .shape = cap,
        .position = vec(0.0, 1.2, 9.0),
    };
    defer player.deinit(gpa);

    var scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var vel_y: f32 = 0;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        _ = scratch.reset(.retain_capacity);
        if (player.isSupported() and vel_y < 0) {
            vel_y = 0;
        }
        vel_y += -9.81 * dt;
        player.linear_velocity = vec(0.0, vel_y, -speed);
        try zimrphysics.characterExtendedUpdate(
            world,
            &player,
            dt,
            vec(0.0, -9.81, 0.0),
            .{},
            scratch.allocator(),
        );
        try zimrphysics.step(world, dt);
    }
    return player.position;
}

test "character keeps walking after it lands on flat ground" {
    const gpa: std.mem.Allocator = std.testing.allocator;
    var world: zimrphysics.World = try makeWorld(gpa, false);
    defer world.deinit(gpa);

    // 180 frames = 3 s. Roughly a quarter second is spent falling, so expect a
    // little under 3 s of travel; anything near zero means the landing froze it.
    const end: Vec = try walk(gpa, &world, 180);
    const travelled: f32 = 9.0 - end[2];
    try expect(travelled > 12.0); // ~14 m at 5 m/s minus the fall
    try expect(end[1] > 0.5); // still standing on the floor, not sunk through
}

test "character is still stopped by a wall" {
    const gpa: std.mem.Allocator = std.testing.allocator;
    var world: zimrphysics.World = try makeWorld(gpa, true);
    defer world.deinit(gpa);

    // The wall's near face is at z = 4.5; the capsule must stop just before it
    // and must not tunnel to the far side.
    const end: Vec = try walk(gpa, &world, 180);
    try expect(end[2] > 4.5);
    try expect(end[2] < 5.5);
}

test "character walks up a step" {
    const gpa: std.mem.Allocator = std.testing.allocator;
    var world: zimrphysics.World = try zimrphysics.World.init(gpa, 256);
    defer world.deinit(gpa);

    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(40.0, 0.5, 40.0), .convex_radius = 0.0 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0.0, -0.5, 0.0),
        .motion_type = .static,
    });

    // A 0.25 m step across the path, well inside the 0.4 m default step-up.
    const step_shape: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(10.0, 0.125, 5.0), .convex_radius = 0.0 },
    });
    _ = try world.createBody(.{
        .shape = step_shape,
        .position = vec(0.0, 0.125, -1.0),
        .motion_type = .static,
    });

    // Walking into it must end up ON TOP (y rises by roughly the step height),
    // not stopped against its face. This is the path the walk-stairs direction
    // selection drives.
    const end: Vec = try walk(gpa, &world, 180);
    try expect(end[2] < 3.0); // got past where the step face would stop us
    try expect(end[1] > 1.1); // standing on top of the step, not on the floor
}
