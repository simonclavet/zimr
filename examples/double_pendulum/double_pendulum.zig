//! double_pendulum — the classic chaotic double pendulum, ported to WebGPU.
//! Two pendulums start 1e-3 rad apart in θ₂; identical at first, they diverge into
//! completely different trajectories — the canonical demo of sensitive dependence on
//! initial conditions. Each leaves a fading trail: a CPU ring buffer of recent rod-2
//! tip positions drawn as alpha-graded segments. (The GL original used a render
//! texture; the wgpu backend doesn't expose render textures yet, so the ring buffer
//! stands in.)
//!
//! Scale mode is `.responsive` (fill the canvas the host gives us, any aspect), so the
//! layout is derived from the LIVE viewport (`f.window.widthf()/heightf()`) every
//! frame — never a hardcoded design size. The render scale is decoupled from the
//! physics units, so the dynamics are identical regardless of canvas size.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const radFromDeg = zm.radFromDeg;
const float = zm.float;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const c = Color;

const simulation_steps: i32 = 30;
const length_scaler: f32 = 0.1;
const trail_len: usize = 360;

// Physics parameters (dynamics units — render scale is separate, see Layout).
const l1: f32 = 15.0;
const l2: f32 = 15.0;
const m1: f32 = 0.2;
const m2: f32 = 0.1;
const gravity: f32 = 9.81;

const Pendulum = struct {
    theta1: f32,
    theta2: f32,
    w1: f32 = 0,
    w2: f32 = 0,
    color: Color,
    trail: [trail_len]Vec2 = @splat(Vec2{ 0, 0 }),
    trail_n: usize = 0,
    head: usize = 0,
};

const State = struct {
    font: z.Font,
    a: Pendulum,
    b: Pendulum,
    frame_count: usize = 0,
};

// Render layout derived from the live viewport. `min(w,h)` sizes the rods so the
// full circular swing always fits on-screen, whatever the canvas aspect.
const Layout = struct {
    ox: f32,
    oy: f32,
    rod_px: f32,
    bob1: f32,
    bob2: f32,
    rod_thick: f32,
    trail_thick: f32,
};

fn computeLayout(f: *z.Frame) Layout {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const m: f32 = @min(w, h);
    return .{
        .ox = w * 0.5,
        .oy = h * 0.42,
        .rod_px = m * 0.19,
        .bob1 = m * 0.020 + 3.0,
        .bob2 = m * 0.014 + 3.0,
        .rod_thick = m * 0.016 + 1.0,
        .trail_thick = @max(1.5, m * 0.004),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    const theta1_0: f32 = radFromDeg(170.0);
    s.* = .{
        .font = font,
        .a = .{ .theta1 = theta1_0, .theta2 = 0.0, .color = c.init(90, 210, 235, 255) },
        .b = .{ .theta1 = theta1_0, .theta2 = 1.0e-3, .color = c.init(230, 110, 210, 255) },
    };
}

/// Advance one pendulum by `dt` using `simulation_steps` velocity-Verlet substeps.
fn stepPendulum(p: *Pendulum, dt: f32) void {
    const step: f32 = dt / float(simulation_steps);
    const step2: f32 = step * step;
    const big_l1: f32 = l1 * length_scaler;
    const big_l2: f32 = l2 * length_scaler;
    const total_m: f32 = m1 + m2;
    var i: i32 = 0;
    while (i < simulation_steps) : (i += 1) {
        const delta: f32 = p.theta1 - p.theta2;
        const sin_d: f32 = @sin(delta);
        const cos_d: f32 = @cos(delta);
        const cos_2d: f32 = @cos(2.0 * delta);
        const ww1: f32 = p.w1 * p.w1;
        const ww2: f32 = p.w2 * p.w2;
        const a1_num: f32 = -gravity * (2.0 * m1 + m2) * @sin(p.theta1) -
            m2 * gravity * @sin(p.theta1 - 2.0 * p.theta2) -
            2.0 * sin_d * m2 * (ww2 * big_l2 + ww1 * big_l1 * cos_d);
        const denom: f32 = 2.0 * m1 + m2 - m2 * cos_2d;
        const a1: f32 = a1_num / (big_l1 * denom);
        const a2_num: f32 = 2.0 * sin_d * (ww1 * big_l1 * total_m +
            gravity * total_m * @cos(p.theta1) +
            ww2 * big_l2 * m2 * cos_d);
        const a2: f32 = a2_num / (big_l2 * denom);
        p.theta1 += p.w1 * step + 0.5 * a1 * step2;
        p.theta2 += p.w2 * step + 0.5 * a2 * step2;
        p.w1 += a1 * step;
        p.w2 += a2 * step;
    }
}

/// Push the current rod-2 tip into the pendulum's ring-buffer trail.
fn pushTrail(p: *Pendulum, tip: Vec2) void {
    p.trail[p.head] = tip;
    p.head = (p.head + 1) % trail_len;
    if (p.trail_n < trail_len) {
        p.trail_n += 1;
    }
}

/// Rod-2 tip in screen space for pendulum `p` under layout `lay`.
fn tipOf(lay: Layout, p: *const Pendulum) Vec2 {
    const jx: f32 = lay.ox + lay.rod_px * @sin(p.theta1);
    const jy: f32 = lay.oy + lay.rod_px * @cos(p.theta1);
    return .{ jx + lay.rod_px * @sin(p.theta2), jy + lay.rod_px * @cos(p.theta2) };
}

fn drawPendulum(
    gl: anytype,
    lay: Layout,
    p: *const Pendulum,
) void {
    const o: Vec2 = .{ lay.ox, lay.oy };
    const jx: f32 = lay.ox + lay.rod_px * @sin(p.theta1);
    const jy: f32 = lay.oy + lay.rod_px * @cos(p.theta1);
    const joint: Vec2 = .{ jx, jy };
    const tip: Vec2 = .{ jx + lay.rod_px * @sin(p.theta2), jy + lay.rod_px * @cos(p.theta2) };

    // Trail: oldest -> newest, alpha graded so newer segments are brighter.
    if (p.trail_n > 1) {
        const start: usize = (p.head + trail_len - p.trail_n) % trail_len;
        var k: usize = 0;
        while (k + 1 < p.trail_n) : (k += 1) {
            const idx_a: usize = (start + k) % trail_len;
            const idx_b: usize = (start + k + 1) % trail_len;
            const num: f32 = float(k + 1);
            const den: f32 = float(p.trail_n);
            gl.line(
                p.trail[idx_a],
                p.trail[idx_b],
                .{ .color = p.color.fade(num / den), .thickness = lay.trail_thick },
            );
        }
    }

    // Rods + bobs.
    gl.line(o, joint, .{ .color = p.color.fade(0.85), .thickness = lay.rod_thick });
    gl.line(joint, tip, .{ .color = p.color.fade(0.85), .thickness = lay.rod_thick });
    gl.circle(joint, lay.bob1, .{ .color = p.color, .segments = 16 });
    gl.circle(tip, lay.bob2, .{ .color = p.color, .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const dt: f32 = f.time.delta_time;

    stepPendulum(&s.a, dt);
    stepPendulum(&s.b, dt);

    const lay: Layout = computeLayout(f);
    pushTrail(&s.a, tipOf(lay, &s.a));
    pushTrail(&s.b, tipOf(lay, &s.b));

    z.clearViewport(f, c.init(10, 12, 20, 255));
    drawPendulum(f.gl, lay, &s.a);
    drawPendulum(f.gl, lay, &s.b);
    f.gl.text(
        .{ 12, 12 },
        "double pendulum: two starts 1e-3 rad apart",
        .{ .size = 18, .color = c.init(228, 232, 240, 255), .font = &s.font },
    );
    f.gl.text(
        .{ 12, 34 },
        "identical, then chaos",
        .{ .size = 14, .color = c.init(138, 147, 168, 255), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            // 800x450 is the preferred-size hint (used as the design size on native /
            // .fit); under .responsive we fill whatever rectangle the host gives.
            .title = "zimr - WebGPU - double pendulum",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
