//! triangle_strip — a gear/star built from a triangle strip: alternating inside- and
//! outside-radius points around a circle form a ring of triangles, each filled with an HSV
//! hue that cycles around the wheel. The strip slowly rotates and the hue drifts so it is
//! alive without input. Phone-first: drag left/right to set the segment count (3..60), tap to
//! toggle the black outline. From raylib shapes_triangle_strip (the raygui slider/checkbox
//! become drag + tap).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const cosRad = zm.cosRad;
const sinRad = zm.sinRad;
const tau = zm.tau;
const clamp = zm.clamp;
const distance = zm.distance;
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const max_seg = 60; // points[2*max_seg + 2] = points[122], matching the raylib sample

const State = struct {
    font: z.Font,
    frame_count: usize = 0,
    segments: f32 = 9,
    rotation: f32 = 0,
    hue_off: f32 = 0,
    outline: bool = true,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    z.clearViewport(f, common.palette.bg);

    // --- input: drag sets the segment count, a tap (press without drag) toggles outline ---
    const down: bool = z.isMouseButtonDown(f.input, .left);
    const mouse: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = mouse;
        s.dragged = false;
    }
    if (down) {
        if (distance(mouse, s.press) > 8.0) {
            s.dragged = true;
        }
        if (s.dragged) {
            const lo: f32 = w * 0.15;
            const hi: f32 = w * 0.85;
            const frac: f32 = clamp((mouse[0] - lo) / (hi - lo), 0.0, 1.0);
            s.segments = 3.0 + frac * @as(f32, max_seg - 3);
        }
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.outline = !s.outline;
    }

    // --- self-animation ---
    s.rotation += 0.004;
    s.hue_off = @mod(s.hue_off + 0.4, 360.0);

    // --- build the strip points (inside/outside radius alternating) ---
    const n: usize = @floor(s.segments);
    const center: Vec2 = common.center(w, h);
    const out_r: f32 = @min(w, h) * 0.40;
    const in_r: f32 = out_r * 0.62;
    const step: f32 = tau / float(n);

    var pts: [2 * max_seg + 2]Vec2 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a1: f32 = float(i) * step + s.rotation;
        pts[i * 2] = .{ center[0] + cosRad(a1) * in_r, center[1] + sinRad(a1) * in_r };
        const a2: f32 = a1 + step * 0.5;
        pts[i * 2 + 1] = .{ center[0] + cosRad(a2) * out_r, center[1] + sinRad(a2) * out_r };
    }
    pts[n * 2] = pts[0];
    pts[n * 2 + 1] = pts[1];

    // --- draw two triangles per segment, HSV-colored by angle around the wheel ---
    const edge: Color = .{ .r = 8, .g = 10, .b = 16, .a = 235 };
    i = 0;
    while (i < n) : (i += 1) {
        const a: Vec2 = pts[i * 2];
        const b: Vec2 = pts[i * 2 + 1];
        const c: Vec2 = pts[i * 2 + 2];
        const d: Vec2 = pts[i * 2 + 3];
        const hue1: f32 = @mod(float(i) / float(n) * 360.0 + s.hue_off, 360.0);
        const hue2: f32 = @mod(hue1 + 180.0 / float(n), 360.0);
        f.gl.triangle(c, b, a, .{ .color = z.colorFromHSV(hue1, 0.85, 1.0) });
        f.gl.triangle(d, b, c, .{ .color = z.colorFromHSV(hue2, 0.85, 1.0) });
        if (s.outline) {
            f.gl.triangleLines(a, b, c, .{ .color = edge });
            f.gl.triangleLines(c, b, d, .{ .color = edge });
        }
    }

    common.caption(f.gl, s.font, "triangle strip: drag to set segments, tap to toggle outline");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - triangle strip",
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
