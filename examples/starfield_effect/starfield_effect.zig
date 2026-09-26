//! starfield_effect - the "warp speed" starfield with a live control panel.
//! DESCRIPTOR-ONLY (P2): the file exposes `pub const app = z.AppSpec(State){...}`
//! and nothing else - no `main`, no `zimr_app`, no `std_options` (those live in
//! the runner, which owns the wasm entry + the frame). `update` draws into the
//! Frame's viewport in LOCAL coords (reads f.window for its size, paints its own
//! background) and never opens/clears/closes the frame - so the SAME body runs
//! full-screen via the standalone runner OR inside a launcher cell unchanged.
//!
//! 420 stars stream outward from the centre via a 1/z perspective divide; two
//! render modes (lines = streaks / circles = discs) + a z.UiHost "Warp drive"
//! panel (speed/mode/trail/colour + Hyperjump). Responsive at any size.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const clamp = zm.clamp;
const ui = z.ui_real;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const num_stars: usize = 420;

const Star = struct {
    x: f32,
    y: f32,
    z: f32,
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    rng: std.Random.DefaultPrng,
    stars: [num_stars]Star = @splat(.{ .x = 0, .y = 0, .z = 1 }),
    speed: f32 = 10.0 / 9.0,
    draw_lines: bool = true,
    trail_age: f32 = 1.0 / 32.0,
    star_color: [3]f32 = .{ 245.0 / 255.0, 245.0 / 255.0, 245.0 / 255.0 },
};

fn randf(
    rand: std.Random,
    low: f32,
    high: f32,
) f32 {
    return low + rand.float(f32) * (high - low);
}

fn respawn(
    star: *Star,
    rand: std.Random,
    hw: f32,
    hh: f32,
) void {
    star.x = randf(rand, -hw, hw);
    star.y = randf(rand, -hh, hh);
    star.z = 1.0;
}

fn init(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .rng = std.Random.DefaultPrng.init(0xC0DECAFE),
    };
    const rand: std.Random = s.rng.random();
    const hw: f32 = @max(1.0, f.window.widthf() * 0.5);
    const hh: f32 = @max(1.0, f.window.heightf() * 0.5);
    for (&s.stars) |*star| {
        respawn(star, rand, hw, hh);
        star.z = randf(rand, 0.1, 1.0);
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn drawUiPanel(
    f: *z.Frame,
    s: *State,
    rand: std.Random,
    hw: f32,
    hh: f32,
) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Warp drive", .{ .initial_pos = .{ 16, 16 } })) |w| {
        defer w.close();

        _ = u.slider("Speed", &s.speed, .{ .min = 0.1, .max = 2.0, .fmt = "{d:.2}" });
        _ = u.checkbox("Lines (vs circles)", &s.draw_lines);
        if (s.draw_lines) {
            _ = u.slider("Trail length", &s.trail_age, .{ .min = 0.001, .max = 0.20, .fmt = "{d:.3}" });
        }
        _ = u.colorEdit("Star colour", &s.star_color, .{});
        u.separator();

        if (u.button("Hyperjump", .{})) {
            for (&s.stars) |*star| {
                respawn(star, rand, hw, hh);
                star.z = 0.1 + rand.float(f32) * 0.9;
            }
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const hw: f32 = w * 0.5;
    const hh: f32 = h * 0.5;
    const rand: std.Random = s.rng.random();

    // Paint our own background (fills our viewport - works full-screen or in a
    // cell). The runner/launcher already opened the frame; we don't clear it.
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = c.init(0, 25, 53, 255) });

    const star_col: Color = c.init(
        @round(s.star_color[0] * 255.0),
        @round(s.star_color[1] * 255.0),
        @round(s.star_color[2] * 255.0),
        255,
    );

    for (&s.stars) |*star| {
        star.z -= dt * s.speed;
        var sx: f32 = hw + star.x / star.z;
        var sy: f32 = hh + star.y / star.z;
        if (star.z < 0.0 or sx < 0.0 or sy < 0.0 or sx > w or sy > h) {
            respawn(star, rand, hw, hh);
            sx = hw + star.x / star.z;
            sy = hh + star.y / star.z;
        }

        if (s.draw_lines) {
            const t: f32 = clamp(star.z + s.trail_age, 0.0, 1.0);
            if ((t - star.z) > 1e-3) {
                const px: f32 = hw + star.x / t;
                const py: f32 = hh + star.y / t;
                f.gl.line(.{ px, py }, .{ sx, sy }, .{ .color = star_col, .thickness = 1.5 });
            }
        } else {
            const radius: f32 = star.z * 1.0 + (1.0 - star.z) * 5.0;
            f.gl.circle(.{ sx, sy }, radius, .{ .color = star_col, .segments = 16 });
        }
    }

    var buf: [32]u8 = undefined;
    const fps: i32 = if (dt > 0.0) @trunc(1.0 / dt) else 0;
    const label: []const u8 = bufPrint(&buf, "{d} FPS", .{fps}) catch "?";
    f.gl.text(.{ 10, 10 }, label, .{ .size = 20, .color = c.lime, .font = &s.font });

    drawUiPanel(f, s, rand, hw, hh);
}

/// The whole example, as data. No globals, no main - the runner/launcher drives it.
pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - starfield effect",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
        .depth_format = null,
    } },
    .init = init,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
