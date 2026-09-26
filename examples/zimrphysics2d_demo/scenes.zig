//! scenes.zig — box2d sample ports for the zimrphysics2d testbed.
//!
//! Each scene is a `build(*World)` that constructs a world out of the Options-struct
//! spawn helpers below; a few carry an `update(*World)` hook for per-frame behaviour
//! (wind, spawners). The registry `list` is grouped by box2d category. Adding a
//! sample is one build fn + one list entry — the renderer/UI/drag handle the rest.
//! See src/notes/box2d_samples_plan.md for the full 137-sample triage.

const z = @import("zimr");
const zm = @import("zm");
const assertUnreachable = zm.assertUnreachable;
const float = zm.float;
const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const render = @import("render.zig");

const phys = z.zimrphysics2d;

const Vec2 = zm.Vec2;
const Rot2 = zm.Rot2;
const Transform2 = zm.Transform2;
const BodyHandle = phys.BodyHandle;
const MotionType = phys.MotionType;
const Color = zm.Color;

const pi = zm.pi;
const rotateVec2 = zm.rotateVec2;
const clamp = zm.clamp;

// Lab-mode palette (collision-query visualisers).
const c_amber: Color = .{ .r = 250, .g = 204, .b = 21, .a = 255 };
const c_red: Color = .{ .r = 248, .g = 113, .b = 113, .a = 255 };
const c_green: Color = .{ .r = 134, .g = 239, .b = 172, .a = 255 };
const c_dim: Color = .{ .r = 90, .g = 96, .b = 110, .a = 255 };

/// Optional per-scene camera framing. box2d samples each set their own camera
/// center + zoom; without this every scene shares one fixed view and large- or
/// tiny-scale samples fall off-screen. `null` = the demo default ({0,4.5}, 34 px/m).
pub const CamHint = struct {
    target: Vec2 = .{ 0, 4.5 },
    ppm: f32 = 34,
};

/// Scratch state a scene may carry across frames (handles created in build, used in update).
/// Generic slots keep the Scene API uniform without a typed payload per scene.
pub const SceneState = struct {
    body: [4]BodyHandle = undefined,
    joint: [8]phys.JointHandle = undefined,
    u: [4]u32 = .{ 0, 0, 0, 0 },
    f: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Abstract player input for the interactive scenes, mapped by the host from both the
/// on-screen button cluster (phone) and the arrow keys + space (keyboard). A scene reads
/// whichever fields it cares about. Held state: true for every frame the control is down.
pub const SceneInput = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    action: bool = false,
};

pub const Scene = struct {
    category: []const u8,
    name: []const u8,
    /// Stateless build (most scenes). Provide exactly one of `build` or `build_s`.
    build: ?*const fn (world: *phys.World) anyerror!void = null,
    /// Stateful build: may stash handles/counters in `st` for `update_s`.
    build_s: ?*const fn (world: *phys.World, st: *SceneState) anyerror!void = null,
    update: ?*const fn (world: *phys.World) void = null,
    update_s: ?*const fn (world: *phys.World, st: *SceneState) void = null,
    /// Interactive per-frame hook: like `update_s` but also receives player input. Runs once
    /// per frame (not per sub-step) so impulse actions like jump fire once per press.
    control: ?*const fn (world: *phys.World, st: *SceneState, in: SceneInput) void = null,
    /// Collision-lab visualiser: queries the world and draws, with the pointer as a probe.
    lab: ?*const fn (ctx: *render.LabCtx) void = null,
    /// Drive the world snapshot/restore demo: the host captures a checkpoint a little way in
    /// and restores it on a loop, so the world visibly jumps back. box2d Determinism|SnapShot.
    auto_snapshot: bool = false,
    cam: ?CamHint = null,
};

// ================================================================================
// Spawn helpers (designated-literal Options structs as the API).
// ================================================================================

const Body = struct {
    x: f32 = 0,
    y: f32 = 0,
    motion: MotionType = .dynamic,
    angle: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    w: f32 = 0, // angular velocity
    bullet: bool = false,
    gravity_scale: f32 = 1,
    lock_x: bool = false, // freeze world-x translation
    lock_y: bool = false, // freeze world-y translation
    lock_rot: bool = false, // freeze rotation
    no_sleep: bool = false, // keep awake even at rest (motor-driven bodies need this)
};

fn addBody(world: *phys.World, b: Body) !BodyHandle {
    return phys.createBody(world, .{
        .motion_type = b.motion,
        .position = .{ b.x, b.y },
        .rotation = Rot2.fromAngle(b.angle),
        .linear_velocity = .{ b.vx, b.vy },
        .angular_velocity = b.w,
        .gravity_scale = b.gravity_scale,
        .enable_sleep = !b.no_sleep,
        .motion_quality = if (b.bullet) .linear_cast else .discrete,
        .allowed_dofs = .{
            .translation_x = !b.lock_x,
            .translation_y = !b.lock_y,
            .rotation_z = !b.lock_rot,
        },
    });
}

const Box = struct {
    hw: f32 = 0.5,
    hh: f32 = 0.5,
    round: f32 = 0,
    density: f32 = 1,
    friction: f32 = 0.6,
    restitution: f32 = 0,
    tangent_speed: f32 = 0,
    rolling: f32 = 0,
    hit_events: bool = false,
    filter: phys.Filter = .{},
};

fn attachBox(
    world: *phys.World,
    h: BodyHandle,
    s: Box,
) !void {
    const poly: phys.Polygon = if (s.round > 0)
        phys.makeRoundedBox(s.hw, s.hh, s.round)
    else
        phys.makeBox(s.hw, s.hh);
    _ = try phys.createShape(world, h, .{
        .geom = .{ .polygon = poly },
        .density = s.density,
        .enable_hit_events = s.hit_events,
        .filter = s.filter,
        .material = .{
            .friction = s.friction,
            .restitution = s.restitution,
            .tangent_speed = s.tangent_speed,
            .rolling_resistance = s.rolling,
        },
    });
}

const Ball = struct {
    r: f32 = 0.5,
    cx: f32 = 0,
    cy: f32 = 0,
    density: f32 = 1,
    friction: f32 = 0.6,
    restitution: f32 = 0,
    rolling: f32 = 0,
    hit_events: bool = false,
};

fn attachCircle(
    world: *phys.World,
    h: BodyHandle,
    s: Ball,
) !void {
    _ = try phys.createShape(world, h, .{
        .geom = .{ .circle = .{ .center = .{ s.cx, s.cy }, .radius = s.r } },
        .density = s.density,
        .enable_hit_events = s.hit_events,
        .material = .{
            .friction = s.friction,
            .restitution = s.restitution,
            .rolling_resistance = s.rolling,
        },
    });
}

/// Attach a sensor circle (no collision; emits sensor begin/end vs solid visitors).
fn attachSensorCircle(
    world: *phys.World,
    h: BodyHandle,
    center: Vec2,
    radius: f32,
) !void {
    _ = try phys.createShape(world, h, .{
        .geom = .{ .circle = .{ .center = center, .radius = radius } },
        .is_sensor = true,
        .density = 0,
    });
}

/// Attach a sensor box (no collision) — a region that reports overlapping bodies.
fn attachSensorBox(
    world: *phys.World,
    h: BodyHandle,
    hw: f32,
    hh: f32,
    center: Vec2,
) !void {
    _ = try phys.createShape(world, h, .{
        .geom = .{ .polygon = phys.makeOffsetBox(hw, hh, center, Rot2.identity) },
        .is_sensor = true,
        .density = 0,
    });
}

/// A BodyIndex → live-enough BodyHandle (createJoint/force paths consume `.index()` only).
fn bodyHandleOf(idx: usize) BodyHandle {
    return BodyHandle.pack(@intCast(idx), 0);
}

/// The owning body index of a shape reported in an event.
fn shapeBodyIndex(world: *phys.World, shape: phys.ShapeIndex) usize {
    return world.shapes.data[shape].body;
}

const Cap = struct {
    half_len: f32 = 0.5,
    r: f32 = 0.3,
    density: f32 = 1,
    friction: f32 = 0.6,
    restitution: f32 = 0,
    horizontal: bool = false,
};

fn attachCapsule(
    world: *phys.World,
    h: BodyHandle,
    s: Cap,
) !void {
    const c1: Vec2 = if (s.horizontal) .{ -s.half_len, 0 } else .{ 0, -s.half_len };
    const c2: Vec2 = if (s.horizontal) .{ s.half_len, 0 } else .{ 0, s.half_len };
    _ = try phys.createShape(world, h, .{
        .geom = .{ .capsule = .{ .center1 = c1, .center2 = c2, .radius = s.r } },
        .density = s.density,
        .material = .{ .friction = s.friction, .restitution = s.restitution },
    });
}

fn groundBox(
    world: *phys.World,
    half_w: f32,
    half_h: f32,
) !BodyHandle {
    const g: BodyHandle = try phys.createBody(world, .{
        .motion_type = .static,
        .position = .{ 0, -half_h },
    });
    _ = try phys.createShape(world, g, .{ .geom = .{ .polygon = phys.makeBox(half_w, half_h) } });
    return g;
}

fn groundSegment(world: *phys.World, half_w: f32) !BodyHandle {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, g, .{
        .geom = .{ .segment = .{ .point1 = .{ -half_w, 0 }, .point2 = .{ half_w, 0 } } },
    });
    return g;
}

/// Attach an axis-aligned box offset from the body origin (compound parts, walls).
fn attachOffsetBox(
    world: *phys.World,
    h: BodyHandle,
    hw: f32,
    hh: f32,
    center: Vec2,
    density: f32,
) !void {
    _ = try phys.createShape(world, h, .{
        .geom = .{ .polygon = phys.makeOffsetBox(hw, hh, center, Rot2.identity) },
        .density = density,
    });
}

/// Attach a box at body-local `center`, rotated by `angle` radians, with explicit friction —
/// the analogue of box2d v2's `SetAsBox(hw, hh, center, angle)`.
fn attachRotBox(
    world: *phys.World,
    h: BodyHandle,
    hw: f32,
    hh: f32,
    center: Vec2,
    angle: f32,
    density: f32,
    friction: f32,
) !void {
    _ = try phys.createShape(world, h, .{
        .geom = .{ .polygon = phys.makeOffsetBox(hw, hh, center, Rot2.fromAngle(angle)) },
        .density = density,
        .material = .{ .friction = friction },
    });
}

/// A hollow static box (floor/ceiling/2 walls) centred at the origin.
fn arena(
    world: *phys.World,
    half: f32,
    thick: f32,
) !BodyHandle {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, half, thick, .{ 0, -half }, 1);
    try attachOffsetBox(world, g, half, thick, .{ 0, half }, 1);
    try attachOffsetBox(world, g, thick, half, .{ -half, 0 }, 1);
    try attachOffsetBox(world, g, thick, half, .{ half, 0 }, 1);
    return g;
}

/// World point → a body's local frame (R(-θ)·(p − origin)).
fn worldToLocal(
    world: *phys.World,
    h: BodyHandle,
    p: Vec2,
) Vec2 {
    const xf: Transform2 = world.bodies.data[h.index()].transform;
    const dx: f32 = p[0] - xf.p[0];
    const dy: f32 = p[1] - xf.p[1];
    return .{ xf.q.cosine * dx + xf.q.sine * dy, -xf.q.sine * dx + xf.q.cosine * dy };
}

const Rev = struct {
    anchor: Vec2,
    motor: bool = false,
    speed: f32 = 0,
    torque: f32 = 0,
    limit: bool = false,
    lo: f32 = 0,
    hi: f32 = 0,
    collide: bool = false,
};

fn pinRevolute(
    world: *phys.World,
    a: BodyHandle,
    b: BodyHandle,
    r: Rev,
) !void {
    _ = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = a,
            .body_b = b,
            .local_frame_a = .{ .p = worldToLocal(world, a, r.anchor), .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b, r.anchor), .q = Rot2.identity },
            .collide_connected = r.collide,
        },
        .enable_motor = r.motor,
        .motor_speed = r.speed,
        .max_motor_torque = r.torque,
        .enable_limit = r.limit,
        .lower_angle = r.lo,
        .upper_angle = r.hi,
    });
}

fn pinWeld(
    world: *phys.World,
    a: BodyHandle,
    b: BodyHandle,
    anchor: Vec2,
) !void {
    _ = try phys.createWeldJoint(world, .{ .base = .{
        .body_a = a,
        .body_b = b,
        .local_frame_a = .{ .p = worldToLocal(world, a, anchor), .q = Rot2.identity },
        .local_frame_b = .{ .p = worldToLocal(world, b, anchor), .q = Rot2.identity },
    } });
}

const Dist = struct {
    pa: Vec2,
    pb: Vec2,
    length: f32,
    hertz: f32 = 0,
    damping: f32 = 0,
};

fn pinDistance(
    world: *phys.World,
    a: BodyHandle,
    b: BodyHandle,
    d: Dist,
) !void {
    _ = try phys.createDistanceJoint(world, .{
        .base = .{
            .body_a = a,
            .body_b = b,
            .local_frame_a = .{ .p = worldToLocal(world, a, d.pa), .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b, d.pb), .q = Rot2.identity },
        },
        .length = d.length,
        .enable_spring = d.hertz > 0,
        .hertz = d.hertz,
        .damping_ratio = d.damping,
    });
}

const Prism = struct {
    anchor: Vec2,
    axis_angle: f32 = 0, // 0 = slide along world +X, pi/2 = along +Y
    motor: bool = false,
    speed: f32 = 0,
    force: f32 = 0,
    spring: bool = false,
    hertz: f32 = 0,
    damping: f32 = 0,
    limit: bool = false,
    lo: f32 = 0,
    hi: f32 = 0,
};

// The joint axis is local_frame_a's x-axis (engine: axis = rotateVec2(frame_a.q, {1,0})).
// Bodies anchored here are unrotated, so the axis rotation is the same in world and local.
fn pinPrismatic(
    world: *phys.World,
    a: BodyHandle,
    b: BodyHandle,
    p: Prism,
) !void {
    const q: Rot2 = Rot2.fromAngle(p.axis_angle);
    _ = try phys.createPrismaticJoint(world, .{
        .base = .{
            .body_a = a,
            .body_b = b,
            .local_frame_a = .{ .p = worldToLocal(world, a, p.anchor), .q = q },
            .local_frame_b = .{ .p = worldToLocal(world, b, p.anchor), .q = q },
        },
        .enable_motor = p.motor,
        .motor_speed = p.speed,
        .max_motor_force = p.force,
        .enable_spring = p.spring,
        .hertz = p.hertz,
        .damping_ratio = p.damping,
        .enable_limit = p.limit,
        .lower_translation = p.lo,
        .upper_translation = p.hi,
    });
}

const Whl = struct {
    anchor: Vec2,
    axis_angle: f32 = 1.5707963, // suspension travel direction; default vertical
    hertz: f32 = 4.0,
    damping: f32 = 0.7,
    motor: bool = false,
    speed: f32 = 0,
    torque: f32 = 0,
};

fn pinWheel(
    world: *phys.World,
    a: BodyHandle,
    b: BodyHandle,
    w: Whl,
) !void {
    const q: Rot2 = Rot2.fromAngle(w.axis_angle);
    _ = try phys.createWheelJoint(world, .{
        .base = .{
            .body_a = a,
            .body_b = b,
            .local_frame_a = .{ .p = worldToLocal(world, a, w.anchor), .q = q },
            .local_frame_b = .{ .p = worldToLocal(world, b, w.anchor), .q = q },
        },
        .enable_spring = true,
        .hertz = w.hertz,
        .damping_ratio = w.damping,
        .enable_motor = w.motor,
        .motor_speed = w.speed,
        .max_motor_torque = w.torque,
    });
}

/// Attach a convex polygon built from a point cloud (for arch voussoirs etc.).
fn attachHull(
    world: *phys.World,
    h: BodyHandle,
    pts: []const Vec2,
    density: f32,
) !void {
    const hull: phys.Hull = phys.computeHull(pts);
    _ = try phys.createShape(world, h, .{
        .geom = .{ .polygon = phys.makePolygon(hull, 0) },
        .density = density,
    });
}

// ================================================================================
// Registry
// ================================================================================

// ---- Robustness ----

fn robustHighMass1(world: *phys.World) !void {
    // Three pyramids of unit boxes, each capped by a heavy box (density 100/200/300)
    // resting on one box — a high mass-ratio stability stress test.
    _ = try groundBox(world, 50, 1);
    const extent: f32 = 1.0;
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        const fj: f32 = float(j);
        const offset: f32 = -20.0 * extent + 2.0 * 11.0 * extent * fj; // 2*(count+1), count=10
        var count: i32 = 10;
        var y: f32 = extent;
        while (count > 0) : (count -= 1) {
            const fc: f32 = float(count);
            var i: i32 = 0;
            while (i < count) : (i += 1) {
                const coeff: f32 = float(i) - 0.5 * fc;
                const yy: f32 = if (count == 1) y + 2.0 else y;
                const dens: f32 = if (count == 1) (fj + 1.0) * 100.0 else 1.0;
                const b: BodyHandle = try addBody(world, .{ .x = 2.0 * coeff * extent + offset, .y = yy });
                try attachBox(world, b, .{ .hw = extent, .hh = extent, .density = dens });
            }
            y += 2.0 * extent;
        }
    }
}

fn robustHighMass2(world: *phys.World) !void {
    // A big heavy box (20x20) resting on two tiny boxes.
    _ = try groundBox(world, 50, 1);
    const a: BodyHandle = try addBody(world, .{ .x = -9, .y = 0.5 });
    try attachBox(world, a, .{ .hw = 0.5, .hh = 0.5 });
    const b: BodyHandle = try addBody(world, .{ .x = 9, .y = 0.5 });
    try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
    const big: BodyHandle = try addBody(world, .{ .x = 0, .y = 26 });
    try attachBox(world, big, .{ .hw = 10, .hh = 10 });
}

fn robustHighMass3(world: *phys.World) !void {
    // A big box resting on two small triangles.
    _ = try groundBox(world, 50, 1);
    const tri = [_]Vec2{ .{ -0.5, 0 }, .{ 0.5, 0 }, .{ 0, 1 } };
    const a: BodyHandle = try addBody(world, .{ .x = -9, .y = 0.5 });
    try attachHull(world, a, &tri, 1.0);
    const b: BodyHandle = try addBody(world, .{ .x = 9, .y = 0.5 });
    try attachHull(world, b, &tri, 1.0);
    const big: BodyHandle = try addBody(world, .{ .x = 0, .y = 14 });
    try attachBox(world, big, .{ .hw = 10, .hh = 10 });
}

fn robustOverlap(world: *phys.World) !void {
    // A small pyramid whose boxes start 25% overlapped; the solver pushes them apart.
    _ = try groundBox(world, 40, 1);
    const base_count: i32 = 4;
    const extent: f32 = 0.5;
    const fraction: f32 = 0.75; // 1 - 0.25 overlap
    var y: f32 = extent;
    var i: i32 = 0;
    while (i < base_count) : (i += 1) {
        var x: f32 = fraction * extent * float(i - base_count);
        var jj: i32 = i;
        while (jj < base_count) : (jj += 1) {
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = extent, .hh = extent });
            x += 2.0 * fraction * extent;
        }
        y += 2.0 * fraction * extent;
    }
}

fn robustTinyPyramid(world: *phys.World) !void {
    // A 30-row pyramid of 2.5 cm squares — small-scale stacking robustness.
    _ = try groundBox(world, 5, 1);
    const base_count: i32 = 30;
    const extent: f32 = 0.025;
    var i: i32 = 0;
    while (i < base_count) : (i += 1) {
        const fi: f32 = float(i);
        const y: f32 = (2.0 * fi + 1.0) * extent;
        var jj: i32 = i;
        while (jj < base_count) : (jj += 1) {
            const fj: f32 = float(jj);
            const bc: f32 = float(base_count);
            const x: f32 = (fi + 1.0) * extent + 2.0 * (fj - fi) * extent - bc * extent;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = extent, .hh = extent });
        }
    }
}

// ---- Bodies ----

fn bodyBad(world: *phys.World) !void {
    // A "bad body": a dynamic body with zero density (no mass) behaves like a kinematic body.
    // Shown beside a normal capsule for comparison. (box2d also pushes the bad body upward each
    // step "for science" — omitted; our Scene.update hook is stateless.)
    _ = try groundSegment(world, 20);
    const bad: BodyHandle = try addBody(world, .{ .x = 0, .y = 3, .angle = 0.25 * pi, .w = 0.5 });
    try attachCapsule(world, bad, .{ .half_len = 1, .r = 1, .density = 0 });
    const normal: BodyHandle = try addBody(world, .{ .x = 2, .y = 3, .angle = 0.25 * pi });
    try attachCapsule(world, normal, .{ .half_len = 1, .r = 1 });
}

fn bodyMixedLocks(world: *phys.World) !void {
    // Boxes with assorted motion locks: a static reference, two free, then angular-z locked,
    // linear-x locked, linear-y + angular-z locked, and a fully-locked dynamic body.
    _ = try groundSegment(world, 20);
    const st: BodyHandle = try addBody(world, .{ .x = 2, .y = 1, .motion = .static });
    try attachBox(world, st, .{ .hw = 0.5, .hh = 0.5 });
    const f1: BodyHandle = try addBody(world, .{ .x = 1, .y = 1 });
    try attachBox(world, f1, .{ .hw = 0.5, .hh = 0.5 });
    const f2: BodyHandle = try addBody(world, .{ .x = 1, .y = 3 });
    try attachBox(world, f2, .{ .hw = 0.5, .hh = 0.5 });
    const az: BodyHandle = try addBody(world, .{ .x = -1, .y = 1, .lock_rot = true });
    try attachBox(world, az, .{ .hw = 0.5, .hh = 0.5 });
    const lx: BodyHandle = try addBody(world, .{ .x = -2, .y = 2, .lock_x = true });
    try attachBox(world, lx, .{ .hw = 0.5, .hh = 0.5 });
    const lyz: BodyHandle = try addBody(world, .{ .x = -1, .y = 2.5, .lock_y = true, .lock_rot = true });
    try attachBox(world, lyz, .{ .hw = 0.5, .hh = 0.5 });
    const locked: BodyHandle = try addBody(world, .{
        .x = 0,
        .y = 1,
        .lock_x = true,
        .lock_y = true,
        .lock_rot = true,
    });
    try attachBox(world, locked, .{ .hw = 0.5, .hh = 0.5 });
}

fn bodyWakeTouching(world: *phys.World) !void {
    // Ten boxes settle onto a segment and fall asleep (sleeping bodies are drawn dimmed).
    _ = try groundSegment(world, 20);
    var x: f32 = -9.0; // -(count - 1)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 4 });
        try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
        x += 2.0;
    }
}

// ---- Continuous (CCD) ----

fn continuousSpecFallback(world: *phys.World) !void {
    // Fast skinny box dropped at -100 m/s onto a polygon ledge — speculative-contact CCD,
    // with the box sitting at a large offset (-8) from its body origin.
    const ground: BodyHandle = try groundSegment(world, 10);
    const ledge = [_]Vec2{ .{ -2, 4 }, .{ 2, 4 }, .{ 2, 4.1 }, .{ -0.5, 4.2 }, .{ -2, 4.2 } };
    try attachHull(world, ground, &ledge, 1.0);
    const fast: BodyHandle = try addBody(world, .{ .x = 8, .y = 12, .vy = -100 });
    const box = [_]Vec2{ .{ -10, -0.05 }, .{ -6, -0.05 }, .{ -6, 0.05 }, .{ -10, 0.05 } };
    try attachHull(world, fast, &box, 1.0);
}

fn continuousSpecSliver(world: *phys.World) !void {
    // A thin sliver triangle falling at -100 m/s onto a segment — speculative CCD on slivers.
    _ = try groundSegment(world, 10);
    const sliver = [_]Vec2{ .{ -2, 0 }, .{ -1, 0 }, .{ 2, 0.5 } };
    const fast: BodyHandle = try addBody(world, .{ .x = 0, .y = 12, .vy = -100 });
    try attachHull(world, fast, &sliver, 1.0);
}

fn continuousSpecGhost(world: *phys.World) !void {
    // A small square skims diagonally just above a ledge; the speculative margin does not
    // produce a ghost collision at this small distance. (gravity off, constant velocity)
    _ = try groundSegment(world, 10);
    const ledge: BodyHandle = try addBody(world, .{ .x = 0, .y = 0.9, .motion = .static });
    try attachBox(world, ledge, .{ .hw = 1, .hh = 0.1 });
    const v: f32 = 0.1 * 1.25 * 60.0; // 0.1 * 1.25 * hertz(60)
    const sq: BodyHandle = try addBody(world, .{ .x = 0.015, .y = 2.515, .vx = v, .vy = -v, .gravity_scale = 0 });
    try attachBox(world, sq, .{ .hw = 0.25, .hh = 0.25 });
}

fn continuousPixelImperfect(world: *phys.World) !void {
    // Box2D collision is not pixel-perfect: a rounded "ball" descends (gravity off) onto a
    // static block; positions drift sub-pixel.
    const ppm: f32 = 30.0;
    const block: BodyHandle = try addBody(world, .{ .x = 175.0 / ppm, .y = 150.0 / ppm, .motion = .static });
    try attachBox(world, block, .{ .hw = 20.0 / ppm, .hh = 10.0 / ppm, .friction = 0 });
    const ball: BodyHandle = try addBody(world, .{
        .x = 200.0 / ppm,
        .y = 275.0 / ppm,
        .vy = -5,
        .gravity_scale = 0,
        .lock_rot = true,
    });
    try attachBox(world, ball, .{ .hw = 4.0 / ppm, .hh = 4.0 / ppm, .round = 0.9 / ppm, .friction = 0 });
}

fn continuousRestitutionThreshold(world: *phys.World) !void {
    // With the restitution threshold at 0.1 m/s, a slow ball striking a tilted block barely bounces.
    world.settings.restitution_threshold = 0.1;
    const ppm: f32 = 30.0;
    const block: BodyHandle = try addBody(world, .{
        .x = 205.0 / ppm,
        .y = 120.0 / ppm,
        .motion = .static,
        .angle = 70.0 * pi / 180.0,
    });
    try attachBox(world, block, .{ .hw = 50.0 / ppm, .hh = 5.0 / ppm, .friction = 0 });
    const ball: BodyHandle = try addBody(world, .{ .x = 200.0 / ppm, .y = 250.0 / ppm, .vy = -2.9, .lock_rot = true });
    try attachCircle(world, ball, .{ .r = 5.0 / ppm, .friction = 0, .restitution = 1 });
}

fn continuousChainSlide(world: *phys.World) !void {
    // A fast circle (100 m/s) slides inside a closed chain loop — CCD against a chain, no ghosts.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    var pts: [80]Vec2 = undefined;
    const w: f32 = 2.0;
    const h: f32 = 1.0;
    var x: f32 = 20.0;
    var y: f32 = 0.0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        pts[i] = .{ x, y };
        x -= w;
    }
    while (i < 40) : (i += 1) {
        pts[i] = .{ x, y };
        y += h;
    }
    while (i < 60) : (i += 1) {
        pts[i] = .{ x, y };
        x += w;
    }
    while (i < 80) : (i += 1) {
        pts[i] = .{ x, y };
        y -= h;
    }
    _ = try phys.createChain(world, ground, .{ .points = &pts, .is_loop = true });
    const ball: BodyHandle = try addBody(world, .{ .x = -19.5, .y = 0.5, .vx = 100 });
    try attachCircle(world, ball, .{ .r = 0.5, .friction = 0 });
}

fn continuousSegmentSlide(world: *phys.World) !void {
    // A fast circle slides along a segment floor and slams into a vertical segment wall.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -40, 0 }, .point2 = .{ 40, 0 } } },
    });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ 40, 0 }, .point2 = .{ 40, 10 } } },
    });
    const ball: BodyHandle = try addBody(world, .{ .x = -20, .y = 0.7, .vx = 100 });
    try attachCircle(world, ball, .{ .r = 0.5 });
}

// ---- Joints ----

fn jointsUserConstraint(world: *phys.World, st: *SceneState) !void {
    // box2d Joints|User Constraint: a soft "cable" constraint built entirely in the update hook from
    // public body accessors — no engine joint. Two cables anchored at a fixed point pull a falling box,
    // computed as a TGS soft constraint and applied by setting the box's velocity each step.
    const box: BodyHandle = try phys.createBody(world, .{
        .motion_type = .dynamic,
        .position = .{ 0, 0 },
        .linear_damping = 0.2,
        .angular_damping = 0.5,
        .enable_sleep = false,
    });
    _ = try phys.createShape(world, box, .{
        .geom = .{ .polygon = phys.makeBox(1.0, 0.5) },
        .density = 20.0,
    });
    st.body[0] = box;
}

fn jointsUserConstraintUpdate(world: *phys.World, st: *SceneState) void {
    const box: BodyHandle = st.body[0];
    const dt: f32 = 1.0 / 60.0;
    const hertz: f32 = 3.0;
    const zeta: f32 = 0.7;
    const max_force: f32 = 1000.0;
    const omega: f32 = 2.0 * pi * hertz;
    const sigma: f32 = 2.0 * zeta + dt * omega;
    const s: f32 = dt * omega * sigma;
    const impulse_coef: f32 = 1.0 / (1.0 + s);
    const mass_coef: f32 = s * impulse_coef;
    const bias_coef: f32 = omega / sigma;

    const mass: f32 = phys.getMass(world, box);
    const inv_mass: f32 = if (mass < 0.0001) 0.0 else 1.0 / mass;
    const inertia: f32 = phys.getRotationalInertia(world, box);
    const inv_i: f32 = if (inertia < 0.0001) 0.0 else 1.0 / inertia;

    var v_b: Vec2 = phys.getLinearVelocity(world, box);
    var omega_b: f32 = phys.getAngularVelocity(world, box);
    const p_b: Vec2 = phys.getWorldCenterOfMass(world, box);

    const anchor_a: Vec2 = .{ 3.0, 0.0 };
    const local_anchors = [_]Vec2{ .{ 1.0, -0.5 }, .{ 1.0, 0.5 } };
    for (local_anchors) |la| {
        const anchor_b: Vec2 = phys.getWorldPoint(world, box, la);
        const delta: Vec2 = anchor_b - anchor_a;
        const dist: f32 = @sqrt(delta[0] * delta[0] + delta[1] * delta[1]);
        const slack: f32 = 1.0;
        const c: f32 = dist - slack;
        if (c < 0.0 or dist < 0.001) {
            continue;
        }
        const axis: Vec2 = .{ delta[0] / dist, delta[1] / dist };
        const r_b: Vec2 = anchor_b - p_b;
        const jb: f32 = r_b[0] * axis[1] - r_b[1] * axis[0];
        const k: f32 = inv_mass + jb * inv_i * jb;
        const inv_k: f32 = if (k < 0.0001) 0.0 else 1.0 / k;
        const cdot: f32 = v_b[0] * axis[0] + v_b[1] * axis[1] + jb * omega_b;
        const impulse: f32 = -mass_coef * inv_k * (cdot + bias_coef * c);
        const applied: f32 = clamp(impulse, -max_force * dt, 0.0);
        v_b = .{ v_b[0] + axis[0] * inv_mass * applied, v_b[1] + axis[1] * inv_mass * applied };
        omega_b += applied * inv_i * jb;
    }
    phys.setLinearVelocity(world, box, v_b);
    phys.setAngularVelocity(world, box, omega_b);
}

fn jointFilter(world: *phys.World) !void {
    // A filter joint disables collision between two specific bodies (more targeted than shape
    // filters): the two boxes can overlap while still landing on the ground.
    _ = try groundSegment(world, 20);
    const a: BodyHandle = try addBody(world, .{ .x = -4, .y = 2 });
    try attachBox(world, a, .{ .hw = 2, .hh = 2 });
    const b: BodyHandle = try addBody(world, .{ .x = 4, .y = 2 });
    try attachBox(world, b, .{ .hw = 2, .hh = 2 });
    _ = try phys.createFilterJoint(world, .{ .body_a = a, .body_b = b });
}

fn jointTopDownFriction(world: *phys.World) !void {
    // Top-down view (gravity off): each body is tied to the static frame by a motor joint with
    // a small max force/torque, acting as friction. A 10x10 grid of mixed bouncy shapes in an arena.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const walls = [4][2]Vec2{
        .{ .{ -10, 0 }, .{ 10, 0 } },
        .{ .{ -10, 0 }, .{ -10, 20 } },
        .{ .{ 10, 0 }, .{ 10, 20 } },
        .{ .{ -10, 20 }, .{ 10, 20 } },
    };
    for (walls) |seg| {
        _ = try phys.createShape(world, ground, .{
            .geom = .{ .segment = .{ .point1 = seg[0], .point2 = seg[1] } },
        });
    }
    var y: f32 = 15;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var x: f32 = -5;
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y, .gravity_scale = 0 });
            const rem: usize = (10 * i + j) % 4;
            if (rem == 0) {
                try attachCapsule(world, b, .{ .half_len = 0.25, .r = 0.25, .horizontal = true, .restitution = 0.8 });
            } else if (rem == 1) {
                try attachCircle(world, b, .{ .r = 0.35, .restitution = 0.8 });
            } else if (rem == 2) {
                try attachBox(world, b, .{ .hw = 0.35, .hh = 0.35, .restitution = 0.8 });
            } else {
                try attachBox(world, b, .{ .hw = 0.35, .hh = 0.35, .round = 0.1, .restitution = 0.8 });
            }
            _ = try phys.createMotorJoint(world, .{
                .base = .{ .body_a = ground, .body_b = b, .collide_connected = true },
                .max_velocity_force = 10,
                .max_velocity_torque = 10,
            });
            x += 1;
        }
        y -= 1;
    }
}

// ---- Shapes (stateful) ----

fn shapesRecreateStaticBuild(world: *phys.World, st: *SceneState) !void {
    // Each step the static ground is destroyed and recreated from scratch — exercises rebuilding
    // a static body every frame under a resting dynamic box without it falling through.
    const b: BodyHandle = try addBody(world, .{ .x = 0, .y = 1 });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    st.u[0] = 0; // no ground created yet
}

fn shapesRecreateStaticUpdate(world: *phys.World, st: *SceneState) void {
    if (st.u[0] == 1) {
        phys.destroyBody(world, st.body[0]);
    }
    const g: BodyHandle = phys.createBody(world, .{ .motion_type = .static }) catch return;
    _ = phys.createShape(world, g, .{
        .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } },
    }) catch return;
    st.body[0] = g;
    st.u[0] = 1;
}

fn jointScaleRagdoll(world: *phys.World) !void {
    // The same ragdoll built at several scales, demonstrating scale-invariant joint behaviour.
    _ = try groundBox(world, 40, 1);
    const scales = [4]f32{ 0.5, 1.0, 1.5, 2.0 };
    const xs = [4]f32{ -7.5, -3.0, 1.5, 7.0 };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try makeRagdoll(world, xs[i], 3.0 + scales[i] * 1.5, scales[i]);
    }
}

fn continuousBounceHumans(world: *phys.World, st: *SceneState) !void {
    // A box arena with bouncy walls + a very bouncy centre circle. Ragdolls spawn one every two
    // seconds and tumble as gravity sweeps around the compass (handled in the update hook).
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const walls = [4][2]Vec2{
        .{ .{ -10, -10 }, .{ 10, -10 } },
        .{ .{ 10, -10 }, .{ 10, 10 } },
        .{ .{ 10, 10 }, .{ -10, 10 } },
        .{ .{ -10, 10 }, .{ -10, -10 } },
    };
    for (walls) |seg| {
        _ = try phys.createShape(world, ground, .{
            .geom = .{ .segment = .{ .point1 = seg[0], .point2 = seg[1] } },
            .material = .{ .restitution = 1.3, .friction = 0.1 },
        });
    }
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .circle = .{ .center = .{ 0, 0 }, .radius = 2 } },
        .material = .{ .restitution = 2.0, .friction = 0.1 },
    });
    st.u[0] = 0;
    st.f[0] = 0;
    st.f[1] = 0;
}

fn continuousBounceHumansUpdate(world: *phys.World, st: *SceneState) void {
    const dt: f32 = 1.0 / 60.0;
    if (st.u[0] < 5 and st.f[0] <= 0) {
        makeRagdoll(world, 0, 5, 1) catch assertUnreachable(@src(), "OOM", .{});
        st.u[0] += 1;
        st.f[0] = 2.0;
    }
    st.f[1] += dt;
    st.f[0] -= dt;
    const t: f32 = st.f[1];
    world.settings.gravity = .{ 10.0 * @sin(0.5 * t), 10.0 * @cos(t) };
}

fn jointBreakable(world: *phys.World, st: *SceneState) !void {
    // Four boxes of increasing mass pinned to the ground by revolute joints, above a floor.
    // The update hook reads each joint's constraint force (~ the weight it holds) and destroys
    // the joint once it passes a threshold, so the heavier boxes break free and drop while the
    // lighter ones keep hanging. Demonstrates getConstraintForce + destroyJoint. (box2d's version
    // cycles joint types behind a live force slider.)
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, 40, 0.5, .{ 0, -0.5 }, 1);
    const dens = [4]f32{ 2, 6, 12, 20 };
    const xs = [4]f32{ -9, -3, 3, 9 };
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const box: BodyHandle = try addBody(world, .{ .x = xs[i], .y = 7 });
        try attachBox(world, box, .{ .hw = 0.5, .hh = 0.5, .density = dens[i] });
        st.body[i] = box;
        st.joint[i] = try phys.createRevoluteJoint(world, .{
            .base = .{
                .body_a = g,
                .body_b = box,
                .local_frame_a = .{ .p = .{ xs[i], 7 }, .q = Rot2.identity },
                .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            },
        });
        st.u[i] = 0;
    }
    st.f[0] = 80;
}

fn jointBreakableUpdate(world: *phys.World, st: *SceneState) void {
    const bf2: f32 = st.f[0] * st.f[0];
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (st.u[i] != 0) {
            continue;
        }
        const force: Vec2 = phys.getConstraintForce(world, st.joint[i]);
        if (force[0] * force[0] + force[1] * force[1] > bf2) {
            phys.destroyJoint(world, st.joint[i]);
            st.u[i] = 1;
        }
    }
}

fn jointMotionLocks(world: *phys.World) !void {
    // A gallery of six rotation-locked boxes (angular DOF locked), one per joint type, showing how
    // each joint holds a locked body: distance, motor, prismatic, revolute, weld, wheel. (box2d adds
    // live lock toggles + an impulse key; we render the static configuration.)
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const y: f32 = 10;
    var x: f32 = -12.5;
    var b: BodyHandle = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinDistance(world, g, b, .{ .pa = .{ x, y + 3 }, .pb = .{ x, y + 1 }, .length = 2 });
    x += 5;
    b = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    _ = try phys.createMotorJoint(world, .{
        .base = .{ .body_a = g, .body_b = b, .local_frame_a = .{ .p = .{ x, y }, .q = Rot2.identity } },
        .max_velocity_force = 200,
        .max_velocity_torque = 200,
    });
    x += 5;
    b = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinPrismatic(world, g, b, .{ .anchor = .{ x - 1, y } });
    x += 5;
    b = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinRevolute(world, g, b, .{ .anchor = .{ x - 1, y } });
    x += 5;
    b = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinWeld(world, g, b, .{ x - 1, y });
    x += 5;
    b = try addBody(world, .{ .x = x, .y = y, .lock_rot = true });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinWheel(world, g, b, .{ .anchor = .{ x - 1, y }, .hertz = 1, .damping = 0.7 });
}

fn jointSeparation(world: *phys.World) !void {
    // The same gallery without rotation locks and spaced wider, over a segment floor: distance,
    // prismatic, revolute, weld, wheel. (box2d adds a live impulse to stress joint separation.)
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, g, .{
        .geom = .{ .segment = .{ .point1 = .{ -40, 0 }, .point2 = .{ 40, 0 } } },
    });
    const y: f32 = 10;
    var x: f32 = -20;
    var b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinDistance(world, g, b, .{ .pa = .{ x, y + 3 }, .pb = .{ x, y + 1 }, .length = 2 });
    x += 10;
    b = try addBody(world, .{ .x = x, .y = y });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinPrismatic(world, g, b, .{ .anchor = .{ x - 1, y } });
    x += 10;
    b = try addBody(world, .{ .x = x, .y = y });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinRevolute(world, g, b, .{ .anchor = .{ x - 1, y } });
    x += 10;
    b = try addBody(world, .{ .x = x, .y = y });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinWeld(world, g, b, .{ x - 1, y });
    x += 10;
    b = try addBody(world, .{ .x = x, .y = y });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
    try pinWheel(world, g, b, .{ .anchor = .{ x - 1, y }, .hertz = 1, .damping = 0.7 });
}

fn jointScissorLift(world: *phys.World) !void {
    // A scissor lift: three stacked levels of crossed capsule links pinned with stiff revolute
    // joints (+ a no-spring wheel joint on one side per level so the X can expand horizontally),
    // topped by a platform. A sprung distance-joint strut holds it up. (box2d puts a live motor on
    // that strut to raise/lower; our static version rests at the sprung height.) 8 substeps for the
    // stiff joints.
    world.settings.sub_step_count = 8;
    const ch: f32 = 240;
    const cd: f32 = 20;
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -20, 0 }, .point2 = .{ 20, 0 } } },
    });
    var base1: BodyHandle = ground;
    var base2: BodyHandle = ground;
    var anchor1: Vec2 = .{ -2.5, 0.2 };
    var anchor2: Vec2 = .{ 2.5, 0.2 };
    var y: f32 = 0.5;
    var link1: BodyHandle = ground;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const a: BodyHandle = try addBody(world, .{ .x = 0, .y = y, .angle = 0.15 });
        try attachCapsule(world, a, .{ .half_len = 2.5, .r = 0.15, .horizontal = true });
        const b: BodyHandle = try addBody(world, .{ .x = 0, .y = y, .angle = -0.15 });
        try attachCapsule(world, b, .{ .half_len = 2.5, .r = 0.15, .horizontal = true });
        if (i == 1) {
            link1 = b;
        }
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = base1,
            .body_b = a,
            .local_frame_a = .{ .p = anchor1, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ -2.5, 0 }, .q = Rot2.identity },
            .collide_connected = i == 0,
            .constraint_hertz = ch,
            .constraint_damping_ratio = cd,
        } });
        if (i == 0) {
            _ = try phys.createWheelJoint(world, .{
                .base = .{
                    .body_a = base2,
                    .body_b = b,
                    .local_frame_a = .{ .p = anchor2, .q = Rot2.identity },
                    .local_frame_b = .{ .p = .{ 2.5, 0 }, .q = Rot2.identity },
                    .collide_connected = true,
                    .constraint_hertz = ch,
                    .constraint_damping_ratio = cd,
                },
                .enable_spring = false,
            });
        } else {
            _ = try phys.createRevoluteJoint(world, .{ .base = .{
                .body_a = base2,
                .body_b = b,
                .local_frame_a = .{ .p = anchor2, .q = Rot2.identity },
                .local_frame_b = .{ .p = .{ 2.5, 0 }, .q = Rot2.identity },
                .collide_connected = false,
                .constraint_hertz = ch,
                .constraint_damping_ratio = cd,
            } });
        }
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = a,
            .body_b = b,
            .local_frame_a = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .collide_connected = false,
            .constraint_hertz = ch,
            .constraint_damping_ratio = cd,
        } });
        base1 = b;
        base2 = a;
        anchor1 = .{ -2.5, 0 };
        anchor2 = .{ 2.5, 0 };
        y += 1;
    }
    const platform: BodyHandle = try addBody(world, .{ .x = 0, .y = y });
    try attachBox(world, platform, .{ .hw = 3, .hh = 0.2 });
    _ = try phys.createRevoluteJoint(world, .{ .base = .{
        .body_a = platform,
        .body_b = base1,
        .local_frame_a = .{ .p = .{ -2.5, -0.4 }, .q = Rot2.identity },
        .local_frame_b = .{ .p = anchor1, .q = Rot2.identity },
        .collide_connected = true,
        .constraint_hertz = ch,
        .constraint_damping_ratio = cd,
    } });
    _ = try phys.createWheelJoint(world, .{
        .base = .{
            .body_a = platform,
            .body_b = base2,
            .local_frame_a = .{ .p = .{ 2.5, -0.4 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = anchor2, .q = Rot2.identity },
            .collide_connected = true,
            .constraint_hertz = ch,
            .constraint_damping_ratio = cd,
        },
        .enable_spring = false,
    });
    _ = try phys.createDistanceJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = link1,
            .local_frame_a = .{ .p = .{ -2.5, 0.2 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0.5, 0 }, .q = Rot2.identity },
        },
        .enable_spring = true,
        .min_length = 0.2,
        .max_length = 5.5,
        .enable_limit = true,
    });
}

// ---- Benchmark ----

fn benchmarkLargeCompounds(world: *phys.World) !void {
    // box2d Benchmark|Large Compounds: many compound bodies, each assembled from several shapes with the
    // mass solve deferred (ShapeDef.update_body_mass=false) and applied once via applyMassFromShapes — O(N)
    // per body instead of O(N^2). Here a modest grid of plus-shaped compounds drops into a wide bin.
    _ = try groundBox(world, 16, 1);

    const offsets = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
    var row: usize = 0;
    while (row < 5) : (row += 1) {
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const x: f32 = -8.0 + float(col) * 4.0;
            const y: f32 = 4.0 + float(row) * 3.0;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            for (offsets) |off| {
                _ = try phys.createShape(world, b, .{
                    .geom = .{ .polygon = phys.makeOffsetBox(0.5, 0.5, off, Rot2.identity) },
                    .density = 1.0,
                    .update_body_mass = false,
                });
            }
            phys.applyMassFromShapes(world, b);
        }
    }
}

fn benchmarkSmash(world: *phys.World) !void {
    // A heavy fast box (gravity off) plows through a dense wall of small squares. (box2d's benchmark
    // uses a 120x80 wall; we use a phone-friendly grid.)
    world.settings.gravity = .{ 0, 0 };
    const big: BodyHandle = try addBody(world, .{ .x = -20, .y = 0, .vx = 40, .bullet = true });
    try attachBox(world, big, .{ .hw = 4, .hh = 4, .density = 8 });
    const d: f32 = 0.4;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var j: usize = 0;
        while (j < 30) : (j += 1) {
            const x: f32 = float(i) * d + 30.0;
            const y: f32 = (float(j) - 15.0) * d;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = 0.5 * d, .hh = 0.5 * d });
        }
    }
}

fn benchmarkJunkyard(world: *phys.World, st: *SceneState) !void {
    // A junkyard: a box-walled bucket, a pile of small pentagons raining in, and a kinematic pusher
    // that sweeps side to side (update hook drives its velocity). (box2d rains ~8000 pieces; we use
    // fewer for the phone.)
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    var x: f32 = -40;
    var i: usize = 0;
    while (i < 81) : (i += 1) {
        try attachOffsetBox(world, ground, 0.55, 0.5, .{ x, 0 }, 1);
        x += 1;
    }
    var y: f32 = 1;
    i = 0;
    while (i < 30) : (i += 1) {
        try attachOffsetBox(world, ground, 0.5, 0.55, .{ -40, y }, 1);
        try attachOffsetBox(world, ground, 0.5, 0.55, .{ 40, y }, 1);
        y += 1;
    }
    // Pentagon prototype (Fibonacci-sphere of 5 points, radius 0.25).
    const golden: f32 = pi * 1.2360680;
    var pts: [5]Vec2 = undefined;
    i = 0;
    while (i < 5) : (i += 1) {
        const th: f32 = golden * float(i);
        pts[i] = .{ 0.25 * @cos(th), 0.25 * @sin(th) };
    }
    var side: f32 = -0.1;
    var c: usize = 0;
    while (c < 60) : (c += 1) {
        var r: usize = 0;
        while (r < 8) : (r += 1) {
            const px: f32 = 1.5 * (2.0 * float(c) - 60.0) * 0.25;
            const py: f32 = 4.0 * float(r) * 0.25 + 15.0;
            const b: BodyHandle = try addBody(world, .{ .x = px + side, .y = py });
            try attachHull(world, b, &pts, 1);
            side = -side;
        }
    }
    const pusher: BodyHandle = try phys.createBody(world, .{ .motion_type = .kinematic });
    try attachOffsetBox(world, pusher, 2, 4, .{ 0, 4 }, 1);
    st.body[0] = pusher;
    st.f[0] = 0;
}

fn benchmarkJunkyardUpdate(world: *phys.World, st: *SceneState) void {
    const dt: f32 = 1.0 / 60.0;
    st.f[0] += dt;
    const vx: f32 = 6.0 * @cos(0.2 * st.f[0]);
    phys.setLinearVelocity(world, st.body[0], .{ vx, 0 });
}

fn benchmarkSleep(world: *phys.World) !void {
    // A tall triangular pyramid of boxes that settles and goes to sleep. (box2d base 100; reduced
    // for the phone.)
    const count: usize = 30;
    const shift: f32 = 1.0;
    const centerx: f32 = shift * float(count) / 2.0;
    const centery: f32 = shift / 2.0 + 1.0;
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, ground, 40, 1, .{ 0, 0 }, 1);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const fi: f32 = float(i);
        const y: f32 = fi * shift + centery;
        var j: usize = i;
        while (j < count) : (j += 1) {
            const fj: f32 = float(j);
            const x: f32 = 0.5 * fi * shift + (fj - fi) * shift - centerx;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5, .friction = 0.5 });
        }
    }
}

fn benchmarkKinematic(world: *phys.World) !void {
    // One large kinematic body — a grid of square shapes — spinning slowly; a broadphase stress
    // test. (box2d uses a wider grid; reduced for the phone.)
    const body: BodyHandle = try addBody(world, .{ .motion = .kinematic, .w = 1.0 });
    const span: i32 = 8;
    var i: i32 = -span;
    while (i < span) : (i += 1) {
        var j: i32 = -span;
        while (j < span) : (j += 1) {
            const x: f32 = float(j);
            const y: f32 = float(i);
            try attachOffsetBox(world, body, 0.5, 0.5, .{ x, y }, 1);
        }
    }
}

fn benchmarkRain(world: *phys.World, st: *SceneState) !void {
    // "Rain": ragdolls spawn in groups over time and pile up on the ground (update hook). (box2d
    // rains ~1000 humans through a recycling ring buffer; we spawn a small capped number.)
    _ = try groundBox(world, 40, 1);
    st.u[0] = 0;
    st.f[0] = 0;
}

fn benchmarkRainUpdate(world: *phys.World, st: *SceneState) void {
    const dt: f32 = 1.0 / 60.0;
    st.f[0] += dt;
    if (st.u[0] < 8 and st.f[0] >= 0.8) {
        st.f[0] = 0;
        const col: f32 = float(st.u[0]);
        const x: f32 = -14.0 + col * 4.0;
        makeRagdoll(world, x, 18, 0.9) catch assertUnreachable(@src(), "OOM", .{});
        st.u[0] += 1;
    }
}

fn benchmarkCapacity(world: *phys.World) !void {
    // A large number of small bodies dropped into a bin — exercises body-pool capacity. (box2d
    // spawns many more; reduced for the phone.)
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, ground, 25, 1, .{ 0, 0 }, 1);
    try attachOffsetBox(world, ground, 1, 15, .{ -25, 15 }, 1);
    try attachOffsetBox(world, ground, 1, 15, .{ 25, 15 }, 1);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var j: usize = 0;
        while (j < 25) : (j += 1) {
            const x: f32 = (float(i) - 20.0) * 1.1;
            const y: f32 = 2.0 + float(j) * 1.1;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachCircle(world, b, .{ .r = 0.45 });
        }
    }
}

/// A static U-shaped bin: a floor plus two side walls, centred on the origin. Returns the ground
/// body. box2d's benchmark bins are built from ~280 little boxes; three large boxes read identically
/// for our purposes and leave more of the body pool for the dynamic payload.
fn benchBin(
    world: *phys.World,
    half_w: f32,
    wall_h: f32,
) !BodyHandle {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, half_w, 0.5, .{ 0, 0 }, 1);
    try attachOffsetBox(world, g, 0.5, wall_h, .{ -half_w - 0.5, wall_h }, 1);
    try attachOffsetBox(world, g, 0.5, wall_h, .{ half_w + 0.5, wall_h }, 1);
    return g;
}

fn benchmarkCompounds(world: *phys.World) !void {
    // A grid of two-triangle compound bodies dropped into a bin — box2d's compound-collision
    // benchmark (3000 bodies there; reduced for the phone). Each body carries a left and right
    // triangle hull that together read as a hollow wedge.
    _ = try benchBin(world, 15, 20);

    const left_pts = [3]Vec2{ .{ -1, 0 }, .{ 0.5, 1 }, .{ 0, 2 } };
    const right_pts = [3]Vec2{ .{ 1, 0 }, .{ -0.5, 1 }, .{ 0, 2 } };
    const left: phys.Polygon = phys.makePolygon(phys.computeHull(&left_pts), 0);
    const right: phys.Polygon = phys.makePolygon(phys.computeHull(&right_pts), 0);

    const columns: usize = 14;
    const rows: usize = 14;
    const shift: f32 = 2.0;
    const extray: f32 = 0.25;
    const centerx: f32 = shift * float(columns) / 2.0 - 1.0;
    const centery: f32 = 1.15 / 2.0;
    const y_start: f32 = 5.0;
    var side: f32 = 0.25;
    var i: usize = 0;
    while (i < columns) : (i += 1) {
        const x: f32 = float(i) * shift - centerx;
        var j: usize = 0;
        while (j < rows) : (j += 1) {
            const y: f32 = float(j) * (shift + extray) + centery + y_start;
            const b: BodyHandle = try addBody(world, .{ .x = x + side, .y = y });
            side = -side;
            _ = try phys.createShape(world, b, .{
                .geom = .{ .polygon = left },
                .density = 1,
                .material = .{ .friction = 0.5 },
            });
            _ = try phys.createShape(world, b, .{
                .geom = .{ .polygon = right },
                .density = 1,
                .material = .{ .friction = 0.5 },
            });
        }
    }
}

/// A cheap deterministic hash → [0,1), so the barrel's mixed shapes vary without an RNG.
fn hash01(n: f32) f32 {
    const h: f32 = @sin(n * 12.9898) * 43758.5453;
    return h - @floor(h);
}

fn benchmarkBarrel(world: *phys.World) !void {
    // A bin packed with a grid of mixed shapes — circles, capsules, rounded boxes, and wedges —
    // box2d's "Barrel" benchmark in its mixed-shape mode. Sizes vary deterministically per index.
    _ = try benchBin(world, 11, 22);

    const wedge_pts = [3]Vec2{ .{ -0.1, -0.5 }, .{ 0.1, -0.5 }, .{ 0, 0.5 } };
    const wedge: phys.Polygon = phys.makePolygon(phys.computeHull(&wedge_pts), 0);

    const columns: usize = 14;
    const rows: usize = 22;
    const shift: f32 = 1.15;
    const centerx: f32 = shift * float(columns) / 2.0;
    var index: usize = 0;
    var i: usize = 0;
    while (i < columns) : (i += 1) {
        const x: f32 = float(i) * shift - centerx;
        var j: usize = 0;
        while (j < rows) : (j += 1) {
            const y: f32 = 1.0 + float(j) * 1.3;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            const fi: f32 = float(index);
            const r: f32 = hash01(fi);
            switch (index % 4) {
                0 => try attachCircle(world, b, .{
                    .r = 0.25 + 0.5 * r,
                    .density = 1,
                    .friction = 0.5,
                    .rolling = 0.2,
                }),
                1 => try attachCapsule(world, b, .{
                    .half_len = 0.125 + 0.375 * r,
                    .r = 0.25 + 0.25 * hash01(fi + 7),
                    .density = 1,
                    .friction = 0.5,
                }),
                2 => try attachBox(world, b, .{
                    .hw = 0.1 + 0.4 * r,
                    .hh = 0.5 + 0.25 * hash01(fi + 3),
                    .round = 0.25 * hash01(fi + 5),
                    .density = 1,
                    .friction = 0.5,
                }),
                else => _ = try phys.createShape(world, b, .{
                    .geom = .{ .polygon = wedge },
                    .density = 1,
                    .material = .{ .friction = 0.5 },
                }),
            }
            index += 1;
        }
    }
}

fn labShapeDistance(ctx: *render.LabCtx) void {
    // GJK distance between a fixed box A at the origin and a box B that follows the pointer:
    // draws the two closest points and the segment between them (collapses when overlapping).
    const a_pts = [4]Vec2{ .{ -1.5, -1 }, .{ 1.5, -1 }, .{ 1.5, 1 }, .{ -1.5, 1 } };
    const b_pts = [4]Vec2{ .{ -0.8, -0.6 }, .{ 0.8, -0.6 }, .{ 0.8, 0.6 }, .{ -0.8, 0.6 } };
    const input: phys.DistanceInput = .{
        .proxy_a = phys.makeProxy(&a_pts, 0),
        .proxy_b = phys.makeProxy(&b_pts, 0),
        .transform = .{ .p = ctx.pointer, .q = Rot2.identity },
        .use_radii = false,
    };
    var cache: phys.SimplexCache = phys.SimplexCache.empty;
    const out: phys.DistanceOutput = phys.shapeDistance(&input, &cache);
    ctx.rect(.{ -1.5, -1 }, .{ 1.5, 1 }, c_dim, 1.5);
    ctx.rect(
        .{ ctx.pointer[0] - 0.8, ctx.pointer[1] - 0.6 },
        .{ ctx.pointer[0] + 0.8, ctx.pointer[1] + 0.6 },
        c_amber,
        1.5,
    );
    ctx.line(out.point_a, out.point_b, c_green, 2);
    ctx.mark(out.point_a, 5, c_red);
    ctx.mark(out.point_b, 5, c_red);
}

fn labManifold(ctx: *render.LabCtx) void {
    // Contact manifold between a fixed box A at the origin and a slowly rotating box B at the
    // pointer: draws the manifold points and the contact normal (pointing A -> B).
    const a: phys.Polygon = phys.makeBox(1.5, 1.0);
    const b: phys.Polygon = phys.makeBox(1.0, 0.8);
    const ang: f32 = ctx.time * 0.5;
    const ca: f32 = @cos(ang);
    const sa: f32 = @sin(ang);
    const xf: phys.Transform2 = .{ .p = ctx.pointer, .q = Rot2.fromAngle(ang) };
    const m: phys.LocalManifold = phys.collidePolygons(a, b, xf);
    ctx.rect(.{ -1.5, -1 }, .{ 1.5, 1 }, c_dim, 1.5);
    const bx = [4]Vec2{ .{ -1, -0.8 }, .{ 1, -0.8 }, .{ 1, 0.8 }, .{ -1, 0.8 } };
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const p0: Vec2 = bx[k];
        const p1: Vec2 = bx[(k + 1) % 4];
        const w0: Vec2 = .{ ctx.pointer[0] + ca * p0[0] - sa * p0[1], ctx.pointer[1] + sa * p0[0] + ca * p0[1] };
        const w1: Vec2 = .{ ctx.pointer[0] + ca * p1[0] - sa * p1[1], ctx.pointer[1] + sa * p1[0] + ca * p1[1] };
        ctx.line(w0, w1, c_amber, 1.5);
    }
    const cnt: usize = m.count;
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        const p: Vec2 = m.points[i].point;
        ctx.mark(p, 5, c_red);
        const tip: Vec2 = .{ p[0] + m.normal[0], p[1] + m.normal[1] };
        ctx.arrow(p, tip, c_green, 2);
    }
}

fn labCastWorldLab(ctx: *render.LabCtx) void {
    // A full fan of rays cast from a point against the whole world; each ray stops at its closest
    // hit, and the fan rotates slowly. (box2d's Cast World stress-tests many world ray casts.)
    const origin: Vec2 = .{ 0, 1 };
    const n: usize = 32;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const frac: f32 = float(i) / float(n);
        const ang: f32 = frac * 2.0 * pi + ctx.time * 0.2;
        const dir: Vec2 = .{ @cos(ang) * 20.0, @sin(ang) * 20.0 };
        const hit: ?phys.RayResult = phys.castRayClosest(ctx.world, origin, dir, .{});
        if (hit) |rr| {
            ctx.line(origin, rr.point, c_amber, 1);
            ctx.mark(rr.point, 3, c_red);
        } else {
            ctx.line(origin, .{ origin[0] + dir[0], origin[1] + dir[1] }, c_dim, 1);
        }
    }
    ctx.mark(origin, 5, c_green);
}

fn labSmoothManifoldLab(ctx: *render.LabCtx) void {
    // Manifold between a CHAIN SEGMENT (with ghost vertices that smooth the joins to neighbouring
    // segments) and a box at the pointer: collideChainSegmentAndPolygon. Ghost links drawn dim.
    const seg: phys.ChainSegment = .{
        .ghost1 = .{ -6, 1 },
        .segment = .{ .point1 = .{ -3, 0 }, .point2 = .{ 3, 0.6 } },
        .ghost2 = .{ 6, 2.5 },
        .chain_id = phys.null_index,
    };
    const poly: phys.Polygon = phys.makeBox(0.9, 0.6);
    const ang: f32 = ctx.time * 0.5;
    const ca: f32 = @cos(ang);
    const sa: f32 = @sin(ang);
    const xf: phys.Transform2 = .{ .p = ctx.pointer, .q = Rot2.fromAngle(ang) };
    var cache: phys.SimplexCache = phys.SimplexCache.empty;
    const m: phys.LocalManifold = phys.collideChainSegmentAndPolygon(seg, poly, xf, &cache);
    ctx.line(.{ -6, 1 }, .{ -3, 0 }, c_dim, 1);
    ctx.line(.{ -3, 0 }, .{ 3, 0.6 }, c_amber, 2);
    ctx.line(.{ 3, 0.6 }, .{ 6, 2.5 }, c_dim, 1);
    const bx = [4]Vec2{ .{ -0.9, -0.6 }, .{ 0.9, -0.6 }, .{ 0.9, 0.6 }, .{ -0.9, 0.6 } };
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const p0: Vec2 = bx[k];
        const p1: Vec2 = bx[(k + 1) % 4];
        const w0: Vec2 = .{ ctx.pointer[0] + ca * p0[0] - sa * p0[1], ctx.pointer[1] + sa * p0[0] + ca * p0[1] };
        const w1: Vec2 = .{ ctx.pointer[0] + ca * p1[0] - sa * p1[1], ctx.pointer[1] + sa * p1[0] + ca * p1[1] };
        ctx.line(w0, w1, c_green, 1.5);
    }
    const cnt: usize = m.count;
    var i: usize = 0;
    while (i < cnt) : (i += 1) {
        const p: Vec2 = m.points[i].point;
        ctx.mark(p, 5, c_red);
        const tip: Vec2 = .{ p[0] + m.normal[0], p[1] + m.normal[1] };
        ctx.arrow(p, tip, c_amber, 2);
    }
}

fn labTimeOfImpactLab(ctx: *render.LabCtx) void {
    // Box A sweeps left -> right at the pointer's height toward a fixed box B at the origin; draws
    // A's start/end (dim) and its pose at the first time of impact (bright). timeOfImpact.
    const a_pts = [4]Vec2{ .{ -0.6, -0.6 }, .{ 0.6, -0.6 }, .{ 0.6, 0.6 }, .{ -0.6, 0.6 } };
    const b_pts = [4]Vec2{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const h: f32 = ctx.pointer[1];
    const sweep_a: phys.Sweep2 = .{
        .local_center = .{ 0, 0 },
        .c1 = .{ -8, h },
        .c2 = .{ 8, h },
        .q1 = Rot2.identity,
        .q2 = Rot2.identity,
    };
    const sweep_b: phys.Sweep2 = .{
        .local_center = .{ 0, 0 },
        .c1 = .{ 0, 0 },
        .c2 = .{ 0, 0 },
        .q1 = Rot2.identity,
        .q2 = Rot2.identity,
    };
    const input: phys.TOIInput = .{
        .proxy_a = phys.makeProxy(&a_pts, 0),
        .proxy_b = phys.makeProxy(&b_pts, 0),
        .sweep_a = sweep_a,
        .sweep_b = sweep_b,
        .max_fraction = 1,
    };
    const out: phys.TOIOutput = phys.timeOfImpact(&input);
    ctx.rect(.{ -1, -1 }, .{ 1, 1 }, c_amber, 1.5);
    ctx.rect(.{ -8.6, h - 0.6 }, .{ -7.4, h + 0.6 }, c_dim, 1);
    ctx.rect(.{ 7.4, h - 0.6 }, .{ 8.6, h + 0.6 }, c_dim, 1);
    if (out.state == .hit or out.state == .overlapped) {
        const ax: f32 = -8.0 + 16.0 * out.fraction;
        ctx.rect(
            .{ ax - 0.6, h - 0.6 },
            .{ ax + 0.6, h + 0.6 },
            c_green,
            2,
        );
        ctx.mark(out.point, 5, c_red);
    }
}

// ---- Shapes (chains / conveyor) ----

fn shapesTangentSpeed(world: *phys.World) !void {
    // A conveyor belt split into sections of increasing tangent speed (the surface material drags
    // contacting bodies along the tangent); a ball on each section is carried at a different speed.
    // (box2d uses an SVG-path loop track; we use a flat segmented belt with end walls.)
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const seg_w: f32 = 5.0;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const x0: f32 = -17.5 + float(i) * seg_w;
        const ts: f32 = -10.0 - float(i) * 10.0;
        _ = try phys.createShape(world, ground, .{
            .geom = .{ .segment = .{ .point1 = .{ x0, 0 }, .point2 = .{ x0 + seg_w, 0 } } },
            .material = .{ .friction = 0.6, .tangent_speed = ts },
        });
        const b: BodyHandle = try addBody(world, .{ .x = x0 + seg_w * 0.5, .y = 1.5 });
        try attachCircle(world, b, .{ .r = 0.5, .friction = 0.6, .rolling = 0.3 });
    }
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -17.5, 0 }, .point2 = .{ -17.5, 4 } } },
    });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ 17.5, 0 }, .point2 = .{ 17.5, 4 } } },
    });
}

fn shapesChainSegment(world: *phys.World) !void {
    // A smooth chain terrain (ghost-linked segments) shaped as a sine wave, with a ball that rolls
    // along it without catching on the segment joins.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const n: usize = 25;
    var pts: [25]Vec2 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: f32 = 25.0 - 50.0 * float(i) / float(n - 1);
        pts[i] = .{ x, 1.5 * @sin(0.18 * x) };
    }
    _ = try phys.createChain(world, ground, .{ .points = &pts, .is_loop = false });
    const ball: BodyHandle = try addBody(world, .{ .x = -18, .y = 5 });
    try attachCircle(world, ball, .{ .r = 0.5, .rolling = 0.1 });
}

fn shapesChainLink(world: *phys.World) !void {
    // Two open chains forming a thin channel; a circle, capsule, and box dropped in slide along it.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const p1 = [6]Vec2{ .{ 40, 1 }, .{ 0, 0 }, .{ -40, 0 }, .{ -40, -1 }, .{ 0, -1 }, .{ 40, -1 } };
    const p2 = [6]Vec2{ .{ -40, -1 }, .{ 0, -1 }, .{ 40, -1 }, .{ 40, 0 }, .{ 0, 0 }, .{ -40, 0 } };
    _ = try phys.createChain(world, ground, .{ .points = &p1, .is_loop = false });
    _ = try phys.createChain(world, ground, .{ .points = &p2, .is_loop = false });
    const c: BodyHandle = try addBody(world, .{ .x = -5, .y = 2 });
    try attachCircle(world, c, .{ .r = 0.5 });
    const cap: BodyHandle = try addBody(world, .{ .x = 0, .y = 2 });
    try attachCapsule(world, cap, .{ .half_len = 0.5, .r = 0.25, .horizontal = true });
    const box: BodyHandle = try addBody(world, .{ .x = 5, .y = 2 });
    try attachBox(world, box, .{ .hw = 0.5, .hh = 0.5 });
}

// ---- Determinism / Robustness ----

fn determinismFallingHinges(world: *phys.World) !void {
    // 4 columns of small rounded boxes, each odd box hinged to the even one below by a limited
    // revolute joint; the leaning columns topple and settle. (box2d uses this as a determinism test
    // that hashes the settled state; we just show the mechanism.)
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, ground, 40, 1, .{ 0, -1 }, 1);
    const h: f32 = 0.25;
    const r: f32 = 0.025;
    const offset: f32 = 0.4 * h;
    const dx: f32 = 10.0 * h;
    const x_base: f32 = -0.5 * dx * 3.0;
    var j: usize = 0;
    while (j < 4) : (j += 1) {
        const x: f32 = x_base + float(j) * dx;
        var prev: BodyHandle = ground;
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const fi: f32 = float(i);
            const px: f32 = x + offset * fi;
            const py: f32 = h + 2.0 * h * fi;
            const ang: f32 = if (i & 1 == 0) -0.1 else 0.1;
            const b: BodyHandle = try addBody(world, .{ .x = px, .y = py, .angle = ang });
            try attachBox(world, b, .{ .hw = h - r, .hh = h - r, .round = r });
            if (i & 1 == 0) {
                prev = b;
            } else {
                const py_prev: f32 = h + 2.0 * h * (fi - 1.0);
                try pinRevolute(world, prev, b, .{
                    .anchor = .{ px, (py + py_prev) * 0.5 },
                    .limit = true,
                    .lo = -0.1 * pi,
                    .hi = 0.2 * pi,
                });
            }
        }
    }
}

fn robustnessMultiplePrismatic(world: *phys.World) !void {
    // A tower of 6 boxes chained by stiff, limited prismatic joints (default horizontal axis) — a
    // robustness test of stacked prismatic constraints.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    var prev: BodyHandle = ground;
    var fa: Vec2 = .{ 0, 0 };
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const y: f32 = 0.6 + 1.2 * float(i);
        const b: BodyHandle = try addBody(world, .{ .x = 0, .y = y });
        try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
        _ = try phys.createPrismaticJoint(world, .{
            .base = .{
                .body_a = prev,
                .body_b = b,
                .local_frame_a = .{ .p = fa, .q = Rot2.identity },
                .local_frame_b = .{ .p = .{ 0, -0.6 }, .q = Rot2.identity },
                .constraint_hertz = 240,
            },
            .enable_limit = true,
            .lower_translation = -6,
            .upper_translation = 6,
        });
        prev = b;
        fa = .{ 0, 0.6 };
    }
}

// ---- Showcase ----

/// The CS296 "Dominos" Rube Goldberg machine (Erin Catto's classic, as used in the IIT-Bombay
/// CS296 lab). A cannon-shot ball at top-left kicks off a cascade that runs the length of the
/// scene: cannon recoil, a staircase of revolving flaps and balls down the right, a domino run,
/// a weight balance, a pulley raising a toothbrush, a centre see-saw platform, and a basin at
/// the bottom-left. Originally box2d v2 (b2EdgeShape / SetAsBox-with-offset / b2PulleyJointDef);
/// ported faithfully to our v3-style API, with the pulley joint reintroduced for this scene.
fn showcaseDominos(world: *phys.World) !void {
    world.settings.sub_step_count = 8; // many stacked joints + the pulley want extra sub-steps

    // Ground edge spanning the whole machine.
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -90, 0 }, .point2 = .{ 90, 0 } } },
    });

    // Top horizontal shelf.
    const top: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 0, 32 } });
    try attachBox(world, top, .{ .hw = 23, .hh = 0.25, .friction = 0.2 });

    // The cannon shot — launched up and to the right.
    const shot: BodyHandle = try addBody(world, .{ .x = 3, .y = 35, .vx = 17, .vy = 15 });
    try attachCircle(world, shot, .{ .r = 1, .density = 5, .friction = 0, .restitution = 0.02 });

    // The cannon: a wheel plus two heavy angled barrel walls; recoils to the left on launch.
    const cannon: BodyHandle = try addBody(world, .{ .x = 0, .y = 33, .vx = -5 });
    try attachCircle(world, cannon, .{ .r = 1.5, .density = 2.5, .friction = 1 });
    try attachRotBox(world, cannon, 4.0, 0.25, .{ 0.7, 3.5 }, pi / 4.0, 15, 1);
    try attachRotBox(world, cannon, 3.5, 0.25, .{ 4.0, 2.0 }, pi / 4.0, 15, 1);

    // The ball waiting to be struck by the recoiling cannon.
    const recoil: BodyHandle = try addBody(world, .{ .x = -4.5, .y = 33 });
    try attachCircle(world, recoil, .{ .r = 1, .density = 9, .friction = 0.1, .restitution = 0.3 });

    // Right side: angular shelf, vertical shelf, then a descending staircase.
    const ang_shelf: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachRotBox(world, ang_shelf, 5.0, 0.25, .{ 55, 30 }, pi / 18.0, 0, 0.2);

    const v_shelf: BodyHandle = try phys.createBody(world, .{
        .motion_type = .static,
        .position = .{ 60, 33 },
        .rotation = Rot2.fromAngle(pi / 2.0),
    });
    try attachBox(world, v_shelf, .{ .hw = 2, .hh = 0.25, .friction = 0.2 });

    const r_shelf1: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 45, 28 } });
    try attachBox(world, r_shelf1, .{ .hw = 3, .hh = 0.25, .friction = 0.2 });

    // Revolving flap 1: a standing plank pivoting about its base on a static hinge post.
    const plank1: BodyHandle = try addBody(world, .{ .x = 41.75, .y = 26.5 });
    try attachBox(world, plank1, .{ .hw = 0.2, .hh = 1.5, .density = 1, .friction = 0.2 });
    const hinge1: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 41.75, 28 } });
    try attachBox(world, hinge1, .{ .hw = 0.2, .hh = 2, .friction = 0.2 });
    _ = try phys.createRevoluteJoint(world, .{ .base = .{
        .body_a = plank1,
        .body_b = hinge1,
        .local_frame_a = .{ .p = .{ 0, -1.5 }, .q = Rot2.identity },
        .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
    } });

    const r_shelf2: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 38, 23 } });
    try attachBox(world, r_shelf2, .{ .hw = 3, .hh = 0.25, .friction = 0.2 });
    const obstruction: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 35, 24 } });
    try attachBox(world, obstruction, .{ .hw = 0.2, .hh = 1, .friction = 0.2 });

    // Revolving flap 2.
    const plank2: BodyHandle = try addBody(world, .{ .x = 41.25, .y = 21.5 });
    try attachBox(world, plank2, .{ .hw = 0.2, .hh = 1.5, .density = 1, .friction = 0.2 });
    const hinge2: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 41.25, 23 } });
    try attachBox(world, hinge2, .{ .hw = 0.2, .hh = 2, .friction = 0.2 });
    _ = try phys.createRevoluteJoint(world, .{ .base = .{
        .body_a = plank2,
        .body_b = hinge2,
        .local_frame_a = .{ .p = .{ 0, -1.5 }, .q = Rot2.identity },
        .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
    } });

    const r_shelf3: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 37, 18 } });
    try attachBox(world, r_shelf3, .{ .hw = 5, .hh = 0.25, .friction = 0.2 });

    // The bouncy ball that rolls off the staircase toward the dominoes.
    const r_ball: BodyHandle = try addBody(world, .{ .x = 40.5, .y = 18.5 });
    try attachCircle(world, r_ball, .{ .r = 1, .density = 1, .friction = 0, .restitution = 1 });

    const r_shelf4: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 25, 16.5 } });
    try attachBox(world, r_shelf4, .{ .hw = 4, .hh = 0.25, .friction = 0.2 });

    // The domino run.
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const dx: f32 = 21.5 + float(i);
        const dom: BodyHandle = try addBody(world, .{ .x = dx, .y = 17.5 });
        try attachBox(world, dom, .{ .hw = 0.2, .hh = 1.0, .density = 20, .friction = 0.1 });
    }

    // Lower shelf and the heavy ball the last domino topples onto.
    const bottom_shelf: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachRotBox(world, bottom_shelf, 7.0, 0.25, .{ 20, 14 }, 0, 0, 0.2);
    const d_ball: BodyHandle = try addBody(world, .{ .x = 18.5, .y = 14.5 });
    try attachCircle(world, d_ball, .{ .r = 1, .density = 13, .friction = 0, .restitution = 0.5 });

    // Weight-balance: a frame hinged at the tip of a fixed wedge.
    const wedge: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 5, 0 } });
    try attachHull(world, wedge, &.{ .{ -2, 0 }, .{ 2, 0 }, .{ 0, 4 } }, 0);
    const frame: BodyHandle = try addBody(world, .{ .x = 5, .y = 4 });
    try attachOffsetBox(world, frame, 6.0, 0.25, .{ 0, 0 }, 1);
    try attachOffsetBox(world, frame, 0.25, 2.0, .{ 5.5, 2.0 }, 0);
    try attachOffsetBox(world, frame, 2.0, 0.2, .{ 5.5, 4.0 }, 0);
    try attachOffsetBox(world, frame, 0.2, 2.0, .{ 3.75, 5.75 }, 0);
    try attachOffsetBox(world, frame, 0.2, 2.0, .{ 7.25, 5.75 }, 0);
    try attachOffsetBox(world, frame, 0.25, 4.0, .{ -5.5, 3.5 }, 0);
    try attachOffsetBox(world, frame, 2.0, 0.2, .{ -5.5, 7.0 }, 0);
    try pinRevolute(world, frame, wedge, .{ .anchor = .{ 5, 4 } });

    // The left pulley: an open carrier box and a heavy "toothbrush" frame over two ground anchors.
    const box1: BodyHandle = try addBody(world, .{ .x = -22, .y = 23, .lock_rot = true });
    try attachRotBox(world, box1, 2.0, 0.2, .{ 0, -13.9 }, 0, 10, 0.5);
    try attachRotBox(world, box1, 0.2, 2.0, .{ 2, -12 }, 0, 10, 0.5);
    try attachRotBox(world, box1, 0.2, 2.0, .{ -2, -12 }, 0, 10, 0.5);

    const box2: BodyHandle = try addBody(world, .{ .x = -5, .y = 15, .lock_rot = true });
    try attachRotBox(world, box2, 3.5, 0.2, .{ 0, -13.9 }, 0, 18, 0.5);
    try attachRotBox(world, box2, 0.1, 0.6, .{ 3.5, -13.4 }, 0, 0, 0.5);
    try attachRotBox(world, box2, 0.1, 0.6, .{ 2.5, -13.4 }, 0, 0, 0.5);

    _ = try phys.createPulleyJoint(world, .{
        .base = .{ .body_a = box1, .body_b = box2 },
        .ground_anchor_a = .{ -22, 25 },
        .ground_anchor_b = .{ -5, 25 },
        .ratio = 1,
    });

    // Centre see-saw platform pivoting on a static hinge post; a heavy bead lands on it.
    const platform: BodyHandle = try addBody(world, .{ .x = 1, .y = 12.5 });
    try attachBox(world, platform, .{ .hw = 5.2, .hh = 0.2, .density = 1, .friction = 0.2 });
    const p_hinge: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 1, 14.5 } });
    try attachBox(world, p_hinge, .{ .hw = 0.2, .hh = 2, .friction = 0.2 });
    _ = try phys.createRevoluteJoint(world, .{ .base = .{
        .body_a = platform,
        .body_b = p_hinge,
        .local_frame_a = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
    } });
    const bead: BodyHandle = try addBody(world, .{ .x = 1, .y = 16 });
    try attachCircle(world, bead, .{ .r = 0.3, .density = 2, .friction = 0, .restitution = 0 });

    // Bottom-left see-saw: a plank balanced on a fixed wedge, weighted on one end.
    const saw_wedge: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ -35, 0 } });
    try attachHull(world, saw_wedge, &.{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, 3 } }, 0);
    const saw_plank: BodyHandle = try addBody(world, .{ .x = -35, .y = 3 });
    try attachBox(world, saw_plank, .{ .hw = 10, .hh = 0.2, .density = 0.8, .friction = 0.2 });
    try attachOffsetBox(world, saw_plank, 0.2, 1.0, .{ 10, 1 }, 0);
    try pinRevolute(world, saw_wedge, saw_plank, .{ .anchor = .{ -35, 3 } });
    const light_box: BodyHandle = try addBody(world, .{ .x = -41, .y = 3.5 });
    try attachBox(world, light_box, .{ .hw = 1, .hh = 1, .density = 1, .friction = 0.2 });
    const stop_box: BodyHandle = try addBody(world, .{ .x = -43, .y = 0.5 });
    try attachBox(world, stop_box, .{ .hw = 1, .hh = 1.5, .density = 0.01, .friction = 0.2 });

    // The basin at the bottom-left holding a block of "water".
    const basin: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, basin, .{
        .geom = .{ .segment = .{ .point1 = .{ -0.7, 3 }, .point2 = .{ -0.7, 0 } } },
    });
    _ = try phys.createShape(world, basin, .{
        .geom = .{ .segment = .{ .point1 = .{ -9, 3 }, .point2 = .{ -9, 0 } } },
    });
    const water: BodyHandle = try addBody(world, .{ .x = -4.8, .y = 1 });
    try attachBox(world, water, .{ .hw = 4.1, .hh = 1, .density = 1, .friction = 0.2 });
}

// ================================================================================
// Benchmark — Washer (spinning ring drum)
// ================================================================================

// A kinematic "washer" ring spun slowly: 36 wedge polygons (between r1..r2) plus 4 inner spokes
// (r0..r1), churning a grid of small dynamic squares that fall into it. box2d CreateWasher uses a
// 90x90 grid (8100 squares); the physics + growable pools handle that fine (~70ms/step on device),
// but the debug-draw vertex ring (gpu_iface.vbo_ring_vertices = 262144) overflows past ~8000 bodies
// and the demo's 60Hz fixed step can't keep real-time at 70ms/step. So the shipped grid is 62x62
// (~3844 squares) — under the vertex ring, and deliberately large so the broad-phase cost (the
// dominant term once the pile densifies) is visible in the perf overlay. The growability proof
// lives in the host harnesses; this scene is tuned to be playable.
fn benchmarkWasher(world: *phys.World) !void {
    const r0: f32 = 14;
    const r1: f32 = 16;
    const r2: f32 = 18;
    const motor_speed: f32 = (pi / 180.0) * 25.0; // 25 deg/s
    const drum: BodyHandle = try addBody(world, .{
        .motion = .kinematic,
        .x = 0,
        .y = 10,
        .w = motor_speed,
        .vx = 0.001,
        .vy = -0.002,
    });
    const seg: Rot2 = Rot2.fromAngle(pi / 18.0); // 10 deg per wedge
    const qo: Rot2 = Rot2.fromAngle(0.1 * (pi / 18.0));
    const qo_inv: Rot2 = qo.invert();
    var dir_a: Vec2 = .{ 1, 0 };
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        var dir_b: Vec2 = .{ 1, 0 };
        if (i != 35) {
            dir_b = rotateVec2(seg, dir_a);
        }
        const a1: Vec2 = rotateVec2(qo_inv, dir_a);
        const a2: Vec2 = rotateVec2(qo, dir_b);
        const ring = [_]Vec2{
            a1 * @as(Vec2, @splat(r1)),
            a1 * @as(Vec2, @splat(r2)),
            a2 * @as(Vec2, @splat(r1)),
            a2 * @as(Vec2, @splat(r2)),
        };
        const ring_hull: phys.Hull = phys.computeHull(&ring);
        _ = try phys.createShape(world, drum, .{ .geom = .{ .polygon = phys.makePolygon(ring_hull, 0) } });
        if (i % 9 == 0) {
            const spoke = [_]Vec2{
                dir_a * @as(Vec2, @splat(r0)),
                dir_a * @as(Vec2, @splat(r1)),
                dir_b * @as(Vec2, @splat(r0)),
                dir_b * @as(Vec2, @splat(r1)),
            };
            const spoke_hull: phys.Hull = phys.computeHull(&spoke);
            _ = try phys.createShape(world, drum, .{ .geom = .{ .polygon = phys.makePolygon(spoke_hull, 0) } });
        }
        dir_a = dir_b;
    }
    const grid_count: usize = 62;
    const a: f32 = 0.1;
    const cell: phys.Polygon = phys.makeSquare(a);
    const gc_f: f32 = float(grid_count);
    var y: f32 = -1.1 * a * gc_f + 10.0;
    var gi: usize = 0;
    while (gi < grid_count) : (gi += 1) {
        var x: f32 = -1.1 * a * gc_f;
        var gj: usize = 0;
        while (gj < grid_count) : (gj += 1) {
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            _ = try phys.createShape(world, b, .{
                .geom = .{ .polygon = cell },
                .density = 1,
                .enable_hit_events = true,
            });
            x += 2.1 * a;
        }
        y += 2.1 * a;
    }
}

// ================================================================================
// Issues (box2d robustness / solver repros)
// ================================================================================

// A near-degenerate sliver triangle — three almost-collinear points sitting far from the body
// origin — dropped onto a segment. Stresses hull centroid and the "bad Steiner point" inertia path.
fn issuesDisable(world: *phys.World, st: *SceneState) !void {
    // box2d Issues|Disable: a dynamic "attachment" arm jointed to a static platform by a motorised
    // revolute. box2d toggles b2Body_Disable/Enable on the arm via a checkbox; here it is automated
    // on a timer — the swinging arm vanishes from the sim and reappears, its joint going inactive and
    // restoring cleanly (the crash this scene originally guarded against).
    const attach: BodyHandle = try addBody(world, .{ .x = -2, .y = 3 });
    try attachBox(world, attach, .{ .hw = 0.5, .hh = 2.0 });

    const platform: BodyHandle = try addBody(world, .{ .x = -4, .y = 5, .motion = .static });
    _ = try phys.createShape(world, platform, .{
        .geom = .{ .polygon = phys.makeOffsetBox(0.5, 4.0, .{ 4, 0 }, Rot2.fromAngle(0.5 * pi)) },
    });

    try pinRevolute(world, attach, platform, .{
        .anchor = .{ -2, 5 },
        .motor = true,
        .torque = 50,
        .speed = 0.6,
    });

    st.body[0] = attach;
    st.u[0] = 0; // frame counter
    st.u[1] = 0; // 0 = enabled, 1 = disabled
}

fn issuesDisableUpdate(world: *phys.World, st: *SceneState) void {
    st.u[0] += 1;
    if (st.u[0] < 100) {
        return;
    }
    st.u[0] = 0;
    const attach: BodyHandle = st.body[0];
    if (st.u[1] == 0) {
        phys.disableBody(world, attach);
        st.u[1] = 1;
    } else {
        phys.enableBody(world, attach) catch assertUnreachable(@src(), "OOM", .{});
        st.u[1] = 0;
    }
}

fn issuesBadSteiner(world: *phys.World) !void {
    _ = try groundSegment(world, 100);
    const body: BodyHandle = try addBody(world, .{ .x = -48, .y = 62 });
    const pts = [_]Vec2{
        .{ 48.7599983, -60.5699997 },
        .{ 48.7400017, -60.5400009 },
        .{ 48.6800003, -60.5600014 },
    };
    try attachHull(world, body, &pts, 1);
}

// A dynamic platform held by a motorised revolute to a hanging attachment AND a limited, motorised
// prismatic to ground — the original mixed-joint crash repro, shown in its default dynamic state.
fn issuesCrash01(world: *phys.World) !void {
    const ground: BodyHandle = try groundSegment(world, 20);
    const attach: BodyHandle = try addBody(world, .{ .x = -2, .y = 3 });
    try attachBox(world, attach, .{ .hw = 0.5, .hh = 2, .density = 1 });
    const platform: BodyHandle = try addBody(world, .{ .x = -4, .y = 5 });
    try attachRotBox(world, platform, 0.5, 4, .{ 4, 0 }, pi * 0.5, 2, 0.6);
    try pinRevolute(world, attach, platform, .{ .anchor = .{ -2, 5 }, .motor = true, .torque = 50 });
    try pinPrismatic(world, ground, platform, .{
        .anchor = .{ 0, 5 },
        .motor = true,
        .force = 1000,
        .limit = true,
        .lo = -10,
        .hi = 10,
    });
}

// A bullet fired at very high speed into a static polygon — a continuous-collision repro that once
// tunnelled straight through the static shape.
fn issuesStaticVsBullet(world: *phys.World) !void {
    const wall: BodyHandle = try addBody(world, .{ .motion = .static });
    const verts = [_]Vec2{
        .{ 48.8525391, 68.1518555 },
        .{ 49.1821289, 68.1152344 },
        .{ 68.8476562, 68.1152344 },
        .{ 68.8476562, 70.2392578 },
        .{ 48.8525391, 70.2392578 },
    };
    const hull: phys.Hull = phys.computeHull(&verts);
    _ = try phys.createShape(world, wall, .{
        .geom = .{ .polygon = phys.makePolygon(hull, 0) },
        .material = .{ .friction = 0.5, .restitution = 0.1 },
    });
    const ball: BodyHandle = try addBody(world, .{
        .x = 58.9243050,
        .y = 77.5401459,
        .vx = 104.868881,
        .vy = -281.073883,
        .bullet = true,
        .lock_rot = true,
    });
    try attachCircle(world, ball, .{ .r = 0.3, .density = 3, .friction = 0.2, .restitution = 0.9 });
}

// A light centre mass between two heavy circles on stiff spring-prismatics — a solver stress test
// that jitters (diverges) when the middle mass is too small or the sub-step count too low.
fn issuesUnstablePrismatic(world: *phys.World) !void {
    _ = try groundSegment(world, 100);
    const center: BodyHandle = try addBody(world, .{ .x = 0, .y = 3 });
    try attachCircle(world, center, .{ .r = 0.5 });
    const left: BodyHandle = try addBody(world, .{ .x = -3.5, .y = 3 });
    try attachCircle(world, left, .{ .r = 2 });
    _ = try phys.createPrismaticJoint(world, .{
        .base = .{ .body_a = center, .body_b = left },
        .enable_spring = true,
        .hertz = 10,
        .damping_ratio = 2,
        .target_translation = -3,
    });
    const right: BodyHandle = try addBody(world, .{ .x = 3.5, .y = 3 });
    try attachCircle(world, right, .{ .r = 2 });
    _ = try phys.createPrismaticJoint(world, .{
        .base = .{ .body_a = center, .body_b = right },
        .enable_spring = true,
        .hertz = 10,
        .damping_ratio = 2,
        .target_translation = 3,
    });
}

// One arm of the windmill: a box welded to the central disc with a stiff base constraint.
fn weldRotor(
    world: *phys.World,
    center: BodyHandle,
    pos: Vec2,
    hw: f32,
    hh: f32,
    frame_a: Vec2,
    frame_b: Vec2,
) !void {
    const body: BodyHandle = try addBody(world, .{ .x = pos[0], .y = pos[1], .gravity_scale = 0 });
    try attachBox(world, body, .{ .hw = hw, .hh = hh, .friction = 0.1 });
    _ = try phys.createWeldJoint(world, .{ .base = .{
        .body_a = center,
        .body_b = body,
        .local_frame_a = .{ .p = frame_a, .q = Rot2.identity },
        .local_frame_b = .{ .p = frame_b, .q = Rot2.identity },
        .constraint_hertz = 30,
    } });
}

// Four box rotors rigidly welded around a gravity-free central disc with a stiff constraint hertz —
// a weld-joint stability test; the high stiffness makes the windmill wobble rather than hold rigid.
fn issuesUnstableWindmill(world: *phys.World) !void {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, g, .{
        .geom = .{ .segment = .{ .point1 = .{ -100, -10 }, .point2 = .{ 100, -10 } } },
    });
    const center: BodyHandle = try addBody(world, .{ .x = 10, .y = 10, .gravity_scale = 0 });
    try attachCircle(world, center, .{ .r = 5, .friction = 0.1 });
    try weldRotor(world, center, .{ 10, 0 }, 4, 5, .{ 0, -5 }, .{ 0, 5 });
    try weldRotor(world, center, .{ 20, 10 }, 5, 4, .{ 5, 0 }, .{ -5, 0 });
    try weldRotor(world, center, .{ 10, 20 }, 4, 5, .{ 0, 5 }, .{ 0, -5 });
    try weldRotor(world, center, .{ 0, 10 }, 5, 4, .{ -5, 0 }, .{ 5, 0 });
}

// Tiny deterministic LCG used to scatter benchmark fields reproducibly (no global rng state).
fn rngNext(seed: *u32) f32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    const bits: u32 = seed.* >> 8;
    return float(bits) / float(@as(u32, 1) << 24);
}

fn rngRange(
    seed: *u32,
    lo: f32,
    hi: f32,
) f32 {
    return lo + (hi - lo) * rngNext(seed);
}

// box2d Benchmark|Cast, scaled for the device (the original is a 1000x1000 grid of ~100k boxes
// with 10k rays/frame for desktop timing). A scattered field of small static boxes that
// benchmarkCastLab sweeps a 360-degree ray fan across, exercising castRayClosest ~200x/frame.
fn benchmarkCast(world: *phys.World) !void {
    var seed: u32 = 1234;
    var i: u32 = 0;
    while (i < 240) : (i += 1) {
        const x: f32 = rngRange(&seed, -13, 13);
        const y: f32 = rngRange(&seed, -13, 13);
        const hw: f32 = rngRange(&seed, 0.18, 0.7);
        const hh: f32 = rngRange(&seed, 0.18, 0.7);
        const ang: f32 = rngRange(&seed, 0, pi);
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y, .angle = ang, .motion = .static });
        try attachBox(world, b, .{ .hw = hw, .hh = hh });
    }
}

fn benchmarkCastLab(ctx: *render.LabCtx) void {
    const n: u32 = 200;
    const origin: Vec2 = .{ 3.0 * @cos(ctx.time * 0.6), 3.0 * @sin(ctx.time * 0.6) };
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const a: f32 = (float(k) / float(n)) * 2.0 * pi;
        const dir: Vec2 = .{ 30.0 * @cos(a), 30.0 * @sin(a) };
        const hit: ?phys.RayResult = phys.castRayClosest(ctx.world, origin, dir, .{});
        if (hit) |rr| {
            ctx.line(origin, rr.point, c_amber, 1);
            ctx.mark(rr.point, 2, c_red);
        }
    }
    ctx.mark(origin, 4, c_green);
}

// box2d Benchmark|Shape Distance, scaled: a probe box (follows the pointer) vs a ring of fixed
// boxes; recomputes the GJK distance to every box each frame and draws the closest-point segment.
fn benchmarkShapeDistanceLab(ctx: *render.LabCtx) void {
    const b_pts = [4]Vec2{ .{ -0.6, -0.45 }, .{ 0.6, -0.45 }, .{ 0.6, 0.45 }, .{ -0.6, 0.45 } };
    const n: u32 = 48;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const a: f32 = (float(k) / float(n)) * 2.0 * pi;
        const cx: f32 = 9.0 * @cos(a);
        const cy: f32 = 9.0 * @sin(a);
        const a_pts = [4]Vec2{
            .{ cx - 0.5, cy - 0.5 },
            .{ cx + 0.5, cy - 0.5 },
            .{ cx + 0.5, cy + 0.5 },
            .{ cx - 0.5, cy + 0.5 },
        };
        const input: phys.DistanceInput = .{
            .proxy_a = phys.makeProxy(&a_pts, 0),
            .proxy_b = phys.makeProxy(&b_pts, 0),
            .transform = .{ .p = ctx.pointer, .q = Rot2.identity },
            .use_radii = false,
        };
        var cache: phys.SimplexCache = phys.SimplexCache.empty;
        const out: phys.DistanceOutput = phys.shapeDistance(&input, &cache);
        ctx.rect(.{ cx - 0.5, cy - 0.5 }, .{ cx + 0.5, cy + 0.5 }, c_dim, 1.0);
        ctx.line(out.point_a, out.point_b, c_green, 1.5);
    }
    ctx.rect(
        .{ ctx.pointer[0] - 0.6, ctx.pointer[1] - 0.45 },
        .{ ctx.pointer[0] + 0.6, ctx.pointer[1] + 0.45 },
        c_amber,
        1.5,
    );
}

// box2d Benchmark|CreateDestroy rebuilds a 100-row pyramid every frame to time the create/destroy
// paths. A scene here can only track a few handles, so we churn a small cluster instead: every
// ~0.45s the four boxes are destroyed and respawned at the top (they fall in between) — the same
// create/destroy exercise, device-sized.
fn benchmarkCreateDestroy(world: *phys.World, st: *SceneState) !void {
    _ = try groundBox(world, 14, 1);
    st.u[0] = 0; // 0 = nothing spawned yet, 1 = cluster live
    st.f[0] = 0; // cycle timer
}

fn benchmarkCreateDestroyUpdate(world: *phys.World, st: *SceneState) void {
    const dt: f32 = 1.0 / 60.0;
    st.f[0] += dt;
    if (st.u[0] == 1 and st.f[0] < 0.45) {
        return;
    }
    st.f[0] = 0;
    if (st.u[0] == 1) {
        var d: u32 = 0;
        while (d < 4) : (d += 1) {
            phys.destroyBody(world, st.body[d]);
        }
    }
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const col: f32 = float(i % 2);
        const row: f32 = float(i / 2);
        st.body[i] = addBody(world, .{ .x = -0.6 + col * 1.2, .y = 11.0 + row * 1.2 }) catch return;
        attachBox(world, st.body[i], .{ .hw = 0.5, .hh = 0.5 }) catch return;
    }
    st.u[0] = 1;
}

// box2d Collision|Dynamic Tree visualizes the broad-phase AABB tree (the original packs ~1e6 proxies
// into a standalone tree). Here we draw the LIVE world tree over a bin of falling boxes: a pile that
// keeps moving makes the tree restructure, so the internal node boxes (dim) shift around the leaves.
fn collisionDynamicTree(world: *phys.World) !void {
    _ = try groundBox(world, 14, 1);
    const lw: BodyHandle = try addBody(world, .{ .x = -13, .y = 6, .motion = .static });
    try attachBox(world, lw, .{ .hw = 0.5, .hh = 7 });
    const rw: BodyHandle = try addBody(world, .{ .x = 13, .y = 6, .motion = .static });
    try attachBox(world, rw, .{ .hw = 0.5, .hh = 7 });
    var seed: u32 = 7;
    var i: u32 = 0;
    while (i < 48) : (i += 1) {
        const x: f32 = rngRange(&seed, -11, 11);
        const y: f32 = rngRange(&seed, 3, 16);
        const ang: f32 = rngRange(&seed, 0, pi);
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y, .angle = ang });
        try attachBox(world, b, .{ .hw = rngRange(&seed, 0.3, 0.6), .hh = rngRange(&seed, 0.3, 0.6) });
    }
}

fn drawTreeNode(
    ctx: *render.LabCtx,
    tree: *const phys.DynamicTree,
    idx: i32,
) void {
    if (idx < 0) {
        return;
    }
    const node: phys.TreeNode = tree.nodes.items[@intCast(idx)];
    if (node.child1 < 0) {
        ctx.rect(node.aabb.lower, node.aabb.upper, c_green, 1.5);
    } else {
        ctx.rect(node.aabb.lower, node.aabb.upper, c_dim, 1.0);
        drawTreeNode(ctx, tree, node.child1);
        drawTreeNode(ctx, tree, node.child2);
    }
}

fn collisionDynamicTreeLab(ctx: *render.LabCtx) void {
    const di: usize = @backingInt(phys.MotionType.dynamic);
    const tree: *const phys.DynamicTree = &ctx.world.broadphase.trees[di];
    drawTreeNode(ctx, tree, tree.root);
}

// box2d Benchmark|Sensor stress-tests thousands of sensor shapes with falling sensor bodies. Scaled
// here to a readable grid: a static field of sensor boxes that dynamic balls fall straight through
// (sensors don't collide), and benchmarkSensorLab flashes each cell as a sensor BEGIN event fires.
const sensor_cols: u32 = 9;
const sensor_rows: u32 = 3;
const sensor_half: f32 = 0.55;
const sensor_dx: f32 = 2.4;
const sensor_y0: f32 = 5.0;
const sensor_dy: f32 = 2.6;

fn sensorCellCenter(i: u32) Vec2 {
    const col: f32 = float(i % sensor_cols);
    const row: f32 = float(i / sensor_cols);
    const x: f32 = (col - float(sensor_cols - 1) * 0.5) * sensor_dx;
    const y: f32 = sensor_y0 + row * sensor_dy;
    return .{ x, y };
}

fn benchmarkSensor(world: *phys.World, st: *SceneState) !void {
    _ = try groundBox(world, 14, 1);
    const grid: BodyHandle = try addBody(world, .{ .motion = .static });
    const total: u32 = sensor_cols * sensor_rows;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const c: Vec2 = sensorCellCenter(i);
        _ = try phys.createShape(world, grid, .{
            .geom = .{ .polygon = phys.makeOffsetBox(sensor_half, sensor_half, c, Rot2.identity) },
            .is_sensor = true,
            .enable_sensor_events = true,
            .user_data = i,
        });
    }
    var b: u32 = 0;
    while (b < 4) : (b += 1) {
        const col: f32 = float(1 + b * 2);
        const cx: f32 = (col - float(sensor_cols - 1) * 0.5) * sensor_dx;
        st.body[b] = try addBody(world, .{
            .x = cx,
            .y = 12.0 + float(b) * 1.5,
            .gravity_scale = 0.4,
        });
        try attachCircle(world, st.body[b], .{ .r = 0.45 });
    }
}

fn benchmarkSensorUpdate(world: *phys.World, st: *SceneState) void {
    var b: u32 = 0;
    while (b < 4) : (b += 1) {
        const p: Vec2 = phys.getPosition(world, st.body[b]);
        if (p[1] < 1.5) {
            phys.setTransform(world, st.body[b], .{ p[0], 13.0 }, Rot2.identity) catch
                assertUnreachable(@src(), "OOM", .{});
        }
    }
}

fn benchmarkSensorLab(ctx: *render.LabCtx) void {
    const total: u32 = sensor_cols * sensor_rows;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const c: Vec2 = sensorCellCenter(i);
        ctx.rect(.{ c[0] - sensor_half, c[1] - sensor_half }, .{ c[0] + sensor_half, c[1] + sensor_half }, c_dim, 1.0);
    }
    const ev: phys.SensorEvents = phys.getSensorEvents(ctx.world);
    for (ev.begin) |e| {
        const idx: u32 = @intCast(ctx.world.shapes.data[e.sensor_shape].user_data);
        const c: Vec2 = sensorCellCenter(idx);
        ctx.rect(
            .{ c[0] - sensor_half, c[1] - sensor_half },
            .{ c[0] + sensor_half, c[1] + sensor_half },
            c_green,
            2.5,
        );
        ctx.mark(c, 6, c_amber);
    }
}

// box2d Joints|Gear Lift: two toothed gears that physically MESH (driver + limited follower), the
// follower winding a 40-link chain that lifts a door. box2d v3 has no gear joint — the gearing is
// real tooth-on-tooth collision, so the geometry is reproduced with box2d's exact numbers (gear1
// teeth sit at r+tooth_hh, gear2 at r+tooth_hw, which is what makes them interlock). The SVG-path
// frame is replaced with a simple floor; update_s cycles gear1's motor so the door rises and lowers.
fn jointsGearLift(world: *phys.World, st: *SceneState) !void {
    const gear_radius: f32 = 1.0;
    const tooth_hw: f32 = 0.09;
    const tooth_hh: f32 = 0.06;
    const tooth_r: f32 = 0.03;
    const link_hl: f32 = 0.07;
    const link_r: f32 = 0.05;
    const link_count: u32 = 40;
    const door_hh: f32 = 1.5;
    const gp1: Vec2 = .{ -4.25, 9.75 };
    const gp2: Vec2 = .{ -2.25, 10.75 };
    const link_attach: Vec2 = .{ gp2[0] + gear_radius + 2.0 * tooth_hw + tooth_r, gp2[1] };
    const chain_len: f32 = 2.0 * float(link_count) * link_hl + door_hh;
    const door_pos: Vec2 = .{ link_attach[0], link_attach[1] - chain_len };
    const da: f32 = 2.0 * pi / 16.0;

    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    const floor_body: BodyHandle = try addBody(world, .{ .x = -1.0, .y = 1.5, .motion = .static });
    try attachBox(world, floor_body, .{ .hw = 5, .hh = 0.5 });

    // gear 1 (driver): circle + 16 radial teeth at r + tooth_hh.
    const gear1: BodyHandle = try addBody(world, .{ .x = gp1[0], .y = gp1[1] });
    try attachCircle(world, gear1, .{ .r = gear_radius, .friction = 0.1 });
    var k1: u32 = 0;
    while (k1 < 16) : (k1 += 1) {
        const rot: Rot2 = Rot2.fromAngle(float(k1) * da);
        const center: Vec2 = rotateVec2(rot, .{ gear_radius + tooth_hh, 0 });
        _ = try phys.createShape(world, gear1, .{
            .geom = .{ .polygon = phys.makeOffsetRoundedBox(tooth_hw, tooth_hh, center, rot, tooth_r) },
            .material = .{ .friction = 0.1 },
        });
    }
    st.joint[0] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = gear1,
            .local_frame_a = .{ .p = gp1, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .motor_speed = 1.5,
        .max_motor_torque = 80.0,
    });

    // gear 2 (follower): circle + 16 teeth at r + tooth_hw; limited revolute with a rotated frame.
    const gear2: BodyHandle = try addBody(world, .{ .x = gp2[0], .y = gp2[1] });
    try attachCircle(world, gear2, .{ .r = gear_radius, .friction = 0.1 });
    var k2: u32 = 0;
    while (k2 < 16) : (k2 += 1) {
        const rot: Rot2 = Rot2.fromAngle(float(k2) * da);
        const center: Vec2 = rotateVec2(rot, .{ gear_radius + tooth_hw, 0 });
        _ = try phys.createShape(world, gear2, .{
            .geom = .{ .polygon = phys.makeOffsetRoundedBox(tooth_hw, tooth_hh, center, rot, tooth_r) },
            .material = .{ .friction = 0.1 },
        });
    }
    _ = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = gear2,
            .local_frame_a = .{ .p = gp2, .q = Rot2.fromAngle(0.25 * pi) },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 0.5,
        .enable_limit = true,
        .lower_angle = -0.3 * pi,
        .upper_angle = 0.8 * pi,
    });

    // 40-link capsule chain from gear2's rim down to the door.
    var pos: Vec2 = .{ link_attach[0], link_attach[1] - link_hl };
    var prev: BodyHandle = gear2;
    var i: u32 = 0;
    while (i < link_count) : (i += 1) {
        const link: BodyHandle = try addBody(world, .{ .x = pos[0], .y = pos[1] });
        try attachCapsule(world, link, .{ .half_len = link_hl, .r = link_r, .density = 2 });
        const pivot: Vec2 = .{ pos[0], pos[1] + link_hl };
        try pinRevolute(world, prev, link, .{ .anchor = pivot, .motor = true, .torque = 0.05 });
        pos[1] -= 2.0 * link_hl;
        prev = link;
    }

    // door: box, revolute to the last link at its top + a vertical prismatic to ground.
    const door: BodyHandle = try addBody(world, .{ .x = door_pos[0], .y = door_pos[1] });
    try attachBox(world, door, .{ .hw = 0.15, .hh = door_hh, .friction = 0.1 });
    const door_top: Vec2 = .{ door_pos[0], door_pos[1] + door_hh };
    try pinRevolute(world, prev, door, .{ .anchor = door_top, .motor = true, .torque = 0.05 });
    try pinPrismatic(world, ground, door, .{ .anchor = door_pos, .axis_angle = 0.5 * pi, .motor = true, .force = 0.2 });

    // a small pile of balls for the door to nudge as it cycles.
    var seed: u32 = 5;
    var b: u32 = 0;
    while (b < 16) : (b += 1) {
        const bx: f32 = rngRange(&seed, -3.5, 1.0);
        const by: f32 = rngRange(&seed, 2.5, 6.0);
        const ball: BodyHandle = try addBody(world, .{ .x = bx, .y = by });
        try attachCircle(world, ball, .{ .r = 0.22, .rolling = 0.3 });
    }

    st.f[0] = 0; // cycle timer
    st.u[0] = 1; // 1 = winding (lift), 0 = unwinding (lower)
}

fn jointsGearLiftUpdate(world: *phys.World, st: *SceneState) void {
    const dt: f32 = 1.0 / 60.0;
    st.f[0] += dt;
    if (st.f[0] >= 5.0) {
        st.f[0] = 0;
        st.u[0] = if (st.u[0] == 1) 0 else 1;
        const speed: f32 = if (st.u[0] == 1) 1.5 else -1.5;
        phys.revoluteSetMotorSpeed(world, st.joint[0], speed);
    }
}

// box2d Character|Mover: a player-controlled upright capsule on stepped terrain. Left/right set
// horizontal velocity, up jumps when grounded (edge-triggered so one press = one jump). Grounded is
// a short ray straight down from the capsule centre. A dynamic capsule (not the kinematic mover API)
// keeps it simple and lets it shove the loose crates around.
fn characterMover(world: *phys.World, st: *SceneState) !void {
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    try attachOffsetBox(world, ground, 9, 0.5, .{ 0, -0.5 }, 1); // floor
    try attachOffsetBox(world, ground, 1.0, 0.4, .{ 3.0, 0.4 }, 1); // step 1
    try attachOffsetBox(world, ground, 1.0, 0.4, .{ 5.0, 1.2 }, 1); // step 2
    try attachOffsetBox(world, ground, 1.0, 0.4, .{ 7.0, 2.0 }, 1); // step 3
    try attachOffsetBox(world, ground, 1.5, 0.3, .{ -5.0, 2.5 }, 1); // floating ledge
    try attachOffsetBox(world, ground, 0.4, 4, .{ -9, 3 }, 1); // left wall
    try attachOffsetBox(world, ground, 0.4, 4, .{ 9, 3 }, 1); // right wall
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const fx: f32 = -2.0 + float(i) * 0.7;
        const crate: BodyHandle = try addBody(world, .{ .x = fx, .y = 1.0 });
        try attachBox(world, crate, .{ .hw = 0.3, .hh = 0.3, .friction = 0.5 });
    }
    const char: BodyHandle = try addBody(world, .{ .x = -6, .y = 1.5, .lock_rot = true });
    try attachCapsule(world, char, .{ .half_len = 0.4, .r = 0.35, .density = 1.2, .friction = 0.3 });
    st.body[0] = char;
    st.u[0] = 0; // previous up-button state, for jump edge detection
}

fn characterMoverControl(world: *phys.World, st: *SceneState, in: SceneInput) void {
    const char: BodyHandle = st.body[0];
    const move_speed: f32 = 6.0;
    const jump_speed: f32 = 9.5;
    const reach: f32 = 0.93; // half_len 0.4 + r 0.35 + 0.18 skin
    const pos: Vec2 = phys.getPosition(world, char);
    const vel: Vec2 = phys.getLinearVelocity(world, char);
    var vx: f32 = 0;
    if (in.right) {
        vx += move_speed;
    }
    if (in.left) {
        vx -= move_speed;
    }
    const grounded: bool = phys.castRayClosest(world, pos, .{ 0, -reach }, .{}) != null;
    const up_edge: bool = in.up and (st.u[0] == 0);
    st.u[0] = if (in.up) 1 else 0;
    var vy: f32 = vel[1];
    if (up_edge and grounded and vy <= 1.0) {
        vy = jump_speed;
    }
    phys.setLinearVelocity(world, char, .{ vx, vy });
}

// box2d Continuous|Pinball: a chain-loop funnel with two centre-pivot flipper boxes (revolute +
// motor + angle limit), two free-spinning "+" spinners, two bouncy bumpers, and a BULLET ball so it
// can't tunnel the thin chain at speed (the point of the Continuous category). box2d flips both on one
// key; here `action`/O flips both, and left/right flip the matching flipper independently.
fn pinballSpinner(
    world: *phys.World,
    ground: BodyHandle,
    at: Vec2,
) !void {
    const sp: BodyHandle = try addBody(world, .{ .x = at[0], .y = at[1] });
    _ = try phys.createShape(world, sp, .{ .geom = .{ .polygon = phys.makeBox(1.5, 0.125) } });
    _ = try phys.createShape(world, sp, .{ .geom = .{ .polygon = phys.makeBox(0.125, 1.5) } });
    _ = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = sp,
            .local_frame_a = .{ .p = at, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 0.1,
    });
}

fn continuousPinball(world: *phys.World, st: *SceneState) !void {
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    const pts: [5]Vec2 = .{ .{ -8, 6 }, .{ -8, 20 }, .{ 8, 20 }, .{ 8, 6 }, .{ 0, -2 } };
    _ = try phys.createChain(world, ground, .{ .points = &pts, .is_loop = true });

    const lf: BodyHandle = try addBody(world, .{ .x = -2, .y = 0 });
    try attachBox(world, lf, .{ .hw = 1.75, .hh = 0.2 });
    st.joint[0] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = lf,
            .local_frame_a = .{ .p = .{ -2, 0 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 1000,
        .enable_limit = true,
        .lower_angle = -30.0 * pi / 180.0,
        .upper_angle = 5.0 * pi / 180.0,
    });
    const rf: BodyHandle = try addBody(world, .{ .x = 2, .y = 0 });
    try attachBox(world, rf, .{ .hw = 1.75, .hh = 0.2 });
    st.joint[1] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = rf,
            .local_frame_a = .{ .p = .{ 2, 0 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 1000,
        .enable_limit = true,
        .lower_angle = -5.0 * pi / 180.0,
        .upper_angle = 30.0 * pi / 180.0,
    });

    try pinballSpinner(world, ground, .{ -4, 17 });
    try pinballSpinner(world, ground, .{ 4, 8 });

    const bump1: BodyHandle = try addBody(world, .{ .x = -4, .y = 8, .motion = .static });
    try attachCircle(world, bump1, .{ .r = 1, .restitution = 1.5 });
    const bump2: BodyHandle = try addBody(world, .{ .x = 4, .y = 17, .motion = .static });
    try attachCircle(world, bump2, .{ .r = 1, .restitution = 1.5 });

    const ball: BodyHandle = try addBody(world, .{ .x = 1, .y = 15, .bullet = true });
    try attachCircle(world, ball, .{ .r = 0.2, .restitution = 0.2 });
    st.body[0] = ball;
}

fn continuousPinballControl(
    world: *phys.World,
    st: *SceneState,
    in: SceneInput,
) void {
    const flip: bool = in.action;
    const left_up: bool = flip or in.left;
    const right_up: bool = flip or in.right;
    const lspeed: f32 = if (left_up) 20.0 else -10.0;
    const rspeed: f32 = if (right_up) -20.0 else 10.0;
    phys.revoluteSetMotorSpeed(world, st.joint[0], lspeed);
    phys.revoluteSetMotorSpeed(world, st.joint[1], rspeed);
    const bp: Vec2 = phys.getPosition(world, st.body[0]);
    if (bp[1] < -6.0) {
        phys.setTransform(world, st.body[0], .{ 1, 15 }, Rot2.identity) catch assertUnreachable(@src(), "OOM", .{});
        phys.setLinearVelocity(world, st.body[0], .{ 0, 0 });
    }
}

// box2d Robustness|Cart: a deliberately punishing setup — a 1000-density chassis riding on two tiny
// 0.1 m wheels under hot gravity (-22). box2d leaves the wheels passive (it's a solver stress test with
// tuning sliders); here the wheel revolutes get motors so left/right drives the cart along the ground,
// which also shows the joints holding the heavy chassis together while it rolls.
fn robustnessCart(world: *phys.World, st: *SceneState) !void {
    world.settings.gravity = .{ 0, -22 };

    const ground: BodyHandle = try addBody(world, .{ .x = 0, .y = -1, .motion = .static });
    try attachBox(world, ground, .{ .hw = 20, .hh = 1, .friction = 0.9 });

    const y_base: f32 = 2.0;
    const chassis: BodyHandle = try addBody(world, .{ .x = 0, .y = y_base });
    _ = try phys.createShape(world, chassis, .{
        .geom = .{ .polygon = phys.makeOffsetBox(1.0, 0.25, .{ 0, 0.25 }, Rot2.identity) },
        .density = 1000,
        .material = .{ .friction = 0.6 },
    });

    const w1: BodyHandle = try addBody(world, .{ .x = -0.9, .y = y_base - 0.15 });
    try attachCircle(world, w1, .{ .r = 0.1, .density = 50, .friction = 0.9, .rolling = 0.02 });
    st.joint[0] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = chassis,
            .body_b = w1,
            .local_frame_a = .{ .p = .{ -0.9, -0.15 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 120,
    });
    const w2: BodyHandle = try addBody(world, .{ .x = 0.9, .y = y_base - 0.15 });
    try attachCircle(world, w2, .{ .r = 0.1, .density = 50, .friction = 0.9, .rolling = 0.02 });
    st.joint[1] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = chassis,
            .body_b = w2,
            .local_frame_a = .{ .p = .{ 0.9, -0.15 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
        },
        .enable_motor = true,
        .max_motor_torque = 120,
    });
}

fn robustnessCartControl(
    world: *phys.World,
    st: *SceneState,
    in: SceneInput,
) void {
    // Wheels spin clockwise (negative omega) to roll right; motor_speed 0 at rest brakes the wheels.
    var speed: f32 = 0;
    if (in.right) {
        speed -= 30.0;
    }
    if (in.left) {
        speed += 30.0;
    }
    phys.revoluteSetMotorSpeed(world, st.joint[0], speed);
    phys.revoluteSetMotorSpeed(world, st.joint[1], speed);
}

// box2d Events|Joint: six 1x1 boxes, each hung from the ground by a DIFFERENT joint type (distance,
// motor, prismatic, revolute, weld, wheel). Every joint carries a force/torque threshold and a
// user_data = its index. Drag a box hard (existing pointer drag) and when the joint force/torque
// exceeds the threshold, getJointEvents reports it and update_s destroys that joint — the box drops.
// box2d uses 20000 N thresholds, but the demo's drag tops out near 1000*mass (~4 kN here), so those
// would never break; lowered to 2.5 kN / 1.5 kN.m so a firm yank breaks a joint while gravity (~40 N)
// and gentle drags hold.
fn ejBox(
    world: *phys.World,
    px: f32,
    y0: f32,
) !BodyHandle {
    const box: BodyHandle = try addBody(world, .{ .x = px, .y = y0, .no_sleep = true });
    try attachBox(world, box, .{ .hw = 1, .hh = 1 });
    return box;
}

fn eventsJoint(world: *phys.World, st: *SceneState) !void {
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -40, 0 }, .point2 = .{ 40, 0 } } },
    });
    const ft: f32 = 2500;
    const tt: f32 = 1500;
    const y0: f32 = 10;

    // 0: distance joint (box hangs 2 m below an anchor point).
    const b0: BodyHandle = try ejBox(world, -12.5, y0);
    const piv1: Vec2 = .{ -12.5, y0 + 3 };
    const piv2: Vec2 = .{ -12.5, y0 + 1 };
    st.joint[0] = try phys.createDistanceJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b0,
            .local_frame_a = .{ .p = piv1, .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b0, piv2), .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 0,
        },
        .length = 2,
    });

    // 1: motor joint (holds the box at its start position).
    const b1: BodyHandle = try ejBox(world, -7.5, y0);
    st.joint[1] = try phys.createMotorJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b1,
            .local_frame_a = .{ .p = .{ -7.5, y0 }, .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 1,
        },
        .max_velocity_force = 1000,
        .max_velocity_torque = 20,
    });

    // 2: prismatic joint (slides along the world x axis).
    const b2: BodyHandle = try ejBox(world, -2.5, y0);
    const p2: Vec2 = .{ -3.5, y0 };
    st.joint[2] = try phys.createPrismaticJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b2,
            .local_frame_a = .{ .p = p2, .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b2, p2), .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 2,
        },
    });

    // 3: revolute joint (box swings about the pivot).
    const b3: BodyHandle = try ejBox(world, 2.5, y0);
    const p3: Vec2 = .{ 1.5, y0 };
    st.joint[3] = try phys.createRevoluteJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b3,
            .local_frame_a = .{ .p = p3, .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b3, p3), .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 3,
        },
    });

    // 4: weld joint (rigid, soft angular).
    const b4: BodyHandle = try ejBox(world, 7.5, y0);
    const p4: Vec2 = .{ 6.5, y0 };
    st.joint[4] = try phys.createWeldJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b4,
            .local_frame_a = .{ .p = p4, .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b4, p4), .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 4,
        },
        .angular_hertz = 2,
        .angular_damping_ratio = 0.5,
    });

    // 5: wheel joint (sprung suspension along the axis, with a motor + limit).
    const b5: BodyHandle = try ejBox(world, 12.5, y0);
    const p5: Vec2 = .{ 11.5, y0 };
    st.joint[5] = try phys.createWheelJoint(world, .{
        .base = .{
            .body_a = ground,
            .body_b = b5,
            .local_frame_a = .{ .p = p5, .q = Rot2.identity },
            .local_frame_b = .{ .p = worldToLocal(world, b5, p5), .q = Rot2.identity },
            .force_threshold = ft,
            .torque_threshold = tt,
            .collide_connected = true,
            .user_data = 5,
        },
        .hertz = 1,
        .damping_ratio = 0.7,
        .enable_limit = true,
        .lower_translation = -1,
        .upper_translation = 1,
        .enable_motor = true,
        .max_motor_torque = 10,
        .motor_speed = 1,
    });

    st.u[0] = 0; // bitmask of joints already destroyed
}

fn eventsJointUpdate(world: *phys.World, st: *SceneState) void {
    const events: []const phys.JointEvent = phys.getJointEvents(world);
    for (events) |ev| {
        const i: usize = @intCast(ev.user_data);
        if (i >= 6) {
            continue;
        }
        const sh: u5 = @intCast(i);
        const bit: u32 = @as(u32, 1) << sh;
        if ((st.u[0] & bit) != 0) {
            continue;
        }
        st.u[0] |= bit;
        phys.destroyJoint(world, st.joint[i]);
    }
}

pub const list = [_]Scene{
    // Stacking
    .{ .category = "Stacking", .name = "Single Box", .build = stackSingleBox },
    .{ .category = "Stacking", .name = "Vertical Stack", .build = stackVertical },
    .{ .category = "Stacking", .name = "Tilted Stack", .build = stackTilted },
    .{ .category = "Stacking", .name = "Circle Stack", .build = stackCircles },
    .{ .category = "Stacking", .name = "Capsule Stack", .build = stackCapsules },
    .{ .category = "Stacking", .name = "Confined", .build = stackConfined },
    .{ .category = "Stacking", .name = "Double Domino", .build = stackDomino },
    .{ .category = "Stacking", .name = "Pyramid", .build = stackPyramid },
    .{ .category = "Stacking", .name = "Arch", .build = stackArch },
    .{ .category = "Stacking", .name = "Card House", .build = stackCardHouse },
    .{ .category = "Stacking", .name = "Cliff", .build = stackCliff },
    // Bodies
    .{ .category = "Bodies", .name = "Body Type", .build = bodyType },
    .{ .category = "Bodies", .name = "Sleep", .build = bodySleep },
    .{ .category = "Bodies", .name = "Weeble", .build = bodyWeeble },
    .{ .category = "Bodies", .name = "Pivot", .build = bodyPivot },
    .{ .category = "Bodies", .name = "Kinematic", .build = bodyKinematic, .update = kinematicUpdate },
    .{ .category = "Bodies", .name = "Set Velocity", .build = bodySetVelocity },
    // Continuous
    .{ .category = "Continuous", .name = "Drop", .build = contDrop },
    .{ .category = "Continuous", .name = "Skinny Box", .build = contSkinny },
    .{ .category = "Continuous", .name = "Bounce House", .build = contBounce },
    .{ .category = "Continuous", .name = "Wedge", .build = contWedge },
    .{ .category = "Continuous", .name = "Chain Drop", .build = chainDrop },
    .{ .category = "Continuous", .name = "Ghost Bumps", .build = continuousGhostBumps },
    // Shapes
    .{ .category = "Shapes", .name = "Friction", .build = shapeFriction },
    .{ .category = "Shapes", .name = "Restitution", .build = shapeRestitution },
    .{ .category = "Shapes", .name = "Rounded", .build = shapeRounded },
    .{ .category = "Shapes", .name = "Ellipse", .build = shapeEllipse },
    .{ .category = "Shapes", .name = "Compound Shapes", .build = shapeCompound },
    .{ .category = "Shapes", .name = "Offset", .build = shapeOffset },
    .{ .category = "Shapes", .name = "Rolling Resistance", .build = shapeRolling },
    .{ .category = "Shapes", .name = "Conveyor Belt", .build = shapeConveyor },
    .{ .category = "Shapes", .name = "Explosion", .build = shapeExplosion },
    .{ .category = "Shapes", .name = "Wind", .build = shapeWind, .update = windUpdate },
    .{ .category = "Shapes", .name = "Chain Shape", .build = chainShape },
    .{ .category = "Shapes", .name = "Box Restitution", .build = shapeBoxRestitution },
    .{ .category = "Shapes", .name = "Filter", .build = shapeFilter },
    .{
        .category = "Shapes",
        .name = "Modify Geometry",
        .build_s = shapesModifyGeometry,
        .update_s = shapesModifyGeometryUpdate,
    },
    .{ .category = "Shapes", .name = "Custom Filter", .build = shapesCustomFilter },
    // Joints
    .{ .category = "Joints", .name = "Revolute", .build = jointRevolute },
    .{
        .category = "Joints",
        .name = "Gear Lift",
        .build_s = jointsGearLift,
        .update_s = jointsGearLiftUpdate,
        .cam = .{ .target = .{ -2, 6.5 }, .ppm = 30 },
    },
    .{
        .category = "Joints",
        .name = "User Constraint",
        .build_s = jointsUserConstraint,
        .update_s = jointsUserConstraintUpdate,
        .cam = .{ .target = .{ 1.5, -1 }, .ppm = 30 },
    },
    .{ .category = "Joints", .name = "Bridge", .build = jointBridge },
    .{ .category = "Joints", .name = "Ball & Chain", .build = jointBallChain },
    .{ .category = "Joints", .name = "Cantilever", .build = jointCantilever },
    .{ .category = "Joints", .name = "Soft Body", .build = jointSoftBody },
    .{ .category = "Joints", .name = "Wheel", .build = jointWheel },
    .{ .category = "Joints", .name = "Prismatic", .build = jointPrismatic },
    .{ .category = "Joints", .name = "Distance Joint", .build = jointDistance },
    .{ .category = "Joints", .name = "Motor Joint", .build = jointMotor },
    .{ .category = "Joints", .name = "Door", .build = jointDoor },
    .{ .category = "Joints", .name = "Ragdoll", .build = jointRagdoll },
    .{ .category = "Joints", .name = "Doohickey", .build = jointDoohickey },
    .{ .category = "Joints", .name = "Driving", .build = jointDriving },
    .{
        .category = "Joints",
        .name = "Rube Goldberg",
        .build = buildDominos,
        .cam = .{ .target = .{ 8, 16 }, .ppm = 9 },
    },
    // World
    .{ .category = "World", .name = "Tiles", .build = worldTiles },
    // Benchmark
    .{ .category = "Benchmark", .name = "Tumbler", .build = benchTumbler },
    .{
        .category = "Benchmark",
        .name = "Large Compounds",
        .build = benchmarkLargeCompounds,
        .cam = .{ .target = .{ 0, 8 }, .ppm = 12 },
    },
    .{ .category = "Benchmark", .name = "Spinner", .build = benchSpinner },
    .{ .category = "Benchmark", .name = "Large Pyramid", .build = benchLargePyramid },
    .{ .category = "Benchmark", .name = "Joint Grid", .build = benchJointGrid },
    .{ .category = "Benchmark", .name = "Many Tumblers", .build = benchManyTumblers },
    .{ .category = "Benchmark", .name = "Barrel 2.4", .build = benchmarkBarrel24 },
    .{
        .category = "Events",
        .name = "Circle Impulse",
        .build = eventCircleImpulse,
        .update = eventCircleImpulseUpdate,
    },
    .{ .category = "Events", .name = "Contact", .build = eventContact, .update = eventContactUpdate },
    .{ .category = "Events", .name = "Platformer", .build_s = eventsPlatformer, .update_s = eventsPlatformerUpdate },
    .{
        .category = "Events",
        .name = "Persistent Contact",
        .build = eventsPersistentContact,
        .lab = eventsPersistentContactLab,
        .cam = .{ .target = .{ 0, 3 }, .ppm = 22 },
    },
    .{ .category = "Events", .name = "Foot Sensor", .build = eventFootSensor, .update = eventFootSensorUpdate },
    .{ .category = "Events", .name = "Sensor Types", .build_s = eventSensorTypes, .update_s = eventSensorTypesUpdate },
    .{ .category = "Events", .name = "Sensor Hits", .build_s = eventSensorHits, .update_s = eventSensorHitsUpdate },
    .{
        .category = "Events",
        .name = "Sensor Funnel",
        .build = eventSensorFunnel,
        .update = eventSensorFunnelUpdate,
    },
    .{
        .category = "Events",
        .name = "Sensor Bookend",
        .build = eventSensorBookend,
        .update = eventSensorBookendUpdate,
    },
    .{ .category = "Events", .name = "Body Move", .build = eventBodyMove, .update = eventBodyMoveUpdate },
    .{
        .category = "Events",
        .name = "Projectile Event",
        .build_s = eventProjectile,
        .update_s = eventProjectileUpdate,
        .cam = .{ .target = .{ -2, 8 }, .ppm = 13 },
    },
    .{ .category = "Collision", .name = "Ray Cast", .build = labObstacles, .lab = labRayCastLab },
    .{
        .category = "Collision",
        .name = "Dynamic Tree",
        .build = collisionDynamicTree,
        .lab = collisionDynamicTreeLab,
        .cam = .{ .target = .{ 0, 6 }, .ppm = 20 },
    },
    .{ .category = "Collision", .name = "Shape Cast", .build = labObstacles, .lab = labShapeCastLab },
    .{ .category = "Collision", .name = "Overlap World", .build = labObstacles, .lab = labOverlapLab },
    .{
        .category = "Collision",
        .name = "Shape Distance",
        .build = labEmpty,
        .lab = labShapeDistance,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 44 },
    },
    .{
        .category = "Collision",
        .name = "Manifold",
        .build = labEmpty,
        .lab = labManifold,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 44 },
    },
    .{
        .category = "Collision",
        .name = "Cast World",
        .build = labObstacles,
        .lab = labCastWorldLab,
        .cam = .{ .target = .{ 0, 1 }, .ppm = 30 },
    },
    .{
        .category = "Collision",
        .name = "Smooth Manifold",
        .build = labEmpty,
        .lab = labSmoothManifoldLab,
        .cam = .{ .target = .{ 0, 1 }, .ppm = 38 },
    },
    .{
        .category = "Collision",
        .name = "Time of Impact",
        .build = labEmpty,
        .lab = labTimeOfImpactLab,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 28 },
    },
    .{ .category = "Geometry", .name = "Convex Hull", .build = labEmpty, .lab = labConvexHullLab },
    .{
        .category = "Robustness",
        .name = "HighMassRatio1",
        .build = robustHighMass1,
        .cam = .{ .target = .{ 3, 14 }, .ppm = 12 },
    },
    .{
        .category = "Robustness",
        .name = "HighMassRatio2",
        .build = robustHighMass2,
        .cam = .{ .target = .{ 0, 16 }, .ppm = 12 },
    },
    .{
        .category = "Robustness",
        .name = "HighMassRatio3",
        .build = robustHighMass3,
        .cam = .{ .target = .{ 0, 12 }, .ppm = 14 },
    },
    .{
        .category = "Robustness",
        .name = "Overlap Recovery",
        .build = robustOverlap,
        .cam = .{ .target = .{ 0, 1.5 }, .ppm = 90 },
    },
    .{
        .category = "Robustness",
        .name = "Tiny Pyramid",
        .build = robustTinyPyramid,
        .cam = .{ .target = .{ 0, 0.7 }, .ppm = 190 },
    },
    .{
        .category = "Bodies",
        .name = "Bad",
        .build = bodyBad,
        .cam = .{ .target = .{ 1, 4 }, .ppm = 34 },
    },
    .{
        .category = "Bodies",
        .name = "Mixed Locks",
        .build = bodyMixedLocks,
        .cam = .{ .target = .{ 0, 2 }, .ppm = 64 },
    },
    .{
        .category = "Bodies",
        .name = "Wake Touching",
        .build = bodyWakeTouching,
        .cam = .{ .target = .{ 0, 3 }, .ppm = 32 },
    },
    .{
        .category = "Continuous",
        .name = "Speculative Fallback",
        .build = continuousSpecFallback,
        .cam = .{ .target = .{ 1, 5 }, .ppm = 44 },
    },
    .{
        .category = "Continuous",
        .name = "Speculative Sliver",
        .build = continuousSpecSliver,
        .cam = .{ .target = .{ 0, 1.75 }, .ppm = 110 },
    },
    .{
        .category = "Continuous",
        .name = "Speculative Ghost",
        .build = continuousSpecGhost,
        .cam = .{ .target = .{ 0, 1.75 }, .ppm = 140 },
    },
    .{
        .category = "Continuous",
        .name = "Pixel Imperfect",
        .build = continuousPixelImperfect,
        .cam = .{ .target = .{ 6.5, 6 }, .ppm = 46 },
    },
    .{
        .category = "Continuous",
        .name = "Restitution Threshold",
        .build = continuousRestitutionThreshold,
        .cam = .{ .target = .{ 6.5, 6 }, .ppm = 46 },
    },
    .{
        .category = "Continuous",
        .name = "Chain Slide",
        .build = continuousChainSlide,
        .cam = .{ .target = .{ 0, 9 }, .ppm = 18 },
    },
    .{
        .category = "Continuous",
        .name = "Segment Slide",
        .build = continuousSegmentSlide,
        .cam = .{ .target = .{ 0, 5 }, .ppm = 16 },
    },
    .{
        .category = "Joints",
        .name = "Filter Joint",
        .build = jointFilter,
        .cam = .{ .target = .{ 0, 5 }, .ppm = 30 },
    },
    .{
        .category = "Joints",
        .name = "Top Down Friction",
        .build = jointTopDownFriction,
        .cam = .{ .target = .{ 0, 10 }, .ppm = 26 },
    },
    .{
        .category = "Joints",
        .name = "Scale Ragdoll",
        .build = jointScaleRagdoll,
        .cam = .{ .target = .{ 0, 4 }, .ppm = 22 },
    },
    .{
        .category = "Joints",
        .name = "Breakable",
        .build_s = jointBreakable,
        .update_s = jointBreakableUpdate,
        .cam = .{ .target = .{ 0, 4 }, .ppm = 22 },
    },
    .{
        .category = "Joints",
        .name = "Motion Locks",
        .build = jointMotionLocks,
        .cam = .{ .target = .{ 0, 9 }, .ppm = 16 },
    },
    .{
        .category = "Joints",
        .name = "Separation",
        .build = jointSeparation,
        .cam = .{ .target = .{ 0, 8 }, .ppm = 11 },
    },
    .{
        .category = "Joints",
        .name = "Scissor Lift",
        .build = jointScissorLift,
        .cam = .{ .target = .{ 0, 4 }, .ppm = 36 },
    },
    .{
        .category = "Benchmark",
        .name = "Smash",
        .build = benchmarkSmash,
        .cam = .{ .target = .{ 15, 2 }, .ppm = 8 },
    },
    .{
        .category = "Benchmark",
        .name = "Junkyard",
        .build_s = benchmarkJunkyard,
        .update_s = benchmarkJunkyardUpdate,
        .cam = .{ .target = .{ 0, 10 }, .ppm = 7 },
    },
    .{
        .category = "Benchmark",
        .name = "Sleep",
        .build = benchmarkSleep,
        .cam = .{ .target = .{ 0, 15 }, .ppm = 9 },
    },
    .{
        .category = "Benchmark",
        .name = "Kinematic",
        .build = benchmarkKinematic,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 16 },
    },
    .{
        .category = "Benchmark",
        .name = "Rain",
        .build_s = benchmarkRain,
        .update_s = benchmarkRainUpdate,
        .cam = .{ .target = .{ 0, 6 }, .ppm = 12 },
    },
    .{
        .category = "Benchmark",
        .name = "Capacity",
        .build = benchmarkCapacity,
        .cam = .{ .target = .{ 0, 12 }, .ppm = 9 },
    },
    .{
        .category = "Benchmark",
        .name = "Compounds",
        .build = benchmarkCompounds,
        .cam = .{ .target = .{ 0, 14 }, .ppm = 7 },
    },
    .{
        .category = "Benchmark",
        .name = "Barrel",
        .build = benchmarkBarrel,
        .cam = .{ .target = .{ 0, 14 }, .ppm = 9 },
    },
    .{
        .category = "Benchmark",
        .name = "Washer",
        .build = benchmarkWasher,
        .cam = .{ .target = .{ 0, 10 }, .ppm = 14 },
    },
    .{
        .category = "Benchmark",
        .name = "Cast",
        .build = benchmarkCast,
        .lab = benchmarkCastLab,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 24 },
    },
    .{
        .category = "Benchmark",
        .name = "Shape Distance",
        .build = labEmpty,
        .lab = benchmarkShapeDistanceLab,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 28 },
    },
    .{
        .category = "Benchmark",
        .name = "CreateDestroy",
        .build_s = benchmarkCreateDestroy,
        .update_s = benchmarkCreateDestroyUpdate,
        .cam = .{ .target = .{ 0, 6 }, .ppm = 22 },
    },
    .{
        .category = "Benchmark",
        .name = "Sensor",
        .build_s = benchmarkSensor,
        .update_s = benchmarkSensorUpdate,
        .lab = benchmarkSensorLab,
        .cam = .{ .target = .{ 0, 6 }, .ppm = 20 },
    },
    .{
        .category = "Continuous",
        .name = "Bounce Humans",
        .build_s = continuousBounceHumans,
        .update_s = continuousBounceHumansUpdate,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 22 },
    },
    .{
        .category = "Shapes",
        .name = "Recreate Static",
        .build_s = shapesRecreateStaticBuild,
        .update_s = shapesRecreateStaticUpdate,
        .cam = .{ .target = .{ 0, 5 }, .ppm = 30 },
    },
    .{
        .category = "Shapes",
        .name = "Tangent Speed",
        .build = shapesTangentSpeed,
        .cam = .{ .target = .{ 0, 2 }, .ppm = 12 },
    },
    .{
        .category = "Shapes",
        .name = "Chain Segment",
        .build = shapesChainSegment,
        .cam = .{ .target = .{ 0, 2 }, .ppm = 12 },
    },
    .{
        .category = "Shapes",
        .name = "Chain Link",
        .build = shapesChainLink,
        .cam = .{ .target = .{ 0, 0 }, .ppm = 16 },
    },
    .{
        .category = "Determinism",
        .name = "Falling Hinges",
        .build = determinismFallingHinges,
        .cam = .{ .target = .{ 0, 5 }, .ppm = 24 },
    },
    .{
        .category = "Determinism",
        .name = "SnapShot",
        .build = determinismFallingHinges,
        .auto_snapshot = true,
        .cam = .{ .target = .{ 0, 5 }, .ppm = 24 },
    },
    .{
        .category = "Robustness",
        .name = "Multiple Prismatic",
        .build = robustnessMultiplePrismatic,
        .cam = .{ .target = .{ 0, 4 }, .ppm = 30 },
    },
    // Showcase
    .{
        .category = "Showcase",
        .name = "Dominos",
        .build = showcaseDominos,
        .cam = .{ .target = .{ 6, 16 }, .ppm = 7 },
    },
    // Issues
    .{ .category = "Issues", .name = "Disable", .build_s = issuesDisable, .update_s = issuesDisableUpdate },
    .{
        .category = "Issues",
        .name = "Bad Steiner",
        .build = issuesBadSteiner,
        .cam = .{ .target = .{ 0, 1.75 }, .ppm = 90 },
    },
    .{
        .category = "Issues",
        .name = "Crash01",
        .build = issuesCrash01,
        .cam = .{ .target = .{ 0.8, 6.4 }, .ppm = 34 },
    },
    .{
        .category = "Issues",
        .name = "StaticVsBulletBug",
        .build = issuesStaticVsBullet,
        .cam = .{ .target = .{ 58, 72 }, .ppm = 16 },
    },
    .{
        .category = "Issues",
        .name = "Unstable Prismatic Joints",
        .build = issuesUnstablePrismatic,
        .cam = .{ .target = .{ 0, 2.5 }, .ppm = 34 },
    },
    .{
        .category = "Issues",
        .name = "Unstable Windmill",
        .build = issuesUnstableWindmill,
        .cam = .{ .target = .{ 10, 8 }, .ppm = 12 },
    },
    .{
        .category = "Character",
        .name = "Mover",
        .build_s = characterMover,
        .control = characterMoverControl,
        .cam = .{ .target = .{ 0, 3 }, .ppm = 26 },
    },
    .{
        .category = "Continuous",
        .name = "Pinball",
        .build_s = continuousPinball,
        .control = continuousPinballControl,
        .cam = .{ .target = .{ 0, 9 }, .ppm = 26 },
    },
    .{
        .category = "Robustness",
        .name = "Cart",
        .build_s = robustnessCart,
        .control = robustnessCartControl,
        .cam = .{ .target = .{ 0, 1.2 }, .ppm = 50 },
    },
    .{
        .category = "Events",
        .name = "Joint",
        .build_s = eventsJoint,
        .update_s = eventsJointUpdate,
        .cam = .{ .target = .{ 0, 7 }, .ppm = 23 },
    },
};

/// Unique category names, in list order — drives the scene picker's category dropdown.
pub const categories = blk: {
    @setEvalBranchQuota(20000);
    var buf: [list.len][]const u8 = undefined;
    var n: usize = 0;
    for (list) |sc| {
        var found: bool = false;
        for (buf[0..n]) |c| {
            if (std.mem.eql(u8, c, sc.category)) {
                found = true;
            }
        }
        if (!found) {
            buf[n] = sc.category;
            n += 1;
        }
    }
    break :blk buf[0..n].*;
};

/// Index into `categories` for a category name (0 if absent).
pub fn categoryIndex(name: []const u8) usize {
    var i: usize = 0;
    while (i < categories.len) : (i += 1) {
        if (std.mem.eql(u8, categories[i], name)) {
            return i;
        }
    }
    return 0;
}

/// First scene index in a category (0 if none) — used when the category changes.
pub fn firstInCategory(cat: usize) usize {
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        if (std.mem.eql(u8, list[i].category, categories[cat])) {
            return i;
        }
    }
    return 0;
}

// ================================================================================
// Stacking
// ================================================================================

fn stackSingleBox(world: *phys.World) !void {
    _ = try groundSegment(world, 60);
    const b: BodyHandle = try addBody(world, .{ .x = 0, .y = 1, .vx = 5 });
    try attachBox(world, b, .{ .hw = 1, .hh = 1 });
}

fn stackVertical(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const cols: usize = 5;
    const rows: usize = 10;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const x: f32 = -4.0 + float(col) * 2.0;
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const shift: f32 = if (row % 2 == 0) -0.02 else 0.02;
            const y: f32 = 0.5 + float(row) * 1.0;
            const b: BodyHandle = try addBody(world, .{ .x = x + shift, .y = y });
            try attachBox(world, b, .{ .hw = 0.45, .hh = 0.45, .round = 0.05 });
        }
    }
}

fn stackTilted(world: *phys.World) !void {
    _ = try groundBox(world, 1000, 1);
    const n: usize = 12;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = fi * 0.2, .y = 0.5 + fi * 1.0 });
        try attachBox(world, b, .{ .hw = 0.45, .hh = 0.45, .round = 0.05 });
    }
}

fn stackCircles(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const n: usize = 10;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const shift: f32 = if (i % 2 == 0) -0.02 else 0.02;
        const b: BodyHandle = try addBody(world, .{ .x = shift, .y = 0.5 + fi * 1.0 });
        try attachCircle(world, b, .{ .r = 0.5 });
    }
}

fn stackCapsules(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const n: usize = 8;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = 0, .y = 0.5 + fi * 0.9 });
        try attachCapsule(world, b, .{ .half_len = 0.25, .r = 0.25, .horizontal = true });
    }
}

fn stackConfined(world: *phys.World) !void {
    _ = try arena(world, 10, 0.5);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const fx: f32 = -7.0 + float(i % 12) * 1.2;
        const fy: f32 = -7.0 + float(i / 12) * 1.2;
        const b: BodyHandle = try addBody(world, .{ .x = fx, .y = fy });
        try attachCircle(world, b, .{ .r = 0.4 });
    }
}

fn stackDomino(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const n: usize = 18;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: f32 = -8.0 + float(i) * 1.0;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 1.5 });
        try attachBox(world, b, .{ .hw = 0.12, .hh = 1.5, .friction = 0.6 });
    }
    // A nudge to topple the first domino.
    const pusher: BodyHandle = try addBody(world, .{ .x = -10.0, .y = 2.0, .vx = 8.0 });
    try attachCircle(world, pusher, .{ .r = 0.4, .density = 2 });
}

fn stackPyramid(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const a: f32 = 0.5;
    const count: usize = 14;
    const dx: Vec2 = .{ 0.5625, 1.25 };
    const dy: Vec2 = .{ 1.125, 0.0 };
    const fcount: f32 = float(count);
    var x: Vec2 = .{ -(fcount - 1.0) * 0.5 * dy[0], 0.75 };
    var row: usize = 0;
    while (row < count) : (row += 1) {
        var p: Vec2 = x;
        var col: usize = row;
        while (col < count) : (col += 1) {
            const b: BodyHandle = try addBody(world, .{ .x = p[0], .y = p[1] });
            try attachBox(world, b, .{ .hw = a, .hh = a });
            p = .{ p[0] + dy[0], p[1] + dy[1] };
        }
        x = .{ x[0] + dx[0], x[1] + dx[1] };
    }
}

// ================================================================================
// Bodies
// ================================================================================

fn bodyType(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A kinematic moving platform.
    const plat: BodyHandle = try addBody(world, .{ .x = -4, .y = 3, .motion = .kinematic, .vx = 1 });
    try attachBox(world, plat, .{ .hw = 2, .hh = 0.25 });
    // Dynamic box, circle, capsule dropped on top.
    const b0: BodyHandle = try addBody(world, .{ .x = 0, .y = 6 });
    try attachBox(world, b0, .{ .hw = 0.5, .hh = 0.5 });
    const b1: BodyHandle = try addBody(world, .{ .x = 2, .y = 6 });
    try attachCircle(world, b1, .{ .r = 0.5 });
    const b2: BodyHandle = try addBody(world, .{ .x = 4, .y = 6 });
    try attachCapsule(world, b2, .{ .half_len = 0.4, .r = 0.3 });
}

fn bodySleep(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A few stacks that settle and sleep (the renderer greys sleeping bodies).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const x: f32 = -5.0 + float(i) * 2.0;
        var j: usize = 0;
        while (j < 3) : (j += 1) {
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = 0.5 + float(j) });
            try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
        }
    }
}

fn bodyWeeble(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // Roly-poly: a dense low circle plus a light tall box → self-rights.
    const b: BodyHandle = try addBody(world, .{ .x = 0, .y = 3, .angle = 0.5 });
    try attachCircle(world, b, .{ .r = 1.0, .cy = -1.0, .density = 6 });
    try attachBox(world, b, .{ .hw = 0.5, .hh = 1.5, .density = 0.2 });
}

// ================================================================================
// Continuous (CCD)
// ================================================================================

fn contDrop(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A thin platform and a fast box that would tunnel without CCD.
    const plat: BodyHandle = try addBody(world, .{ .x = 0, .y = 2, .motion = .static });
    try attachBox(world, plat, .{ .hw = 6, .hh = 0.05 });
    const b: BodyHandle = try addBody(world, .{ .x = 0, .y = 18, .vy = -40, .bullet = true });
    try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
}

fn contSkinny(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const plat: BodyHandle = try addBody(world, .{ .x = 0, .y = 2, .motion = .static });
    try attachBox(world, plat, .{ .hw = 6, .hh = 0.05 });
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const x: f32 = -3.0 + float(i) * 1.5;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 18, .vy = -45, .bullet = true });
        try attachBox(world, b, .{ .hw = 0.05, .hh = 1.0 });
    }
}

fn contBounce(world: *phys.World) !void {
    _ = try arena(world, 10, 0.5);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const fx: f32 = -6.0 + float(i % 6) * 2.4;
        const fy: f32 = -2.0 + float(i / 6) * 2.4;
        const b: BodyHandle = try addBody(world, .{ .x = fx, .y = fy, .vx = 8, .vy = -6, .bullet = true });
        try attachCircle(world, b, .{ .r = 0.4, .restitution = 0.95 });
    }
}

fn contWedge(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A tilted ramp (rotated static box) and a box sliding down it.
    const ramp: BodyHandle = try addBody(world, .{ .x = 0, .y = 4, .motion = .static, .angle = -0.35 });
    try attachBox(world, ramp, .{ .hw = 8, .hh = 0.25 });
    const b: BodyHandle = try addBody(world, .{ .x = -5, .y = 7, .bullet = true });
    try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4, .friction = 0.1 });
}

// ================================================================================
// Shapes
// ================================================================================

fn shapeFriction(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // Three ramps; a box on each slides differently by friction.
    const frictions = [_]f32{ 0.05, 0.3, 0.9 };
    var i: usize = 0;
    while (i < frictions.len) : (i += 1) {
        const y: f32 = 8.0 - float(i) * 3.0;
        const ramp: BodyHandle = try addBody(world, .{ .x = 0, .y = y, .motion = .static, .angle = -0.25 });
        try attachBox(world, ramp, .{ .hw = 8, .hh = 0.2 });
        const b: BodyHandle = try addBody(world, .{ .x = -5.5, .y = y + 2.0 });
        try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4, .friction = frictions[i] });
    }
}

fn shapeRestitution(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const n: usize = 8;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const x: f32 = -7.0 + fi * 2.0;
        const e: f32 = fi / float(n - 1);
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 8 });
        try attachCircle(world, b, .{ .r = 0.5, .restitution = e });
    }
}

fn shapeBoxRestitution(world: *phys.World) !void {
    // Box twin of "Restitution": two rows of boxes, restitution 0 -> 1 left to right.
    _ = try groundBox(world, 40, 1);
    const n: usize = 10;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const x: f32 = -9.0 + fi * 2.0;
        const e: f32 = fi / float(n - 1);
        const lo: BodyHandle = try addBody(world, .{ .x = x, .y = 2 });
        try attachBox(world, lo, .{ .hw = 0.5, .hh = 0.5, .restitution = e });
        const hi: BodyHandle = try addBody(world, .{ .x = x, .y = 6 });
        try attachBox(world, hi, .{ .hw = 0.5, .hh = 0.5, .restitution = e });
    }
}

fn shapesModifyGeometry(world: *phys.World, st: *SceneState) !void {
    // box2d Shapes|Modify Geometry: a kinematic body whose single shape is swapped through
    // circle → capsule → box → segment at runtime via setShapeGeometry, while a dynamic box rests
    // on it — the morphing platform visibly changes the contact each cycle.
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    try attachOffsetBox(world, ground, 10.0, 1.0, .{ 0, -1 }, 1.0);

    const faller: BodyHandle = try addBody(world, .{ .x = 0, .y = 6 });
    try attachBox(world, faller, .{ .hw = 1.0, .hh = 1.0 });

    const morph: BodyHandle = try addBody(world, .{ .x = 0, .y = 1, .motion = .kinematic });
    _ = try phys.createShape(world, morph, .{
        .geom = .{ .circle = .{ .center = .{ 0, 0 }, .radius = 0.5 } },
    });

    st.body[0] = morph;
    st.u[0] = 0; // current geometry index
    st.u[1] = 0; // frame counter
}

fn shapesModifyGeometryUpdate(world: *phys.World, st: *SceneState) void {
    st.u[1] += 1;
    if (st.u[1] < 75) {
        return;
    }
    st.u[1] = 0;
    st.u[0] = (st.u[0] + 1) % 4;
    const sh: phys.ShapeHandle = phys.getFirstShape(world, st.body[0]);
    const geom: phys.Geometry = switch (st.u[0]) {
        0 => .{ .circle = .{ .center = .{ 0, 0 }, .radius = 0.5 } },
        1 => .{ .capsule = .{ .center1 = .{ -0.6, 0 }, .center2 = .{ 0.6, 0 }, .radius = 0.4 } },
        2 => .{ .polygon = phys.makeBox(0.8, 0.8) },
        else => .{ .segment = .{ .point1 = .{ -1.0, 0 }, .point2 = .{ 1.0, 0 } } },
    };
    phys.setShapeGeometry(world, sh, geom) catch assertUnreachable(@src(), "OOM", .{});
}

fn customFilterShouldCollide(
    a: u32,
    b: u32,
    ctx: ?*anyopaque,
) bool {
    // Collide only when both shapes share parity (both odd or both even index). ctx is the world,
    // so we can read each shape's user_data (its 1-based index).
    const world: *phys.World = @ptrCast(@alignCast(ctx.?));
    const ud_a: u64 = world.shapes.data[a].user_data;
    const ud_b: u64 = world.shapes.data[b].user_data;
    if (ud_a == 0 or ud_b == 0) {
        return true;
    }
    return ((ud_a & 1) + (ud_b & 1)) != 1;
}

fn shapesCustomFilter(world: *phys.World) !void {
    // box2d Shapes|Custom Filter: ten boxes opt into custom filtering; the callback lets two boxes
    // collide only when they share parity, so odd/even neighbours interpenetrate while same-parity
    // ones stack. Each shape's user_data carries its 1-based index, read back in the callback.
    phys.setCustomFilterCallback(world, customFilterShouldCollide, world);

    _ = try groundSegment(world, 40);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const x: f32 = -10.0 + float(i) * 2.0;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 5 });
        _ = try phys.createShape(world, b, .{
            .geom = .{ .polygon = phys.makeBox(1.0, 1.0) },
            .enable_custom_filtering = true,
            .user_data = @as(u64, @intCast(i + 1)),
        });
    }
}

fn shapeFilter(world: *phys.World) !void {
    // box2d "Filter": collision categories + masks. The LEFT column shares one category and
    // masks only the ground, so its boxes fall THROUGH each other and pile flat. The RIGHT
    // column gives each box its own category (masking the other two), so they collide + stack.
    const ground_bit: u64 = 0x0001; // groundBox uses the default category (bit 0)
    const t1: u64 = 0x0002;
    const t2: u64 = 0x0004;
    const t3: u64 = 0x0008;

    _ = try groundBox(world, 40, 1);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = -3, .y = 2 + fi * 2.0 });
        try attachBox(world, b, .{ .hw = 0.6, .hh = 0.6, .filter = .{ .category = t1, .mask = ground_bit } });
    }

    const cats = [_]u64{ t1, t2, t3 };
    const masks = [_]u64{ ground_bit | t2 | t3, ground_bit | t1 | t3, ground_bit | t1 | t2 };
    i = 0;
    while (i < 3) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = 3, .y = 2 + fi * 2.0 });
        try attachBox(world, b, .{ .hw = 0.6, .hh = 0.6, .filter = .{ .category = cats[i], .mask = masks[i] } });
    }
}

fn shapeRounded(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = -4.5 + fi * 1.0, .y = 4, .angle = fi * 0.3 });
        try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5, .round = 0.25 });
    }
}

fn shapeEllipse(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = -5.5 + fi * 1.0, .y = 5, .angle = fi * 0.5 });
        try attachCapsule(world, b, .{ .half_len = 0.5, .r = 0.25, .horizontal = true });
    }
}

fn shapeCompound(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // "Tables": one body with a top slab and two legs (offset boxes).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const x: f32 = -6.0 + float(i) * 2.4;
        const t: BodyHandle = try addBody(world, .{ .x = x, .y = 3.0 + float(i) * 0.5 });
        try attachOffsetBox(world, t, 1.0, 0.15, .{ 0, 0.6 }, 1);
        try attachOffsetBox(world, t, 0.15, 0.6, .{ -0.8, 0 }, 1);
        try attachOffsetBox(world, t, 0.15, 0.6, .{ 0.8, 0 }, 1);
    }
}

fn shapeOffset(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const fi: f32 = float(i);
        const b: BodyHandle = try addBody(world, .{ .x = -5.0 + fi * 1.4, .y = 5 });
        // Shape offset from the body origin → spins about an off-centre mass.
        try attachOffsetBox(world, b, 0.4, 0.4, .{ 0.6, 0.0 }, 1);
    }
}

fn shapeRolling(world: *phys.World) !void {
    // A long ramp; circles with increasing rolling resistance stop at different points.
    const ramp: BodyHandle = try addBody(world, .{ .x = 0, .y = 4, .motion = .static, .angle = -0.15 });
    try attachBox(world, ramp, .{ .hw = 14, .hh = 0.25 });
    const n: usize = 6;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = float(i);
        const rr: f32 = fi * 0.06;
        const b: BodyHandle = try addBody(world, .{ .x = -10.0, .y = 6.0 + fi * 0.1 });
        try attachCircle(world, b, .{ .r = 0.4, .rolling = rr });
    }
}

fn shapeConveyor(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A belt: static box whose surface drags contacts along (tangent_speed).
    const belt: BodyHandle = try addBody(world, .{ .x = 0, .y = 2, .motion = .static });
    try attachBox(world, belt, .{ .hw = 12, .hh = 0.4, .tangent_speed = 4.0, .friction = 0.8 });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const x: f32 = -10.0 + float(i) * 1.2;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 3.0 });
        try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4 });
    }
}

fn shapeExplosion(world: *phys.World) !void {
    _ = try arena(world, 12, 0.5);
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const fx: f32 = -6.0 + float(i % 8) * 1.5;
        const fy: f32 = -6.0 + float(i / 8) * 1.5;
        const b: BodyHandle = try addBody(world, .{ .x = fx, .y = fy });
        try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4 });
    }
    phys.explode(world, .{ .position = .{ 0, 0 }, .radius = 8.0, .falloff = 2.0, .impulse_per_length = 60.0 });
}

fn shapeWind(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A loose pile the wind hook will push sideways each frame.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const fx: f32 = -6.0 + float(i % 6) * 0.9;
        const fy: f32 = 0.5 + float(i / 6) * 0.9;
        const b: BodyHandle = try addBody(world, .{ .x = fx, .y = fy });
        try attachBox(world, b, .{ .hw = 0.35, .hh = 0.35, .density = 0.3 });
    }
}

fn windUpdate(world: *phys.World) void {
    const f: Vec2 = .{ 6.0, 0.0 };
    for (world.active.items) |idx| {
        phys.applyForceToCenter(world, BodyHandle.pack(@intCast(idx), 0), f, true);
    }
}

// ================================================================================
// Joints
// ================================================================================

fn jointRevolute(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    // A motorised wheel pinned to ground.
    const wheel: BodyHandle = try addBody(world, .{ .x = 0, .y = 5 });
    try attachBox(world, wheel, .{ .hw = 2.0, .hh = 0.25 });
    try pinRevolute(world, g, wheel, .{ .anchor = .{ 0, 5 }, .motor = true, .speed = 2.0, .torque = 200.0 });
}

fn jointBridge(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const n: usize = 16;
    const plank_hw: f32 = 0.5;
    var prev: BodyHandle = g;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: f32 = -7.5 + float(i) * 1.0;
        const plank: BodyHandle = try addBody(world, .{ .x = x, .y = 6 });
        try attachBox(world, plank, .{ .hw = plank_hw, .hh = 0.125, .density = 2 });
        try pinRevolute(world, prev, plank, .{ .anchor = .{ x - plank_hw, 6 } });
        prev = plank;
    }
    try pinRevolute(world, prev, g, .{ .anchor = .{ -7.5 + float(n) * 1.0 - plank_hw, 6 } });
    // A ball to load the bridge.
    const ball: BodyHandle = try addBody(world, .{ .x = 0, .y = 10 });
    try attachCircle(world, ball, .{ .r = 0.8, .density = 3 });
}

fn jointBallChain(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const n: usize = 10;
    const link_hh: f32 = 0.5;
    var prev: BodyHandle = g;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y: f32 = 14.0 - float(i) * 1.0;
        const link: BodyHandle = try addBody(world, .{ .x = 0, .y = y });
        try attachCapsule(world, link, .{ .half_len = link_hh - 0.1, .r = 0.15 });
        try pinRevolute(world, prev, link, .{ .anchor = .{ 0, y + link_hh } });
        prev = link;
    }
    const ball: BodyHandle = try addBody(world, .{ .x = 0, .y = 14.0 - float(n) * 1.0 });
    try attachCircle(world, ball, .{ .r = 0.7, .density = 4 });
    try pinRevolute(world, prev, ball, .{ .anchor = .{ 0, 14.0 - float(n) * 1.0 + link_hh } });
}

fn jointCantilever(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const n: usize = 8;
    const hw: f32 = 0.5;
    var prev: BodyHandle = g;
    var anchor_x: f32 = -4.0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: f32 = -4.0 + (float(i) + 0.5) * (2.0 * hw);
        const seg_body: BodyHandle = try addBody(world, .{ .x = x, .y = 8 });
        try attachBox(world, seg_body, .{ .hw = hw, .hh = 0.125, .density = 1 });
        try pinWeld(world, prev, seg_body, .{ anchor_x, 8 });
        prev = seg_body;
        anchor_x = x + hw;
    }
}

fn jointSoftBody(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    // A ring of point-masses tied by distance springs → a wobbly blob.
    const n: usize = 12;
    const radius: f32 = 2.0;
    const cx: f32 = 0;
    const cy: f32 = 6;
    var nodes: [16]BodyHandle = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a: f32 = (float(i) / float(n)) * 6.2831853;
        const px: f32 = cx + radius * @cos(a);
        const py: f32 = cy + radius * @sin(a);
        nodes[i] = try addBody(world, .{ .x = px, .y = py });
        try attachCircle(world, nodes[i], .{ .r = 0.25, .density = 1 });
    }
    i = 0;
    while (i < n) : (i += 1) {
        const j: usize = (i + 1) % n;
        const xa: f32 = world.bodies.data[nodes[i].index()].transform.p[0];
        const ya: f32 = world.bodies.data[nodes[i].index()].transform.p[1];
        const xb: f32 = world.bodies.data[nodes[j].index()].transform.p[0];
        const yb: f32 = world.bodies.data[nodes[j].index()].transform.p[1];
        const len: f32 = @sqrt((xb - xa) * (xb - xa) + (yb - ya) * (yb - ya));
        try pinDistance(world, nodes[i], nodes[j], .{
            .pa = .{ xa, ya },
            .pb = .{ xb, yb },
            .length = len,
            .hertz = 5.0,
            .damping = 0.5,
        });
        // A spoke to the opposite node keeps the ring from collapsing.
        const k: usize = (i + n / 2) % n;
        const xk: f32 = world.bodies.data[nodes[k].index()].transform.p[0];
        const yk: f32 = world.bodies.data[nodes[k].index()].transform.p[1];
        const dlen: f32 = @sqrt((xk - xa) * (xk - xa) + (yk - ya) * (yk - ya));
        try pinDistance(world, nodes[i], nodes[k], .{
            .pa = .{ xa, ya },
            .pb = .{ xk, yk },
            .length = dlen,
            .hertz = 3.0,
            .damping = 0.5,
        });
    }
}

// ================================================================================
// World
// ================================================================================

fn worldTiles(world: *phys.World) !void {
    // A big static tile floor, then a pyramid on top.
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    const tiles: usize = 20;
    var t: usize = 0;
    while (t < tiles) : (t += 1) {
        const x: f32 = -19.0 + float(t) * 2.0;
        try attachOffsetBox(world, g, 1.0, 0.5, .{ x, 0 }, 1);
    }
    const count: usize = 10;
    var row: usize = 0;
    while (row < count) : (row += 1) {
        const in_row: usize = count - row;
        var c: usize = 0;
        while (c < in_row) : (c += 1) {
            const x: f32 = -float(in_row) * 0.5 + float(c) + 0.5;
            const y: f32 = 1.0 + float(row) * 1.0;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
        }
    }
}

// ================================================================================
// Benchmark
// ================================================================================

fn benchTumbler(world: *phys.World) !void {
    _ = try groundBox(world, 30, 1);
    // A kinematic hollow drum spinning about its centre; grains tumble inside.
    const drum: BodyHandle = try addBody(world, .{ .x = 0, .y = 8, .motion = .kinematic, .w = 1.5 });
    const half: f32 = 4.0;
    const t: f32 = 0.2;
    try attachOffsetBox(world, drum, half, t, .{ 0, -half }, 5);
    try attachOffsetBox(world, drum, half, t, .{ 0, half }, 5);
    try attachOffsetBox(world, drum, t, half, .{ -half, 0 }, 5);
    try attachOffsetBox(world, drum, t, half, .{ half, 0 }, 5);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const fx: f32 = -2.0 + float(i % 8) * 0.55;
        const fy: f32 = 6.0 + float(i / 8) * 0.55;
        const gb: BodyHandle = try addBody(world, .{ .x = fx, .y = fy });
        try attachBox(world, gb, .{ .hw = 0.2, .hh = 0.2 });
    }
}

// ================================================================================
// Wave 2 — joints, chains, structures, stress
// ================================================================================

fn jointWheel(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const body: BodyHandle = try addBody(world, .{ .x = 0, .y = 4 });
    try attachBox(world, body, .{ .hw = 1.6, .hh = 0.4, .density = 1 });
    const wl: BodyHandle = try addBody(world, .{ .x = -1.1, .y = 3.2 });
    try attachCircle(world, wl, .{ .r = 0.5, .friction = 0.9 });
    const wr: BodyHandle = try addBody(world, .{ .x = 1.1, .y = 3.2 });
    try attachCircle(world, wr, .{ .r = 0.5, .friction = 0.9 });
    try pinWheel(world, body, wl, .{ .anchor = .{ -1.1, 3.6 }, .hertz = 4.0, .damping = 0.7 });
    try pinWheel(world, body, wr, .{ .anchor = .{ 1.1, 3.6 }, .hertz = 4.0, .damping = 0.7 });
}

fn jointPrismatic(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const lift: BodyHandle = try addBody(world, .{ .x = 0, .y = 2 });
    try attachBox(world, lift, .{ .hw = 1.5, .hh = 0.3, .density = 1 });
    try pinPrismatic(world, g, lift, .{
        .anchor = .{ 0, 2 },
        .axis_angle = 1.5707963,
        .motor = true,
        .speed = 1.5,
        .force = 3000.0,
        .limit = true,
        .lo = 0,
        .hi = 6,
    });
    const rider: BodyHandle = try addBody(world, .{ .x = 0, .y = 3 });
    try attachBox(world, rider, .{ .hw = 0.5, .hh = 0.5 });
}

fn jointDistance(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const ball: BodyHandle = try addBody(world, .{ .x = 4, .y = 9 });
    try attachCircle(world, ball, .{ .r = 0.6, .density = 2 });
    try pinDistance(world, g, ball, .{
        .pa = .{ 0, 12 },
        .pb = .{ 4, 9 },
        .length = 5.0,
        .hertz = 2.0,
        .damping = 0.2,
    });
}

fn jointMotor(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const box: BodyHandle = try addBody(world, .{ .x = 0, .y = 6 });
    try attachBox(world, box, .{ .hw = 0.7, .hh = 0.7, .density = 1 });
    _ = try phys.createMotorJoint(world, .{
        .base = .{
            .body_a = g,
            .body_b = box,
            .local_frame_a = .{ .p = worldToLocal(world, g, .{ 0, 6 }), .q = Rot2.identity },
            .local_frame_b = Transform2.identity,
        },
        .angular_velocity = 3.0,
        .max_velocity_torque = 800.0,
        .linear_hertz = 3.0,
        .linear_damping_ratio = 0.6,
        .max_spring_force = 800.0,
    });
}

fn jointDoor(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const door: BodyHandle = try addBody(world, .{ .x = 1.0, .y = 8 });
    try attachBox(world, door, .{ .hw = 1.0, .hh = 0.1, .density = 1 });
    try pinRevolute(world, g, door, .{ .anchor = .{ 0, 8 }, .limit = true, .lo = -1.3, .hi = 1.3 });
    const ball: BodyHandle = try addBody(world, .{ .x = -3, .y = 8, .vx = 6 });
    try attachCircle(world, ball, .{ .r = 0.4, .density = 2 });
}

/// Build a ragdoll (torso/head/2 arms/2 legs joined by limited revolute joints) centred at
/// (cx, cy), uniformly scaled by `s`. Used by the ragdoll scenes (Scale Ragdoll, Bounce Humans).
/// A faithful port of the classic CS296 (IIT Bombay) "dominos" Rube Goldberg machine, the
/// teaching showcase built on box2d v2. A cannon fires a ball along the top shelf; the recoil
/// nudges a second ball; balls cascade down angled shelves through revolving planks, topple a
/// row of dominoes into a heavy ball, and a hanging toothbrush on a *pulley* hauls an open box
/// up on the far side. It exercises the new pulley joint alongside revolute hinges, see-saws,
/// and dense contact. The whole chain reaction is kicked off by one ball's initial velocity.
fn buildDominos(world: *phys.World) !void {
    world.settings.sub_step_count = 8; // stiff revolute + pulley chain wants extra sub-steps

    // Ground.
    _ = try groundSegment(world, 90);

    // Top horizontal shelf the cannon ball rolls along.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 0, .y = 32, .motion = .static });
        try attachBox(world, h, .{ .hw = 23, .hh = 0.25 });
    }

    // The cannon shot: a ball launched up and to the right.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 3, .y = 35, .vx = 17, .vy = 15 });
        try attachCircle(world, h, .{ .r = 1, .density = 5, .friction = 0, .restitution = 0.02 });
    }

    // The cannon body: a wheel plus two angled barrel walls, given a recoil velocity.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 0, .y = 33, .vx = -5 });
        try attachCircle(world, h, .{ .r = 1.5, .density = 2.5, .friction = 1 });
        _ = try phys.createShape(world, h, .{
            .geom = .{ .polygon = phys.makeOffsetBox(4, 0.25, .{ 0.7, 3.5 }, Rot2.fromAngle(pi / 4.0)) },
            .density = 15,
            .material = .{ .friction = 1 },
        });
        _ = try phys.createShape(world, h, .{
            .geom = .{ .polygon = phys.makeOffsetBox(3.5, 0.25, .{ 4, 2 }, Rot2.fromAngle(pi / 4.0)) },
            .density = 15,
            .material = .{ .friction = 1 },
        });
    }

    // The ball nudged by the cannon's recoil.
    {
        const h: BodyHandle = try addBody(world, .{ .x = -4.5, .y = 33 });
        try attachCircle(world, h, .{ .r = 1, .density = 9, .friction = 0.1, .restitution = 0.3 });
    }

    // Right side's angled and vertical shelves.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 55, .y = 30, .angle = pi / 18.0, .motion = .static });
        try attachBox(world, h, .{ .hw = 5, .hh = 0.25 });
    }
    {
        const h: BodyHandle = try addBody(world, .{ .x = 60, .y = 33, .angle = pi / 2.0, .motion = .static });
        try attachBox(world, h, .{ .hw = 2, .hh = 0.25 });
    }
    {
        const h: BodyHandle = try addBody(world, .{ .x = 45, .y = 28, .motion = .static });
        try attachBox(world, h, .{ .hw = 3, .hh = 0.25 });
    }

    // Right revolving plank 1: pivots at its base on a static hinge post.
    {
        const plank: BodyHandle = try addBody(world, .{ .x = 41.75, .y = 26.5 });
        try attachBox(world, plank, .{ .hw = 0.2, .hh = 1.5 });
        const hinge: BodyHandle = try addBody(world, .{ .x = 41.75, .y = 28, .motion = .static });
        try attachBox(world, hinge, .{ .hw = 0.2, .hh = 2 });
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = plank,
            .body_b = hinge,
            .local_frame_a = .{ .p = .{ 0, -1.5 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .collide_connected = false,
        } });
    }

    // Shelf and obstruction below it.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 38, .y = 23, .motion = .static });
        try attachBox(world, h, .{ .hw = 3, .hh = 0.25 });
        const obs: BodyHandle = try addBody(world, .{ .x = 35, .y = 24, .motion = .static });
        try attachBox(world, obs, .{ .hw = 0.2, .hh = 1 });
    }

    // Right revolving plank 2.
    {
        const plank: BodyHandle = try addBody(world, .{ .x = 41.25, .y = 21.5 });
        try attachBox(world, plank, .{ .hw = 0.2, .hh = 1.5 });
        const hinge: BodyHandle = try addBody(world, .{ .x = 41.25, .y = 23, .motion = .static });
        try attachBox(world, hinge, .{ .hw = 0.2, .hh = 2 });
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = plank,
            .body_b = hinge,
            .local_frame_a = .{ .p = .{ 0, -1.5 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .collide_connected = false,
        } });
    }

    {
        const h: BodyHandle = try addBody(world, .{ .x = 37, .y = 18, .motion = .static });
        try attachBox(world, h, .{ .hw = 5, .hh = 0.25 });
    }

    // A bouncy ball that ricochets toward the dominoes.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 40.5, .y = 18.5 });
        try attachCircle(world, h, .{ .r = 1, .density = 1, .friction = 0, .restitution = 1 });
    }

    {
        const h: BodyHandle = try addBody(world, .{ .x = 25, .y = 16.5, .motion = .static });
        try attachBox(world, h, .{ .hw = 4, .hh = 0.25 });
    }

    // The row of seven dominoes.
    {
        var i: u32 = 0;
        while (i < 7) : (i += 1) {
            const fi: f32 = float(i);
            const h: BodyHandle = try addBody(world, .{ .x = 21.5 + fi, .y = 17.5 });
            try attachBox(world, h, .{ .hw = 0.2, .hh = 1.0, .density = 20, .friction = 0.1 });
        }
    }

    // Bottom shelf and the heavy ball the dominoes knock into.
    {
        const h: BodyHandle = try addBody(world, .{ .x = 20, .y = 14, .motion = .static });
        try attachBox(world, h, .{ .hw = 7, .hh = 0.25 });
    }
    {
        const h: BodyHandle = try addBody(world, .{ .x = 18.5, .y = 14.5 });
        try attachCircle(world, h, .{ .r = 1, .density = 13, .friction = 0, .restitution = 0.5 });
    }

    // The weight-balance system: a static wedge with a dynamic frame pivoting on its tip.
    {
        const wedge: BodyHandle = try addBody(world, .{ .x = 5, .y = 0, .motion = .static });
        try attachHull(world, wedge, &.{ .{ -2, 0 }, .{ 2, 0 }, .{ 0, 4 } }, 1);

        const frame: BodyHandle = try addBody(world, .{ .x = 5, .y = 4 });
        try attachBox(world, frame, .{ .hw = 6, .hh = 0.25, .density = 1 });
        const parts = [_]struct { hw: f32, hh: f32, c: Vec2 }{
            .{ .hw = 0.25, .hh = 2, .c = .{ 5.5, 2 } },
            .{ .hw = 2, .hh = 0.2, .c = .{ 5.5, 4 } },
            .{ .hw = 0.2, .hh = 2, .c = .{ 3.75, 5.75 } },
            .{ .hw = 0.2, .hh = 2, .c = .{ 7.25, 5.75 } },
            .{ .hw = 0.25, .hh = 4, .c = .{ -5.5, 3.5 } },
            .{ .hw = 2, .hh = 0.2, .c = .{ -5.5, 7 } },
        };
        for (parts) |p| {
            _ = try phys.createShape(world, frame, .{
                .geom = .{ .polygon = phys.makeOffsetBox(p.hw, p.hh, p.c, Rot2.identity) },
                .density = 0,
            });
        }
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = frame,
            .body_b = wedge,
            .local_frame_a = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 4 }, .q = Rot2.identity },
            .collide_connected = false,
        } });
    }

    // The left pulley system: an open box and a heavy toothbrush over two ground anchors.
    {
        const box1: BodyHandle = try addBody(world, .{ .x = -22, .y = 23, .lock_rot = true });
        _ = try phys.createShape(world, box1, .{
            .geom = .{ .polygon = phys.makeOffsetBox(2, 0.2, .{ 0, -13.9 }, Rot2.identity) },
            .density = 10,
            .material = .{ .friction = 0.5 },
        });
        _ = try phys.createShape(world, box1, .{
            .geom = .{ .polygon = phys.makeOffsetBox(0.2, 2, .{ 2, -12 }, Rot2.identity) },
            .density = 10,
            .material = .{ .friction = 0.5 },
        });
        _ = try phys.createShape(world, box1, .{
            .geom = .{ .polygon = phys.makeOffsetBox(0.2, 2, .{ -2, -12 }, Rot2.identity) },
            .density = 10,
            .material = .{ .friction = 0.5 },
        });

        const box2: BodyHandle = try addBody(world, .{ .x = -5, .y = 15, .lock_rot = true });
        _ = try phys.createShape(world, box2, .{
            .geom = .{ .polygon = phys.makeOffsetBox(3.5, 0.2, .{ 0, -13.9 }, Rot2.identity) },
            .density = 18,
            .material = .{ .friction = 0.5 },
        });
        _ = try phys.createShape(world, box2, .{
            .geom = .{ .polygon = phys.makeOffsetBox(0.1, 0.6, .{ 3.5, -13.4 }, Rot2.identity) },
            .density = 0,
        });
        _ = try phys.createShape(world, box2, .{
            .geom = .{ .polygon = phys.makeOffsetBox(0.1, 0.6, .{ 2.5, -13.4 }, Rot2.identity) },
            .density = 0,
        });

        _ = try phys.createPulleyJoint(world, .{
            .base = .{ .body_a = box1, .body_b = box2 },
            .ground_anchor_a = .{ -22, 25 },
            .ground_anchor_b = .{ -5, 25 },
            .ratio = 1,
        });
    }

    // The revolving horizontal platform pivoting at its centre, with a heavy sphere on top.
    {
        const platform: BodyHandle = try addBody(world, .{ .x = 1, .y = 12.5 });
        try attachBox(world, platform, .{ .hw = 5.2, .hh = 0.2, .density = 1 });
        const hinge: BodyHandle = try addBody(world, .{ .x = 1, .y = 14.5, .motion = .static });
        try attachBox(world, hinge, .{ .hw = 0.2, .hh = 2 });
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = platform,
            .body_b = hinge,
            .local_frame_a = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .collide_connected = false,
        } });
        const ball: BodyHandle = try addBody(world, .{ .x = 1, .y = 16 });
        try attachCircle(world, ball, .{ .r = 0.3, .density = 2, .friction = 0 });
    }

    // The see-saw at the bottom: a wedge, a pivoting plank, and two boxes.
    {
        const wedge: BodyHandle = try addBody(world, .{ .x = -35, .y = 0 });
        try attachHull(world, wedge, &.{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, 3 } }, 10);

        const plank: BodyHandle = try addBody(world, .{ .x = -35, .y = 3 });
        try attachBox(world, plank, .{ .hw = 10, .hh = 0.2, .density = 0.8 });
        _ = try phys.createShape(world, plank, .{
            .geom = .{ .polygon = phys.makeOffsetBox(0.2, 1, .{ 10, 1 }, Rot2.identity) },
            .density = 0.8,
        });
        _ = try phys.createRevoluteJoint(world, .{ .base = .{
            .body_a = wedge,
            .body_b = plank,
            .local_frame_a = .{ .p = .{ 0, 3 }, .q = Rot2.identity },
            .local_frame_b = .{ .p = .{ 0, 0 }, .q = Rot2.identity },
            .collide_connected = false,
        } });

        const light: BodyHandle = try addBody(world, .{ .x = -41, .y = 3.5 });
        try attachBox(world, light, .{ .hw = 1, .hh = 1, .density = 1 });
        const restrict: BodyHandle = try addBody(world, .{ .x = -43, .y = 0.5 });
        try attachBox(world, restrict, .{ .hw = 1, .hh = 1.5, .density = 0.01 });
    }

    // The water tank: two static walls with a light floating block between them.
    {
        const walls: BodyHandle = try addBody(world, .{ .x = 0, .y = 0, .motion = .static });
        _ = try phys.createShape(world, walls, .{
            .geom = .{ .segment = .{ .point1 = .{ -0.7, 3 }, .point2 = .{ -0.7, 0 } } },
        });
        _ = try phys.createShape(world, walls, .{
            .geom = .{ .segment = .{ .point1 = .{ -9, 3 }, .point2 = .{ -9, 0 } } },
        });
        const water: BodyHandle = try addBody(world, .{ .x = -4.8, .y = 1 });
        try attachBox(world, water, .{ .hw = 4.1, .hh = 1, .density = 0.8 });
    }
}

fn makeRagdoll(
    world: *phys.World,
    cx: f32,
    cy: f32,
    s: f32,
) !void {
    const torso: BodyHandle = try addBody(world, .{ .x = cx, .y = cy });
    try attachCapsule(world, torso, .{ .half_len = 0.6 * s, .r = 0.28 * s });
    const head: BodyHandle = try addBody(world, .{ .x = cx, .y = cy + 1.3 * s });
    try attachCircle(world, head, .{ .r = 0.3 * s });
    try pinRevolute(world, torso, head, .{
        .anchor = .{ cx, cy + 0.9 * s },
        .limit = true,
        .lo = -0.4,
        .hi = 0.4,
    });
    const arm_l: BodyHandle = try addBody(world, .{ .x = cx - 0.9 * s, .y = cy + 0.4 * s, .angle = 1.2 });
    try attachCapsule(world, arm_l, .{ .half_len = 0.45 * s, .r = 0.14 * s });
    try pinRevolute(world, torso, arm_l, .{
        .anchor = .{ cx - 0.35 * s, cy + 0.5 * s },
        .limit = true,
        .lo = -1.6,
        .hi = 1.6,
    });
    const arm_r: BodyHandle = try addBody(world, .{ .x = cx + 0.9 * s, .y = cy + 0.4 * s, .angle = -1.2 });
    try attachCapsule(world, arm_r, .{ .half_len = 0.45 * s, .r = 0.14 * s });
    try pinRevolute(world, torso, arm_r, .{
        .anchor = .{ cx + 0.35 * s, cy + 0.5 * s },
        .limit = true,
        .lo = -1.6,
        .hi = 1.6,
    });
    const leg_l: BodyHandle = try addBody(world, .{ .x = cx - 0.3 * s, .y = cy - 1.3 * s, .angle = 0.15 });
    try attachCapsule(world, leg_l, .{ .half_len = 0.6 * s, .r = 0.17 * s });
    try pinRevolute(world, torso, leg_l, .{
        .anchor = .{ cx - 0.25 * s, cy - 0.6 * s },
        .limit = true,
        .lo = -1.0,
        .hi = 1.0,
    });
    const leg_r: BodyHandle = try addBody(world, .{ .x = cx + 0.3 * s, .y = cy - 1.3 * s, .angle = -0.15 });
    try attachCapsule(world, leg_r, .{ .half_len = 0.6 * s, .r = 0.17 * s });
    try pinRevolute(world, torso, leg_r, .{
        .anchor = .{ cx + 0.25 * s, cy - 0.6 * s },
        .limit = true,
        .lo = -1.0,
        .hi = 1.0,
    });
}

fn jointRagdoll(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    try makeRagdoll(world, 0, 9, 1);
}

fn jointDoohickey(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const crank: BodyHandle = try addBody(world, .{ .x = -2, .y = 7 });
    try attachBox(world, crank, .{ .hw = 0.8, .hh = 0.15, .density = 1 });
    try pinRevolute(world, g, crank, .{ .anchor = .{ -2, 7 }, .motor = true, .speed = 2.5, .torque = 200.0 });
    const rod: BodyHandle = try addBody(world, .{ .x = 0.5, .y = 7 });
    try attachBox(world, rod, .{ .hw = 1.7, .hh = 0.1, .density = 1 });
    try pinRevolute(world, crank, rod, .{ .anchor = .{ -1.2, 7 } });
    const slider: BodyHandle = try addBody(world, .{ .x = 2.2, .y = 7 });
    try attachBox(world, slider, .{ .hw = 0.35, .hh = 0.35, .density = 1 });
    try pinPrismatic(world, g, slider, .{
        .anchor = .{ 2.2, 7 },
        .axis_angle = 0,
        .limit = true,
        .lo = -1.5,
        .hi = 1.5,
    });
    try pinRevolute(world, rod, slider, .{ .anchor = .{ 2.2, 7 } });
}

fn jointDriving(world: *phys.World) !void {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, 30, 1, .{ 0, 0 }, 1);
    var k: usize = 0;
    while (k < 5) : (k += 1) {
        const bx: f32 = -8.0 + float(k) * 5.0;
        try attachOffsetBox(world, g, 0.6, 0.25, .{ bx, 1.0 }, 1);
    }
    const chassis: BodyHandle = try addBody(world, .{ .x = -18, .y = 3 });
    try attachBox(world, chassis, .{ .hw = 1.6, .hh = 0.3, .density = 1 });
    const wb: BodyHandle = try addBody(world, .{ .x = -19.1, .y = 2.4 });
    try attachCircle(world, wb, .{ .r = 0.5, .friction = 1.5 });
    const wf: BodyHandle = try addBody(world, .{ .x = -16.9, .y = 2.4 });
    try attachCircle(world, wf, .{ .r = 0.5, .friction = 1.5 });
    try pinWheel(world, chassis, wb, .{
        .anchor = .{ -19.1, 2.8 },
        .hertz = 5.0,
        .damping = 0.7,
        .motor = true,
        .speed = 12.0,
        .torque = 60.0,
    });
    try pinWheel(world, chassis, wf, .{ .anchor = .{ -16.9, 2.8 }, .hertz = 5.0, .damping = 0.7 });
}

fn buildChainTerrain(world: *phys.World) !BodyHandle {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    var pts: [25]Vec2 = undefined;
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const x: f32 = -24.0 + float(i) * 2.0;
        const y: f32 = 1.5 * @sin(x * 0.35) - 1.0;
        pts[i] = .{ x, y };
    }
    _ = try phys.createChain(world, g, .{ .points = &pts });
    return g;
}

fn chainShape(world: *phys.World) !void {
    _ = try buildChainTerrain(world);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const x: f32 = -18.0 + float(i) * 3.0;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 8 });
        if (i % 2 == 0) {
            try attachCircle(world, b, .{ .r = 0.4, .restitution = 0.3 });
        } else {
            try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4 });
        }
    }
}

fn chainDrop(world: *phys.World) !void {
    _ = try buildChainTerrain(world);
    const heavy: BodyHandle = try addBody(world, .{ .x = 0, .y = 12, .bullet = true });
    try attachBox(world, heavy, .{ .hw = 1.0, .hh = 1.0, .density = 5 });
}

fn continuousGhostBumps(world: *phys.World) !void {
    // box2d Continuous|Ghost Bumps: a closed-loop chain track whose internal vertices carry ghost
    // edges, so a shape sliding across a segment junction never catches on a phantom corner. The
    // 20-point loop and the dropped circle are ported point-for-point from the box2d sample; the
    // smooth glide around the bowl is the visible proof that ghost-vertex handling is working.
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });

    const m: f32 = 1.0 / @sqrt(2.0);
    const mm: f32 = 2.0 * (@sqrt(2.0) - 1.0);
    const hx: f32 = 4.0;
    const hy: f32 = 0.25;

    // Per-vertex offsets from the previous point (box2d builds the loop as a running b2Add chain).
    const deltas: [19][2]f32 = .{
        .{ -2.0 * hx * m, 2.0 * hx * m },
        .{ -2.0 * hx * m, 2.0 * hx * m },
        .{ -2.0 * hx * m, 2.0 * hx * m },
        .{ -2.0 * hy * m, -2.0 * hy * m },
        .{ 2.0 * hx * m, -2.0 * hx * m },
        .{ 2.0 * hx * m, -2.0 * hx * m },
        .{ 2.0 * hx * m + 2.0 * hy * (1.0 - m), -2.0 * hx * m - 2.0 * hy * (1.0 - m) },
        .{ 2.0 * hx + hy * mm, 0.0 },
        .{ 2.0 * hx, 0.0 },
        .{ 2.0 * hx + hy * mm, 0.0 },
        .{ 2.0 * hx * m + 2.0 * hy * (1.0 - m), 2.0 * hx * m + 2.0 * hy * (1.0 - m) },
        .{ 2.0 * hx * m, 2.0 * hx * m },
        .{ 2.0 * hx * m, 2.0 * hx * m },
        .{ -2.0 * hy * m, 2.0 * hy * m },
        .{ -2.0 * hx * m, -2.0 * hx * m },
        .{ -2.0 * hx * m, -2.0 * hx * m },
        .{ -2.0 * hx * m, -2.0 * hx * m },
        .{ -2.0 * hx, 0.0 },
        .{ -2.0 * hx, 0.0 },
    };

    var pts: [20]Vec2 = undefined;
    var x: f32 = -3.0 * hx;
    var y: f32 = hy;
    pts[0] = .{ x, y };
    for (deltas, 1..) |d, i| {
        x += d[0];
        y += d[1];
        pts[i] = .{ x, y };
    }

    _ = try phys.createChain(world, g, .{
        .points = &pts,
        .is_loop = true,
        .material = .{ .friction = 0.2 },
    });

    // Drop a circle into the bowl; gravity walks it around the loop, riding over the chain's
    // internal vertices rather than snagging on them.
    const ball: BodyHandle = try addBody(world, .{ .x = -28.0, .y = 18.0 });
    try attachCircle(world, ball, .{ .r = 0.5, .density = 1.0, .friction = 0.2 });
}

fn stackArch(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const n: usize = 11;
    const ri: f32 = 4.0;
    const ro: f32 = 5.4;
    const cy: f32 = 1.0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a0: f32 = pi * float(i) / float(n);
        const a1: f32 = pi * float(i + 1) / float(n);
        const o0x: f32 = ro * @cos(a0);
        const o0y: f32 = cy + ro * @sin(a0);
        const o1x: f32 = ro * @cos(a1);
        const o1y: f32 = cy + ro * @sin(a1);
        const i1x: f32 = ri * @cos(a1);
        const i1y: f32 = cy + ri * @sin(a1);
        const i0x: f32 = ri * @cos(a0);
        const i0y: f32 = cy + ri * @sin(a0);
        const mx: f32 = (o0x + o1x + i1x + i0x) * 0.25;
        const my: f32 = (o0y + o1y + i1y + i0y) * 0.25;
        const stone: BodyHandle = try addBody(world, .{ .x = mx, .y = my });
        const local: [4]Vec2 = .{
            .{ o0x - mx, o0y - my },
            .{ o1x - mx, o1y - my },
            .{ i1x - mx, i1y - my },
            .{ i0x - mx, i0y - my },
        };
        try attachHull(world, stone, &local, 1.0);
    }
}

fn stackCardHouse(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const tilt: f32 = 0.3;
    const hh: f32 = 1.0;
    const tents: usize = 5;
    var s: usize = 0;
    while (s < tents) : (s += 1) {
        const cx: f32 = -float(tents) * 1.1 + float(s) * 2.2 + 1.1;
        const lft: BodyHandle = try addBody(world, .{ .x = cx - 0.5, .y = 1.0 + hh, .angle = tilt });
        try attachBox(world, lft, .{ .hw = 0.05, .hh = hh, .friction = 0.9 });
        const rgt: BodyHandle = try addBody(world, .{ .x = cx + 0.5, .y = 1.0 + hh, .angle = -tilt });
        try attachBox(world, rgt, .{ .hw = 0.05, .hh = hh, .friction = 0.9 });
    }
    var r: usize = 0;
    while (r < tents) : (r += 1) {
        const cx: f32 = -float(tents) * 1.1 + float(r) * 2.2 + 1.1;
        const roof: BodyHandle = try addBody(world, .{ .x = cx, .y = 1.0 + 2.0 * hh + 0.05 });
        try attachBox(world, roof, .{ .hw = 1.0, .hh = 0.05, .friction = 0.9 });
    }
}

fn stackCliff(world: *phys.World) !void {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, 16, 1, .{ 0, 0 }, 1);
    try attachOffsetBox(world, g, 5, 3, .{ -8, 3 }, 1);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const x: f32 = -4.0 + float(i) * 0.9;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 6.6 });
        try attachBox(world, b, .{ .hw = 0.4, .hh = 0.4 });
    }
    const cap: BodyHandle = try addBody(world, .{ .x = -2.5, .y = 6.8 });
    try attachCapsule(world, cap, .{ .half_len = 1.2, .r = 0.25, .horizontal = true });
}

fn bodyPivot(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const arm: BodyHandle = try addBody(world, .{ .x = 0, .y = 8 });
    try attachBox(world, arm, .{ .hw = 3.0, .hh = 0.2, .density = 1 });
    try pinRevolute(world, g, arm, .{ .anchor = .{ 0, 8 } });
    const wt: BodyHandle = try addBody(world, .{ .x = 2.6, .y = 8 });
    try attachBox(world, wt, .{ .hw = 0.5, .hh = 0.5, .density = 6 });
    try pinWeld(world, arm, wt, .{ 2.6, 8 });
}

fn bodyKinematic(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const plat: BodyHandle = try addBody(world, .{ .x = 0, .y = 4, .motion = .kinematic, .vx = 3.0 });
    try attachBox(world, plat, .{ .hw = 2.0, .hh = 0.3 });
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const x: f32 = -1.0 + float(i) * 1.0;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = 5 });
        try attachBox(world, b, .{ .hw = 0.35, .hh = 0.35 });
    }
}

fn kinematicUpdate(world: *phys.World) void {
    for (world.active.items) |idx| {
        const b: *const phys.Body = &world.bodies.data[idx];
        if (b.motion_type != .kinematic) {
            continue;
        }
        const x: f32 = b.transform.p[0];
        const vx: f32 = world.motion[idx].linear_velocity[0];
        if (x > 6.0 and vx > 0.0) {
            world.motion[idx].linear_velocity = .{ -3.0, 0 };
        }
        if (x < -6.0 and vx < 0.0) {
            world.motion[idx].linear_velocity = .{ 3.0, 0 };
        }
    }
}

fn bodySetVelocity(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const ang: f32 = 0.4 + float(i) * 0.13;
        const sp: f32 = 13.0;
        const b: BodyHandle = try addBody(world, .{
            .x = -12,
            .y = 2,
            .vx = sp * @cos(ang),
            .vy = sp * @sin(ang),
            .w = float(i) - 2.5,
        });
        try attachBox(world, b, .{ .hw = 0.3, .hh = 0.3 });
    }
}

fn benchSpinner(world: *phys.World) !void {
    _ = try arena(world, 10, 0.5);
    const spin: BodyHandle = try addBody(world, .{ .x = 0, .y = 0, .motion = .kinematic, .w = 6.0 });
    try attachBox(world, spin, .{ .hw = 6.0, .hh = 0.25, .density = 1 });
    try attachOffsetBox(world, spin, 0.25, 6.0, .{ 0, 0 }, 1);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const x: f32 = -8.0 + float(i % 16) * 1.05;
        const y: f32 = -8.0 + float(i / 16) * 0.9;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
        try attachBox(world, b, .{ .hw = 0.2, .hh = 0.2 });
    }
}

fn benchmarkBarrel24(world: *phys.World) !void {
    // box2d Benchmark|Barrel 2.4: a tall U-shaped bin (floor + two 90°-rotated walls) packed with a
    // 26 × (5·26) grid of unit cubes — the classic v2.4-era stress arrangement. Ported 1:1.
    const ground_size: f32 = 25.0;

    const bin_floor: BodyHandle = try addBody(world, .{ .motion = .static });
    try attachBox(world, bin_floor, .{ .hw = ground_size, .hh = 1.2 });

    const right_wall: BodyHandle = try addBody(world, .{
        .x = ground_size,
        .y = 2.0 * ground_size,
        .angle = 0.5 * pi,
        .motion = .static,
    });
    try attachBox(world, right_wall, .{ .hw = 2.0 * ground_size, .hh = 1.2 });

    const left_wall: BodyHandle = try addBody(world, .{
        .x = -ground_size,
        .y = 2.0 * ground_size,
        .angle = 0.5 * pi,
        .motion = .static,
    });
    try attachBox(world, left_wall, .{ .hw = 2.0 * ground_size, .hh = 1.2 });

    const num: usize = 26;
    const rad: f32 = 0.5;
    const shift: f32 = rad * 2.0;
    const center_x: f32 = shift * float(num) / 2.0;
    const center_y: f32 = shift / 2.0;
    const num_j: usize = 5 * num;

    var i: usize = 0;
    while (i < num) : (i += 1) {
        const x: f32 = float(i) * shift - center_x;
        var j: usize = 0;
        while (j < num_j) : (j += 1) {
            const y: f32 = float(j) * shift + center_y + 2.0;
            const cube: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, cube, .{ .hw = 0.5, .hh = 0.5, .density = 1.0, .friction = 0.5 });
        }
    }
}

fn benchLargePyramid(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    const count: usize = 24;
    var row: usize = 0;
    while (row < count) : (row += 1) {
        const in_row: usize = count - row;
        var c: usize = 0;
        while (c < in_row) : (c += 1) {
            const x: f32 = -float(in_row) * 0.5 + float(c) + 0.5;
            const y: f32 = 1.0 + float(row) * 1.0;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachBox(world, b, .{ .hw = 0.5, .hh = 0.5 });
        }
    }
}

fn benchJointGrid(world: *phys.World) !void {
    const g: BodyHandle = try groundBox(world, 40, 1);
    const cols: usize = 14;
    const rows: usize = 10;
    const gap: f32 = 0.7;
    const x0: f32 = -float(cols) * gap * 0.5;
    const y0: f32 = 12.0;
    var grid: [140]BodyHandle = undefined;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const x: f32 = x0 + float(c) * gap;
            const y: f32 = y0 - float(r) * gap;
            const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
            try attachCircle(world, b, .{ .r = 0.12, .density = 1 });
            grid[r * cols + c] = b;
            if (c > 0) {
                try pinDistance(world, grid[r * cols + c - 1], b, .{
                    .pa = .{ x - gap, y },
                    .pb = .{ x, y },
                    .length = gap,
                });
            }
            if (r > 0) {
                try pinDistance(world, grid[(r - 1) * cols + c], b, .{
                    .pa = .{ x, y + gap },
                    .pb = .{ x, y },
                    .length = gap,
                });
            } else {
                try pinDistance(world, g, b, .{ .pa = .{ x, y + gap }, .pb = .{ x, y }, .length = gap });
            }
        }
    }
}

fn benchManyTumblers(world: *phys.World) !void {
    _ = try groundBox(world, 60, 1);
    var d: usize = 0;
    while (d < 3) : (d += 1) {
        const cx: f32 = -16.0 + float(d) * 16.0;
        const drum: BodyHandle = try addBody(world, .{ .x = cx, .y = 8, .motion = .kinematic, .w = 1.5 });
        const half: f32 = 3.0;
        const t: f32 = 0.2;
        try attachOffsetBox(world, drum, half, t, .{ 0, -half }, 5);
        try attachOffsetBox(world, drum, half, t, .{ 0, half }, 5);
        try attachOffsetBox(world, drum, t, half, .{ -half, 0 }, 5);
        try attachOffsetBox(world, drum, t, half, .{ half, 0 }, 5);
        var i: usize = 0;
        while (i < 24) : (i += 1) {
            const fx: f32 = cx - 1.5 + float(i % 6) * 0.5;
            const fy: f32 = 6.5 + float(i / 6) * 0.5;
            const gb: BodyHandle = try addBody(world, .{ .x = fx, .y = fy });
            try attachBox(world, gb, .{ .hw = 0.18, .hh = 0.18 });
        }
    }
}

// ================================================================================
// Wave 3 — event-driven scenes (read getContactEvents/getSensorEvents/getBodyEvents
// in a per-frame update hook and react). Visualisation is the engine's debug draw.
// ================================================================================

const tag_platform: u64 = 1;
const tag_player: u64 = 2;

fn platformerPreSolve(
    shape_a: u32,
    shape_b: u32,
    point: Vec2,
    normal: Vec2,
    ctx: ?*anyopaque,
) bool {
    _ = point;
    // One-way platform: keep the contact only when the player sits above the platform (so it lands),
    // and disable it when the player is rising from below (so it passes through). The manifold normal
    // points from shape_a to shape_b; orient it to point from platform toward player. ctx is the world,
    // used to read the shapes' role tags.
    const world: *phys.World = @ptrCast(@alignCast(ctx.?));
    const ud_a: u64 = world.shapes.data[shape_a].user_data;
    const ud_b: u64 = world.shapes.data[shape_b].user_data;
    var sign: f32 = 0;
    if (ud_a == tag_platform and ud_b == tag_player) {
        sign = 1.0;
    } else if (ud_b == tag_platform and ud_a == tag_player) {
        sign = -1.0;
    } else {
        return true; // not a platform/player pair → ordinary solid contact
    }
    return sign * normal[1] > 0.95;
}

fn eventsPlatformer(world: *phys.World, st: *SceneState) !void {
    // box2d Events|Platformer: jump-through (one-way) platforms via a pre-solve veto. box2d drives the
    // player with the keyboard; here it auto-jumps on a timer so the one-way behaviour is visible — the
    // player rises straight through each platform and lands on top coming back down.
    _ = try groundSegment(world, 20);

    const heights = [_]f32{ 4.0, 8.0 };
    for (heights) |y| {
        const plat: BodyHandle = try addBody(world, .{ .x = 0, .y = y, .motion = .static });
        _ = try phys.createShape(world, plat, .{
            .geom = .{ .polygon = phys.makeBox(3.0, 0.25) },
            .enable_pre_solve = true,
            .user_data = tag_platform,
        });
    }

    const player: BodyHandle = try addBody(world, .{ .x = 0, .y = 1 });
    _ = try phys.createShape(world, player, .{
        .geom = .{ .capsule = .{ .center1 = .{ 0, 0 }, .center2 = .{ 0, 1 }, .radius = 0.5 } },
        .enable_pre_solve = true,
        .user_data = tag_player,
    });

    phys.setPreSolveCallback(world, platformerPreSolve, world);
    st.body[0] = player;
    st.u[0] = 0;
}

fn eventsPlatformerUpdate(world: *phys.World, st: *SceneState) void {
    st.u[0] += 1;
    if (st.u[0] < 150) {
        return;
    }
    st.u[0] = 0;
    phys.setLinearVelocity(world, st.body[0], .{ 0, 11 });
}

fn eventsPersistentContact(world: *phys.World) !void {
    // box2d Events|Persistent Contact: a ball rolls in a smooth bowl, keeping a contact alive across many
    // steps. The lab reads each live touching contact's manifold (getContactData) and draws the contact
    // point and its accumulated normal impulse.
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    const pts = [_]Vec2{
        .{ -10, 5 },
        .{ -7, 2 },
        .{ -4, 0.5 },
        .{ 0, 0 },
        .{ 4, 0.5 },
        .{ 7, 2 },
        .{ 10, 5 },
    };
    _ = try phys.createChain(world, ground, .{ .points = &pts, .is_loop = false });

    const ball: BodyHandle = try addBody(world, .{ .x = -6, .y = 3 });
    try attachCircle(world, ball, .{ .cx = 0, .cy = 0, .r = 0.5, .restitution = 0.1 });
}

fn eventsPersistentContactLab(ctx: *render.LabCtx) void {
    const n: u32 = phys.liveContactCount(ctx.world);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const cid: u32 = phys.liveContactId(ctx.world, i);
        if (phys.isContactTouching(ctx.world, cid) == false) {
            continue;
        }
        const data: phys.ContactData = phys.getContactData(ctx.world, cid);
        var k: u32 = 0;
        while (k < data.point_count) : (k += 1) {
            const p1: Vec2 = data.points[k].point;
            // Scale the impulse vector up so the (small) supporting impulse is visible.
            const scale: f32 = 4.0;
            const imp: f32 = data.points[k].normal_impulse * scale;
            const p2: Vec2 = .{ p1[0] + data.normal[0] * imp, p1[1] + data.normal[1] * imp };
            ctx.line(p1, p2, c_red, 2);
            ctx.mark(p1, 5.0, c_red);
        }
    }
}

fn eventCircleImpulse(world: *phys.World) !void {
    _ = try arena(world, 12, 0.5);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const x: f32 = -8.0 + float(i % 12) * 1.4;
        const y: f32 = -6.0 + float(i / 12) * 1.4;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
        try attachCircle(world, b, .{ .r = 0.35, .restitution = 0.3, .hit_events = true });
    }
}

fn eventCircleImpulseUpdate(world: *phys.World) void {
    const ev: phys.ContactEvents = phys.getContactEvents(world);
    for (ev.hit) |h| {
        if (h.approach_speed < 3.0) {
            continue;
        }
        const ia: usize = shapeBodyIndex(world, h.shape_a);
        const ib: usize = shapeBodyIndex(world, h.shape_b);
        const kx: f32 = h.normal[0] * 0.25;
        const ky: f32 = h.normal[1] * 0.25;
        phys.applyLinearImpulseToCenter(world, bodyHandleOf(ia), .{ -kx, -ky }, true);
        phys.applyLinearImpulseToCenter(world, bodyHandleOf(ib), .{ kx, ky }, true);
    }
}

fn eventContact(world: *phys.World) !void {
    _ = try arena(world, 12, 0.5);
    const bumpers: [5]Vec2 = .{ .{ -5, -2 }, .{ 5, -2 }, .{ 0, 2 }, .{ -3, 5 }, .{ 3, 5 } };
    for (bumpers) |p| {
        const bp: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = p });
        try attachCircle(world, bp, .{ .r = 0.8 });
    }
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const b: BodyHandle = try addBody(world, .{ .x = -6.0 + float(i) * 0.8, .y = 9 });
        try attachCircle(world, b, .{ .r = 0.3, .restitution = 0.5 });
    }
}

fn eventContactUpdate(world: *phys.World) void {
    const ev: phys.ContactEvents = phys.getContactEvents(world);
    for (ev.begin) |bg| {
        const ia: usize = shapeBodyIndex(world, bg.shape_a);
        const ib: usize = shapeBodyIndex(world, bg.shape_b);
        const a_dyn: bool = world.bodies.data[ia].motion_type == .dynamic;
        const b_dyn: bool = world.bodies.data[ib].motion_type == .dynamic;
        if (a_dyn == b_dyn) {
            continue;
        }
        const dyn_i: usize = if (a_dyn) ia else ib;
        const stat_i: usize = if (a_dyn) ib else ia;
        const dc: Vec2 = world.bodies.data[dyn_i].center;
        const sc: Vec2 = world.bodies.data[stat_i].center;
        const dx: f32 = dc[0] - sc[0];
        const dy: f32 = dc[1] - sc[1];
        const d2: f32 = dx * dx + dy * dy;
        if (d2 < 0.0001) {
            continue;
        }
        const inv: f32 = 1.0 / @sqrt(d2);
        phys.applyLinearImpulseToCenter(world, bodyHandleOf(dyn_i), .{ dx * inv * 2.5, dy * inv * 2.5 }, true);
    }
}

fn eventSensorTypes(world: *phys.World, st: *SceneState) !void {
    // box2d Events|Sensor Types: a sensor on each of a static, kinematic, and dynamic body, plus a
    // filtered ground, exercising sensor begin/end detection across every body type. The kinematic
    // sensor bobs up and down (see update); balls rain down through all three to trip them.
    const cat_ground: u64 = 0x1;
    const cat_sensor: u64 = 0x2;
    const cat_default: u64 = 0x4;

    // Ground floor + two side walls; collides only with DEFAULT so the sensors pass through it.
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    const segs: [3][2]Vec2 = .{
        .{ .{ -6, 0 }, .{ 6, 0 } },
        .{ .{ -6, 0 }, .{ -6, 4 } },
        .{ .{ 6, 0 }, .{ 6, 4 } },
    };
    for (segs) |s| {
        _ = try phys.createShape(world, ground, .{
            .geom = .{ .segment = .{ .point1 = s[0], .point2 = s[1] } },
            .filter = .{ .category = cat_ground, .mask = cat_default },
        });
    }

    // Static sensor.
    const stat: BodyHandle = try addBody(world, .{ .x = -3, .y = 0.8, .motion = .static });
    _ = try phys.createShape(world, stat, .{
        .geom = .{ .polygon = phys.makeBox(1.0, 1.0) },
        .is_sensor = true,
        .density = 0,
        .filter = .{ .category = cat_sensor },
    });

    // Kinematic sensor — bobs up and down (update). Stash the handle for the update hook.
    const kin: BodyHandle = try addBody(world, .{ .x = 0, .y = 0, .motion = .kinematic, .vy = 1 });
    _ = try phys.createShape(world, kin, .{
        .geom = .{ .polygon = phys.makeBox(1.0, 1.0) },
        .is_sensor = true,
        .density = 0,
        .filter = .{ .category = cat_sensor },
    });
    st.body[0] = kin;

    // Dynamic sensor — a sensor box plus a real solid box so the body is physical.
    const dyn: BodyHandle = try addBody(world, .{ .x = 3, .y = 1 });
    _ = try phys.createShape(world, dyn, .{
        .geom = .{ .polygon = phys.makeBox(1.0, 1.0) },
        .is_sensor = true,
        .density = 0,
        .filter = .{ .category = cat_sensor },
    });
    try attachBox(world, dyn, .{ .hw = 0.8, .hh = 0.8, .filter = .{ .category = cat_default } });

    // Balls (DEFAULT, but masked to be seen by every sensor) rain down through the three sensors.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const fx: f32 = -5.0 + float(i) * 2.0;
        const ball: BodyHandle = try addBody(world, .{ .x = fx, .y = 6.0 });
        _ = try phys.createShape(world, ball, .{
            .geom = .{ .circle = .{ .center = .{ 0, 0 }, .radius = 0.5 } },
            .filter = .{ .category = cat_default, .mask = cat_ground | cat_default | cat_sensor },
        });
    }
}

fn eventSensorTypesUpdate(world: *phys.World, st: *SceneState) void {
    // Reverse the kinematic sensor at the ends of its travel so it sweeps the falling balls.
    const kin: BodyHandle = st.body[0];
    const p: Vec2 = phys.getPosition(world, kin);
    if (p[1] < 0.0) {
        phys.setLinearVelocity(world, kin, .{ 0, 1 });
    } else if (p[1] > 3.0) {
        phys.setLinearVelocity(world, kin, .{ 0, -1 });
    }
}

fn launchSensorBullet(world: *phys.World) !BodyHandle {
    // A small fast bullet (CCD) fired left→right across all three sensors.
    const bullet: BodyHandle = try addBody(world, .{ .x = -26.7, .y = 6, .vx = 250, .bullet = true });
    try attachCircle(world, bullet, .{ .r = 0.25, .friction = 0.8, .rolling = 0.01 });
    return bullet;
}

fn eventSensorHits(world: *phys.World, st: *SceneState) !void {
    // box2d Events|Sensor Hits: a fast bullet repeatedly tunnel-tests three sensors — a static
    // tripwire segment, a kinematic tripwire drifting right, and a dynamic capsule riding a motorised
    // prismatic. Even at ~250 m/s the CCD bullet trips every sensor's begin event. box2d fires the
    // bullet on a key; here the launch is automated on a timer, destroying the prior bullet each time.
    const ground: BodyHandle = try addBody(world, .{ .motion = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -10, 0 }, .point2 = .{ 10, 0 } } },
    });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ 10, 0 }, .point2 = .{ 10, 10 } } },
    });

    // Static sensor: a vertical tripwire segment.
    const stat: BodyHandle = try addBody(world, .{ .x = -4, .y = 1, .motion = .static });
    _ = try phys.createShape(world, stat, .{
        .geom = .{ .segment = .{ .point1 = .{ 0, 0 }, .point2 = .{ 0, 10 } } },
        .is_sensor = true,
        .density = 0,
    });

    // Kinematic sensor: same tripwire, drifting slowly to the right.
    const kin: BodyHandle = try addBody(world, .{ .x = 0, .y = 1, .motion = .kinematic, .vx = 0.5 });
    _ = try phys.createShape(world, kin, .{
        .geom = .{ .segment = .{ .point1 = .{ 0, 0 }, .point2 = .{ 0, 10 } } },
        .is_sensor = true,
        .density = 0,
    });

    // Dynamic sensor: an upright capsule sensor slid back and forth by a motorised prismatic joint.
    const dyn: BodyHandle = try addBody(world, .{ .x = 4, .y = 1 });
    _ = try phys.createShape(world, dyn, .{
        .geom = .{ .capsule = .{ .center1 = .{ 0, 1 }, .center2 = .{ 0, 9 }, .radius = 0.1 } },
        .is_sensor = true,
        .density = 1,
    });
    try pinPrismatic(world, ground, dyn, .{
        .anchor = .{ 4, 7 },
        .axis_angle = 0,
        .motor = true,
        .speed = 0.5,
        .force = 1000,
    });

    st.body[0] = try launchSensorBullet(world);
    st.u[0] = 0;
}

fn eventSensorHitsUpdate(world: *phys.World, st: *SceneState) void {
    // Relaunch on a timer; launch the fresh bullet first, then retire the previous one so a failed
    // spawn can never leave a dangling handle to double-free.
    st.u[0] += 1;
    if (st.u[0] >= 150) {
        st.u[0] = 0;
        const old: BodyHandle = st.body[0];
        const fresh: BodyHandle = launchSensorBullet(world) catch return;
        phys.destroyBody(world, old);
        st.body[0] = fresh;
    }
}

fn eventFootSensor(world: *phys.World) !void {
    _ = try groundBox(world, 40, 1);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const x: f32 = -4.0 + float(i) * 2.6;
        const ch: BodyHandle = try addBody(world, .{ .x = x, .y = 3 });
        try attachCapsule(world, ch, .{ .half_len = 0.4, .r = 0.3 });
        try attachSensorCircle(world, ch, .{ 0, -0.7 }, 0.25);
    }
}

fn eventFootSensorUpdate(world: *phys.World) void {
    const ev: phys.SensorEvents = phys.getSensorEvents(world);
    for (ev.begin) |sb| {
        const ci: usize = shapeBodyIndex(world, sb.sensor_shape);
        const m: f32 = world.bodies.data[ci].mass;
        const seed: f32 = float(ci % 7) - 3.0;
        phys.applyLinearImpulseToCenter(world, bodyHandleOf(ci), .{ seed * 0.4 * m, 7.0 * m }, true);
    }
}

fn eventSensorFunnel(world: *phys.World) !void {
    _ = try arena(world, 12, 0.5);
    const pad: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachSensorBox(world, pad, 10, 0.5, .{ 0, -9 });
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const x: f32 = -8.0 + float(i % 10) * 1.6;
        const y: f32 = 2.0 + float(i / 10) * 1.2;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
        try attachCircle(world, b, .{ .r = 0.3, .restitution = 0.2 });
    }
}

fn eventSensorFunnelUpdate(world: *phys.World) void {
    const ev: phys.SensorEvents = phys.getSensorEvents(world);
    for (ev.begin) |sb| {
        const vi: usize = shapeBodyIndex(world, sb.visitor_shape);
        const m: f32 = world.bodies.data[vi].mass;
        const seed: f32 = float(vi % 5) - 2.0;
        phys.applyLinearImpulseToCenter(world, bodyHandleOf(vi), .{ seed * 0.6 * m, 14.0 * m }, true);
    }
}

fn eventSensorBookend(world: *phys.World) !void {
    _ = try arena(world, 12, 0.5);
    const zone: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachSensorBox(world, zone, 5, 4, .{ 0, 0 });
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const x: f32 = -8.0 + float(i % 8) * 2.2;
        const y: f32 = 6.0 + float(i / 8) * 1.2;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
        try attachBox(world, b, .{ .hw = 0.3, .hh = 0.3 });
    }
}

fn eventSensorBookendUpdate(world: *phys.World) void {
    const ev: phys.SensorEvents = phys.getSensorEvents(world);
    for (ev.begin) |sb| {
        const vi: usize = shapeBodyIndex(world, sb.visitor_shape);
        world.motion[vi].gravity_scale = -0.4;
    }
    for (ev.end) |se| {
        const vi: usize = shapeBodyIndex(world, se.visitor_shape);
        world.motion[vi].gravity_scale = 1.0;
    }
}

fn eventBodyMove(world: *phys.World) !void {
    // No floor — bodies rain, bounce off two static ledges, fall away, and are recycled
    // to the top by reading body-move events.
    const l1: BodyHandle = try addBody(world, .{ .x = -3, .y = 2, .motion = .static, .angle = -0.3 });
    try attachBox(world, l1, .{ .hw = 3, .hh = 0.2 });
    const l2: BodyHandle = try addBody(world, .{ .x = 3, .y = -1, .motion = .static, .angle = 0.3 });
    try attachBox(world, l2, .{ .hw = 3, .hh = 0.2 });
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const x: f32 = -10.0 + float(i % 20) * 1.0;
        const y: f32 = 4.0 + float(i / 20) * 2.0;
        const b: BodyHandle = try addBody(world, .{ .x = x, .y = y });
        if (i % 3 == 0) {
            try attachCircle(world, b, .{ .r = 0.22 });
        } else {
            try attachBox(world, b, .{ .hw = 0.22, .hh = 0.22 });
        }
    }
}

fn eventBodyMoveUpdate(world: *phys.World) void {
    const moves: []const phys.BodyMoveEvent = phys.getBodyEvents(world);
    for (moves) |mv| {
        if (mv.transform.p[1] > -14.0) {
            continue;
        }
        const idx: usize = mv.body;
        const seed: f32 = float((idx * 37) % 20) - 10.0;
        phys.setTransform(world, bodyHandleOf(idx), .{ seed, 14.0 }, Rot2.identity) catch
            assertUnreachable(@src(), "OOM", .{});
        phys.setLinearVelocity(world, bodyHandleOf(idx), .{ 0, 0 });
    }
}

/// box2d's "Projectile Event": a bullet is auto-fired at a stack of rounded boxes every couple of
/// seconds; on its first contact it detonates a small explosion at the impact point and is removed.
/// The original fires on mouse-drag — here it loops autonomously. Exercises bullet bodies, contact
/// events, world.explode, and runtime body destruction, all driven from the scene-state slot.
fn eventProjectile(world: *phys.World, st: *SceneState) !void {
    const ground: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ 10, 0 }, .point2 = .{ 10, 20 } } },
    });
    _ = try phys.createShape(world, ground, .{
        .geom = .{ .segment = .{ .point1 = .{ -30, 0 }, .point2 = .{ 30, 0 } } },
    });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: f32 = if (i % 2 == 0) -0.01 else 0.01;
        const y: f32 = 0.5 + float(i);
        const b: BodyHandle = try addBody(world, .{ .x = 8 + shift, .y = y });
        try attachBox(world, b, .{ .hw = 0.45, .hh = 0.45, .round = 0.05 });
    }
    st.u[0] = 0; // 1 while a projectile is in flight
    st.u[1] = 140; // step counter, primed so the first shot fires shortly after entry
}

fn eventProjectileUpdate(world: *phys.World, st: *SceneState) void {
    st.u[1] += 1;
    if (st.u[1] >= 160) {
        st.u[1] = 0;
        if (st.u[0] == 1) {
            phys.destroyBody(world, st.body[0]);
            st.u[0] = 0;
        }
        const p: BodyHandle = addBody(world, .{ .x = -12, .y = 11, .bullet = true, .vx = 30, .vy = -9 }) catch return;
        attachCircle(world, p, .{ .r = 0.25 }) catch {
            phys.destroyBody(world, p);
            return;
        };
        st.body[0] = p;
        st.u[0] = 1;
    }
    if (st.u[0] != 1) {
        return;
    }
    // On the projectile's first contact with anything, detonate at its centre and remove it.
    const proj_i: usize = st.body[0].index();
    const ev: phys.ContactEvents = phys.getContactEvents(world);
    for (ev.begin) |bg| {
        const ia: usize = shapeBodyIndex(world, bg.shape_a);
        const ib: usize = shapeBodyIndex(world, bg.shape_b);
        if (ia != proj_i and ib != proj_i) {
            continue;
        }
        const center: Vec2 = phys.getPosition(world, st.body[0]);
        phys.explode(world, .{ .position = center, .radius = 1.5, .impulse_per_length = 20 });
        phys.destroyBody(world, st.body[0]);
        st.u[0] = 0;
        break;
    }
}
// as a draggable probe.
// ================================================================================

fn labObstacles(world: *phys.World) !void {
    const g: BodyHandle = try phys.createBody(world, .{ .motion_type = .static });
    try attachOffsetBox(world, g, 1.6, 1.6, .{ 3, 2 }, 1);
    try attachOffsetBox(world, g, 1.0, 2.6, .{ -4, -1 }, 1);
    const c1: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 0.5, 4.5 } });
    try attachCircle(world, c1, .{ .r = 1.5 });
    const cap: BodyHandle = try phys.createBody(world, .{ .motion_type = .static, .position = .{ 5.5, -3 } });
    try attachCapsule(world, cap, .{ .half_len = 1.4, .r = 0.6, .horizontal = true });
}

fn labRayCastLab(ctx: *render.LabCtx) void {
    const origin: Vec2 = .{ -9, -6 };
    const dir: Vec2 = .{ ctx.pointer[0] - origin[0], ctx.pointer[1] - origin[1] };
    const hit: ?phys.RayResult = phys.castRayClosest(ctx.world, origin, dir, .{});
    if (hit) |rr| {
        ctx.line(origin, rr.point, c_amber, 2);
        ctx.line(rr.point, ctx.pointer, c_dim, 1);
        ctx.mark(rr.point, 5, c_red);
        const tip: Vec2 = .{ rr.point[0] + rr.normal[0] * 1.3, rr.point[1] + rr.normal[1] * 1.3 };
        ctx.arrow(rr.point, tip, c_green, 2);
    } else {
        ctx.line(origin, ctx.pointer, c_amber, 2);
    }
    ctx.mark(origin, 4, c_amber);
    ctx.mark(ctx.pointer, 4, c_dim);
}

fn labShapeCastLab(ctx: *render.LabCtx) void {
    const origin: Vec2 = .{ -9, -6 };
    const r: f32 = 0.6;
    const pt: [1]Vec2 = .{.{ 0, 0 }};
    const proxy: phys.ShapeProxy = phys.makeProxy(&pt, r);
    const dir: Vec2 = .{ ctx.pointer[0] - origin[0], ctx.pointer[1] - origin[1] };
    const hit: ?phys.CastResult = phys.castShapeClosest(ctx.world, origin, proxy, dir, .{});
    ctx.ring(origin, r, c_dim, 1);
    if (hit) |cr| {
        const ctr: Vec2 = .{ origin[0] + dir[0] * cr.fraction, origin[1] + dir[1] * cr.fraction };
        ctx.line(origin, ctr, c_dim, 1);
        ctx.ring(ctr, r, c_amber, 2);
        ctx.mark(cr.point, 5, c_red);
        const tip: Vec2 = .{ cr.point[0] + cr.normal[0] * 1.3, cr.point[1] + cr.normal[1] * 1.3 };
        ctx.arrow(cr.point, tip, c_green, 2);
    } else {
        ctx.line(origin, ctx.pointer, c_dim, 1);
        ctx.ring(ctx.pointer, r, c_amber, 2);
    }
}

const OverlapViz = struct {
    ctx: *render.LabCtx,
};

fn labOverlapCb(shape: phys.ShapeIndex, p: *anyopaque) bool {
    const ov: *OverlapViz = @ptrCast(@alignCast(p));
    const bi: usize = ov.ctx.world.shapes.data[shape].body;
    const c: Vec2 = ov.ctx.world.bodies.data[bi].center;
    ov.ctx.mark(c, 9, c_red);
    return true;
}

fn labOverlapLab(ctx: *render.LabCtx) void {
    const half: f32 = 2.0;
    const lo: Vec2 = .{ ctx.pointer[0] - half, ctx.pointer[1] - half };
    const hi: Vec2 = .{ ctx.pointer[0] + half, ctx.pointer[1] + half };
    const box: phys.Aabb2 = .{ .lower = lo, .upper = hi };
    var ov: OverlapViz = .{ .ctx = ctx };
    phys.overlapAabb(ctx.world, box, .{}, labOverlapCb, &ov);
    ctx.rect(lo, hi, c_amber, 2);
}

fn labConvexHullLab(ctx: *render.LabCtx) void {
    var pts: [12]Vec2 = undefined;
    var i: usize = 0;
    while (i < 11) : (i += 1) {
        const fi: f32 = float(i);
        const a: f32 = ctx.time * 0.3 + fi * 0.61;
        const rr: f32 = 2.0 + @sin(ctx.time + fi) * 1.4;
        pts[i] = .{ @cos(a) * rr, @sin(a) * rr * 0.8 + 1.0 };
    }
    pts[11] = ctx.pointer;
    for (pts) |p| {
        ctx.mark(p, 3, c_dim);
    }
    const hull: phys.Hull = phys.computeHull(&pts);
    var j: u32 = 0;
    while (j < hull.count) : (j += 1) {
        const a2: Vec2 = hull.points[j];
        const b2: Vec2 = hull.points[(j + 1) % hull.count];
        ctx.line(a2, b2, c_green, 2);
        ctx.mark(a2, 4, c_amber);
    }
    ctx.mark(ctx.pointer, 5, c_red);
}

fn labEmpty(world: *phys.World) !void {
    _ = world; // convex hull queries nothing — the pointer is just a hull point
}
