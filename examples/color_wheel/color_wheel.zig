//! color_wheel — an HSV colour wheel drawn as a fan of triangles (rim = full-saturation hue,
//! hub = the value/grey), with a draggable picker and a value slider. Drag inside the wheel to pick
//! a hue+saturation; drag the bar to set value. The selected colour shows as a swatch with its hex.
//! A port of raylib's rlgl colour wheel (its rlBegin/rlColor/rlVertex fan -> drawTriangleGradient).
//! From raylib shapes_rlgl_color_wheel.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const sinRad = zm.sinRad;
const cosRad = zm.cosRad;
const atan2Rad = zm.atan2Rad;
const clamp = zm.clamp;
const tau = zm.tau;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;

const triangle_count = 120;

const mode_none = 0;
const mode_wheel = 1;
const mode_slider = 2;

const State = struct {
    font: z.Font,
    hue: f32 = 0, // 0..360
    sat: f32 = 0, // 0..1
    value: f32 = 1, // 0..1
    mode: u8 = mode_none,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

const Layout = struct {
    center: Vec2,
    radius: f32,
    sx0: f32,
    sx1: f32,
    sy: f32,
};

fn layoutOf(f: *z.Frame) Layout {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    return .{
        .center = .{ w * 0.5, h * 0.46 },
        .radius = @min(w * 0.42, h * 0.34),
        .sx0 = w * 0.18,
        .sx1 = w * 0.82,
        .sy = h - 48.0,
    };
}

fn dirOf(hue_deg: f32) Vec2 {
    const r: f32 = hue_deg * rad_per_deg;
    return .{ sinRad(r), -cosRad(r) };
}

fn selectedColor(s: *State) Color {
    const grey: Color = z.colorFromHSV(0, 0, s.value);
    const pure: Color = z.colorFromHSV(s.hue, s.sat, 1.0);
    return Color.lerp(grey, pure, s.sat);
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, common.palette.bg);
    const lay: Layout = layoutOf(f);

    const down: bool = z.isMouseButtonDown(f.input, .left);
    const m: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        const on_slider: bool = (m[0] >= lay.sx0 - 12 and m[0] <= lay.sx1 + 12 and
            m[1] >= lay.sy - 18 and m[1] <= lay.sy + 18);
        if (on_slider) {
            s.mode = mode_slider;
        } else if (zm.distance(m, lay.center) <= lay.radius + 12) {
            s.mode = mode_wheel;
        } else {
            s.mode = mode_none;
        }
    }
    if (down and s.mode == mode_wheel) {
        const off: Vec2 = .{ m[0] - lay.center[0], m[1] - lay.center[1] };
        s.sat = clamp(zm.length(off) / lay.radius, 0.0, 1.0);
        var a: f32 = atan2Rad(off[0], -off[1]); // 0 at top, clockwise
        if (a < 0) {
            a += tau;
        }
        s.hue = a / rad_per_deg;
    }
    if (down and s.mode == mode_slider) {
        s.value = clamp((m[0] - lay.sx0) / (lay.sx1 - lay.sx0), 0.0, 1.0);
    }
    if (!down) {
        s.mode = mode_none;
    }

    drawWheel(f, lay, s.value);

    // picker handle
    const handle: Vec2 = .{
        lay.center[0] + dirOf(s.hue)[0] * lay.radius * s.sat,
        lay.center[1] + dirOf(s.hue)[1] * lay.radius * s.sat,
    };
    const handle_col: Color = if (s.sat <= 0.5 and s.value <= 0.5) common.palette.ink_dim else common.palette.ink;
    f.gl.circle(handle, 6.0, .{ .color = handle_col, .outline = 1 });

    // value slider: a rounded track + a knob tinted with the current value
    f.gl.rectRoundedXYWH(lay.sx0, lay.sy - 6, lay.sx1 - lay.sx0, 12, 1.0, 8, .{ .color = common.palette.surface });
    const kx: f32 = lay.sx0 + s.value * (lay.sx1 - lay.sx0);
    f.gl.circle(.{ kx, lay.sy }, 11, .{ .color = z.colorFromHSV(0, 0, s.value), .segments = 16 });
    f.gl.circle(.{ kx, lay.sy }, 11, .{ .color = common.palette.ink, .outline = 1 });

    drawSwatch(f, s);
    z.endDrawing(f.gl);
}

fn drawWheel(f: *z.Frame, lay: Layout, value: f32) void {
    const hub: Color = z.colorFromHSV(0, 0, value);
    const step: f32 = tau / float(triangle_count);
    var i: usize = 0;
    while (i < triangle_count) : (i += 1) {
        const a0: f32 = step * float(i);
        const a1: f32 = step * float(i + 1);
        const p0: Vec2 = .{ lay.center[0] + sinRad(a0) * lay.radius, lay.center[1] - cosRad(a0) * lay.radius };
        const p1: Vec2 = .{ lay.center[0] + sinRad(a1) * lay.radius, lay.center[1] - cosRad(a1) * lay.radius };
        const c0: Color = z.colorFromHSV(a0 / rad_per_deg, 1.0, 1.0);
        const c1: Color = z.colorFromHSV(a1 / rad_per_deg, 1.0, 1.0);
        f.gl.triangleGradient(p0, lay.center, p1, c0, hub, c1);
    }
}

fn drawSwatch(f: *z.Frame, s: *State) void {
    const color: Color = selectedColor(s);
    f.gl.rect(.{ .x = 12, .y = 12, .width = 64, .height = 64 }, .{ .color = color });
    f.gl.rect(
        .{ .x = 12, .y = 12, .width = 64, .height = 64 },
        .{ .color = Color.lerp(color, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, 0.5), .outline = 1.0 },
    );
    var buf: [48]u8 = undefined;
    const hex: []const u8 = bufPrint(
        &buf,
        "#{X:0>2}{X:0>2}{X:0>2}  ({d}, {d}, {d})",
        .{ color.r, color.g, color.b, color.r, color.g, color.b },
    ) catch "";
    f.gl.text(.{ 12, 84 }, hex, .{ .size = 18, .color = common.palette.ink, .font = &s.font });
    common.caption(f.gl, s.font, "colour wheel - drag the wheel to pick hue/saturation, the bar for value");
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - color wheel",
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
