//! src/WgpuGl.zig — the WebGPU `gl: anytype` adapter (the "third renderer").
//!
//! `src/renderer_trait.zig` defines a comptime trait (`assertIsGlContext`) plus two
//! adapters — `GlAdapter` (wraps `*rlgl.GlState`, the WebGL path) and
//! `SwAdapter` (wraps `*raster.Context`, the software rasterizer) — so a single
//! `fn drawX(gl: anytype, ...)` drives both with zero overhead. Its own comment
//! says "adding a third renderer is a third adapter struct." This is that third
//! adapter: a WebGPU one, so the SAME scene code runs on rlgl, raster, AND wgpu.
//!
//! It is the spine of two later goals: the bulk example port (scene code stops
//! caring which backend it draws through) and the raster‖wgpu side-by-side demo
//! (N6) — CPU and GPU halves driven by one `shaderMain` AND one `drawScene`.
//!
//! HOW IT WORKS (immediate-mode → batched)
//! The trait is immediate-mode (raylib/rlgl style): `begin(mode)`, then
//! `vertex2f/3f` + `color4ub` + `texCoord2f` per vertex, then `end`. rlgl and
//! raster consume that natively. `Renderer2D` (the WebGPU 2D pipeline) instead
//! wants batched primitives, so this adapter bridges the two: it accumulates
//! the current primitive's vertices, transforms each by the modelview stack
//! top, and on `end` emits triangles/quads into `Renderer2D`'s shapes batch via
//! `WgpuBackend.drawTriangleBatched`. The PROJECTION stack feeds the batch
//! shader's per-frame view-projection UBO — exactly the rlgl/raster split
//! (modelview transforms verts CPU-side; projection lives in the shader).
//!
//! LIFETIME
//! Holds a `*Renderer2D` (long-lived, owns the batch + pipeline) and a
//! `*PassState` (the live render pass, valid only between beginDrawing /
//! endDrawing). Construct per frame via `WgpuGl.init(renderer, pass)`; no
//! allocation, no teardown — like the other two adapters.
//!
//! v1 SCOPE (N4 in wgpu_new_beginnings.md)
//!  * Primitive modes: points/lines/triangles/quads accumulate + emit as
//!    triangles (points/lines degenerate to thin tris is future; for now
//!    `.triangles` + `.quads` are the load-bearing modes the 2D shape API uses).
//!  * `enable/disable/clearColor/clear` are recorded but the heavy lifting
//!    (real scissor, depth toggles) lands with the 2D-parity work in N5; the
//!    trait requires the methods, so they exist and are sound no-ops/recorders.
//!  * texture binding (`setTexture`) swaps the batch's material — wired in N5
//!    when textured 2D lands; for now it forces a flush + records the id.

const renderer_2d = @import("renderer_2d.zig");
const BindGroupHandle = @import("wgpu.zig").BindGroupHandle;
const gpu_iface = @import("gpu_iface.zig");
const raster = @import("raster.zig");
const zm = @import("zm");
const Mat = zm.Mat;
const std_for_tests = @import("std");
const Vec = zm.Vec;
const identity = zm.identity;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const vec4 = zm.vec4;
const translation = zm.translation;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const rotationZ = zm.rotationZ;
const scaling = zm.scaling;
const float = zm.float;

const Renderer2D = renderer_2d.Renderer2D;
const PassState = gpu_iface.PassState;
const Backend = gpu_iface.WgpuBackend;
const Matrix = Mat;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const Rectangle = @import("types.zig").Rectangle;
const draw2d = @import("draw2d.zig");
const WgpuTexture = @import("wgpu_texture.zig").WgpuTexture;
const Texture = @import("types.zig").Texture;
const image_mod = @import("image.zig");
const text2d = @import("text2d.zig");
const Font = @import("types.zig").Font;
const Sprite = @import("Sprite.zig");
const shapes2d = @import("shapes2d.zig");

// Max vertices buffered for one begin/end primitive group before the adapter
// assembles + emits. A single shape (rect, circle fan, polyline) stays well
// under this; it only bounds one immediate-mode group, not the whole frame.
const max_group_vertices: usize = 256;

/// A buffered immediate-mode vertex: position is already in MODELVIEW space
/// (the stack transform applied at vertex-call time); the shader applies the
/// projection. uv + color travel through unchanged.
const GroupVertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

const max_matrix_depth = 32;

fn identityMatrix() Matrix {
    return identity();
}

/// glFrustum: an off-center perspective projection. Column-major to match
/// zm.Mat's row-of-Vec layout (mulMatVec treats it consistently with the rest
/// of the pipeline).
fn frustumMatrix(
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near: f64,
    far: f64,
) Matrix {
    const l: f32 = @floatCast(left);
    const r: f32 = @floatCast(right);
    const b: f32 = @floatCast(bottom);
    const t: f32 = @floatCast(top);
    const n: f32 = @floatCast(near);
    const f: f32 = @floatCast(far);
    const rl: f32 = r - l;
    const tb: f32 = t - b;
    const fn_: f32 = f - n;
    return .{
        vec4(2 * n / rl, 0, 0, 0),
        vec4(0, 2 * n / tb, 0, 0),
        vec4((r + l) / rl, (t + b) / tb, -(f + n) / fn_, -1),
        vec4(0, 0, -(2 * f * n) / fn_, 0),
    };
}

/// Orthographic projection matrix matching glOrtho / rlOrtho. Column-major to
/// match frustumMatrix + the rest of the matrix stack.
fn orthoMatrix(
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near: f64,
    far: f64,
) Matrix {
    const l: f32 = @floatCast(left);
    const r: f32 = @floatCast(right);
    const b: f32 = @floatCast(bottom);
    const t: f32 = @floatCast(top);
    const n: f32 = @floatCast(near);
    const f: f32 = @floatCast(far);
    const rl: f32 = r - l;
    const tb: f32 = t - b;
    const fn_: f32 = f - n;
    return .{
        vec4(2 / rl, 0, 0, 0),
        vec4(0, 2 / tb, 0, 0),
        vec4(0, 0, -2 / fn_, 0),
        vec4(-(r + l) / rl, -(t + b) / tb, -(f + n) / fn_, 1),
    };
}

const ScissorRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Convert a GL-convention scissor (bottom-left origin, framebuffer px, as
/// `beginScissorMode` emits) into a WebGPU-convention `setScissorRect`
/// (top-left origin) clamped to the `[0,rw] x [0,rh]` framebuffer.
///
/// The clamp preserves BOTH edges: clamping a negative left/top edge to 0 also
/// shrinks the width/height, so the right/bottom edge stays at its intended
/// position. The earlier bug clamped the origin but kept the full extent, so a
/// negative x (window dragged/scrolled off-screen left) left the right edge at
/// `0 + w` — hundreds of px past the window — and content spilled to the right.
fn clampScissorRect(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    rw: i32,
    rh: i32,
) ScissorRect {
    // Un-flip: GL y is bottom-left; WebGPU is top-left. top_y = rh - (y + h).
    const top_y: i32 = rh - (y + h);
    const x0: i32 = if (x < 0) 0 else if (x > rw) rw else x;
    const x1: i32 = if (x + w < 0) 0 else if (x + w > rw) rw else x + w;
    const y0: i32 = if (top_y < 0) 0 else if (top_y > rh) rh else top_y;
    const y1: i32 = if (top_y + h < 0) 0 else if (top_y + h > rh) rh else top_y + h;
    return .{
        .x = x0,
        .y = y0,
        .w = if (x1 > x0) x1 - x0 else 0,
        .h = if (y1 > y0) y1 - y0 else 0,
    };
}

/// The file *is* WgpuGl: `@import("WgpuGl.zig")` gives this struct.
const WgpuGl = @This();

renderer_slot: *?Renderer2D,
pass: *PassState,

/// Opaque back-pointer to the owning `App` (set by App.beginDrawing). Lets
/// the `z.beginDrawing`/`z.endDrawing` free functions reach the App's
/// frame/pass lifecycle from just the `gl` handle. Null when the WgpuGl is
/// constructed standalone (e.g. in unit tests).
owner: ?*anyopaque = null,
/// Backing render-target dimensions (px), set by beginDrawing. Used to
/// CLAMP scissor rects — WebGPU REJECTS a scissor larger than the render
/// area (unlike GL, which clamps), so disable(.scissor_test) must reset to
/// exactly these, not a giant rect.
render_w: u32 = 0,
render_h: u32 = 0,

// Current immediate-mode primitive group.
mode: raster.DrawMode = .triangles,
group: [max_group_vertices]GroupVertex = undefined,
group_len: usize = 0,

// Per-vertex "current" attributes (raylib/rlgl semantics: color + texcoord
// are sticky state applied to each subsequent vertex call).
cur_color: [4]u8 = .{ 255, 255, 255, 255 },
cur_uv: [2]f32 = .{ 0, 0 },

// Matrix stacks. `which` selects the stack a matrixMode/loadIdentity/
// multMatrix call targets. Only the modelview top is applied to vertices
// here; the projection top is pushed to the shader UBO by the frame setup.
which: raster.MatrixMode = .modelview,
modelview: Matrix = identityMatrix(),
projection: Matrix = identityMatrix(),
// rlPushMatrix / rlPopMatrix save stack for the MODELVIEW top (rlgl depth 32).
// The 2D matrix API (drawTextureNPatch, rotated text via rlTranslatef/rlRotatef)
// pushes a translate+rotate then pops. Projection is set per-frame by the frame
// setup and is not stacked here, matching the modelview/projection split above.
modelview_stack: [max_matrix_depth]Matrix = undefined,
stack_depth: usize = 0,

pub fn init(renderer_slot: *?Renderer2D, pass: *PassState) WgpuGl {
    return .{ .renderer_slot = renderer_slot, .pass = pass };
}

/// The live Renderer2D. SINGLE SOURCE OF TRUTH: `renderer_slot` points at
/// `App.renderer_2d`, so this can never be a stale copy, and there is no field
/// to wire per-frame. Asserts (via assertf, so it fires even in ReleaseSmall —
/// surfacing on the page log rather than compiling out) that the renderer has
/// been created; a use-before-init is a clear message AT THE SOURCE instead of
/// an `undefined`/null deref that crashes far away.
pub fn renderer(gl: *WgpuGl) *Renderer2D {
    zm.assertf(
        gl.renderer_slot.* != null,
        @src(),
        "WgpuGl.renderer used before the Renderer2D was created (ensureFrame/beginDrawing must run first)",
        .{},
    );
    return &gl.renderer_slot.*.?;
}

// ---- Immediate-mode primitives -------------------------------------

pub fn begin(self: *WgpuGl, mode: raster.DrawMode) void {
    self.mode = mode;
    self.group_len = 0;
}

pub fn end(self: *WgpuGl) void {
    self.flushGroup();
    self.group_len = 0;
}

pub fn vertex2f(
    self: *WgpuGl,
    x: f32,
    y: f32,
) void {
    self.vertex3f(x, y, 0);
}

pub fn vertex3f(
    self: *WgpuGl,
    x: f32,
    y: f32,
    z: f32,
) void {
    if (self.group_len >= max_group_vertices) {
        // Group overflow: assemble what we have, then keep going. (For the
        // strip-free modes we emit here this never splits a primitive.)
        self.flushGroup();
        self.group_len = 0;
    }
    // Apply the modelview top; the shader applies projection. (z is carried
    // for the transform but the 2D batch is screen-space, so we keep xy.)
    const v: Vec = mulMatVec(self.modelview, vec4(x, y, z, 1));
    self.group[self.group_len] = .{
        .pos = .{ v[0], v[1] },
        .uv = self.cur_uv,
        .color = self.cur_color,
    };
    self.group_len += 1;
}

pub fn color4ub(
    self: *WgpuGl,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) void {
    self.cur_color = .{ r, g, b, a };
}

pub fn texCoord2f(
    self: *WgpuGl,
    u: f32,
    v: f32,
) void {
    self.cur_uv = .{ u, v };
}

/// Bind a texture as the active 2D material (drawn by subsequent
/// vertices). Flushes the current batch first, so geometry before the swap
/// keeps the old texture; geometry after uses `tex`. This is what makes
/// textured quads, the font atlas (N5f), and the raster framebuffer upload
/// (N6) work. raylib's `rlSetTexture` shape. `.invalid` view resets to the
/// built-in white texture (untextured = solid color).
/// Bind a WgpuTexture directly as the active 2D material (flushing first so
/// prior geometry keeps the old texture). Used by the direct textured-2D
/// helpers (drawTexture/drawTextureRec). An `.invalid` view resets to white.
pub fn bindTexture(self: *WgpuGl, tex: WgpuTexture) void {
    // Material-bind dedup: re-binding the texture already staged (e.g. the
    // font atlas rebound per-glyph by drawWithFont) must NOT flush — that
    // turned a batchable text run into one draw call per glyph. Only a real
    // texture CHANGE flushes the staged geometry + swaps the bind group.
    const bg: BindGroupHandle = self.renderer().bindGroupForTexture(tex);
    if (bg == self.renderer().shapes_batch.current_texture_bind_group) {
        return;
    }
    self.flushBeforeMaterialSwap();
    // Route through the per-texture registry (cached by handle) so this
    // texture gets a DISTINCT, persistent bind group — NOT the shared
    // `bind_groups[1]` mutated in place. The shapes batch resolves the bind
    // group lazily at flush time; mutating a shared slot would alias a prior
    // untextured/other-textured draw onto this texture at submit time (the
    // turn-909 black-shapes bug in the CPU|GPU composite). With a distinct
    // handle per texture, bindTexture(tex) and setTexture(id) are equally
    // safe and neither can reintroduce that aliasing.
    self.renderer().shapes_batch.bindTextureGroup(bg);
}

/// gl_iface trait method: bind a texture by its REGISTERED id (the same
/// `setTexture(id: u32)` shape as GlAdapter/SwAdapter). This is what makes
/// the reusable, `gl: anytype`-generic texture+text stack (drawTexturePro,
/// drawWithFont, ...) work through WgpuGl: it resolves the id to the
/// registry's prebuilt material bind group. id 0 = white/untextured.
pub fn setTexture(self: *WgpuGl, id: u32) void {
    const bg: BindGroupHandle = self.renderer().lookupBindGroup(id);
    if (bg == self.renderer().shapes_batch.current_texture_bind_group) {
        return;
    }
    self.flushBeforeMaterialSwap();
    self.renderer().shapes_batch.bindTextureGroup(bg);
}

/// Flush the in-flight immediate group + the batch (before a material swap
/// or pass-state change like scissor), so geometry already submitted keeps
/// the texture/clip it was drawn with.
pub fn flushBeforeMaterialSwap(self: *WgpuGl) void {
    self.flushGroup();
    self.group_len = 0;
    Backend.flushBatch(self.pass);
}

/// gl_iface trait: per-vertex normal. 2D drawing ignores it (the shapes
/// pipeline has no lighting), but drawTexturePro calls it, so it must exist.
pub fn normal3f(
    self: *WgpuGl,
    x: f32,
    y: f32,
    z: f32,
) void {
    _ = self;
    _ = x;
    _ = y;
    _ = z;
}

// ---- Matrix stack --------------------------------------------------

pub fn matrixMode(self: *WgpuGl, mode: raster.MatrixMode) void {
    self.which = mode;
}

pub fn loadIdentity(self: *WgpuGl) void {
    switch (self.which) {
        .projection => self.projection = identityMatrix(),
        else => self.modelview = identityMatrix(),
    }
}

pub fn multMatrix(self: *WgpuGl, m: *const Matrix) void {
    switch (self.which) {
        .projection => self.projection = mulMat(self.projection, m.*),
        else => self.modelview = mulMat(self.modelview, m.*),
    }
}

/// rlPushMatrix: save the current MODELVIEW so a subsequent translate/rotate/scale
/// can be undone with popMatrix. On overflow we clamp (rlgl records an error; the
/// 2D depth is shallow so this never bites in practice).
pub fn pushMatrix(self: *WgpuGl) void {
    if (self.stack_depth >= max_matrix_depth) {
        return;
    }
    self.modelview_stack[self.stack_depth] = self.modelview;
    self.stack_depth += 1;
}

/// rlPopMatrix: restore the MODELVIEW saved by the matching pushMatrix.
pub fn popMatrix(self: *WgpuGl) void {
    if (self.stack_depth == 0) {
        return;
    }
    self.stack_depth -= 1;
    self.modelview = self.modelview_stack[self.stack_depth];
}

/// rlTranslatef: post-multiply the modelview by a translation (GL order, so the
/// translate applies before earlier transforms when the vertex is multiplied in).
pub fn translate(self: *WgpuGl, x: f32, y: f32, z: f32) void {
    self.modelview = mulMat(self.modelview, translation(x, y, z));
}

/// Post-multiply the modelview by a rotation of `angle_rad` radians about axis
/// (x, y, z). 2D and text paths use (0, 0, 1); the three principal axes are
/// supported and anything else falls back to Z. (`rlRotatef`, the raylib
/// degree-taking name, is a thin shim over this — see text2d.)
pub fn rotate(
    self: *WgpuGl,
    angle_rad: f32,
    x: f32,
    y: f32,
    z: f32,
) void {
    const m: Matrix = if (x != 0 and y == 0 and z == 0)
        rotationX(angle_rad)
    else if (y != 0 and x == 0 and z == 0)
        rotationY(angle_rad)
    else
        rotationZ(angle_rad);
    self.modelview = mulMat(self.modelview, m);
}

/// rlScalef: post-multiply the modelview by a non-uniform scale.
pub fn scale(self: *WgpuGl, x: f32, y: f32, z: f32) void {
    self.modelview = mulMat(self.modelview, scaling(x, y, z));
}

// ---- Unified draw2d surface (see notes/drawing_api.md). One-line delegations to
// the shared emit helpers, which decompose to setTexture(0)+begin+vertex2f.
// Rounding is deferred; outline circles fall back to filled for now.

pub fn rect(self: *WgpuGl, r: Rectangle, opts: draw2d.RectOpts) void {
    if (opts.outline <= 0) {
        draw2d.rectFilled(self, r, opts.color);
    } else {
        draw2d.rectOutline(self, r, opts.color, opts.outline);
    }
}

pub fn rectXYWH(
    self: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    opts: draw2d.RectOpts,
) void {
    self.rect(.{ .x = x, .y = y, .width = w, .height = h }, opts);
}

pub fn circle(
    self: *WgpuGl,
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

/// Resolve a Sprite to a registered GPU texture id, uploading `sprite.image` and
/// registering it (engine-owned) on first draw. The residency is cached by the
/// Sprite's monotonic id in the renderer, so each Sprite uploads exactly once.
fn resolveSprite(self: *WgpuGl, sprite: Sprite) u32 {
    const r: *Renderer2D = self.renderer();
    if (r.findSprite(sprite.id)) |id| {
        return id;
    }
    const w: u32 = @intCast(sprite.image.width);
    const h: u32 = @intCast(sprite.image.height);
    const bytes: []const u8 = @as([*]const u8, @ptrCast(sprite.image.data.?))[0 .. w * h * 4];
    const wtex: WgpuTexture = WgpuTexture.createFromPixels(r.resources.f.device, r.resources.f.queue, .{
        .pixels = bytes,
        .width = w,
        .height = h,
    });
    const id: u32 = r.registerOwnedTexture(wtex);
    r.cacheSprite(sprite.id, id);
    return id;
}

/// Unified primitive: draw `sprite` (uploaded + cached on first use) into `dst`.
/// Reuses the proven `drawTexturePro` / `drawTextureNPatch` paths.
pub fn image(self: *WgpuGl, dst: Rectangle, sprite: Sprite, opts: draw2d.ImageOpts) void {
    const tex_id: u32 = self.resolveSprite(sprite);
    const img_tex: Texture = .{
        .id = tex_id,
        .width = sprite.image.width,
        .height = sprite.image.height,
        .mipmaps = 1,
        .format = sprite.image.format,
    };
    if (opts.npatch) |np| {
        image_mod.drawTextureNPatch(self, img_tex, np, dst, opts.origin, opts.rotation_rad, opts.tint);
    } else {
        const src: Rectangle = opts.source orelse .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(sprite.image.width),
            .height = @floatFromInt(sprite.image.height),
        };
        image_mod.drawTexturePro(self, img_tex, src, dst, opts.origin, opts.rotation_rad, opts.tint);
    }
}

/// `image` twin taking loose numbers for the destination.
pub fn imageXYWH(
    self: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    sprite: Sprite,
    opts: draw2d.ImageOpts,
) void {
    self.image(.{ .x = x, .y = y, .width = w, .height = h }, sprite, opts);
}

/// Gap primitive: draw an already-loaded GPU `WgpuTexture` into `dst`. Binds the
/// texture directly and emits a textured quad (the same path as raylib
/// `drawTexture`), so there is no per-frame registry churn.
///
/// `opts.source` selects a sub-rectangle **in PIXELS** — the same units as
/// `gl.image` (Sprites) and raylib's `DrawTexturePro`, including raylib's
/// negative-extent rule: a negative `width`/`height` FLIPS that axis, which is
/// how you draw a RenderTexture right-way-up (`.height = -h`). `null` draws the
/// whole texture.
///
/// This primitive used to take raw 0..1 UVs while its doc comment claimed
/// pixels. Every one of its five call sites therefore hand-divided by the
/// texture size (`sr.x / tw`, ...) — five private copies of one transform, none
/// of which could flip. Same bug class as the scissor letterbox: the conversion
/// belongs in the primitive, so it lives here, once.
pub fn texture(
    self: *WgpuGl,
    dst: Rectangle,
    tex: WgpuTexture,
    opts: draw2d.TextureOpts,
) void {
    const tw: f32 = float(@max(tex.width, 1));
    const th: f32 = float(@max(tex.height, 1));
    var ua: f32 = 0;
    var va: f32 = 0;
    var ub: f32 = 1;
    var vb: f32 = 1;
    if (opts.source) |source_in| {
        // Identical normalization to image.zig:drawTexturePro — negative width
        // mirrors u; negative height slides the origin down by |height| and
        // leaves the extent negative, so v runs bottom-to-top.
        var src: Rectangle = source_in;
        var flip_x: bool = false;
        if (src.width < 0) {
            flip_x = true;
            src.width *= -1;
        }
        if (src.height < 0) {
            src.y -= src.height;
        }
        const uv_lo: f32 = src.x / tw;
        const uv_hi: f32 = (src.x + src.width) / tw;
        ua = if (flip_x) uv_hi else uv_lo;
        ub = if (flip_x) uv_lo else uv_hi;
        va = src.y / th;
        vb = (src.y + src.height) / th;
    }
    const cs: f32 = @cos(opts.rotation_rad);
    const sn: f32 = @sin(opts.rotation_rad);
    const ox: f32 = opts.origin[0];
    const oy: f32 = opts.origin[1];
    const dw: f32 = dst.width;
    const dh: f32 = dst.height;
    const c00: Vec2 = texCorner(dst, 0, 0, ox, oy, cs, sn);
    const c10: Vec2 = texCorner(dst, dw, 0, ox, oy, cs, sn);
    const c11: Vec2 = texCorner(dst, dw, dh, ox, oy, cs, sn);
    const c01: Vec2 = texCorner(dst, 0, dh, ox, oy, cs, sn);
    self.bindTexture(tex);
    self.begin(.triangles);
    self.color4ub(opts.tint.r, opts.tint.g, opts.tint.b, opts.tint.a);
    self.texCoord2f(ua, va);
    self.vertex2f(c00[0], c00[1]);
    self.texCoord2f(ub, va);
    self.vertex2f(c10[0], c10[1]);
    self.texCoord2f(ub, vb);
    self.vertex2f(c11[0], c11[1]);
    self.texCoord2f(ua, va);
    self.vertex2f(c00[0], c00[1]);
    self.texCoord2f(ub, vb);
    self.vertex2f(c11[0], c11[1]);
    self.texCoord2f(ua, vb);
    self.vertex2f(c01[0], c01[1]);
    self.end();
    self.bindTexture(.{}); // reset to white so subsequent shapes are solid
}

/// One corner of a (possibly rotated) textured quad: corner `(cx,cy)` relative to
/// the dst top-left, offset by `-origin`, rotated by (cs,sn), placed at dst.pos.
/// Reduces to `dst.pos + (cx,cy)` when origin=0 and rotation=0.
fn texCorner(
    dst: Rectangle,
    cx: f32,
    cy: f32,
    ox: f32,
    oy: f32,
    cs: f32,
    sn: f32,
) Vec2 {
    const rx: f32 = cx - ox;
    const ry: f32 = cy - oy;
    return .{ dst.x + rx * cs - ry * sn, dst.y + rx * sn + ry * cs };
}

// --- gap shape primitives: thin wrappers over shapes2d (host-safe gl:anytype) ---

pub fn lineDashed(
    self: *WgpuGl,
    a: Vec2,
    b: Vec2,
    thick: f32,
    dash: f32,
    gap: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.lineDashedEmit(self, a, b, thick, dash, gap, opts.color);
}

pub fn circleSector(
    self: *WgpuGl,
    center: Vec2,
    radius: f32,
    start_rad: f32,
    end_rad: f32,
    segments: i32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.circleSectorFilled(self, center, radius, start_rad, end_rad, segments, opts.color);
}

pub fn circleSectorLines(
    self: *WgpuGl,
    center: Vec2,
    radius: f32,
    start_rad: f32,
    end_rad: f32,
    segments: i32,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawCircleSectorLines(self, center, radius, start_rad, end_rad, segments, opts.color);
}

pub fn ellipse(
    self: *WgpuGl,
    center: Vec2,
    rx: f32,
    ry: f32,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawEllipseV(self, center, rx, ry, opts.color);
}

pub fn ellipseLines(
    self: *WgpuGl,
    center: Vec2,
    rx: f32,
    ry: f32,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawEllipseLinesV(self, center, rx, ry, opts.color);
}

pub fn triangleLines(
    self: *WgpuGl,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawTriangleLines(self, a, b, c, opts.color);
}

pub fn ring(
    self: *WgpuGl,
    center: Vec2,
    inner: f32,
    outer: f32,
    start_rad: f32,
    end_rad: f32,
    segments: i32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.ringFilled(self, center, inner, outer, start_rad, end_rad, segments, opts.color);
}

pub fn ringLines(
    self: *WgpuGl,
    center: Vec2,
    inner: f32,
    outer: f32,
    start_rad: f32,
    end_rad: f32,
    segments: i32,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawRingLines(self, center, inner, outer, start_rad, end_rad, segments, opts.color);
}

pub fn poly(
    self: *WgpuGl,
    center: Vec2,
    sides: i32,
    radius: f32,
    rotation_rad: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.polyFilled(self, center, sides, radius, rotation_rad, opts.color);
}

pub fn polyLines(
    self: *WgpuGl,
    center: Vec2,
    sides: i32,
    radius: f32,
    rotation_rad: f32,
    opts: draw2d.ShapeOpts,
) void {
    shapes2d.drawPolyLines(self, center, sides, radius, rotation_rad, opts.color);
}

pub fn circleGradient(
    self: *WgpuGl,
    center: Vec2,
    radius: f32,
    inner: Color,
    outer: Color,
) void {
    shapes2d.drawCircleGradient(self, center, radius, inner, outer);
}

pub fn rectGradientVertical(
    self: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    top: Color,
    bottom: Color,
) void {
    draw2d.rectGradientVerticalEmit(self, x, y, w, h, top, bottom);
}

pub fn rectGradientCorners(
    self: *WgpuGl,
    rec: Rectangle,
    tl: Color,
    bl: Color,
    br: Color,
    tr: Color,
) void {
    draw2d.rectGradientCornersEmit(self, rec, tl, bl, br, tr);
}

pub fn triangleFan(self: *WgpuGl, points: []const Vec2, opts: draw2d.ShapeOpts) void {
    draw2d.triangleFanEmit(self, points, opts.color);
}

pub fn splineLinear(
    self: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.splineLinearEmit(self, points, thick, opts.color);
}

pub fn splineBasis(
    self: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.splineBasisEmit(self, points, thick, opts.color);
}

pub fn splineCatmullRom(
    self: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.splineCatmullRomEmit(self, points, thick, opts.color);
}

pub fn splineBezierCubic(
    self: *WgpuGl,
    points: []const Vec2,
    thick: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.splineBezierCubicEmit(self, points, thick, opts.color);
}

pub fn rectRoundedLinesXYWH(
    self: *WgpuGl,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    roundness: f32,
    segments: i32,
    thick: f32,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.rectRoundedLinesEmit(self, x, y, w, h, roundness, segments, thick, opts.color);
}

pub fn line(self: *WgpuGl, a: Vec2, b: Vec2, opts: draw2d.LineOpts) void {
    draw2d.lineEmit(self, a, b, opts.color, opts.thickness);
}

/// Unified primitive: a filled triangle.
pub fn triangle(
    self: *WgpuGl,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    opts: draw2d.ShapeOpts,
) void {
    draw2d.triangleFilled(self, a, b, c, opts.color);
}

/// Unified primitive: draw `str` at `pos`. `opts.font` is required for now (the
/// sink default is deferred — a null font draws nothing). Renders via the same
/// host-safe glyph path as raylib `drawText`.
pub fn text(self: *WgpuGl, pos: Vec2, str: []const u8, opts: draw2d.TextOpts) void {
    const font: *const Font = opts.font orelse return;
    text2d.drawWithFont(self, 0, font.*, str, pos, opts.size, opts.spacing, opts.color);
}

/// Gap primitive: rotated filled rectangle (raylib DrawRectanglePro).
pub fn rectRotated(
    self: *WgpuGl,
    rec: Rectangle,
    origin: Vec2,
    rotation_rad: f32,
    opts: draw2d.RectOpts,
) void {
    draw2d.rectRotatedFilled(self, rec, origin, rotation_rad, opts.color);
}

/// Gap primitive: rounded filled rectangle (loose numbers, roundness 0..1).
pub fn rectRoundedXYWH(
    self: *WgpuGl,
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
    self: *WgpuGl,
    a: Vec2,
    b: Vec2,
    c: Vec2,
    ca: Color,
    cb: Color,
    cc: Color,
) void {
    draw2d.triangleGradient(self, a, b, c, ca, cb, cc);
}

pub fn frustum(
    self: *WgpuGl,
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near: f64,
    far: f64,
) void {
    // Multiply the active stack by an off-center perspective frustum,
    // matching glFrustum / rlFrustum semantics.
    const m: Matrix = frustumMatrix(left, right, bottom, top, near, far);
    switch (self.which) {
        .projection => self.projection = mulMat(self.projection, m),
        else => self.modelview = mulMat(self.modelview, m),
    }
}

/// Multiply the active matrix stack by an orthographic projection, matching
/// glOrtho / rlOrtho semantics. Mirrors `frustum`. Part of the gl_iface
/// trait so `fn drawX(gl: anytype)` 2D code (e.g. the UI panel's
/// `ortho(0, w, h, 0, -1, 1)` top-left setup) runs on the WGPU backend
/// unchanged.
pub fn ortho(
    self: *WgpuGl,
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
    near: f64,
    far: f64,
) void {
    const m: Matrix = orthoMatrix(left, right, bottom, top, near, far);
    switch (self.which) {
        .projection => self.projection = mulMat(self.projection, m),
        else => self.modelview = mulMat(self.modelview, m),
    }
}

/// Blend recipe. Matches the shape of gl_iface's trait `setBlendMode` (an
/// enum-literal `.alpha` coerces to this), but defined locally so the WGPU
/// backend doesn't depend on gl_iface → rlgl. WgpuGl's 2D pipeline is
/// created with standard alpha blending already, so `.alpha` is native and
/// this is a no-op — present so `gl: anytype` scene code compiles + runs on
/// WGPU. (Seam for swapping the pipeline's blend state when more modes land.)
pub const BlendMode = enum { alpha };
pub fn setBlendMode(self: *WgpuGl, mode: BlendMode) void {
    _ = self;
    switch (mode) {
        .alpha => {}, // already the pipeline's blend state
    }
}

// ---- Render state --------------------------------------------------

pub fn enable(self: *WgpuGl, cap: raster.Capability) void {
    // Real scissor / depth-toggle wiring is N5; the trait needs the method
    // and the no-op is sound (the 2D pipeline's fixed state covers the
    // shape demos). Kept explicit so N5 has the seam.
    _ = self;
    _ = cap;
}

pub fn disable(self: *WgpuGl, cap: raster.Capability) void {
    switch (cap) {
        // Reset the GPU scissor to "everything" (ui.zig's drawing.text ends
        // clipping with `gl.disable(.scissor_test)`). A max-extent rect is
        // clamped to the render area by the GPU, so no surface query needed.
        .scissor_test => {
            self.flushBeforeMaterialSwap();
            @import("wgpu.zig").render_pass.setScissorRect(self.pass.pass, 0, 0, self.render_w, self.render_h);
        },
        else => {},
    }
}

/// Set the GPU scissor rect in BACKING pixels (x,y,w,h). ui.zig's
/// drawing.text clips windows/content via `gl.scissor(...)` (already
/// DPR-scaled + Y-flipped + clamped to the render area by the caller).
/// Flushes first (scissor is pass-state). Negative coords/extents are
/// floored to 0 (WebGPU rejects negatives).
pub fn scissor(
    self: *WgpuGl,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) void {
    self.flushBeforeMaterialSwap();
    const rw: i32 = @intCast(self.render_w);
    const rh: i32 = @intCast(self.render_h);
    // INCOMING coords are GL-convention (bottom-left origin, framebuffer px,
    // as beginScissorMode emits). clampScissorRect un-flips to WebGPU's
    // top-left origin and clamps BOTH edges to the framebuffer so a negative
    // left/top shrinks the width/height instead of letting the right/bottom
    // edge blow past the window (the off-screen-left "spills right" bug).
    const sc: ScissorRect = clampScissorRect(x, y, w, h, rw, rh);
    @import("wgpu.zig").render_pass.setScissorRect(
        self.pass.pass,
        @intCast(sc.x),
        @intCast(sc.y),
        @intCast(sc.w),
        @intCast(sc.h),
    );
}

pub fn clearColor(self: *WgpuGl, c: Color) void {
    // The clear color is applied at beginRenderPass (the frame's clear), not
    // mid-pass; record it for a future clear-within-pass path. No-op now.
    _ = self;
    _ = c;
}

pub fn clear(self: *WgpuGl, mask: raster.ClearMask) void {
    // WebGPU clears at render-pass begin (load op), not via an in-pass
    // command, so an in-pass clear is a no-op here. The frame's clear color
    // is set by beginDrawing.
    _ = self;
    _ = mask;
}

// ---- internals -----------------------------------------------------

/// Assemble the buffered group into triangles and emit them into the 2D
/// shapes batch. `.triangles` consumes vertices in threes; `.quads` (4 per
/// face) becomes two triangles; lines/points are not yet expanded (N5).
fn flushGroup(self: *WgpuGl) void {
    switch (self.mode) {
        .triangles => {
            var i: usize = 0;
            while (i + 2 < self.group_len) : (i += 3) {
                self.emitTriangle(i, i + 1, i + 2);
            }
        },
        .quads => {
            var i: usize = 0;
            while (i + 3 < self.group_len) : (i += 4) {
                self.emitTriangle(i, i + 1, i + 2);
                self.emitTriangle(i, i + 2, i + 3);
            }
        },
        // points / lines: expansion to thin quads is N5; emitting nothing is
        // sound (no spurious geometry) until then.
        else => {},
    }
}

fn emitTriangle(
    self: *WgpuGl,
    a: usize,
    b: usize,
    c: usize,
) void {
    const va: GroupVertex = self.group[a];
    const vb: GroupVertex = self.group[b];
    const vc: GroupVertex = self.group[c];
    Backend.drawTriangleBatched(self.pass, .{
        .p0 = va.pos,
        .p1 = vb.pos,
        .p2 = vc.pos,
        .uv0 = va.uv,
        .uv1 = vb.uv,
        .uv2 = vc.uv,
        .colors = .{ va.color, vb.color, vc.color },
    });
}

// ============================================================================
// Matrix helpers (column-major [4]Vec, matching zm.Mat / glFrustum)
// ============================================================================

// ============================================================================
// Tests — the headline: WgpuGl satisfies the gl_iface trait, and a single
// `fn drawX(gl: anytype)` compiles against all three adapters.
// ============================================================================

const gl_iface = @import("renderer_trait.zig");

test "WgpuGl satisfies the gl_iface trait" {
    // Comptime check: errors at compile time if any required method is missing.
    var dummy_renderer: ?Renderer2D = @as(?Renderer2D, null);
    var dummy_pass: PassState = undefined;
    var gl: WgpuGl = WgpuGl.init(&dummy_renderer, &dummy_pass);
    gl_iface.assertIsGlContext(&gl);
}

test "one `gl: anytype` scene fn compiles against WgpuGl" {
    // This is the whole point of the adapter: scene code written once runs on
    // any renderer. We only need it to COMPILE + instantiate against WgpuGl
    // (the runtime draw path needs a live pass + GPU). Calling it with a
    // WgpuGl instantiates the generic fn for this type, proving the trait
    // surface matches; drawTriangleBatched is a no-op when the batch is unset.
    const Scene = struct {
        fn draw(gl: anytype) void {
            gl_iface.assertIsGlContext(gl);
            gl.matrixMode(.modelview);
            gl.loadIdentity();
            gl.begin(.triangles);
            gl.color4ub(255, 0, 0, 255);
            gl.vertex2f(0, 0);
            gl.vertex2f(1, 0);
            gl.vertex2f(0, 1);
            gl.end();
        }
    };
    var dummy_renderer: ?Renderer2D = @as(?Renderer2D, null);
    var dummy_pass: PassState = undefined;
    dummy_pass.batch = null; // emits become no-ops
    var gl: WgpuGl = WgpuGl.init(&dummy_renderer, &dummy_pass);
    Scene.draw(&gl);
}

// Moved from renderer_trait.zig (structure-plan S0): the impl asserts its own
// trait conformance — and the old placement made trait↔impl a cycle.
test "assertIsGlContext: WgpuGl satisfies the trait" {
    // Compile-time check; if this doesn't fail to compile, the live
    // renderer has every required method (GL-retirement P5: this
    // replaces the GlAdapter check).
    var dummy: WgpuGl = undefined;
    gl_iface.assertIsGlContext(&dummy);
}

// ----------------------------------------------------------------------------
// Scissor clamp (pure, unit-tested) — see WgpuGl.scissor for usage.

test "clampScissorRect: in-bounds rect keeps its size" {
    const sc: ScissorRect = clampScissorRect(100, 100, 400, 200, 1080, 2000);
    try std_for_tests.testing.expectEqual(@as(i32, 100), sc.x);
    try std_for_tests.testing.expectEqual(@as(i32, 400), sc.w);
}

test "clampScissorRect: off-screen-left preserves the right edge" {
    // x=-500, w=884 in a 1080-wide target: right edge intended at 384.
    // The bug left width=884 (right edge 884); the fix gives width=384.
    const sc: ScissorRect = clampScissorRect(-500, 100, 884, 200, 1080, 2000);
    try std_for_tests.testing.expectEqual(@as(i32, 0), sc.x);
    try std_for_tests.testing.expectEqual(@as(i32, 384), sc.w);
}

test "clampScissorRect: off-screen-right clamps width to framebuffer" {
    const sc: ScissorRect = clampScissorRect(900, 100, 884, 200, 1080, 2000);
    try std_for_tests.testing.expectEqual(@as(i32, 900), sc.x);
    try std_for_tests.testing.expectEqual(@as(i32, 180), sc.w);
}

test "clampScissorRect: fully off-screen left yields zero width" {
    const sc: ScissorRect = clampScissorRect(-2000, 100, 884, 200, 1080, 2000);
    try std_for_tests.testing.expectEqual(@as(i32, 0), sc.x);
    try std_for_tests.testing.expectEqual(@as(i32, 0), sc.w);
}

test "clampScissorRect: y un-flip with top clamp preserves bottom edge" {
    // y=500,h=200,rh=600 => top_y = 600-700 = -100 (clamped to 0); the bottom
    // edge top_y+h = 100 is preserved, so height = 100.
    const sc: ScissorRect = clampScissorRect(0, 500, 100, 200, 1080, 600);
    try std_for_tests.testing.expectEqual(@as(i32, 0), sc.y);
    try std_for_tests.testing.expectEqual(@as(i32, 100), sc.h);
}
