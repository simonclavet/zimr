//! bullet_hell — a radial bullet spawner. Every few frames a ring of bullets fires outward from the
//! centre; the spawn angle creeps each volley so the rings braid into a spiral. A rotating "magic
//! circle" (two spinning squares + three rings) anchors the middle. Self-running; tap to cycle the
//! spiral pattern (row count / creep / speed). From raylib shapes_bullet_hell.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const common = @import("example_common");

const sinRad = zm.sinRad;
const cosRad = zm.cosRad;
const clamp = zm.clamp;
const distance = zm.distance;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const max_bullets = 3000;

const red: Color = .{ .r = 235, .g = 80, .b = 90, .a = 255 };
const blue: Color = .{ .r = 80, .g = 150, .b = 255, .a = 255 };
const purple: Color = .{ .r = 170, .g = 110, .b = 235, .a = 170 };

const Bullet = struct {
    pos: Vec2,
    vel: Vec2,
    color: Color,
    active: bool,
};

const Preset = struct {
    rows: i32,
    inc: f32,
    speed: f32,
};

const presets = [_]Preset{
    .{ .rows = 6, .inc = 5, .speed = 3.0 },
    .{ .rows = 12, .inc = 7, .speed = 2.6 },
    .{ .rows = 5, .inc = 11, .speed = 3.2 },
    .{ .rows = 8, .inc = 3, .speed = 2.4 },
    .{ .rows = 3, .inc = 23, .speed = 3.6 },
    .{ .rows = 18, .inc = 13, .speed = 2.2 },
};

const State = struct {
    font: z.Font,
    bullets: [max_bullets]Bullet,
    head: usize = 0,
    base_dir: f32 = 0,
    cooldown_timer: f32 = 0,
    magic_rot: f32 = 0,
    preset: usize = 0,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .bullets = @splat(.{ .pos = .{ 0, 0 }, .vel = .{ 0, 0 }, .color = red, .active = false }),
    };
}

fn spawnRing(s: *State, center: Vec2, scale: f32) void {
    const p: Preset = presets[s.preset];
    const deg_per_row: f32 = 360.0 / float(p.rows);
    var row: i32 = 0;
    while (row < p.rows) : (row += 1) {
        const rad: f32 = (s.base_dir + deg_per_row * float(row)) * rad_per_deg;
        s.bullets[s.head] = .{
            .pos = center,
            .vel = .{ cosRad(rad) * p.speed * scale, sinRad(rad) * p.speed * scale },
            .color = if (@mod(row, 2) == 0) red else blue,
            .active = true,
        };
        s.head = (s.head + 1) % max_bullets;
    }
    s.base_dir += p.inc;
    if (s.base_dir >= 360.0) {
        s.base_dir -= 360.0;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const center: Vec2 = .{ w * 0.5, h * 0.5 };
    const scale: f32 = @min(w, h) / 450.0;
    const radius: f32 = 9.0 * scale;
    const step: f32 = clamp(f.time.delta_time * 60.0, 0.0, 3.0); // 60fps-equivalent frames
    z.clearViewport(f, common.palette.bg);

    // --- input: tap cycles the spiral preset (edge-triggered; no was_down bookkeeping) ---
    const m: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = m;
        s.dragged = false;
    }
    if (z.isMouseButtonDown(f.input, .left) and distance(m, s.press) > 8.0) {
        s.dragged = true;
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.preset = (s.preset + 1) % presets.len;
    }

    // --- spawn volleys ---
    s.cooldown_timer -= step;
    if (s.cooldown_timer <= 0) {
        s.cooldown_timer += 2.0; // 2 frames between volleys
        spawnRing(s, center, scale);
    }

    // --- advance bullets, retire off-screen ---
    const margin: f32 = radius * 2.0;
    var i: usize = 0;
    while (i < max_bullets) : (i += 1) {
        if (!s.bullets[i].active) {
            continue;
        }
        s.bullets[i].pos[0] += s.bullets[i].vel[0] * step;
        s.bullets[i].pos[1] += s.bullets[i].vel[1] * step;
        const p: Vec2 = s.bullets[i].pos;
        if (p[0] < -margin or p[0] > w + margin or p[1] < -margin or p[1] > h + margin) {
            s.bullets[i].active = false;
        }
    }

    drawScene(f, s, center, scale, radius);
    common.caption(f.gl, s.font, "bullet hell - tap to change the spiral pattern");
    z.endDrawing(f.gl);
}

fn drawScene(
    f: *z.Frame,
    s: *State,
    center: Vec2,
    scale: f32,
    radius: f32,
) void {
    const gl = f.gl;
    // magic circle (under the bullets)
    s.magic_rot += clamp(f.time.delta_time * 60.0, 0.0, 3.0);
    const sq: f32 = 120.0 * scale;
    const half: f32 = sq * 0.5;
    const rec: z.Rectangle = .{ .x = center[0], .y = center[1], .width = sq, .height = sq };
    gl.rectRotated(rec, .{ half, half }, radFromDeg(s.magic_rot), .{ .color = purple });
    gl.rectRotated(rec, .{ half, half }, radFromDeg(s.magic_rot + 45.0), .{ .color = purple });
    gl.circle(center, 70.0 * scale, .{ .color = common.palette.ink_dim, .outline = 1 });
    gl.circle(center, 50.0 * scale, .{ .color = common.palette.ink_dim, .outline = 1 });
    gl.circle(center, 30.0 * scale, .{ .color = common.palette.ink_dim, .outline = 1 });

    // bullets
    var i: usize = 0;
    while (i < max_bullets) : (i += 1) {
        if (!s.bullets[i].active) {
            continue;
        }
        gl.circle(s.bullets[i].pos, radius, .{ .color = s.bullets[i].color, .segments = 16 });
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - bullet hell",
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
