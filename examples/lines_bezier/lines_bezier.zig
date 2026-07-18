//! lines_bezier — a cubic Bézier curve ported to WebGPU. Four control points drift
//! along slow Lissajous paths; each frame the cubic is sampled into a polyline and drawn
//! via `drawSplineLinear`, with the control polygon as a dashed line and the control
//! points as dots. The GL original let you drag the endpoints; this animates itself.
//! Viewport-relative under `.responsive`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const c = Color;
const samples: usize = 48;

const State = struct {
    font: z.Font,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

/// A control point drifting on a Lissajous path centred at (cxf*w, cyf*h).
fn ctrl(
    w: f32,
    h: f32,
    t: f32,
    cxf: f32,
    cyf: f32,
    fx: f32,
    fy: f32,
    amp: f32,
) Vec2 {
    const m: f32 = @min(w, h);
    return .{ w * cxf + @cos(t * fx) * m * amp, h * cyf + @sin(t * fy) * m * amp };
}

fn cubic(
    p0: Vec2,
    c0: Vec2,
    c1: Vec2,
    p1: Vec2,
    t: f32,
) Vec2 {
    const u: f32 = 1.0 - t;
    const a: f32 = u * u * u;
    const b: f32 = 3.0 * u * u * t;
    const cc: f32 = 3.0 * u * t * t;
    const d: f32 = t * t * t;
    return .{
        a * p0[0] + b * c0[0] + cc * c1[0] + d * p1[0],
        a * p0[1] + b * c0[1] + cc * c1[1] + d * p1[1],
    };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const t: f32 = f.time.time;

    const p0: Vec2 = ctrl(w, h, t, 0.18, 0.50, 0.5, 0.7, 0.10);
    const c0: Vec2 = ctrl(w, h, t, 0.40, 0.25, 0.8, 1.1, 0.16);
    const c1: Vec2 = ctrl(w, h, t, 0.62, 0.75, 1.1, 0.9, 0.16);
    const p1: Vec2 = ctrl(w, h, t, 0.84, 0.50, 0.7, 0.6, 0.10);

    z.clearViewport(f, c.init(10, 12, 18, 255));

    // Control polygon (dashed) + control points.
    const ctl: Color = c.init(120, 126, 140, 200);
    f.gl.lineDashed(p0, c0, 1.0, 6, 5, .{ .color = ctl });
    f.gl.lineDashed(c0, c1, 1.0, 6, 5, .{ .color = ctl });
    f.gl.lineDashed(c1, p1, 1.0, 6, 5, .{ .color = ctl });
    f.gl.circle(c0, 5.0, .{ .color = c.init(235, 200, 90, 255), .segments = 16 });
    f.gl.circle(c1, 5.0, .{ .color = c.init(235, 200, 90, 255), .segments = 16 });
    f.gl.circle(p0, 6.0, .{ .color = c.init(90, 200, 130, 255), .segments = 16 });
    f.gl.circle(p1, 6.0, .{ .color = c.init(90, 200, 130, 255), .segments = 16 });

    // Sample + draw the cubic.
    var pts: [samples]Vec2 = undefined;
    for (0..samples) |i| {
        const tt: f32 = float(i) / float(samples - 1);
        pts[i] = cubic(p0, c0, c1, p1, tt);
    }
    f.gl.splineLinear(&pts, 3.0, .{ .color = c.init(120, 170, 245, 255) });

    f.gl.text(
        .{ 12, 12 },
        "cubic bezier (animated control points)",
        .{ .size = 16, .color = c.init(210, 214, 224, 220), .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - bezier",
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
