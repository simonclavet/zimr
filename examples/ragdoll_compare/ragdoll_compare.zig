//! ragdoll_compare — one humanoid, two engines.
//!
//! MuJoCo's humanoid, limp, dropped twice onto the same floor from the same tipped squat:
//!
//!   ORANGE, left:  REDUCED coordinates, `robot.zig`. Twenty-seven numbers, and the joints ARE
//!                  the coordinates, so they cannot come apart. Contacts come from zimrphysics
//!                  through `robot_physics.Bridge`, one kinematic proxy per geom.
//!   BLUE, right:   MAXIMAL coordinates, `zimrphysics`. Thirteen rigid bodies and twelve joints
//!                  that a solver holds together every step, built by `robot_maximal`.
//!
//! Same geoms, same masses and inertias (tested equal to 1e-7), same 1/500 s timestep, same
//! floor. Each engine steps in its own world, so every microsecond on a readout belongs to one
//! engine — and the reduced side's include its collision detection, because it needs some.
//!
//! ── WHAT TO LOOK AT ──
//!
//!   * **joint gap** — how far the maximal ragdoll's joints have opened. The reduced one has
//!     nothing to open.
//!   * **the limit buttons.** With ALL limits the maximal ragdoll never quite settles; with
//!     hinge limits only it does; with none it settles perfectly. That is Stage 0's measured
//!     finding (`src/notes/ragdoll_compare_plan.md`), shown here rather than described.
//!   * **µs per step** for each engine, averaged over half a second, because a browser's clock
//!     is too coarse to time one step.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const common = @import("example_common");
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const zp = z.zimrphysics;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const rmx = z.robot_maximal;
const bridge_mod = z.robot_physics;
const ui = z.ui;

const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const rotate = zm.rotate;
const qmul = zm.qmul;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const quatToMat = zm.quatToMat;
const identity = zm.identity;
const normalize3 = zm.normalize3;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const zUpToYUp = zm.zUpToYUp;
const assertUnreachable = zm.assertUnreachable;
const float64 = zm.float64;
const float = zm.float;
const bufPrint = std.fmt.bufPrint;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The two physics rates on offer: the comparison's 500 Hz, and one step per 60 Hz frame.
const rates = [_]u32{ 500, 60 };
/// Steps one frame may take. Past this the simulation runs slow instead of spiralling: a frame
/// that owes more steps takes longer, and owes more still.
const max_steps_per_frame: u32 = 40;
/// Each ragdoll lives at the origin of its own world; they are drawn this far either side.
const side_offset: f32 = 0.8;
/// How long the step timers accumulate before a readout updates, in seconds.
const timing_window: f32 = 0.5;
/// "Hold the squat". Reduced: IMPLICIT computed torque through floating-base inverse dynamics
/// (`rmx.stableSpringAccel`, `rmx.floatingBaseTorques`) — stable at any stiffness and any rate;
/// at 60 Hz, falling onto the floor, 20 Hz held the squat to 7 degrees. Maximal: joint motors
/// at 10 Hz, the stiffest that reached the squat on a fixed base without fighting its limits
/// into a blow-up (ragdoll_compare_plan.md §9) — and, free and on the floor, they do NOT yet
/// hold it at either rate. That is the finding, not a bug in this page.
const hold_frequency_reduced: f32 = 20.0;
const hold_frequency_maximal: f32 = 10.0;

const bg: Color = .{ .r = 18, .g = 14, .b = 16, .a = 255 };
const reduced_col: Color = .{ .r = 240, .g = 150, .b = 70, .a = 255 };
const maximal_col: Color = .{ .r = 90, .g = 170, .b = 240, .a = 255 };

/// Which joint limits the maximal ragdoll carries. The reduced one always has all of its own.
const LimitMode = enum { all, hinges_only, none };

/// Wall time one engine spent stepping, and the average it produced last window.
const Timer = struct {
    ms: f64 = 0,
    steps: u32 = 0,
    us_per_step: f64 = 0,

    fn roll(self: *Timer) void {
        if (self.steps > 0) {
            self.us_per_step = self.ms * 1000.0 / float64(self.steps);
        }
        self.ms = 0;
        self.steps = 0;
    }
};

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    world_reduced: zp.World,
    bridge: bridge_mod.Bridge,
    world_maximal: zp.World,
    ragdoll: rmx.Ragdoll,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cylinder: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
    limit_mode: LimitMode,
    paused: bool,
    want_reset: bool,
    accumulator: f32,
    sim_time: f32,
    window_time: f32,
    reduced_timer: Timer,
    maximal_timer: Timer,
    joint_gap_peak: f32,
    /// The pose "hold the squat" drives toward, as the reduced model's forward kinematics.
    target: rbt.Data,
    a_des: []f32,
    torque: []f32,
    full_accel: []f32,
    dense_mass: []f32,
    hold_pose: bool,
    motors_on: bool,
    /// Steps per second, one of `rates`; changing it rebuilds both worlds.
    rate_hz: u32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("humanoid.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    // Newton, because a limp body is the coupled-contact regime where PGS keeps twitching
    // (`robot_physics`' ragdoll test measured it). Z-up, because MJCF is.
    var options: rbt.Options = .{
        .max_contacts = 256,
        .timestep = 1.0 / float(rates[0]), // `buildWorlds` sets the chosen rate on every build
        .gravity = vec(0, 0, -9.81),
    };
    options.solver.algorithm = .newton;
    options.solver.max_iterations = 100;
    s.imported = try rmj.build(gpa, &s.robot, options);
    // Limp on both sides: the maximal ragdoll has no springs, damping or armature to match.
    rmx.limpReduced(&s.imported.model);
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cam = z.OrbitCamera.init(vec(0, 0.3, 0), 3.4);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.transform = .{identity()};
    s.limit_mode = .all;
    s.paused = false;
    s.want_reset = false;
    s.target = try rbt.Data.init(gpa, &s.imported.model);
    @memcpy(s.target.pos, s.imported.model.qpos0);
    _ = rmj.applyKeyframe(&s.imported.model, &s.target, s.robot.keyframes[0]);
    s.target.stage = .stale;
    rbt.forward(&s.imported.model, &s.target);
    const nv: usize = s.imported.model.nv;
    s.a_des = try gpa.alloc(f32, nv);
    s.torque = try gpa.alloc(f32, nv);
    s.full_accel = try gpa.alloc(f32, nv);
    s.dense_mass = try gpa.alloc(f32, nv * nv);
    s.hold_pose = false;
    s.motors_on = false;
    s.rate_hz = rates[0];
    try buildWorlds(gpa, s);
}

fn deinit(gpa: Allocator, s: *State) void {
    destroyWorlds(gpa, s);
    gpa.free(s.a_des);
    gpa.free(s.torque);
    gpa.free(s.full_accel);
    gpa.free(s.dense_mass);
    s.target.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

/// A static floor, the same in both worlds.
fn floorWorld(gpa: Allocator) !zp.World {
    var world: zp.World = try .init(gpa, 256);
    errdefer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    // Timing is compared, so neither side gets to skip work by sleeping.
    world.settings.allow_sleeping = false;
    world.settings.penetration_slop = 0.005;
    const ground: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(6, 6, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
        .friction = 0.7,
    });
    return world;
}

/// Build both worlds and drop both ragdolls from the same pose.
fn buildWorlds(gpa: Allocator, s: *State) !void {
    const m: *rbt.Model = &s.imported.model;
    m.opt.timestep = 1.0 / float(s.rate_hz);
    // The maximal ragdoll is built at qpos0: its joint limits are measured from there.
    @memcpy(s.data.pos, m.qpos0);
    @memset(s.data.vel, 0);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
    s.world_maximal = try floorWorld(gpa);
    s.ragdoll = try rmx.build(gpa, &s.world_maximal, m, &s.data, .{
        .limits = s.limit_mode != .none,
        .swing_twist_limits = s.limit_mode == .all,
    });

    dropPose(s);
    try s.ragdoll.setPose(gpa, &s.world_maximal, &s.data);
    s.world_reduced = try floorWorld(gpa);
    s.bridge = try .init(gpa, &s.world_reduced, m, &s.data, 256);
    s.bridge.listen(&s.world_reduced);
    // Motors live on the constraints, which were just rebuilt.
    s.motors_on = false;

    s.accumulator = 0;
    s.sim_time = 0;
    s.window_time = 0;
    s.reduced_timer = .{};
    s.maximal_timer = .{};
    s.joint_gap_peak = 0;
}

fn destroyWorlds(gpa: Allocator, s: *State) void {
    s.bridge.deinit(&s.world_reduced);
    s.world_reduced.deinit(gpa);
    s.ragdoll.deinit();
    s.world_maximal.deinit(gpa);
}

/// The model's `squat` keyframe, 1.2 m up and tipped onto its side — the drop `robot_physics`'
/// ragdoll test uses. A body that lands upright makes few contacts and shows little.
fn dropPose(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    _ = rmj.applyKeyframe(m, &s.data, s.robot.keyframes[0]);
    s.data.pos[2] = 1.2;
    const tipped: Quat = quatFromAxisAngle(normalize3(vec(1, 0.3, 0)), 1.4);
    s.data.pos[3] = tipped[0];
    s.data.pos[4] = tipped[1];
    s.data.pos[5] = tipped[2];
    s.data.pos[6] = tipped[3];
    @memset(s.data.vel, 0);
    s.data.stage = .stale;
    rbt.forward(m, &s.data);
}

/// One step of each engine, each timed on its own.
fn stepBoth(s: *State) void {
    const m: *rbt.Model = &s.imported.model;
    const timestep: f32 = m.opt.timestep;
    const start: f64 = z.wgpu.nowMs();
    rbt.forward(m, &s.data);
    s.bridge.sync(&s.world_reduced, m, &s.data) catch |err| {
        assertUnreachable(@src(), "proxy sync failed: {t}", .{err});
    };
    zp.step(&s.world_reduced, timestep) catch |err| {
        assertUnreachable(@src(), "reduced-side collision step failed: {t}", .{err});
    };
    s.bridge.harvest(&s.data);
    @memset(s.data.applied_force, 0);
    if (s.hold_pose) {
        holdTorques(s);
    }
    rbt.step(m, &s.data);
    const reduced_done: f64 = z.wgpu.nowMs();
    zp.step(&s.world_maximal, timestep) catch |err| {
        assertUnreachable(@src(), "maximal step failed: {t}", .{err});
    };
    const maximal_done: f64 = z.wgpu.nowMs();

    s.reduced_timer.ms += reduced_done - start;
    s.reduced_timer.steps += 1;
    s.maximal_timer.ms += maximal_done - reduced_done;
    s.maximal_timer.steps += 1;
    s.sim_time += timestep;
    s.joint_gap_peak = @max(s.joint_gap_peak, s.ragdoll.jointError(&s.world_maximal));
}

/// Torques toward the target pose: each hinge asks for an IMPLICIT critically damped spring's
/// acceleration, and floating-base inverse dynamics turns that into torques with the free root
/// allowed to respond (its rows are zero: it has no actuator). The fixed-base form - the joint
/// rows of M a + c - threw the falling body off at the velocity cap.
fn holdTorques(s: *State) void {
    const m: *const rbt.Model = &s.imported.model;
    @memset(s.a_des, 0);
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] != .hinge) {
            continue;
        }
        const q: u32 = m.jnt_qpos_adr[j];
        const v: u32 = m.jnt_dof_adr[j];
        s.a_des[v] = rmx.stableSpringAccel(
            s.target.pos[q] - s.data.pos[q],
            s.data.vel[v],
            hold_frequency_reduced,
            1.0,
            m.opt.timestep,
        );
    }
    rbt.biasForce(m, &s.data);
    rmx.floatingBaseTorques(m, &s.data, s.a_des, s.dense_mass, s.full_accel, s.torque);
    for (0..m.njnt) |j| {
        if (m.jnt_type[j] == .hinge) {
            const v: u32 = m.jnt_dof_adr[j];
            s.data.applied_force[v] = s.torque[v];
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;

    if (s.want_reset) {
        s.want_reset = false;
        destroyWorlds(s.gpa, s);
        buildWorlds(s.gpa, s) catch |err| {
            assertUnreachable(@src(), "rebuilding the worlds failed: {t}", .{err});
        };
    }

    // The maximal motors are switched, not recomputed: they hold a target inside the solver.
    if (s.hold_pose != s.motors_on) {
        if (s.hold_pose) {
            s.ragdoll.driveToPose(&s.world_maximal, &s.imported.model, &s.target, .{
                .frequency = hold_frequency_maximal,
            });
        } else {
            s.ragdoll.motorsOff(&s.world_maximal);
        }
        s.motors_on = s.hold_pose;
    }

    if (!s.paused) {
        const timestep: f32 = s.imported.model.opt.timestep;
        s.accumulator += @min(f.time.delta_time, 0.1);
        var steps: u32 = 0;
        while (s.accumulator >= timestep and steps < max_steps_per_frame) : (steps += 1) {
            s.accumulator -= timestep;
            stepBoth(s);
        }
        if (steps == max_steps_per_frame) {
            s.accumulator = 0; // behind: run slow rather than owe ever more steps
        }
    }
    s.window_time += f.time.delta_time;
    if (s.window_time >= timing_window) {
        s.window_time = 0;
        s.reduced_timer.roll();
        s.maximal_timer.roll();
    }

    // Built before the clear so the camera knows whether the mouse belongs to the panel, and
    // rendered after it (the deferred `render`) so the clear does not erase it.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 9.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 24, 0.25);
    const m: *const rbt.Model = &s.imported.model;
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        drawGeom(s, gl, g, s.data.body_xpos[body], s.data.body_xrot[body], reduced_col, -side_offset);
        const frame: rmx.Frame = s.ragdoll.robotBodyFrame(&s.world_maximal, body);
        drawGeom(s, gl, g, frame.pos, frame.rot, maximal_col, side_offset);
    }
    z.endMode3D(gl);
}

/// Draw one collision geom at a body pose, shifted sideways by `offset_x` (Z-up metres).
fn drawGeom(
    s: *State,
    gl: *z.WgpuGl,
    g: usize,
    body_pos: Vec,
    body_rot: Quat,
    tint: Color,
    offset_x: f32,
) void {
    const m: *const rbt.Model = &s.imported.model;
    const world_pos: Vec = body_pos + rotate(body_rot, m.geom_pos[g]) + vec(offset_x, 0, 0);
    const world_rot: Mat = quatToMat(qmul(body_rot, m.geom_rot[g]));
    const place: Mat = mulMat(
        mulMat(zUpToYUp(), translation(world_pos[0], world_pos[1], world_pos[2])),
        world_rot,
    );
    switch (m.geom_shape[g]) {
        .sphere => |sph| {
            s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
            z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
        },
        .capsule => |cap| {
            // The cylinder mesh runs along Y over [0, h] (see `humanoid`'s drawRobot), so a
            // half-length shift centres it; two spheres close the ends.
            s.transform[0] = mulMat(
                mulMat(place, translation(0, -cap.half_height, 0)),
                scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
            );
            z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            for ([_]f32{ -1.0, 1.0 }) |end| {
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, end * cap.half_height, 0)),
                    scaling(cap.radius, cap.radius, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            }
        },
        else => {},
    }
}

fn reducedSpeed(s: *const State) f32 {
    var fastest: f32 = 0;
    for (0..s.imported.model.nv) |i| {
        fastest = @max(fastest, @abs(s.data.vel[i]));
    }
    return fastest;
}

fn setRate(s: *State, rate: u32) void {
    if (s.rate_hz != rate) {
        s.rate_hz = rate;
        s.want_reset = true;
    }
}

fn setLimitMode(s: *State, mode: LimitMode) void {
    if (s.limit_mode != mode) {
        s.limit_mode = mode;
        s.want_reset = true;
    }
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(470.0, viewport_w * 0.42);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    // A height cap so a phone gets a scrollbar instead of a panel that runs off the screen.
    u.setNextWindowSize(.{ panel_w, @min(470.0, viewport_h * 0.62) }, .{});
    if (u.window("Ragdolls: reduced vs maximal", .{})) |window| {
        defer window.close();
        u.text("one humanoid, limp; same geoms, masses, floor", .{});
        u.text("{d} steps/s   t = {d:.1} s", .{ s.rate_hz, s.sim_time });
        for (rates) |rate| {
            var label_buf: [16]u8 = undefined;
            const label: []const u8 = bufPrint(&label_buf, "{d} Hz", .{rate}) catch "rate";
            if (u.button(label, .{})) {
                setRate(s, rate);
            }
        }
        u.separator();
        u.text("REDUCED  robot.zig  (orange)", .{});
        u.text("  {d:.0} us/step   speed {d:.2}", .{ s.reduced_timer.us_per_step, reducedSpeed(s) });
        u.text("  contacts {d}   joint gap: none, by construction", .{s.data.contact_count});
        u.separator();
        u.text("MAXIMAL  zimrphysics  (blue)", .{});
        u.text("  {d:.0} us/step   speed {d:.2}", .{
            s.maximal_timer.us_per_step,
            s.ragdoll.peakSpeed(&s.world_maximal),
        });
        u.text("  joint gap {d:.1} mm   (peak {d:.1} mm)", .{
            s.ragdoll.jointError(&s.world_maximal) * 1000.0,
            s.joint_gap_peak * 1000.0,
        });
        u.separator();
        u.text("maximal joint limits (now: {t})", .{s.limit_mode});
        if (u.button("all limits", .{})) {
            setLimitMode(s, .all);
        }
        if (u.button("hinge limits only", .{})) {
            setLimitMode(s, .hinges_only);
        }
        if (u.button("no limits", .{})) {
            setLimitMode(s, .none);
        }
        u.separator();
        _ = u.checkbox("hold the squat", &s.hold_pose);
        u.text("  left: implicit CT 20 Hz; right: motors 10 Hz", .{});
        u.separator();
        if (u.button("drop again", .{})) {
            s.want_reset = true;
        }
        _ = u.checkbox("pause", &s.paused);
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ragdolls: reduced vs maximal",
            .width = 900,
            .height = 680,
            .scale_mode = .responsive,
            // 3D needs a depth buffer or nearer geometry does not occlude farther.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
