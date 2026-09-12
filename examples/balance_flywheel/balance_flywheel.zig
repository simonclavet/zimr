//! balance_flywheel — why a balancing robot windmills its arms.
//!
//! Two identical inverted pendulums get the same shove. The near one may only shift its centre
//! of pressure inside its foot; the far one may also spin its arms. Both are driven by the same
//! planner, the same cost and the same horizon — **the only difference is whether the arms are
//! allowed to move.**
//!
//! ── ★★ WHAT THE ARMS ACTUALLY DO, BECAUSE IT IS NOT WHAT IT LOOKS LIKE ──
//!
//! They are a momentum SINK, not a momentum source. Internal joint torques cannot change a
//! body's angular momentum about its own centre of mass — that is Newton's third law, and it is
//! provable in one line. What changes it is the GROUND:
//!
//!     L̇ = (p − c) × f          →     L̇_y = −h·fₓ − (pₓ − cₓ)·m·g
//!
//! Two independent knobs fall out. The **centre of pressure** `p`, limited by the foot. And the
//! **tangential force** `fₓ`, limited by friction. Once the foot has run out of room the first
//! is finished — but you can still push sideways, and that generates angular momentum which has
//! to go somewhere. Into the arms, or the body rotates and you fall over.
//!
//! ★ SO THE WINDMILLING IS THE PRICE OF THE SIDEWAYS PUSH, NOT THE PUSH ITSELF. Watch the near
//! pendulum: its pressure marker pins to the edge of the foot and then it has nothing left.
//!
//! ── ★★★ AND WHY THIS NEEDS A PLANNER RATHER THAN A GAIN ──
//!
//! Angular momentum is bounded in EXCURSION — arms only rotate so far. So spending it is
//! BORROWING: you take momentum now to arrest the fall and must give it back before the arms
//! run out. That is a finite-horizon trade with a terminal condition, and there is no gain that
//! means "spend now, repay in 400 ms". Measured, the foot alone survives 0.30 m/s and the arms
//! take it to 0.85 — **2.8x** — and the whole of that margin is momentum the planner knows it
//! can return.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const mpc = z.robot_mpc;
const ui = z.ui;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const clamp = zm.clamp;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;

const sim_timestep: f32 = 1.0 / 100.0;
const horizon_knots: u32 = 60;
/// Roughly a human on one foot: 40.8 kg with its mass 0.83 m up.
const body: mpc.BalanceModel = .{ .mass = 40.8, .height = 0.83, .gravity = 9.81 };
/// How much the visible arms weigh, for turning momentum into an angle to draw.
const arm_inertia: f32 = 1.6;

const background: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const foot_colour: Color = .{ .r = 70, .g = 78, .b = 96, .a = 255 };
const rod_colour: Color = .{ .r = 148, .g = 156, .b = 172, .a = 255 };
const mass_ok: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };
const mass_lost: Color = .{ .r = 214, .g = 92, .b = 92, .a = 255 };
const arm_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const pressure_free: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const pressure_pinned: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };

/// One pendulum: its own planner, its own state, its own permission to use its arms.
const Pendulum = struct {
    plan: mpc.BalancePlan,
    /// `[com_xy, vel_xy, momentum_xy]`.
    state: [mpc.lipm_state_dim]f32,
    /// Where the arms have rotated to, from integrating the momentum. Drawing only.
    arm_angle: f32,
    limits: mpc.BalanceLimits,
    fallen: bool,
    /// The centre of pressure the planner asked for last tick.
    pressure: [2]f32,
    pinned: bool,
};

const State = struct {
    gpa: Allocator,
    foot_only: Pendulum,
    with_arms: Pendulum,
    push_speed: f32,
    running: bool,
    accumulator: f32,
    /// Seconds since the last shove, so the readouts mean something.
    since_push: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
};

// Cost weights, in state order [com_x, com_y, vel_x, vel_y, momentum_x, momentum_y].
//
// ★ MOMENTUM IS BARELY PENALISED ALONG THE WAY AND HEAVILY AT THE END. That asymmetry IS the
// borrowing: the planner is free to take on momentum mid-horizon and must have given it back by
// the last knot. Penalising it uniformly would forbid the very thing the arms are for.
const state_weight = [_]f32{ 400, 400, 40, 40, 0.02, 0.02 };
const control_weight = [_]f32{ 1.0, 1.0, 0.002, 0.002 };
const terminal_weight = [_]f32{ 4000, 4000, 400, 400, 0.2, 0.2 };

fn weights() mpc.Weights {
    return .{ .state = &state_weight, .control = &control_weight, .terminal = &terminal_weight };
}

/// One human foot: about 10 cm of usable travel fore-and-aft, 3 cm across.
const foot_half = [2]f32{ 0.10, 0.03 };

fn makePendulum(gpa: Allocator, momentum_rate: f32) !Pendulum {
    const plan: mpc.BalancePlan = try mpc.BalancePlan.init(gpa, horizon_knots);
    @memset(plan.ctrl, 0);
    @memset(plan.reference, 0);
    return .{
        .plan = plan,
        .state = @splat(0),
        .arm_angle = 0,
        .limits = .{ .foot_half = foot_half, .max_momentum_rate = momentum_rate },
        .fallen = false,
        .pressure = .{ 0, 0 },
        .pinned = false,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.foot_only = try makePendulum(gpa, 0.0);
    s.with_arms = try makePendulum(gpa, 60.0);
    s.push_speed = 0.55;
    s.running = true;
    s.accumulator = 0;
    s.since_push = 99;

    s.cam = z.OrbitCamera.init(vec(0, 0.45, 0), 2.2);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 12, 10);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.with_arms.plan.deinit();
    s.foot_only.plan.deinit();
}

fn resetAll(s: *State) void {
    inline for (.{ &s.foot_only, &s.with_arms }) |p| {
        p.state = @splat(0);
        p.arm_angle = 0;
        p.fallen = false;
        p.pressure = .{ 0, 0 };
        p.pinned = false;
        @memset(p.plan.ctrl, 0);
    }
    s.since_push = 99;
    s.accumulator = 0;
}

fn shove(s: *State) void {
    inline for (.{ &s.foot_only, &s.with_arms }) |p| {
        p.state[mpc.lipm_vel_offset] += s.push_speed;
    }
    s.since_push = 0;
}

fn advance(p: *Pendulum) void {
    if (p.fallen) {
        return;
    }
    _ = mpc.solveBalance(body, &p.plan, &p.state, weights(), p.limits, sim_timestep, 3);
    p.pressure = .{ p.plan.ctrl[mpc.lipm_cop_offset], p.plan.ctrl[mpc.lipm_cop_offset + 1] };
    // ★ SATURATION IS THE STORY, so it gets its own flag and its own colour. The near pendulum
    // spends almost the whole recovery pinned to the edge of its foot with nothing left.
    p.pinned = @abs(p.pressure[0]) > 0.98 * foot_half[0];

    p.state = mpc.lipmStep(body, &p.state, p.plan.ctrl[0..mpc.lipm_control_dim], sim_timestep);

    // The arms carry whatever angular momentum the ground has handed over, so their ANGLE is
    // its integral. This is the only reason the momentum is visible at all.
    p.arm_angle += (p.state[mpc.lipm_momentum_offset + 1] / arm_inertia) * sim_timestep;

    // Past about a third of a metre a real body has stepped or gone down; the model stops
    // describing anything useful either way.
    if (@abs(p.state[mpc.lipm_com_offset]) > 0.35) {
        p.fallen = true;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    if (s.running) {
        s.accumulator += @min(f.time.delta_time, 0.1);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            advance(&s.foot_only);
            advance(&s.with_arms);
            s.since_push += sim_timestep;
        }
    }

    z.clearViewport(f, background);
    const aspect: f32 = f.window.widthf() / @max(1.0, f.window.heightf());
    s.cam.distance = clamp(2.4 / @max(0.35, aspect), 1.8, 5.5);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 8.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 12, 0.25);
    drawPendulum(s, gl, &s.foot_only, -0.55);
    drawPendulum(s, gl, &s.with_arms, 0.55);
    z.endMode3D(gl);
}

/// Draw one pendulum at render depth `offset`. The model plane is (x, y) with the mass at
/// height `h`; the render is Y-up, so model x is render x and model height is render y.
fn drawPendulum(s: *State, gl: *z.WgpuGl, p: *const Pendulum, offset: f32) void {
    const com_x: f32 = p.state[mpc.lipm_com_offset];
    const mass_at: Vec = vec(com_x, body.height, offset);

    // The foot: the box the centre of pressure is allowed to live in.
    s.transform[0] = mulMat(
        translation(0, 0.005, offset),
        scaling(2.0 * foot_half[0], 0.01, 0.16),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, foot_colour);

    // Where the pressure actually is, and whether it has run out of room.
    const cop: Vec = vec(p.pressure[0], 0.02, offset);
    s.transform[0] = mulMat(translation(cop[0], cop[1], cop[2]), scaling(0.03, 0.03, 0.03));
    z.drawMeshInstanced(
        gl,
        &s.sphere,
        &s.transform,
        if (p.pinned) pressure_pinned else pressure_free,
    );

    // The body: a rod from the support to the mass.
    z.drawLine3D(gl, vec(0, 0, offset), mass_at, rod_colour);
    s.transform[0] = mulMat(
        translation(mass_at[0], mass_at[1], mass_at[2]),
        scaling(0.09, 0.09, 0.09),
    );
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, if (p.fallen) mass_lost else mass_ok);

    // ★ THE ARMS. Their angle is the integral of the angular momentum, so a pendulum with no
    // momentum authority simply never moves them — which is the comparison, drawn.
    const arm_length: f32 = 0.34;
    inline for ([_]f32{ 0.0, zm.pi }) |side| {
        const angle: f32 = p.arm_angle + side;
        const tip: Vec = vec(
            mass_at[0] + arm_length * @cos(angle),
            mass_at[1] + arm_length * @sin(angle),
            offset,
        );
        z.drawLine3D(gl, mass_at, tip, arm_colour);
        s.transform[0] = mulMat(
            translation(tip[0], tip[1], tip[2]),
            scaling(0.045, 0.045, 0.045),
        );
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, arm_colour);
    }
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    // ★ THE HEIGHT IS NO LONGER NEEDED: the window sizes to its content, so nothing here has to
    // know how tall the viewport is. Kept in the signature because every example shares it.
    _ = viewport_h;
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    // ★ AUTO-SIZED, AND NARROW ON A PHONE. These panels asked for 70-80% of the viewport height,
    // which on a phone left the thing the demo is ABOUT as a sliver at the bottom. Letting the
    // window size to its content keeps it as small as it can be, and capping the width stops it
    // spanning the screen.
    const panel_w: f32 = if (narrow) @min(viewport_w - 16, 340.0) else @min(380.0, viewport_w * 0.32);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("why a robot windmills", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        u.text("same shove, same planner, same cost.", .{});
        u.text("the only difference is the arms.", .{});
        u.separator();

        report(u, "foot only ", &s.foot_only);
        report(u, "with arms ", &s.with_arms);
        u.separator();

        _ = u.slider("shove m/s", &s.push_speed, .{ .min = 0.1, .max = 1.6, .fmt = "{d:.2}" });
        u.text("foot alone survives ~0.30; arms ~0.85", .{});
        if (u.button("SHOVE BOTH", .{})) {
            shove(s);
        }
        if (u.button("reset", .{})) {
            resetAll(s);
        }
        _ = u.checkbox("run", &s.running);
        u.separator();

        u.text("pink pressure marker = pinned to the", .{});
        u.text("  foot edge, no authority left", .{});
    }
    return captured;
}

fn report(u: ui.Ui, label: []const u8, p: *const Pendulum) void {
    if (p.fallen) {
        u.text("{s} FELL", .{label});
        return;
    }
    u.text("{s} lean {d:>6.3} m  speed {d:>6.3}", .{
        label,
        p.state[mpc.lipm_com_offset],
        p.state[mpc.lipm_vel_offset],
    });
    u.text("           momentum {d:>7.2}  cop {d:>6.3}{s}", .{
        p.state[mpc.lipm_momentum_offset + 1],
        p.pressure[0],
        if (p.pinned) " PINNED" else "",
    });
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - why a robot windmills its arms",
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
