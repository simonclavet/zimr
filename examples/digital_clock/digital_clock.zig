//! digital_clock — a clock with two faces: a custom seven-segment digital readout and an
//! analog dial with sweeping hands. Both are ported faithfully from the raylib original (the
//! seven-segment glyphs are hand-built from hexagonal bar segments; the hands are rotated bars).
//! There is no wall-clock-of-day in the raylib original's sense, but zimr exposes z.localTime()
//! (real local time, DST-correct), so this shows the actual current time. Tap anywhere to switch
//! faces (raylib uses SPACE). From raylib shapes_digital_clock.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const sin = zm.sin;
const cos = zm.cos;
const clamp = zm.clamp;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// seven-segment patterns, bit A=0 .. G=6 (matches the raylib byte table)
const seg_patterns = [10]u8{ 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };
// per-segment centre (native units, relative to a digit's top-left) + orientation
const seg_cx = [7]f32{ 50, 90, 90, 50, 10, 10, 50 };
const seg_cy = [7]f32{ 20, 64, 152, 196, 152, 64, 108 };
const seg_vert = [7]bool{ false, true, true, false, true, true, false };
// native digit x-positions and colon-dot centres inside the HH:MM:SS block
const digit_x = [6]f32{ 0, 120, 260, 380, 520, 640 };
const colon_x = [2]f32{ 240, 500 };
const block_w = 740.0;
const block_h = 216.0;

const on_col: Color = .{ .r = 236, .g = 72, .b = 60, .a = 255 };
const off_col: Color = .{ .r = 54, .g = 58, .b = 70, .a = 255 };
const face_col: Color = .{ .r = 22, .g = 26, .b = 36, .a = 255 };
const tick_col: Color = .{ .r = 120, .g = 128, .b = 146, .a = 255 };

const State = struct {
    font: z.Font,
    digital: bool = true,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// One hexagonal seven-segment bar (a 6-vertex strip), horizontal or vertical.
fn drawSegment(
    gl: *z.WgpuGl,
    center: Vec2,
    len: f32,
    thick: f32,
    vertical: bool,
    color: Color,
) void {
    const hl: f32 = len * 0.5;
    const ht: f32 = thick * 0.5;
    var p: [6]Vec2 = undefined;
    if (vertical) {
        p = .{
            .{ 0, -hl - ht }, .{ -ht, -hl }, .{ ht, -hl },
            .{ -ht, hl },     .{ ht, hl },   .{ 0, hl + ht },
        };
    } else {
        p = .{
            .{ -hl - ht, 0 }, .{ -hl, ht }, .{ -hl, -ht },
            .{ hl, ht },      .{ hl, -ht }, .{ hl + ht, 0 },
        };
    }
    for (&p) |*pt| {
        pt.* = .{ center[0] + pt[0], center[1] + pt[1] };
    }
    gl.triangle(p[0], p[1], p[2], .{ .color = color });
    gl.triangle(p[1], p[2], p[3], .{ .color = color });
    gl.triangle(p[2], p[3], p[4], .{ .color = color });
    gl.triangle(p[3], p[4], p[5], .{ .color = color });
}

/// One digit at `pos` (top-left), scaled by `k`. Lit segments use `on`, dark ones `off`.
fn drawDigit(
    gl: *z.WgpuGl,
    pos: Vec2,
    value: usize,
    k: f32,
    on: Color,
    off: Color,
) void {
    const bits: u8 = seg_patterns[value];
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const center: Vec2 = .{ pos[0] + seg_cx[i] * k, pos[1] + seg_cy[i] * k };
        const lit: bool = ((bits >> @intCast(i)) & 1) != 0;
        drawSegment(gl, center, 60.0 * k, 20.0 * k, seg_vert[i], if (lit) on else off);
    }
}

fn drawDigital(f: *z.Frame, hms: [3]i64) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const k: f32 = clamp(@min(w * 0.92 / block_w, h * 0.62 / block_h), 0.1, 1.2);
    const x0: f32 = (w - block_w * k) * 0.5;
    const y0: f32 = (h - block_h * k) * 0.5;

    const digits = [6]usize{
        @intCast(@divFloor(hms[0], 10)), @intCast(@mod(hms[0], 10)),
        @intCast(@divFloor(hms[1], 10)), @intCast(@mod(hms[1], 10)),
        @intCast(@divFloor(hms[2], 10)), @intCast(@mod(hms[2], 10)),
    };
    for (digits, 0..) |d, i| {
        drawDigit(f.gl, .{ x0 + digit_x[i] * k, y0 }, d, k, on_col, off_col);
    }
    // colon dots blink with the seconds parity
    const blink: Color = if (@mod(hms[2], 2) == 0) on_col else off_col;
    for (colon_x) |cx| {
        f.gl.circle(.{ x0 + cx * k, y0 + 70.0 * k }, 12.0 * k, .{ .color = blink, .segments = 16 });
        f.gl.circle(.{ x0 + cx * k, y0 + 150.0 * k }, 12.0 * k, .{ .color = blink, .segments = 16 });
    }
}

fn handTip(center: Vec2, deg: f32, len: f32) Vec2 {
    const r: f32 = deg * rad_per_deg;
    return .{ center[0] + cos(r) * len, center[1] + sin(r) * len };
}

fn drawAnalog(f: *z.Frame, hms: [3]i64) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const center: Vec2 = .{ w * 0.5, h * 0.5 };
    const radius: f32 = @min(w, h) * 0.42;
    const ks: f32 = radius / 160.0;

    f.gl.circle(center, radius, .{ .color = face_col, .segments = 16 });

    // 60 minute/second ticks (every 5th is longer + thicker)
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const r: f32 = (6.0 * float(i) - 90.0) * rad_per_deg;
        const dir: Vec2 = .{ cos(r), sin(r) };
        const major: bool = (i % 5) == 0;
        const factor: f32 = if (major) 0.84 else 0.90;
        const inner: f32 = radius * factor;
        const outer: f32 = radius * 0.97;
        const a: Vec2 = .{ center[0] + dir[0] * inner, center[1] + dir[1] * inner };
        const b: Vec2 = .{ center[0] + dir[0] * outer, center[1] + dir[1] * outer };
        f.gl.line(a, b, .{ .color = tick_col, .thickness = if (major) 3.0 * ks else 1.0 * ks });
    }

    const hf: f32 = float(hms[0]);
    const mf: f32 = float(hms[1]);
    const sf: f32 = float(hms[2]);
    const hour_deg: f32 = @mod(hf, 12.0) * 30.0 + mf * 0.5 - 90.0;
    const min_deg: f32 = mf * 6.0 + sf * 0.1 - 90.0;
    const sec_deg: f32 = sf * 6.0 - 90.0;

    f.gl.line(center, handTip(center, hour_deg, radius * 0.5), .{ .color = co.palette.ink, .thickness = 7.0 * ks });
    f.gl.line(center, handTip(center, min_deg, radius * 0.72), .{ .color = co.palette.accent, .thickness = 5.0 * ks });
    f.gl.line(center, handTip(center, sec_deg, radius * 0.82), .{ .color = on_col, .thickness = 2.0 * ks });
    f.gl.circle(center, radius * 0.05, .{ .color = tick_col, .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, co.palette.bg);

    // real local wall-clock time (DST-correct), via z.localTime()
    const dt: z.DateTime = z.localTime();
    const hms = [3]i64{ dt.hour, dt.minute, dt.second };

    // tap toggles the face
    const down: bool = z.isMouseButtonDown(f.input, .left);
    const mouse: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = mouse;
        s.dragged = false;
    }
    if (down and zm.distance(mouse, s.press) > 8.0) {
        s.dragged = true;
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.digital = !s.digital;
    }

    if (s.digital) {
        drawDigital(f, hms);
    } else {
        drawAnalog(f, hms);
    }

    co.caption(f.gl, s.font, if (s.digital)
        "digital clock - tap to switch to the analog face"
    else
        "analog clock - tap to switch to the digital face");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - digital clock",
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
