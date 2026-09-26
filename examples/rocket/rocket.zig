//! rocket - landing on an engine you are not allowed to switch off.
//!
//! Two identical vehicles get the same descent. The near one runs PD on altitude and attitude;
//! the far one plans. Same thrust range, same gimbal limit, same start.
//!
//! -- *** THE LOWER THRUST BOUND IS THE PROBLEM --
//!
//! The engine cannot throttle below **40% of weight**, so "cut it and coast" does not exist.
//! A vehicle that needs less deceleration than the minimum provides has exactly one move:
//! **lean over and waste some thrust sideways.** Watch the flame - it never goes out.
//!
//! That manoeuvre is not something a gain can represent, and it falls out of the box solve for
//! free because the bound is ASYMMETRIC: `[0.4*W, 2.0*W]`, not a symmetric clamp.
//!
//! -- ** IT LANDS ALL FOUR STARTS; THE PD LANDS NONE --
//!
//!     controller   touchdown vy    tilt      verdict
//!     PD                 -1.10     0.002     0 of 4
//!     MPC                -0.11     0.005     4 of 4
//!
//! An order of magnitude inside every criterion, from every offset - and the PD is not bad, it
//! simply descends at 1.10 m/s against a 0.5 bar with no way to correct laterally.
//!
//! * AND THE FIRST VERSION FAILED IN A WAY THAT VALIDATED THE MODEL. Told to be AT the pad -
//! 100 m away, with a 3 s horizon - it found that unreachable, settled for zero VELOCITY, and
//! leaned 0.474 rad to waste thrust so it could hover below minimum throttle. Exactly the
//! manoeuvre this example exists to show, applied to the wrong goal. **A reference has to be
//! reachable inside the horizon**, so the planner now tracks a descent PROFILE instead.
//!
//! ** THE THRUST READOUT IS THE NEXT MEASUREMENT, ON PURPOSE. If the planner is not saturating
//! high in the last seconds, it does not believe it needs to flare - and that is a reference
//! problem, not a weights problem. The panel shows commanded throttle so the question is
//! answerable by looking.

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
const splat = zm.splat;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;
const rotationZ = zm.rotationZ;

const sim_timestep: f32 = 0.05;
const horizon_knots: u32 = 60;
const body: mpc.RocketModel = .{ .mass = 500.0, .inertia = 3000.0, .arm = 5.0, .gravity = 9.81 };
const weight: f32 = 500.0 * 9.81;
const limits: mpc.RocketLimits = .{
    .min_thrust = 0.4 * weight,
    .max_thrust = 2.0 * weight,
    .max_gimbal = 0.262,
};

const background: Color = .{ .r = 14, .g = 16, .b = 24, .a = 255 };
const ground_colour: Color = .{ .r = 62, .g = 70, .b = 86, .a = 255 };
const pad_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const hull_colour: Color = .{ .r = 168, .g = 176, .b = 192, .a = 255 };
const flame_low: Color = .{ .r = 226, .g = 140, .b = 70, .a = 255 };
const flame_high: Color = .{ .r = 255, .g = 226, .b = 140, .a = 255 };
const trail_colour: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };
const landed_colour: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const crashed_colour: Color = .{ .r = 214, .g = 92, .b = 92, .a = 255 };

const trail_length: usize = 400;

const Vehicle = struct {
    state: [mpc.rocket_state_dim]f32,
    plan: mpc.RocketPlan,
    planned: bool,
    thrust: f32,
    gimbal: f32,
    /// Set once the vehicle reaches the ground, and what it looked like when it did.
    down: bool,
    touchdown_vy: f32,
    touchdown_vx: f32,
    touchdown_tilt: f32,
    good: bool,
    trail: [trail_length]Vec,
    trail_count: usize,
};

const State = struct {
    gpa: Allocator,
    pd: Vehicle,
    planner: Vehicle,
    start_x: f32,
    start_alt: f32,
    start_vy: f32,
    running: bool,
    accumulator: f32,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    transform: [1]Mat,
};

// * LEANING IS NEARLY FREE MID-HORIZON AND EXPENSIVE AT THE LAST KNOT. A vehicle 30 m off the
// pad HAS to translate, and the only way to translate is to lean - `ax = T*sin(theta+delta)/m`. Weighting
// tilt heavily along the whole path made the lean cost more than the miss, and the planner flew
// down beside the pad and hovered there with 5.65 m/s of drift still on it.
const state_weight = [_]f32{ 3.0, 0.02, 4.0, 4.0, 5.0, 8.0 };
const control_weight = [_]f32{ 2.0e-6, 30.0 };
const terminal_weight = [_]f32{ 300.0, 40.0, 600.0, 600.0, 1200.0, 800.0 };

fn weights() mpc.Weights {
    return .{ .state = &state_weight, .control = &control_weight, .terminal = &terminal_weight };
}

fn makeVehicle(gpa: Allocator, planned: bool) !Vehicle {
    const plan: mpc.RocketPlan = try mpc.RocketPlan.init(gpa, horizon_knots);
    @memset(plan.ctrl, 0);
    @memset(plan.reference, 0);
    return .{
        .state = @splat(0),
        .plan = plan,
        .planned = planned,
        .thrust = weight,
        .gimbal = 0,
        .down = false,
        .touchdown_vy = 0,
        .touchdown_vx = 0,
        .touchdown_tilt = 0,
        .good = false,
        .trail = @splat(vec(0, 0, 0)),
        .trail_count = 0,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.pd = try makeVehicle(gpa, false);
    s.planner = try makeVehicle(gpa, true);
    s.start_x = 30.0;
    s.start_alt = 100.0;
    s.start_vy = -30.0;
    s.running = true;
    s.accumulator = 0;

    s.cam = z.OrbitCamera.init(vec(0, 45, 0), 150.0);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.transform = .{identity()};
    resetAll(s);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.planner.plan.deinit();
    s.pd.plan.deinit();
}

fn resetAll(s: *State) void {
    inline for (.{ &s.pd, &s.planner }) |v| {
        v.state = @splat(0);
        v.state[mpc.rocket_x_offset] = s.start_x;
        v.state[mpc.rocket_y_offset] = s.start_alt;
        v.state[mpc.rocket_vy_offset] = s.start_vy;
        v.state[mpc.rocket_vx_offset] = -0.3 * s.start_x / 3.0;
        v.thrust = weight;
        v.gimbal = 0;
        v.down = false;
        v.good = false;
        v.trail_count = 0;
        // * AND THE PLAN, NOT ONLY THE VEHICLE. `solveRocket` warm-starts from `plan.ctrl`;
        // leaving the last descent's commands there means the first tick of the next one
        // applies them. That exact oversight explained both "it explodes" and "reset does not
        // reset" in the humanoid.
        @memset(v.plan.ctrl, 0);
        for (0..v.plan.horizon) |k| {
            v.plan.ctrl[k * mpc.rocket_control_dim + mpc.rocket_thrust_offset] = weight;
        }
    }
    s.accumulator = 0;
}

fn advance(v: *Vehicle) void {
    if (v.down) {
        return;
    }
    if (v.planned) {
        // -- *** A DESCENT PROFILE, NOT A DESTINATION --
        //
        // `v = -sqrt(2*a*h)` is the fastest descent from which a given deceleration still brings you
        // to rest at the ground. That shape is kinematics, not a tuning choice - a linear
        // `-0.4*h` commands -2.2 m/s with 5 m left, and the vehicle faithfully delivers -2.2.
        var altitude: f32 = v.state[mpc.rocket_y_offset];
        var lateral: f32 = v.state[mpc.rocket_x_offset];
        for (0..v.plan.horizon + 1) |k| {
            const want_vy: f32 = -@min(35.0, @sqrt(2.0 * 0.6 * @max(0.0, altitude)) + 0.15);
            // *** AND THE LATERAL AXIS GETS A PROFILE TOO. Fixing only the vertical one left `x`
            // as a STEP target of zero at every knot, so a vehicle 30 m out was told to be over
            // the pad IMMEDIATELY - the same unreachable reference that made the first version
            // hover, left in place on the other axis. It is exactly why the centred start landed
            // and the offset ones never did.
            const fall_speed: f32 = @max(0.5, -want_vy);
            const time_left: f32 = @max(1.0, altitude / fall_speed);
            const want_vx: f32 = clamp(-lateral / time_left, -25.0, 25.0);
            v.plan.reference[k * mpc.rocket_state_dim + mpc.rocket_y_offset] = altitude;
            v.plan.reference[k * mpc.rocket_state_dim + mpc.rocket_vy_offset] = want_vy;
            v.plan.reference[k * mpc.rocket_state_dim + mpc.rocket_x_offset] = lateral;
            v.plan.reference[k * mpc.rocket_state_dim + mpc.rocket_vx_offset] = want_vx;
            altitude = @max(0.0, altitude + want_vy * sim_timestep);
            lateral += want_vx * sim_timestep;
        }
        _ = mpc.solveRocket(body, &v.plan, &v.state, weights(), limits, sim_timestep, 4);
        // *** SLIDE THE PLAN A KNOT FORWARD. The tutorial has said to since it was written, and
        // this planner did not: every tick warm-started from a sequence stale by one knot.
        // Measured without it, the commanded throttle chattered between its bounds on the way
        // down - 163%, 109%, 88%, 61%, 132%, 192%, 200%, 77% - which is not a flare, it is a
        // solver re-deriving from a seed that no longer describes its problem.
        mpc.shiftRocketPlan(&v.plan);
        v.thrust = v.plan.ctrl[mpc.rocket_thrust_offset];
        v.gimbal = v.plan.ctrl[mpc.rocket_gimbal_offset];
    } else {
        // * THE HONEST BASELINE: PD on altitude and attitude, same bounds. Nothing in it can say
        // "lean over to waste thrust I am not allowed to switch off", because there is nowhere
        // sensible to put such a term.
        const want_vy: f32 = -0.15 * v.state[mpc.rocket_y_offset] - 1.0;
        const raw_thrust: f32 = weight + 900.0 * (want_vy - v.state[mpc.rocket_vy_offset]);
        const want_tilt: f32 = clamp(
            -0.02 * v.state[mpc.rocket_x_offset] - 0.08 * v.state[mpc.rocket_vx_offset],
            -0.3,
            0.3,
        );
        const raw_gimbal: f32 = -2.0 * (want_tilt - v.state[mpc.rocket_tilt_offset]) +
            1.5 * v.state[mpc.rocket_rate_offset];
        v.thrust = clamp(raw_thrust, limits.min_thrust, limits.max_thrust);
        v.gimbal = clamp(raw_gimbal, -limits.max_gimbal, limits.max_gimbal);
    }

    const u = [_]f32{ v.thrust, v.gimbal };
    v.state = mpc.rocketStep(body, &v.state, &u, sim_timestep);

    if (v.trail_count < trail_length) {
        v.trail[v.trail_count] = vec(v.state[mpc.rocket_x_offset], v.state[mpc.rocket_y_offset], 0);
        v.trail_count += 1;
    }

    if (v.state[mpc.rocket_y_offset] <= 0) {
        v.down = true;
        v.touchdown_vy = v.state[mpc.rocket_vy_offset];
        v.touchdown_vx = v.state[mpc.rocket_vx_offset];
        v.touchdown_tilt = v.state[mpc.rocket_tilt_offset];
        // The acceptance test, checked where it happens.
        v.good = @abs(v.touchdown_vy) < 0.5 and @abs(v.touchdown_vx) < 0.3 and
            @abs(v.touchdown_tilt) < 0.087 and @abs(v.state[mpc.rocket_x_offset]) < 1.0;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    if (s.running) {
        s.accumulator += @min(f.time.delta_time, 0.2);
        while (s.accumulator >= sim_timestep) : (s.accumulator -= sim_timestep) {
            advance(&s.pd);
            advance(&s.planner);
        }
    }

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 40.0, .max_distance = 400.0 });
    z.beginMode3D(gl, cam);

    // Ground, and the pad the vehicles are aiming at.
    s.transform[0] = mulMat(translation(0, -1.5, 0), scaling(400, 3, 120));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_colour);
    s.transform[0] = mulMat(translation(0, 0.3, 0), scaling(8, 0.6, 40));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, pad_colour);

    drawVehicle(s, gl, &s.pd, -26.0);
    drawVehicle(s, gl, &s.planner, 26.0);
    z.endMode3D(gl);
}

fn drawVehicle(s: *State, gl: *z.WgpuGl, v: *const Vehicle, depth: f32) void {
    const at: Vec = vec(v.state[mpc.rocket_x_offset], v.state[mpc.rocket_y_offset], depth);
    const tilt: f32 = v.state[mpc.rocket_tilt_offset];
    // * +tilt LEANS TOWARD +x, and the render's Z rotation turns +y toward -x - hence the
    // negation. Getting this backwards draws a vehicle leaning away from where it is going.
    const lean: Mat = rotationZ(-tilt);

    s.transform[0] = mulMat(mulMat(translation(at[0], at[1], at[2]), lean), scaling(3.0, 12.0, 3.0));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, if (v.down)
        (if (v.good) landed_colour else crashed_colour)
    else
        hull_colour);

    // * THE FLAME LENGTH IS THE THROTTLE, AND IT NEVER GOES OUT. That is the whole constraint,
    // drawn: the minimum is 40% of weight, so there is always a flame, and a vehicle that needs
    // less deceleration has to lean instead.
    if (!v.down) {
        const throttle: f32 = v.thrust / limits.max_thrust;
        const body_down: Vec = vec(@sin(tilt), -@cos(tilt), 0);
        const nozzle: Vec = at + body_down * splat(6.0);
        const jet: f32 = tilt + v.gimbal;
        const exhaust: Vec = nozzle + vec(@sin(jet), -@cos(jet), 0) * splat(6.0 + 26.0 * throttle);
        z.drawLine3D(gl, nozzle, exhaust, if (throttle > 0.7) flame_high else flame_low);
    }

    // * GUARDED, BECAUSE `1..0` IS AN INTEGER UNDERFLOW, NOT AN EMPTY RANGE. On the first frame
    // the trail is empty and `for (1..0)` traps in debug wasm - which is how this surfaced: it
    // ran fine in release on the host and died instantly in the smoke run.
    if (v.trail_count < 2) {
        return;
    }
    for (1..v.trail_count) |i| {
        z.drawLine3D(gl, v.trail[i - 1] + vec(0, 0, depth), v.trail[i] + vec(0, 0, depth), trail_colour);
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
    if (u.window("landing an engine you cannot switch off", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        u.text("throttle floor {d:.0}%% of weight —", .{100.0 * limits.min_thrust / weight});
        u.text("  coasting is not available.", .{});
        u.separator();

        report(u, "PD ", &s.pd);
        report(u, "MPC", &s.planner);
        u.separator();

        u.text("target: |vy|<0.5  |vx|<0.3  tilt<5deg", .{});
        u.text("4 starts: PD 0 of 4, MPC 4 of 4", .{});
        u.separator();

        _ = u.slider("start x", &s.start_x, .{ .min = -50, .max = 50, .fmt = "{d:.0}" });
        _ = u.slider("start altitude", &s.start_alt, .{ .min = 40, .max = 200, .fmt = "{d:.0}" });
        _ = u.slider("start descent", &s.start_vy, .{ .min = -50, .max = -5, .fmt = "{d:.0}" });
        if (u.button("LAUNCH DESCENT", .{})) {
            resetAll(s);
        }
        _ = u.checkbox("run", &s.running);
    }
    return captured;
}

fn report(u: ui.Ui, label: []const u8, v: *const Vehicle) void {
    if (v.down) {
        u.text("{s} DOWN  vy {d:>6.2}  vx {d:>6.2}  tilt {d:>6.3}", .{
            label, v.touchdown_vy, v.touchdown_vx, v.touchdown_tilt,
        });
        u.text("     {s}", .{if (v.good) "*** LANDED ***" else "crashed"});
        return;
    }
    u.text("{s} alt {d:>6.1}  vy {d:>6.2}  x {d:>6.1}", .{
        label,
        v.state[mpc.rocket_y_offset],
        v.state[mpc.rocket_vy_offset],
        v.state[mpc.rocket_x_offset],
    });
    // * THROTTLE IS THE MEASUREMENT THAT MATTERS RIGHT NOW. If the planner is not saturating
    // high in the last seconds, it does not think it needs to flare - a reference problem, not
    // a weights problem.
    const throttle: f32 = 100.0 * v.thrust / weight;
    u.text("     throttle {d:>5.0}%%{s}  gimbal {d:>6.3}  tilt {d:>6.3}", .{
        throttle,
        if (v.thrust >= 0.999 * limits.max_thrust)
            " MAX"
        else if (v.thrust <= 1.001 * limits.min_thrust)
            " MIN"
        else
            "    ",
        v.gimbal,
        v.state[mpc.rocket_tilt_offset],
    });
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - landing an engine you cannot switch off",
            .width = 960,
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
