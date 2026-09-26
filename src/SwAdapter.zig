//! lint:alias SwAdapter
//! src/SwAdapter.zig - the raster (software rasterizer) renderer-trait adapter.
//!
//! Wraps `*raster.Context` behind the `gl: anytype` renderer interface so the
//! SAME scene-drawing code runs on the software rasterizer and on the GPU
//! backends. Lives in its own file (NOT renderer_trait.zig) so it carries ZERO
//! dependency on the GL backend (rlgl) - the WebGPU side imports this directly
//! to drive the software half of the CPU|GPU side-by-side demo. renderer_trait.zig
//! re-exports `SwAdapter` from here for the GL-side demos.

const raster = @import("raster.zig");
const zm = @import("zm");
const turnsFromRad = zm.turnsFromRad;
const Mat = zm.Mat;

const Color = zm.Color;
const Vec2 = zm.Vec2;
const Rectangle = @import("types.zig").Rectangle;
const Font = @import("types.zig").Font;
const text2d = @import("text2d.zig");
const draw2d = @import("draw2d.zig");
const Matrix = Mat;

/// The file *is* the SwAdapter: `@import("SwAdapter.zig")` gives this struct.
const SwAdapter = @This();

/// Blend recipe shared across the renderer adapters. Minimal by design - the
/// demos only need standard alpha compositing; more recipes get added here when
/// a real use appears. (Lifted out of renderer_trait.zig so it's backend-neutral.)
pub const BlendMode = enum {
    /// `out = src * src.a + dst * (1 - src.a)`. raster: `(.src_alpha,
    /// .one_minus_src_alpha)`; rlgl: `RL_BLEND_ALPHA`.
    alpha,
};

ctx: *raster.Context,

pub fn init(ctx: *raster.Context) SwAdapter {
    return .{ .ctx = ctx };
}

pub fn begin(self: *SwAdapter, mode: raster.DrawMode) void {
    self.ctx.begin(mode);
}

pub fn end(self: *SwAdapter) void {
    self.ctx.end();
}

pub fn vertex2f(
    self: *SwAdapter,
    x: f32,
    y: f32,
) void {
    self.ctx.vertex2f(x, y);
}

pub fn vertex3f(
    self: *SwAdapter,
    x: f32,
    y: f32,
    z: f32,
) void {
    self.ctx.vertex3f(x, y, z);
}

pub fn color4ub(
    self: *SwAdapter,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) void {
    self.ctx.color4ub(r, g, b, a);
}

pub fn texCoord2f(
    self: *SwAdapter,
    u: f32,
    v: f32,
) void {
    self.ctx.texCoord2f(u, v);
}

pub fn normal3f(
    self: *SwAdapter,
    x: f32,
    y: f32,
    z: f32,
) void {
    self.ctx.normal3f(x, y, z);
}

pub fn setTexture(self: *SwAdapter, id: u32) void {
    self.ctx.setTexture(id);
}

// ---- Unified draw2d surface (see notes/drawing_api.md). Same one-line
// delegations as WgpuGl to the shared emit helpers; identical call sites.

pub fn rect(self: *SwAdapter, r: Rectangle, opts: draw2d.RectOpts) void {
    if (opts.outline <= 0) {
        draw2d.rectFilled(self, r, opts.color);
    } else {
        draw2d.rectOutline(self, r, opts.color, opts.outline);
    }
}

pub fn rectXYWH(
    self: *SwAdapter,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: draw2d.RectOpts,
) void {
    self.rect(.{ .x = x, .y = y, .width = w, .height = h }, opts);
}

pub fn circle(
    self: *SwAdapter,
    center: Vec2,
    radius: f32,
    opts: draw2d.CircleOpts,
) void {
    if (opts.outline <= 0) {
        draw2d.circleFilled(self, center, radius, opts.color, opts.segments);
    } else {
        draw2d.circleOutline(self, center, radius, opts.color, opts.outline, opts.segments);
    }
}

/// Unified primitive: a thick line from `a` to `b`.
pub fn line(self: *SwAdapter, a: Vec2, b: Vec2, opts: draw2d.LineOpts) void {
    draw2d.lineEmit(self, a, b, opts.color, opts.thickness);
}

/// Unified primitive: a filled triangle.
pub fn triangle(
    self: *SwAdapter,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.triangleFilled(self, a, b, c, opts.color);
}

/// Unified primitive: draw `str` at `pos`. `opts.font` required for now (sink
/// default deferred). Same host-safe glyph path as the GPU backend.
pub fn text(self: *SwAdapter, pos: Vec2, str: []const u8, opts: draw2d.TextOpts) void {
    const font: *const Font = opts.font orelse return;
    text2d.drawWithFont(self, 0, font.*, str, pos, opts.size, opts.spacing, opts.color);
}

/// Gap primitive: rotated filled rectangle.
pub fn rectRotated(
    self: *SwAdapter,
    rec: Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    opts: draw2d.RectOpts,
) void {
    draw2d.rectRotatedFilled(self, rec, origin, turnsFromRad(rotation_rad), opts.color);
}

/// Gap primitive: rounded filled rectangle (loose numbers, roundness 0..1).
pub fn rectRoundedXYWH(
    self: *SwAdapter,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: u32,
    opts: draw2d.RectOpts,
) void {
    draw2d.rectRoundedFilled(self, x, y, w, h, roundness, segments, opts.color);
}

/// Gap primitive: triangle with a per-vertex (Gouraud) color.
pub fn triangleGradient(
    self: *SwAdapter,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    ca: Color,
    cb: Color,
    cc: Color,
) void {
    draw2d.triangleGradient(self, a, b, c, ca, cb, cc);
}

pub fn matrixMode(self: *SwAdapter, mode: raster.MatrixMode) void {
    self.ctx.matrixMode(mode);
}

pub fn loadIdentity(self: *SwAdapter) void {
    self.ctx.loadIdentity();
}

pub fn multMatrix(self: *SwAdapter, m: *const Matrix) void {
    self.ctx.multMatrix(m);
}

pub fn frustum(
    self: *SwAdapter,
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near_plane: f64,
    far_plane: f64,
) void {
    self.ctx.frustum(left, right, bottom, top, near_plane, far_plane);
}

pub fn ortho(
    self: *SwAdapter,
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near_plane: f64,
    far_plane: f64,
) void {
    self.ctx.ortho(left, right, bottom, top, near_plane, far_plane);
}

pub fn enable(self: *SwAdapter, cap: raster.Capability) void {
    self.ctx.enable(cap);
}

pub fn disable(self: *SwAdapter, cap: raster.Capability) void {
    self.ctx.disable(cap);
}

pub fn clearColor(self: *SwAdapter, c: Color) void {
    self.ctx.clearColor(c);
}

pub fn clear(self: *SwAdapter, mask: raster.ClearMask) void {
    self.ctx.clear(mask);
}

/// Translate `BlendMode.alpha` to raster's
/// `(.src_alpha, .one_minus_src_alpha)` factor pair.  See the
/// matching `GlAdapter.setBlendMode` doc.
pub fn setBlendMode(self: *SwAdapter, mode: BlendMode) void {
    switch (mode) {
        .alpha => self.ctx.blendFunc(.src_alpha, .one_minus_src_alpha),
    }
}
