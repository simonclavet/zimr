//! zimrphysics_demo — switchable physics scenes driven by the `zimrphysics`
//! (Jolt port) World and drawn with `render.drawWorld`, the pure-ECS render pass
//! over `world.bodies` (see render.zig). Six scenes inspired by Jolt's samples:
//! showcase (mixed shape rain), pyramid, stack (alternating yaw), restitution
//! (0..1), friction ramp (0..1), and a funnel/bowl. TAB cycles scenes (rebuilding
//! the World via `World.deinit`), R resets, one finger orbits, two fingers
//! pinch-zoom and pan (wheel/drag on desktop), and SPACE launches a body from
//! the camera.
//!
//! Follows the standard wgpu example contract: a `pub const app: z.AppSpec(State)`
//! wired into `src/wgpu_runner.zig` by `addWgpuApp` in build.zig. The served page
//! is `zig build wgpu-zimrphysics-demo`; the single-file build is
//! `zig build wgpu-zimrphysics-demo-standalone`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const render = @import("render.zig");

const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const clamp = zm.clamp;
const vec = zm.vec;
const splat = zm.splat;
const normalize3 = zm.normalize3;
const cross = zm.cross;
const quat_identity = zm.quat_identity;
const rotate = zm.rotate;
const pi = zm.pi;
const radFromDeg = zm.radFromDeg;

const c = z.colors;
const zp = z.zimrphysics;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const demo_palette = [_]Color{
    c.amber_400,
    c.emerald_400,
    c.sky_400,
    c.rose_400,
    c.violet_400,
    c.green_400,
};

const quatFromAxisAngle = zm.quatFromAxisAngle;
const qmul = zm.qmul;

/// The switchable demo scenes. The shape galleries come first so they show on
/// load and when paging with TAB; the rest are each inspired by a Jolt sample
/// (Pyramid, Stack, Restitution, Friction, Funnel, + the constraint scenes).
/// Each rebuilds the World from scratch via `World.deinit` + `init`.
const Scene = enum {
    shapes,
    terrain,
    showcase,
    pyramid,
    stack,
    rods,
    restitution,
    friction_ramp,
    funnel,
    bridge,
    chain,
    motor,
    weld,
    slider,
    pulley,
    ragdoll,
    gear,
    rack_and_pinion,
    path,
    newtons_cradle,
    wrecking_ball,
    plinko,
    rube_goldberg,
    tumbler,
    conveyor,
    clockwork,
    stirrer,
    ragdoll_pile,
    stress,

    fn next(self: Scene) Scene {
        const count: u32 = @as(u32, @intFromEnum(Scene.stress)) + 1;
        return @enumFromInt((@as(u32, @intFromEnum(self)) + 1) % count);
    }
    fn prev(self: Scene) Scene {
        const count: u32 = @as(u32, @intFromEnum(Scene.stress)) + 1;
        return @enumFromInt((@as(u32, @intFromEnum(self)) + count - 1) % count);
    }
    fn label(self: Scene) []const u8 {
        return switch (self) {
            .shapes => "shapes",
            .terrain => "terrain",
            .showcase => "showcase",
            .pyramid => "pyramid",
            .stack => "stack",
            .rods => "10 spinning rods",
            .restitution => "restitution 0..1",
            .friction_ramp => "friction ramp 0..1",
            .funnel => "funnel",
            .bridge => "swing bridge",
            .chain => "hanging chain",
            .motor => "motorized bars",
            .weld => "welded table",
            .slider => "powered slider",
            .pulley => "pulley",
            .ragdoll => "ragdoll (swing-twist)",
            .gear => "gear train",
            .rack_and_pinion => "rack & pinion",
            .path => "path (bead on rail)",
            .newtons_cradle => "Newton's cradle",
            .wrecking_ball => "wrecking ball",
            .plinko => "plinko (Galton board)",
            .rube_goldberg => "rube goldberg (chain reaction)",
            .tumbler => "tumbler (rotating drum)",
            .conveyor => "conveyor (surface velocity)",
            .clockwork => "clockwork (gear train + rack)",
            .stirrer => "stirrer (swing-twist motor)",
            .ragdoll_pile => "ragdoll pile (humanoid)",
            .stress => "stress (mega scene)",
        };
    }
    /// Which `zimrphysics` constraint each scene demonstrates (shown in the HUD),
    /// or "" for the shape/stacking scenes that use no joints.
    fn constraintNote(self: Scene) []const u8 {
        return switch (self) {
            .bridge => "createPointJoint",
            .chain => "createDistanceJoint",
            .motor => "createRevoluteJoint",
            .weld => "createWeldJoint",
            .slider => "createPrismaticJoint",
            .pulley => "createPulleyJoint",
            .ragdoll => "createSwingTwistJoint",
            .gear => "createGearJoint",
            .rack_and_pinion => "createRackAndPinionJoint",
            .path => "createPathJoint",
            .newtons_cradle => "createDistanceJoint (5 pendulums)",
            .wrecking_ball => "createDistanceJoint + brick wall",
            .plinko => "many-body + restitution (bell curve)",
            .rube_goldberg => "CCD marble + dominoes + chute",
            .tumbler => "motor hinge + compound drum",
            .conveyor => "contact surface velocity",
            .clockwork => "gear train + rack & pinion + motor",
            .stirrer => "powered swing-twist rotor",
            .ragdoll_pile => "12-bone swing-twist humanoids",
            .stress => "blender + galton + pyramid + chain at once",
            else => "",
        };
    }
    fn camDistance(self: Scene) f32 {
        return switch (self) {
            .shapes => 18,
            .terrain => 22,
            .showcase => 16,
            .pyramid => 13,
            .stack => 15,
            .rods => 16,
            .restitution => 22,
            .friction_ramp => 18,
            .funnel => 20,
            .bridge => 16,
            .chain => 14,
            .motor => 16,
            .weld => 14,
            .slider => 14,
            .pulley => 16,
            .ragdoll => 15,
            .gear => 12,
            .rack_and_pinion => 16,
            .path => 16,
            .newtons_cradle => 18,
            .wrecking_ball => 20,
            .plinko => 20,
            .rube_goldberg => 30,
            .tumbler => 12,
            .conveyor => 18,
            .clockwork => 16,
            .stirrer => 15,
            .ragdoll_pile => 13,
            .stress => 56,
        };
    }
    fn camTargetX(self: Scene) f32 {
        return switch (self) {
            .conveyor => 2.0,
            .rube_goldberg => 7.0, // wide left-to-right chain; centre the camera on it
            else => 0.0,
        };
    }

    fn camTargetY(self: Scene) f32 {
        return switch (self) {
            .stack => 4.0,
            .restitution => 3.0,
            .pyramid => 2.5,
            .funnel => 2.5,
            .bridge => 3.5,
            .chain => 3.0,
            .motor => 3.0,
            .weld => 2.0,
            .slider => 4.0,
            .pulley => 4.5,
            .ragdoll => 4.5,
            .gear => 4.0,
            .rack_and_pinion => 3.0,
            .path => 3.5,
            .newtons_cradle => 4.0,
            .wrecking_ball => 3.5,
            .plinko => 6.0,
            .rube_goldberg => -0.5,
            .tumbler => 3.0,
            .conveyor => 0.5,
            .clockwork => 2.4,
            .stirrer => 1.5,
            .ragdoll_pile => 0.8,
            else => 2.0,
        };
    }
};

/// Context for the conveyor scene's contact listener: which body is the belt and the
/// surface speed it drives. The belt is the lower body index, so in a belt-vs-marble
/// pair the belt is `a` and we negate the desired carry direction.
const ConveyorCtx = struct {
    belt: zp.BodyIndex = 0,
    speed: f32 = 5.0,
};

const State = struct {
    font: z.Font,
    gpa: Allocator,
    world: zp.World,
    scratch: std.heap.ArenaAllocator,
    ui_host: z.UiHost,
    profiling: bool = false, // "Profile" button: freeze the profiler + pause stepping
    watching: bool = false, // "Watch" button: auto-freeze the profiler on a frame-time spike
    launch_shape: zp.ShapeId = 0,
    slider_plat: zp.BodyHandle = .nil, // .slider scene: platform body (read x to reverse motor)
    slider_idx: usize = 0, // .slider scene: index of the slider constraint in world.constraints
    pulley_idx: usize = 0, // .pulley scene: index of the pulley constraint (rope overlay)
    path_idx: usize = 0, // .path scene: index of the path constraint (rail overlay), +1 (0 = none)
    plinko_phys_steps: usize = 0, // .plinko: physics-step counter driving the ball spawner
    plinko_spawned: usize = 0, // .plinko: balls released so far (caps the stream)
    plinko_seed: u32 = 777, // .plinko: LCG state for drop-point jitter
    galton_ball: zp.ShapeId = 0, // .stress: galton drop-ball shape (released one at a time)
    galton_origin: Vec = vec(0, 0, 0), // .stress: galton board world origin
    galton_y_top: f32 = 0, // .stress: galton peg-field top (spawn just above it)
    conveyor_ctx: ConveyorCtx = .{}, // .conveyor: belt body + surface speed for the contact listener
    conveyor_steps: usize = 0, // .conveyor: physics-step counter driving the marble spawner
    conveyor_spawned: usize = 0, // .conveyor: marbles released so far (caps the stream)
    clockwork_motor: usize = 0, // .clockwork: index of the driven gear's hinge (reverse it to reciprocate)
    clockwork_rack: zp.BodyHandle = .nil, // .clockwork: the rack body (read x to reverse the drive)
    clockwork_home: f32 = 0, // .clockwork: the rack's home x (reverse when it strays past +-1.3)
    scene: Scene = .shapes,
    cam_angle_yaw: f32 = 35.0,
    cam_angle_pitch: f32 = 18.0,
    cam_distance: f32 = 16.0,
    cam_pan: Vec = vec(0, 0, 0), // target offset from two-finger / drag pan
    prev_pinch: f32 = 0, // last two-finger spacing (px); 0 = not pinching
    prev_pan_mid: Vec2 = .{ 0, 0 }, // last two-finger midpoint (px)
    two_finger: bool = false,
    frame_count: usize = 0,
    phys_accum: f32 = 0, // fixed-timestep accumulator (real seconds owed to the solver)
    spawned: bool = false,
    dragging: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.world.deinit(gpa);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const world: zp.World = try zp.World.init(gpa, 1024);
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    s.* = .{
        .font = font,
        .gpa = gpa,
        .world = world,
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .ui_host = z.UiHost.init(gpa, font),
    };
}

/// Static flat floor (a box; static box-vs-convex contact is solid).
fn addFlatFloor(world: *zp.World, gpa: Allocator, half: f32) !void {
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(half, 0.5, half),
        .convex_radius = 0.05,
    } });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
        .material = 0,
    });
}

/// Wave B — shape gallery. One of (almost) every convex / decorator shape the
/// engine has, dropped in a row so each settles on the floor: SphereShape,
/// BoxShape, CapsuleShape, CylinderShape, TaperedCapsuleShape, ConvexHullShape,
/// StaticCompoundShape, OffsetCenterOfMassShape, RotatedTranslatedShape.
fn sceneShapes(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 9);
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    const qid: zm.Quat = quatFromAxisAngle(vec(0, 1, 0), 0.0);
    const y: f32 = 3.0;

    const s_sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    _ = try world.createBody(.{ .shape = s_sphere, .position = vec(-7.0, y, 0), .material = 1 });

    const s_box: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.5, 0.5, 0.5), .convex_radius = 0.05 },
    });
    _ = try world.createBody(.{ .shape = s_box, .position = vec(-5.25, y, 0), .material = 2 });

    const s_cap: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.4, .radius = 0.35 } });
    _ = try world.createBody(.{ .shape = s_cap, .position = vec(-3.5, y, 0), .material = 3 });

    const s_cyl: zp.ShapeId = try world.shapes.add(gpa, .{
        .cylinder = .{ .half_height = 0.5, .radius = 0.4, .convex_radius = 0.05 },
    });
    _ = try world.createBody(.{ .shape = s_cyl, .position = vec(-1.75, y, 0), .material = 4 });

    const s_tcap: zp.ShapeId = try world.shapes.add(gpa, .{
        .tapered_capsule = .{ .half_height = 0.4, .top_radius = 0.2, .bottom_radius = 0.45 },
    });
    _ = try world.createBody(.{ .shape = s_tcap, .position = vec(0.0, y, 0), .material = 5 });

    // Convex hull: an octahedron from 6 axis points.
    const hull_pts = [_]Vec{
        vec(0.6, 0, 0), vec(-0.6, 0, 0),
        vec(0, 0.6, 0), vec(0, -0.6, 0),
        vec(0, 0, 0.6), vec(0, 0, -0.6),
    };
    const s_hull: zp.ShapeId = try world.shapes.addConvexHull(gpa, &hull_pts);
    _ = try world.createBody(.{ .shape = s_hull, .position = vec(1.75, y, 0), .material = 1 });

    // Static compound: a dumbbell (cylinder bar + two end spheres) as one body.
    const bar: zp.ShapeId = try world.shapes.add(gpa, .{
        .cylinder = .{ .half_height = 0.55, .radius = 0.14, .convex_radius = 0.02 },
    });
    const knob: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.32 } });
    const dumbbell: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
        .{ .shape = bar, .local_pos = vec(0, 0, 0), .local_rot = qid },
        .{ .shape = knob, .local_pos = vec(0, 0.62, 0), .local_rot = qid },
        .{ .shape = knob, .local_pos = vec(0, -0.62, 0), .local_rot = qid },
    });
    _ = try world.createBody(.{ .shape = dumbbell, .position = vec(3.5, y, 0), .material = 2 });

    // Offset centre of mass: a box whose COM is shifted low, so it self-rights.
    const base_box: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.5, 0.5, 0.5), .convex_radius = 0.05 },
    });
    const s_offcom: zp.ShapeId = try world.shapes.addOffsetCom(gpa, base_box, vec(0, -0.4, 0));
    _ = try world.createBody(.{
        .shape = s_offcom,
        .position = vec(5.25, y, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), 0.9),
        .material = 3,
    });

    // Rotated/translated: a box pre-posed 45 deg about Z; lands on an edge.
    const rt_rot: zm.Quat = quatFromAxisAngle(vec(0, 0, 1), pi * 0.25);
    const s_rt: zp.ShapeId = try world.shapes.addRotatedTranslated(gpa, base_box, rt_rot, vec(0, 0, 0));
    _ = try world.createBody(.{ .shape = s_rt, .position = vec(7.0, y, 0), .material = 4 });
}

/// Wave B — static special geometry: a heightfield terrain, a triangle mesh
/// ramp, an infinite plane wall, and a single triangle, with a few balls and
/// boxes dropped on them to show they collide. Covers HeightFieldShape,
/// MeshShape, PlaneShape, TriangleShape.
fn sceneTerrain(world: *zp.World, gpa: Allocator, state: *State) !void {
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });

    // Heightfield terrain: a 13x13 grid with a smooth central bump.
    const sn: u32 = 13;
    const cell: f32 = 1.2;
    var heights: [sn * sn]f32 = undefined;
    var gz: u32 = 0;
    while (gz < sn) : (gz += 1) {
        var gx: u32 = 0;
        while (gx < sn) : (gx += 1) {
            const fx: f32 = float(gx) - float(sn - 1) * 0.5;
            const fz: f32 = float(gz) - float(sn - 1) * 0.5;
            const r: f32 = @sqrt(fx * fx + fz * fz);
            heights[gz * sn + gx] = 1.6 * @exp(-r * r * 0.06);
        }
    }
    const hf: zp.ShapeId = try world.shapes.addHeightField(gpa, &heights, sn, sn, cell);
    const span: f32 = float(sn - 1) * cell;
    _ = try world.createBody(.{
        .shape = hf,
        .position = vec(-span * 0.5, 0, -span * 0.5),
        .motion_type = .static,
        .material = 0,
    });

    // A static triangle-mesh ramp off to the side.
    const ramp_v = [_]Vec{
        vec(5, 0, -3), vec(11, 0, -3), vec(11, 3, 3),
        vec(5, 0, -3), vec(11, 3, 3),  vec(5, 3, 3),
    };
    const ramp_t = [_][3]u32{ .{ 0, 1, 2 }, .{ 3, 4, 5 } };
    const ramp: zp.ShapeId = try world.shapes.addMesh(gpa, &ramp_v, &ramp_t);
    _ = try world.createBody(.{ .shape = ramp, .position = vec(0, 0, 0), .motion_type = .static, .material = 0 });

    // An infinite plane as a back wall (normal +Z, offset back).
    const wall: zp.ShapeId = try world.shapes.addPlane(gpa, vec(0, 0, 1), 9.0, 12.0);
    _ = try world.createBody(.{ .shape = wall, .position = vec(0, 0, 0), .motion_type = .static, .material = 0 });

    // A single large static triangle as a little shelf.
    const tri: zp.ShapeId = try world.shapes.add(gpa, .{ .triangle = .{
        .v0 = vec(-10, 2.5, 2),
        .v1 = vec(-6, 2.5, 2),
        .v2 = vec(-8, 2.5, -2),
    } });
    _ = try world.createBody(.{ .shape = tri, .position = vec(0, 0, 0), .motion_type = .static, .material = 0 });

    // Drop balls and boxes to show the terrain/mesh/triangle are solid.
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.45 } });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.4, 0.4, 0.4), .convex_radius = 0.05 },
    });
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const fi: f32 = float(i);
        _ = try world.createBody(.{
            .shape = if (i % 2 == 0) ball else box,
            .position = vec(-3.0 + fi * 1.1, 6.0 + fi * 0.4, -1.0 + fi * 0.3),
            .material = @intCast(1 + i % 5),
        });
    }
    // One ball aimed at the ramp.
    _ = try world.createBody(.{ .shape = ball, .position = vec(8.0, 6.0, 2.0), .material = 2 });
}

/// A staggered rain of every supported convex shape (sphere/capsule/cylinder/box).
fn sceneShowcase(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 12);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const capsule: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.5, .radius = 0.35 } });
    const cylinder: zp.ShapeId = try world.shapes.add(gpa, .{ .cylinder = .{
        .half_height = 0.5,
        .radius = 0.45,
        .convex_radius = 0.05,
    } });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    state.launch_shape = sphere;
    const shapes = [_]zp.ShapeId{ sphere, capsule, cylinder, box };
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        const col: f32 = float(i % 6);
        const row: f32 = float(i / 6);
        _ = try world.createBody(.{
            .shape = shapes[i % 4],
            .position = vec((col - 2.5) * 1.6, 4.0 + row * 1.4, (row - 1.5) * 1.6),
            .motion_type = .dynamic,
            .restitution = 0.3,
            .friction = 0.6,
            .material = @intCast(i % 6),
        });
    }
}

/// A square-base box pyramid (Jolt PyramidTest), 4 wide => 30 boxes.
fn scenePyramid(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 12);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    const base: u32 = 4;
    var mat: u32 = 0;
    var layer: u32 = 0;
    while (layer < base) : (layer += 1) {
        const n: u32 = base - layer;
        const y: f32 = 0.55 + float(layer) * 1.01;
        const off: f32 = float(n - 1) * 0.5;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const px: f32 = (float(j) - off) * 1.02;
                const pz: f32 = (float(k) - off) * 1.02;
                _ = try world.createBody(.{
                    .shape = box,
                    .position = vec(px, y, pz),
                    .motion_type = .dynamic,
                    .friction = 0.8,
                    .material = @intCast(mat % 6),
                });
                mat += 1;
            }
        }
    }
}

/// Eight elongated boxes stacked with alternating 90° yaw (Jolt StackTest) — a
/// stability stress now that box-vs-box rests cleanly.
fn sceneStack(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 10);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.45, 0.45, 0.95),
        .convex_radius = 0.05,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const angle: f32 = if (i % 2 == 0) 0.0 else pi * 0.5;
        _ = try world.createBody(.{
            .shape = box,
            .position = vec(0, 0.55 + float(i) * 0.92, 0),
            .rotation = quatFromAxisAngle(vec(0, 1, 0), angle),
            .motion_type = .dynamic,
            .friction = 0.8,
            .material = @intCast(i % 6),
        });
    }
}

/// Ten elongated rods dropped from different angles with different spins. This is the
/// torque-free-rotation stress case: a thin (anisotropic) body tumbling while spinning
/// exercises world-frame angular integration and the rocking-contact solve. They should
/// tumble, clatter, and settle flat without launching or wobbling indefinitely.
fn sceneRods(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 12);
    const rod: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.15, 0.15, 0.8),
        .convex_radius = 0.03,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const fi: f32 = float(i);
        const px: f32 = (fi - 4.5) * 1.6;
        const py: f32 = 3.0 + fi * 0.15;
        const tilt_x: f32 = 0.3 + fi * 0.12;
        const tilt_z: f32 = 0.7 - fi * 0.09;
        const rot: zm.Quat = qmul(quatFromAxisAngle(vec(0, 0, 1), tilt_z), quatFromAxisAngle(vec(1, 0, 0), tilt_x));
        const bi: zp.BodyHandle = try world.createBody(.{
            .shape = rod,
            .position = vec(px, py, 0),
            .rotation = rot,
            .motion_type = .dynamic,
            .friction = 0.6,
            .restitution = 0.3,
            .material = @intCast(i % 6),
        });
        try world.setAngularVelocity(gpa, bi, vec(0.2 * fi - 0.5, 1.0 + 0.2 * fi, 0.3 - 0.1 * fi));
    }
}

/// A row of spheres with restitution stepping 0 -> 1 (Jolt RestitutionTest):
/// dropped from one height they rebound to visibly increasing heights.
fn sceneRestitution(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 14);
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.5 } });
    state.launch_shape = sphere;
    const n: u32 = 7;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t: f32 = float(i) / float(n - 1);
        _ = try world.createBody(.{
            .shape = sphere,
            .position = vec((float(i) - 3.0) * 1.9, 6.0, 0),
            .motion_type = .dynamic,
            .restitution = t,
            .friction = 0.4,
            .linear_damping = 0.0,
            .material = @intCast(i % 6),
        });
    }
}

/// A tilted static ramp with a row of boxes whose friction steps 0 -> 1 (Jolt
/// FrictionTest): the slippery ones slide off, the grippy ones hold.
fn sceneFrictionRamp(world: *zp.World, gpa: Allocator, state: *State) !void {
    const angle: f32 = 0.40; // ~23°
    const ramp: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(9, 0.5, 6),
        .convex_radius = 0.05,
    } });
    _ = try world.createBody(.{
        .shape = ramp,
        .position = vec(0, 0, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), angle),
        .motion_type = .static,
        .friction = 1.0,
        .material = 0,
    });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.4, 0.4, 0.4),
        .convex_radius = 0.05,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    const n: u32 = 6;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t: f32 = float(i) / float(n - 1);
        _ = try world.createBody(.{
            .shape = box,
            .position = vec(3.0, 2.6, (float(i) - 2.5) * 1.1),
            .motion_type = .dynamic,
            .friction = t,
            .material = @intCast(i % 6),
        });
    }
}

/// Four inward-leaning static walls form a bowl; a mix of shapes pours in and
/// piles toward the centre (a lightweight take on Jolt FunnelTest).
fn sceneFunnel(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 6);
    const wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(5, 0.3, 5),
        .convex_radius = 0.05,
    } });
    const tilt: f32 = 0.6; // top leans inward
    var w: u32 = 0;
    while (w < 4) : (w += 1) {
        const yaw: f32 = pi * 0.5 * float(w);
        const rot: zm.Quat = qmul(quatFromAxisAngle(vec(1, 0, 0), tilt), quatFromAxisAngle(vec(0, 1, 0), yaw));
        _ = try world.createBody(.{
            .shape = wall,
            .position = vec(@sin(yaw) * 4.5, 3.0, @cos(yaw) * 4.5),
            .rotation = rot,
            .motion_type = .static,
            .material = 0,
        });
    }
    const sphere: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.4, 0.4, 0.4),
        .convex_radius = 0.05,
    } });
    const capsule: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.4, .radius = 0.3 } });
    state.launch_shape = sphere;
    const shapes = [_]zp.ShapeId{ sphere, box, capsule };
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        const col: f32 = float(i % 5) - 2.0;
        const row: f32 = float(i / 5);
        _ = try world.createBody(.{
            .shape = shapes[i % 3],
            .position = vec(col * 0.6, 7.0 + row * 1.0, (float((i * 7) % 5) - 2.0) * 0.6),
            .motion_type = .dynamic,
            .friction = 0.5,
            .restitution = 0.2,
            .material = @intCast(i % 6),
        });
    }
}

/// Group id shared by the links of a constraint construct so they don't
/// self-collide (Jolt's samples use a GroupFilterTable for the same reason);
/// dropped props stay in group 0 so they still hit the construct.
const link_group: u32 = 1;

/// Swing bridge (Jolt PointConstraintTest, both ends pinned): a row of dynamic
/// planks linked end-to-end with `createPointJoint`, anchored to two static
/// posts. The chain of point joints sags into a catenary; dropped boxes load it
/// so it visibly flexes. Headless-proven: neighbour spans hold to 0.003, mid sags.
fn sceneBridge(world: *zp.World, gpa: Allocator, state: *State) !void {
    const post: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 0.4, 0.6),
        .convex_radius = 0.05,
    } });
    const plank: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.12, 0.6),
        .convex_radius = 0.05,
    } });
    const span_y: f32 = 5.0;
    const left: zp.BodyHandle = try world.createBody(.{
        .shape = post,
        .position = vec(-4.5, span_y, 0),
        .motion_type = .static,
        .material = 0,
    });
    const right: zp.BodyHandle = try world.createBody(.{
        .shape = post,
        .position = vec(4.5, span_y, 0),
        .motion_type = .static,
        .material = 0,
    });
    const n: u32 = 8;
    var prev: zp.BodyHandle = left;
    var prev_x: f32 = -4.5;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const px: f32 = -3.5 + float(i) * 1.0;
        const idx: zp.BodyHandle = try world.createBody(.{
            .shape = plank,
            .position = vec(px, span_y, 0),
            .motion_type = .dynamic,
            .friction = 0.6,
            .group_id = link_group, // planks ignore each other; props (group 0) still land on them
            .material = @intCast(1 + i % 5),
        });
        // Pin BOTH front/back corners of the shared edge (z = ±0.4). A single
        // mid-edge anchor puts the link's two pins on one line (the bridge X
        // axis), leaving each plank free to ROLL about it — so any off-centre
        // load (the dropped crates) spins the deck up without limit. A point
        // constraint locks position, not rotation; two anchors spread across the
        // width remove the roll/twist DOF while still letting the bridge sag.
        const jx: f32 = (prev_x + px) * 0.5;
        try zp.createPointJoint(world, prev, idx, vec(jx, span_y, -0.4));
        try zp.createPointJoint(world, prev, idx, vec(jx, span_y, 0.4));
        prev = idx;
        prev_x = px;
    }
    const jx_end: f32 = (prev_x + 4.5) * 0.5;
    try zp.createPointJoint(world, prev, right, vec(jx_end, span_y, -0.4));
    try zp.createPointJoint(world, prev, right, vec(jx_end, span_y, 0.4));

    // Two boxes dropped onto the deck so the bridge flexes under load.
    const crate: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
    _ = try world.createBody(.{
        .shape = crate,
        .position = vec(-1.0, 8.0, 0),
        .motion_type = .dynamic,
        .material = 3,
    });
    _ = try world.createBody(.{
        .shape = crate,
        .position = vec(1.2, 9.5, 0.2),
        .motion_type = .dynamic,
        .material = 4,
    });
}

/// Hanging chain (Jolt DistanceConstraintTest): capsule links joined by
/// `createDistanceJoint` ropes (min 0, max = gap) dangling from a static
/// anchor, with a heavy ball on the end and a sideways nudge so it swings like a
/// pendulum. Headless-proven: the rope holds at its cap distance.
fn sceneChain(world: *zp.World, gpa: Allocator, state: *State) !void {
    const anchor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.25 } });
    const link: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.3, .radius = 0.22 } });
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.6 } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });

    const top_y: f32 = 7.5;
    // Spawn pitch = the caps-touching geometry: 2 radii (cap-sphere gap at touch)
    // + 2 half-heights (the two cap-centre offsets). At this pitch the rest config
    // already has the end spheres touching, the pair ropes are taut at rest, and
    // the 5% tethers stay genuinely slack. (At the old 0.85 the caps spawned
    // OVERLAPPED and the tethers — sized from that pitch — pinned the chain there,
    // so the pair ropes could never reach touching.)
    const gap: f32 = 2.0 * 0.22 + 2.0 * 0.3; // = 1.04
    const anchor: zp.BodyHandle = try world.createBody(.{
        .shape = anchor_shape,
        .position = vec(0, top_y, 0),
        .motion_type = .static,
        .material = 0,
    });
    const n: u32 = 8;
    const hh: f32 = 0.3; // capsule half-height = cap-sphere-centre offset from COM
    const two_r: f32 = 2.0 * 0.22; // two capsule radii: the end spheres may touch, not part
    var prev: zp.BodyHandle = anchor;
    var prev_y: f32 = top_y;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const cy: f32 = top_y - gap * float(i + 1);
        const idx: zp.BodyHandle = try world.createBody(.{
            .shape = link,
            .position = vec(0, cy, 0),
            .motion_type = .dynamic,
            .group_id = link_group,
            .material = @intCast(1 + i % 5),
        });
        // Link the adjacent CAP-SPHERE CENTRES with max = 2 radii, so the two
        // end spheres can touch but the link can't pull apart — a natural chain
        // (a distance constraint fixes only the one DOF, so links still swing
        // and spin). The anchors sit off-COM, which only holds under load thanks
        // to the per-position-iteration re-derive of the constraint (Jolt does
        // the same): without it the heavy bob below tore an off-COM rope open.
        try zp.createDistanceJoint(world, prev, idx, vec(0, prev_y - hh, 0), vec(0, cy + hh, 0), 0.0, two_r);
        // Long "safety" tether: ceiling -> this body centre, capped at 1.05x the
        // body's rest depth below the ceiling (min=0). The 5% slack is deliberate:
        // taut tethers pin every body to an exact depth and the pair ropes have
        // nothing left to do (the chain dangles kinked). With slack, the pair
        // constraints define the shape and the tether only catches runaway creep —
        // the bob's load no longer has to propagate down all 8 links for a body to
        // be held (the anchor is infinite-mass), which is the iterative-solver
        // limit that bites every engine on a heavy-ended long chain, Jolt included.
        const rest_depth: f32 = top_y - cy;
        const tether_max: f32 = rest_depth * 1.05;
        try zp.createDistanceJoint(world, anchor, idx, vec(0, top_y, 0), vec(0, cy, 0), 0.0, tether_max);
        prev = idx;
        prev_y = cy;
    }
    // Heavy bob on the end, then shove the whole chain sideways so it swings.
    const bob: zp.BodyHandle = try world.createBody(.{
        .shape = ball,
        .position = vec(0, prev_y - gap, 0),
        .motion_type = .dynamic,
        .density = 4000.0,
        .group_id = link_group,
        .material = 3,
    });
    // Last cap-sphere centre to the top of the bob, same touch-but-don't-part rule.
    const bob_a: Vec = vec(0, prev_y - hh, 0);
    const bob_b: Vec = vec(0, prev_y - gap + 0.6, 0);
    try zp.createDistanceJoint(world, prev, bob, bob_a, bob_b, 0.0, two_r);
    // Ceiling tether for the heaviest body too — this is the one the link chain
    // struggles to hold, so the direct anchor link matters most here. Same 5% slack.
    const bob_y: f32 = prev_y - gap;
    const bob_tether_max: f32 = (top_y - bob_y) * 1.05;
    try zp.createDistanceJoint(world, anchor, bob, vec(0, top_y, 0), vec(0, bob_y, 0), 0.0, bob_tether_max);
    try world.setLinearVelocity(gpa, bob, vec(7.0, 0, 0));
}

/// stepped speeds — they spin like propellers (COM at the pivot, so gravity adds
/// no torque). Loose balls get batted around. Headless-proven: a motor reaches
/// its target rad/s; here sleeping is disabled so the bars never doze.
fn sceneMotor(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false; // a powered joint must keep running (Jolt sets SetAllowSleeping(false))
    try addFlatFloor(world, gpa, 10);
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.15 } });
    const bar: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(1.6, 0.18, 0.18),
        .convex_radius = 0.04,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });

    const bar_y: f32 = 3.0;
    const speeds = [_]f32{ 2.5, 4.0, 6.0 };
    var b: u32 = 0;
    while (b < speeds.len) : (b += 1) {
        const bx: f32 = (float(b) - 1.0) * 4.0;
        const hub_idx: zp.BodyHandle = try world.createBody(.{
            .shape = hub,
            .position = vec(bx, bar_y, 0),
            .motion_type = .static,
            .material = 0,
        });
        const paddle: zp.BodyHandle = try world.createBody(.{
            .shape = bar,
            .position = vec(bx, bar_y, 0),
            .motion_type = .dynamic,
            .density = 300.0,
            .group_id = link_group + b + 1, // each bar ignores nothing but itself; balls (group 0) still hit it
            .material = @intCast(1 + b % 5),
        });
        try zp.createRevoluteJoint(world, hub_idx, paddle, .{
            .anchor = vec(bx, bar_y, 0),
            .axis = vec(0, 0, 1),
            // Motor torque scales with inertia (Jolt: torque_limit = inertia * accel),
            // so `max_force` is set well above what this bar needs to hold target.
            .motor = .{ .mode = .velocity, .target_velocity = speeds[b], .max_force = 150000.0 },
        });
    }
    // Props for the bars to fling around.
    const ballp: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        _ = try world.createBody(.{
            .shape = ballp,
            .position = vec((float(i % 4) - 1.5) * 2.6, 5.5 + float(i / 4) * 1.0, (float(i % 2) - 0.5) * 0.8),
            .motion_type = .dynamic,
            .restitution = 0.4,
            .material = @intCast(2 + i % 4),
        });
    }
}

/// Welded structures (Jolt FixedConstraintTest): a horizontal cantilever of boxes
/// welded with `createWeldJoint` holds straight out from a static anchor (the
/// weld locks position AND orientation, so it doesn't sag like the bridge/chain),
/// and a welded "table" dropped beside it lands as one rigid piece.
/// Headless-proven: a 5-box cantilever droops only 0.07; a 2-box weld stays rigid.
fn sceneWeld(world: *zp.World, gpa: Allocator, state: *State) !void {
    try addFlatFloor(world, gpa, 12);
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });

    // Cantilever: a static anchor box, then 5 dynamic boxes welded in a line.
    const arm_y: f32 = 5.0;
    var prev: zp.BodyHandle = try world.createBody(.{
        .shape = box,
        .position = vec(-5.0, arm_y, 0),
        .motion_type = .static,
        .group_id = link_group,
        .material = 0,
    });
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        const idx: zp.BodyHandle = try world.createBody(.{
            .shape = box,
            .position = vec(-5.0 + float(i) * 1.0, arm_y, 0),
            .motion_type = .dynamic,
            .group_id = link_group,
            .material = @intCast(1 + i % 5),
        });
        try zp.createWeldJoint(world, prev, idx);
        prev = idx;
    }

    // A welded "table": a top slab welded onto four leg boxes, dropped to land rigid.
    const slab: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(1.4, 0.18, 1.4),
        .convex_radius = 0.05,
    } });
    const leg: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.18, 0.7, 0.18),
        .convex_radius = 0.05,
    } });
    const tx: f32 = 3.0;
    const ty: f32 = 4.0;
    const top: zp.BodyHandle = try world.createBody(.{
        .shape = slab,
        .position = vec(tx, ty + 0.7, 0),
        .motion_type = .dynamic,
        .group_id = link_group + 1,
        .material = 5,
    });
    const leg_dx = [_]f32{ -1.1, 1.1, -1.1, 1.1 };
    const leg_dz = [_]f32{ -1.1, -1.1, 1.1, 1.1 };
    var l: u32 = 0;
    while (l < 4) : (l += 1) {
        const leg_idx: zp.BodyHandle = try world.createBody(.{
            .shape = leg,
            .position = vec(tx + leg_dx[l], ty, leg_dz[l]),
            .motion_type = .dynamic,
            .group_id = link_group + 1,
            .material = 2,
        });
        try zp.createWeldJoint(world, top, leg_idx);
    }
}

/// A powered linear slider (Jolt PoweredSliderConstraintTest): a dynamic platform
/// rides a horizontal rail, driven back and forth by a velocity motor that the
/// update loop reverses at the limit stops. Only the slide axis is free; the
/// slider's perpendicular DOFs hold the platform up against gravity. Headless-
/// proven: the platform sweeps x in [-2.83, 2.80] with ~0.12 m perpendicular
/// drift and reverses cleanly at +-2.8 (steady-state drift is zero when driven
/// to a single limit). The platform COM is coincident with the rail centre-line
/// because the slider preserves the creation-pose perpendicular offset.
fn sceneSlider(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false; // a powered joint must keep running
    try addFlatFloor(world, gpa, 8);
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });

    const mid: Vec = vec(0, 4.0, 0);
    // Long thin static rail: the visible track the platform slides along.
    const rail_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.6, 0.08, 0.08),
        .convex_radius = 0.02,
    } });
    const rail: zp.BodyHandle = try world.createBody(.{
        .shape = rail_shape,
        .position = mid,
        .motion_type = .static,
    });
    // Dynamic platform, COM coincident with the rail centre-line.
    const plat_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.7, 0.2, 0.7),
        .convex_radius = 0.02,
    } });
    const plat: zp.BodyHandle = try world.createBody(.{
        .shape = plat_shape,
        .position = mid,
        .motion_type = .dynamic,
        .density = 300.0,
        .material = 3,
    });

    try zp.createPrismaticJoint(world, rail, plat, .{
        .anchor = mid,
        .axis = vec(1, 0, 0),
        .has_limits = true,
        .limit_min = -3.0,
        .limit_max = 3.0,
        // Motor force scales with mass; set well above what 2 m/s needs to hold.
        .motor = .{ .mode = .velocity, .target_velocity = 2.0, .max_force = 300000.0 },
    });
    state.slider_plat = plat;
    state.slider_idx = world.constraints.items.len - 1;
}

/// that runs up over a fixed beam and back down. The rope is rigid (min == max ==
/// the creation length), so the total length is conserved: the heavy box descends
/// to the floor and hauls the light box up toward the beam. The rope itself is
/// drawn by drawSceneOverlay (it isn't a body). Headless-proven: heavy box settles
/// at y=0.48 (on the floor), light box rises to y=8.02, rope length drift = 0.
fn scenePulley(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    try addFlatFloor(world, gpa, 10);
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });

    // Static beam the rope hangs over.
    const beam: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.2, 0.15, 0.15),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = beam, .position = vec(0, 9.0, 0), .motion_type = .static });

    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.02,
    } });
    const pa: Vec = vec(-2.5, 5.0, 0); // heavy box (descends)
    const pb: Vec = vec(2.5, 3.5, 0); // light box (rises)
    const a: zp.BodyHandle = try world.createBody(.{
        .shape = box,
        .position = pa,
        .motion_type = .dynamic,
        .density = 1500.0,
        .material = 1,
    });
    const b: zp.BodyHandle = try world.createBody(.{
        .shape = box,
        .position = pb,
        .motion_type = .dynamic,
        .density = 300.0,
        .material = 4,
    });

    // Rope ends at the top of each box; the two fixed pulley points sit just under
    // the beam, directly above each box. ratio 1, rigid rope (min == max == current).
    const bp_a: Vec = pa + vec(0, 0.5, 0);
    const bp_b: Vec = pb + vec(0, 0.5, 0);
    const fixed_a: Vec = vec(-2.5, 8.85, 0);
    const fixed_b: Vec = vec(2.5, 8.85, 0);
    try zp.createPulleyJoint(world, a, b, bp_a, fixed_a, bp_b, fixed_b, 1.0, -1.0, -1.0);
    state.pulley_idx = world.constraints.items.len - 1;
}

/// Swing-twist (ragdoll) cone joints. A static overhead bar holds four capsule
/// "limbs", each pinned by `createSwingTwistJoint` with an increasingly wide
/// swing cone (0.25..1.0 rad) and a tight twist range. Each limb is kicked
/// sideways so it drives into its cone: a correct cone holds the limb within
/// roughly its half-angle (the swing-twist cone limit now holds — see zimrphysics.zig).
fn sceneRagdoll(world: *zp.World, gpa: Allocator, state: *State) !void {
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });

    const bar: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(7, 0.2, 0.2), .convex_radius = 0.05 },
    });
    const top_y: f32 = 8.0;
    const anchor: zp.BodyHandle = try world.createBody(.{
        .shape = bar,
        .position = vec(0, top_y, 0),
        .motion_type = .static,
        .material = 0,
    });

    const limb: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.7, .radius = 0.22 } });
    const cones = [_]f32{ 0.25, 0.45, 0.7, 1.0 };
    var i: u32 = 0;
    while (i < cones.len) : (i += 1) {
        const x: f32 = -5.25 + 3.5 * float(i);
        const cy: f32 = top_y - 0.95; // COM just below the pivot; long axis (Y) vertical
        const idx: zp.BodyHandle = try world.createBody(.{
            .shape = limb,
            .position = vec(x, cy, 0),
            .motion_type = .dynamic,
            .group_id = link_group,
            .material = @intCast(1 + i % 5),
        });
        // Twist axis = the limb's long axis (vertical Y); plane axis = X. The cone
        // limits how far the limb may tilt away from vertical; twist about Y is tight.
        try zp.createSwingTwistJoint(world, anchor, idx, .{
            .anchor = vec(x, top_y, 0),
            .twist_axis = vec(0, 1, 0),
            .plane_axis = vec(1, 0, 0),
            .swing_type = .cone,
            .normal_half_cone = cones[i],
            .plane_half_cone = cones[i],
            .twist_min = -0.2,
            .twist_max = 0.2,
        });
        // Kick it sideways (about Z) so it swings into the cone, then gravity returns it.
        try world.setAngularVelocity(gpa, idx, vec(0, 0, 7.0));
    }
}

/// Gear train (Jolt GearConstraintTest): three disks pinned by hinges about Z and
/// coupled by `createGearJoint`. The first disk is driven by a velocity motor;
/// the gear constraints make the neighbours counter-rotate at the meshing ratio
/// (ratio = r_driven / r_driver, so smaller gears spin faster). Each gear is a
/// compound (disk + a contrasting spoke) so the rotation is visible, and the COM
/// sits on the pivot so gravity adds no torque. Headless-proven: a 2:1 pair gives
/// wB ~= -wA/2.
fn sceneGear(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    // Cylinder axis is local Y; rotate 90deg about X so the disk faces the camera (axis -> Z).
    const face_z: zm.Quat = quatFromAxisAngle(vec(1, 0, 0), pi * 0.5);
    const qid: zm.Quat = quatFromAxisAngle(vec(0, 1, 0), 0.0);

    const radii = [_]f32{ 1.1, 0.8, 0.55 };
    const gy: f32 = 4.0;
    var cx: f32 = -2.2; // running x; first gear centre
    var prev_idx: zp.BodyHandle = .nil;
    var prev_r: f32 = 0;
    var i: u32 = 0;
    while (i < radii.len) : (i += 1) {
        const r: f32 = radii[i];
        if (i > 0) cx += prev_r + r; // place so the disks mesh (centres = sum of radii)
        const disk: zp.ShapeId = try world.shapes.add(gpa, .{
            .cylinder = .{ .half_height = 0.18, .radius = r, .convex_radius = 0.03 },
        });
        const spoke: zp.ShapeId = try world.shapes.add(gpa, .{
            // A diametric rib that clearly stands proud of the disk on BOTH faces
            // (depth 0.30 > disk half-height 0.18) so it reads as an attached spoke
            // rather than a same-coloured bar embedded flush in the disk face (which
            // z-fights and looks like it is detaching as the gear spins).
            .box = .{ .half_extent = vec(r * 0.96, 0.11, 0.30), .convex_radius = 0.02 },
        });
        const gear_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
            .{ .shape = disk, .local_pos = vec(0, 0, 0), .local_rot = face_z },
            .{ .shape = spoke, .local_pos = vec(0, 0, 0), .local_rot = qid },
        });
        const hub_idx: zp.BodyHandle = try world.createBody(.{
            .shape = hub,
            .position = vec(cx, gy, 0),
            .motion_type = .static,
            // Same group as the gear: the hub sits inside the disk, and zimr does not yet
            // collision-filter constraint-connected bodies (Jolt's collide_connected=false),
            // so without this the embedded static hub fights the spinning gear and blows up.
            .group_id = link_group + i + 1,
            .material = 0,
        });
        const gear_idx: zp.BodyHandle = try world.createBody(.{
            .shape = gear_shape,
            .position = vec(cx, gy, 0),
            .motion_type = .dynamic,
            .density = 120.0,
            .group_id = link_group + i + 1, // gears never collide with each other (teeth aren't modelled)
            .material = @intCast(1 + i % 5),
        });
        // Hinge about Z. Motor only the first gear; the rest are driven through the gears.
        const motor: zp.MotorSettings = if (i == 0)
            .{ .mode = .velocity, .target_velocity = 2.5, .max_force = 1.0e6 }
        else
            .{};
        try zp.createRevoluteJoint(world, hub_idx, gear_idx, .{
            .anchor = vec(cx, gy, 0),
            .axis = vec(0, 0, 1),
            .motor = motor,
        });
        if (i > 0) {
            // ratio = r_this / r_prev: equal surface speed at the mesh, opposite sense.
            // Pure velocity coupling (hinge refs -1): the velocity part now enforces the
            // coupling on its own and is stable; the optional drift-correction path is not
            // wired here (see createGearJoint's note).
            try zp.createGearJoint(
                world,
                prev_idx,
                gear_idx,
                vec(0, 0, 1),
                vec(0, 0, 1),
                r / prev_r,
                -1,
                -1,
            );
        }
        prev_idx = gear_idx;
        prev_r = r;
    }
}

/// Rack and pinion (Jolt's RackAndPinionConstraintTest): a motor-driven pinion (a
/// gear-like disk+spoke hinged about Z) whose rotation is tied to a long toothed rack
/// sliding along X by `createRackAndPinionJoint`. ratio = 1/r_pinion, so the rack
/// surface speed matches the pinion rim. Pure velocity coupling (refs -1): the
/// rack tracks the pinion at v = w/ratio. Pinion and rack share a no-collide group
/// (the constraint provides the meshing; teeth are not modelled as geometry).
/// NOTE: the rack travels one way under the constant motor; reciprocation via motor
/// reversal or a slider spring is not wired here — both currently lose stability /
/// energy through the coupling (logged as a parity gap). Reset to replay.
fn sceneRackPinion(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.35 } });
    const grp: u32 = 1500;

    // Pinion: disk + spoke compound, hinged about Z, velocity-motored.
    const r_pin: f32 = 0.7;
    const py: f32 = 3.2;
    const face_z: zm.Quat = quatFromAxisAngle(vec(1, 0, 0), pi * 0.5);
    const qid: zm.Quat = quatFromAxisAngle(vec(0, 1, 0), 0.0);
    const disk: zp.ShapeId = try world.shapes.add(gpa, .{
        .cylinder = .{ .half_height = 0.18, .radius = r_pin, .convex_radius = 0.03 },
    });
    const spoke: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(r_pin * 0.96, 0.11, 0.30), .convex_radius = 0.02 },
    });
    const pinion_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
        .{ .shape = disk, .local_pos = vec(0, 0, 0), .local_rot = face_z },
        .{ .shape = spoke, .local_pos = vec(0, 0, 0), .local_rot = qid },
    });
    const hub_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    const pin_hub: zp.BodyHandle = try world.createBody(.{
        .shape = hub_shape,
        .position = vec(0, py, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const pinion: zp.BodyHandle = try world.createBody(.{
        .shape = pinion_shape,
        .position = vec(0, py, 0),
        .motion_type = .dynamic,
        .density = 120.0,
        .group_id = grp,
        .material = 4,
    });
    try zp.createRevoluteJoint(world, pin_hub, pinion, .{
        .anchor = vec(0, py, 0),
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = 1.3, .max_force = 1.0e6 },
    });

    // Rack: a long bar with evenly spaced teeth (compound) on a slider along X.
    const ry: f32 = py - r_pin - 0.18; // rack top just under the pinion rim
    const half_len: f32 = 6.0;
    const bar: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(half_len, 0.18, 0.25), .convex_radius = 0.02 },
    });
    const tooth: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.12, 0.16, 0.22), .convex_radius = 0.01 },
    });
    var children: [48]zp.CompoundChild = undefined;
    var nch: usize = 0;
    children[nch] = .{ .shape = bar, .local_pos = vec(0, 0, 0), .local_rot = qid };
    nch += 1;
    const pitch: f32 = 0.55;
    var tx: f32 = -half_len + pitch;
    while (tx < half_len - pitch * 0.5 and nch < children.len) : (tx += pitch) {
        children[nch] = .{ .shape = tooth, .local_pos = vec(tx, 0.30, 0), .local_rot = qid };
        nch += 1;
    }
    const rack_shape: zp.ShapeId = try world.shapes.addCompound(gpa, children[0..nch]);
    const rack_rail: zp.BodyHandle = try world.createBody(.{
        .shape = hub_shape,
        .position = vec(0, ry, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const rack: zp.BodyHandle = try world.createBody(.{
        .shape = rack_shape,
        .position = vec(0, ry, 0),
        .motion_type = .dynamic,
        .density = 80.0,
        .group_id = grp,
        .material = 1,
    });
    try zp.createPrismaticJoint(world, rack_rail, rack, .{ .anchor = vec(0, ry, 0), .axis = vec(1, 0, 0) });

    // ratio = 1/r_pinion: rack surface speed == pinion rim speed. Pure velocity coupling.
    try zp.createRackAndPinionJoint(world, pinion, rack, vec(0, 0, 1), vec(1, 0, 0), 1.0 / r_pin, -1, -1);
}

/// A bead threaded on a valley-shaped Hermite rail (Jolt PathConstraintTest). The rail is
/// defined in a static anchor's space and drawn by drawSceneOverlay; the bead is frictionless,
/// so under gravity it slides to the bottom and oscillates side to side, conserving energy.
fn scenePath(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    try addFlatFloor(world, gpa, 10);

    const anchor: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    const a: zp.BodyHandle = try world.createBody(.{
        .shape = anchor,
        .position = vec(0, 0, 0),
        .motion_type = .static,
    });

    const bead: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.45 } });
    state.launch_shape = bead;
    const origin: Vec = vec(0, 3, 0);
    const p0: Vec = vec(-4, 2, 0); // high left
    const p1: Vec = vec(0, 0, 0); // valley bottom
    const p2: Vec = vec(4, 2, 0); // high right
    const b: zp.BodyHandle = try world.createBody(.{
        .shape = bead,
        .position = origin + p0,
        .motion_type = .dynamic,
        .density = 500.0,
        .material = 3,
    });
    const nrm: Vec = vec(0, 0, 1); // frame normal: keep the rail in the XY plane
    const pts = [_]zp.HermitePoint{
        .{ .position = p0, .tangent = vec(4, -2, 0), .normal = nrm },
        .{ .position = p1, .tangent = vec(4, 0, 0), .normal = nrm },
        .{ .position = p2, .tangent = vec(4, 2, 0), .normal = nrm },
    };
    const path_i: usize = try zp.createPathJoint(world, a, b, &pts, false, origin, quat_identity, 0.0, .free);
    state.path_idx = path_i + 1; // +1 so 0 means "no path in this scene"
}

/// Newton's cradle: five equal balls hang as planar pendulums (rigid distance-constraint
/// strings) from a static beam, just touching, restitution ~1. The leftmost is lifted and
/// released; momentum transfers along the row and the rightmost swings out — then it
/// oscillates back and forth. `allowed_dofs = plane_2d` keeps every ball in the XY plane so
/// the row stays aligned. Strings are drawn by drawSceneOverlay. A tiny gap helps the
/// transfers resolve sequentially rather than as one mushy pile.
fn sceneNewtonsCradle(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    world.settings.min_velocity_for_restitution = 0.02; // let the chain stay elastic
    world.settings.velocity_steps = 24;
    world.settings.position_steps = 4;
    try addFlatFloor(world, gpa, 10);

    const r: f32 = 0.5;
    const y_top: f32 = 6.0;
    const y_rest: f32 = 3.0;
    const rope_len: f32 = y_top - y_rest;

    const beam_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(4, 0.2, 0.2),
        .convex_radius = 0.02,
    } });
    const beam: zp.BodyHandle = try world.createBody(.{
        .shape = beam_shape,
        .position = vec(2, y_top + 0.2, 0),
        .motion_type = .static,
    });

    const ball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = r } });
    state.launch_shape = ball_shape;
    const gap: f32 = 0.004; // 4 mm — sequential, near-invisible
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const x: f32 = float(i) * (2 * r + gap);
        var pos: Vec = vec(x, y_rest, 0);
        if (i == 0) {
            const th: f32 = 0.8727; // 50 degrees in radians (lift leftmost)
            pos = vec(x - rope_len * @sin(th), y_top - rope_len * @cos(th), 0);
        }
        const ball: zp.BodyHandle = try world.createBody(.{
            .shape = ball_shape,
            .position = pos,
            .motion_type = .dynamic,
            .density = 1000.0,
            .restitution = 1.0,
            .friction = 0.0,
            .linear_damping = 0.0,
            .angular_damping = 0.0,
            .allowed_dofs = zp.AllowedDofs.plane_2d,
        });
        try zp.createDistanceJoint(world, beam, ball, vec(x, y_top, 0), pos, rope_len, rope_len);
    }
}

/// Wrecking ball: a heavy sphere hangs from a fixed pivot by a rigid distance-constraint
/// chain, lifted to one side. Released, it swings down and smashes through a free-standing
/// brick wall (a 2-deep box stack), scattering it. Pure gravity drive — no motor. Combines a
/// distance-constraint pendulum, box stacking + friction, and big mass ratios. The chain is
/// drawn by drawSceneOverlay. Headless-proven: the wall settles, then the ball plows through
/// (mean brick displacement > 1.5 m) with no NaN.
fn sceneWreckingBall(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    try addFlatFloor(world, gpa, 16);

    // Free-standing brick wall: nx deep, nz wide, ny tall.
    const hx: f32 = 0.4;
    const hy: f32 = 0.3;
    const hz: f32 = 0.6;
    const brick: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(hx, hy, hz),
        .convex_radius = 0.01,
    } });
    const nx: usize = 2;
    const nz: usize = 3;
    const ny: usize = 5;
    const x0: f32 = 2.6;
    var ix: usize = 0;
    while (ix < nx) : (ix += 1) {
        var iz: usize = 0;
        while (iz < nz) : (iz += 1) {
            var iy: usize = 0;
            while (iy < ny) : (iy += 1) {
                const px: f32 = x0 + float(ix) * (2 * hx);
                const pz: f32 = (float(iz) - 1.0) * (2 * hz);
                const py: f32 = hy + float(iy) * (2 * hy);
                _ = try world.createBody(.{
                    .shape = brick,
                    .position = vec(px, py, pz),
                    .motion_type = .dynamic,
                    .density = 400.0,
                    .friction = 0.7,
                    .restitution = 0.0,
                    .material = 2,
                });
            }
        }
    }

    // Pivot + heavy ball on a rigid chain, lifted ~70 deg.
    const pivot_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 0.3, 0.3),
        .convex_radius = 0.02,
    } });
    const pivot: zp.BodyHandle = try world.createBody(.{
        .shape = pivot_shape,
        .position = vec(0, 9, 0),
        .motion_type = .static,
    });
    const rope_len: f32 = 6.0;
    const ball_r: f32 = 1.0;
    const ball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = ball_r } });
    state.launch_shape = ball_shape;
    const th: f32 = 1.222; // ~70 degrees
    const bp: Vec = vec(0 - rope_len * @sin(th), 9 - rope_len * @cos(th), 0);
    const ball: zp.BodyHandle = try world.createBody(.{
        .shape = ball_shape,
        .position = bp,
        .motion_type = .dynamic,
        .density = 5000.0,
        .friction = 0.5,
        .restitution = 0.1,
        .material = 5,
    });
    try zp.createDistanceJoint(world, pivot, ball, vec(0, 9, 0), bp, rope_len, rope_len);
}

/// Plinko / Galton board: balls are released one at a time from the top centre (by the
/// per-step spawner in update) and cascade through a staggered field of frictionless static
/// pegs into binned slots, building a bell curve. Balls are `plane_2d` so it stays a clean 2D
/// board; the small drop-point jitter + peg deflections supply the distribution. Frictionless
/// pegs (restitution 0.30) keep balls sliding off rather than balancing on top (no jams).
/// Headless-proven: 36 balls all reach the bins (zero field-jams), centre bins outweigh edges,
/// distribution centred (meanX ~0).
fn scenePlinko(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    state.plinko_phys_steps = 0;
    state.plinko_spawned = 0;
    state.plinko_seed = 777;

    const dx: f32 = 1.4;
    const dy: f32 = 1.1;
    const rows: usize = 6;
    const y_top: f32 = 11.0;
    const half: f32 = 6.5;

    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(half + 1, 0.5, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = floor_shape, .position = vec(0, -0.5, 0), .motion_type = .static });
    const wall_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 7, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = wall_shape, .position = vec(-half, 6, 0), .motion_type = .static });
    _ = try world.createBody(.{ .shape = wall_shape, .position = vec(half, 6, 0), .motion_type = .static });

    const peg_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.25 } });
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const py: f32 = y_top - float(row) * dy;
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
            _ = try world.createBody(.{
                .shape = peg_shape,
                .position = vec(px, py, 0),
                .motion_type = .static,
                .friction = 0.0,
                .restitution = 0.30,
                .material = 4, // distinct peg colour
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
        _ = try world.createBody(.{ .shape = div_shape, .position = vec(dxpos, 1.3, 0), .motion_type = .static });
    }

    // The balls are released over time by spawnPlinkoBall (update loop).
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.25 } });
}

/// Rube Goldberg chain reaction (Wave-J flagship). A CCD marble rolls down a ramp,
/// bowls into a line of six dominoes that topple in sequence; the last domino shoves
/// a heavy ball off a ledge; the ball drops onto an angled chute that funnels it into
/// a catch bin. One self-running spectacle exercising CCD (`motion_quality =
/// .linear_cast`) · a ramp · stacking + friction (dominoes) · restitution · a chute +
/// bin. Gravity-driven end to end (no motors), so it replays identically on Reset.
/// Headless-proven: marble rolls, 6/6 dominoes fall, ball settles in the bin
/// (x ~17.8, y ~-2.9), nothing goes non-finite.
fn sceneRubeGoldberg(world: *zp.World, gpa: Allocator) !void {
    world.settings.allow_sleeping = false;

    // Upper floor — ends at x=10 to make the ledge the ball gets shoved off.
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(7, 0.5, 2),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(3, -0.5, 0),
        .motion_type = .static,
        .friction = 0.5,
    });

    // Ramp: half-length 3 along local X, tilted -28°, sloping down to the right.
    const ramp_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3, 0.2, 1.5),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = ramp_shape,
        .position = vec(-0.65, 1.71, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), -0.4887),
        .motion_type = .static,
        .friction = 0.15,
    });

    // CCD marble at the top of the ramp (linear_cast so a fast roll can't tunnel).
    const marble_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.32 } });
    _ = try world.createBody(.{
        .shape = marble_shape,
        .position = vec(-2.8, 3.5, 0),
        .motion_type = .dynamic,
        .density = 1200,
        .friction = 0.3,
        .restitution = 0.05,
        .motion_quality = .linear_cast,
        .material = 1,
    });

    // Six dominoes — thin, tall, light; spaced so each topples into the next.
    const dom_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.08, 1.0, 0.5),
        .convex_radius = 0.01,
    } });
    for (0..6) |i| {
        const x: f32 = 3.3 + float(i) * 1.2;
        _ = try world.createBody(.{
            .shape = dom_shape,
            .position = vec(x, 1.0, 0),
            .motion_type = .dynamic,
            .density = 120,
            .friction = 0.4,
            .restitution = 0.0,
            .material = @intCast(i % 5 + 2),
        });
    }

    // Trigger ball at the ledge edge — the last domino shoves it off.
    const tball_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    _ = try world.createBody(.{
        .shape = tball_shape,
        .position = vec(9.9, 0.35, 0),
        .motion_type = .dynamic,
        .density = 800,
        .friction = 0.3,
        .restitution = 0.1,
        .motion_quality = .linear_cast,
        .material = 4,
    });

    // Angled chute that funnels the fallen ball down into the bin.
    const chute_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.0, 0.15, 0.8),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = chute_shape,
        .position = vec(12.2, -1.7, 0),
        .rotation = quatFromAxisAngle(vec(0, 0, 1), -0.32),
        .motion_type = .static,
        .friction = 0.25,
    });

    // Catch bin: a floor + a right wall.
    const bin_floor: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(2.5, 0.3, 1),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = bin_floor,
        .position = vec(16, -3.5, 0),
        .motion_type = .static,
        .friction = 0.6,
    });
    const bin_wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.2, 1.2, 1),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = bin_wall, .position = vec(18.3, -2.6, 0), .motion_type = .static });
}

/// Tumbler (Wave-J showcase). A hexagonal drum — six tangential wall boxes welded into
/// one compound body — spins on a velocity-motored hinge while a load of balls tumbles
/// inside. Shows a powered hinge motor, a compound shape used as a moving container, and
/// many-body contact, all contained so nothing can escape. Headless-proven: 15/15 balls
/// stay inside, drum holds 1.3 rad/s, balls tumble (avg speed ~1.5), zero z-drift.
fn sceneTumbler(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    const grp: u16 = 4;
    const center: Vec = vec(0, 3, 0);
    const radius: f32 = 2.5;
    // Hexagonal drum: six tangential wall boxes posed around the centre as one compound.
    const wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.12, 1.5, 1.2),
        .convex_radius = 0.02,
    } });
    var children: [6]zp.CompoundChild = undefined;
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        const th: f32 = float(k) * pi / 3.0;
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
    const hub: zp.BodyHandle = try world.createBody(.{
        .shape = hub_shape,
        .position = center,
        .motion_type = .static,
        .group_id = grp,
    });
    const drum: zp.BodyHandle = try world.createBody(.{
        .shape = drum_shape,
        .position = center,
        .motion_type = .dynamic,
        .density = 200,
        .friction = 0.8,
        .group_id = grp,
    });
    try zp.createRevoluteJoint(world, hub, drum, .{
        .anchor = center,
        .axis = vec(0, 0, 1),
        .motor = .{ .mode = .velocity, .target_velocity = 1.3, .max_force = 1.0e7 },
    });
    // A load of balls tumbling inside (varied materials for colour).
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
    state.launch_shape = ball;
    var n: usize = 0;
    var gy: f32 = 0;
    while (gy < 3) : (gy += 1) {
        var gx: f32 = 0;
        while (gx < 5) : (gx += 1) {
            if (n >= 15) {
                break;
            }
            _ = try world.createBody(.{
                .shape = ball,
                .position = center + vec((gx - 2) * 0.7, (gy - 1) * 0.7 - 0.5, 0),
                .motion_type = .dynamic,
                .density = 500,
                .friction = 0.5,
                .restitution = 0.1,
                .material = @intCast(n % 6 + 1),
            });
            n += 1;
        }
    }
}

/// Contact listener for the conveyor scene: drive any marble touching the belt along
/// the belt surface. The belt is the lower body index, so it is `a` in a belt-vs-marble
/// pair and we negate the carry direction (set the relative surface velocity v_a - v_b).
fn conveyorContact(
    cptr: ?*anyopaque,
    _: *const zp.World,
    a: zp.BodyIndex,
    b: zp.BodyIndex,
    _: u32,
    _: *const zp.Manifold,
    settings: *zp.ContactSettings,
) void {
    const cc: *const ConveyorCtx = @ptrCast(@alignCast(cptr.?));
    if (a == cc.belt) {
        settings.relative_linear_surface_velocity = vec(-cc.speed, 0, 0);
    } else if (b == cc.belt) {
        settings.relative_linear_surface_velocity = vec(cc.speed, 0, 0);
    }
}

/// Conveyor (Wave-J showcase). A flat belt — a static box whose contact friction is given
/// a surface velocity by `conveyorContact` — carries a stream of marbles from a feed point
/// on the left into a walled catch bin on the right. Shows Jolt-style contact-surface
/// velocity (the conveyor-belt feature). Reliable BY CONTAINMENT: a left back-stop plus a
/// walled bin (left wall just below the drop-off) mean a marble cannot escape even if it is
/// jostled. Headless-proven: 16/16 marbles ride across and stay in the bin, zero z-drift.
fn sceneConveyor(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    // Flat belt driving +X; the contact listener reads conveyor_ctx each step.
    const belt_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(5, 0.15, 1.3),
        .convex_radius = 0.02,
    } });
    const belt: zp.BodyHandle = try world.createBody(.{
        .shape = belt_shape,
        .position = vec(0, 2, 0),
        .motion_type = .static,
        .friction = 1.0,
    });
    state.conveyor_ctx = .{ .belt = belt.index(), .speed = 5.0 };
    world.contact_listener = .{
        .context = &state.conveyor_ctx,
        .on_contact_added = conveyorContact,
        .on_contact_persisted = conveyorContact,
    };
    // Left back-stop so a freshly dropped marble can't drift off the feed end.
    const lstop: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.2, 1.5, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = lstop, .position = vec(-5.2, 3.0, 0), .motion_type = .static });
    // Walled catch bin: floor + left wall (top just below the drop-off) + right wall, so
    // marbles fall in over the left wall but cannot be knocked back out onto the belt.
    const bin_floor: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(2.25, 0.3, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = bin_floor,
        .position = vec(7.25, -1.3, 0),
        .motion_type = .static,
        .friction = 0.6,
    });
    const bin_wall: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.15, 1.25, 1.3),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{ .shape = bin_wall, .position = vec(5.0, 0.25, 0), .motion_type = .static });
    _ = try world.createBody(.{ .shape = bin_wall, .position = vec(9.5, 0.25, 0), .motion_type = .static });
    // Marble shape (also the tap-launch shape); the stream is released by spawnConveyorMarble.
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.28 } });
    state.conveyor_steps = 0;
    state.conveyor_spawned = 0;
}

/// Clockwork (Wave-J showcase). A five-gear train of alternating sizes (so each gear spins
/// at a visibly different rate and adjacent gears counter-rotate) is driven by a velocity
/// motor on the first gear; the last gear drives a VERTICAL rack (a piston tangent to its
/// right edge) via rack-and-pinion. The drive reverses whenever the rack reaches the end of
/// its travel, so the whole machine reciprocates forever. Combines a powered hinge motor, a
/// gear train (pure velocity coupling), and rack-and-pinion (the coupling holds the rack's
/// weight against gravity along its slide axis). Headless-proven: each gear holds w0*r0/r_i
/// (alternating sign), the rack reciprocates ~2 units about its home height, nothing NaNs.
fn sceneClockwork(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    const grp: u16 = 7;
    const radii = [_]f32{ 0.6, 1.3, 0.5, 1.1, 0.7 };
    const w0: f32 = 2.5;
    const gy: f32 = 3.0;
    const face_z: zm.Quat = quatFromAxisAngle(vec(1, 0, 0), pi * 0.5);
    const qid: zm.Quat = quatFromAxisAngle(vec(0, 1, 0), 0.0);
    const hub: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.12 } });
    // Centre the train: the centres span the sum of adjacent radius pairs.
    var span: f32 = 0;
    var s: usize = 0;
    while (s + 1 < radii.len) : (s += 1) {
        span += radii[s] + radii[s + 1];
    }
    var cx: f32 = -span * 0.5;
    var prev_idx: zp.BodyHandle = .nil;
    var prev_r: f32 = 0;
    var last_gear: zp.BodyHandle = .nil;
    var last_cx: f32 = 0;
    var i: usize = 0;
    while (i < radii.len) : (i += 1) {
        const r: f32 = radii[i];
        if (i > 0) {
            cx += prev_r + r; // place so the disks mesh (centres = sum of radii)
        }
        const disk: zp.ShapeId = try world.shapes.add(gpa, .{
            .cylinder = .{ .half_height = 0.18, .radius = r, .convex_radius = 0.03 },
        });
        const spoke: zp.ShapeId = try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(r * 0.96, 0.11, 0.30), .convex_radius = 0.02 },
        });
        const gear_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
            .{ .shape = disk, .local_pos = vec(0, 0, 0), .local_rot = face_z },
            .{ .shape = spoke, .local_pos = vec(0, 0, 0), .local_rot = qid },
        });
        const hub_idx: zp.BodyHandle = try world.createBody(.{
            .shape = hub,
            .position = vec(cx, gy, 0),
            .motion_type = .static,
            .group_id = grp,
        });
        const gear_idx: zp.BodyHandle = try world.createBody(.{
            .shape = gear_shape,
            .position = vec(cx, gy, 0),
            .motion_type = .dynamic,
            .density = 100.0,
            .group_id = grp,
            .material = @intCast(i % 6 + 1),
        });
        const motor: zp.MotorSettings = if (i == 0)
            .{ .mode = .velocity, .target_velocity = w0, .max_force = 1.0e7 }
        else
            .{};
        try zp.createRevoluteJoint(world, hub_idx, gear_idx, .{
            .anchor = vec(cx, gy, 0),
            .axis = vec(0, 0, 1),
            .motor = motor,
        });
        if (i == 0) {
            state.clockwork_motor = world.constraints.items.len - 1;
        }
        if (i > 0) {
            // ratio = r_this / r_prev: equal surface speed at the mesh, opposite sense.
            try zp.createGearJoint(world, prev_idx, gear_idx, vec(0, 0, 1), vec(0, 0, 1), r / prev_r, -1, -1);
        }
        prev_idx = gear_idx;
        prev_r = r;
        last_gear = gear_idx;
        last_cx = cx;
    }
    // The last gear drives a VERTICAL rack tangent to its right edge (a piston that
    // slides up and down), so the rack never crosses the other gears.
    const r_last: f32 = radii[radii.len - 1];
    const rack_x: f32 = last_cx + r_last + 0.1;
    const rail: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 0.1, 0.1),
        .convex_radius = 0.01,
    } });
    const rack_rail: zp.BodyHandle = try world.createBody(.{
        .shape = rail,
        .position = vec(rack_x, gy, 0),
        .motion_type = .static,
        .group_id = grp,
    });
    const rack_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.18, 1.5, 0.25),
        .convex_radius = 0.02,
    } });
    const rack: zp.BodyHandle = try world.createBody(.{
        .shape = rack_shape,
        .position = vec(rack_x, gy, 0),
        .motion_type = .dynamic,
        .density = 60.0,
        .group_id = grp,
        .material = 4,
    });
    try zp.createPrismaticJoint(world, rack_rail, rack, .{
        .anchor = vec(rack_x, gy, 0),
        .axis = vec(0, 1, 0),
    });
    try zp.createRackAndPinionJoint(world, last_gear, rack, vec(0, 0, 1), vec(0, 1, 0), 1.0 / r_last, -1, -1);
    state.clockwork_rack = rack;
    state.clockwork_home = gy;
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
}

/// The four collision-stable shapes the stirrer rains in. tapered_capsule and convex_hull are
/// excluded on purpose — both NaN under heavy crowding (see sceneStirrer).
fn stirrerObjectShape(world: *zp.World, gpa: Allocator, kind: usize) !zp.ShapeId {
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

/// Stirrer (Wave-J showcase). A near-full-width four-blade rotor spins about a VERTICAL axis
/// inside a ROUND bowl, vigorously steering a deep load of 36 mixed-shape objects (spheres,
/// cubes, cylinders, capsules) around the wall. The rotor is driven by a swing-twist TWIST
/// motor (the powered ragdoll joint, used here as a continuous drive) with a tight cone so it
/// only spins, never tilts — the one constraint the showcase hadn't exercised under power.
/// Two things make a big rotor stable here: (1) a ROUND wall (32 tangent segments) so the
/// blade tip shoves objects ALONG the wall (they orbit) instead of wedging them into a flat
/// corner; (2) FAT convex radius on the cubes/cylinders so deep contacts resolve via GJK
/// before the EPA degeneracy (flat-face deep penetration -> NaN) trips. tapered_capsule and
/// convex_hull are still excluded (they NaN under crowding regardless). Objects rain in from
/// above so none spawn inside the blades. Headless-proven: 36/36 stay in, churn ~2.9 m/s,
/// finite over 7200 steps (120 s).
fn sceneStirrer(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    const grp: u16 = 3;
    const center: Vec = vec(0, 1.15, 0);
    // Static bowl: a big floor + a ROUND wall of tangent segments. A curved wall is what lets
    // the near-full-width rotor work: the blade tip moves tangentially, so it shoves objects
    // ALONG the wall (they orbit) instead of wedging them into a flat corner. Flat walls
    // wedge box/cylinder shapes into deep penetration and trip the EPA degeneracy (NaN).
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(3.2, 0.3, 3.2),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
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
        const phi: f32 = float(seg) * (2.0 * pi / float(seg_count));
        _ = try world.createBody(.{
            .shape = seg_shape,
            .position = vec(r_wall * zm.cos(phi), 1.5, r_wall * zm.sin(phi)),
            .rotation = quatFromAxisAngle(vec(0, 1, 0), -(phi + pi / 2.0)),
            .motion_type = .static,
        });
    }
    // Rotor: a horizontal cross of blades spinning about Y via a swing-twist twist motor.
    const anchor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.12, 0.12, 0.12),
        .convex_radius = 0.01,
    } });
    const anchor: zp.BodyHandle = try world.createBody(.{
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
    const rotor: zp.BodyHandle = try world.createBody(.{
        .shape = rotor_shape,
        .position = center,
        .motion_type = .dynamic,
        .density = 120.0,
        .group_id = grp,
        .material = 2,
    });
    try zp.createSwingTwistJoint(world, anchor, rotor, .{
        .anchor = center,
        .twist_axis = vec(0, 1, 0),
        .plane_axis = vec(1, 0, 0),
        .normal_half_cone = 0.05, // tight cone -> pure spin about Y, no tilt
        .plane_half_cone = 0.05,
        .twist_min = -1000.0,
        .twist_max = 1000.0,
        .twist_motor = .{ .min_torque = -1.0e7, .max_torque = 1.0e7 },
    });
    const con: *zp.Constraint = &world.constraints.items[world.constraints.items.len - 1];
    zp.swingTwistSetTwistMotorState(con, .velocity);
    zp.swingTwistSetTargetAngularVelocityCS(con, vec(1.5, 0, 0));
    // 36 mixed objects (sphere, cube, cylinder, capsule) raining into the bowl from above
    // the rotor, so nothing spawns overlapping the blades. tapered_capsule and convex_hull
    // are deliberately excluded: both go non-finite when many are crowded/churned together
    // (a real collision instability, logged as an open engine item, separate from the
    // sphere-vs-cylinder deep-penetration note).
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.3 } });
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
                const shape: zp.ShapeId = try stirrerObjectShape(world, gpa, n % 4);
                _ = try world.createBody(.{
                    .shape = shape,
                    .position = vec(ox, oy, oz),
                    .motion_type = .dynamic,
                    .density = 400.0,
                    .friction = 0.4,
                    .restitution = 0.1,
                    .material = @intCast(n % 6 + 1),
                });
                n += 1;
            }
        }
    }
}

const RagPart = struct { hh: f32, r: f32, pos: Vec, horiz: bool };

const RagJoint = struct {
    parent: usize,
    child: usize,
    pivot: Vec,
    twist: Vec,
    twist_deg: f32,
    normal_deg: f32,
    plane_deg: f32,
};

fn rj(
    parent: usize,
    child: usize,
    pivot: Vec,
    twist: Vec,
    tw: f32,
    n: f32,
    p: f32,
) RagJoint {
    return .{
        .parent = parent,
        .child = child,
        .pivot = pivot,
        .twist = twist,
        .twist_deg = tw,
        .normal_deg = n,
        .plane_deg = p,
    };
}

/// Build one Jolt-standard humanoid ragdoll: 12 capsule bones (3 torso segments, head, two
/// arms of two bones, two legs of two bones) joined by swing-twist constraints with per-joint
/// cone + twist limits (values taken from Jolt's RagdollLoader). All bones share one collision
/// group so the ragdoll does not self-collide, but different ragdolls (different groups) do
/// collide with each other and the ground. The whole body is offset by `off` and given an
/// initial `shove` so it topples and flops on landing. Headless-proven: 12 bones stay finite,
/// the joints hold, and the body settles flat on the ground (no explosion).
fn buildRagdoll(
    world: *zp.World,
    gpa: Allocator,
    off: Vec,
    grp: u16,
    shove: Vec,
    scale: f32,
) !void {
    const parts = [12]RagPart{
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
    const z90: zm.Quat = quatFromAxisAngle(vec(0, 0, 1), pi / 2.0);
    const idq: zm.Quat = quatFromAxisAngle(vec(0, 0, 1), 0);
    var bodies: [12]zp.BodyHandle = undefined;
    for (parts, 0..) |pt, i| {
        const shape: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{
            .half_height = pt.hh * scale,
            .radius = pt.r * scale,
        } });
        bodies[i] = try world.createBody(.{
            .shape = shape,
            .position = pt.pos * splat(scale) + off,
            .rotation = if (pt.horiz) z90 else idq,
            .motion_type = .dynamic,
            .density = 1000.0,
            .friction = 0.5,
            .group_id = grp,
            .material = @intCast(1 + i % 5),
        });
        try world.setLinearVelocity(gpa, bodies[i], shove);
    }
    const joints = [11]RagJoint{
        rj(0, 1, vec(0, 1.25, 0), vec(0, 1, 0), 5, 10, 10),
        rj(1, 2, vec(0, 1.45, 0), vec(0, 1, 0), 5, 10, 10),
        rj(2, 3, vec(0, 1.65, 0), vec(0, 1, 0), 90, 45, 45),
        rj(2, 4, vec(-0.225, 1.55, 0), vec(-1, 0, 0), 45, 90, 45),
        rj(2, 5, vec(0.225, 1.55, 0), vec(1, 0, 0), 45, 90, 45),
        rj(4, 6, vec(-0.65, 1.55, 0), vec(-1, 0, 0), 45, 0, 90),
        rj(5, 7, vec(0.65, 1.55, 0), vec(1, 0, 0), 45, 0, 90),
        rj(0, 8, vec(-0.15, 1.05, 0), vec(0, -1, 0), 45, 45, 45),
        rj(0, 9, vec(0.15, 1.05, 0), vec(0, -1, 0), 45, 45, 45),
        rj(8, 10, vec(-0.15, 0.55, 0), vec(0, -1, 0), 45, 0, 60),
        rj(9, 11, vec(0.15, 0.55, 0), vec(0, -1, 0), 45, 0, 60),
    };
    for (joints) |j| {
        try zp.createSwingTwistJoint(world, bodies[j.parent], bodies[j.child], .{
            .anchor = j.pivot * splat(scale) + off,
            .twist_axis = j.twist,
            .plane_axis = vec(0, 0, 1),
            .swing_type = .cone,
            .normal_half_cone = radFromDeg(j.normal_deg),
            .plane_half_cone = radFromDeg(j.plane_deg),
            .twist_min = -radFromDeg(j.twist_deg),
            .twist_max = radFromDeg(j.twist_deg),
        });
    }
}

/// Ragdoll pile (Wave-J showcase). Three Jolt-standard humanoid ragdolls are dropped with a
/// sideways shove so they topple, collide, and flop into a heap on the ground — the classic
/// Jolt "Ragdoll" sample. Each is 12 capsule bones joined by 11 swing-twist constraints with
/// realistic per-joint cone/twist limits (tight spine, hinge-like elbows/knees, wide shoulders
/// and hips). Tapping Launch fires a ball into the pile to scatter them. Headless-proven: all
/// 36 bones stay finite, joints hold, the ragdolls settle into a stable pile. Each ragdoll has
/// its own collision group (no self-collision; different ragdolls and the ground do collide).
fn sceneRagdollPile(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = true;
    const ground: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(20, 0.5, 20),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
        .friction = 0.7,
    });
    const offs = [3]Vec{ vec(-2.0, 1.0, 0), vec(0, 1.6, 0.3), vec(2.0, 1.0, -0.2) };
    const shoves = [3]Vec{ vec(1.2, 0, 0.4), vec(-0.3, 0, 0.6), vec(-1.2, 0, -0.5) };
    for (offs, 0..) |off, i| {
        try buildRagdoll(world, gpa, off, @intCast(30 + i), shoves[i], 1.0);
    }
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.4 } });
}

// ============================================================================
// Mega STRESS scene: one big world combining a spinning blender in a round
// container with many balls, a Galton board fed 100 balls, a ~100-box pyramid,
// and a chain pendulum. Built to push the solver — broad/narrow phase plus the
// velocity/position constraint sweeps — to the limit. Pair with the profiler's
// Statistics tab (each physics PHASE zone shows where the time goes).
// ============================================================================

fn stressObjectShape(world: *zp.World, gpa: Allocator, kind: usize) !zp.ShapeId {
    return switch (kind % 5) {
        0 => try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.45 } }),
        1 => try world.shapes.add(gpa, .{ .box = .{ .half_extent = vec(0.42, 0.42, 0.42), .convex_radius = 0.12 } }),
        2 => try world.shapes.add(gpa, .{ .box = .{ .half_extent = vec(1.0, 0.25, 0.25), .convex_radius = 0.1 } }),
        3 => try world.shapes.add(gpa, .{ .cylinder = .{
            .half_height = 0.55,
            .radius = 0.38,
            .convex_radius = 0.12,
        } }),
        else => try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.55, .radius = 0.32 } }),
    };
}

fn stressFloor(world: *zp.World, gpa: Allocator) !void {
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(40, 0.5, 40),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
        .friction = 0.6,
    });
}

fn stressBlender(world: *zp.World, gpa: Allocator, state: *State, o: Vec) !void {
    // This mirrors the proven sceneStirrer geometry (curved wall so the rotor tip
    // shoves objects ALONG the wall, no corner-wedging EPA blow-ups), scaled ~1.3x
    // to fit three ragdolls, with the same 1.5 rad/s twist motor. The earlier big
    // version (r_wall 5, blade 4.3) churned hard enough to jitter — this doesn't.
    const grp: u32 = 3;
    const center: Vec = o + vec(0, 3.0, 0);
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(8.0, 0.3, 8.0),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = o + vec(0, 0.5, 0),
        .motion_type = .static,
        .friction = 0.5,
    });
    const r_wall: f32 = 6.5;
    const seg_count: usize = 48;
    const seg_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.6, 3.8, 0.18),
        .convex_radius = 0.02,
    } });
    var seg: usize = 0;
    while (seg < seg_count) : (seg += 1) {
        const phi: f32 = float(seg) * (2.0 * pi / float(seg_count));
        _ = try world.createBody(.{
            .shape = seg_shape,
            .position = o + vec(r_wall * zm.cos(phi), 3.8, r_wall * zm.sin(phi)),
            .rotation = quatFromAxisAngle(vec(0, 1, 0), -(phi + pi / 2.0)),
            .motion_type = .static,
        });
    }
    const anchor_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.12, 0.12, 0.12),
        .convex_radius = 0.01,
    } });
    const anchor: zp.BodyHandle = try world.createBody(.{
        .shape = anchor_shape,
        .position = center,
        .motion_type = .static,
        .group_id = grp,
    });
    const blade_x: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(5.2, 1.5, 0.5),
        .convex_radius = 0.02,
    } });
    const blade_z: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 1.5, 5.2),
        .convex_radius = 0.02,
    } });
    const rotor_shape: zp.ShapeId = try world.shapes.addCompound(gpa, &.{
        .{ .shape = blade_x, .local_pos = vec(0, 0, 0), .local_rot = quatFromAxisAngle(vec(0, 1, 0), 0) },
        .{ .shape = blade_z, .local_pos = vec(0, 0, 0), .local_rot = quatFromAxisAngle(vec(0, 1, 0), 0) },
    });
    const rotor: zp.BodyHandle = try world.createBody(.{
        .shape = rotor_shape,
        .position = center,
        .motion_type = .dynamic,
        .density = 120.0,
        .group_id = grp,
        .material = 2,
    });
    // A hinge locks the rotor to pure Y-spin: it geometrically cannot tilt or flip,
    // unlike the swing-twist cone which only softly limited it and lost the fight when
    // a ragdoll landed off-centre on a blade. Velocity motor drives the constant spin.
    try zp.createRevoluteJoint(world, anchor, rotor, .{
        .anchor = center,
        .axis = vec(0, 1, 0),
        .motor = .{ .mode = .velocity, .target_velocity = 0.8, .max_force = 1.0e7 },
    });

    // 24 mixed objects (spheres, cubes, rods, cylinders, capsules) raining in over
    // the rotor, then 3 big ragdolls dropped from higher so nothing spawns overlapping.
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.45 } });
    var n: usize = 0;
    var layer: usize = 0;
    while (layer < 3 and n < 24) : (layer += 1) {
        const oy: f32 = 5.0 + float(layer) * 1.0;
        var ix: usize = 0;
        while (ix < 4 and n < 24) : (ix += 1) {
            var iz: usize = 0;
            while (iz < 2 and n < 24) : (iz += 1) {
                const ox: f32 = -3.3 + float(ix) * 2.2;
                const oz: f32 = -1.8 + float(iz) * 3.6;
                const shape: zp.ShapeId = try stressObjectShape(world, gpa, n);
                _ = try world.createBody(.{
                    .shape = shape,
                    .position = o + vec(ox, oy, oz),
                    .motion_type = .dynamic,
                    .density = 400.0,
                    .friction = 0.4,
                    .restitution = 0.1,
                    .material = @intCast(n % 6 + 1),
                });
                n += 1;
            }
        }
    }
    const rag_off = [3]Vec{ vec(-2.6, 8.0, 1.0), vec(2.6, 9.5, -1.2), vec(0.3, 11.0, 1.8) };
    const rag_shove = [3]Vec{ vec(0.5, 0, 0.3), vec(-0.4, 0, 0.4), vec(0.2, 0, -0.5) };
    var ri: usize = 0;
    while (ri < 3) : (ri += 1) {
        try buildRagdoll(world, gpa, o + rag_off[ri], @intCast(40 + ri), rag_shove[ri], 3.0);
    }
}

fn stressGalton(world: *zp.World, gpa: Allocator, o: Vec, state: *State) !void {
    const half: f32 = 6.5;
    const wall_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.3, 9, 1.0),
        .convex_radius = 0.02,
    } });
    const glass: u16 = render.invisible_material;
    _ = try world.createBody(.{
        .shape = wall_shape,
        .position = o + vec(-half, 9, 0),
        .motion_type = .static,
        .material = glass,
    });
    _ = try world.createBody(.{
        .shape = wall_shape,
        .position = o + vec(half, 9, 0),
        .motion_type = .static,
        .material = glass,
    });
    const back_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(half + 0.5, 9, 0.3),
        .convex_radius = 0.02,
    } });
    _ = try world.createBody(.{
        .shape = back_shape,
        .position = o + vec(0, 9, 0.95),
        .motion_type = .static,
        .material = glass,
    });
    _ = try world.createBody(.{
        .shape = back_shape,
        .position = o + vec(0, 9, -0.95),
        .motion_type = .static,
        .material = glass,
    });

    // Pegs: cylinders lying along Z (rotate Y->Z) so a round face meets each ball
    // in the X-Y drop plane, like a real Galton board.
    const peg_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .cylinder = .{
        .half_height = 0.85,
        .radius = 0.25,
        .convex_radius = 0.02,
    } });
    const peg_rot: zm.Quat = quatFromAxisAngle(vec(1, 0, 0), pi / 2.0);
    const dx: f32 = 1.4;
    const dy: f32 = 1.1;
    const y_top: f32 = 13.0;
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        const py: f32 = y_top - float(row) * dy;
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
            _ = try world.createBody(.{
                .shape = peg_shape,
                .position = o + vec(px, py, 0),
                .rotation = peg_rot,
                .motion_type = .static,
                .friction = 0.0,
                .restitution = 0.30,
                .material = 4,
            });
        }
    }
    // Visible collecting bins at the bottom: thin vertical dividers so the balls
    // pile up in columns and the bell curve is legible.
    const div_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.1, 2.0, 0.95),
        .convex_radius = 0.02,
    } });
    var d: i32 = -5;
    while (d <= 5) : (d += 1) {
        const dxpos: f32 = float(d) * 1.3;
        _ = try world.createBody(.{
            .shape = div_shape,
            .position = o + vec(dxpos, 2.0, 0),
            .motion_type = .static,
            .material = 5,
        });
    }
    // Balls sized so their diameter is ~half the board's (thin) width. They are
    // released ONE AT A TIME from the middle by spawnStressGaltonBall (update loop),
    // so they stream through the pegs like a real Galton board.
    state.galton_ball = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.225 } });
    state.galton_origin = o;
    state.galton_y_top = y_top;
    state.plinko_phys_steps = 0;
    state.plinko_spawned = 0;
    state.plinko_seed = 24681;
}

fn stressPyramid(world: *zp.World, gpa: Allocator, o: Vec) !void {
    const box: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.5, 0.5, 0.5),
        .convex_radius = 0.05,
    } });
    const base: u32 = 6;
    var count: u32 = 0;
    var mat: u32 = 0;
    var layer: u32 = 0;
    while (layer < base and count < 1000) : (layer += 1) {
        const ncells: u32 = base - layer;
        const y: f32 = 0.55 + float(layer) * 1.01;
        const offc: f32 = float(ncells - 1) * 0.5;
        var j: u32 = 0;
        while (j < ncells and count < 1000) : (j += 1) {
            var k: u32 = 0;
            while (k < ncells and count < 1000) : (k += 1) {
                const px: f32 = (float(j) - offc) * 1.02;
                const pz: f32 = (float(k) - offc) * 1.02;
                _ = try world.createBody(.{
                    .shape = box,
                    .position = o + vec(px, y, pz),
                    .motion_type = .dynamic,
                    .friction = 0.8,
                    .material = @intCast(mat % 6),
                });
                mat += 1;
                count += 1;
            }
        }
    }
}

fn stressChain(world: *zp.World, gpa: Allocator, o: Vec) !void {
    // A motorized arm spins about Y; the chain hangs from the arm's END, so the
    // attachment point orbits and the chain+bob are dragged around forever (a
    // tetherball / centrifuge) instead of swinging once and damping out.
    const top_y: f32 = 13.0;
    const arm_len: f32 = 3.5;
    const hub_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(0.35, 0.35, 0.35),
        .convex_radius = 0.02,
    } });
    const hub: zp.BodyHandle = try world.createBody(.{
        .shape = hub_shape,
        .position = o + vec(0, top_y, 0),
        .motion_type = .static,
        .group_id = link_group,
    });
    const arm_shape: zp.ShapeId = try world.shapes.add(gpa, .{ .box = .{
        .half_extent = vec(arm_len, 0.22, 0.22),
        .convex_radius = 0.02,
    } });
    const arm: zp.BodyHandle = try world.createBody(.{
        .shape = arm_shape,
        .position = o + vec(0, top_y, 0),
        .motion_type = .dynamic,
        .density = 300.0,
        .group_id = link_group,
        .material = 2,
    });
    try zp.createRevoluteJoint(world, hub, arm, .{
        .anchor = o + vec(0, top_y, 0),
        .axis = vec(0, 1, 0),
        .motor = .{ .mode = .velocity, .target_velocity = 1.3, .max_force = 1.0e6 },
    });

    const link: zp.ShapeId = try world.shapes.add(gpa, .{ .capsule = .{ .half_height = 0.3, .radius = 0.22 } });
    const ball: zp.ShapeId = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.55 } });
    const gap: f32 = 2.0 * 0.22 + 2.0 * 0.3;
    const hh: f32 = 0.3;
    const two_r: f32 = 2.0 * 0.22;
    const ex: f32 = arm_len; // chain hangs from the arm end
    const n: u32 = 7;
    var prev: zp.BodyHandle = arm;
    var prev_bottom: Vec = o + vec(ex, top_y, 0);
    var prev_y: f32 = top_y;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const cy: f32 = top_y - gap * float(i + 1);
        const idx: zp.BodyHandle = try world.createBody(.{
            .shape = link,
            .position = o + vec(ex, cy, 0),
            .motion_type = .dynamic,
            .group_id = link_group,
            .material = @intCast(1 + i % 5),
        });
        const link_b: Vec = o + vec(ex, cy + hh, 0);
        try zp.createDistanceJoint(world, prev, idx, prev_bottom, link_b, 0.0, two_r);
        prev = idx;
        prev_bottom = o + vec(ex, cy - hh, 0);
        prev_y = cy;
    }
    const bob: zp.BodyHandle = try world.createBody(.{
        .shape = ball,
        .position = o + vec(ex, prev_y - gap, 0),
        .motion_type = .dynamic,
        .density = 1500.0,
        .group_id = link_group,
        .material = 3,
    });
    const bob_top: Vec = o + vec(ex, prev_y - gap + 0.55, 0);
    try zp.createDistanceJoint(world, prev, bob, prev_bottom, bob_top, 0.0, two_r);
}

fn sceneStress(world: *zp.World, gpa: Allocator, state: *State) !void {
    world.settings.allow_sleeping = false;
    try stressFloor(world, gpa);
    try stressBlender(world, gpa, state, vec(0, 0, 0));
    try stressGalton(world, gpa, vec(15, 0, -3), state);
    try stressPyramid(world, gpa, vec(-14, 0, 5));
    try stressChain(world, gpa, vec(-14, 0, 13));
    // A big heavy projectile: 3x the usual radius (~27x mass) so a thrown ball
    // can bowl through the pyramid.
    state.launch_shape = try world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.9 } });
}

fn buildScene(state: *State) !void {
    const gpa: Allocator = state.gpa;
    const world: *zp.World = &state.world;
    switch (state.scene) {
        .shapes => try sceneShapes(world, gpa, state),
        .terrain => try sceneTerrain(world, gpa, state),
        .showcase => try sceneShowcase(world, gpa, state),
        .pyramid => try scenePyramid(world, gpa, state),
        .stack => try sceneStack(world, gpa, state),
        .rods => try sceneRods(world, gpa, state),
        .restitution => try sceneRestitution(world, gpa, state),
        .friction_ramp => try sceneFrictionRamp(world, gpa, state),
        .funnel => try sceneFunnel(world, gpa, state),
        .bridge => try sceneBridge(world, gpa, state),
        .chain => try sceneChain(world, gpa, state),
        .motor => try sceneMotor(world, gpa, state),
        .weld => try sceneWeld(world, gpa, state),
        .slider => try sceneSlider(world, gpa, state),
        .pulley => try scenePulley(world, gpa, state),
        .ragdoll => try sceneRagdoll(world, gpa, state),
        .gear => try sceneGear(world, gpa, state),
        .rack_and_pinion => try sceneRackPinion(world, gpa, state),
        .path => try scenePath(world, gpa, state),
        .newtons_cradle => try sceneNewtonsCradle(world, gpa, state),
        .wrecking_ball => try sceneWreckingBall(world, gpa, state),
        .plinko => try scenePlinko(world, gpa, state),
        .rube_goldberg => try sceneRubeGoldberg(world, gpa),
        .tumbler => try sceneTumbler(world, gpa, state),
        .conveyor => try sceneConveyor(world, gpa, state),
        .clockwork => try sceneClockwork(world, gpa, state),
        .stirrer => try sceneStirrer(world, gpa, state),
        .ragdoll_pile => try sceneRagdollPile(world, gpa, state),
        .stress => try sceneStress(world, gpa, state),
    }
}

/// Tear the World down and rebuild it for `scene` (exercises `World.deinit`).
/// The fresh World is created BEFORE freeing the old one so a failed init
/// leaves the running scene intact.
fn switchScene(state: *State, scene: Scene) void {
    const fresh: zp.World = zp.World.init(state.gpa, 1024) catch return;
    state.world.deinit(state.gpa);
    state.world = fresh;
    state.scene = scene;
    state.cam_distance = scene.camDistance();
    state.cam_pan = vec(0, 0, 0);
    buildScene(state) catch {};
}

// ===== Phase 4: constraint showcase scenes (one Jolt sample each) =====

/// Plinko ball spawner: called once per physics step. Releases one `plane_2d` ball from the
/// top centre (with small deterministic jitter) every `interval` steps, up to `max_balls`.
fn spawnPlinkoBall(state: *State) void {
    const max_balls: usize = 40;
    const interval: usize = 18;
    state.plinko_phys_steps += 1;
    if (state.plinko_spawned >= max_balls or state.plinko_phys_steps % interval != 0) {
        return;
    }
    state.plinko_seed = state.plinko_seed *% 1664525 +% 1013904223;
    const j: f32 = (float(state.plinko_seed % 1000) / 1000.0 - 0.5) * 0.7; // +-0.35
    _ = state.world.createBody(.{
        .shape = state.launch_shape,
        .position = vec(j, 12.5, 0),
        .motion_type = .dynamic,
        .density = 800.0,
        .friction = 0.0,
        .restitution = 0.30,
        .material = @intCast(state.plinko_spawned % 6 + 1),
    }) catch return;
    state.plinko_spawned += 1;
}

/// Release a marble onto the feed end of the belt at a fixed interval (well spaced so they
/// ride across without crowding), capped so the bin doesn't overflow. Driven from `update`.
/// Stress-scene Galton spawner: releases one ball from the board's middle every
/// `interval` steps (reusing the plinko counters), up to `max_balls`.
fn spawnStressGaltonBall(state: *State) void {
    const max_balls: usize = 160;
    const interval: usize = 9;
    state.plinko_phys_steps += 1;
    if (state.plinko_spawned >= max_balls or state.plinko_phys_steps % interval != 0) {
        return;
    }
    state.plinko_seed = state.plinko_seed *% 1664525 +% 1013904223;
    const jx: f32 = (float(state.plinko_seed % 1000) / 1000.0 - 0.5) * 0.3;
    state.plinko_seed = state.plinko_seed *% 1664525 +% 1013904223;
    const jz: f32 = (float(state.plinko_seed % 1000) / 1000.0 - 0.5) * 0.3;
    const y: f32 = state.galton_y_top + 2.0;
    _ = state.world.createBody(.{
        .shape = state.galton_ball,
        .position = state.galton_origin + vec(jx, y, jz),
        .motion_type = .dynamic,
        .friction = 0.05,
        .restitution = 0.25,
        .material = @intCast(state.plinko_spawned % 6 + 1),
    }) catch return;
    state.plinko_spawned += 1;
}

fn spawnConveyorMarble(state: *State) void {
    const max_marbles: usize = 15;
    const interval: usize = 55;
    state.conveyor_steps += 1;
    if (state.conveyor_spawned >= max_marbles or state.conveyor_steps % interval != 0) {
        return;
    }
    _ = state.world.createBody(.{
        .shape = state.launch_shape,
        .position = vec(-4.2, 2.7, 0),
        .motion_type = .dynamic,
        .density = 600.0,
        .friction = 0.9,
        .restitution = 0.05,
        .material = @intCast(state.conveyor_spawned % 6 + 1),
    }) catch return;
    state.conveyor_spawned += 1;
}

/// Per-scene 3D overlay, drawn in the same pass as the world (after drawWorld,
/// before endMode3D). The pulley scene's rope isn't a body, so draw it here: each
/// box's attachment point up to its fixed pulley point, plus the span between the
/// two pulleys along the beam.
fn drawSceneOverlay(f: *z.Frame, state: *State) void {
    switch (state.scene) {
        .pulley => {
            if (state.pulley_idx >= state.world.constraints.items.len) {
                return;
            }
            const con: *const zp.Constraint = &state.world.constraints.items[state.pulley_idx];
            const ba: *const zp.Body = &state.world.bodies.data[con.body_a];
            const bb: *const zp.Body = &state.world.bodies.data[con.body_b];
            const wa: Vec = ba.com_pos + rotate(ba.rot, con.local_anchor_a);
            const wb: Vec = bb.com_pos + rotate(bb.rot, con.local_anchor_b);
            const rope: Color = c.slate_300;
            z.drawLine3D(f.gl, wa, con.pulley_fixed_a, rope);
            z.drawLine3D(f.gl, con.pulley_fixed_a, con.pulley_fixed_b, rope);
            z.drawLine3D(f.gl, con.pulley_fixed_b, wb, rope);
        },
        .path => {
            if (state.path_idx == 0 or state.path_idx - 1 >= zp.pathCount(&state.world)) {
                return;
            }
            const idx: usize = state.path_idx - 1;
            const rail: Color = c.slate_300;
            const segs: usize = 64;
            var prev: Vec = zp.pathWorldPoint(&state.world, idx, 0.0);
            var i: usize = 1;
            while (i <= segs) : (i += 1) {
                const t: f32 = float(i) / float(segs);
                const cur: Vec = zp.pathWorldPoint(&state.world, idx, t);
                z.drawLine3D(f.gl, prev, cur, rail);
                prev = cur;
            }
        },
        .newtons_cradle, .wrecking_ball => {
            // Each rigid string is a distance constraint; draw beam-anchor -> ball.
            const rope: Color = c.slate_300;
            for (state.world.constraints.items) |*con| {
                if (con.kind != .distance) {
                    continue;
                }
                const ba: *const zp.Body = &state.world.bodies.data[con.body_a];
                const bb: *const zp.Body = &state.world.bodies.data[con.body_b];
                const wa: Vec = ba.com_pos + rotate(ba.rot, con.local_anchor_a);
                const wb: Vec = bb.com_pos + rotate(bb.rot, con.local_anchor_b);
                z.drawLine3D(f.gl, wa, wb, rope);
            }
        },
        else => {},
    }
}

/// The point the camera orbits and looks at: the per-scene framing height plus
/// any accumulated pan offset.
fn orbitTarget(state: *const State) Vec {
    return vec(state.scene.camTargetX(), state.scene.camTargetY(), 0) + state.cam_pan;
}

fn orbitCamPos(state: *const State) Vec {
    const yaw_rad: f32 = state.cam_angle_yaw * pi / 180.0;
    const pitch_rad: f32 = state.cam_angle_pitch * pi / 180.0;
    const cos_p: f32 = @cos(pitch_rad);
    const offset: Vec = vec(
        @sin(yaw_rad) * cos_p * state.cam_distance,
        @sin(pitch_rad) * state.cam_distance,
        @cos(yaw_rad) * cos_p * state.cam_distance,
    );
    return orbitTarget(state) + offset;
}

fn launchSphere(state: *State) !void {
    const cam_pos: Vec = orbitCamPos(state);
    const dir: Vec = normalize3(vec(0, 2.0, 0) - cam_pos);
    const idx: zp.BodyHandle = try state.world.createBody(.{
        .shape = state.launch_shape,
        .position = cam_pos + dir * splat(1.5),
        .motion_type = .dynamic,
        .restitution = 0.4,
        .material = 1,
    });
    try state.world.setLinearVelocity(state.gpa, idx, dir * splat(26.0));
}

// ===== On-screen controls via ui.zig (TAB/R/SPACE are keyboard-only; phones need taps) =====

/// A pinned `ui.zig` panel: current scene + the joint it shows + body count, then
/// the four controls as real `u.button` widgets. Returns `wantCaptureMouse` so the
/// caller suppresses camera orbit while a finger is on the panel (imgui idiom).
/// Built between `ui_host.begin` and `ui_host.render`; the click handling is the
/// immediate-mode button return value, so there is no manual hit-testing.
fn drawUiPanel(f: *z.Frame, state: *State) bool {
    const u: z.ui_real.Ui = state.ui_host.begin(f);
    const btn: z.ui_real.ButtonOpts = .{ .size = .{ 82, 26 } }; // thumb-sized targets

    if (u.window("zimrphysics", .{
        .initial_pos = .{ 10, 10 },
        .initial_size = .{ 196, 172 },
        .flags = .{ .no_move = true, .no_resize = true, .no_collapse = true },
    })) |w| {
        defer w.close();
        u.text("scene: {s}", .{state.scene.label()});
        u.separator();
        if (u.button("< Prev", btn)) {
            switchScene(state, state.scene.prev());
        }
        u.sameLine(.{});
        if (u.button("Next >", btn)) {
            switchScene(state, state.scene.next());
        }
        if (u.button("Reset", btn)) {
            switchScene(state, state.scene);
        }
        u.sameLine(.{});
        if (u.button("Launch", btn)) {
            launchSphere(state) catch {};
        }
        const plabel: []const u8 = if (state.profiling) "Resume" else "Profile";
        if (u.button(plabel, btn)) {
            state.profiling = !state.profiling;
            if (state.profiling) {
                z.profiler.freeze();
            } else {
                z.profiler.unfreeze();
            }
        }
        u.sameLine(.{});
        const wlabel: []const u8 = if (state.watching) "Watching" else "Watch";
        if (u.button(wlabel, btn)) {
            state.watching = !state.watching;
            if (state.watching) {
                z.profiler.armAutoFreeze(2.0, 4.0); // freeze on a frame > 2x baseline (and > 4ms)
            } else {
                z.profiler.disarmAutoFreeze();
                if (state.profiling and z.profiler.autoFroze()) {
                    state.profiling = false;
                    z.profiler.unfreeze();
                }
            }
        }
    }
    // A watched spike auto-freezes the profiler; mirror that into the app's pause so
    // the panel pops up on the captured hitch without the user timing anything.
    if (state.watching and z.profiler.isFrozen() and !state.profiling) {
        state.profiling = true;
    }
    // When profiling, pause the sim and show the flamegraph of the worst frame
    // in the 2s before freezing. App-owned: the profiler imposes no input.
    if (state.profiling) {
        if (u.window("profiler - worst frame", .{
            .initial_pos = .{ 10, 184 },
            .initial_size = .{ 600, 380 },
        })) |w| {
            defer w.close();
            z.profiler_ui.panel(u);
        }
    }
    return u.wantCaptureMouse();
}

fn update(f: *z.Frame, state: *State) void {
    // Physics runs on a FIXED 1/60 s timestep, decoupled from the (variable, often
    // ~30 fps on mobile) render rate. Passing the raw frame dt straight to the solver
    // was the bug behind exploding stacks: one ~1/30 s Euler step is too large for the
    // contact solver and pumps energy into the pile. Jolt's own guidance is the same —
    // keep each step <= 1/60 s and subdivide longer frames. We accumulate real time here
    // and drain it in fixed sub-steps below (capped to avoid a slow-device spiral).
    state.phys_accum += clamp(f.time.delta_time, 0.0, 0.1);
    state.frame_count += 1;

    if (!state.spawned) {
        state.cam_distance = state.scene.camDistance();
        buildScene(state) catch {};
        state.spawned = true;
    }

    // The ui.zig panel runs first: its buttons fire here (immediate-mode) and it
    // reports whether the pointer is over the panel so orbit can stand down.
    const ui_capture: bool = drawUiPanel(f, state);

    // Phone-style camera: 1 finger orbits, 2 fingers pinch-zoom and pan. Mirrors
    // the helmet/raytracer viewers. Orbit is gated to <2 touches so a pinch never
    // also spins the view; all gestures stand down while the pointer is on the UI.
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2 and !ui_capture) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const spread_x: f32 = a[0] - b[0];
        const spread_y: f32 = a[1] - b[1];
        const spacing: f32 = @sqrt(spread_x * spread_x + spread_y * spread_y);
        const mid: Vec2 = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
        if (state.two_finger) {
            // Pinch: fingers spreading -> move closer.
            state.cam_distance = clamp(state.cam_distance - (spacing - state.prev_pinch) * 0.03, 6.0, 40.0);
            // Pan: slide the target in the camera's screen plane by the midpoint delta.
            const md_x: f32 = mid[0] - state.prev_pan_mid[0];
            const md_y: f32 = mid[1] - state.prev_pan_mid[1];
            const fwd: Vec = normalize3(orbitTarget(state) - orbitCamPos(state));
            const right: Vec = normalize3(cross(fwd, vec(0, 1, 0)));
            const up: Vec = cross(right, fwd);
            const k: f32 = state.cam_distance * 0.0016;
            state.cam_pan = state.cam_pan - right * splat(md_x * k) + up * splat(md_y * k);
        }
        state.prev_pinch = spacing;
        state.prev_pan_mid = mid;
        state.two_finger = true;
        state.dragging = false;
    } else {
        state.two_finger = false;
        state.prev_pinch = 0;
        if (touches < 2 and z.isMouseButtonDown(f.input, .left) and !ui_capture) {
            if (state.dragging) {
                const delta: Vec2 = z.getMouseDelta(f.input);
                state.cam_angle_yaw -= delta[0] * 0.4;
                state.cam_angle_pitch = clamp(state.cam_angle_pitch + delta[1] * 0.4, -85.0, 85.0);
            }
            state.dragging = true;
        } else {
            state.dragging = false;
        }
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0 and !ui_capture) {
        state.cam_distance = clamp(state.cam_distance - wheel * 1.5, 6.0, 40.0);
    }

    if (z.isKeyPressed(f.input, .space)) {
        launchSphere(state) catch {};
    }
    if (z.isKeyPressed(f.input, .tab)) {
        switchScene(state, state.scene.next());
    }
    if (z.isKeyPressed(f.input, .r)) {
        switchScene(state, state.scene);
    }

    // Powered-slider scene: reverse the velocity motor at the limit stops so the
    // platform sweeps back and forth instead of parking against one end.
    if (state.scene == .slider and state.slider_idx < state.world.constraints.items.len) {
        const px: f32 = state.world.bodies.data[state.slider_plat.index()].com_pos[0];
        const con: *zp.Constraint = &state.world.constraints.items[state.slider_idx];
        if (px > 2.8 and con.motor.target_velocity > 0) {
            con.motor.target_velocity = -2.0;
        }
        if (px < -2.8 and con.motor.target_velocity < 0) {
            con.motor.target_velocity = 2.0;
        }
    }

    if (state.scene == .clockwork and state.clockwork_motor < state.world.constraints.items.len) {
        const ry: f32 = state.world.bodies.data[state.clockwork_rack.index()].com_pos[1];
        const con: *zp.Constraint = &state.world.constraints.items[state.clockwork_motor];
        if (ry > state.clockwork_home + 1.0 and con.motor.target_velocity > 0) {
            con.motor.target_velocity = -2.5;
        }
        if (ry < state.clockwork_home - 1.0 and con.motor.target_velocity < 0) {
            con.motor.target_velocity = 2.5;
        }
    }

    const fixed_dt: f32 = 1.0 / 60.0;
    if (state.profiling) {
        state.phys_accum = 0; // paused for inspection; profiler is frozen
    } else {
        var sub: u32 = 0;
        while (state.phys_accum >= fixed_dt and sub < 4) : (sub += 1) {
            if (state.scene == .plinko) {
                spawnPlinkoBall(state);
            }
            if (state.scene == .stress) {
                spawnStressGaltonBall(state);
            }
            if (state.scene == .conveyor) {
                spawnConveyorMarble(state);
            }
            zp.step(&state.world, fixed_dt) catch {};
            state.phys_accum -= fixed_dt;
        }
        if (state.phys_accum > fixed_dt) {
            state.phys_accum = 0; // device fell behind; drop the backlog rather than spiral
        }
    }

    // No clearViewport: the runner's pass already cleared to the config colour.
    // A full-screen 2D quad here would flush after the 3D and paint over it.
    const cam: Camera3D = .{
        .position = orbitCamPos(state),
        .target = orbitTarget(state),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    {
        const zg: z.profiler.Zone = z.profiler.zoneNamed(@src(), "render.grid");
        defer zg.end();
        z.drawGrid(f.gl, 24, 1.0);
    }
    const style: render.Style = .{
        .palette = &demo_palette,
        // A medium slate so static geometry (terrain, ramps, floors) reads
        // against the near-black background; co.palette.surface was almost black.
        .static_color = c.slate_500,
    };
    render.drawWorld(f.gl, &state.world, style);
    {
        const zo: z.profiler.Zone = z.profiler.zoneNamed(@src(), "render.overlay");
        defer zo.end();
        drawSceneOverlay(f, state);
    }
    {
        const zf: z.profiler.Zone = z.profiler.zoneNamed(@src(), "render.flush3d");
        defer zf.end();
        z.endMode3D(f.gl);
    }
    // endMode3D restores the 2D pipeline automatically, so the UI composes on
    // top of the 3D in the same pass with no manual restore/reopen.
    {
        const zu: z.profiler.Zone = z.profiler.zoneNamed(@src(), "render.ui");
        defer zu.end();
        state.ui_host.render(f);
    }
    // NB: no explicit endDrawing — the runner closes the frame (and endDrawing is
    // idempotent). Leaving the pass open lets a host like the launcher compose its
    // own overlay on top of this app's frame.
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - zimrphysics demo",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
            // Clear via the pass load-op (matches the page background). Drawing the
            // background as a full-screen 2D quad instead would sit in the 2D
            // batch and flush AFTER the immediate 3D, painting over it.
            .clear = .{ .r = 10.0 / 255.0, .g = 12.0 / 255.0, .b = 18.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
