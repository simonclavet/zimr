// src/tests/zimrphysics_stack_test.zig — regression guard for the box-stack
// interpenetration bug: the demo's `stack` scene collapsed as box-box face
// manifolds degraded from 4 points to 1 under accumulated micro-tilt (the SAT
// reclassified near-flat resting contacts as edge-edge and emitted a single
// point). Jolt always builds the manifold from each box's SUPPORTING FACE
// relative to the penetration normal, so a near-flat contact stays a
// multi-point face manifold; collideBoxBox now does the same.
//
// This test rebuilds that exact scene (8 elongated boxes, alternating 90° yaw),
// disables sleeping so the solver must hold the stack every frame, runs 10 s,
// and asserts the boxes never interpenetrate beyond the slop and never reorder.

const std = @import("std");
const zimrphysics = @import("../zimrphysics.zig");
const zm = @import("zm");
const float = zm.float;

const vec = zm.vec;
const Vec = zm.Vec;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const pi = zm.pi;
const expect = std.testing.expect;

const half_y: f32 = 0.45; // box half-height (Y extent is unaffected by yaw)
const n_boxes: u32 = 8;

test "stack scene: boxes rest without interpenetrating" {
    const gpa: std.mem.Allocator = std.testing.allocator;

    var world: zimrphysics.World = try zimrphysics.World.init(gpa, 1024);
    defer world.deinit(gpa);
    // Stress: prove the solver holds the stack every frame, not that it merely
    // freezes once asleep. Sleeping would mask residual instability.
    world.settings.allow_sleeping = false;

    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // floor_shape (top at y=0)
    const floor_shape: zimrphysics.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(10, 0.5, 10),
        .convex_radius = 0.05,
    } });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
    });

    // 8 elongated boxes, alternating 90° yaw (the demo's sceneStack)
    const box: zimrphysics.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.45, 0.45, 0.95),
        .convex_radius = 0.05,
    } });
    var ids: [n_boxes]zimrphysics.BodyHandle = undefined;
    var i: u32 = 0;
    while (i < n_boxes) : (i += 1) {
        const angle: f32 = if (i % 2 == 0) 0.0 else pi * 0.5;
        ids[i] = try world.createBody(.{
            .shape = box,
            .position = vec(0, 0.55 + float(i) * 0.92, 0),
            .rotation = quatFromAxisAngle(vec(0, 1, 0), angle),
            .motion_type = .dynamic,
            .friction = 0.8,
        });
    }

    const dt: f32 = 1.0 / 60.0;
    const slop: f32 = 0.02;
    var max_pen: f32 = 0;

    var frame: u32 = 0;
    while (frame < 600) : (frame += 1) { // 10 s, continuously awake
        try zimrphysics.step(&world, dt);
        _ = arena.reset(.retain_capacity);

        // After a short settle, the column must hold: ordered heights and no
        // adjacent overlap beyond the slop.
        if (frame > 60) {
            var k: u32 = 0;
            while (k + 1 < n_boxes) : (k += 1) {
                const y: f32 = world.bodies.data[ids[k].index()].com_pos[1];
                const y_above: f32 = world.bodies.data[ids[k + 1].index()].com_pos[1];
                const pen: f32 = (2.0 * half_y) - (y_above - y); // >0 = interpenetrating
                if (pen > max_pen) {
                    max_pen = pen;
                }
                try expect(y_above > y); // never sink past each other
            }
        }
    }

    // The settled stack must not interpenetrate beyond ~one slop (measured 0.013).
    try expect(max_pen < 1.5 * slop);

    // Every box still near its clean resting height (k -> ~0.45 + k*0.9). A stable
    // stack rests at the penetration slop, and that compression ACCUMULATES up the
    // column, so box k can sit up to ~k*slop below the ideal flush height. Allow that
    // (plus a small fixed margin); the ordering and max_pen asserts above already guard
    // against the real collapse bug (boxes sinking through each other / reordering).
    var k: u32 = 0;
    while (k < n_boxes) : (k += 1) {
        const y: f32 = world.bodies.data[ids[k].index()].com_pos[1];
        const expected: f32 = 0.45 + float(k) * 0.9;
        const tol: f32 = 0.05 + float(k) * 1.5 * slop;
        try expect(@abs(y - expected) < tol);
    }
}

test "hanging chain: off-COM rope links hold a heavy bob" {
    const gpa: std.mem.Allocator = std.testing.allocator;
    var world: zimrphysics.World = try zimrphysics.World.init(gpa, 64);
    defer world.deinit(gpa);
    world.settings.allow_sleeping = false;
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const link: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .capsule = .{ .half_height = 0.3, .radius = 0.22 },
    });
    const anchor_s: zimrphysics.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.25 } });
    const ball: zimrphysics.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.6 } });
    const top_y: f32 = 7.5;
    const gap: f32 = 0.85;
    const hh: f32 = 0.3;
    const two_r: f32 = 2.0 * 0.22;
    const anchor: zimrphysics.BodyHandle = try world.createBody(.{
        .shape = anchor_s,
        .position = vec(0, top_y, 0),
        .motion_type = .static,
    });
    const m: u32 = 8;
    var ids: [m]zimrphysics.BodyHandle = undefined;
    var prev: zimrphysics.BodyHandle = anchor;
    var prev_y: f32 = top_y;
    var i: u32 = 0;
    while (i < m) : (i += 1) {
        const cy: f32 = top_y - gap * float(i + 1);
        ids[i] = try world.createBody(.{
            .shape = link,
            .position = vec(0, cy, 0),
            .motion_type = .dynamic,
            .group_id = 9,
        });
        // cap-sphere centres, max = 2 radii (the demo's link). Off-COM anchors:
        // only stays bounded because the position solve re-derives the moment arm.
        try zimrphysics.createDistanceJoint(
            &world,
            prev,
            ids[i],
            vec(0, prev_y - hh, 0),
            vec(0, cy + hh, 0),
            0.0,
            two_r,
        );
        prev = ids[i];
        prev_y = cy;
    }
    const bob: zimrphysics.BodyHandle = try world.createBody(.{
        .shape = ball,
        .position = vec(0, prev_y - gap, 0),
        .motion_type = .dynamic,
        .density = 4000.0,
        .group_id = 9,
    });
    try zimrphysics.createDistanceJoint(
        &world,
        prev,
        bob,
        vec(0, prev_y - hh, 0),
        vec(0, prev_y - gap + 0.6, 0),
        0.0,
        two_r,
    );
    try world.setLinearVelocity(gpa, bob, vec(7.0, 0, 0)); // shove it sideways

    const dt: f32 = 1.0 / 60.0;
    var frame: u32 = 0;
    while (frame < 300) : (frame += 1) {
        try zimrphysics.step(&world, dt);
        _ = arena.reset(.retain_capacity);
        if (frame > 30) {
            // The off-COM rope must stay BOUNDED (the pre-fix bug ran the centre
            // spacing to 15x and dropped the chain to y=-90). Caps settle near
            // touching: centre spacing ~ 2r + 2*hh = 1.04, plus a little under load.
            var p: Vec = world.bodies.data[anchor.index()].com_pos;
            var k: u32 = 0;
            while (k < m) : (k += 1) {
                const c: Vec = world.bodies.data[ids[k].index()].com_pos;
                const d: Vec = c - p;
                const s: f32 = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
                try expect(s < 1.5); // bounded — no runaway
                p = c;
            }
            try expect(world.bodies.data[bob.index()].com_pos[1] > -4.0); // chain holds, doesn't fall
        }
    }
}
