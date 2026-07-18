//! splines_drawing — four spline families over a shared set of draggable points:
//! Linear, B-Spline (Basis), Catmull-Rom, and Cubic Bezier. Drag any point to reshape the curve;
//! tap empty space to cycle the spline type. In Bezier mode the two control points per segment are
//! derived automatically and shown with handle dots + tangent lines. The stroke breathes its
//! thickness and drifts hue so the canvas stays alive between drags. From raylib shapes_splines_drawing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const sin = zm.sin;
const distance = zm.distance;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;

const point_count = 5;
const grab_radius = 16.0;
const type_names = [_][]const u8{ "LINEAR", "B-SPLINE", "CATMULL-ROM", "BEZIER" };

const State = struct {
    font: z.Font,
    points: [point_count]Vec2,
    spline_type: usize = 0,
    selected: i32 = -1,
    t: f32 = 0,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const sx: f32 = f.window.widthf() / 800.0;
    const sy: f32 = f.window.heightf() / 450.0;
    // raylib's five starting points, scaled to the actual viewport
    const base = [point_count]Vec2{
        .{ 50, 400 }, .{ 160, 220 }, .{ 340, 380 }, .{ 520, 60 }, .{ 710, 260 },
    };
    var pts: [point_count]Vec2 = undefined;
    for (base, 0..) |b, i| {
        pts[i] = .{ b[0] * sx, b[1] * sy };
    }
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24), .points = pts };
}

fn nearestPoint(pts: []const Vec2, m: Vec2) i32 {
    var best: i32 = -1;
    var best_d: f32 = grab_radius;
    for (pts, 0..) |p, i| {
        const d: f32 = distance(p, m);
        if (d <= best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, co.palette.bg);
    s.t += 0.016;

    // --- input: drag the nearest point; a clean tap on empty space cycles the type ---
    const down: bool = z.isMouseButtonDown(f.input, .left);
    const mouse: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = mouse;
        s.dragged = false;
        s.selected = nearestPoint(s.points[0..], mouse);
    }
    if (down) {
        if (distance(mouse, s.press) > 8.0) {
            s.dragged = true;
        }
        if (s.selected >= 0) {
            s.points[@intCast(s.selected)] = mouse;
        }
    }
    if (z.isMouseButtonReleased(f.input, .left) and s.selected < 0 and !s.dragged) {
        s.spline_type = (s.spline_type + 1) % type_names.len;
    }
    if (!down) {
        s.selected = -1;
    }

    const focused: i32 = if (s.selected >= 0) s.selected else nearestPoint(s.points[0..], mouse);

    // --- spline stroke: breathing thickness + slow hue drift ---
    const thick: f32 = 8.0 + 2.0 * sin(s.t * 2.0);
    const stroke: Color = z.colorFromHSV(@mod(s.t * 30.0, 360.0), 0.85, 0.95);

    // control-polygon helper lines (basis / catmull-rom only, like raylib)
    if (s.spline_type == 1 or s.spline_type == 2) {
        var i: usize = 0;
        while (i + 1 < point_count) : (i += 1) {
            f.gl.line(s.points[i], s.points[i + 1], .{ .color = co.palette.ink_dim, .thickness = 1.0 });
        }
    }

    switch (s.spline_type) {
        0 => f.gl.splineLinear(s.points[0..], thick, .{ .color = stroke }),
        1 => f.gl.splineBasis(s.points[0..], thick, .{ .color = stroke }),
        2 => f.gl.splineCatmullRom(s.points[0..], thick, .{ .color = stroke }),
        else => drawBezier(f, s, thick, stroke),
    }

    // --- point helpers: a ring per point (fatter when focused) + a coordinate label ---
    for (s.points, 0..) |p, i| {
        const is_focus: bool = (focused == @as(i32, @intCast(i)));
        const r: f32 = if (is_focus) 12.0 else 8.0;
        const ring: Color = if (is_focus) co.palette.accent else co.palette.accent2;
        f.gl.circle(p, r, .{ .color = ring, .outline = 1 });
        var buf: [32]u8 = undefined;
        const label: []const u8 = bufPrint(&buf, "[{d:.0}, {d:.0}]", .{ p[0], p[1] }) catch "";
        f.gl.text(.{ p[0] + 12, p[1] - 6 }, label, .{ .size = 12, .color = co.palette.ink_dim, .font = &s.font });
    }

    var hud: [64]u8 = undefined;
    const line: []const u8 = bufPrint(
        &hud,
        "spline: {s} - drag points, tap to cycle",
        .{type_names[s.spline_type]},
    ) catch "";
    co.caption(f.gl, s.font, line);
    z.endDrawing(f.gl);
}

/// Cubic-Bezier: build the interleaved start/c1/c2/end array (controls auto-derived as a
/// horizontal offset off each anchor), draw the curve, then the control handles + tangents.
fn drawBezier(f: *z.Frame, s: *State, thick: f32, stroke: Color) void {
    var inter: [3 * (point_count - 1) + 1]Vec2 = undefined;
    var i: usize = 0;
    while (i + 1 < point_count) : (i += 1) {
        const c_start: Vec2 = .{ s.points[i][0] + 60, s.points[i][1] };
        const c_end: Vec2 = .{ s.points[i + 1][0] - 60, s.points[i + 1][1] };
        inter[3 * i] = s.points[i];
        inter[3 * i + 1] = c_start;
        inter[3 * i + 2] = c_end;
    }
    inter[3 * (point_count - 1)] = s.points[point_count - 1];

    f.gl.splineBezierCubic(inter[0..], thick, .{ .color = stroke });

    // control handles + tangent lines
    i = 0;
    while (i + 1 < point_count) : (i += 1) {
        const c_start: Vec2 = inter[3 * i + 1];
        const c_end: Vec2 = inter[3 * i + 2];
        f.gl.line(s.points[i], c_start, .{ .color = co.palette.ink_dim, .thickness = 1.5 });
        f.gl.line(s.points[i + 1], c_end, .{ .color = co.palette.ink_dim, .thickness = 1.5 });
        f.gl.circle(c_start, 5.0, .{ .color = co.palette.warn, .segments = 16 });
        f.gl.circle(c_end, 5.0, .{ .color = co.palette.warn, .segments = 16 });
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - splines drawing",
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
