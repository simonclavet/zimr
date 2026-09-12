//! rectangle_advanced — rounded rectangles with independent left/right corner roundness
//! and a horizontal colour gradient (solid corners, body interpolated). A faithful port of the
//! raylib DrawRectangleRoundedGradientH helper. A stack of bars breathes: each bar oscillates
//! its two corner radii on offset sine waves while the gradient hues drift around the wheel.
//! Phone-first: drag left/right scales the overall roundness (0..1.3), tap toggles the outline.
//! From raylib shapes_rectangle_advanced.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const cosRad = zm.cosRad;
const sinRad = zm.sinRad;
const clamp = zm.clamp;
const distance = zm.distance;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const bar_count = 5;
const corner_segments = 24;

const State = struct {
    font: z.Font,
    t: f32 = 0,
    round_scale: f32 = 1.0,
    outline: bool = false,
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn arcPoint(center: Vec2, deg: f32, radius: f32) Vec2 {
    const r: f32 = deg * rad_per_deg;
    return .{ center[0] + cosRad(r) * radius, center[1] + sinRad(r) * radius };
}

/// Rounded rect with per-side corner radius and a left->right colour gradient.
/// Ported from raylib's DrawRectangleRoundedGradientH (RL_TRIANGLES path).
fn roundedGradientH(
    gl: *z.WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    round_l: f32,
    round_r: f32,
    left: Color,
    right: Color,
) void {
    const rec_size: f32 = @min(w, h);
    const rad_l: f32 = @max(rec_size * round_l * 0.5, 0.0);
    const rad_r: f32 = @max(rec_size * round_r * 0.5, 0.0);

    // 12-point skeleton (see the raylib diagram): P0..P7 outline, P8..P11 corner centres.
    const p: [12]Vec2 = .{
        .{ x + rad_l, y },             .{ x + w - rad_r, y },             .{ x + w, y + rad_r },
        .{ x + w, y + h - rad_r },     .{ x + w - rad_r, y + h },         .{ x + rad_l, y + h },
        .{ x, y + h - rad_l },         .{ x, y + rad_l },                 .{ x + rad_l, y + rad_l },
        .{ x + w - rad_r, y + rad_r }, .{ x + w - rad_r, y + h - rad_r }, .{ x + rad_l, y + h - rad_l },
    };

    // --- four corner fans (solid: left corners = left colour, right = right) ---
    const centers: [4]Vec2 = .{ p[8], p[9], p[10], p[11] };
    const start_deg: [4]f32 = .{ 180, 270, 0, 90 };
    const step: f32 = 90.0 / float(corner_segments);
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const on_left: bool = (k == 0 or k == 3);
        const col: Color = if (on_left) left else right;
        const radius: f32 = if (on_left) rad_l else rad_r;
        const center: Vec2 = centers[k];
        var i: usize = 0;
        while (i < corner_segments) : (i += 1) {
            const a0: f32 = start_deg[k] + step * float(i);
            const a1: f32 = a0 + step;
            gl.triangle(center, arcPoint(center, a1, radius), arcPoint(center, a0, radius), .{ .color = col });
        }
    }

    // --- body quads; left points get `left`, right points get `right` (OpenGL-style lerp) ---
    // [2] top, [9] middle, [6] bottom span the gradient; [8] left and [4] right are solid.
    gradQuad(gl, p[7], p[8], p[11], p[6], left, left, left, left); // [8] left block
    gradQuad(gl, p[8], p[9], p[10], p[11], left, right, right, left); // [9] middle
    gradQuad(gl, p[0], p[1], p[9], p[8], left, right, right, left); // [2] top
    gradQuad(gl, p[11], p[10], p[4], p[5], left, right, right, left); // [6] bottom
    gradQuad(gl, p[9], p[2], p[3], p[10], right, right, right, right); // [4] right block
}

fn gradQuad(
    gl: *z.WgpuGl,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    d: Vec2,
    ca: Color,
    cb: Color,
    cc: Color,
    cd: Color,
) void {
    gl.triangleGradient(a, b, c, ca, cb, cc);
    gl.triangleGradient(a, c, d, ca, cc, cd);
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    z.clearViewport(f, common.palette.bg);

    // --- input: drag sets the roundness scale, tap toggles the outline ---
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
            const frac: f32 = clamp(mouse[0] / w, 0.0, 1.0);
            s.round_scale = frac * 1.3;
        }
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        s.outline = !s.outline;
    }
    s.t += 0.016;

    // --- layout: a centred stack of bars ---
    const bar_w: f32 = w * 0.5;
    const gap: f32 = 8.0;
    const bar_h: f32 = @min(h / 7.0, 70.0);
    const total: f32 = float(bar_count) * (bar_h + gap) - gap;
    const x0: f32 = (w - bar_w) * 0.5;
    var y: f32 = (h - total) * 0.5;

    var i: usize = 0;
    while (i < bar_count) : (i += 1) {
        const fi: f32 = float(i);
        // each bar breathes its two corners on offset phases
        const rl: f32 = clamp((0.5 + 0.5 * sinRad(s.t * 1.1 + fi * 0.9)) * s.round_scale, 0.0, 1.0);
        const rr: f32 = clamp((0.5 + 0.5 * sinRad(s.t * 1.3 + fi * 0.9 + 1.6)) * s.round_scale, 0.0, 1.0);
        const hue_l: f32 = @mod(s.t * 22.0 + fi * 40.0, 360.0);
        const hue_r: f32 = @mod(hue_l + 70.0, 360.0);
        const left: Color = z.colorFromHSV(hue_l, 0.7, 0.95);
        const right: Color = z.colorFromHSV(hue_r, 0.75, 0.9);
        roundedGradientH(f.gl, x0, y, bar_w, bar_h, rl, rr, left, right);
        if (s.outline) {
            const round_avg: f32 = (rl + rr) * 0.5;
            f.gl.rectRoundedLinesXYWH(
                x0,
                y,
                bar_w,
                bar_h,
                round_avg,
                corner_segments,
                2.0,
                .{ .color = common.palette.ink },
            );
        }
        y += bar_h + gap;
    }

    common.caption(f.gl, s.font, "rectangle advanced: drag to set roundness, tap to toggle outline");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - rectangle advanced",
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
