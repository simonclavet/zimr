//! lint:alias draw2d
//! Unified 2D primitive surface — the shared Options structs for the
//! `sink.rect` / `image` / `text` / `line` / `circle` primitives. Immediate
//! (WgpuGl / Sw / Gl), retained-GPU (`DrawList`), and retained-CPU (`Canvas`)
//! all take these, so a `fn draw(sink: anytype)` scene runs against any backend.
//! See `notes/drawing_api.md`. All angles are radians; all colors `Color`; all
//! rects `Rectangle`.

const std = @import("std");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const types = @import("types.zig");

const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const Rectangle = types.Rectangle;
const Font = types.Font;
const NPatchInfo = types.NPatchInfo;

const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// `rect` / `rectXYWH`. `outline == 0` fills; `> 0` strokes at that thickness.
/// `rect` / `rectXYWH`. `outline == 0` fills; `> 0` strokes at that px width.
/// (Rounded + rotated rects are not implemented on the sink surface yet — add
/// them here, wired to shapes2d.drawRectangleRounded / a rotated-quad emit, when a
/// real use case needs them, rather than carrying fields that silently do nothing.)
pub const RectOpts = struct {
    color: Color,
    outline: f32 = 0,
};

/// `image` / `imageXYWH`. `source == null` uses the whole texture; `source` is a
/// pixel-space sub-rect. `npatch` set → nine/three-patch.
pub const ImageOpts = struct {
    source: ?Rectangle = null,
    origin: Vec2 = .{ 0, 0 },
    /// Radians: this struct feeds the image path, which was not converted.
    rotation_rad: f32 = 0,
    tint: Color = white,
    npatch: ?NPatchInfo = null,
};

/// `texture`. Like `image`, but for an already-loaded GPU `WgpuTexture` (a
/// pre-uploaded handle) rather than a pixel-carrying `Sprite`. GPU-only: the CPU
/// sinks have no `WgpuTexture`, so a scene using `texture` won't compile against
/// them — the accepted coverage-gap behavior. `source == null` draws the whole
/// texture.
pub const TextureOpts = struct {
    source: ?Rectangle = null,
    origin: Vec2 = .{ 0, 0 },
    /// Radians: this struct feeds the image path, which was not converted.
    rotation_rad: f32 = 0,
    tint: Color = white,
};

/// `text`. `font == null` uses the sink's default font. A pointer (not a value):
/// retained backends record it for later replay, so it must reference a font that
/// outlives the draw — pass `&my_font`.
pub const TextOpts = struct {
    size: f32,
    color: Color,
    font: ?*const Font = null,
    spacing: f32 = 0,
};

/// `line`.
pub const LineOpts = struct {
    color: Color,
    thickness: f32 = 1,
};

/// `circle`. `outline == 0` fills; `> 0` strokes.
pub const CircleOpts = struct {
    color: Color,
    outline: f32 = 0,
    segments: u32 = 36,
};

/// `triangle` (filled; triangle stroke isn't implemented on the sink surface).
pub const ShapeOpts = struct {
    color: Color,
};

// ===========================================================================
// Immediate-backend emit helpers (`gl: anytype`). Shared by WgpuGl and the SW
// adapter: they decompose a primitive into the low-level trait — `setTexture(0)`
// binds the built-in white texture (portable: all adapters take `setTexture(u32)`),
// then `begin`/`color4ub`/`vertex2f`. The immediate adapters' `rect`/`circle`
// methods are one-line delegations to these.
// ===========================================================================

pub fn rectFilled(gl: anytype, r: Rectangle, color: Color) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const x: f32 = r.x;
    const y: f32 = r.y;
    const w: f32 = r.width;
    const h: f32 = r.height;
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y + h);
    gl.end();
}

pub fn rectOutline(gl: anytype, r: Rectangle, color: Color, thickness: f32) void {
    const t: f32 = thickness;
    rectFilled(gl, .{ .x = r.x, .y = r.y, .width = r.width, .height = t }, color); // top
    rectFilled(gl, .{ .x = r.x, .y = r.y + r.height - t, .width = r.width, .height = t }, color); // bottom
    rectFilled(gl, .{ .x = r.x, .y = r.y, .width = t, .height = r.height }, color); // left
    rectFilled(gl, .{ .x = r.x + r.width - t, .y = r.y, .width = t, .height = r.height }, color); // right
}

pub fn circleFilled(
    gl: anytype,
    center: Vec2,
    radius: f32,
    color: Color,
    segments: u32,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const seg: u32 = if (segments < 3) 3 else segments;
    const fseg: f32 = @floatFromInt(seg);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const fi1: f32 = @floatFromInt(i + 1);
        const a0_turns: f32 = fi / fseg;
        const a1_turns: f32 = fi1 / fseg;
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + radius * cosTurns(a0_turns), cy + radius * sinTurns(a0_turns));
        gl.vertex2f(cx + radius * cosTurns(a1_turns), cy + radius * sinTurns(a1_turns));
    }
    gl.end();
}

/// A circle outline (ring) of `thickness`, as a triangle strip between the inner
/// and outer radius.
pub fn circleOutline(
    gl: anytype,
    center: Vec2,
    radius: f32,
    color: Color,
    thickness: f32,
    segments: u32,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const seg: u32 = if (segments < 3) 3 else segments;
    const fseg: f32 = @floatFromInt(seg);
    const r_out: f32 = radius;
    const r_in: f32 = @max(0.0, radius - thickness);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const fi1: f32 = @floatFromInt(i + 1);
        const a0_turns: f32 = fi / fseg;
        const a1_turns: f32 = fi1 / fseg;
        const c0: f32 = cosTurns(a0_turns);
        const s0: f32 = sinTurns(a0_turns);
        const c1: f32 = cosTurns(a1_turns);
        const s1: f32 = sinTurns(a1_turns);
        gl.vertex2f(cx + r_out * c0, cy + r_out * s0);
        gl.vertex2f(cx + r_in * c0, cy + r_in * s0);
        gl.vertex2f(cx + r_out * c1, cy + r_out * s1);
        gl.vertex2f(cx + r_in * c0, cy + r_in * s0);
        gl.vertex2f(cx + r_in * c1, cy + r_in * s1);
        gl.vertex2f(cx + r_out * c1, cy + r_out * s1);
    }
    gl.end();
}

/// A thick line as a quad (two triangles) perpendicular to a→b.
pub fn lineEmit(
    gl: anytype,
    a: Vec2,
    b: Vec2,
    color: Color,
    thickness: f32,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const dx: f32 = b[0] - a[0];
    const dy: f32 = b[1] - a[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    const half: f32 = thickness * 0.5;
    // Unit perpendicular * half thickness (fall back to a vertical offset for a
    // zero-length segment so a dot still shows).
    const nx: f32 = if (len > 0) (-dy / len) * half else 0;
    const ny: f32 = if (len > 0) (dx / len) * half else half;
    const x0: f32 = a[0] + nx;
    const y0: f32 = a[1] + ny;
    const x1: f32 = a[0] - nx;
    const y1: f32 = a[1] - ny;
    const x2: f32 = b[0] - nx;
    const y2: f32 = b[1] - ny;
    const x3: f32 = b[0] + nx;
    const y3: f32 = b[1] + ny;
    gl.vertex2f(x0, y0);
    gl.vertex2f(x1, y1);
    gl.vertex2f(x2, y2);
    gl.vertex2f(x0, y0);
    gl.vertex2f(x2, y2);
    gl.vertex2f(x3, y3);
    gl.end();
}

/// A filled triangle (a, b, c).
pub fn triangleFilled(
    gl: anytype,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    color: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(a[0], a[1]);
    gl.vertex2f(b[0], b[1]);
    gl.vertex2f(c[0], c[1]);
    gl.end();
}

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const EmitProbe = struct {
    vx: [64]f32 = undefined,
    vy: [64]f32 = undefined,
    n: usize = 0,
    tex: u32 = 999,
    pub fn setTexture(self: *EmitProbe, id: u32) void {
        self.tex = id;
    }
    pub fn begin(self: *EmitProbe, mode: anytype) void {
        _ = self;
        _ = mode;
    }
    pub fn end(self: *EmitProbe) void {
        _ = self;
    }
    pub fn color4ub(
        self: *EmitProbe,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    ) void {
        _ = self;
        _ = r;
        _ = g;
        _ = b;
        _ = a;
    }
    pub fn vertex2f(self: *EmitProbe, x: f32, y: f32) void {
        if (self.n < self.vx.len) {
            self.vx[self.n] = x;
            self.vy[self.n] = y;
            self.n += 1;
        }
    }
};

// --- gap primitives (added for example conversion) ---------------------------

fn emitQuad(
    gl: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) void {
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y);
    gl.vertex2f(x + w, y + h);
    gl.vertex2f(x, y + h);
}

/// ANGLES IN TURNS, WHICH IS WHAT AN ARC WAS ALWAYS MEASURED IN
///
/// A quarter of a circle is 0.25, not `pi / 2`. Every caller of this fan is drawing a fraction of
/// a circle - a rounded corner, a pie slice, a ring segment - and had to spell that fraction in
/// radians so `@sin` would accept it.
///
/// Measured on the four corners of a rounded rectangle at radius 40: the radian route lands
/// 2.29e-5 from the exact arc and this lands 8.87e-6. **Both are far below a pixel, so this is
/// not a visible improvement** - it is the call sites reading as `0.5` and `0.75` where they read
/// `pi` and `pi * 1.5`.
fn emitFan(
    gl: anytype,
    cx: f32,
    cy: f32,
    r: f32,
    a0_turns: f32,
    a1_turns: f32,
    seg: u32,
) void {
    const fseg: f32 = @floatFromInt(seg);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const t0_turns: f32 = a0_turns + (a1_turns - a0_turns) * float(i) / fseg;
        const t1_turns: f32 = a0_turns + (a1_turns - a0_turns) * float(i + 1) / fseg;
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + r * cosTurns(t0_turns), cy + r * sinTurns(t0_turns));
        gl.vertex2f(cx + r * cosTurns(t1_turns), cy + r * sinTurns(t1_turns));
    }
}

/// A filled rectangle rotated `rotation_turns` about `origin` (relative to the
/// rect's top-left corner).
pub fn rectRotatedFilled(
    gl: anytype,
    rec: Rectangle,
    origin: Vec2,
    rotation_turns: f32,
    color: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const cs: f32 = cosTurns(rotation_turns);
    const sn: f32 = sinTurns(rotation_turns);
    const corners = [4]Vec2{
        .{ -origin[0], -origin[1] },
        .{ rec.width - origin[0], -origin[1] },
        .{ rec.width - origin[0], rec.height - origin[1] },
        .{ -origin[0], rec.height - origin[1] },
    };
    var o: [4]Vec2 = undefined;
    for (corners, 0..) |cnr, i| {
        o[i] = .{
            rec.x + origin[0] + cnr[0] * cs - cnr[1] * sn,
            rec.y + origin[1] + cnr[0] * sn + cnr[1] * cs,
        };
    }
    gl.vertex2f(o[0][0], o[0][1]);
    gl.vertex2f(o[1][0], o[1][1]);
    gl.vertex2f(o[2][0], o[2][1]);
    gl.vertex2f(o[0][0], o[0][1]);
    gl.vertex2f(o[2][0], o[2][1]);
    gl.vertex2f(o[3][0], o[3][1]);
    gl.end();
}

/// A filled rounded rectangle. `roundness` is 0..1 (fraction of the shorter side).
pub fn rectRoundedFilled(
    gl: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: u32,
    color: Color,
) void {
    const half: f32 = @min(w, h) * 0.5;
    var r: f32 = roundness * half;
    if (r < 0) {
        r = 0;
    }
    if (r > half) {
        r = half;
    }
    const seg: u32 = if (segments < 1) 1 else segments;
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    emitQuad(gl, x, y + r, w, h - 2 * r);
    emitQuad(gl, x + r, y, w - 2 * r, r);
    emitQuad(gl, x + r, y + h - r, w - 2 * r, r);
    // Each corner is a quarter turn, and now says so.
    emitFan(gl, x + r, y + r, r, 0.5, 0.75, seg);
    emitFan(gl, x + w - r, y + r, r, 0.75, 1.0, seg);
    emitFan(gl, x + w - r, y + h - r, r, 0.0, 0.25, seg);
    emitFan(gl, x + r, y + h - r, r, 0.25, 0.5, seg);
    gl.end();
}

/// A filled triangle with a per-vertex color (Gouraud).
pub fn triangleGradient(
    gl: anytype,
    a: Vec2,
    b: Vec2,
    cc: Vec2,
    ca: Color,
    cb: Color,
    cd: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(ca.r, ca.g, ca.b, ca.a);
    gl.vertex2f(a[0], a[1]);
    gl.color4ub(cb.r, cb.g, cb.b, cb.a);
    gl.vertex2f(b[0], b[1]);
    gl.color4ub(cd.r, cd.g, cd.b, cd.a);
    gl.vertex2f(cc[0], cc[1]);
    gl.end();
}

/// Filled circle sector (pie slice) — a fan over the arc [start, end].
pub fn circleSectorFilled(
    gl: anytype,
    center: Vec2,
    radius: f32,
    start_turns: f32,
    end_turns: f32,
    segments: i32,
    color: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const seg: u32 = @intCast(@max(segments, 1));
    emitFan(gl, center[0], center[1], radius, start_turns, end_turns, seg);
    gl.end();
}

/// Filled regular polygon — a fan of `sides` segments over the full circle.
pub fn polyFilled(
    gl: anytype,
    center: Vec2,
    sides: i32,
    radius: f32,
    rotation_turns: f32,
    color: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const seg: u32 = @intCast(@max(sides, 1));
    emitFan(gl, center[0], center[1], radius, rotation_turns, rotation_turns + 1.0, seg);
    gl.end();
}

/// Filled ring (annulus sector) — a strip between inner and outer radius over [start, end].
pub fn ringFilled(
    gl: anytype,
    center: Vec2,
    inner: f32,
    outer: f32,
    start_turns: f32,
    end_turns: f32,
    segments: i32,
    color: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    gl.color4ub(color.r, color.g, color.b, color.a);
    const cx: f32 = center[0];
    const cy: f32 = center[1];
    const seg: u32 = @intCast(@max(segments, 1));
    const fseg: f32 = @floatFromInt(seg);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const t0_turns: f32 = start_turns + (end_turns - start_turns) * float(i) / fseg;
        const t1_turns: f32 = start_turns + (end_turns - start_turns) * float(i + 1) / fseg;
        const c0: f32 = cosTurns(t0_turns);
        const s0: f32 = sinTurns(t0_turns);
        const c1: f32 = cosTurns(t1_turns);
        const s1: f32 = sinTurns(t1_turns);
        gl.vertex2f(cx + outer * c0, cy + outer * s0);
        gl.vertex2f(cx + inner * c0, cy + inner * s0);
        gl.vertex2f(cx + outer * c1, cy + outer * s1);
        gl.vertex2f(cx + inner * c0, cy + inner * s0);
        gl.vertex2f(cx + inner * c1, cy + inner * s1);
        gl.vertex2f(cx + outer * c1, cy + outer * s1);
    }
    gl.end();
}

/// A dashed line from `a` to `b` (`dash` on, `gap` off, `thick` wide).
pub fn lineDashedEmit(
    gl: anytype,
    a: Vec2,
    b: Vec2,
    thick: f32,
    dash: f32,
    gap: f32,
    color: Color,
) void {
    const dx: f32 = b[0] - a[0];
    const dy: f32 = b[1] - a[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len <= 0) {
        return;
    }
    const ux: f32 = dx / len;
    const uy: f32 = dy / len;
    const step: f32 = @max(dash + gap, 0.001);
    var t: f32 = 0;
    while (t < len) : (t += step) {
        const d_end: f32 = @min(t + dash, len);
        lineEmit(gl, .{ a[0] + ux * t, a[1] + uy * t }, .{ a[0] + ux * d_end, a[1] + uy * d_end }, color, thick);
    }
}

fn c4(gl: anytype, col: Color) void {
    gl.color4ub(col.r, col.g, col.b, col.a);
}

/// A vertical-gradient filled rectangle (top color to bottom color).
pub fn rectGradientVerticalEmit(
    gl: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    top: Color,
    bottom: Color,
) void {
    gl.setTexture(0);
    gl.begin(.triangles);
    c4(gl, top);
    gl.vertex2f(x, y);
    c4(gl, top);
    gl.vertex2f(x + w, y);
    c4(gl, bottom);
    gl.vertex2f(x + w, y + h);
    c4(gl, top);
    gl.vertex2f(x, y);
    c4(gl, bottom);
    gl.vertex2f(x + w, y + h);
    c4(gl, bottom);
    gl.vertex2f(x, y + h);
    gl.end();
}

/// A four-corner-gradient filled rectangle (tl, bl, br, tr).
pub fn rectGradientCornersEmit(
    gl: anytype,
    rec: Rectangle,
    tl: Color,
    bl: Color,
    br: Color,
    tr: Color,
) void {
    const x1: f32 = rec.x + rec.width;
    const y1: f32 = rec.y + rec.height;
    gl.setTexture(0);
    gl.begin(.triangles);
    c4(gl, tl);
    gl.vertex2f(rec.x, rec.y);
    c4(gl, tr);
    gl.vertex2f(x1, rec.y);
    c4(gl, br);
    gl.vertex2f(x1, y1);
    c4(gl, tl);
    gl.vertex2f(rec.x, rec.y);
    c4(gl, br);
    gl.vertex2f(x1, y1);
    c4(gl, bl);
    gl.vertex2f(rec.x, y1);
    gl.end();
}

/// A triangle fan from `points[0]` through the rest.
pub fn triangleFanEmit(gl: anytype, points: []const Vec2, color: Color) void {
    if (points.len < 3) {
        return;
    }
    gl.setTexture(0);
    gl.begin(.triangles);
    c4(gl, color);
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        gl.vertex2f(points[0][0], points[0][1]);
        gl.vertex2f(points[i][0], points[i][1]);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
    }
    gl.end();
}

/// A linear spline (polyline) through `points`.
pub fn splineLinearEmit(
    gl: anytype,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 2) {
        return;
    }
    var i: usize = 0;
    while (i + 1 < points.len) : (i += 1) {
        lineEmit(gl, points[i], points[i + 1], color, thick);
    }
}

/// Curve-spline centreline sampling (24 samples/segment), stroked as a thick
/// polyline to match `splineLinear`'s style. shapes2d builds a mitred triangle-strip
/// ribbon with rounded caps; the sink deliberately uses the finely-sampled polyline
/// so all splines share one emit path and need no ShapesTextureState.
const spline_divisions: usize = 24;

/// Uniform cubic B-spline through `points` (>= 4). Curve does not pass through the
/// control points; mirrors shapes2d.drawSplineBasis.
pub fn splineBasisEmit(
    gl: anytype,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: f32 = @floatFromInt(spline_divisions);
    var prev: Vec2 = .{ 0, 0 };
    for (0..points.len - 3) |i| {
        const p1: Vec2 = points[i];
        const p2: Vec2 = points[i + 1];
        const p3: Vec2 = points[i + 2];
        const p4: Vec2 = points[i + 3];
        const a0_turns: f32 = (-p1[0] + 3.0 * p2[0] - 3.0 * p3[0] + p4[0]) / 6.0;
        const a1_turns: f32 = (3.0 * p1[0] - 6.0 * p2[0] + 3.0 * p3[0]) / 6.0;
        const a2: f32 = (-3.0 * p1[0] + 3.0 * p3[0]) / 6.0;
        const a3: f32 = (p1[0] + 4.0 * p2[0] + p3[0]) / 6.0;
        const b0: f32 = (-p1[1] + 3.0 * p2[1] - 3.0 * p3[1] + p4[1]) / 6.0;
        const b1: f32 = (3.0 * p1[1] - 6.0 * p2[1] + 3.0 * p3[1]) / 6.0;
        const b2: f32 = (-3.0 * p1[1] + 3.0 * p3[1]) / 6.0;
        const b3: f32 = (p1[1] + 4.0 * p2[1] + p3[1]) / 6.0;
        if (i == 0) {
            prev = .{ a3, b3 };
        }
        for (1..spline_divisions + 1) |j| {
            const t: f32 = float(j) / divs;
            const cur: Vec2 = .{
                a3 + t * (a2 + t * (a1_turns + t * a0_turns)),
                b3 + t * (b2 + t * (b1 + t * b0)),
            };
            lineEmit(gl, prev, cur, color, thick);
            prev = cur;
        }
    }
}

/// Catmull-Rom spline through `points` (>= 4); the curve passes through every
/// control point except the first and last. Mirrors shapes2d.drawSplineCatmullRom.
pub fn splineCatmullRomEmit(
    gl: anytype,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: f32 = @floatFromInt(spline_divisions);
    var prev: Vec2 = points[1];
    for (0..points.len - 3) |i| {
        const p1: Vec2 = points[i];
        const p2: Vec2 = points[i + 1];
        const p3: Vec2 = points[i + 2];
        const p4: Vec2 = points[i + 3];
        for (1..spline_divisions + 1) |j| {
            const t: f32 = float(j) / divs;
            const q0: f32 = (-1.0 * t * t * t) + (2.0 * t * t) + (-1.0 * t);
            const q1: f32 = (3.0 * t * t * t) + (-5.0 * t * t) + 2.0;
            const q2: f32 = (-3.0 * t * t * t) + (4.0 * t * t) + t;
            const q3: f32 = t * t * t - t * t;
            const cur: Vec2 = .{
                0.5 * (p1[0] * q0 + p2[0] * q1 + p3[0] * q2 + p4[0] * q3),
                0.5 * (p1[1] * q0 + p2[1] * q1 + p3[1] * q2 + p4[1] * q3),
            };
            lineEmit(gl, prev, cur, color, thick);
            prev = cur;
        }
    }
}

/// Cubic Bezier through `points`; segment k uses points[3k .. 3k+3]
/// (anchor, control, control, anchor). Mirrors shapes2d.drawSplineBezierCubic.
pub fn splineBezierCubicEmit(
    gl: anytype,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    const divs: f32 = @floatFromInt(spline_divisions);
    const n_segs: usize = (points.len - 1) / 3;
    for (0..n_segs) |k| {
        const base: usize = k * 3;
        const p0: Vec2 = points[base];
        const c1: Vec2 = points[base + 1];
        const c2: Vec2 = points[base + 2];
        const p1: Vec2 = points[base + 3];
        var prev: Vec2 = p0;
        for (1..spline_divisions + 1) |j| {
            const t: f32 = float(j) / divs;
            const omt: f32 = 1.0 - t;
            const wa: f32 = omt * omt * omt;
            const wb: f32 = 3.0 * omt * omt * t;
            const wc: f32 = 3.0 * omt * t * t;
            const wd: f32 = t * t * t;
            const cur: Vec2 = .{
                wa * p0[0] + wb * c1[0] + wc * c2[0] + wd * p1[0],
                wa * p0[1] + wb * c1[1] + wc * c2[1] + wd * p1[1],
            };
            lineEmit(gl, prev, cur, color, thick);
            prev = cur;
        }
    }
}

fn emitArcLines(
    gl: anytype,
    cx: f32,
    cy: f32,
    r: f32,
    a0_turns: f32,
    a1_turns: f32,
    seg: u32,
    thick: f32,
    color: Color,
) void {
    const fseg: f32 = @floatFromInt(seg);
    var i: u32 = 0;
    while (i < seg) : (i += 1) {
        const t0_turns: f32 = a0_turns + (a1_turns - a0_turns) * float(i) / fseg;
        const t1_turns: f32 = a0_turns + (a1_turns - a0_turns) * float(i + 1) / fseg;
        const p0: Vec2 = .{ cx + r * cosTurns(t0_turns), cy + r * sinTurns(t0_turns) };
        const p1: Vec2 = .{ cx + r * cosTurns(t1_turns), cy + r * sinTurns(t1_turns) };
        lineEmit(gl, p0, p1, color, thick);
    }
}

/// A rounded-rectangle outline of `thick` px.
pub fn rectRoundedLinesEmit(
    gl: anytype,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: i32,
    thick: f32,
    color: Color,
) void {
    const half: f32 = @min(w, h) * 0.5;
    var r: f32 = roundness * half;
    if (r < 0) {
        r = 0;
    }
    if (r > half) {
        r = half;
    }
    const seg: u32 = @intCast(@max(segments, 1));
    lineEmit(gl, .{ x + r, y }, .{ x + w - r, y }, color, thick);
    lineEmit(gl, .{ x + w, y + r }, .{ x + w, y + h - r }, color, thick);
    lineEmit(gl, .{ x + r, y + h }, .{ x + w - r, y + h }, color, thick);
    lineEmit(gl, .{ x, y + r }, .{ x, y + h - r }, color, thick);
    // Quarter turns, as above.
    emitArcLines(gl, x + r, y + r, r, 0.5, 0.75, seg, thick, color);
    emitArcLines(gl, x + w - r, y + r, r, 0.75, 1.0, seg, thick, color);
    emitArcLines(gl, x + w - r, y + h - r, r, 0.0, 0.25, seg, thick, color);
    emitArcLines(gl, x + r, y + h - r, r, 0.25, 0.5, seg, thick, color);
}

test "draw2d emit: rectFilled binds white and emits the right quad" {
    var gl = EmitProbe{};
    rectFilled(&gl, .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try expectEqual(@as(u32, 0), gl.tex); // white texture bound
    try expectEqual(@as(usize, 6), gl.n); // two triangles
    try expectEqual(@as(f32, 10), gl.vx[0]); // top-left x
    try expectEqual(@as(f32, 20), gl.vy[0]); // top-left y
    try expectEqual(@as(f32, 40), gl.vx[2]); // bottom-right x = 10+30
    try expectEqual(@as(f32, 60), gl.vy[2]); // bottom-right y = 20+40
}

test "draw2d emit: circleFilled emits three verts per segment as a fan" {
    var gl = EmitProbe{};
    circleFilled(&gl, .{ 50, 50 }, 10, .{ .r = 0, .g = 255, .b = 0, .a = 255 }, 8);
    try expectEqual(@as(u32, 0), gl.tex);
    try expectEqual(@as(usize, 24), gl.n); // 8 segments * 3 verts
    try expectEqual(@as(f32, 50), gl.vx[0]); // first vert is the center
    try expectEqual(@as(f32, 50), gl.vy[0]);
    // a rim vertex is within [center-radius, center+radius]
    try expect(gl.vx[1] >= 40 and gl.vx[1] <= 60);
}

test "draw2d emit: lineEmit binds white and emits a quad" {
    var gl = EmitProbe{};
    lineEmit(&gl, .{ 0, 0 }, .{ 10, 0 }, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, 4);
    try expectEqual(@as(u32, 0), gl.tex);
    try expectEqual(@as(usize, 6), gl.n); // two triangles
    // horizontal line, thickness 4 => perpendicular is vertical (+/-2)
    try expectEqual(@as(f32, 0), gl.vx[0]);
    try expectEqual(@as(f32, 2), gl.vy[0]);
}

test "draw2d emit: triangleFilled binds white and emits three verts" {
    var gl = EmitProbe{};
    triangleFilled(&gl, .{ 0, 0 }, .{ 10, 0 }, .{ 5, 8 }, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try expectEqual(@as(u32, 0), gl.tex);
    try expectEqual(@as(usize, 3), gl.n);
    try expectEqual(@as(f32, 5), gl.vx[2]);
    try expectEqual(@as(f32, 8), gl.vy[2]);
}

test "draw2d emit: circleOutline binds white and emits a ring" {
    var gl = EmitProbe{};
    circleOutline(&gl, .{ 50, 50 }, 10, .{ .r = 1, .g = 2, .b = 3, .a = 255 }, 3, 8);
    try expectEqual(@as(u32, 0), gl.tex);
    try expectEqual(@as(usize, 48), gl.n); // 8 segments * 6 verts (two tris per seg)
}
