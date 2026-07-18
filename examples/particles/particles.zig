// examples/particles/particles.zig
//
// A CPU particle fountain on WebGPU with a REAL ui.zig control panel. Particles
// spawn from an emitter (drag with the mouse on the canvas), fall under gravity,
// fade out. The ImGui window controls emission rate, gravity, and particle size,
// plus a reset button — proving "scene + real Dear ImGui" on the wgpu backend
// (the pattern every ported UI example follows: scene draw via gl: anytype, UI
// via z.UiHost).
//
// Build:      zig build wgpu-particles
// Standalone: zig build wgpu-particles-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const pi = zm.pi;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const width: u32 = 900;
const height: u32 = 600;
const max_particles: usize = 4000;

const Particle = struct {
    pos: Vec2,
    vel: Vec2,
    life: f32, // 1 -> 0
    radius: f32,
    color: Color,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    particles: [max_particles]Particle,
    count: usize,
    emitter: Vec2,
    rng: std.Random.DefaultPrng,
    // UI-controlled:
    rate: f32,
    gravity: f32,
    size: f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .particles = undefined,
        .count = 0,
        .emitter = .{ @as(f32, width) * 0.5, @as(f32, height) * 0.35 },
        .rng = std.Random.DefaultPrng.init(0x1234),
        .rate = 12,
        .gravity = 320,
        .size = 4,
    };
}

fn spawn(s: *State) void {
    if (s.count >= max_particles) {
        return;
    }
    const r: std.Random = s.rng.random();
    const ang: f32 = -pi * 0.5 + (r.float(f32) - 0.5) * 1.2;
    const speed: f32 = 120 + r.float(f32) * 180;
    s.particles[s.count] = .{
        .pos = s.emitter,
        .vel = .{ @cos(ang) * speed, @sin(ang) * speed },
        .life = 1.0,
        .radius = s.size * (0.6 + r.float(f32) * 0.8),
        .color = Color.fromFloats(
            (150 + r.float(f32) * 105) / 255.0,
            (80 + r.float(f32) * 120) / 255.0,
            (200 + r.float(f32) * 55) / 255.0,
            1.0,
        ),
    };
    s.count += 1;
}

fn update(f: *z.Frame, s: *State) void {
    // Clamp dt: a tab-switch / hitch makes delta_time spike to seconds,
    // flinging every particle off-screen in one step (the "vanish then black"
    // bug). Cap at ~1/30s so the sim stays sane after any stall.
    const dt: f32 = @min(f.time.delta_time, 1.0 / 30.0);

    // Drag the emitter with LMB on the canvas (gated below the UI panel).
    const mouse: Vec2 = z.getMousePosition(f.input);
    const over_panel: bool = mouse[0] < 300 and mouse[1] < 220;
    if (z.isMouseButtonDown(f.input, .left) and !over_panel) {
        s.emitter = mouse;
    }

    // Emit.
    var to_emit: i32 = @trunc(s.rate);
    while (to_emit > 0) : (to_emit -= 1) {
        spawn(s);
    }

    // Integrate + compact (remove dead).
    var i: usize = 0;
    while (i < s.count) {
        const p: *Particle = &s.particles[i];
        p.vel[1] += s.gravity * dt;
        p.pos[0] += p.vel[0] * dt;
        p.pos[1] += p.vel[1] * dt;
        p.life -= dt * 0.6;
        if (p.life <= 0 or p.pos[1] > @as(f32, height) + 40) {
            s.particles[i] = s.particles[s.count - 1];
            s.count -= 1;
        } else {
            i += 1;
        }
    }

    z.clearViewport(f, .{ .r = 10, .g = 11, .b = 18, .a = 255 });

    // Draw particles (fade alpha with life).
    var j: usize = 0;
    while (j < s.count) : (j += 1) {
        const p = s.particles[j];
        const col = p.color.fade(p.life);
        f.gl.circle(p.pos, p.radius, .{ .color = col, .segments = 16 });
    }
    // Emitter marker.
    f.gl.circle(s.emitter, 5, .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 200 }, .segments = 16 });

    // ---- real ImGui control panel ----
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    if (ui.window("Particles", .{ .initial_pos = .{ 14, 14 }, .initial_size = .{ 280, 200 } })) |w| {
        defer w.close();
        ui.text("alive: {d}", .{s.count});
        ui.text("drag LMB to move emitter", .{});
        ui.separator();
        _ = ui.slider("rate", &s.rate, .{ .min = 0, .max = 40 });
        _ = ui.slider("gravity", &s.gravity, .{ .min = -200, .max = 800 });
        _ = ui.slider("size", &s.size, .{ .min = 1, .max = 12 });
        if (ui.button("clear", .{})) {
            s.count = 0;
        }
    }
    s.ui_host.render(f);

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - particles + real ImGui",
            .width = width,
            .height = height,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
