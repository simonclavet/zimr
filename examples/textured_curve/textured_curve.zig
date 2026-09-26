//! textured_curve — a "road" texture swept along a cubic Bézier as a UV-mapped
//! ribbon. Each of `segments` steps becomes a quad extended along the curve
//! normal by `width`; U runs 0..1 across the width and V accumulates along the
//! length so the road texture tiles down the curve. Drag the four control
//! points (endpoints + tangents) to reshape it; sliders set width and segment
//! count; a toggle overlays the base Bézier.
//!
//! Port of raylib `textures_textured_curve` (its rlSetTexture + rlBegin(QUADS)
//! sweep). The road bitmap is generated procedurally instead of loading
//! resources/road.png, so the example is self-contained. rlBegin(QUADS) is
//! emitted here as two triangles per segment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const clamp = zm.clamp;
const length = zm.length;
const distance = zm.distance;
const bufPrint = std.fmt.bufPrint;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Procedural road texture. U spans the road width; V tiles down its length.
const tex_w: i32 = 64;
const tex_h: i32 = 64;

// raylib palette (faithful literals).
const raywhite: Color = .{ .r = 245, .g = 245, .b = 245, .a = 255 };
const blue: Color = .{ .r = 0, .g = 121, .b = 241, .a = 255 };
const skyblue: Color = .{ .r = 102, .g = 191, .b = 255, .a = 255 };
const lightgray_fade: Color = .{ .r = 200, .g = 200, .b = 200, .a = 102 };
const purple: Color = .{ .r = 200, .g = 122, .b = 255, .a = 255 };
const red: Color = .{ .r = 230, .g = 41, .b = 55, .a = 255 };
const maroon: Color = .{ .r = 190, .g = 33, .b = 55, .a = 255 };
const green: Color = .{ .r = 0, .g = 228, .b = 48, .a = 255 };
const darkgreen: Color = .{ .r = 0, .g = 117, .b = 44, .a = 255 };
const yellow_hi: Color = .{ .r = 253, .g = 249, .b = 0, .a = 255 };
const darkgray: Color = .{ .r = 80, .g = 80, .b = 80, .a = 255 };
const surface: Color = .{ .r = 225, .g = 225, .b = 228, .a = 255 };
const ink: Color = .{ .r = 40, .g = 44, .b = 52, .a = 255 };

const drag_none: i32 = -1;
const drag_width: i32 = 10;
const drag_segs: i32 = 11;

const State = struct {
    font: z.Font,
    road: z.WgpuTexture,
    p_start: Vec2,
    t_start: Vec2,
    p_end: Vec2,
    t_end: Vec2,
    width: f32 = 48,
    segments: i32 = 24,
    show_curve: bool = false,
    drag: i32 = drag_none,
    // Offset from the pointer to the grabbed point at pick time, so the point
    // sticks exactly under the finger with no first-frame jump (getMouseDelta's
    // cross-frame delta teleports on touch, where the previous position is the
    // last release point).
    grab_off: Vec2 = .{ 0, 0 },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.road.deinit();
}

// A tiny deterministic hash for asphalt speckle (no per-pixel RNG state).
fn speckle(x: i32, y: i32) i32 {
    var h: u32 = @bitCast(x *% 73856093 ^ y *% 19349663);
    h ^= h >> 13;
    h *%= 0x5bd1e995;
    h ^= h >> 15;
    return @intCast(h % 17); // 0..16
}

/// Build the road bitmap: dark asphalt with speckle, white edge lines, and a
/// dashed yellow centre line (dashes tile along V).
fn buildRoad(gpa: Allocator) !z.Image {
    const base: Color = .{ .r = 58, .g = 60, .b = 66, .a = 255 };
    const img: z.Image = try z.genImageColor(gpa, tex_w, tex_h, base);
    defer z.unloadImage(gpa, img);
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));

    const wf: f32 = float(tex_w);
    const hf: f32 = float(tex_h);
    var y: i32 = 0;
    while (y < tex_h) : (y += 1) {
        const vy: f32 = float(y) / hf;
        var x: i32 = 0;
        while (x < tex_w) : (x += 1) {
            const ux: f32 = float(x) / wf;
            const idx: usize = @intCast(y * tex_w + x);
            // asphalt with speckle
            const n: i32 = speckle(x, y) - 8;
            var c: Color = .{
                .r = @intCast(clamp(@as(i32, base.r) + n, 0, 255)),
                .g = @intCast(clamp(@as(i32, base.g) + n, 0, 255)),
                .b = @intCast(clamp(@as(i32, base.b) + n, 0, 255)),
                .a = 255,
            };
            // white edge lines near both rims
            if ((ux > 0.045 and ux < 0.085) or (ux > 0.915 and ux < 0.955)) {
                c = .{ .r = 235, .g = 235, .b = 230, .a = 255 };
            }
            // dashed yellow centre line: on for ~62% of each tile, gap after
            if (ux > 0.470 and ux < 0.530 and vy < 0.62) {
                c = .{ .r = 240, .g = 200, .b = 40, .a = 255 };
            }
            px[idx] = c;
        }
    }
    return img;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try buildRoad(gpa);
    const road: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    // (img is a one-shot init allocation; the GPU texture owns its own copy.)

    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .road = road,
        // raylib's fixed points, expressed as fractions of an 800x450 frame so
        // the layout adapts to a phone canvas.
        .p_start = .{ 0.10 * w, 0.22 * h },
        .t_start = .{ 0.125 * w, 0.667 * h },
        .p_end = .{ 0.875 * w, 0.778 * h },
        .t_end = .{ 0.75 * w, 0.22 * h },
    };
}

fn v2(x: f32, y: f32) Vec2 {
    return .{ x, y };
}
fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}
fn scale(a: Vec2, s: f32) Vec2 {
    return .{ a[0] * s, a[1] * s };
}

/// The hero: sweep the road texture along the cubic Bézier as a UV ribbon.
fn drawTexturedCurve(f: *z.Frame, s: *State) void {
    const segs: i32 = if (s.segments < 2) 2 else s.segments;
    const step: f32 = 1.0 / float(segs);
    const road_h: f32 = float(tex_h);

    var previous: Vec2 = s.p_start;
    var previous_tangent: Vec2 = v2(0, 0);
    var previous_v: f32 = 0;
    var tangent_set: bool = false;

    z.rlSetTexture(f.gl, s.road);
    z.rlBegin(f.gl, .triangles);
    z.rlColor4ub(f.gl, 255, 255, 255, 255);

    var i: i32 = 1;
    while (i <= segs) : (i += 1) {
        const t: f32 = step * float(i);
        const omt: f32 = 1.0 - t;
        const a: f32 = omt * omt * omt;
        const b: f32 = 3.0 * omt * omt * t;
        const c: f32 = 3.0 * omt * t * t;
        const d: f32 = t * t * t;

        const current: Vec2 = .{
            a * s.p_start[0] + b * s.t_start[0] + c * s.t_end[0] + d * s.p_end[0],
            a * s.p_start[1] + b * s.t_start[1] + c * s.t_end[1] + d * s.p_end[1],
        };

        const delta: Vec2 = .{ current[0] - previous[0], current[1] - previous[1] };
        const len: f32 = length(delta);
        const inv: f32 = if (len > 0.0001) 1.0 / len else 0.0;
        // right-hand normal to delta
        const normal: Vec2 = .{ -delta[1] * inv, delta[0] * inv };

        const v: f32 = previous_v + len / (road_h * 2.0);

        if (!tangent_set) {
            previous_tangent = normal;
            tangent_set = true;
        }

        const prev_pos: Vec2 = add(previous, scale(previous_tangent, s.width));
        const prev_neg: Vec2 = add(previous, scale(previous_tangent, -s.width));
        const cur_pos: Vec2 = add(current, scale(normal, s.width));
        const cur_neg: Vec2 = add(current, scale(normal, -s.width));

        // raylib's RL_QUADS winding (prevNeg, prevPos, curPos, curNeg) as 2 tris.
        emit(f, 0, previous_v, prev_neg);
        emit(f, 1, previous_v, prev_pos);
        emit(f, 1, v, cur_pos);

        emit(f, 0, previous_v, prev_neg);
        emit(f, 1, v, cur_pos);
        emit(f, 0, v, cur_neg);

        previous = current;
        previous_tangent = normal;
        previous_v = v;
    }

    z.rlEnd(f.gl);
    z.rlSetTexture(f.gl, .{}); // back to the white 1x1 so shapes stay solid
}

fn emit(f: *z.Frame, u: f32, v: f32, p: Vec2) void {
    z.rlTexCoord2f(f.gl, u, v);
    z.rlVertex2f(f.gl, p[0], p[1]);
}

// A cheap horizontal slider: returns the (possibly updated) value.
fn slider(
    f: *z.Frame,
    x0: f32,
    x1: f32,
    y: f32,
    val: f32,
    lo: f32,
    hi: f32,
    active: bool,
) f32 {
    f.gl.rectRoundedXYWH(x0, y - 5, x1 - x0, 10, 1.0, 8, .{ .color = surface });
    var out: f32 = val;
    if (active) {
        const m: Vec2 = z.getMousePosition(f.input);
        out = lo + clamp((m[0] - x0) / (x1 - x0), 0.0, 1.0) * (hi - lo);
    }
    const kx: f32 = x0 + clamp((out - lo) / (hi - lo), 0.0, 1.0) * (x1 - x0);
    f.gl.circle(.{ kx, y }, 10, .{ .color = skyblue, .segments = 16 });
    f.gl.circle(.{ kx, y }, 10, .{ .color = ink, .outline = 1 });
    return out;
}

fn hit(m: Vec2, p: Vec2, r: f32) bool {
    return distance(m, p) <= r;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, raywhite);

    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const m: Vec2 = z.getMousePosition(f.input);
    const down: bool = z.isMouseButtonDown(f.input, .left);

    // control widgets along the bottom
    const wsx0: f32 = w * 0.06;
    const wsx1: f32 = w * 0.44;
    const ssx0: f32 = w * 0.56;
    const ssx1: f32 = w * 0.94;
    const sy: f32 = h - 26.0;
    const toggle: z.Rectangle = z_rect(w * 0.06, 14, 150, 26);

    if (z.isMouseButtonPressed(f.input, .left)) {
        if (hit(m, s.p_start, 12)) {
            s.drag = 0;
            s.grab_off = .{ s.p_start[0] - m[0], s.p_start[1] - m[1] };
        } else if (hit(m, s.t_start, 12)) {
            s.drag = 1;
            s.grab_off = .{ s.t_start[0] - m[0], s.t_start[1] - m[1] };
        } else if (hit(m, s.p_end, 12)) {
            s.drag = 2;
            s.grab_off = .{ s.p_end[0] - m[0], s.p_end[1] - m[1] };
        } else if (hit(m, s.t_end, 12)) {
            s.drag = 3;
            s.grab_off = .{ s.t_end[0] - m[0], s.t_end[1] - m[1] };
        } else if (m[0] >= wsx0 - 14 and m[0] <= wsx1 + 14 and m[1] >= sy - 20 and m[1] <= sy + 20) {
            s.drag = drag_width;
        } else if (m[0] >= ssx0 - 14 and m[0] <= ssx1 + 14 and m[1] >= sy - 20 and m[1] <= sy + 20) {
            s.drag = drag_segs;
        } else if (pointInRect(m, toggle)) {
            s.show_curve = !s.show_curve;
            s.drag = drag_none;
        } else {
            s.drag = drag_none;
        }
    }
    if (!down) {
        s.drag = drag_none;
    }

    if (down) {
        // Position-based drag: point tracks the finger via the grab offset, so
        // there is no first-frame jump and no coordinate-scale dependence.
        const target: Vec2 = .{ m[0] + s.grab_off[0], m[1] + s.grab_off[1] };
        switch (s.drag) {
            0 => s.p_start = target,
            1 => s.t_start = target,
            2 => s.p_end = target,
            3 => s.t_end = target,
            else => {},
        }
    }

    // ---- draw the ribbon first (under the handles) ----
    drawTexturedCurve(f, s);

    // optional reference Bézier as a sampled polyline
    if (s.show_curve) {
        var prev: Vec2 = s.p_start;
        var k: i32 = 1;
        while (k <= 32) : (k += 1) {
            const t: f32 = float(k) / 32.0;
            const omt: f32 = 1.0 - t;
            const a: f32 = omt * omt * omt;
            const b: f32 = 3 * omt * omt * t;
            const c: f32 = 3 * omt * t * t;
            const d: f32 = t * t * t;
            const cur: Vec2 = .{
                a * s.p_start[0] + b * s.t_start[0] + c * s.t_end[0] + d * s.p_end[0],
                a * s.p_start[1] + b * s.t_start[1] + c * s.t_end[1] + d * s.p_end[1],
            };
            f.gl.line(prev, cur, .{ .color = blue, .thickness = 2 });
            prev = cur;
        }
    }

    // tangent guide lines
    f.gl.line(s.p_start, s.t_start, .{ .color = skyblue, .thickness = 2 });
    f.gl.line(s.t_start, s.t_end, .{ .color = lightgray_fade, .thickness = 2 });
    f.gl.line(s.p_end, s.t_end, .{ .color = purple, .thickness = 2 });

    // control-point handles (highlight the hovered one)
    drawHandle(f, m, s.p_start, red);
    drawHandle(f, m, s.t_start, maroon);
    drawHandle(f, m, s.p_end, green);
    drawHandle(f, m, s.t_end, darkgreen);

    // ---- widgets ----
    s.width = slider(f, wsx0, wsx1, sy, s.width, 2, 120, s.drag == drag_width);
    const seg_f: f32 = slider(f, ssx0, ssx1, sy, float(s.segments), 2, 64, s.drag == drag_segs);
    s.segments = @round(seg_f);

    // toggle box
    f.gl.rect(toggle, .{ .color = if (s.show_curve) skyblue else surface });
    f.gl.rect(
        .{ .x = toggle.x, .y = toggle.y, .width = toggle.width, .height = toggle.height },
        .{ .color = ink, .outline = 1.0 },
    );
    f.gl.text(.{ toggle.x + 8, toggle.y + 6 }, "show base curve", .{ .size = 14, .color = ink, .font = &s.font });

    var buf: [96]u8 = undefined;
    const info: []const u8 = bufPrint(&buf, "width {d:.0}   segments {d}", .{ s.width, s.segments }) catch "";
    f.gl.text(.{ w * 0.06, h - 62 }, info, .{ .size = 16, .color = darkgray, .font = &s.font });

    // Diagnostic: a small crosshair at the reported pointer position. If it
    // does not sit under the finger, input and drawing are in different scales.
    if (down) {
        f.gl.line(.{ m[0] - 12, m[1] }, .{ m[0] + 12, m[1] }, .{ .color = red, .thickness = 1.5 });
        f.gl.line(.{ m[0], m[1] - 12 }, .{ m[0], m[1] + 12 }, .{ .color = red, .thickness = 1.5 });
    }

    common.caption(f.gl, s.font, "textured curve - drag the four points; sliders set width & segments");
    z.endDrawing(f.gl);
}

fn drawHandle(f: *z.Frame, m: Vec2, p: Vec2, col: Color) void {
    if (hit(m, p, 8)) {
        f.gl.circle(p, 8, .{ .color = yellow_hi, .segments = 16 });
    }
    f.gl.circle(p, 5, .{ .color = col, .segments = 16 });
}

// small local Rectangle helpers (types.Rectangle via z)
fn z_rect(x: f32, y: f32, w: f32, h: f32) z.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}
fn pointInRect(m: Vec2, r: z.Rectangle) bool {
    return m[0] >= r.x and m[0] <= r.x + r.width and m[1] >= r.y and m[1] <= r.y + r.height;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textured curve",
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
