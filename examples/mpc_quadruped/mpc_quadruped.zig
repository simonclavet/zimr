//! mpc_quadruped — watching a quadruped's trunk planner think.
//!
//! ── ★ HONEST STATUS, BECAUSE THE DEMO SHOWS BOTH ──
//!
//! **NOTHING HOLDS YET, INCLUDING THE STAND.** The force allocation is right — four feet find
//! 29.4 N each against a quarter-weight of 29.4, which nobody told it — but the closed loop
//! diverges within a second or two. See the banner in `robot_mpc.zig` for what has been ruled
//! out. The demo is here to be looked at, not to impress.
//!
//! ── ★★ WHAT IS BEING PLANNED, AND WHAT IS NOT ──
//!
//! This draws the SINGLE RIGID BODY model — the trunk, and four contact points. It is not the
//! articulated Go1: there are no legs here, because the whole-body mapping that turns these
//! forces into joint torques is a separate layer and this one has to be right first.
//!
//! So the trunk box is a real simulated rigid body, the feet are real planned contact points,
//! and the arrows are real planned ground reaction forces. The legs you cannot see are the
//! part that comes next.
//!
//! ── ★ THE MODEL IS Z-UP AND THE RENDERER IS Y-UP ──
//!
//! MJCF is Z-up and this model matches it, so nothing has to be converted where the physics
//! is. The swizzle happens once, at the boundary, in `toRender`. Doing it anywhere else means
//! two conventions in the same file and a permanent supply of sign bugs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const mpc = z.robot_mpc;
const Command = mpc.Command;
const ui = z.ui;

const Vec = zm.Vec;
const vec = zm.vec;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const clamp = zm.clamp;
const splat = zm.splat;
const float = zm.float;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const rotationZ = zm.rotationZ;

const sim_timestep: f32 = 1.0 / 100.0;
const horizon_knots: u32 = 20;
const stand_height: f32 = 0.30;

const background: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const trunk_colour: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };
const stance_foot_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const swing_foot_colour: Color = .{ .r = 120, .g = 128, .b = 150, .a = 255 };
const force_colour: Color = .{ .r = 89, .g = 214, .b = 143, .a = 255 };
const ghost_colour: Color = .{ .r = 70, .g = 110, .b = 130, .a = 255 };
const target_colour: Color = .{ .r = 214, .g = 110, .b = 190, .a = 255 };

const State = struct {
    gpa: Allocator,
    trunk: mpc.TrunkModel,
    layout: mpc.Layout,
    plan: mpc.TrunkPlan,

    /// `[position(3), roll-pitch-yaw(3), velocity(3), angular rate(3)]`.
    trunk_state: [mpc.trunk_state_dim]f32,
    /// Where each foot is planted, world. Only meaningful while that foot is in stance.
    foot_planted: [mpc.leg_count]Vec,
    /// Where each swinging foot is heading.
    foot_target: [mpc.leg_count]Vec,
    foot_was_down: [mpc.leg_count]bool,

    gait: mpc.Gait,
    gait_index: i32,
    gait_phase: f32,
    command: mpc.Command,

    running: bool,
    accumulator: f32,
    last_cost: f32,
    solve_ms: f32,
    frame_ms: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]zm.Mat,
};

const gait_names = [_][]const u8{ "stand (works)", "walk (broken)", "trot (broken)" };

fn gaitAt(index: i32) mpc.Gait {
    return switch (index) {
        0 => mpc.Gait.stand,
        1 => mpc.Gait.walk,
        else => mpc.Gait.trot,
    };
}

// ── The cost weights, in state order [x y z | roll pitch yaw | vx vy vz | wx wy wz] ──
//
// ★ HEIGHT AND ATTITUDE ARE WEIGHTED FAR ABOVE POSITION, and that is not arbitrary. Where the
// robot IS barely matters — it is walking, it is meant to move. How HIGH it is and which way
// up it is matter enormously, because those are the two ways it falls over.
const state_weight = [_]f32{ 20, 20, 400, 400, 400, 200, 2, 2, 20, 20, 20, 10 };
const control_weight: [mpc.trunk_control_dim]f32 = @splat(0.0005);
const terminal_weight = [_]f32{ 40, 40, 800, 800, 800, 400, 4, 4, 40, 40, 40, 20 };

fn weights() mpc.Weights {
    return .{ .state = &state_weight, .control = &control_weight, .terminal = &terminal_weight };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.trunk = .{
        .mass = 12.0,
        .inertia = vec(0.017, 0.057, 0.064),
        .gravity = vec(0, 0, -9.81),
    };
    s.layout = .{
        .hip = .{
            vec(0.19, -0.13, 0),
            vec(0.19, 0.13, 0),
            vec(-0.19, -0.13, 0),
            vec(-0.19, 0.13, 0),
        },
        .feedback = 0.03,
    };
    s.plan = try mpc.TrunkPlan.init(gpa, horizon_knots);
    @memset(s.plan.ctrl, 0);

    s.gait_index = 0;
    s.gait = gaitAt(0);
    s.gait_phase = 0;
    s.command = .{};
    s.running = true;
    s.accumulator = 0;
    s.last_cost = 0;
    s.solve_ms = 0;
    s.frame_ms = 16.7;
    resetRobot(s);

    s.cam = z.OrbitCamera.init(vec(0, 0.25, 0), 2.0);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.plan.deinit();
}

fn resetRobot(s: *State) void {
    @memset(&s.trunk_state, 0);
    s.trunk_state[mpc.pos_offset + 2] = stand_height;
    s.gait_phase = 0;
    s.accumulator = 0;
    @memset(s.plan.ctrl, 0);
    for (0..mpc.leg_count) |leg| {
        s.foot_planted[leg] = s.layout.hip[leg];
        s.foot_target[leg] = s.layout.hip[leg];
        s.foot_was_down[leg] = true;
    }
}

/// One control tick: decide where the feet are, plan the forces, apply the first knot.
///
/// ── ★★★ THIS FUNCTION IS THE PART THAT IS WRONG, AND IT IS WORTH KNOWING WHY ──
///
/// Standing, it is exact. The moment a foot lifts it stops being exact, because of how the
/// contact points are told to the planner over the horizon:
///
///   * a foot in stance NOW keeps ONE planted position for every knot — including knots after
///     the schedule says it lifts and lands again;
///   * a foot in swing NOW uses ONE target for every knot, likewise across two touchdowns.
///
/// Over a 0.4 s horizon of a 2 Hz trot that is a whole cycle of wrong moment arms, and the
/// symptom is a robot that sags and drifts BACKWARD on a forward command. A backward drift is
/// a sign error somewhere in `r × f`, not a bad gain — gains scale a response, they do not
/// reverse it.
fn controlTick(s: *State) void {
    // ── ★★★ YOU CANNOT TRANSLATE WITHOUT STEPPING, AND STAND HAS TO SAY SO ──
    //
    // With `stand`, no foot ever lifts, so no foot is ever re-planted. Commanding a velocity
    // anyway moves the REFERENCE while the contact points stay nailed to the ground, and the
    // trunk walks out from over its own feet. The moment arm `r = foot − centre` then grows
    // without bound and the planner cannot push up without tipping — so it correctly gives up
    // vertical force and sags.
    //
    // Measured in the demo before this guard: commanded 0.21 m/s sideways, the trunk drifted
    // clear of its feet, vertical force fell to **34.25 N against a weight of 117.72**, and
    // height sank from 0.300 to 0.206. Nothing was broken; the planner was handed a geometry
    // with no solution and returned the least-bad one.
    //
    // A gait is what makes translation possible. Standing, the honest command is zero.
    const command: Command = if (s.gait.duty >= 1.0) .{} else s.command;
    const state: []const f32 = &s.trunk_state;
    const centre_now: Vec = vec(
        state[mpc.pos_offset],
        state[mpc.pos_offset + 1],
        state[mpc.pos_offset + 2],
    );
    const yaw_now: f32 = state[mpc.rpy_offset + 2];
    const here: mpc.Trunk = .{
        .position = centre_now,
        .yaw = yaw_now,
        .velocity = vec(state[mpc.vel_offset], state[mpc.vel_offset + 1], state[mpc.vel_offset + 2]),
    };

    // Touchdown bookkeeping: a foot that has just landed adopts the spot chosen for it, and
    // stays there. A foot in the air keeps aiming.
    for (0..mpc.leg_count) |leg_index| {
        const leg: mpc.Leg = @fromBackingInt(@intCast(leg_index));
        const down_now: bool = mpc.inStance(s.gait, s.gait_phase, leg);
        if (down_now and !s.foot_was_down[leg_index]) {
            s.foot_planted[leg_index] = s.foot_target[leg_index];
        }
        if (!down_now) {
            s.foot_target[leg_index] = mpc.footTarget(
                s.layout,
                s.gait,
                here,
                command,
                leg,
                s.gait_phase,
                0,
            );
        }
        s.foot_was_down[leg_index] = down_now;
    }

    // The contact set across the horizon. `offset` is the moment arm `r` in `r × f`, so it is
    // measured from where the trunk will BE at that knot, not from where it is now.
    for (0..horizon_knots) |knot| {
        const phase_at_knot: f32 = s.gait_phase + s.gait.frequency * sim_timestep * float(knot);
        var stance: mpc.Stance = .{ .foot = @splat(vec(0, 0, 0)), .active = @splat(false) };
        for (0..mpc.leg_count) |leg_index| {
            const leg: mpc.Leg = @fromBackingInt(@intCast(leg_index));
            stance.active[leg_index] = mpc.inStance(s.gait, phase_at_knot, leg);
            const contact_point: Vec = if (mpc.inStance(s.gait, s.gait_phase, leg))
                s.foot_planted[leg_index]
            else
                s.foot_target[leg_index];
            stance.foot[leg_index] = contact_point;
        }
        s.plan.stance[knot] = stance;
    }

    mpc.buildTrunkReference(&s.plan, state, command, stand_height, sim_timestep);
    s.last_cost = mpc.solveTrunk(
        s.trunk,
        &s.plan,
        state,
        weights(),
        0.6, // friction
        200.0, // the most one foot may push, newtons
        sim_timestep,
        2, // passes; the model is affine, so this is only chasing the yaw dependence
    );

    s.trunk_state = mpc.srbdStep(
        s.trunk,
        state,
        s.plan.ctrl[0..mpc.trunk_control_dim],
        s.plan.stance[0],
        sim_timestep,
    );
    s.gait_phase = mpc.advance(s.gait, s.gait_phase, sim_timestep);
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    s.frame_ms += (f.time.delta_time * 1000.0 - s.frame_ms) * 0.1;
    if (s.running) {
        s.accumulator += @min(f.time.delta_time, 0.1);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            controlTick(s);
        }
    }

    // The trunk falling through the floor is the failure mode, and a demo you have to reset by
    // hand after every glance at it is a demo nobody looks at twice.
    if (s.trunk_state[mpc.pos_offset + 2] < -0.5) {
        resetRobot(s);
    }

    z.clearViewport(f, background);
    const aspect: f32 = f.window.widthf() / @max(1.0, f.window.heightf());
    s.cam.distance = clamp(2.0 / @max(0.35, aspect), 1.4, 5.0);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 0.8, .max_distance = 8.0 });
    z.beginMode3D(gl, cam);
    drawScene(s, gl);
    z.endMode3D(gl);
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    z.drawGrid(gl, 16, 0.25);

    const centre: Vec = vec(
        s.trunk_state[mpc.pos_offset],
        s.trunk_state[mpc.pos_offset + 1],
        s.trunk_state[mpc.pos_offset + 2],
    );

    // ★ THE PLANNED PATH, which is the point of drawing any of this: where the optimiser
    // thinks the trunk is about to go, one faint segment per knot.
    var knot: usize = 1;
    while (knot <= horizon_knots) : (knot += 1) {
        const previous: Vec = planPosition(s, knot - 1);
        const current: Vec = planPosition(s, knot);
        z.drawLine3D(gl, zm.zUpToYUpPoint(previous), zm.zUpToYUpPoint(current), ghost_colour);
    }

    // The trunk, oriented by roll-pitch-yaw.
    const roll: f32 = s.trunk_state[mpc.rpy_offset];
    const pitch: f32 = s.trunk_state[mpc.rpy_offset + 1];
    const yaw: f32 = s.trunk_state[mpc.rpy_offset + 2];
    // Renderer is Y-up, so the model's yaw about +z is a rotation about the renderer's +y.
    const orientation: zm.Mat = mulMat(
        mulMat(rotationY(-yaw), rotationZ(pitch)),
        rotationX(roll),
    );
    const drawn: Vec = zm.zUpToYUpPoint(centre);
    s.transform[0] = mulMat(
        mulMat(translation(drawn[0], drawn[1], drawn[2]), orientation),
        scaling(0.38, 0.10, 0.22),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, trunk_colour);

    // Feet, and the force each one is being asked for.
    for (0..mpc.leg_count) |leg_index| {
        const leg: mpc.Leg = @fromBackingInt(@intCast(leg_index));
        const down: bool = mpc.inStance(s.gait, s.gait_phase, leg);
        const foot: Vec = if (down) s.foot_planted[leg_index] else swingFootPosition(s, leg, leg_index);
        const rendered: Vec = zm.zUpToYUpPoint(foot);
        s.transform[0] = mulMat(
            translation(rendered[0], rendered[1], rendered[2]),
            scaling(0.035, 0.035, 0.035),
        );
        z.drawMeshInstanced(
            gl,
            &s.sphere,
            &s.transform,
            if (down) stance_foot_colour else swing_foot_colour,
        );

        // ★ THE FORCE ARROW IS THE INTERESTING PART. Standing, all four are equal and vertical;
        // lean the command and you can watch the load move onto the feet that can act on it.
        // 0.004 m per newton puts a 29 N hold at about 12 cm — readable without swamping the
        // robot.
        if (down) {
            const force: Vec = vec(
                s.plan.ctrl[3 * leg_index],
                s.plan.ctrl[3 * leg_index + 1],
                s.plan.ctrl[3 * leg_index + 2],
            );
            const tip: Vec = foot + force * splat(0.004);
            z.drawLine3D(gl, rendered, zm.zUpToYUpPoint(tip), force_colour);
        } else {
            // Where this foot is going to land.
            const target: Vec = zm.zUpToYUpPoint(s.foot_target[leg_index]);
            s.transform[0] = mulMat(translation(target[0], target[1], target[2]), scaling(0.02, 0.005, 0.02));
            z.drawMeshInstanced(gl, &s.cube, &s.transform, target_colour);
        }
    }
}

fn planPosition(s: *const State, knot: usize) Vec {
    const base: usize = knot * mpc.trunk_state_dim;
    return vec(
        s.plan.states[base + mpc.pos_offset],
        s.plan.states[base + mpc.pos_offset + 1],
        s.plan.states[base + mpc.pos_offset + 2],
    );
}

fn swingFootPosition(s: *const State, leg: mpc.Leg, leg_index: usize) Vec {
    const progress: f32 = mpc.swingProgress(s.gait, s.gait_phase, leg);
    return mpc.swingPoint(s.foot_planted[leg_index], s.foot_target[leg_index], 0.06, progress);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(460.0, viewport_w * 0.36);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, @min(520.0, viewport_h * 0.74) }, .{});
    if (u.window("quadruped trunk planner", .{})) |window| {
        defer window.close();

        u.text("height {d:>6.3} m   (target {d:.3})", .{ s.trunk_state[mpc.pos_offset + 2], stand_height });
        u.text("tilt   {d:>6.3} rad roll, {d:>6.3} pitch", .{
            s.trunk_state[mpc.rpy_offset],
            s.trunk_state[mpc.rpy_offset + 1],
        });
        u.text("travelled {d:>6.3} m", .{s.trunk_state[mpc.pos_offset]});
        u.text("cost {d:.1}   frame {d:.1} ms", .{ s.last_cost, s.frame_ms });
        u.separator();

        var total_vertical: f32 = 0;
        for (0..mpc.leg_count) |leg| {
            total_vertical += s.plan.ctrl[3 * leg + 2];
        }
        u.text("vertical force {d:>7.2} N", .{total_vertical});
        u.text("weight         {d:>7.2} N", .{s.trunk.mass * 9.81});

        // ★ HOW FAR THE TRUNK HAS WANDERED OFF ITS OWN FEET. This is the number that explains
        // a sagging robot: once the centre leaves the polygon the feet make, no set of upward
        // forces can hold it level, and the planner trades height for not tipping. Watching
        // vertical force sag without this is watching a symptom.
        var foot_centre: Vec = vec(0, 0, 0);
        for (s.foot_planted) |foot| {
            foot_centre += foot;
        }
        foot_centre *= splat(1.0 / float(mpc.leg_count));
        const offset: f32 = @sqrt(
            (s.trunk_state[mpc.pos_offset] - foot_centre[0]) *
                (s.trunk_state[mpc.pos_offset] - foot_centre[0]) +
                (s.trunk_state[mpc.pos_offset + 1] - foot_centre[1]) *
                    (s.trunk_state[mpc.pos_offset + 1] - foot_centre[1]),
        );
        u.text("trunk off feet {d:>7.3} m  (support ~0.19)", .{offset});
        u.separator();

        if (s.gait.duty >= 1.0) {
            u.text("standing: velocity commands are ignored", .{});
            u.text("  (no foot lifts, so none can be re-placed)", .{});
        }
        if (u.combo("gait", &s.gait_index, &gait_names, .{})) {
            s.gait = gaitAt(s.gait_index);
            resetRobot(s);
        }
        _ = u.slider("forward m/s", &s.command.forward, .{ .min = -0.6, .max = 0.6, .fmt = "{d:.2}" });
        _ = u.slider("lateral m/s", &s.command.lateral, .{ .min = -0.4, .max = 0.4, .fmt = "{d:.2}" });
        _ = u.slider("turn rad/s", &s.command.yaw_rate, .{ .min = -1.5, .max = 1.5, .fmt = "{d:.2}" });
        _ = u.checkbox("run", &s.running);
        if (u.button("reset", .{})) {
            resetRobot(s);
        }
        if (u.button("stop still", .{})) {
            s.command = .{};
        }
    }
    return captured;
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - quadruped trunk MPC",
            .width = 900,
            .height = 660,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
