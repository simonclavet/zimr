//! physics_audit — headless, deterministic probe of the zimrphysics engine.
//!
//! No GPU/window: it builds tiny worlds, steps them with `zp.step`, and asserts
//! on body state (rest heights, tunneling, NaN, restitution, raycast). Each
//! scenario prints PASS/FAIL + the measured numbers, so engine bugs surface as
//! data instead of needing a screenshot. This is the Phase-0 audit instrument
//! (and the regression harness every later solver fix is proven against).
//!
//! Build (native), root deps on `zp` + `zm`:
//!   zig build-exe --dep zp --dep zm -Mroot=tools/physics_audit.zig \
//!     --dep zm --dep build_options -Mzp=src/zimrphysics.zig \
//!     --dep build_options -Mzm=src/zimrmath.zig \
//!     -Mbuild_options=<assert_log=false>.zig

const std = @import("std");
const zp = @import("zp");
const zm = @import("zm");
const float = zm.float;

const bufPrint = std.fmt.bufPrint;
const Vec = zm.Vec;
const vec = zm.vec;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const length3 = zm.length3;

const dt: f32 = 1.0 / 60.0;

/// Floor top sits at y=0: a static box centred at y=-0.5 with half-height 0.5.
fn addFloor(world: *zp.World, gpa: std.mem.Allocator) !void {
    const floor_id: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(20, 0.5, 20),
        .convex_radius = 0.05,
    } });
    _ = try world.addBody(gpa, .{
        .shape = floor_id,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
    });
}

/// Step `frames` times with a fresh scratch arena each step (mirrors the demo).
fn simulate(world: *zp.World, gpa: std.mem.Allocator, frames: u32) !void {
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(world, scratch.allocator(), dt);
    }
}

fn comY(world: *const zp.World, idx: zp.BodyIndex) f32 {
    return world.bodies.data[idx].com_pos[1];
}

/// NaN-safe: a NaN never equals itself. Tunneling shows as a huge finite value
/// (caught by per-scenario bounds), so a NaN guard is all we need here.
fn finite3(v: Vec) bool {
    return v[0] == v[0] and v[1] == v[1] and v[2] == v[2];
}

const Report = struct {
    pass: u32 = 0,
    fail: u32 = 0,

    fn check(self: *Report, name: []const u8, ok: bool, detail: []const u8) void {
        const tag: []const u8 = if (ok) "PASS" else "FAIL";
        std.debug.print("  [{s}] {s: <26} {s}\n", .{ tag, name, detail });
        if (ok) {
            self.pass += 1;
        } else {
            self.fail += 1;
        }
    }
};

/// A single dynamic shape dropped onto the floor should settle at ~`expect_y`
/// (its half-height above the floor top), stay finite, and never sink below 0.
fn restScenario(
    rep: *Report,
    gpa: std.mem.Allocator,
    name: []const u8,
    shape_desc: zp.Shape,
    expect_y: f32,
) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const shape: zp.ShapeId = try world.shapes.add(gpa, shape_desc);
    const body: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = shape,
        .position = vec(0, 3.0, 0),
        .motion_type = .dynamic,
        .friction = 0.6,
    });
    try simulate(&world, gpa, 400);
    const y: f32 = comY(&world, body);
    const finite: bool = finite3(world.bodies.data[body].com_pos);
    const settled: bool = finite and @abs(y - expect_y) < 0.15 and y > -0.5;
    var buf: [96]u8 = undefined;
    const detail: []const u8 = bufPrint(
        &buf,
        "rest y={d:.3} (expect ~{d:.2})",
        .{ y, expect_y },
    ) catch "fmt";
    rep.check(name, settled, detail);
}

/// Three boxes stacked: they must come to rest in increasing height order with
/// none tunneling below the floor. This is the canonical box-box solver probe.
fn boxStackScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    var ids: [3]zp.BodyIndex = undefined;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        ids[i] = try world.addBody(gpa, .{
            .shape = box,
            .position = vec(0, 0.55 + float(i) * 1.02, 0),
            .motion_type = .dynamic,
            .friction = 0.8,
        });
    }
    try simulate(&world, gpa, 600);
    const y0: f32 = comY(&world, ids[0]);
    const y1: f32 = comY(&world, ids[1]);
    const y2: f32 = comY(&world, ids[2]);
    const finite: bool = finite3(world.bodies.data[ids[2]].com_pos);
    const no_tunnel: bool = y0 > 0.0 and y1 > 0.0 and y2 > 0.0;
    const ordered: bool = y1 > y0 + 0.3 and y2 > y1 + 0.3;
    const ok: bool = finite and no_tunnel and ordered;
    var buf: [128]u8 = undefined;
    const detail: []const u8 = bufPrint(
        &buf,
        "heights = {d:.2}, {d:.2}, {d:.2}",
        .{ y0, y1, y2 },
    ) catch "fmt";
    rep.check("box-stack-3", ok, detail);
}

/// A bouncy sphere (restitution 0.8) dropped from 3 m should rebound clearly.
fn bounceScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const body: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = sphere,
        .position = vec(0, 3.0, 0),
        .motion_type = .dynamic,
        .restitution = 0.8,
        .friction = 0.2,
    });
    var peak_after_contact: f32 = 0.0;
    var touched: bool = false;
    var f: u32 = 0;
    while (f < 240) : (f += 1) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(&world, scratch.allocator(), dt);
        const y: f32 = comY(&world, body);
        if (!touched and y < 0.6) {
            touched = true;
        }
        if (touched and y > peak_after_contact) {
            peak_after_contact = y;
        }
    }
    const ok: bool = touched and peak_after_contact > 1.0;
    var buf: [96]u8 = undefined;
    const detail: []const u8 = bufPrint(
        &buf,
        "rebound peak y={d:.2} (want >1.0)",
        .{peak_after_contact},
    ) catch "fmt";
    rep.check("restitution-bounce", ok, detail);
}

/// Cast a ray straight down at a resting sphere; the hit must exist, be finite,
/// and (the suspected bug) carry a 0..1 `fraction`, not a world distance.
fn raycastScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    _ = try world.addBody(gpa, .{
        .shape = sphere,
        .position = vec(0, 0.5, 0),
        .motion_type = .static,
    });
    try simulate(&world, gpa, 2); // refresh broadphase
    const hit: ?zp.RayHit = zp.castRay(&world, vec(0, 5, 0), vec(0, -1, 0), 10.0, .{});
    if (hit) |h| {
        // Ray from y=5 down, max 10; sphere top at y=1 => distance 4, fraction 0.4.
        const in_unit: bool = h.fraction >= 0.0 and h.fraction <= 1.0;
        const dist_ok: bool = @abs(h.distance - 4.0) < 0.05;
        const consistent: bool = @abs(h.fraction * 10.0 - h.distance) < 0.01;
        const ok: bool = in_unit and dist_ok and consistent;
        var buf: [112]u8 = undefined;
        const detail: []const u8 = bufPrint(
            &buf,
            "fraction={d:.3} distance={d:.3} (want 0.4 / 4.0)",
            .{ h.fraction, h.distance },
        ) catch "fmt";
        rep.check("raycast-fraction", ok, detail);
    } else {
        rep.check("raycast-fraction", false, "no hit on a sphere under the ray");
    }
}

/// A box dropped tilted 30° about Z must settle finite and rest on the floor
/// (COM in a sane band), not tunnel. Exercises non-axis-aligned axis selection.
fn boxTiltedScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    const body: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(0, 3.0, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), 0.52),
        .motion_type = .dynamic,
        .friction = 0.6,
    });
    try simulate(&world, gpa, 500);
    const y: f32 = comY(&world, body);
    const ok: bool = finite3(world.bodies.data[body].com_pos) and y > 0.2 and y < 1.3;
    var buf: [96]u8 = undefined;
    rep.check("box-tilted", ok, bufPrint(&buf, "rest y={d:.3} (band 0.2..1.3)", .{y}) catch "fmt");
}

/// A 3-2-1 box pyramid must settle without any box tunneling — the box-on-box
/// under load case the physics_pyramid example needs (boxes use SAT, not EPA).
fn boxPyramidScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 64);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    var ids: [6]zp.BodyIndex = undefined;
    var n: u32 = 0;
    var row: u32 = 0;
    while (row < 3) : (row += 1) {
        const count: u32 = 3 - row;
        var c: u32 = 0;
        while (c < count) : (c += 1) {
            const cx: f32 = (float(c) - float(count - 1) * 0.5) * 1.05;
            const cy: f32 = 0.55 + float(row) * 1.02;
            ids[n] = try world.addBody(gpa, .{
                .shape = box,
                .position = vec(cx, cy, 0),
                .motion_type = .dynamic,
                .friction = 0.9,
            });
            n += 1;
        }
    }
    try simulate(&world, gpa, 800);
    var all_ok: bool = true;
    var min_y: f32 = 1.0e9;
    for (ids[0..n]) |id| {
        const yy: f32 = comY(&world, id);
        if (yy < min_y) {
            min_y = yy;
        }
        if (!finite3(world.bodies.data[id].com_pos) or yy < 0.2) {
            all_ok = false;
        }
    }
    var buf: [96]u8 = undefined;
    rep.check("box-pyramid-321", all_ok, bufPrint(&buf, "lowest COM y={d:.3} (want >0.2)", .{min_y}) catch "fmt");
}

/// A settled box must STAY put: COM drift over the final 60 frames is tiny.
fn restStabilityScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    const body: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(0, 1.0, 0),
        .motion_type = .dynamic,
        .friction = 0.8,
    });
    try simulate(&world, gpa, 300);
    const y_before: f32 = comY(&world, body);
    try simulate(&world, gpa, 60);
    const drift: f32 = @abs(comY(&world, body) - y_before);
    var buf: [96]u8 = undefined;
    rep.check("box-rest-stable", drift < 0.02, bufPrint(&buf, "drift/60f = {d:.4} (want <0.02)", .{drift}) catch "fmt");
}

/// Two spheres linked by a max-distance rope: the lower one, pulled by gravity,
/// must hang at ~the rope length below the static upper one (constraint solver).
fn distanceConstraintScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    const top: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = sphere,
        .position = vec(0, 5, 0),
        .motion_type = .static,
    });
    const bot: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = sphere,
        .position = vec(0, 4, 0),
        .motion_type = .dynamic,
    });
    const rope_len: f32 = 2.0;
    try zp.addDistanceConstraint(&world, gpa, top, bot, vec(0, 5, 0), vec(0, 4, 0), 0.0, rope_len);
    try simulate(&world, gpa, 400);
    const d: f32 = length3(world.bodies.data[top].com_pos - world.bodies.data[bot].com_pos);
    const ok: bool = d <= rope_len + 0.1 and d > rope_len - 0.5;
    var buf: [96]u8 = undefined;
    rep.check("distance-constraint", ok, bufPrint(&buf, "rope dist={d:.3} (cap {d:.1})", .{ d, rope_len }) catch "fmt");
}

/// queryAabb must return only the bodies whose AABB overlaps the query box.
fn queryAabbScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    _ = try world.addBody(gpa, .{ .shape = sphere, .position = vec(0, 0, 0), .motion_type = .static });
    _ = try world.addBody(gpa, .{ .shape = sphere, .position = vec(10, 0, 0), .motion_type = .static });
    try simulate(&world, gpa, 2);
    var hits: std.ArrayListUnmanaged(zp.BodyIndex) = .empty;
    try world.broadphase.queryAabb(gpa, .{ .min = vec(-1, -1, -1), .max = vec(1, 1, 1) }, &hits);
    var buf: [96]u8 = undefined;
    const detail: []const u8 = bufPrint(&buf, "found {d} in region (want 1)", .{hits.items.len}) catch "fmt";
    rep.check("queryAabb", hits.items.len == 1, detail);
}

/// World.deinit smoke: build, step, free — exercises every field access in the
/// new deinit (a wrong field name fails to compile; arena frees are no-ops here).
fn worldDeinitScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    _ = try world.addBody(gpa, .{ .shape = box, .position = vec(0, 2, 0), .motion_type = .dynamic });
    try simulate(&world, gpa, 30);
    world.deinit(gpa);
    rep.check("world-deinit", true, "build+step+deinit, no crash");
}

/// Point-constraint swing bridge (Phase 4): a row of dynamic planks linked
/// end-to-end with `addPointConstraint`, both ends pinned to static posts. A
/// point constraint holds its two bodies coincident at the world anchor, so
/// after the bridge settles every joint gap must stay ~0 while the middle plank
/// sags below the post line (it hangs) yet never falls through. Proves point
/// constraints hold a chain under gravity.
fn pointBridgeScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 32);
    const post: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.2, 0.2, 0.5),
        .convex_radius = 0.05,
    } });
    const plank: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.1, 0.4),
        .convex_radius = 0.05,
    } });
    const span_y: f32 = 5.0;
    const left: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = post,
        .position = vec(-3.0, span_y, 0),
        .motion_type = .static,
    });
    const right: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = post,
        .position = vec(3.0, span_y, 0),
        .motion_type = .static,
    });
    const n: u32 = 5;
    var planks: [n]zp.BodyIndex = undefined;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const px: f32 = -2.0 + float(i) * 1.0;
        planks[i] = try world.addBody(gpa, .{
            .shape = plank,
            .position = vec(px, span_y, 0),
            .motion_type = .dynamic,
            .friction = 0.5,
        });
    }
    // Joints sit halfway between consecutive bodies; post-to-plank anchors are at
    // the post edge so the chain hangs from the two fixed ends.
    try zp.addPointConstraint(&world, gpa, left, planks[0], vec(-2.5, span_y, 0));
    i = 0;
    while (i + 1 < n) : (i += 1) {
        const mid_x: f32 = -2.0 + float(i) * 1.0 + 0.5;
        try zp.addPointConstraint(&world, gpa, planks[i], planks[i + 1], vec(mid_x, span_y, 0));
    }
    try zp.addPointConstraint(&world, gpa, planks[n - 1], right, vec(2.5, span_y, 0));

    try simulate(&world, gpa, 400);

    // Every linked neighbour (post->plank and plank->plank) starts 1.0 apart and
    // the point joints + rigid planks must hold that spacing while the chain sags.
    var max_span_err: f32 = 0.0;
    var all_finite: bool = true;
    i = 0;
    while (i < n) : (i += 1) {
        all_finite = all_finite and finite3(world.bodies.data[planks[i]].com_pos);
    }
    const left_span: f32 = length3(world.bodies.data[planks[0]].com_pos - world.bodies.data[left].com_pos);
    const right_span: f32 = length3(world.bodies.data[planks[n - 1]].com_pos - world.bodies.data[right].com_pos);
    max_span_err = @max(@abs(left_span - 1.0), @abs(right_span - 1.0));
    i = 0;
    while (i + 1 < n) : (i += 1) {
        const d: f32 = length3(world.bodies.data[planks[i]].com_pos - world.bodies.data[planks[i + 1]].com_pos);
        max_span_err = @max(max_span_err, @abs(d - 1.0));
    }
    const mid_y: f32 = world.bodies.data[planks[n / 2]].com_pos[1];
    const sagged: bool = mid_y < span_y - 0.05 and mid_y > 0.0;
    const ok: bool = all_finite and max_span_err < 0.15 and sagged;
    var buf: [96]u8 = undefined;
    rep.check("point-bridge", ok, bufPrint(
        &buf,
        "mid y={d:.2} sag, max span err={d:.3}",
        .{ mid_y, max_span_err },
    ) catch "fmt");
}

/// Hinge + velocity motor (Phase 4): a dynamic cylinder pinned to a static hub by
/// a hinge about Z, driven by a velocity motor. The static side has zero angular
/// velocity, so the wheel's spin about Z must climb to ~the motor target. Proves
/// `addHingeConstraint` + `MotorSettings.velocity` actually drive a joint.
fn hingeMotorScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    world.settings.allow_sleeping = false; // isolate the motor; a parked wheel must not doze off
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.2 } });
    const wheel_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .cylinder = .{
        .half_height = 0.15,
        .radius = 0.6,
        .convex_radius = 0.05,
    } });
    const hub_idx: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub,
        .position = vec(0, 3, 0),
        .motion_type = .static,
    });
    // Lay the cylinder on its side so its round face spins in the XY plane (axis Z).
    const wheel: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = wheel_shape,
        .position = vec(0, 3, 0),
        .rotation = quatFromAxisAngle(vec(1, 0, 0), 0.5 * zm.pi),
        .motion_type = .dynamic,
        .density = 200.0,
        .gravity_factor = 0.0, // isolate the motor; no gravity sag on the joint
    });
    const target: f32 = 6.0; // rad/s
    try zp.addHingeConstraint(&world, gpa, hub_idx, wheel, .{
        .anchor = vec(0, 3, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = target, .max_force = 200000.0 },
    });
    try simulate(&world, gpa, 120);
    const spin_z: f32 = world.getAngularVelocity(wheel)[2];
    const finite: bool = finite3(world.getAngularVelocity(wheel));
    const ok: bool = finite and spin_z > target - 0.5 and spin_z < target + 0.5;
    var buf: [96]u8 = undefined;
    rep.check("hinge-motor", ok, bufPrint(
        &buf,
        "spin_z={d:.2} rad/s (target {d:.1})",
        .{ spin_z, target },
    ) catch "fmt");
}

/// Fixed/weld constraint (Phase 4): two boxes welded with `addFixedConstraint`
/// fall as one rigid body. Their COM-to-COM offset must stay ~constant (rigid),
/// both must rest on the floor, and neither tunnels. Proves the weld locks both
/// relative position and orientation.
fn gearChainScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Two gears about Z: gear A velocity-motored, gear B free, coupled by addGearConstraint
    // (pure velocity coupling, refs -1). B must counter-rotate at the ratio and stay finite.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.settings.allow_sleeping = false;
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    const disk: zp.ShapeId = try world.shapes.add(gpa, .{ .cylinder = .{
        .half_height = 0.15,
        .radius = 0.6,
        .convex_radius = 0.04,
    } });
    const hubA: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub,
        .position = vec(-0.7, 3, 0),
        .motion_type = .static,
    });
    const gearA: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = disk,
        .position = vec(-0.7, 3, 0),
        .motion_type = .dynamic,
        .density = 150.0,
        .gravity_factor = 0.0,
        .group_id = 991,
    });
    const hubB: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub,
        .position = vec(0.7, 3, 0),
        .motion_type = .static,
    });
    const gearB: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = disk,
        .position = vec(0.7, 3, 0),
        .motion_type = .dynamic,
        .density = 150.0,
        .gravity_factor = 0.0,
        .group_id = 992,
    });
    const target: f32 = 4.0;
    try zp.addHingeConstraint(&world, gpa, hubA, gearA, .{
        .anchor = vec(-0.7, 3, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = target, .max_force = 1.0e6 },
    });
    try zp.addHingeConstraint(&world, gpa, hubB, gearB, .{ .anchor = vec(0.7, 3, 0), .axis = vec(0, 0, 1) });
    const ratio: f32 = 2.0;
    try zp.addGearConstraint(&world, gpa, gearA, gearB, vec(0, 0, 1), vec(0, 0, 1), ratio, -1, -1);
    try simulate(&world, gpa, 300);
    const wa: f32 = world.getAngularVelocity(gearA)[2];
    const wb: f32 = world.getAngularVelocity(gearB)[2];
    const finite: bool = finite3(world.getAngularVelocity(gearB)) and finite3(world.bodies.data[gearB].com_pos);
    const expected_wb: f32 = -wa / ratio;
    const ok: bool = finite and @abs(wb - expected_wb) < 0.3 and wa > target - 0.5;
    var buf: [110]u8 = undefined;
    rep.check("gear-chain", ok, bufPrint(
        &buf,
        "wA={d:.2} wB={d:.2} (expect {d:.2}), finite={}",
        .{ wa, wb, expected_wb, finite },
    ) catch "fmt");
}

fn rackPinionScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Pinion (hinge about Z, velocity-motored) coupled to a rack (slider along X) by
    // addRackAndPinionConstraint (pure velocity coupling, refs -1). Rack must track at
    // v = w / ratio and stay finite.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.settings.allow_sleeping = false;
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    const r_pin: f32 = 0.6;
    const disk: zp.ShapeId = try world.shapes.add(gpa, .{ .cylinder = .{
        .half_height = 0.15,
        .radius = r_pin,
        .convex_radius = 0.04,
    } });
    const bar: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(4.0, 0.15, 0.15),
        .convex_radius = 0.02,
    } });
    const pin_hub: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub,
        .position = vec(0, 3, 0),
        .motion_type = .static,
        .group_id = 880,
    });
    const pinion: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = disk,
        .position = vec(0, 3, 0),
        .motion_type = .dynamic,
        .density = 150.0,
        .gravity_factor = 0.0,
        .group_id = 880,
    });
    const rail: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub,
        .position = vec(0, 2.2, 0),
        .motion_type = .static,
        .group_id = 880,
    });
    const rack: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = bar,
        .position = vec(0, 2.2, 0),
        .motion_type = .dynamic,
        .density = 100.0,
        .gravity_factor = 0.0,
        .group_id = 880,
    });
    const target: f32 = 3.0;
    try zp.addHingeConstraint(&world, gpa, pin_hub, pinion, .{
        .anchor = vec(0, 3, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = target, .max_force = 1.0e6 },
    });
    try zp.addSliderConstraint(&world, gpa, rail, rack, .{ .anchor = vec(0, 2.2, 0), .axis = vec(1, 0, 0) });
    const ratio: f32 = 1.0 / r_pin;
    try zp.addRackAndPinionConstraint(&world, gpa, pinion, rack, vec(0, 0, 1), vec(1, 0, 0), ratio, -1, -1);
    try simulate(&world, gpa, 200);
    const wp: f32 = world.getAngularVelocity(pinion)[2];
    const vr: f32 = world.motion[rack].lin_vel[0];
    const finite: bool = finite3(world.motion[rack].lin_vel) and finite3(world.bodies.data[rack].com_pos);
    const expected_vr: f32 = wp / ratio;
    const ok: bool = finite and @abs(vr - expected_vr) < 0.2 and wp > target - 0.5;
    var buf: [110]u8 = undefined;
    rep.check("rack-pinion", ok, bufPrint(
        &buf,
        "w={d:.2} v_rack={d:.2} (expect {d:.2}), finite={}",
        .{ wp, vr, expected_vr, finite },
    ) catch "fmt");
}

fn pulleyScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Rigid rope over two fixed points: a heavy box and a light box hang from the
    // ends. The heavy box must descend (to the floor) and haul the light box up,
    // with total rope length |a-fa| + |b-fb| conserved (Jolt PulleyConstraintTest).
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const ground: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(12, 0.5, 12),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = ground, .position = vec(0, -0.5, 0), .motion_type = .static });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.02,
    } });
    const pa: Vec = vec(-2.5, 5.0, 0);
    const pb: Vec = vec(2.5, 3.5, 0);
    const a: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = pa,
        .motion_type = .dynamic,
        .density = 1500.0,
    });
    const b: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = pb,
        .motion_type = .dynamic,
        .density = 300.0,
    });
    const bp_a: Vec = pa + vec(0, 0.5, 0);
    const bp_b: Vec = pb + vec(0, 0.5, 0);
    const fa: Vec = vec(-2.5, 8.85, 0);
    const fb: Vec = vec(2.5, 8.85, 0);
    try zp.addPulleyConstraint(&world, gpa, a, b, bp_a, fa, bp_b, fb, 1.0, -1.0, -1.0);
    const l0: f32 = length3(bp_a - fa) + length3(bp_b - fb);
    const ya0: f32 = comY(&world, a);
    const yb0: f32 = comY(&world, b);
    try simulate(&world, gpa, 200);
    const yaf: f32 = comY(&world, a);
    const ybf: f32 = comY(&world, b);
    const waf: Vec = world.bodies.data[a].com_pos + vec(0, 0.5, 0);
    const wbf: Vec = world.bodies.data[b].com_pos + vec(0, 0.5, 0);
    const lf: f32 = length3(waf - fa) + length3(wbf - fb);
    const finite: bool = finite3(world.bodies.data[a].com_pos) and finite3(world.bodies.data[b].com_pos);
    const ok: bool = finite and (yaf < ya0 - 1.0) and (ybf > yb0 + 1.0) and @abs(lf - l0) < 0.05;
    var buf: [110]u8 = undefined;
    rep.check("pulley", ok, bufPrint(
        &buf,
        "heavy {d:.2}->{d:.2} light {d:.2}->{d:.2} ropeL {d:.2} (L0 {d:.2})",
        .{ ya0, yaf, yb0, ybf, lf, l0 },
    ) catch "fmt");
}

fn pathScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A frictionless bead constrained to a valley-shaped Hermite path (in the XY plane)
    // must (a) stay exactly on the path plane (z == 0), (b) slide down to the bottom, and
    // (c) conserve energy — swing back up to near its start height on the far side.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const anchor: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.1 } });
    const a: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = anchor,
        .position = vec(0, 0, 0),
        .motion_type = .static,
    });
    const bead: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    const origin: Vec = vec(0, 3, 0);
    const p0: Vec = vec(-4, 2, 0);
    const p1: Vec = vec(0, 0, 0);
    const p2: Vec = vec(4, 2, 0);
    const b: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = bead,
        .position = origin + p0,
        .motion_type = .dynamic,
        .density = 500.0,
    });
    const nrm: Vec = vec(0, 0, 1);
    const pts = [_]zp.HermitePoint{
        .{ .position = p0, .tangent = vec(4, -2, 0), .normal = nrm },
        .{ .position = p1, .tangent = vec(4, 0, 0), .normal = nrm },
        .{ .position = p2, .tangent = vec(4, 2, 0), .normal = nrm },
    };
    _ = try zp.addPathConstraint(&world, gpa, a, b, &pts, false, origin, zm.quat_identity, 0.0, .free);

    const y0: f32 = comY(&world, b);
    var max_z: f32 = 0;
    var min_y: f32 = y0;
    var max_y_after_bottom: f32 = 0;
    var reached_bottom: bool = false;
    var f: u32 = 0;
    while (f < 200) : (f += 1) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(&world, scratch.allocator(), dt);
        const p: Vec = world.bodies.data[b].com_pos;
        if (@abs(p[2]) > max_z) max_z = @abs(p[2]);
        if (p[1] < min_y) min_y = p[1];
        if (p[1] < 3.3) reached_bottom = true;
        if (reached_bottom and p[0] > 1.0 and p[1] > max_y_after_bottom) max_y_after_bottom = p[1];
    }
    const p: Vec = world.bodies.data[b].com_pos;
    const finite: bool = finite3(p) and finite3(world.motion[b].lin_vel);
    // on-path plane, reached bottom, swung back up (energy conserved), bounded.
    const ok: bool = finite and max_z < 0.02 and reached_bottom and
        max_y_after_bottom > 4.4 and @abs(p[0]) < 4.5;
    var buf: [110]u8 = undefined;
    rep.check("path", ok, bufPrint(
        &buf,
        "maxZ={d:.4} minY={d:.2} swingBackY={d:.2} (start {d:.2})",
        .{ max_z, min_y, max_y_after_bottom, y0 },
    ) catch "fmt");
}

fn newtonsCradleScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Two equal balls as planar pendulums, restitution 1: the lifted ball swings in and
    // must transfer (near) all its velocity to the resting ball, stopping itself dead —
    // momentum + energy conservation through the contact (Jolt-style elastic collision).
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    world.settings.min_velocity_for_restitution = 0.02;
    const r: f32 = 0.5;
    const y_top: f32 = 6.0;
    const y_rest: f32 = 3.0;
    const rope_len: f32 = y_top - y_rest;
    const beam_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(4, 0.2, 0.2),
        .convex_radius = 0.02,
    } });
    const beam: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = beam_shape,
        .position = vec(1, y_top + 0.2, 0),
        .motion_type = .static,
    });
    const ball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = r } });
    const th: f32 = 0.8727; // 50 degrees in radians
    const p0: Vec = vec(0 - rope_len * @sin(th), y_top - rope_len * @cos(th), 0);
    const p1: Vec = vec(2 * r, y_rest, 0);
    const b0: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = ball_shape,
        .position = p0,
        .motion_type = .dynamic,
        .density = 1000.0,
        .restitution = 1.0,
        .friction = 0.0,
        .linear_damping = 0.0,
        .angular_damping = 0.0,
        .allowed_dofs = zp.AllowedDofs.plane_2d,
    });
    const b1: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = ball_shape,
        .position = p1,
        .motion_type = .dynamic,
        .density = 1000.0,
        .restitution = 1.0,
        .friction = 0.0,
        .linear_damping = 0.0,
        .angular_damping = 0.0,
        .allowed_dofs = zp.AllowedDofs.plane_2d,
    });
    try zp.addDistanceConstraint(&world, gpa, beam, b0, vec(0, y_top, 0), p0, rope_len, rope_len);
    try zp.addDistanceConstraint(&world, gpa, beam, b1, vec(2 * r, y_top, 0), p1, rope_len, rope_len);

    var impact_speed: f32 = 0;
    var peak_v1: f32 = 0;
    var v0_at_peak: f32 = 0;
    var transferred: bool = false;
    var f: u32 = 0;
    while (f < 90) : (f += 1) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(&world, scratch.allocator(), dt);
        const v0: f32 = world.motion[b0].lin_vel[0];
        const v1: f32 = world.motion[b1].lin_vel[0];
        if (v1 < 0.5 and v0 > impact_speed) impact_speed = v0; // swing-in speed
        if (v1 > peak_v1) {
            peak_v1 = v1;
            v0_at_peak = v0;
        }
        if (v1 > 2.0) transferred = true;
    }
    const finite: bool = finite3(world.motion[b0].lin_vel) and finite3(world.motion[b1].lin_vel);
    // ball1 took (near) all the speed; ball0 (near) stopped; no energy gained.
    const ok: bool = finite and transferred and peak_v1 > 0.85 * impact_speed and
        @abs(v0_at_peak) < 0.4 and peak_v1 < impact_speed * 1.05;
    var buf: [110]u8 = undefined;
    rep.check("newtons-cradle", ok, bufPrint(
        &buf,
        "impact={d:.2} ball1_out={d:.2} ball0_left={d:.2}",
        .{ impact_speed, peak_v1, v0_at_peak },
    ) catch "fmt");
}

fn wreckingBallScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A heavy ball on a rigid chain swings into a free-standing brick wall: the wall must
    // stand on its own (small displacement before impact) then be demolished (large mean
    // displacement after), with no NaN — a pendulum + stacking + mass-ratio showcase.
    var world: zp.World = try zp.World.init(gpa, 128);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(20, 0.5, 20),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = floor_shape, .position = vec(0, -0.5, 0), .motion_type = .static });
    const hx: f32 = 0.4;
    const hy: f32 = 0.3;
    const hz: f32 = 0.6;
    const brick: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(hx, hy, hz),
        .convex_radius = 0.01,
    } });
    var bricks: [60]zp.BodyIndex = undefined;
    var startpos: [60]Vec = undefined;
    var nb: usize = 0;
    var ix: usize = 0;
    while (ix < 2) : (ix += 1) {
        var iz: usize = 0;
        while (iz < 3) : (iz += 1) {
            var iy: usize = 0;
            while (iy < 5) : (iy += 1) {
                const p: Vec = vec(
                    2.6 + float(ix) * (2 * hx),
                    hy + float(iy) * (2 * hy),
                    (float(iz) - 1.0) * (2 * hz),
                );
                bricks[nb] = try world.addBody(gpa, .{
                    .shape = brick,
                    .position = p,
                    .motion_type = .dynamic,
                    .density = 400.0,
                    .friction = 0.7,
                    .restitution = 0.0,
                });
                startpos[nb] = p;
                nb += 1;
            }
        }
    }
    const pivot_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 0.3, 0.3),
        .convex_radius = 0.02,
    } });
    const pivot: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = pivot_shape,
        .position = vec(0, 9, 0),
        .motion_type = .static,
    });
    const rope_len: f32 = 6.0;
    const ball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 1.0 } });
    const th: f32 = 1.222;
    const bp: Vec = vec(0 - rope_len * @sin(th), 9 - rope_len * @cos(th), 0);
    const ball: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = ball_shape,
        .position = bp,
        .motion_type = .dynamic,
        .density = 5000.0,
        .friction = 0.5,
        .restitution = 0.1,
    });
    try zp.addDistanceConstraint(&world, gpa, pivot, ball, vec(0, 9, 0), bp, rope_len, rope_len);

    var settle_disp: f32 = 0; // mean displacement just before impact (step 60)
    var max_ball_x: f32 = -100;
    var f: u32 = 0;
    while (f < 150) : (f += 1) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(&world, scratch.allocator(), dt);
        const bx: f32 = world.bodies.data[ball].com_pos[0];
        if (bx > max_ball_x) {
            max_ball_x = bx;
        }
        if (f == 60) {
            var d: f32 = 0;
            for (0..nb) |k| {
                d += length3(world.bodies.data[bricks[k]].com_pos - startpos[k]);
            }
            settle_disp = d / float(nb);
        }
    }
    var final_disp: f32 = 0;
    var finite: bool = true;
    for (0..nb) |k| {
        const p: Vec = world.bodies.data[bricks[k]].com_pos;
        if (!finite3(p)) {
            finite = false;
        }
        final_disp += length3(p - startpos[k]);
    }
    final_disp /= float(nb);
    // wall stood before impact, was demolished after, ball swung through, all finite.
    const ok: bool = finite and settle_disp < 0.3 and final_disp > 0.8 and max_ball_x > 3.0;
    var buf: [110]u8 = undefined;
    rep.check("wrecking-ball", ok, bufPrint(
        &buf,
        "settleDisp={d:.2} finalDisp={d:.2} ballMaxX={d:.2}",
        .{ settle_disp, final_disp, max_ball_x },
    ) catch "fmt");
}

fn plinkoScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Galton board: balls are released one at a time from the top centre and cascade through
    // a staggered field of frictionless pegs into bins. Must build a centered, peaked
    // distribution with every ball reaching the bins (no field-jams) and no NaN.
    var world: zp.World = try zp.World.init(gpa, 256);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const dx: f32 = 1.4;
    const dy: f32 = 1.1;
    const half: f32 = 6.5;
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(half + 1, 0.5, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = floor_shape, .position = vec(0, -0.5, 0), .motion_type = .static });
    const wall_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 7, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = wall_shape, .position = vec(-half, 6, 0), .motion_type = .static });
    _ = try world.addBody(gpa, .{ .shape = wall_shape, .position = vec(half, 6, 0), .motion_type = .static });
    const peg_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.25 } });
    var row: usize = 0;
    while (row < 6) : (row += 1) {
        const py: f32 = 11.0 - float(row) * dy;
        const odd: bool = (row % 2 == 1);
        const ncols: usize = if (odd) 8 else 9;
        var col: usize = 0;
        while (col < ncols) : (col += 1) {
            var px: f32 = (float(col) - 4.0) * dx;
            if (odd) {
                px += dx / 2.0;
            }
            if (@abs(px) > half - 0.4) {
                continue;
            }
            _ = try world.addBody(gpa, .{
                .shape = peg_shape,
                .position = vec(px, py, 0),
                .motion_type = .static,
                .friction = 0.0,
                .restitution = 0.30,
            });
        }
    }
    const div_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.08, 1.3, 2),
        .convex_radius = 0.01,
    } });
    var b: i32 = -4;
    while (b <= 5) : (b += 1) {
        const dxpos: f32 = (float(b) - 0.5) * dx;
        if (@abs(dxpos) > half) {
            continue;
        }
        _ = try world.addBody(gpa, .{ .shape = div_shape, .position = vec(dxpos, 1.3, 0), .motion_type = .static });
    }
    const ball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.22 } });

    // Spawn one ball every 24 steps (matching the demo), up to 36, with deterministic jitter.
    var balls: [44]zp.BodyIndex = undefined;
    var nb: usize = 0;
    var seed: u32 = 777;
    var step: usize = 0;
    while (step < 1500) : (step += 1) {
        if (nb < 40 and step % 18 == 0) {
            seed = seed *% 1664525 +% 1013904223;
            const j: f32 = (float(seed % 1000) / 1000.0 - 0.5) * 0.7;
            balls[nb] = try world.addBody(gpa, .{
                .shape = ball_shape,
                .position = vec(j, 12.5, 0),
                .motion_type = .dynamic,
                .density = 800.0,
                .friction = 0.0,
                .restitution = 0.30,
            });
            nb += 1;
        }
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try zp.step(&world, scratch.allocator(), dt);
    }

    var binned: usize = 0;
    var jam: usize = 0;
    var center: i32 = 0;
    var edge: i32 = 0;
    var mean_x: f32 = 0;
    for (0..nb) |kk| {
        const p: Vec = world.bodies.data[balls[kk]].com_pos;
        if (!finite3(p)) {
            jam += 1;
            continue;
        }
        if (p[1] > 4.5) {
            jam += 1; // stuck up in the peg field
            continue;
        }
        binned += 1;
        mean_x += p[0];
        if (@abs(p[0]) <= dx * 1.5) {
            center += 1;
        }
        if (@abs(p[0]) >= dx * 2.5) {
            edge += 1;
        }
    }
    if (binned > 0) {
        mean_x /= float(binned);
    }
    // every ball reached the bins, distribution centered + peaked.
    const ok: bool = jam == 0 and binned == nb and @abs(mean_x) < 1.2 and center > edge;
    var buf: [110]u8 = undefined;
    rep.check("plinko", ok, bufPrint(
        &buf,
        "binned={d}/{d} jam={d} center={d} edge={d} meanX={d:.2}",
        .{ binned, nb, jam, center, edge, mean_x },
    ) catch "fmt");
}

fn rubeGoldbergScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Wave-J flagship chain reaction: a CCD marble rolls down a ramp, topples six
    // dominoes, the last domino shoves a heavy ball off a ledge, and the ball funnels
    // down an angled chute into a catch bin. Gravity-driven end to end. Asserts the
    // whole chain completes: every domino falls, the ball lands in the bin, no NaN.
    var world: zp.World = try zp.World.init(gpa, 256);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;

    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(7, 0.5, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = floor_shape,
        .position = vec(3, -0.5, 0),
        .motion_type = .static,
        .friction = 0.5,
    });

    const ramp_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3, 0.2, 1.5),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = ramp_shape,
        .position = vec(-0.65, 1.71, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), -0.4887),
        .motion_type = .static,
        .friction = 0.15,
    });

    const marble_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.32 } });
    _ = try world.addBody(gpa, .{
        .shape = marble_shape,
        .position = vec(-2.8, 3.5, 0),
        .motion_type = .dynamic,
        .density = 1200,
        .friction = 0.3,
        .restitution = 0.05,
        .motion_quality = .linear_cast,
    });

    const dom_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.08, 1.0, 0.5),
        .convex_radius = 0.01,
    } });
    var doms: [6]zp.BodyIndex = undefined;
    for (0..6) |i| {
        const x: f32 = 3.3 + float(i) * 1.2;
        doms[i] = try world.addBody(gpa, .{
            .shape = dom_shape,
            .position = vec(x, 1.0, 0),
            .motion_type = .dynamic,
            .density = 120,
            .friction = 0.4,
            .restitution = 0.0,
        });
    }

    const tball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    const tball: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = tball_shape,
        .position = vec(9.9, 0.35, 0),
        .motion_type = .dynamic,
        .density = 800,
        .friction = 0.3,
        .restitution = 0.1,
        .motion_quality = .linear_cast,
    });

    const chute_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.0, 0.15, 0.8),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = chute_shape,
        .position = vec(12.2, -1.7, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), -0.32),
        .motion_type = .static,
        .friction = 0.25,
    });

    const bin_floor: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(2.5, 0.3, 1),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = bin_floor,
        .position = vec(16, -3.5, 0),
        .motion_type = .static,
        .friction = 0.6,
    });
    const bin_wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.2, 1.2, 1),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = bin_wall, .position = vec(18.3, -2.6, 0), .motion_type = .static });

    try simulate(&world, gpa, 900);

    var fallen: u32 = 0;
    for (doms) |d| {
        const up_y: f32 = zm.rotate(world.bodies.data[d].rot, vec(0, 1, 0))[1];
        if (up_y < 0.5) {
            fallen += 1;
        }
    }
    const bp: Vec = world.bodies.data[tball].com_pos;
    const in_bin: bool = finite3(bp) and bp[0] > 15.0 and bp[0] < 18.3 and bp[1] > -3.3 and bp[1] < -2.5;
    const ok: bool = fallen == 6 and in_bin;
    var buf: [110]u8 = undefined;
    rep.check("rube-goldberg", ok, bufPrint(
        &buf,
        "dominoes={d}/6 ballX={d:.2} ballY={d:.2} inBin={}",
        .{ fallen, bp[0], bp[1], in_bin },
    ) catch "fmt");
}

fn hingeOffsetAnchorScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A door hinged at its EDGE (offset anchor) must swing freely like a pendulum.
    // Guards against the false "offset-anchor lockup" (that was a colliding test post,
    // not a solver bug). A locked door would stay near up_y = 1; a free one swings past.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const post_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const post: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = post_shape,
        .position = vec(0, 5, 0.5), // clear of the door (offset in z) + shared group
        .motion_type = .static,
        .group_id = 9,
    });
    const door_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(1.5, 0.1, 0.4),
        .convex_radius = 0.01,
    } });
    const door: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = door_shape,
        .position = vec(1.5, 5, 0),
        .motion_type = .dynamic,
        .density = 200,
        .group_id = 9,
    });
    try zp.addHingeConstraint(&world, gpa, post, door, .{ .anchor = vec(0, 5, 0), .axis = vec(0, 0, 1) });
    var min_up: f32 = 1.0;
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        try simulate(&world, gpa, 1);
        const up_y: f32 = zm.rotate(world.bodies.data[door].rot, vec(0, 1, 0))[1];
        if (up_y < min_up) {
            min_up = up_y;
        }
    }
    const ok: bool = min_up < 0.0 and finite3(world.bodies.data[door].com_pos);
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "minDoorUpY={d:.2} (lock would hold ~1.0)", .{min_up}) catch "fmt";
    rep.check("hinge-offset-anchor", ok, msg);
}

fn sliderPerpHoldScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A +Y slider under symmetric perpendicular gravity stress must hold BOTH
    // perpendicular axes (no leak, no asymmetry). Guards the slider dual-axis lock.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(3.0, -9.81, 3.0);
    world.settings.allow_sleeping = false;
    const base_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 0.3, 0.3),
        .convex_radius = 0.02,
    } });
    const base: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = base_shape,
        .position = vec(0, 0, 0),
        .motion_type = .static,
        .group_id = 5,
    });
    const plat_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.8, 0.2, 0.8),
        .convex_radius = 0.02,
    } });
    const plat: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = plat_shape,
        .position = vec(0, 2, 0),
        .motion_type = .dynamic,
        .density = 100,
        .group_id = 5,
    });
    try zp.addSliderConstraint(&world, gpa, base, plat, .{
        .anchor = vec(0, 0, 0),
        .axis = vec(0, 1, 0),
        .has_limits = true,
        .limit_min = -0.3,
        .limit_max = 0.3,
    });
    try simulate(&world, gpa, 360);
    const p: Vec = world.bodies.data[plat].com_pos;
    const ok: bool = finite3(p) and @abs(p[0]) < 0.01 and @abs(p[2]) < 0.01;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "|X|={d:.4} |Z|={d:.4} (want ~0)", .{ @abs(p[0]), @abs(p[2]) }) catch "fmt";
    rep.check("slider-perp-hold", ok, msg);
}

fn rackReciprocationScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Reversing a velocity-motored pinion under rack-pinion coupling must reciprocate
    // cleanly through exact rest — no deadlock, no NaN. Guards the motor/coupling path.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const grp: u16 = 8;
    const r_pin: f32 = 0.5;
    const hub_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const pin_hub: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub_shape,
        .position = vec(0, 3, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const pin_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(r_pin, 0.11, 0.3),
        .convex_radius = 0.02,
    } });
    const pinion: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = pin_shape,
        .position = vec(0, 3, 0),
        .motion_type = .dynamic,
        .density = 120,
        .group_id = grp,
    });
    try zp.addHingeConstraint(&world, gpa, pin_hub, pinion, .{
        .anchor = vec(0, 3, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = 1.3, .max_force = 1.0e6 },
    });
    const rail_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const rack_rail: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = rail_shape,
        .position = vec(0, 1, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const rack_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(4.0, 0.18, 0.25),
        .convex_radius = 0.02,
    } });
    const rack: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = rack_shape,
        .position = vec(0, 1, 0),
        .motion_type = .dynamic,
        .density = 80,
        .group_id = grp,
    });
    try zp.addSliderConstraint(&world, gpa, rack_rail, rack, .{
        .anchor = vec(0, 1, 0),
        .axis = vec(1, 0, 0),
    });
    try zp.addRackAndPinionConstraint(&world, gpa, pinion, rack, vec(0, 0, 1), vec(1, 0, 0), 1.0 / r_pin, -1, -1);
    var max_x: f32 = -1.0e9;
    var min_x: f32 = 1.0e9;
    var step: usize = 0;
    var ok: bool = true;
    while (step < 700) : (step += 1) {
        if (step % 120 == 0 and step > 0) {
            const tv = world.constraints.items[0].motor.target_velocity;
            world.constraints.items[0].motor.target_velocity = -tv;
        }
        try simulate(&world, gpa, 1);
        if (!finite3(world.bodies.data[rack].com_pos)) {
            ok = false;
            break;
        }
        const rx: f32 = world.bodies.data[rack].com_pos[0];
        if (rx > max_x) {
            max_x = rx;
        }
        if (rx < min_x) {
            min_x = rx;
        }
    }
    ok = ok and (max_x - min_x) > 0.8;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "rackTravel={d:.2} finite (no NaN/deadlock)", .{max_x - min_x}) catch "fmt";
    rep.check("rack-reciprocation", ok, msg);
}

fn gearDriftRefsScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // Gear coupling with the drift-correction refs SET must stay stable at high spin
    // (wB = -wA, no blow-up). Guards the optional drift path that was feared unstable.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, 0, 0);
    world.settings.allow_sleeping = false;
    const grp: u16 = 8;
    const hub_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const gear_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.2),
        .convex_radius = 0.02,
    } });
    const hub_a: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub_shape,
        .position = vec(-1, 3, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const gear_a: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = gear_shape,
        .position = vec(-1, 3, 0),
        .motion_type = .dynamic,
        .density = 100,
        .group_id = grp,
    });
    try zp.addHingeConstraint(&world, gpa, hub_a, gear_a, .{
        .anchor = vec(-1, 3, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = 40.0, .max_force = 1.0e6 },
    });
    const hub_b: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub_shape,
        .position = vec(1, 3, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const gear_b: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = gear_shape,
        .position = vec(1, 3, 0),
        .motion_type = .dynamic,
        .density = 100,
        .group_id = grp,
    });
    try zp.addHingeConstraint(&world, gpa, hub_b, gear_b, .{
        .anchor = vec(1, 3, 0),
        .axis = vec(0, 0, 1),
    });
    try zp.addGearConstraint(&world, gpa, gear_a, gear_b, vec(0, 0, 1), vec(0, 0, 1), 1.0, 0, 1);
    try simulate(&world, gpa, 900);
    const wa: f32 = world.getAngularVelocity(gear_a)[2];
    const wb: f32 = world.getAngularVelocity(gear_b)[2];
    const stable: bool = finite3(world.getAngularVelocity(gear_a)) and finite3(world.getAngularVelocity(gear_b));
    const ok: bool = stable and @abs(wb + wa) < 0.5 and @abs(wa) > 35.0;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "wA={d:.2} wB={d:.2} (want wB=-wA, stable)", .{ wa, wb }) catch "fmt";
    rep.check("gear-drift-refs", ok, msg);
}

fn swingTwistMotorScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // The swing-twist twist velocity motor must drive the bone toward its target.
    // Guards that the ragdoll-joint motors are wired and functional.
    var world: zp.World = try zp.World.init(gpa, 16);
    world.gravity = vec(0, 0, 0);
    world.settings.allow_sleeping = false;
    const anch_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const anchor: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = anch_shape,
        .position = vec(0, 3, 0),
        .motion_type = .static,
        .group_id = 6,
    });
    const bone_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(1.0, 0.2, 0.2),
        .convex_radius = 0.02,
    } });
    const bone: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = bone_shape,
        .position = vec(0, 3, 0),
        .motion_type = .dynamic,
        .density = 100,
        .group_id = 6,
    });
    try zp.addSwingTwistConstraint(&world, gpa, anchor, bone, .{
        .anchor = vec(0, 3, 0),
        .twist_axis = vec(1, 0, 0),
        .plane_axis = vec(0, 1, 0),
        .normal_half_cone = 1.0,
        .plane_half_cone = 1.0,
        .twist_min = -3.0,
        .twist_max = 3.0,
        .twist_motor = .{ .min_torque = -1.0e6, .max_torque = 1.0e6 },
    });
    const con: *zp.Constraint = &world.constraints.items[0];
    zp.swingTwistSetTwistMotorState(con, .velocity);
    zp.swingTwistSetTargetAngularVelocityCS(con, vec(3.0, 0, 0));
    var max_w: f32 = 0.0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try simulate(&world, gpa, 1);
        const wx: f32 = @abs(world.getAngularVelocity(bone)[0]);
        if (wx > max_w) {
            max_w = wx;
        }
    }
    const ok: bool = max_w > 2.5 and finite3(world.bodies.data[bone].com_pos);
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "maxTwistAngVel={d:.2} (target 3.0)", .{max_w}) catch "fmt";
    rep.check("swingtwist-motor", ok, msg);
}

fn tumblerScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A motored hexagonal drum (compound) must tumble its load AND contain it:
    // all balls stay inside, the drum holds its spin, nothing goes non-finite.
    var world: zp.World = try zp.World.init(gpa, 64);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const center: Vec = vec(0, 3, 0);
    const radius: f32 = 2.5;
    const wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.12, 1.5, 1.2),
        .convex_radius = 0.02,
    } });
    var children: [6]zp.CompoundChild = undefined;
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        const th: f32 = float(k) * zm.pi / 3.0;
        children[k] = .{
            .shape = wall,
            .local_pos = vec(radius * @cos(th), radius * @sin(th), 0),
            .local_rot = quatFromAxisAngle(vec(0, 0, 1), th),
        };
    }
    const drum_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &children);
    const hub_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const hub: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = hub_shape,
        .position = center,
        .motion_type = .static,
        .group_id = 4,
    });
    const drum: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = drum_shape,
        .position = center,
        .motion_type = .dynamic,
        .density = 200,
        .friction = 0.8,
        .group_id = 4,
    });
    try zp.addHingeConstraint(&world, gpa, hub, drum, .{
        .anchor = center,
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = 1.3, .max_force = 1.0e7 },
    });
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    var balls: [15]zp.BodyIndex = undefined;
    var n: usize = 0;
    var gy: f32 = 0;
    while (gy < 3) : (gy += 1) {
        var gx: f32 = 0;
        while (gx < 5) : (gx += 1) {
            if (n >= 15) {
                break;
            }
            balls[n] = try world.addBody(gpa, .{
                .shape = ball,
                .position = center + vec((gx - 2) * 0.7, (gy - 1) * 0.7 - 0.5, 0),
                .motion_type = .dynamic,
                .density = 500,
                .friction = 0.5,
                .restitution = 0.1,
            });
            n += 1;
        }
    }
    try simulate(&world, gpa, 720);
    var inside: usize = 0;
    for (balls[0..n]) |b| {
        const p: Vec = world.bodies.data[b].com_pos;
        if (finite3(p) and length3(p - center) < radius + 0.2) {
            inside += 1;
        }
    }
    const w: f32 = world.getAngularVelocity(drum)[2];
    const ok: bool = inside == n and w > 1.0;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "inside={d}/{d} drumW={d:.2}", .{ inside, n, w }) catch "fmt";
    rep.check("tumbler", ok, msg);
}

const AuditConveyorCtx = struct { belt: zp.BodyIndex, speed: f32 };

fn auditConveyorContact(
    cptr: ?*anyopaque,
    _: *const zp.World,
    a: zp.BodyIndex,
    b: zp.BodyIndex,
    _: u32,
    _: *const zp.Manifold,
    settings: *zp.ContactSettings,
) void {
    const cc: *const AuditConveyorCtx = @ptrCast(@alignCast(cptr.?));
    if (a == cc.belt) {
        settings.relative_linear_surface_velocity = vec(-cc.speed, 0, 0);
    } else if (b == cc.belt) {
        settings.relative_linear_surface_velocity = vec(cc.speed, 0, 0);
    }
}

fn conveyorScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A flat belt (contact surface velocity) must carry a stream of marbles into a walled
    // bin AND contain them: all reach the bin, none escape (the cascade's fly-off failure
    // is excluded by the left back-stop + walled bin). Guards the conveyor mechanic.
    var world: zp.World = try zp.World.init(gpa, 64);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const belt_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(5, 0.15, 1.3),
        .convex_radius = 0.02,
    } });
    const belt: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = belt_shape,
        .position = vec(0, 2, 0),
        .motion_type = .static,
        .friction = 1.0,
    });
    var cctx: AuditConveyorCtx = .{ .belt = belt, .speed = 5.0 };
    world.contact_listener = .{
        .context = &cctx,
        .on_contact_added = auditConveyorContact,
        .on_contact_persisted = auditConveyorContact,
    };
    const lstop: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.2, 1.5, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = lstop, .position = vec(-5.2, 3.0, 0), .motion_type = .static });
    const bin_floor: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(2.25, 0.3, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = bin_floor,
        .position = vec(7.25, -1.3, 0),
        .motion_type = .static,
        .friction = 0.6,
    });
    const bin_wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.15, 1.25, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{ .shape = bin_wall, .position = vec(5.0, 0.25, 0), .motion_type = .static });
    _ = try world.addBody(gpa, .{ .shape = bin_wall, .position = vec(9.5, 0.25, 0), .motion_type = .static });
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.28 } });
    var marbles: [15]zp.BodyIndex = undefined;
    var nm: usize = 0;
    var step: usize = 0;
    while (step < 1600) : (step += 1) {
        if (nm < 15 and step % 55 == 0) {
            marbles[nm] = try world.addBody(gpa, .{
                .shape = ball,
                .position = vec(-4.2, 2.7, 0),
                .motion_type = .dynamic,
                .density = 600.0,
                .friction = 0.9,
                .restitution = 0.05,
            });
            nm += 1;
        }
        try simulate(&world, gpa, 1);
    }
    var in_bin: usize = 0;
    var lost: usize = 0;
    for (marbles[0..nm]) |m| {
        const p: Vec = world.bodies.data[m].com_pos;
        if (!finite3(p) or @abs(p[2]) > 3 or p[1] < -5) {
            lost += 1;
        } else if (p[0] > 5.0 and p[0] < 9.6 and p[1] > -2.0 and p[1] < 1.6) {
            in_bin += 1;
        }
    }
    const ok: bool = lost == 0 and in_bin == nm;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "inBin={d}/{d} lost={d}", .{ in_bin, nm, lost }) catch "fmt";
    rep.check("conveyor", ok, msg);
}

fn clockworkScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A motor-driven 5-gear train (alternating radii) whose last gear drives a rack; the
    // drive reverses periodically. Guards the gear-train + rack-and-pinion + motor combo:
    // every gear holds w0*r0/r_i, the rack reciprocates, nothing goes non-finite.
    var world: zp.World = try zp.World.init(gpa, 32);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const grp: u16 = 7;
    const radii = [_]f32{ 0.6, 1.3, 0.5, 1.1, 0.7 };
    const w0: f32 = 2.5;
    const gy: f32 = 3.0;
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    var gears: [5]zp.BodyIndex = undefined;
    var cx: f32 = -3.55;
    var prev_idx: zp.BodyIndex = 0;
    var prev_r: f32 = 0;
    var i: usize = 0;
    while (i < radii.len) : (i += 1) {
        const r: f32 = radii[i];
        if (i > 0) {
            cx += prev_r + r;
        }
        const disk: zp.ShapeId = try world.shapes.add(gpa, .{
            .cylinder = .{ .half_height = 0.18, .radius = r, .convex_radius = 0.03 },
        });
        const hub_idx: zp.BodyIndex = try world.addBody(gpa, .{
            .shape = hub,
            .position = vec(cx, gy, 0),
            .motion_type = .static,
            .group_id = grp,
        });
        const gear_idx: zp.BodyIndex = try world.addBody(gpa, .{
            .shape = disk,
            .position = vec(cx, gy, 0),
            .motion_type = .dynamic,
            .density = 100.0,
            .group_id = grp,
        });
        gears[i] = gear_idx;
        const motor: zp.MotorSettings = if (i == 0)
            .{ .mode = .velocity, .target_velocity = w0, .max_force = 1.0e7 }
        else
            .{};
        try zp.addHingeConstraint(&world, gpa, hub_idx, gear_idx, .{
            .anchor = vec(cx, gy, 0),
            .axis = vec(0, 0, 1),
            .motor = motor,
        });
        if (i > 0) {
            try zp.addGearConstraint(&world, gpa, prev_idx, gear_idx, vec(0, 0, 1), vec(0, 0, 1), r / prev_r, -1, -1);
        }
        prev_idx = gear_idx;
        prev_r = r;
    }
    const r_last: f32 = radii[radii.len - 1];
    const rack_x: f32 = cx + r_last + 0.1; // tangent to the right edge of the last gear
    const rack_home: f32 = gy;
    const rail: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const rack_rail: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = rail,
        .position = vec(rack_x, rack_home, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const rack_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.18, 1.5, 0.25),
        .convex_radius = 0.02,
    } });
    const rack: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = rack_shape,
        .position = vec(rack_x, rack_home, 0),
        .motion_type = .dynamic,
        .density = 60.0,
        .group_id = grp,
    });
    try zp.addSliderConstraint(&world, gpa, rack_rail, rack, .{
        .anchor = vec(rack_x, rack_home, 0),
        .axis = vec(0, 1, 0),
    });
    try zp.addRackAndPinionConstraint(
        &world,
        gpa,
        gears[gears.len - 1],
        rack,
        vec(0, 0, 1),
        vec(0, 1, 0),
        1.0 / r_last,
        -1,
        -1,
    );
    var rmax: f32 = -1.0e9;
    var rmin: f32 = 1.0e9;
    var step: usize = 0;
    while (step < 900) : (step += 1) {
        const ry: f32 = world.bodies.data[rack].com_pos[1];
        if (ry > rack_home + 1.0 and world.constraints.items[0].motor.target_velocity > 0) {
            world.constraints.items[0].motor.target_velocity = -w0;
        }
        if (ry < rack_home - 1.0 and world.constraints.items[0].motor.target_velocity < 0) {
            world.constraints.items[0].motor.target_velocity = w0;
        }
        try simulate(&world, gpa, 1);
        const ry2: f32 = world.bodies.data[rack].com_pos[1];
        if (ry2 > rmax) {
            rmax = ry2;
        }
        if (ry2 < rmin) {
            rmin = ry2;
        }
    }
    var all_finite: bool = finite3(world.bodies.data[rack].com_pos);
    for (gears) |g| {
        if (!finite3(world.getAngularVelocity(g))) {
            all_finite = false;
        }
    }
    const w_mid: f32 = world.getAngularVelocity(gears[2])[2]; // r=0.5 -> fastest gear
    const ok: bool = all_finite and (rmax - rmin) > 1.5 and @abs(w_mid) > 2.5;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "rackTravel={d:.2} wFast={d:.2}", .{ rmax - rmin, w_mid }) catch "fmt";
    rep.check("clockwork", ok, msg);
}

fn stirrerObjShape(world: *zp.World, gpa: std.mem.Allocator, kind: usize) !zp.ShapeId {
    return switch (kind) {
        0 => try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } }),
        1 => try world.shapes.add(gpa, .{ .box = .{ .half_extent = vec(0.24, 0.24, 0.24), .convex_radius = 0.12 } }),
        2 => try world.shapes.add(gpa, .{ .cylinder = .{
            .half_height = 0.28,
            .radius = 0.26,
            .convex_radius = 0.12,
        } }),
        else => try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.26, .radius = 0.22 } }),
    };
}

fn stirrerScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A swing-twist TWIST-motor-driven rotor spinning about Y inside a walled bowl must
    // churn its load AND contain it: all balls stay in, the rotor holds its spin, nothing
    // goes non-finite. Guards the powered swing-twist joint (used passively in ragdoll).
    var world: zp.World = try zp.World.init(gpa, 128);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const grp: u16 = 3;
    const center: Vec = vec(0, 1.15, 0);
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.2, 0.3, 3.2),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = floor_shape,
        .position = vec(0, 0.5, 0),
        .motion_type = .static,
        .friction = 0.5,
    });
    const r_wall: f32 = 2.7;
    const seg_count: usize = 32;
    const seg_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.35, 1.6, 0.15),
        .convex_radius = 0.02,
    } });
    var seg: usize = 0;
    while (seg < seg_count) : (seg += 1) {
        const phi: f32 = float(seg) * (2.0 * zm.pi / float(seg_count));
        _ = try world.addBody(gpa, .{
            .shape = seg_shape,
            .position = vec(r_wall * zm.cosRad(phi), 1.5, r_wall * zm.sinRad(phi)),
            .rotation = quatFromAxisAngle(vec(0, 1, 0), -(phi + zm.pi / 2.0)),
            .motion_type = .static,
        });
    }
    const anchor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.12, 0.12, 0.12),
        .convex_radius = 0.01,
    } });
    const anchor: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = anchor_shape,
        .position = center,
        .motion_type = .static,
        .group_id = grp,
    });
    const blade_x: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(2.3, 0.32, 0.34),
        .convex_radius = 0.02,
    } });
    const blade_z: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.34, 0.32, 2.3),
        .convex_radius = 0.02,
    } });
    const rotor_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
        .{ .shape = blade_x, .local_pos = vec(0, 0, 0), .local_rot = quatFromAxisAngle(vec(0, 1, 0), 0) },
        .{ .shape = blade_z, .local_pos = vec(0, 0, 0), .local_rot = quatFromAxisAngle(vec(0, 1, 0), 0) },
    });
    const rotor: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = rotor_shape,
        .position = center,
        .motion_type = .dynamic,
        .density = 120.0,
        .group_id = grp,
    });
    try zp.addSwingTwistConstraint(&world, gpa, anchor, rotor, .{
        .anchor = center,
        .twist_axis = vec(0, 1, 0),
        .plane_axis = vec(1, 0, 0),
        .normal_half_cone = 0.05,
        .plane_half_cone = 0.05,
        .twist_min = -1000.0,
        .twist_max = 1000.0,
        .twist_motor = .{ .min_torque = -1.0e7, .max_torque = 1.0e7 },
    });
    const con: *zp.Constraint = &world.constraints.items[world.constraints.items.len - 1];
    zp.swingTwistSetTwistMotorState(con, .velocity);
    zp.swingTwistSetTargetAngularVelocityCS(con, vec(1.5, 0, 0));
    var balls: [36]zp.BodyIndex = undefined;
    var n: usize = 0;
    var layer: usize = 0;
    while (layer < 3 and n < 36) : (layer += 1) {
        const oy: f32 = 2.2 + float(layer) * 0.75;
        var ix: usize = 0;
        while (ix < 5 and n < 36) : (ix += 1) {
            var iz: usize = 0;
            while (iz < 3 and n < 36) : (iz += 1) {
                const ox: f32 = -1.8 + float(ix) * 0.9;
                const oz: f32 = -1.6 + float(iz) * 1.6;
                const shape: zp.ShapeId = try stirrerObjShape(&world, gpa, n % 4);
                balls[n] = try world.addBody(gpa, .{
                    .shape = shape,
                    .position = vec(ox, oy, oz),
                    .motion_type = .dynamic,
                    .density = 400.0,
                    .friction = 0.4,
                    .restitution = 0.1,
                });
                n += 1;
            }
        }
    }
    try simulate(&world, gpa, 900);
    var inside: usize = 0;
    var spd: f32 = 0;
    for (balls[0..n]) |b| {
        const p: Vec = world.bodies.data[b].com_pos;
        const rad: f32 = length3(vec(p[0], 0, p[2]));
        if (finite3(p) and rad < r_wall + 0.4 and p[1] > -1.0 and p[1] < 6.0) {
            inside += 1;
        }
        spd += zm.length3(world.getLinearVelocity(b));
    }
    const w: f32 = world.getAngularVelocity(rotor)[1];
    const avg_speed: f32 = spd / float(n);
    // The big rotor must both CONTAIN the load and actually STEER it (avg speed stays high).
    const ok: bool = inside == n and w > 1.0 and avg_speed > 1.0;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(
        &buf,
        "inside={d}/{d} rotorWy={d:.2} avgSpeed={d:.2}",
        .{ inside, n, w, avg_speed },
    ) catch "fmt";
    rep.check("stirrer", ok, msg);
}

const AudRagPart = struct { hh: f32, r: f32, pos: Vec, horiz: bool };

fn buildAuditRagdoll(
    world: *zp.World,
    gpa: std.mem.Allocator,
    off: Vec,
    grp: u16,
    bodies: *[12]zp.BodyIndex,
) !void {
    const parts = [12]AudRagPart{
        .{ .hh = 0.15, .r = 0.10, .pos = vec(0, 1.15, 0), .horiz = true },
        .{ .hh = 0.15, .r = 0.10, .pos = vec(0, 1.35, 0), .horiz = true },
        .{ .hh = 0.15, .r = 0.10, .pos = vec(0, 1.55, 0), .horiz = true },
        .{ .hh = 0.075, .r = 0.10, .pos = vec(0, 1.825, 0), .horiz = false },
        .{ .hh = 0.15, .r = 0.06, .pos = vec(-0.425, 1.55, 0), .horiz = true },
        .{ .hh = 0.15, .r = 0.06, .pos = vec(0.425, 1.55, 0), .horiz = true },
        .{ .hh = 0.15, .r = 0.05, .pos = vec(-0.8, 1.55, 0), .horiz = true },
        .{ .hh = 0.15, .r = 0.05, .pos = vec(0.8, 1.55, 0), .horiz = true },
        .{ .hh = 0.2, .r = 0.075, .pos = vec(-0.15, 0.8, 0), .horiz = false },
        .{ .hh = 0.2, .r = 0.075, .pos = vec(0.15, 0.8, 0), .horiz = false },
        .{ .hh = 0.2, .r = 0.06, .pos = vec(-0.15, 0.3, 0), .horiz = false },
        .{ .hh = 0.2, .r = 0.06, .pos = vec(0.15, 0.3, 0), .horiz = false },
    };
    const z90: zm.Quat = quatFromAxisAngle(vec(0, 0, 1), 1.5707964); // 90 deg, capsule horizontal
    const idq: zm.Quat = quatFromAxisAngle(vec(0, 0, 1), 0);
    for (parts, 0..) |pt, i| {
        const shape: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = pt.hh, .radius = pt.r } });
        bodies[i] = try world.addBody(gpa, .{
            .shape = shape,
            .position = pt.pos + off,
            .rotation = if (pt.horiz) z90 else idq,
            .motion_type = .dynamic,
            .density = 1000.0,
            .friction = 0.5,
            .group_id = grp,
        });
    }
    const par = [11]usize{ 0, 1, 2, 2, 2, 4, 5, 0, 0, 8, 9 };
    const chi = [11]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const piv = [11]Vec{
        vec(0, 1.25, 0),      vec(0, 1.45, 0),     vec(0, 1.65, 0),
        vec(-0.225, 1.55, 0), vec(0.225, 1.55, 0), vec(-0.65, 1.55, 0),
        vec(0.65, 1.55, 0),   vec(-0.15, 1.05, 0), vec(0.15, 1.05, 0),
        vec(-0.15, 0.55, 0),  vec(0.15, 0.55, 0),
    };
    const twa = [11]Vec{
        vec(0, 1, 0),  vec(0, 1, 0),  vec(0, 1, 0),  vec(-1, 0, 0),
        vec(1, 0, 0),  vec(-1, 0, 0), vec(1, 0, 0),  vec(0, -1, 0),
        vec(0, -1, 0), vec(0, -1, 0), vec(0, -1, 0),
    };
    const twd = [11]f32{ 5, 5, 90, 45, 45, 45, 45, 45, 45, 45, 45 };
    const nrd = [11]f32{ 10, 10, 45, 90, 90, 0, 0, 45, 45, 0, 0 };
    const pld = [11]f32{ 10, 10, 45, 45, 45, 90, 90, 45, 45, 60, 60 };
    for (0..11) |k| {
        try zp.addSwingTwistConstraint(world, gpa, bodies[par[k]], bodies[chi[k]], .{
            .anchor = piv[k] + off,
            .twist_axis = twa[k],
            .plane_axis = vec(0, 0, 1),
            .swing_type = .cone,
            .normal_half_cone = nrd[k] * zm.pi / 180.0,
            .plane_half_cone = pld[k] * zm.pi / 180.0,
            .twist_min = -twd[k] * zm.pi / 180.0,
            .twist_max = twd[k] * zm.pi / 180.0,
        });
    }
}

fn ragdollScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    // A Jolt-standard humanoid ragdoll dropped with a shove must stay finite, hold its joints,
    // and settle flat on the ground (no joint explosion / NaN). Guards the 12-bone swing-twist
    // skeleton used by the ragdoll_pile scene.
    var world: zp.World = try zp.World.init(gpa, 64);
    world.gravity = vec(0, -9.81, 0);
    world.settings.allow_sleeping = false;
    const ground: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(20, 0.5, 20),
        .convex_radius = 0.02,
    } });
    _ = try world.addBody(gpa, .{
        .shape = ground,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
        .friction = 0.7,
    });
    var bodies: [12]zp.BodyIndex = undefined;
    try buildAuditRagdoll(&world, gpa, vec(0, 1.0, 0), 30, &bodies);
    for (bodies) |b| {
        try world.setLinearVelocity(gpa, b, vec(1.5, 0, 0.5));
    }
    try simulate(&world, gpa, 450);
    var fin: usize = 0;
    var spd: f32 = 0;
    var maxy: f32 = -1.0e9;
    for (bodies) |b| {
        const pp: Vec = world.bodies.data[b].com_pos;
        if (finite3(pp)) {
            fin += 1;
        }
        spd += length3(world.getLinearVelocity(b));
        if (pp[1] > maxy) {
            maxy = pp[1];
        }
    }
    const avg: f32 = spd / 12.0;
    const ok: bool = fin == 12 and avg < 1.0 and maxy < 1.0;
    var buf: [96]u8 = undefined;
    const msg: []const u8 = bufPrint(
        &buf,
        "finite={d}/12 avgSpd={d:.2} maxY={d:.2}",
        .{ fin, avg, maxy },
    ) catch "fmt";
    rep.check("ragdoll_pile", ok, msg);
}

fn fixedWeldScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    try addFloor(&world, gpa);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    const a: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(-0.55, 3, 0),
        .motion_type = .dynamic,
    });
    const b: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(0.55, 3, 0),
        .motion_type = .dynamic,
    });
    const start_offset: f32 = length3(world.bodies.data[a].com_pos - world.bodies.data[b].com_pos);
    try zp.addFixedConstraint(&world, gpa, a, b);
    try simulate(&world, gpa, 400);
    const end_offset: f32 = length3(world.bodies.data[a].com_pos - world.bodies.data[b].com_pos);
    const ya: f32 = world.bodies.data[a].com_pos[1];
    const yb: f32 = world.bodies.data[b].com_pos[1];
    const rigid: bool = @abs(end_offset - start_offset) < 0.1;
    const rested: bool = ya > 0.2 and ya < 0.9 and yb > 0.2 and yb < 0.9;
    const finite: bool = finite3(world.bodies.data[a].com_pos) and finite3(world.bodies.data[b].com_pos);
    const ok: bool = rigid and rested and finite;
    var buf: [96]u8 = undefined;
    rep.check("fixed-weld", ok, bufPrint(
        &buf,
        "offset {d:.2}->{d:.2}, y={d:.2}/{d:.2}",
        .{ start_offset, end_offset, ya, yb },
    ) catch "fmt");
}

/// Friction ramp (Jolt FrictionTest): a 23° static ramp; a near-frictionless box
/// must slide much farther downhill than a high-friction box that grips.
fn frictionRampScenario(rep: *Report, gpa: std.mem.Allocator) !void {
    var world: zp.World = try zp.World.init(gpa, 16);
    const angle: f32 = 0.40; // ~23°, below the grippy box's friction so it holds
    const ramp: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(8, 0.5, 8),
        .convex_radius = 0.05,
    } });
    _ = try world.addBody(gpa, .{
        .shape = ramp,
        .position = vec(0, 0, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), angle),
        .motion_type = .static,
        .friction = 1.0,
    });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.4, 0.4, 0.4),
        .convex_radius = 0.05,
    } });
    const slippery: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(0, 1.0, -1.5),
        .motion_type = .dynamic,
        .friction = 0.02,
    });
    const grippy: zp.BodyIndex = try world.addBody(gpa, .{
        .shape = box,
        .position = vec(0, 1.0, 1.5),
        .motion_type = .dynamic,
        .friction = 1.0,
    });
    const sx0: f32 = world.bodies.data[slippery].com_pos[0];
    const gx0: f32 = world.bodies.data[grippy].com_pos[0];
    try simulate(&world, gpa, 400);
    const slip: f32 = @abs(world.bodies.data[slippery].com_pos[0] - sx0);
    const grip: f32 = @abs(world.bodies.data[grippy].com_pos[0] - gx0);
    const ok: bool = finite3(world.bodies.data[slippery].com_pos) and
        finite3(world.bodies.data[grippy].com_pos) and slip > grip + 0.5;
    var buf: [96]u8 = undefined;
    rep.check("friction-ramp", ok, bufPrint(&buf, "slip slide={d:.2} vs grip={d:.2}", .{ slip, grip }) catch "fmt");
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: std.mem.Allocator = arena.allocator();

    std.debug.print("\n=== zimrphysics headless audit ===\n", .{});
    var rep: Report = .{};

    try restScenario(&rep, gpa, "rest-sphere", .{ .sphere = .{ .radius = 0.5 } }, 0.5);
    try restScenario(&rep, gpa, "rest-box", .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } }, 0.5);
    try restScenario(&rep, gpa, "rest-capsule", .{ .capsule = .{
        .half_height = 0.5,
        .radius = 0.35,
    } }, 0.85);
    try restScenario(&rep, gpa, "rest-cylinder", .{ .cylinder = .{
        .half_height = 0.5,
        .radius = 0.45,
        .convex_radius = 0.05,
    } }, 0.5);
    try boxStackScenario(&rep, gpa);
    try bounceScenario(&rep, gpa);
    try raycastScenario(&rep, gpa);
    try boxTiltedScenario(&rep, gpa);
    try boxPyramidScenario(&rep, gpa);
    try restStabilityScenario(&rep, gpa);
    try distanceConstraintScenario(&rep, gpa);
    try pointBridgeScenario(&rep, gpa);
    try hingeMotorScenario(&rep, gpa);
    try gearChainScenario(&rep, gpa);
    try rackPinionScenario(&rep, gpa);
    try pulleyScenario(&rep, gpa);
    try pathScenario(&rep, gpa);
    try newtonsCradleScenario(&rep, gpa);
    try wreckingBallScenario(&rep, gpa);
    try plinkoScenario(&rep, gpa);
    try rubeGoldbergScenario(&rep, gpa);
    try hingeOffsetAnchorScenario(&rep, gpa);
    try sliderPerpHoldScenario(&rep, gpa);
    try rackReciprocationScenario(&rep, gpa);
    try gearDriftRefsScenario(&rep, gpa);
    try swingTwistMotorScenario(&rep, gpa);
    try tumblerScenario(&rep, gpa);
    try conveyorScenario(&rep, gpa);
    try clockworkScenario(&rep, gpa);
    try stirrerScenario(&rep, gpa);
    try ragdollScenario(&rep, gpa);
    try fixedWeldScenario(&rep, gpa);
    try queryAabbScenario(&rep, gpa);
    try frictionRampScenario(&rep, gpa);
    try worldDeinitScenario(&rep, gpa);

    std.debug.print("\n  total: {d} passed, {d} failed\n\n", .{ rep.pass, rep.fail });
    if (rep.fail > 0) {
        std.process.exit(1);
    }
}
