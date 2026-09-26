//! Geno, servoing a copied clip: the robot built from the character its captures were recorded on
//! (rl_track_plan.md, Phase R), standing on a real floor and pulled through a capture by the tracking
//! task's own servo.
//!
//! Nothing here learns, and nothing is fitted. The clip is the capture COPIED onto the robot - every
//! joint turned exactly as recorded (`robot_geno.copyClip`). The physics is the engine's, with contacts
//! through the bridge and the model's own exclusions. The servo is `robot_track.pdTorques`, the very law a
//! policy will act through, with Geno's own gains (`robot_geno.servo_gains`: its acceleration cap tuned on
//! the get-up). So what you watch is how far a spring alone gets - and every
//! stumble is something a policy will have to learn to prevent.
//!
//! The translucent figure is the reference: the clip's own pose, drawn from the same model. When the
//! robot's hips drift 35 cm from the reference's, it has fallen; the page notes how long it stood and
//! starts the clip again.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const codecs = z.codecs;
const rbt = z.robot;
const mjcf = z.mjcf;
const robot_mjcf = z.robot_mjcf;
const robot_physics = z.robot_physics;
const zimrphysics = z.zimrphysics;
const robot_track = z.robot_track;
const dance = z.robot_dance;
const geno = z.robot_geno;

const Allocator = std.mem.Allocator;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const vec = zm.vec;
const float = zm.float;
const splat = zm.splat;
const mulMat = zm.mulMat;
const qmul = zm.qmul;
const rotate = zm.rotate;
const quatToMat = zm.quatToMat;
const conjugate = zm.conjugate;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const radFromDeg = zm.radFromDeg;
const quatFromTo = zm.quatFromTo;
const translation = zm.translation;
const scaling = zm.scaling;
const length3 = zm.length3;

const bind_bvh = @embedFile("geno_bind.bvh");
const walk_bvh = @embedFile("walk.bvh");
const getup_bvh = @embedFile("getup.bvh");
/// Geno's T-pose - the pose the page can hold still, with or without a small bend at the knees.
const stance_bvh = @embedFile("geno_stance.bvh");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };
const robot_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const foot_col: Color = .{ .r = 150, .g = 190, .b = 140, .a = 255 };
/// The reference, see-through, so the robot is always visible inside or beside it.
const ghost_col: Color = .{ .r = 230, .g = 210, .b = 120, .a = 70 };

/// One control step: the clips' own rate, and the rate the page aims for.
const frame_time: f32 = 1.0 / 60.0;
/// The robot has fallen when its hips are this far from where the reference has them.
/// The engine's world is z-up (MuJoCo's convention); the page draws y-up. A quarter turn back about x.
const to_y_up: Quat = .{ -0.70710678, 0.0, 0.0, 0.70710678 };

const clip_names = [_][]const u8{ "walk", "get-up" };

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,

    /// The robot: its model text parsed and built, its state, and the reference's.
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    data: rbt.Data,
    reference: rbt.Data,
    hips: u32,
    /// The floor, in the collision world the bridge joins to the robot.
    world: zimrphysics.World,
    bridge: robot_physics.Bridge,
    /// The floor's body, kept so its friction can be changed live.
    floor: zimrphysics.BodyHandle,
    /// The floor's friction (a contact's is the geometric mean with the feet's 1.0).
    floor_friction: f32 = geno.floor_friction,
    /// The captures, copied onto the robot.
    clips: [clip_names.len]dance.Clip,
    /// The T-pose, copied - one frame - and the pose actually held: the T-pose with the knee bend applied.
    stance: dance.Clip,
    held: []f32,
    /// The servo's working space, as the task allocates it.
    accel: []f32,
    scratch: []f32,
    dense: []f32,
    full: []f32,
    torque: []f32,

    which: usize = 0,
    frame: usize = 0,
    /// The one failure criterion - the task's, the teacher's, the tests' (`geno.FailureCheck`).
    check: geno.FailureCheck = undefined,
    playing: bool = true,
    show_reference: bool = true,
    /// Off: a fall ends nothing - the robot keeps following the clip's joint angles wherever it lies, which
    /// shows the servo's local pose on a ragdoll.
    reset_on_fall: bool = true,
    /// Hold a pose still instead of playing a clip: Geno's T-pose, bent at the knees by `knee_bend`.
    hold_pose: bool = false,
    /// Degrees of bend at each knee - the hips and ankles take half each, the other way, so the torso
    /// stays upright and the feet flat.
    knee_bend: f32 = 0.0,
    /// Degrees the held pose leans BACK over its ankles - the feet stay flat and where they are.
    lean_back: f32 = 0.0,
    /// The camera follows the robot's hips.
    follow_camera: bool = false,
    /// The servo's spring, live: its stiffness (Hz) and its acceleration cap - Geno's tuned values to start.
    /// The capture-point reflex (while holding the T-pose): radians of ankle lean per metre the capture point
    /// sits ahead of the feet. 2-4 holds; 8 and more over-correct into a wobble and a fall.
    reflex_gain: f32 = 3.0,
    reflex: geno.Reflex = undefined,
    balanced_goal: []f32 = &.{},
    frequency: f32 = geno.servo_gains.frequency,
    max_acceleration: f32 = geno.servo_gains.max_acceleration,
    /// How long one control step takes - collision, servo and dynamics - smoothed, in milliseconds.
    step_ms: f32 = 0.0,
    /// How far the hips are from the reference's, this frame.
    off: f32 = 0.0,
    /// Frames since the robot last started the clip.
    up_frames: usize = 0,
    falls: usize = 0,
    last_run: f32 = 0.0,
    best_run: f32 = 0.0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 16),
        .ui_host = undefined,
        .cam = z.OrbitCamera.init(vec(0.0, 0.9, 0), 3.2),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
        .transform = .{zm.identity()},
        .doc = undefined,
        .robot = undefined,
        .imported = undefined,
        .data = undefined,
        .reference = undefined,
        .hips = 0,
        .world = undefined,
        .bridge = undefined,
        .floor = undefined,
        .clips = undefined,
        .stance = undefined,
        .held = &.{},
        .accel = &.{},
        .scratch = &.{},
        .dense = &.{},
        .full = &.{},
        .torque = &.{},
    };
    s.ui_host = z.UiHost.init(gpa, s.font);

    // The robot, from its checked model file - at the clips' own rate, with room for a whole body's
    // contacts.
    s.doc = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    // Armature 2 on every joint: in this servo a joint's strength is its free-flight inertia, and this makes
    // each as strong standing as the load it carries needs (it costs the dance nothing).
    for (s.robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = geno.standing_armature;
        }
    }
    s.imported = try robot_mjcf.build(gpa, &s.robot, .{
        .gravity = vec(0, 0, -9.81),
        .timestep = frame_time,
        .max_contacts = 256,
    });
    const m: *const rbt.Model = &s.imported.model;
    s.data = try rbt.Data.init(gpa, m);
    s.check = try .init(gpa, m);
    s.reference = try rbt.Data.init(gpa, m);
    s.hips = s.imported.bodyIndex("Hips") orelse return error.NoHips;

    // The clips: each capture, copied onto the robot.
    var bind: geno.Posed = try geno.readPose(gpa, bind_bvh);
    defer bind.deinit(gpa);
    for ([_][]const u8{ walk_bvh, getup_bvh }, 0..) |bytes, k| {
        var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
        defer capture.deinit();
        s.clips[k] = try geno.copyClip(gpa, &s.imported, bind, capture);
    }
    var stance_capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_bvh, null);
    defer stance_capture.deinit();
    s.stance = try geno.copyClip(gpa, &s.imported, bind, stance_capture);
    s.held = try gpa.alloc(f32, s.stance.nq);
    bendKnees(s);

    // The floor: a static box whose top face is the engine's z = 0.
    s.world = try .init(gpa, 64);
    const floor_shape: zimrphysics.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(50, 50, 0.5), .convex_radius = 0.001 },
    });
    s.floor = try s.world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, 0, -0.5),
        .rotation = zm.qidentity(),
        .motion_type = .static,
        .friction = s.floor_friction,
    });

    const nv: usize = m.nv;
    s.accel = try gpa.alloc(f32, nv);
    s.scratch = try gpa.alloc(f32, nv);
    s.dense = try gpa.alloc(f32, nv * nv);
    s.full = try gpa.alloc(f32, nv);
    s.torque = try gpa.alloc(f32, nv);
    s.balanced_goal = try gpa.alloc(f32, m.nq);
    s.reflex = try .init(&s.imported, s.imported.bodyIndex("Hips") orelse return error.NoHips);

    restart(s);
    s.bridge = try .init(gpa, &s.world, m, &s.data, 256);
    s.bridge.listen(&s.world);
}

fn deinit(gpa: Allocator, s: *State) void {
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    for (&s.clips) |*clip| {
        clip.deinit();
    }
    gpa.free(s.held);
    s.stance.deinit();
    gpa.free(s.torque);
    gpa.free(s.balanced_goal);
    gpa.free(s.full);
    gpa.free(s.dense);
    gpa.free(s.scratch);
    gpa.free(s.accel);
    s.reference.deinit();
    s.check.deinit(gpa);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// The pose the servo pulls toward this frame: the clip's, or the held one.
fn target(s: *const State) []const f32 {
    if (s.hold_pose) {
        return s.held;
    }
    const clip: *const dance.Clip = &s.clips[s.which];
    return clip.targets[s.frame * clip.nq ..][0..clip.nq];
}

/// Build the held pose: the T-pose, bent. Each bend is a turn about the world's sideways axis applied AT
/// a joint - so everything below it turns with it - the hips by -b/2, the knees by +b, the ankles by -b/2:
/// the thigh ends turned -b/2, the shin +b/2, the foot level again. All three turn about one axis, so they
/// compose exactly. Then the root comes down by however far the bend lifted the ankles off the floor, and
/// up 5 mm, since Geno's soles sit 4.5 mm below it at rest.
fn bendKnees(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    @memcpy(s.held, s.stance.targets[0..s.stance.nq]);
    const d: *rbt.Data = &s.reference;
    @memcpy(d.pos, s.held);
    d.stage = .stale;
    rbt.kinematics(m, d);
    const ankle: u32 = s.imported.bodyIndex("LeftFoot") orelse return;
    const other_ankle: u32 = s.imported.bodyIndex("RightFoot") orelse return;
    const before: f32 = d.body_xpos[ankle][2];
    const feet_before: Vec = (d.body_xpos[ankle] + d.body_xpos[other_ankle]) * splat(0.5);
    // The lean: the root turns back about the sideways axis, and the ankles turn it back out of the feet.
    // (A turn of +a about +x tips the body forward, toward -y, in the engine's z-up world.)
    const lean: f32 = -radFromDeg(s.lean_back);
    const half: f32 = radFromDeg(0.5 * s.knee_bend);
    const bends = [_]struct { name: []const u8, angle: f32 }{
        .{ .name = "LeftUpLeg", .angle = -half },
        .{ .name = "RightUpLeg", .angle = -half },
        .{ .name = "LeftLeg", .angle = 2.0 * half },
        .{ .name = "RightLeg", .angle = 2.0 * half },
        .{ .name = "LeftFoot", .angle = -half - lean },
        .{ .name = "RightFoot", .angle = -half - lean },
    };
    {
        // The root's own turn is a world turn (its free joint is absolute): lean it first.
        const r: []f32 = s.held[3..7];
        const leaned: Quat = qmul(quatFromAxisAngle(vec(1, 0, 0), lean), .{ r[0], r[1], r[2], r[3] });
        r[0] = leaned[0];
        r[1] = leaned[1];
        r[2] = leaned[2];
        r[3] = leaned[3];
    }
    for (bends) |bend| {
        const b: u32 = s.imported.bodyIndex(bend.name) orelse continue;
        const joint: usize = for (m.jnt_body, 0..) |owner, j| {
            if (owner == b) {
                break j;
            }
        } else continue;
        const adr: usize = m.jnt_qpos_adr[joint];
        // The engine keeps a ball's quaternion w-last (measured, R7); the turn, carried into the joint's
        // own frame, goes on the joint's right: joint' = joint * (W^-1 * turn * W).
        const q: []f32 = s.held[adr..][0..4];
        const world: Quat = d.body_xrot[b];
        const turn: Quat = quatFromAxisAngle(vec(1, 0, 0), bend.angle);
        const local: Quat = qmul(qmul(conjugate(world), turn), world);
        const bent: Quat = qmul(.{ q[0], q[1], q[2], q[3] }, local);
        q[0] = bent[0];
        q[1] = bent[1];
        q[2] = bent[2];
        q[3] = bent[3];
    }
    @memcpy(d.pos, s.held);
    d.stage = .stale;
    rbt.kinematics(m, d);
    // Put the feet back where they stood: across the floor from their midpoint, and down from the bend's lift.
    const feet_after: Vec = (d.body_xpos[ankle] + d.body_xpos[other_ankle]) * splat(0.5);
    s.held[0] += feet_before[0] - feet_after[0];
    s.held[1] += feet_before[1] - feet_after[1];
    s.held[2] -= d.body_xpos[ankle][2] - before;
    s.held[2] += 0.005;
}

/// Back to the start: the robot placed exactly on the reference - a copy - and still.
fn restart(s: *State) void {
    // Back to the clip's start FIRST: the placement below reads the frame (a run that ended mid-clip must
    // not launch the body there while the reference starts over).
    s.frame = 0;
    // A CLEAN start: every layer's memory of the last run forgotten - the solver's warm starts, the world's
    // cached contacts, the bridge's sense of motion, the reflex's last frame - so a restart is repeatable.
    s.data.reset(&s.imported.model);
    s.data.forgetWarmStart();
    geno.ServoRun.forgetContacts(&s.world);
    if (s.hold_pose) {
        // A pose held still: placed on it, at rest.
        @memcpy(s.data.pos, target(s));
        @memset(s.data.vel, 0);
        s.data.stage = .stale;
        rbt.forward(&s.imported.model, &s.data);
    } else {
        // A clip: the task's own reset, exactly as the training fleet takes it - the frame's pose and the
        // velocity the clip has there (the backward difference into it), so the body starts in stride.
        robot_track.resetToFrame(&s.imported.model, &s.data, &s.clips[s.which], s.frame);
    }
    // Rested ON the floor, 1 mm clear: a copied pose puts the feet into it (17 mm on the walk's first frame),
    // and the contact solver would throw that overlap out in one step - the jump on every restart.
    _ = rbt.restOnFloor(&s.imported.model, &s.data, 0.001);
    s.bridge.teleported();
    s.reflex.forget();
    s.up_frames = 0;
}

/// A run ends - by a fall, or by reaching the clip's end: note how long the robot stood, and start again.
fn endRun(s: *State, fell: bool) void {
    s.last_run = float(s.up_frames) * frame_time;
    s.best_run = @max(s.best_run, s.last_run);
    if (fell) {
        s.falls += 1;
    }
    restart(s);
}

/// One control step, exactly as the tracking task takes it: collide, then the servo's torques toward this
/// frame's target, then the dynamics.
fn step(s: *State) !void {
    const started: f64 = z.wgpu.nowMs();
    defer {
        // Smoothed, so the number can be read: a tenth of each new step.
        const took: f32 = @floatCast(z.wgpu.nowMs() - started);
        s.step_ms = if (s.step_ms == 0.0) took else 0.9 * s.step_ms + 0.1 * took;
    }
    const m: *const rbt.Model = &s.imported.model;
    const clip: *const dance.Clip = &s.clips[s.which];
    const requested: []const f32 = target(s);
    const goal: []const f32 = if (s.hold_pose and s.reflex_gain > 0.0) blk: {
        s.reflex.apply(&s.data, s.reflex_gain, frame_time, requested, s.balanced_goal);
        break :blk s.balanced_goal;
    } else requested;
    try s.bridge.sync(&s.world, m, &s.data);
    try zimrphysics.step(&s.world, frame_time);
    s.bridge.harvest(&s.data);
    rbt.biasForce(m, &s.data);
    robot_track.pdTorques(
        m,
        &s.data,
        goal,
        .{ .frequency = s.frequency, .max_acceleration = s.max_acceleration },
        frame_time,
        s.accel,
        s.scratch,
        s.dense,
        s.full,
        s.torque,
    );
    @memcpy(s.data.applied_force, s.torque);
    rbt.step(m, &s.data);
    rbt.forward(m, &s.data);
    s.up_frames += 1;
    if (s.hold_pose) {
        return;
    }
    s.frame += 1;
    if (s.frame >= clip.frame_count) {
        if (s.reset_on_fall) {
            endRun(s, false);
        } else {
            // Loop the reference; the robot stays wherever it is.
            s.frame = 0;
        }
    }
}

/// The reference's pose on the current frame - what the servo is pulling toward.
fn placeReference(s: *State) void {
    @memcpy(s.reference.pos, target(s));
    s.reference.stage = .stale;
    rbt.kinematics(&s.imported.model, &s.reference);
}

fn toYUp(p: Vec) Vec {
    return rotate(to_y_up, p);
}

fn update(f: *z.Frame, s: *State) void {
    if (s.playing) {
        step(s) catch |err| std.log.err("geno_track: step failed: {t}", .{err});
    }
    placeReference(s);
    // Fallen: the reference LOST, by the one failure criterion (`geno.FailureCheck`: the task's own) - which ends
    // the run, unless the ragdoll is being watched on the floor. The hips' distance is still shown.
    s.off = length3(s.data.body_xpos[s.hips] - s.reference.body_xpos[s.hips]);
    const clip: *const dance.Clip = &s.clips[s.which];
    if (s.reset_on_fall and s.check.lost(&s.imported.model, &s.data, clip, s.frame)) {
        endRun(s, true);
        placeReference(s);
    }

    z.clearViewport(f, bg);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    // The view follows the robot as the clip carries it across the floor.
    if (s.follow_camera) {
        const hips: Vec = toYUp(s.data.body_xpos[s.hips]);
        s.cam.target = vec(hips[0], 0.9, hips[2]);
    }
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 10.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 40, 0.25);
    s.transform[0] = mulMat(translation(0, -0.1, 0), scaling(40, 0.2, 40));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);
    drawBodies(s, gl, &s.data, robot_col, foot_col);
    // Last, so the robot shows through it.
    if (s.show_reference) {
        drawBodies(s, gl, &s.reference, ghost_col, ghost_col);
    }
    z.endMode3D(gl);
}

/// Every shape the model carries, where `d` puts its body - turned from the engine's z-up world into the
/// page's y-up one. MJCF capsules lie along their own z axis, `size` holding the radius and half length.
fn drawBodies(
    s: *State,
    gl: *z.WgpuGl,
    d: *const rbt.Data,
    round: Color,
    flat: Color,
) void {
    for (s.robot.bodies) |body| {
        const b: u32 = s.imported.bodyIndex(body.name) orelse continue;
        for (s.robot.geoms[body.geom_start..][0..body.geom_count]) |geom| {
            const at: Vec = toYUp(d.body_xpos[b] + rotate(d.body_xrot[b], geom.pos));
            const turn: Quat = qmul(to_y_up, qmul(d.body_xrot[b], geom.rot));
            switch (geom.kind) {
                .capsule => {
                    const half: Vec = rotate(turn, vec(0, 0, geom.size[1]));
                    drawCapsule(s, gl, at - half, at + half, geom.size[0], round);
                },
                .sphere => drawBall(s, gl, at, geom.size[0], round),
                .box => {
                    s.transform[0] = mulMat(
                        mulMat(translation(at[0], at[1], at[2]), quatToMat(turn)),
                        scaling(2.0 * geom.size[0], 2.0 * geom.size[1], 2.0 * geom.size[2]),
                    );
                    z.drawMeshInstanced(gl, &s.cube, &s.transform, flat);
                },
                else => {},
            }
        }
    }
}

fn drawBall(
    s: *State,
    gl: *z.WgpuGl,
    at: Vec,
    radius: f32,
    colour: Color,
) void {
    s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(radius, radius, radius));
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, colour);
}

/// A capsule: a cylinder between two points - the mesh runs up its own y from 0 to 1 - and a ball on
/// each end.
fn drawCapsule(
    s: *State,
    gl: *z.WgpuGl,
    a: Vec,
    b: Vec,
    radius: f32,
    colour: Color,
) void {
    const along: Vec = b - a;
    const span: f32 = length3(along);
    const upright: Quat = if (span > 1.0e-6) quatFromTo(vec(0, 1, 0), along * splat(1.0 / span)) else zm.qidentity();
    s.transform[0] = mulMat(mulMat(translation(a[0], a[1], a[2]), quatToMat(upright)), scaling(radius, span, radius));
    z.drawMeshInstanced(gl, &s.cylinder, &s.transform, colour);
    drawBall(s, gl, a, radius, colour);
    drawBall(s, gl, b, radius, colour);
}

fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    const placement: ui.WindowOpts = .{ .initial_pos = .{ 4, 4 }, .initial_size = .{ 360, 400 } };
    if (u.window("Geno, servoing a copied clip", placement)) |window| {
        defer window.close();
        const label: []const u8 = if (s.which == 0) "walk (tap for the get-up)" else "get-up (tap for the walk)";
        if (u.button(label, .{})) {
            s.which = 1 - s.which;
            s.falls = 0;
            s.last_run = 0.0;
            s.best_run = 0.0;
            restart(s);
        }
        u.text("frame {d} of {d}", .{ s.frame, s.clips[s.which].frame_count });
        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("reference", &s.show_reference);
        u.sameLine(.{});
        if (u.button("restart", .{})) {
            restart(s);
        }
        _ = u.checkbox("reset on fall", &s.reset_on_fall);
        if (u.checkbox("hold T-pose", &s.hold_pose)) {
            restart(s);
        }
        u.sameLine(.{});
        if (u.slider("knee bend", &s.knee_bend, .{ .min = 0.0, .max = 60.0, .fmt = "{d:.0}" })) {
            bendKnees(s);
            if (s.hold_pose) {
                restart(s);
            }
        }
        if (u.slider("lean back", &s.lean_back, .{ .min = -15.0, .max = 15.0, .fmt = "{d:.1}" })) {
            bendKnees(s);
            if (s.hold_pose) {
                restart(s);
            }
        }
        _ = u.checkbox("camera follows", &s.follow_camera);
        _ = u.slider("balance reflex", &s.reflex_gain, .{ .min = 0.0, .max = 8.0, .fmt = "{d:.1}" });
        _ = u.slider("stiffness Hz", &s.frequency, .{ .min = 2.0, .max = 60.0, .fmt = "{d:.0}" });
        _ = u.slider("accel cap", &s.max_acceleration, .{ .min = 100.0, .max = 10000.0, .fmt = "{d:.0}" });
        // Live: every contact reads the floor's friction as it is made.
        if (u.slider("floor friction", &s.floor_friction, .{ .min = 0.1, .max = 8.0, .fmt = "{d:.1}" })) {
            s.world.bodies.data[s.floor.index()].friction = s.floor_friction;
        }
        u.text("standing {d:.1} s   hips {d:.2} m off", .{ float(s.up_frames) * frame_time, s.off });
        u.text("falls {d}   last run {d:.1} s   best {d:.1} s", .{ s.falls, s.last_run, s.best_run });
        u.text("physics + servo {d:.2} ms a step ({d:.0}% of 60 fps)", .{
            s.step_ms,
            100.0 * s.step_ms / (1000.0 * frame_time),
        });
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Geno, servoing a copied clip",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
