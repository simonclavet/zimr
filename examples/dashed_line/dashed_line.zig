//! dashed_line — a dashed line whose endpoint follows the pointer (drag to aim; when
//! idle the endpoint orbits so the demo stays alive). The dash and gap lengths breathe on
//! sines so the dashing is visibly parametric, and a tap cycles the line colour (it also
//! auto-advances). A translucent panel reads back the live dash/space values. Ported from
//! raylib examples/shapes/shapes_dashed_line.c (the desktop original aimed at the mouse and
//! changed dash/space with the arrow keys); touch-first on mobile.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const bufPrint = std.fmt.bufPrint;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// raylib's palette for this sample (RED, ORANGE, GOLD, GREEN, BLUE, VIOLET, PINK, SKYBLUE).
const line_colors = [_]Color{
    .{ .r = 230, .g = 41, .b = 55, .a = 255 },
    .{ .r = 255, .g = 161, .b = 0, .a = 255 },
    .{ .r = 255, .g = 203, .b = 0, .a = 255 },
    .{ .r = 0, .g = 228, .b = 48, .a = 255 },
    .{ .r = 0, .g = 121, .b = 241, .a = 255 },
    .{ .r = 135, .g = 60, .b = 190, .a = 255 },
    .{ .r = 255, .g = 109, .b = 194, .a = 255 },
    .{ .r = 102, .g = 191, .b = 255, .a = 255 },
};

const State = struct {
    font: z.Font,
    time: f32 = 0,
    color_index: usize = 0,
    auto_timer: f32 = 0,
    end: Vec2 = .{ 0, 0 },
};

/// Walk a→b in dash+gap periods, drawing one thick segment per period. The final dash is
/// clamped to the segment end so the line never overshoots.
fn drawDashedLine(
    gl: *z.WgpuGl,
    a: Vec2,
    b: Vec2,
    dash: f32,
    gap: f32,
    thick: f32,
    color: Color,
) void {
    const dx: f32 = b[0] - a[0];
    const dy: f32 = b[1] - a[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len < 1.0e-4) {
        return;
    }
    const ux: f32 = dx / len;
    const uy: f32 = dy / len;
    const period: f32 = dash + gap;
    var t: f32 = 0;
    while (t < len) : (t += period) {
        const d_end: f32 = @min(t + dash, len);
        const p0: Vec2 = .{ a[0] + ux * t, a[1] + uy * t };
        const p1: Vec2 = .{ a[0] + ux * d_end, a[1] + uy * d_end };
        gl.line(p0, p1, .{ .color = color, .thickness = thick });
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    s.time += dt;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    // Tap cycles the colour; it also auto-advances every few seconds so an untouched demo
    // keeps moving through the palette.
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.color_index = (s.color_index + 1) % line_colors.len;
    }
    s.auto_timer += dt;
    if (s.auto_timer >= 2.5) {
        s.auto_timer = 0;
        s.color_index = (s.color_index + 1) % line_colors.len;
    }

    // Endpoint: follow the pointer while held, otherwise orbit a point on the right.
    const start: Vec2 = .{ 0.07 * w, 0.16 * h };
    if (z.isMouseButtonDown(f.input, .left)) {
        s.end = z.getMousePosition(f.input);
    } else {
        const cx: f32 = 0.68 * w;
        const cy: f32 = 0.62 * h;
        const rad: f32 = 0.22 * @min(w, h);
        s.end = .{ cx + rad * @cos(s.time * 0.6), cy + rad * @sin(s.time * 0.6) };
    }

    // Dash and gap breathe so the parameterisation is visible (the desktop original tied
    // these to the arrow keys).
    const dash: f32 = 22.0 + 12.0 * @sin(s.time * 0.7);
    const gap: f32 = 14.0 + 6.0 * @sin(s.time * 0.5 + 1.0);
    const col: Color = line_colors[s.color_index];

    drawDashedLine(f.gl, start, s.end, dash, gap, 4.0, col);
    f.gl.circle(start, 5.0, .{ .color = col, .segments = 16 });
    f.gl.circle(s.end, 5.0, .{ .color = col, .segments = 16 });

    // Read-out panel (translucent surface + border), echoing raylib's controls box.
    const panel: Color = .{ .r = 20, .g = 24, .b = 34, .a = 200 };
    const border: Color = .{ .r = 90, .g = 200, .b = 230, .a = 180 };
    f.gl.rect(.{ .x = 10, .y = 40, .width = 250, .height = 78 }, .{ .color = panel });
    f.gl.rect(.{ .x = 10, .y = 40, .width = 250, .height = 78 }, .{ .color = border, .outline = 1.0 });

    var buf: [96]u8 = undefined;
    const readout: []const u8 = bufPrint(
        &buf,
        "Dash: {d:.0}  |  Space: {d:.0}",
        .{ dash, gap },
    ) catch "Dash: --  |  Space: --";
    f.gl.text(.{ 22, 52 }, readout, .{ .size = 14, .color = co.palette.ink, .font = &s.font });
    f.gl.text(.{ 22, 74 }, "tap: cycle colour", .{ .size = 13, .color = co.palette.ink_dim, .font = &s.font });
    f.gl.text(.{ 22, 94 }, "drag: aim the line", .{ .size = 13, .color = co.palette.ink_dim, .font = &s.font });

    co.caption(f.gl, s.font, "dashed line");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - dashed line",
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
