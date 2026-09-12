//! robot_pendulum — the first thing `src/robot.zig` can draw.
//!
//! A double pendulum, simulated in GENERALIZED COORDINATES: the whole machine is two
//! numbers (two hinge angles) plus their velocities. There are no constraints to enforce
//! and nothing to converge — the links cannot come apart, because the freedom to come
//! apart was never represented.
//!
//! It is a good first demo for a reason beyond being easy. A double pendulum is chaotic,
//! so a mass matrix or a bias force that is subtly wrong does not produce a subtly wrong
//! swing; it produces motion that is visibly not a pendulum. And with no damping and no
//! contact, total mechanical energy must be conserved — so the HUD shows the drift, which
//! is a live readout of how good the integrator is.
//!
//! Tap to re-throw from a new pose. The button switches integrator, which makes the point
//! of the energy readout obvious: RK4 holds the line, Euler leaks.
//!
//! Deliberately minimal, and it should stay that way. New scenes belong in a scene table,
//! not bolted onto the demo whose job is to be the simplest thing that exercises the whole
//! pipeline. See src/notes/robot_port_plan.md section 4b.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// zm decls bound at file scope (the linter wants no qualified `zm.x` inside fn bodies).
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const vec = zm.vec;
const vec2 = zm.vec2;
const rotate = zm.rotate;
const float = zm.float;
const pi = zm.pi;
const assertUnreachable = zm.assertUnreachable;

/// The model. Two links hanging along −Y, hinged about Z, so the whole thing swings in the
/// screen plane and can be drawn in 2D without a camera.
///
/// `damping = 0` is deliberate: a conserved quantity is only informative when it is
/// actually conserved, and the energy readout is the point of the demo.
const Pendulum = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = upper_half, .radius = 0.05 } },
                .pos = vec(0, -upper_half, 0),
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -2.0 * upper_half, 0),
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = lower_half, .radius = 0.04 } },
                .pos = vec(0, -lower_half, 0),
            }},
        },
    },
    .options = .{ .timestep = 1.0 / 240.0 },
});

const upper_half: f32 = 0.25;
const lower_half: f32 = 0.20;

/// Metres to pixels. The pendulum is about 0.9 m tall, so this keeps it comfortably on a
/// phone screen in portrait.
const scale: f32 = 260.0;

// zimr's dark-warm palette, so the demo looks like the rest of the tree.
const bg: Color = .{ .r = 31, .g = 20, .b = 14, .a = 255 };
const upper_color: Color = .{ .r = 211, .g = 95, .b = 51, .a = 255 };
const lower_color: Color = .{ .r = 79, .g = 179, .b = 165, .a = 255 };
const trail_color: Color = .{ .r = 79, .g = 179, .b = 165, .a = 90 };
const text_color: Color = .{ .r = 240, .g = 230, .b = 210, .a = 255 };
const dim_color: Color = .{ .r = 168, .g = 150, .b = 132, .a = 255 };
const panel_color: Color = .{ .r = 51, .g = 34, .b = 24, .a = 255 };

/// How many past tip positions to draw. Enough to show the shape of the motion, short
/// enough that a chaotic path stays readable rather than filling the screen.
const trail_len: usize = 220;

const State = struct {
    model: rbt.Model,
    data: rbt.Data,
    font: z.Font,

    /// Energy at the moment of the last throw, so the HUD can show DRIFT rather than an
    /// absolute number nobody can calibrate against.
    energy0: f32,
    /// Ring buffer of tip positions, in world metres.
    trail: [trail_len]Vec2,
    trail_n: usize,
    /// Simulated seconds since the last throw — the axis the drift should be read against.
    elapsed: f32,
    /// Advances the fixed-timestep loop independently of frame rate.
    accumulator: f32,
    /// Cycled by the button; also relabels the readout.
    integrator: rbt.Integrator,

    fn throwFrom(self: *State, shoulder: f32, elbow: f32) void {
        self.data.reset(&self.model);
        self.data.setJointPos(&self.model, Pendulum.Joint.shoulder, shoulder);
        self.data.setJointPos(&self.model, Pendulum.Joint.elbow, elbow);
        // `forward` so the energy baseline and the first frame's drawing both see a state
        // whose derived quantities are current. Without it `energy` would read a stale
        // mass matrix — the imperative pipeline being imperative.
        rbt.forward(&self.model, &self.data);
        self.energy0 = rbt.energy(&self.model, &self.data);
        self.trail_n = 0;
        self.elapsed = 0;
        self.accumulator = 0;
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .model = try Pendulum.build(gpa),
        .data = undefined,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .energy0 = 0,
        .trail = @splat(vec2(0, 0)),
        .trail_n = 0,
        .elapsed = 0,
        .accumulator = 0,
        .integrator = .rk4,
    };
    s.data = try rbt.Data.init(gpa, &s.model);
    s.throwFrom(2.2, -1.4);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.data.deinit();
    s.model.deinit();
}

/// World metres to screen pixels. The pivot sits a third of the way down so a full swing
/// stays in frame.
fn toScreen(w: f32, h: f32, p: Vec2) Vec2 {
    return vec2(w * 0.5 + p[0] * scale, h * 0.34 - p[1] * scale);
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const w: f32 = float(f.window.screen_width);
    const h: f32 = float(f.window.screen_height);

    // Fixed-timestep integration, decoupled from the frame rate so the physics is the same
    // on a 60 Hz phone and a 120 Hz one. Capped so a long stall cannot spiral.
    s.model.opt.integrator = s.integrator;
    const dt: f32 = s.model.opt.timestep;
    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= dt) : (s.accumulator -= dt) {
        rbt.step(&s.model, &s.data);
        s.elapsed += dt;
    }

    // `step` leaves the derived quantities describing the state BEFORE the last step, so
    // bring them up to date before drawing or measuring anything.
    rbt.forward(&s.model, &s.data);

    // ---- geometry, straight out of the engine ----
    const bi_lower: usize = 2;
    const pivot: Vec2 = vec2(0, 0);
    const elbow: Vec2 = vec2(s.data.body_xpos[bi_lower][0], s.data.body_xpos[bi_lower][1]);
    // The tip is the far end of the lower link, which is its body origin plus its own
    // length along the link's local −Y. Asking the engine where a point on a body is, is
    // exactly what a site would be for; for one point, this is cheaper than a site.
    const tip_local: Vec = vec(0, -2.0 * lower_half, 0);
    const tip_world: Vec = s.data.body_xpos[bi_lower] + rotate(s.data.body_xrot[bi_lower], tip_local);
    const tip: Vec2 = vec2(tip_world[0], tip_world[1]);

    s.trail[s.trail_n % trail_len] = tip;
    s.trail_n += 1;

    // ---- draw ----
    z.clearViewport(f, bg);

    // The trail first, so the links sit on top of it.
    const shown: usize = @min(s.trail_n, trail_len);
    var k: usize = 1;
    while (k < shown) : (k += 1) {
        const oldest: usize = if (s.trail_n > trail_len) s.trail_n - trail_len else 0;
        const a: Vec2 = s.trail[(oldest + k - 1) % trail_len];
        const b: Vec2 = s.trail[(oldest + k) % trail_len];
        gl.line(toScreen(w, h, a), toScreen(w, h, b), .{ .color = trail_color, .thickness = 2 });
    }

    gl.line(toScreen(w, h, pivot), toScreen(w, h, elbow), .{ .color = upper_color, .thickness = 10 });
    gl.line(toScreen(w, h, elbow), toScreen(w, h, tip), .{ .color = lower_color, .thickness = 8 });
    gl.circle(toScreen(w, h, pivot), 7, .{ .color = dim_color });
    gl.circle(toScreen(w, h, elbow), 6, .{ .color = upper_color });
    gl.circle(toScreen(w, h, tip), 7, .{ .color = lower_color });

    // ---- readout ----
    // Energy drift is the honest measure of a closed system's integration: with no damping
    // and no contact it MUST be conserved, so whatever this shows is the integrator's.
    const now: f32 = rbt.energy(&s.model, &s.data);
    const drift: f32 = if (@abs(s.energy0) > 1.0e-6)
        (now - s.energy0) / @abs(s.energy0) * 100.0
    else
        0.0;

    var buf: [128]u8 = undefined;
    // Only `.rk4` and `.euler` are reachable — the toggle below flips between those two. The
    // other arms exist because this switch is EXHAUSTIVE ON PURPOSE: `.implicit` was added to
    // `rbt.Integrator` and broke this line, which is the behaviour we want. An `else` here
    // would have compiled and then shown the wrong name forever.
    const label: []const u8 = switch (s.integrator) {
        .rk4 => "RK4",
        .euler => "semi-implicit Euler",
        .implicit => "implicit",
        .implicitfast => "implicit (fast)",
    };
    const line: []const u8 = bufPrint(
        &buf,
        "{s}  |  t = {d:.1} s  |  energy drift {c}{d:.3} %",
        .{ label, s.elapsed, @as(u8, if (drift < 0) '-' else '+'), @abs(drift) },
    ) catch "readout unavailable";
    gl.text(vec2(16, 24), line, .{ .size = 18, .color = text_color, .font = &s.font });
    gl.text(
        vec2(16, 48),
        "two numbers describe this machine - tap to re-throw",
        .{ .size = 14, .color = dim_color, .font = &s.font },
    );

    // A hand-rolled toggle rather than the UI framework: this demo's job is to be the
    // smallest thing that exercises the whole pipeline, and one hit-tested rectangle is
    // less to read than a widget system.
    const toggle: z.Rectangle = .{ .x = 16, .y = h - 62, .width = 210, .height = 44 };
    gl.rect(toggle, .{ .color = panel_color });
    gl.text(
        vec2(toggle.x + 14, toggle.y + 27),
        if (s.integrator == .rk4) "integrator: RK4" else "integrator: Euler",
        .{ .size = 16, .color = text_color, .font = &s.font },
    );

    if (z.isMouseButtonPressed(f.input, .left)) {
        const p: Vec2 = z.getMousePosition(f.input);
        const on_toggle: bool = p[0] >= toggle.x and p[0] <= toggle.x + toggle.width and
            p[1] >= toggle.y and p[1] <= toggle.y + toggle.height;
        if (on_toggle) {
            // Re-throw from the same pose so the two integrators are compared on identical
            // initial conditions -- otherwise the energy readout means nothing.
            s.integrator = if (s.integrator == .rk4) .euler else .rk4;
            s.throwFrom(2.2, -1.4);
        } else {
            // Tap elsewhere to re-throw from a pose that depends on where you tapped, so
            // the chaos is something to play with rather than watch.
            s.throwFrom(pi * (p[0] / w) * 2.0 - pi, pi * (p[1] / h) * 2.0 - pi);
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - robot: double pendulum",
            .width = 520,
            .height = 900,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};

comptime {
    // The whole point of the demo: this machine is TWO numbers.
    if (Pendulum.nv != 2) {
        @compileError("robot_pendulum expects a 2-DOF model");
    }
    _ = assertUnreachable;
}
