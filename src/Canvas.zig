//! `Canvas` — a pure-Zig, native, anti-aliased 2D drawing surface that
//! exports PNG with zero third-party code. It renders into a supersampled
//! RGBA8 buffer using zimr's own `imageDraw*` rasterizers + truetype text, then
//! box-downsamples (premultiplied) for clean anti-aliasing, and encodes via
//! zimr's own PNG codec.
//!
//! It is also a drop-in `plot.zig` *sink*: the method set (fillRect / line /
//! polyline / circleFilled / triangleFilled / text / pushClip / popClip /
//! texturedQuad) matches what the plot renderers call, so a `Plot` can be drawn
//! straight to a PNG with no UI / GPU / wasm involved.
//!
//! Ergonomics: build a `Canvas`, draw, `savePng(io, "out.png")` — where `io`
//! is the `std.Io` your `main` already created (see `examples/native_plot_png`
//! for a ~40-line program). For bytes without a file, use `writePngToMemory`.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const img = @import("image.zig");
const text2d = @import("text2d.zig");
const codecs = @import("codecs.zig");
const types = @import("types.zig");
const plot = @import("plot.zig");
const draw2d = @import("draw2d.zig");

const Allocator = std.mem.Allocator;
const Image = types.Image;
const Sprite = @import("Sprite.zig");
const Rectangle = types.Rectangle;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const Rect = plot.Rect;
const clamp = zm.clamp;

/// The file *is* the Canvas: `@import("Canvas.zig")` gives this struct.
const Canvas = @This();

/// Canvas construction options.
pub const Options = struct {
    /// Supersampling factor for anti-aliasing: every primitive is drawn at
    /// `ss`x resolution and box-downsampled on resolve. 1 = no AA, 3-4 = crisp
    /// publication quality. Clamped to 1..4.
    ss: u8 = 4,
    /// Background fill (the whole surface starts as this).
    background: Color = .{ .r = 250, .g = 250, .b = 252, .a = 255 },
    /// Atlas bake size for text (in supersampled pixels). Larger = sharper text
    /// at big point sizes. 64 is a good default.
    font_atlas_size: i32 = 64,
};

/// Intersect `r` with `clip` (if any). Returns null when empty.
fn clipRect(r: Rect, clip: ?Rect) ?Rect {
    const cl: Rect = clip orelse return r;
    const x0: f32 = @max(r.x, cl.x);
    const y0: f32 = @max(r.y, cl.y);
    const x1: f32 = @min(r.x + r.w, cl.x + cl.w);
    const y1: f32 = @min(r.y + r.h, cl.y + cl.h);
    if (x1 <= x0 or y1 <= y0) {
        return null;
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Liang-Barsky: clip segment p0->p1 to `cl`. Returns false if fully outside.
fn clipSegment(cl: Rect, p0: *Vec2, p1: *Vec2) bool {
    var t0: f32 = 0;
    var t1: f32 = 1;
    const dx: f32 = p1[0] - p0[0];
    const dy: f32 = p1[1] - p0[1];
    const xmin: f32 = cl.x;
    const xmax: f32 = cl.x + cl.w;
    const ymin: f32 = cl.y;
    const ymax: f32 = cl.y + cl.h;
    const ps = [_]f32{ -dx, dx, -dy, dy };
    const qs = [_]f32{ p0[0] - xmin, xmax - p0[0], p0[1] - ymin, ymax - p0[1] };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) {
                return false; // parallel and outside
            }
        } else {
            const t: f32 = q / p;
            if (p < 0) {
                if (t > t1) {
                    return false;
                }
                if (t > t0) {
                    t0 = t;
                }
            } else {
                if (t < t0) {
                    return false;
                }
                if (t < t1) {
                    t1 = t;
                }
            }
        }
    }
    const nx0: f32 = p0[0] + t0 * dx;
    const ny0: f32 = p0[1] + t0 * dy;
    const nx1: f32 = p0[0] + t1 * dx;
    const ny1: f32 = p0[1] + t1 * dy;
    p0.* = .{ nx0, ny0 };
    p1.* = .{ nx1, ny1 };
    return true;
}

gpa: Allocator,
/// Logical (output) dimensions.
w: i32,
h: i32,
/// Supersampling factor (>=1).
ss: i32,
/// Supersampled working buffer (w*ss by h*ss, RGBA8).
buf: Image,
/// Optional text font: a baked glyph atlas (CPU). Null until `useFont`.
atlas: ?text2d.FontAtlas = null,
atlas_size: i32 = 64,
/// Clip-rect stack (logical coords). Top is the active clip; empty = none.
clip_stack: [16]Rect = undefined,
clip_top: usize = 0,

pub fn init(gpa: Allocator, width: i32, height: i32, opts: Options) !Canvas {
    const ss: i32 = @intCast(clamp(opts.ss, 1, 4));
    const buf: Image = try img.genImageColor(gpa, width * ss, height * ss, opts.background);
    return .{
        .gpa = gpa,
        .w = width,
        .h = height,
        .ss = ss,
        .buf = buf,
        .atlas_size = opts.font_atlas_size,
    };
}

pub fn deinit(self: *Canvas) void {
    img.unloadImage(self.gpa, self.buf);
    if (self.atlas) |*a| {
        a.deinit(self.gpa);
    }
    self.* = undefined;
}

/// Enable text by baking a glyph atlas from TTF bytes (the caller keeps
/// ownership of `ttf_bytes`, e.g. via `@embedFile`). ASCII 32..126 by
/// default. Pure-Zig (truetype + atlas bake); needs no GPU.
pub fn useFont(self: *Canvas, ttf_bytes: []const u8) !void {
    var cps: [95]u21 = undefined;
    for (0..95) |k| {
        cps[k] = @intCast(32 + k);
    }
    const tt: codecs.truetype.Font = try codecs.truetype.loadFontFromTtf(self.gpa, ttf_bytes);
    const atlas: text2d.FontAtlas = try text2d.bakeFontAtlas(self.gpa, &tt, self.atlas_size, &cps, 2);
    if (self.atlas) |*old| {
        old.deinit(self.gpa);
    }
    self.atlas = atlas;
}

fn ssf(self: *const Canvas) f32 {
    return @floatFromInt(self.ss);
}

fn activeClip(self: *const Canvas) ?Rect {
    return if (self.clip_top == 0) null else self.clip_stack[self.clip_top - 1];
}

// ---- sink interface (logical coords; scaled to the SS buffer) ----------

pub fn fillRect(self: *Canvas, r: Rect, col: Color) void {
    const c: Rect = clipRect(r, self.activeClip()) orelse return;
    const k: f32 = self.ssf();
    img.imageDrawRectangleRec(&self.buf, .{
        .x = c.x * k,
        .y = c.y * k,
        .width = c.w * k,
        .height = c.h * k,
    }, col);
}

/// Unified primitive: fill or stroke a `Rectangle` (see `notes/drawing_api.md`).
/// `Rect` remains Canvas's internal helper; this is the public surface. Rounding
/// and rotation aren't yet honored on the CPU canvas (filled/stroked only).
pub fn rect(self: *Canvas, r: Rectangle, opts: draw2d.RectOpts) void {
    if (opts.outline <= 0) {
        self.fillRect(.{ .x = r.x, .y = r.y, .w = r.width, .h = r.height }, opts.color);
        return;
    }
    const t: f32 = opts.outline;
    self.fillRect(.{ .x = r.x, .y = r.y, .w = r.width, .h = t }, opts.color); // top
    self.fillRect(.{ .x = r.x, .y = r.y + r.height - t, .w = r.width, .h = t }, opts.color); // bottom
    self.fillRect(.{ .x = r.x, .y = r.y, .w = t, .h = r.height }, opts.color); // left
    self.fillRect(.{ .x = r.x + r.width - t, .y = r.y, .w = t, .h = r.height }, opts.color); // right
}

/// `rect` twin that takes loose numbers, so callers without a `Rectangle` aren't
/// forced to build one.
pub fn rectXYWH(
    self: *Canvas,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: draw2d.RectOpts,
) void {
    self.rect(.{ .x = x, .y = y, .width = w, .height = h }, opts);
}

pub fn line(
    self: *Canvas,
    a: Vec2,
    b: Vec2,
    opts: draw2d.LineOpts,
) void {
    const col: Color = opts.color;
    const thickness: f32 = opts.thickness;
    var p0: Vec2 = a;
    var p1: Vec2 = b;
    if (self.activeClip()) |cl| {
        if (!clipSegment(cl, &p0, &p1)) {
            return;
        }
    }
    const k: f32 = self.ssf();
    const tr: i32 = @round(thickness * k);
    const t: i32 = @max(1, tr);
    img.imageDrawLineThick(&self.buf, .{ p0[0] * k, p0[1] * k }, .{ p1[0] * k, p1[1] * k }, t, col);
}

pub fn polyline(
    self: *Canvas,
    pts: []const Vec2,
    col: Color,
    thickness: f32,
    closed: bool,
) void {
    if (pts.len < 2) {
        return;
    }
    var i: usize = 1;
    while (i < pts.len) : (i += 1) {
        self.line(pts[i - 1], pts[i], .{ .color = col, .thickness = thickness });
    }
    if (closed) {
        self.line(pts[pts.len - 1], pts[0], .{ .color = col, .thickness = thickness });
    }
}

pub fn circleFilled(self: *Canvas, c: Vec2, radius: f32, col: Color) void {
    const k: f32 = self.ssf();
    const cx: i32 = @round(c[0] * k);
    const cy: i32 = @round(c[1] * k);
    const r: i32 = @round(radius * k);
    img.imageDrawCircle(&self.buf, cx, cy, r, col);
}

/// Unified primitive: fill a circle (see notes/drawing_api.md). `circleFilled`
/// stays as the plot-sink name. Outline (ring) and `segments` are deferred on the
/// CPU canvas — it fills a smooth disc, so segments don't apply.
pub fn circle(self: *Canvas, center: Vec2, radius: f32, opts: draw2d.CircleOpts) void {
    self.circleFilled(center, radius, opts.color);
}

/// Unified primitive: a filled triangle. `triangleFilled` stays as the plot-sink
/// name; outline is deferred on the CPU canvas.
pub fn triangle(
    self: *Canvas,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    opts: draw2d.ShapeOpts,
) void {
    self.triangleFilled(a, b, c, opts.color);
}

pub fn triangleFilled(
    self: *Canvas,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    col: Color,
) void {
    const k: f32 = self.ssf();
    img.imageDrawTriangle(
        &self.buf,
        .{ a[0] * k, a[1] * k },
        .{ b[0] * k, b[1] * k },
        .{ c[0] * k, c[1] * k },
        col,
    );
}

/// Plot image-series sink. The CPU canvas has no GPU texture registry, so a
/// `tex_id` can't be sampled; we fill the destination with the tint as an
/// honest placeholder. (Real textured output is the GPU/UI path's job.)
pub fn texturedQuad(
    self: *Canvas,
    dst: Rect,
    tex_id: u32,
    uv0: Vec2,
    uv1: Vec2,
    tint: Color,
) void {
    _ = tex_id;
    _ = uv0;
    _ = uv1;
    self.fillRect(dst, tint);
}

/// Unified primitive: draw `sprite` into `dst` with tint. `source` (pixel-space)
/// picks a sub-rect; null = whole sprite. Origin, rotation, and npatch are
/// deferred on the CPU canvas. The Sprite carries its own pixels, so no
/// per-canvas texture registration is needed.
pub fn image(self: *Canvas, dst: Rectangle, sprite: Sprite, opts: draw2d.ImageOpts) void {
    const src: Image = sprite.image;
    const source: Rectangle = opts.source orelse .{
        .x = 0,
        .y = 0,
        .width = float(src.width),
        .height = float(src.height),
    };
    const k: f32 = self.ssf();
    const dst_scaled: Rectangle = .{
        .x = dst.x * k,
        .y = dst.y * k,
        .width = dst.width * k,
        .height = dst.height * k,
    };
    img.imageDraw(&self.buf, src, source, dst_scaled, opts.tint);
}

/// `image` twin taking loose numbers for the destination.
pub fn imageXYWH(
    self: *Canvas,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    sprite: Sprite,
    opts: draw2d.ImageOpts,
) void {
    self.image(.{ .x = x, .y = y, .width = w, .height = h }, sprite, opts);
}

pub fn pushClip(self: *Canvas, r: Rect) void {
    const merged: Rect = clipRect(r, self.activeClip()) orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (self.clip_top < self.clip_stack.len) {
        self.clip_stack[self.clip_top] = merged;
        self.clip_top += 1;
    }
}

pub fn popClip(self: *Canvas) void {
    if (self.clip_top > 0) {
        self.clip_top -= 1;
    }
}

pub fn text(
    self: *Canvas,
    pos: Vec2,
    s: []const u8,
    opts: draw2d.TextOpts,
) void {
    const size: f32 = opts.size;
    const col: Color = opts.color;
    const atlas: text2d.FontAtlas = self.atlas orelse return;
    const k: f32 = self.ssf();
    // Glyph scale: atlas was baked at `base_size`; we draw at `size` logical
    // points => `size*ss` device pixels.
    const gscale: f32 = (size * k) / float(atlas.base_size);
    var pen_x: f32 = pos[0] * k;
    const pen_y: f32 = pos[1] * k;
    for (s) |ch| {
        const cp: u21 = ch;
        var idx: ?usize = null;
        for (atlas.glyphs, 0..) |g, gi| {
            if (@as(u21, @intCast(g.value)) == cp) {
                idx = gi;
                break;
            }
        }
        const gi: usize = idx orelse {
            pen_x += float(atlas.base_size) * 0.5 * gscale;
            continue;
        };
        const g: types.GlyphInfo = atlas.glyphs[gi];
        const rec: Rectangle = atlas.recs[gi];
        if (rec.width > 0 and rec.height > 0) {
            const dst_rec: Rectangle = .{
                .x = pen_x + float(g.offsetX) * gscale,
                .y = pen_y + float(g.offsetY) * gscale,
                .width = rec.width * gscale,
                .height = rec.height * gscale,
            };
            img.imageDraw(&self.buf, atlas.image, rec, dst_rec, col);
        }
        pen_x += float(g.advanceX) * gscale;
    }
}

// ---- resolve / export --------------------------------------------------

/// Box-downsample the supersampled buffer into a fresh logical-size RGBA8
/// `Image` (caller frees with `unloadImage`). Averaging is premultiplied so
/// translucent edges resolve correctly.
pub fn resolve(self: *const Canvas) !Image {
    const out: Image = try img.genImageColor(self.gpa, self.w, self.h, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const ss: usize = @intCast(self.ss);
    const sw: usize = @intCast(self.w * self.ss);
    const ow: usize = @intCast(self.w);
    const oh: usize = @intCast(self.h);
    const src: [*]const u8 = @ptrCast(@alignCast(self.buf.data.?));
    const dst: [*]u8 = @ptrCast(@alignCast(out.data.?));
    const n: f32 = float(ss * ss);
    for (0..oh) |oy| {
        for (0..ow) |ox| {
            var ra: f32 = 0;
            var ga: f32 = 0;
            var ba: f32 = 0;
            var aa: f32 = 0;
            for (0..ss) |sy| {
                const row: usize = (oy * ss + sy) * sw;
                for (0..ss) |sx| {
                    const si: usize = (row + ox * ss + sx) * 4;
                    const a: f32 = float(src[si + 3]);
                    ra += float(src[si + 0]) * a;
                    ga += float(src[si + 1]) * a;
                    ba += float(src[si + 2]) * a;
                    aa += a;
                }
            }
            const di: usize = (oy * ow + ox) * 4;
            if (aa > 0) {
                dst[di + 0] = @round(ra / aa);
                dst[di + 1] = @round(ga / aa);
                dst[di + 2] = @round(ba / aa);
                dst[di + 3] = @round(aa / n);
            } else {
                dst[di + 0] = 0;
                dst[di + 1] = 0;
                dst[di + 2] = 0;
                dst[di + 3] = 0;
            }
        }
    }
    return out;
}

/// Resolve + encode to PNG bytes (caller frees the returned slice).
pub fn writePngToMemory(self: *const Canvas) ![]u8 {
    const out: Image = try self.resolve();
    defer img.unloadImage(self.gpa, out);
    return img.exportImageToMemory(self.gpa, out, ".png");
}

/// Resolve, encode, and write `path`. Takes the application's `io` (the
/// `std.Io` chosen in `main`, e.g. from a `std.Io.Threaded`) — same way the
/// rest of zimr threads its allocator. For bytes-in-memory use
/// `writePngToMemory` (no `io` needed).
pub fn savePng(self: *const Canvas, io: std.Io, path: []const u8) !void {
    const png: []u8 = try self.writePngToMemory();
    defer self.gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
}

// ---- clip helpers ---------------------------------------------------------

const testing = std.testing;

test "png_canvas: shapes resolve to a valid PNG (no font needed)" {
    const opts: Options = .{ .ss = 3, .background = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    var canvas: Canvas = try Canvas.init(testing.allocator, 80, 60, opts);
    defer canvas.deinit();
    canvas.fillRect(.{ .x = 8, .y = 8, .w = 30, .h = 18 }, .{ .r = 30, .g = 120, .b = 220, .a = 120 });
    canvas.line(.{ 2, 2 }, .{ 78, 58 }, .{ .color = .{ .r = 220, .g = 40, .b = 40, .a = 255 }, .thickness = 2.0 });
    canvas.circleFilled(.{ 60, 18 }, 8, .{ .r = 250, .g = 190, .b = 60, .a = 255 });
    canvas.triangleFilled(.{ 10, 55 }, .{ 40, 35 }, .{ 70, 55 }, .{ .r = 60, .g = 200, .b = 120, .a = 160 });
    const data: []u8 = try canvas.writePngToMemory();
    defer testing.allocator.free(data);
    try testing.expect(data.len > 100);
    try testing.expect(data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G');
}

test "png_canvas: clip rect intersect" {
    const r: ?Rect = clipRect(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ .x = 50, .y = 50, .w = 100, .h = 100 });
    try testing.expect(r != null);
    try testing.expectEqual(@as(f32, 50), r.?.x);
    try testing.expectEqual(@as(f32, 50), r.?.w);
    const empty: ?Rect = clipRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 50, .y = 50, .w = 10, .h = 10 });
    try testing.expect(empty == null);
}
