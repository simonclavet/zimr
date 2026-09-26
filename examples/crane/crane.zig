//! crane - moving a swinging load and arriving with it still.
//!
//! Two identical gantry cranes get the same job: carry the payload to the flag and stop. The
//! near one runs a position PD on the trolley; the far one plans. Same acceleration limit, same
//! cable, same target.
//!
//! -- ** WATCH THE TROLLEY, NOT THE LOAD --
//!
//! The planner **decelerates early and briefly runs backwards** near the end. That looks like a
//! mistake and it is the entire trick:
//!
//!     x_ddot = a          theta_ddot = -(g/L)*sin theta - (a/L)*cos theta
//!
//! Accelerating forward swings the payload BACKWARD. So to arrest a load that is already
//! swinging you have to accelerate INTO it - and by then the trolley is already at the flag, so
//! a controller that only watches trolley POSITION has nothing left to say. It arrives, and the
//! load keeps swinging.
//!
//! -- *** MEASURED, SAME LIMIT, SAME TRAVEL --
//!
//!     controller     final x   |angle|   |rate|   peak |vel|   residual swing
//!     position PD      9.994    0.1348   0.3129       2.077           0.2217
//!     MPC             10.000    0.0001   0.0001       3.258           0.0002
//!
//! **A thousandfold less residual swing.** The PD leaves the load swinging through 12.7 degrees.
//!
//! * AND THE PLANNER SPENDS RAIL SPEED TO GET IT: 3.26 m/s against 2.08. Speed is a STATE limit
//! and `boxQP` bounds controls only, so there is no constraint to write - the cost weight is the
//! whole brake. The readout shows peak speed for exactly that reason.
//!
//! -- * THE PLAN IS AN APPROXIMATION AND THE SIMULATION IS NOT --
//!
//! The planner uses the small-angle model; the crane is stepped with the real `sin`/`cos`. That
//! is what real MPC does, and it makes "does the linearisation hold?" something you can watch
//! rather than something this comment claims.

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

const sim_timestep: f32 = 0.02;
const horizon_knots: u32 = 100;
const body: mpc.CraneModel = .{ .cable = 3.0, .gravity = 9.81 };

const background: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const rail_colour: Color = .{ .r = 70, .g = 78, .b = 96, .a = 255 };
const trolley_colour: Color = .{ .r = 148, .g = 156, .b = 172, .a = 255 };
const cable_colour: Color = .{ .r = 108, .g = 116, .b = 132, .a = 255 };
const load_still: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const load_swinging: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };
const flag_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const trail_colour: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };

const trail_length: usize = 220;

/// One crane: its state, and whichever controller drives it.
const Crane = struct {
    state: [mpc.crane_state_dim]f32,
    plan: mpc.CranePlan,
    planned: bool,
    /// Last commanded trolley acceleration, for the readout and the arrow.
    accel: f32,
    peak_speed: f32,
    /// Where the payload has been, so the path is visible rather than remembered.
    trail: [trail_length]Vec,
    trail_count: usize,
    trail_next: usize,
};

const State = struct {
    gpa: Allocator,
    pd: Crane,
    planner: Crane,
    target: f32,
    accel_limit: f32,
    running: bool,
    accumulator: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
};

// Cost weights over `[x, x_dot, theta, theta_dot]`.
//
// * THE SWING TERMS CARRY REAL WEIGHT ALONG THE WAY, not only at the end. Penalising the swing
// solely at the terminal knot lets the plan fling the load and promise to sort it out later,
// which it then cannot do inside the acceleration limit.
const state_weight = [_]f32{ 4.0, 2.0, 60.0, 60.0 };
const control_weight = [_]f32{0.5};
const terminal_weight = [_]f32{ 400.0, 200.0, 2000.0, 2000.0 };

fn weights() mpc.Weights {
    return .{ .state = &state_weight, .control = &control_weight, .terminal = &terminal_weight };
}

fn makeCrane(gpa: Allocator, planned: bool) !Crane {
    const plan: mpc.CranePlan = try mpc.CranePlan.init(gpa, horizon_knots);
    @memset(plan.ctrl, 0);
    @memset(plan.reference, 0);
    return .{
        .state = @splat(0),
        .plan = plan,
        .planned = planned,
        .accel = 0,
        .peak_speed = 0,
        .trail = @splat(vec(0, 0, 0)),
        .trail_count = 0,
        .trail_next = 0,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.pd = try makeCrane(gpa, false);
    s.planner = try makeCrane(gpa, true);
    s.target = 10.0;
    s.accel_limit = 1.2;
    s.running = true;
    s.accumulator = 0;

    s.cam = z.OrbitCamera.init(vec(5, 1.0, 0), 14.0);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 14, 12);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.planner.plan.deinit();
    s.pd.plan.deinit();
}

fn resetAll(s: *State) void {
    inline for (.{ &s.pd, &s.planner }) |c| {
        c.state = @splat(0);
        c.accel = 0;
        c.peak_speed = 0;
        c.trail_count = 0;
        c.trail_next = 0;
        // * AND THE PLAN, NOT ONLY THE CRANE. `solveCrane` warm-starts from `plan.ctrl`; leaving
        // the last run's commands there means the first tick after a reset applies them.
        @memset(c.plan.ctrl, 0);
    }
    s.accumulator = 0;
}

/// Where the payload hangs, given the trolley and the cable angle.
fn payloadAt(state: [mpc.crane_state_dim]f32, depth: f32) Vec {
    const angle: f32 = state[mpc.crane_angle_offset];
    return vec(
        state[mpc.crane_pos_offset] + body.cable * @sin(angle),
        depth - body.cable * @cos(angle),
        0,
    );
}

fn advance(s: *State, c: *Crane, depth: f32) void {
    if (c.planned) {
        for (0..c.plan.horizon + 1) |k| {
            c.plan.reference[k * mpc.crane_state_dim + mpc.crane_pos_offset] = s.target;
        }
        _ = mpc.solveCrane(body, &c.plan, &c.state, weights(), s.accel_limit, sim_timestep, 3);
        c.accel = c.plan.ctrl[0];
    } else {
        // * A POSITION PD, WHICH IS THE HONEST BASELINE. It sees the trolley and nothing else -
        // no term in it refers to the payload, because there is nowhere sensible to put one.
        const err: f32 = s.target - c.state[mpc.crane_pos_offset];
        c.accel = clamp(
            0.35 * err - 1.2 * c.state[mpc.crane_vel_offset],
            -s.accel_limit,
            s.accel_limit,
        );
    }

    const u = [_]f32{c.accel};
    // * THE REAL DYNAMICS, NOT THE PLANNED ONE.
    c.state = mpc.craneStep(body, &c.state, &u, sim_timestep, false);
    c.peak_speed = @max(c.peak_speed, @abs(c.state[mpc.crane_vel_offset]));

    c.trail[c.trail_next] = payloadAt(c.state, depth);
    c.trail_next = (c.trail_next + 1) % trail_length;
    c.trail_count = @min(c.trail_count + 1, trail_length);
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    if (s.running) {
        s.accumulator += @min(f.time.delta_time, 0.1);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            advance(s, &s.pd, 5.0);
            advance(s, &s.planner, 5.0);
        }
    }

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 6.0, .max_distance = 30.0 });
    z.beginMode3D(gl, cam);
    drawCrane(s, gl, &s.pd, -2.2);
    drawCrane(s, gl, &s.planner, 2.2);
    z.endMode3D(gl);
}

fn drawCrane(s: *State, gl: *z.WgpuGl, c: *const Crane, depth: f32) void {
    const rail_y: f32 = 5.0;

    // The rail, and the flag marking the target.
    s.transform[0] = mulMat(
        translation(s.target * 0.5, rail_y + 0.15, depth),
        scaling(s.target + 6.0, 0.12, 0.3),
    );
    z.drawMeshInstanced(gl, &s.cube, &s.transform, rail_colour);
    z.drawLine3D(gl, vec(s.target, rail_y, depth), vec(s.target, rail_y - body.cable - 0.6, depth), flag_colour);

    // The trolley, and an arrow for the acceleration it is being given.
    const trolley: Vec = vec(c.state[mpc.crane_pos_offset], rail_y, depth);
    s.transform[0] = mulMat(translation(trolley[0], trolley[1], trolley[2]), scaling(0.7, 0.35, 0.5));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, trolley_colour);
    z.drawLine3D(gl, trolley, trolley + vec(c.accel * 1.2, 0, 0), flag_colour);

    // Cable and payload. The load turns green once it has genuinely stopped swinging.
    const load: Vec = payloadAt(c.state, rail_y);
    z.drawLine3D(gl, trolley, load, cable_colour);
    const still: bool = @abs(c.state[mpc.crane_angle_offset]) < 0.02 and
        @abs(c.state[mpc.crane_rate_offset]) < 0.02;
    s.transform[0] = mulMat(translation(load[0], load[1], load[2]), scaling(0.45, 0.45, 0.45));
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, if (still) load_still else load_swinging);

    // * THE PAYLOAD'S PATH, which is the comparison drawn: one arrives and stops, the other
    // keeps drawing arcs long after the trolley has parked.
    if (c.trail_count > 1) {
        const start: usize = if (c.trail_count < trail_length) 0 else c.trail_next;
        for (1..c.trail_count) |i| {
            const a: Vec = c.trail[(start + i - 1) % trail_length];
            const b: Vec = c.trail[(start + i) % trail_length];
            z.drawLine3D(gl, a, b, trail_colour);
        }
    }
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    // * THE HEIGHT IS NO LONGER NEEDED: the window sizes to its content, so nothing here has to
    // know how tall the viewport is. Kept in the signature because every example shares it.
    _ = viewport_h;
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    // * AUTO-SIZED, AND NARROW ON A PHONE. These panels asked for 70-80% of the viewport height,
    // which on a phone left the thing the demo is ABOUT as a sliver at the bottom. Letting the
    // window size to its content keeps it as small as it can be, and capping the width stops it
    // spanning the screen.
    const panel_w: f32 = if (narrow) @min(viewport_w - 16, 340.0) else @min(380.0, viewport_w * 0.32);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("carrying a swinging load", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        u.text("same target, same accel limit.", .{});
        u.text("one plans, one does not.", .{});
        u.separator();

        report(u, "PD  ", &s.pd);
        report(u, "MPC ", &s.planner);
        u.separator();

        _ = u.slider("target m", &s.target, .{ .min = 3.0, .max = 18.0, .fmt = "{d:.1}" });
        _ = u.slider("accel limit", &s.accel_limit, .{ .min = 0.3, .max = 3.0, .fmt = "{d:.2}" });
        if (u.button("RESET", .{})) {
            resetAll(s);
        }
        _ = u.checkbox("run", &s.running);
        u.separator();

        u.text("watch the MPC trolley slow early and", .{});
        u.text("  briefly reverse — that is it pushing", .{});
        u.text("  INTO the swing to kill it.", .{});
        u.text("green load = genuinely stopped", .{});
    }
    return captured;
}

fn report(u: ui.Ui, label: []const u8, c: *const Crane) void {
    u.text("{s} x {d:>6.2}  swing {d:>7.4} rad", .{
        label,
        c.state[mpc.crane_pos_offset],
        c.state[mpc.crane_angle_offset],
    });
    u.text("     peak speed {d:>5.2} m/s   accel {d:>6.2}", .{ c.peak_speed, c.accel });
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - carrying a swinging load",
            .width = 940,
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
