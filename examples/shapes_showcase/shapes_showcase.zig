//! shapes_showcase — a grid of animated 2D shape primitives. Exercises the new
//! gradient / polygon / fan / outline primitives (drawCircleGradient, drawCircleLines,
//! drawPoly, drawPolyLines, drawRectangleGradientVertical/Ex, drawTriangleFan, drawTriangleLines)
//! alongside existing ones (sectors, ellipses, splines, dashed lines), on the shared
//! scaffold. Adapted from raylib's shapes showcase; self-running.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const float = zm.float;
const co = @import("example_common");

const Vec2 = zm.Vec2;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const cols: usize = 4;
const rows: usize = 3;

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

/// Centre of grid cell `i` (row-major), below the top caption strip.
fn cellCenter(
    i: usize,
    w: f32,
    h: f32,
) Vec2 {
    const cw: f32 = w / float(cols);
    const ch: f32 = (h - 30.0) / float(rows);
    const col: f32 = float(i % cols);
    const row: f32 = float(i / cols);
    return .{ col * cw + cw * 0.5, 30.0 + row * ch + ch * 0.5 };
}

/// Small caption under a cell's shape.
fn label(
    gl: anytype,
    font: z.Font,
    c: Vec2,
    txt: []const u8,
    r: f32,
) void {
    gl.text(.{ c[0] - r, c[1] + r + 4 }, txt, .{ .size = 11, .color = co.palette.ink_dim, .font = &font });
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const r: f32 = @min(w / float(cols), (h - 30.0) / float(rows)) * 0.30;
    const ang: f32 = t * 40.0;

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    {
        const c: Vec2 = cellCenter(0, w, h);
        f.gl.circleGradient(.{ c[0], c[1] }, r, co.palette.accent, co.palette.surface);
        label(f.gl, s.font, c, "circleGradient", r);
    }
    {
        const c: Vec2 = cellCenter(1, w, h);
        f.gl.circle(c, r, .{ .color = co.palette.accent2, .outline = 1 });
        label(f.gl, s.font, c, "circleLines", r);
    }
    {
        const c: Vec2 = cellCenter(2, w, h);
        f.gl.poly(c, 5, r, radFromDeg(ang), .{ .color = co.palette.good });
        label(f.gl, s.font, c, "poly(5)", r);
    }
    {
        const c: Vec2 = cellCenter(3, w, h);
        f.gl.polyLines(c, 6, r, radFromDeg(-ang), .{ .color = co.palette.warn });
        label(f.gl, s.font, c, "polyLines(6)", r);
    }
    {
        const c: Vec2 = cellCenter(4, w, h);
        f.gl.rectGradientVertical(c[0] - r, c[1] - r, 2.0 * r, 2.0 * r, co.palette.accent, co.palette.accent2);
        label(f.gl, s.font, c, "rectGradV", r);
    }
    {
        const c: Vec2 = cellCenter(5, w, h);
        const rec: z.Rectangle = .{ .x = c[0] - r, .y = c[1] - r, .width = 2.0 * r, .height = 2.0 * r };
        f.gl.rectGradientCorners(
            rec,
            co.palette.ramp(0),
            co.palette.ramp(90),
            co.palette.ramp(180),
            co.palette.ramp(270),
        );
        label(f.gl, s.font, c, "rectGradEx", r);
    }
    {
        const c: Vec2 = cellCenter(6, w, h);
        const pts = [_]Vec2{
            c,
            .{ c[0] - r, c[1] + r * 0.5 },
            .{ c[0] - r * 0.5, c[1] - r },
            .{ c[0] + r * 0.5, c[1] - r },
            .{ c[0] + r, c[1] + r * 0.5 },
        };
        f.gl.triangleFan(&pts, .{ .color = co.palette.accent.fade(0.8) });
        label(f.gl, s.font, c, "triangleFan", r);
    }
    {
        const c: Vec2 = cellCenter(7, w, h);
        f.gl.triangleLines(
            .{ c[0], c[1] - r },
            .{ c[0] - r, c[1] + r },
            .{ c[0] + r, c[1] + r },
            .{ .color = co.palette.ink },
        );
        label(f.gl, s.font, c, "triangleLines", r);
    }
    {
        const c: Vec2 = cellCenter(8, w, h);
        f.gl.circleSector(c, r, 0, radFromDeg(@mod(ang * 3.0, 360.0)), 32, .{ .color = co.palette.good.fade(0.7) });
        label(f.gl, s.font, c, "circleSector", r);
    }
    {
        const c: Vec2 = cellCenter(9, w, h);
        f.gl.ellipse(c, r * 1.2, r * 0.7, .{ .color = co.palette.accent2.fade(0.7) });
        label(f.gl, s.font, c, "ellipse", r);
    }
    {
        const c: Vec2 = cellCenter(10, w, h);
        const pts = [_]Vec2{
            .{ c[0] - r, c[1] },
            .{ c[0] - r * 0.5, c[1] - r * 0.6 },
            .{ c[0], c[1] + r * 0.6 },
            .{ c[0] + r * 0.5, c[1] - r * 0.6 },
            .{ c[0] + r, c[1] },
        };
        f.gl.splineLinear(&pts, 3.0, .{ .color = co.palette.accent });
        label(f.gl, s.font, c, "splineLinear", r);
    }
    {
        const c: Vec2 = cellCenter(11, w, h);
        f.gl.lineDashed(.{ c[0] - r, c[1] - r }, .{ c[0] + r, c[1] + r }, 3.0, 8.0, 6.0, .{ .color = co.palette.warn });
        label(f.gl, s.font, c, "lineDashed", r);
    }

    co.caption(f.gl, s.font, "shapes showcase: 2D primitives");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - shapes showcase",
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
