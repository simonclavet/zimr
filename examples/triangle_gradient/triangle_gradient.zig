//! triangle_gradient - three gradient-filled triangles whose corners pulse on
//! out-of-phase sine waves. Each vertex carries its own colour and the GPU interpolates
//! across the face, so the blend direction breathes. Exercises the new drawTriangleGradient
//! primitive. Ported from raylib's gradient-triangle demo, themed with the shared scaffold.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// An upward-pointing equilateral triangle centred at (cx,cy) with three corner colours.
fn tri(
    gl: anytype,
    cx: f32,
    cy: f32,
    r: f32,
    cols: [3]common.Color,
) void {
    const top: Vec2 = .{ cx, cy - r };
    const ll: Vec2 = .{ cx - r * 0.866, cy + r * 0.5 };
    const lr: Vec2 = .{ cx + r * 0.866, cy + r * 0.5 };
    gl.triangleGradient(top, ll, lr, cols[0], cols[1], cols[2]);
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const cy: f32 = h * 0.5;
    const r: f32 = @min(w, h) * 0.20;

    const pa: u8 = @round(128.0 + 127.0 * @sin(t * 1.7));
    const pb: u8 = @round(128.0 + 127.0 * @sin(t * 2.3 + 1.0));
    const pc: u8 = @round(128.0 + 127.0 * @sin(t * 1.1 + 2.0));

    z.clearViewport(f, common.palette.bg);
    common.backdrop(f.gl, w, h);

    tri(f.gl, w * 0.25, cy, r, .{
        .{ .r = pa, .g = 40, .b = 40, .a = 255 },
        .{ .r = 40, .g = pb, .b = 40, .a = 255 },
        .{ .r = 40, .g = 40, .b = pc, .a = 255 },
    });
    tri(f.gl, w * 0.5, cy, r, .{
        .{ .r = 255, .g = pa, .b = 0, .a = 255 },
        .{ .r = 255, .g = 0, .b = pb, .a = 255 },
        .{ .r = pc, .g = 80, .b = 0, .a = 255 },
    });
    tri(f.gl, w * 0.75, cy, r, .{
        .{ .r = 0, .g = pa, .b = 255, .a = 255 },
        .{ .r = pb, .g = 0, .b = 255, .a = 255 },
        .{ .r = 0, .g = 255, .b = pc, .a = 255 },
    });

    common.caption(f.gl, s.font, "triangle gradient: per-vertex colour, GPU-interpolated");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - triangle gradient",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
