//! friction_slope — does the engine's friction match Coulomb's law?
//!
//! ── ★★★ A DEMO WITH A CLOSED-FORM ANSWER ──
//!
//! A body resting on a slope holds when **tan(θ) < μ** and slides beyond. That is not a
//! judgement call or a tuning target; it is a line on the chart, and the engine either lands on
//! it or does not. The predicted threshold is drawn as a marker on the angle slider, so the
//! question "is the friction right?" is answered by looking at where the sliding starts.
//!
//! ── ★★ WHY THIS EXISTS ──
//!
//! `examples/quadruped` slides about a metre in twenty seconds while standing perfectly still,
//! with the measured tangential demand at only **0.20 of the friction cone** — the feet creep
//! with four fifths of the grip unused. That says the sliding is not Coulomb slip. But it does
//! not say whether the Coulomb LIMIT is right, and those are different faults with different
//! fixes:
//!
//!   * **the limit is wrong** → the robot would slip at angles well below `atan(μ)`;
//!   * **the limit is right and the solver creeps** → it holds to the predicted angle, but drifts
//!     slowly at every angle below it.
//!
//! ★ THE SLOPE SEPARATES THEM, and nothing else measured so far does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const ctl = z.robot_control;
const zp = z.zimrphysics;
const rphys = z.robot_physics;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const ui = z.ui;
const profiler = z.profiler;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const length3 = zm.length3;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;
const pi = zm.pi;
const atanRad = zm.atanRad;

const sim_dt: f32 = 1.0 / 250.0;

const background: Color = .{ .r = 16, .g = 18, .b = 26, .a = 255 };
const slope_colour: Color = .{ .r = 58, .g = 66, .b = 84, .a = 255 };
const robot_colour: Color = .{ .r = 150, .g = 200, .b = 190, .a = 255 };
const hold_colour: Color = .{ .r = 108, .g = 200, .b = 168, .a = 255 };
const slip_colour: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    act: ctl.Actuation,
    home: []f32,
    world: zp.World,
    bridge: rphys.Bridge,
    ground: zp.BodyHandle,

    /// Slope angle in radians, and the friction the contacts are given.
    slope: f32,
    friction: f32,
    /// What the slope and friction were when the run started, so a change restarts cleanly.
    last_slope: f32,
    last_friction: f32,

    start_pos: Vec,
    slid: f32,
    elapsed: f32,
    /// Peak |tangential| / (mu * normal) seen since the reset — the cone occupancy.
    cone_worst: f32,

    running: bool,
    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("go1.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    s.imported = try rmj.build(gpa, &s.robot, .{
        .max_contacts = 64,
        .timestep = sim_dt,
        .gravity = vec(0, 0, -9.81),
    });
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    s.act = try ctl.Actuation.init(gpa, &s.imported.model);

    s.world = try .init(gpa, 256);
    s.world.gravity = vec(0, 0, -9.81);
    const shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(8, 8, 0.5), .convex_radius = 0.01 },
    });
    s.ground = try s.world.createBody(.{
        .shape = shape,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });
    s.bridge = try .init(gpa, &s.world, &s.imported.model, &s.data, 256);
    s.bridge.listen(&s.world);

    s.home = try gpa.alloc(f32, s.imported.model.nq);
    s.slope = 0.0;
    s.friction = 0.6;
    s.last_slope = -1;
    s.last_friction = -1;
    s.start_pos = vec(0, 0, 0);
    s.slid = 0;
    s.elapsed = 0;
    s.cone_worst = 0;
    s.running = true;

    s.cam = z.OrbitCamera.init(vec(0, 0.3, 0), 3.4);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 12, 10);
    s.transform = .{identity()};
    restart(s);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    gpa.free(s.home);
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.act.deinit();
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

fn restart(s: *State) void {
    const m: *rbt.Model = &s.imported.model;

    // ── ★ THE SLOPE IS THE GROUND ROTATED, NOT GRAVITY TILTED ──
    //
    // Tilting gravity would give the same free-body diagram and a much easier contact problem:
    // the normal would stay aligned with the box's face. Rotating the GROUND is the honest
    // version, because it exercises the same oblique contact normals a real slope produces.
    var body: *zp.Body = &s.world.bodies.data[s.ground.index()];
    body.rot = zm.quatFromAxisAngle(vec(0, 1, 0), s.slope);
    body.com_pos = zm.rotate(body.rot, vec(0, 0, -0.5));

    // ★ FRICTION ON THE GROUND BODY. Contact friction combines the two bodies' values, so the
    // slider has to move one of them and the robot's feet keep theirs — which is what a real
    // surface change looks like.
    body.friction = s.friction;

    for (s.robot.keyframes) |key| {
        if (std.mem.eql(u8, key.name, "home")) {
            if (!rmj.applyKeyframe(m, &s.data, key)) {
                std.log.err("friction_slope: home keyframe refused", .{});
            }
        }
    }
    // Sit the robot ON the slope: rotate its base to match and lift it clear.
    const tilt: zm.Quat = zm.quatFromAxisAngle(vec(0, 1, 0), s.slope);
    s.data.pos[3] = tilt[0];
    s.data.pos[4] = tilt[1];
    s.data.pos[5] = tilt[2];
    s.data.pos[6] = tilt[3];
    s.data.pos[2] = 0.30 + 0.25 * @sin(@abs(s.slope));
    @memset(s.data.vel, 0);
    @memset(s.data.applied_force, 0);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
    @memcpy(s.home, s.data.pos[0..m.nq]);
    s.bridge.teleported();

    s.start_pos = s.data.body_xpos[1];
    s.slid = 0;
    s.elapsed = 0;
    s.cone_worst = 0;
    s.last_slope = s.slope;
    s.last_friction = s.friction;
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    const was_frozen: bool = profiler.isFrozen();
    profiler.freeze();
    defer if (!was_frozen) profiler.unfreeze();

    if (s.slope != s.last_slope or s.friction != s.last_friction) {
        restart(s);
    }

    if (s.running) {
        const m: *rbt.Model = &s.imported.model;
        var step: u32 = 0;
        while (step < 4) : (step += 1) {
            (ctl.PoseHold{
                .target = s.home,
                .kp = 100,
                .kv = 6,
                .max_torque = 35,
            }).apply(m, &s.data, s.act);
            rbt.forward(m, &s.data);
            s.bridge.sync(&s.world, m, &s.data) catch {};
            zp.step(&s.world, sim_dt) catch {};
            s.bridge.harvest(&s.data);
            rbt.step(m, &s.data);
            s.elapsed += sim_dt;

            // ★★ CONE OCCUPANCY, the number that separates "the limit is wrong" from "the solver
            // creeps". A body sliding at 0.2 of its cone is not being held back by friction.
            for (0..s.data.contact_count) |c| {
                const base: usize = c * rbt.rows_per_contact;
                var normal: f32 = 0;
                for (0..rbt.rows_per_contact) |r| {
                    normal += s.data.constraint_force[base + r];
                }
                if (normal < 1.0) {
                    continue;
                }
                const t1: f32 = s.data.constraint_force[base] - s.data.constraint_force[base + 1];
                const t2: f32 = s.data.constraint_force[base + 2] - s.data.constraint_force[base + 3];
                const tang: f32 = @sqrt(t1 * t1 + t2 * t2);
                const mu: f32 = @max(0.01, s.data.contacts[c].friction[0]);
                s.cone_worst = @max(s.cone_worst, tang / (mu * normal));
            }
        }
        rbt.forward(m, &s.data);
        s.slid = length3(s.data.body_xpos[1] - s.start_pos);
    }

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.6, .max_distance = 12.0 });
    z.beginMode3D(gl, cam);
    drawScene(s, gl);
    z.endMode3D(gl);
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;

    // The slope, drawn from the same rotation the solver is using.
    const body: *const zp.Body = &s.world.bodies.data[s.ground.index()];
    const centre: Vec = zm.zUpToYUpPoint(body.com_pos);
    s.transform[0] = mulMat(
        // ── ★★★ THE RENDER AXIS IS DERIVED, NOT GUESSED ──
        //
        // The solver tilts the ground about **Y in its Z-up frame**:
        //
        //     x' =  x·cosθ + z·sinθ
        //     z' = -x·sinθ + z·cosθ
        //
        // The render swizzle is `(x,y,z)_zup -> (x,z,y)_yup`, so substituting:
        //
        //     x_r' =  x_r·cosθ + y_r·sinθ
        //     y_r' = -x_r·sinθ + y_r·cosθ
        //     z_r' =  z_r
        //
        // ★ THAT IS A ROTATION IN THE RENDER x–y PLANE — **about render Z**, not X. I guessed X
        // and the ground drew tilted the wrong way while the robot, whose base quaternion is set
        // in solver space, banked correctly. **The robot was right and the floor was wrong**,
        // which reads as the robot leaning the wrong way.
        //
        // ★★ AND THE SIGN FOLLOWS THE SAME WAY: `rotationZ(φ)` gives `x' = x·cosφ - y·sinφ`, so
        // matching the substitution above needs `φ = -θ`. A frame conversion is two lines of
        // algebra; guessing it is two turns of looking at pictures.
        mulMat(zm.rotationZ(-s.slope), scaling(16, 1, 16)),
        translation(centre[0], centre[1], centre[2]),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, slope_colour);

    for (1..m.nbody) |b| {
        const at: Vec = zm.zUpToYUpPoint(s.data.body_xpos[b]);
        const parent: u32 = m.body_parent[b];
        if (parent != rbt.world_body) {
            z.drawLine3D(gl, zm.zUpToYUpPoint(s.data.body_xpos[parent]), at, robot_colour);
        }
        s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(0.05, 0.05, 0.05));
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, robot_colour);
    }

    // ★ WHERE IT STARTED, so the slide is visible rather than only reported.
    const from: Vec = zm.zUpToYUpPoint(s.start_pos);
    const now: Vec = zm.zUpToYUpPoint(s.data.body_xpos[1]);
    const holding: bool = s.slid < 0.05;
    z.drawLine3D(gl, from, now, if (holding) hold_colour else slip_colour);
    s.transform[0] = mulMat(translation(from[0], from[1], from[2]), scaling(0.05, 0.05, 0.05));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, if (holding) hold_colour else slip_colour);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const panel_w: f32 = @min(380.0, viewport_w - 16);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("does friction obey Coulomb?", .{ .flags = .{ .always_auto_resize = true } })) |w| {
        defer w.close();

        var degrees: f32 = s.slope * 180.0 / pi;
        if (u.slider("slope deg", &degrees, .{ .min = 0, .max = 45, .fmt = "{d:.1}" })) {
            s.slope = degrees * pi / 180.0;
        }
        _ = u.slider("friction mu", &s.friction, .{ .min = 0.05, .max = 1.5, .fmt = "{d:.2}" });

        // ── ★★★ THE PREDICTION, STATED BEFORE THE RESULT ──
        //
        // Coulomb says a resting body holds while tan(θ) < μ. That threshold is arithmetic, not
        // opinion, so the demo can mark it and let the engine be judged against it.
        const threshold: f32 = atanRad(s.friction) * 180.0 / pi;
        u.separator();
        u.text("Coulomb says: holds below {d:.1} deg", .{threshold});
        u.text("  tan(slope) {d:.3}  vs  mu {d:.2}", .{ @tan(s.slope), s.friction });
        if (degrees < threshold - 1.0) {
            u.text("  -> should HOLD", .{});
        } else if (degrees > threshold + 1.0) {
            u.text("  -> should SLIDE", .{});
        } else {
            u.text("  -> right at the threshold", .{});
        }

        u.separator();
        u.text("after {d:.1} s:  slid {d:.4} m", .{ s.elapsed, s.slid });
        u.text("  peak cone occupancy {d:.2}", .{s.cone_worst});
        // ★★ THE DIAGNOSIS THE DEMO EXISTS TO MAKE. Sliding while the cone is far from full means
        // friction is not what is failing — the solver is letting contacts drift inside their
        // own limit. Sliding WITH a full cone is ordinary Coulomb slip and entirely correct.
        if (s.slid > 0.05 and s.cone_worst < 0.8 and degrees < threshold - 1.0) {
            u.text("  SLIDING BELOW THE THRESHOLD, cone not full:", .{});
            u.text("  the limit is fine, the solver is creeping.", .{});
        }
        if (u.button("restart", .{})) {
            restart(s);
        }
        _ = u.checkbox("run", &s.running);
    }

    u.setNextWindowPos(.{ 8, viewport_h - 72 }, .{});
    u.setNextWindowSize(.{ viewport_w - 16, 64 }, .{});
    if (u.window("slope_help", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_inputs = true,
        .no_scrollbar = true,
    } })) |h| {
        defer h.close();
        u.text("green marker = where it started.  line = how far it moved.", .{});
        u.text("raise the slope past the predicted angle: it should let go there,", .{});
        u.text("and hold below it. anything else is the engine, not the robot.", .{});
    }
    return captured;
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - does friction obey Coulomb?",
            .width = 900,
            .height = 620,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
