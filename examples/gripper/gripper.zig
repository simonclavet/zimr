//! gripper — a 4-DOF arm with a geared two-finger gripper, driven by inverse kinematics.
//!
//! ── ★ WHAT THIS DEMONSTRATES ──
//!
//!   * an `<equality type="joint">` COUPLING: one slider moves the left finger, and the right
//!     mirrors it through a constraint the solver enforces — not through code that sets two
//!     numbers. That is what a real parallel gripper is;
//!   * damped-least-squares IK placing the grasp point wherever you put it, on a redundant
//!     arm, once per frame;
//!   * gains in FREQUENCY units. This arm's wrist has a mass-matrix diagonal of 0.00041
//!     against 0.13 at its shoulder, and a `kp` that suits one destroys the other — see
//!     `PoseHold.scale_by_inertia`.
//!
//! ── ★★ WHY IT IS HAND-DRIVEN AND NOT A SCRIPTED PICK-AND-PLACE ──
//!
//! **Inverse kinematics is collision-blind**, here and in MuJoCo. It will happily return a
//! pose that folds the arm through its own base or through the table, reporting a
//! sub-millimetre error for a configuration the robot cannot occupy. Measured: five targets in
//! free space reached to under a millimetre with zero contacts; the same solver aiming at a
//! cube on a table put the forearm INTO the table.
//!
//! Choosing waypoints around an obstacle is a planning problem this engine does not claim to
//! solve. So the human does it — which is not a consolation prize, because watching the arm
//! track a target you drag around is a better demonstration of the IK than any fixed sequence.
//!
//! ── ★★ THE THING TO TRY ──
//!
//! Move the target down and toward the base. The arm follows until it cannot, and `reach err`
//! climbs — that is the solver telling you the truth about a pose it found but the robot
//! cannot hold.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const zp = z.zimrphysics;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const bridge_mod = z.robot_physics;
const ctl = z.robot_control;
const Color = zm.Color;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const splat = zm.splat;
const ui = z.ui;
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const quatToMat = zm.quatToMat;
const identity = zm.identity;

/// The Go1 runs at 500 Hz in Menagerie, and its contacts want it.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const timestep: f32 = 1.0 / 500.0;

/// How many projectiles the scene carries.
///
/// ── ★★ A FIXED POOL, RECYCLED, RATHER THAN SPAWNED ON DEMAND ──
///
/// A ball has to be a body in the ROBOT'S OWN TREE to hit it properly (§4k) — that is the
/// whole point of the unified tree, and it is what makes the impact push back on the legs
/// with the right mass. But a tree is built once: adding a body means rebuilding the model,
/// which throws away the robot's state mid-flight.
///
/// So the balls exist from the start, parked below the floor where nothing can reach them,
/// and a throw teleports one into place with a velocity. Recycling the oldest means the
/// scene never grows and a rapid-fire user cannot exhaust it.
/// Where an unthrown ball waits: far below the floor, spread out so two never overlap.
///
/// ★ THEY ARE STILL SIMULATED DOWN THERE, and that is fine — nothing is near them, so they
/// contribute no contacts and cost only their six DOFs in the mass matrix. Parking beats
/// deleting because a tree cannot gain a body without being rebuilt, and rebuilding mid-throw
/// would discard the robot's state.
/// Where the fingers meet, in the wrist's frame.
///
/// ★ NOT THE WRIST'S ORIGIN. The jaws hang from it spanning 0.010..0.100, so the point a
/// grasped object's centre belongs at is halfway down them. Aiming the origin instead puts the
/// object 5 cm above the fingers and everything after looks like an IK failure.
const grasp_offset: Vec = vec(0, 0, 0.055);

const cube_half: f32 = 0.020;
/// ★ THE TABLE CLEARS THE ARM. A first attempt spanned x from 0.10 — straight through the
/// forearm's rest position at x = 0.163 — so the arm started embedded in the furniture and the
/// cube was fired across the room. Obstacles are placed against the robot's ACTUAL rest pose.
const table_center: Vec = vec(0.45, 0, 0.40);
const table_half: Vec = vec(0.15, 0.20, 0.05);

const bg: Color = .{ .r = 16, .g = 15, .b = 20, .a = 255 };
const link_col: Color = .{ .r = 90, .g = 185, .b = 175, .a = 255 };
const finger_col: Color = .{ .r = 225, .g = 130, .b = 70, .a = 255 };
const cube_col: Color = .{ .r = 220, .g = 200, .b = 90, .a = 255 };
const table_col: Color = .{ .r = 70, .g = 66, .b = 72, .a = 255 };
/// Straight down: the wrist's local +z onto the world's −z.
const jaws_down: zm.Quat = zm.quatFromAxisAngle(vec(0, 1, 0), pi);

const target_col: Color = .{ .r = 250, .g = 240, .b = 120, .a = 255 };

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    world: zp.World,
    bridge: bridge_mod.Bridge,
    actuated: ctl.Actuation,
    cam: z.OrbitCamera,
    ui_host: z.UiHost,
    font: z.Font,
    cylinder: z.Mesh,
    sphere: z.Mesh,
    cube: z.Mesh,
    transform: [1]Mat,
    accumulator: f32,

    /// What the PD tracks. IK writes joint angles here; nothing else does.
    home: []f32,
    /// Scratch so the IK solve can run on a copy — see `solveReach`.
    pose_scratch: []f32,
    ik_scratch: []Vec,
    wrist: u32,
    cube_body: u32,
    left_finger_q: u32,

    target: Vec,
    reach_error: f32,
    grip: f32,
    physics_on: bool,
    /// Whether to constrain the wrist's attitude as well as its position.
    aim_down: bool,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("arm.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    const cube_body = [_]z.robot_scene.FreeBody{.{
        .name = "cube",
        .pos = vec(table_center[0], 0, table_center[2] + table_half[2] + cube_half),
        .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = splat(cube_half) } }, .mass = 0.08 }},
    }};
    s.imported = try rmj.buildScene(gpa, &s.robot, &cube_body, .{
        .max_contacts = 64,
        .timestep = timestep,
        .gravity = vec(0, 0, -9.81),
    });
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    s.actuated = try ctl.Actuation.init(gpa, &s.imported.model);

    s.world = try zp.World.init(gpa, 64);
    s.world.gravity = vec(0, 0, -9.81);
    const table_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = table_half, .convex_radius = 0.01 },
    });
    _ = try s.world.createBody(.{ .shape = table_shape, .position = table_center, .motion_type = .static });
    const floor_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(3, 3, 0.5), .convex_radius = 0.01 },
    });
    _ = try s.world.createBody(.{ .shape = floor_shape, .position = vec(0, 0, -0.5), .motion_type = .static });

    // ★ THE READY POSE, and it is not decoration. Every joint at zero stands the arm straight
    // up, which is SINGULAR: the Jacobian has no preferred direction, so the first IK call
    // picks one arbitrarily. Measured from zero, a goal at (0.30, 0, 0.05) ended at
    // (−0.50, 0, 0.45) — the opposite side of the robot.
    _ = rmj.applyKeyframe(&s.imported.model, &s.data, s.robot.keyframes[0]);
    rbt.forward(&s.imported.model, &s.data);

    s.bridge = try bridge_mod.Bridge.init(gpa, &s.world, &s.imported.model, &s.data, 64);
    s.bridge.listen(&s.world);

    s.home = try gpa.dupe(f32, s.data.pos);
    s.pose_scratch = try gpa.alloc(f32, s.imported.model.nq);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.imported.model));
    s.wrist = s.imported.bodyIndex("wrist").?;
    s.cube_body = s.imported.bodyIndex("cube").?;
    s.left_finger_q = blk: {
        for (0..s.imported.model.njnt) |j| {
            if (s.imported.model.jnt_type[j] == .slide) {
                break :blk s.imported.model.jnt_qpos_adr[j];
            }
        }
        break :blk 0;
    };

    // Start the target where the grasp point already is, so nothing lurches on frame one.
    s.target = s.data.body_xpos[s.wrist] + zm.rotate(s.data.body_xrot[s.wrist], grasp_offset);
    s.reach_error = 0;
    s.grip = 0;
    s.physics_on = true;
    s.aim_down = true;
    s.accumulator = 0;

    // ★ THE ORBIT TARGET IS THE TABLE, not the origin: the interesting half of this scene is
    // 45 cm up, and a camera aimed at the floor spends its range looking at the pedestal.
    s.cam = z.OrbitCamera.init(vec(0, 0.45, 0.25), 1.5);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.ik_scratch);
    gpa.free(s.pose_scratch);
    gpa.free(s.home);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.actuated.deinit();
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

/// Point the grasp at `s.target`, and write the result where the controller will read it.
///
/// ── ★ THE SOLVE RUNS ON A COPY ──
///
/// `Ik.solve` writes joint angles into `data` — that IS its answer. Doing it to the live state
/// would teleport the arm every frame: no dynamics, no contact, nothing to resist. The result
/// becomes a TARGET instead, so the arm travels there under its own torque limits and can
/// visibly fail to arrive.
fn solveReach(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    @memcpy(s.pose_scratch, s.data.pos);
    const result: ctl.Ik.Result = (ctl.Ik{ .max_iterations = 40 }).solve(
        m,
        &s.data,
        s.actuated,
        .{
            .body = s.wrist,
            .offset = grasp_offset,
            .goal = s.target,
            // ★ JAWS DOWN, WHICH A POSITION TARGET CANNOT ASK FOR. Without this the wrist's
            // attitude is whatever the solver's nullspace drifted into — on this arm, sideways
            // — and a top grasp is not expressible however the target position is moved.
            .orientation = if (s.aim_down) jaws_down else null,
        },
        s.ik_scratch,
    );
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        s.home[q] = s.data.pos[q];
    }
    @memcpy(s.data.pos, s.pose_scratch);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
    s.reach_error = result.error_distance;
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const m: *const rbt.Model = &s.imported.model;

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    // ★ IK RUNS ONCE PER FRAME, NOT PER SUBSTEP. It answers "where should the joints be",
    // which changes only when the target moves; inside the fixed-timestep loop it would
    // recompute the same answer several times over and the cost would multiply.
    solveReach(s);

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        rbt.forward(m, &s.data);
        if (s.physics_on) {
            // These two can only fail by running out of memory: the frame callback that contains them
            // returns `void` by the engine's design, so there is nothing to propagate to. Swallowing
            // leaves the world un-stepped for one frame, which is the least-bad outcome available here -
            // and is why the rule wants it said out loud rather than written silently.
            // lint:off catch-suppression: OOM only, void callback - see above
            s.bridge.sync(&s.world, m, &s.data) catch {};
            // lint:off catch-suppression: OOM only, void callback - see above
            zp.step(&s.world, timestep) catch {};
            s.bridge.harvest(&s.data);
        } else {
            s.data.clearContacts();
        }
        // ★ GAINS IN FREQUENCY UNITS: `kp` is ω² and `kv` is 2ζω. This arm's links differ by
        // three orders of magnitude in inertia — 0.13 at the shoulder, 0.00041 at the wrist —
        // and a single torque-unit gain cannot serve both. Measured at kp = 600 unscaled, the
        // wrist DIVERGED to the velocity clamp while its position sat still, which reads as a
        // stuck joint rather than a broken controller.
        (ctl.PoseHold{
            .target = s.home,
            .kp = 2500,
            .kv = 100,
            .max_torque = 300,
            .scale_by_inertia = true,
        }).apply(m, &s.data, s.actuated);
        // The gripper is commanded directly; the coupling moves the other finger.
        s.home[s.left_finger_q] = -s.grip;
        rbt.step(m, &s.data);
    }
    rbt.forward(m, &s.data);

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 0.5, .max_distance = 4.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 16, 0.25);
    drawScene(s, gl);
    z.endMode3D(gl);
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();

    // The table, which is world geometry rather than part of the tree.
    s.transform[0] = mulMat(
        mulMat(to_y_up, translation(table_center[0], table_center[1], table_center[2])),
        scaling(2 * table_half[0], 2 * table_half[1], 2 * table_half[2]),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, table_col);

    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: zm.Quat = s.data.body_xrot[body];
        const world_pos: Vec = s.data.body_xpos[body] + zm.rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(zm.qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(
            mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])),
            world_rot,
        );
        const tint: Color = if (body == s.cube_body)
            cube_col
        else if (body >= s.wrist)
            finger_col
        else
            link_col;
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .capsule => |cap| {
                // ★ THE GENERATED CYLINDER SPANS [0, h] ALONG Y, not centred on the origin and
                // not along Z — measured from the mesh's own bounds rather than read off the
                // generator, which remaps as it writes.
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cap.half_height, 0)),
                    scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            .cylinder => |cyl| {
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cyl.half_height, 0)),
                    scaling(cyl.radius, 2.0 * cyl.half_height, cyl.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            .box => |b| {
                s.transform[0] = mulMat(place, scaling(
                    2 * b.half_extent[0],
                    2 * b.half_extent[1],
                    2 * b.half_extent[2],
                ));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            else => {},
        }
    }

    // The target, so the thing being tracked is visible alongside what is tracking it.
    s.transform[0] = mulMat(
        mulMat(to_y_up, translation(s.target[0], s.target[1], s.target[2])),
        scaling(0.016, 0.016, 0.016),
    );
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, target_col);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    // Sized to the viewport rather than to pixels — see `ui.Ui.scaleToViewport`.
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(400.0, viewport_w * 0.32);
    _ = u.scaleToViewport(panel_w, if (narrow) 30.0 else 22.0);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    // Height capped to the viewport: auto-size lets the window run off a short screen.
    u.setNextWindowSize(.{ panel_w, @min(470.0, viewport_h * 0.7) }, .{});
    if (u.window("4-DOF arm with a geared gripper", .{})) |window| {
        defer window.close();
        u.text("IK target (metres)", .{});
        _ = u.slider("x", &s.target[0], .{ .min = 0.10, .max = 0.60, .fmt = "{d:.3}" });
        _ = u.slider("y", &s.target[1], .{ .min = -0.40, .max = 0.40, .fmt = "{d:.3}" });
        _ = u.slider("z", &s.target[2], .{ .min = 0.20, .max = 0.75, .fmt = "{d:.3}" });
        u.text("   reach err {d:.4} m", .{s.reach_error});
        // ★ TURN THIS OFF AND WATCH THE WRIST WANDER. Position targets say nothing about
        // attitude, so the jaws end up wherever the nullspace leaves them — which is exactly
        // why an orientation target had to exist.
        _ = u.checkbox("aim the jaws down", &s.aim_down);
        u.separator();

        // ★★ ONE SLIDER, TWO FINGERS. The right one is not set here — an
        // `<equality type="joint" polycoef="0 -1">` ties it to the left, and the SOLVER moves
        // it. That is what a parallel gripper physically is, and modelling it as two joints a
        // controller keeps in sync is how a gripper ends up gripping crooked.
        u.text("gripper (one motor, coupled)", .{});
        _ = u.slider("close", &s.grip, .{ .min = -0.010, .max = 0.020, .fmt = "{d:.3}" });
        u.text("   left {d:>6.3}  right {d:>6.3}", .{
            s.data.pos[s.left_finger_q],
            s.data.pos[s.left_finger_q + 1],
        });
        u.separator();

        _ = u.checkbox("physics", &s.physics_on);
        if (u.button("reset", .{})) {
            resetScene(s);
        }
        u.text("contacts {d}", .{s.data.contact_count});
    }
    return captured;
}

/// Put the arm and the cube back where they started.
///
/// ★ EVERYTHING THAT REMEMBERS, or the button appears to do nothing: `home` is what the
/// controller tracks, so restoring `pos` alone lets it drag the arm straight back. Velocities
/// go too — a reset mid-swing keeps its momentum — and so does the solver's warm start.
fn resetScene(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    _ = rmj.applyKeyframe(m, &s.data, s.robot.keyframes[0]);
    const cube_joint: u32 = m.jnt_qpos_adr[m.body_jnt_adr[s.cube_body]];
    s.data.pos[cube_joint + 0] = table_center[0];
    s.data.pos[cube_joint + 1] = 0;
    s.data.pos[cube_joint + 2] = table_center[2] + table_half[2] + cube_half;
    s.data.pos[cube_joint + 3] = 0;
    s.data.pos[cube_joint + 4] = 0;
    s.data.pos[cube_joint + 5] = 0;
    s.data.pos[cube_joint + 6] = 1;
    @memset(s.data.vel, 0);
    @memset(s.data.acc, 0);
    s.data.clearContacts();
    s.data.forgetWarmStart();
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
    @memcpy(s.home, s.data.pos);
    s.grip = 0;
    s.accumulator = 0;
    s.target = s.data.body_xpos[s.wrist] + zm.rotate(s.data.body_xrot[s.wrist], grasp_offset);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - arm and coupled gripper",
            .width = 820,
            .height = 680,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
