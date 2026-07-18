//! src/raster_shader.zig — run zimr fragment shaders on the CPU.
//!
//! Companion to the SPIR-V/GLSL/WebGL2 pipeline.  The same shader
//! source (`pub fn shaderMain(io: Io) Out`) is dispatched per-pixel
//! into an `raster.Context`'s color attachment.  Same iface schema,
//! same logic, same UBO struct — bit-for-bit identical Zig code,
//! just compiled for x86_64/wasm rather than SPIR-V.
//!
//! Used by `examples/mandel_sidebyside` (left-half CPU /
//! right-half GPU side-by-side) and any future "shader as library"
//! consumer that wants pure-CPU pixel work.
//!
//! See `src/notes/software_shaders.md` for the design rationale.
//! S3 of that plan is what this file implements.
//!
//! Lifetime + threading:
//!   - The dispatcher reads from `base_io` (the caller-supplied Io
//!     template) and writes to the raster framebuffer's color
//!     attachment.  No internal allocations.
//!   - Single-threaded.  A future enhancement could parallelize
//!     rows; the API doesn't expose threading state, so adding it
//!     is non-breaking.
//!   - The shader kernel is called once per pixel; if the kernel
//!     references samplers (S2+ work), the texture pointers must
//!     stay valid for the duration of the dispatch call.
//!
//! Performance:
//!   - Naive scalar.  ~2-5M pixels/sec on a modern x86_64 release
//!     build for mandelbrot.  Adequate for a 400×450 side-by-side
//!     viewer at interactive frame rates.
//!   - SIMD-batched fast path deferred; the per-pixel branch in the
//!     mandelbrot loop limits the benefit anyway.

const std = @import("std");
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const raster = @import("raster.zig");
const raster_pixel = @import("raster_pixel.zig");
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const float64 = zm.float64;
const float = zm.float;
const Vec2i = zm.Vec2i;
const ceili = zm.ceili;
const floori = zm.floori;
const roundi = zm.roundi;

/// Rectangle in framebuffer pixels.  Origin top-left, +Y down (matches
/// raster's natural buffer layout, same as GL's `glReadPixels` and GLSL
/// `gl_FragCoord` once Y is flipped at compose time).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Dispatch a fragment shader over every pixel in `rect`.
///
/// `ShaderModule` is comptime — typically the result of `@import(
/// "mandelbrot_fs.zig")`.  It must declare `pub const Io = struct {
/// ... }`, `pub const Out = struct { out_color: Vec4, ... }`, and
/// `pub fn shaderMain(io: Io) Out`.  Codegen emits the `Io`/`Out`
/// types into `io.zig`, and the shader source defines `shaderMain`
/// — so any shader on the new shape is dispatch-ready for free.
///
/// `base_io` is the template Io.  The dispatcher overrides
/// `frag_tex_coord` per-pixel (computed from the rect-relative
/// position); every other field is copied verbatim.  Typical usage:
///   - Set `base_io.u` to the UBO struct you'd push to the GPU.
///   - Leave `base_io.frag_tex_coord = undefined` — it'll be
///     overwritten.
///   - Set `base_io.frag_color = .{1, 1, 1, 1}` (engine default).
///
/// Pixel coordinates: `frag_tex_coord` is normalized to [0, 1] over
/// the rect's bounds, matching the GPU pipeline's varying behavior
/// when a fullscreen quad spans the rect's UVs.  For mandelbrot
/// specifically: `Ubo.resolution` should be set to `(rect.w,
/// rect.h)` so the screen-to-complex math produces the same view
/// as the GPU side.
///
/// Writes go to the raster context's active color attachment via
/// `colorBufferBytesMut`.  Rect is clipped to the framebuffer; out-
/// of-bounds pixels are dropped (not wrapped).  No depth test, no
/// blending — overwrites whatever's there.
pub fn dispatchFragmentShader(
    ctx: *raster.Context,
    comptime ShaderModule: type,
    base_io: ShaderModule.Io,
    rect: Rect,
) void {
    // Resolve framebuffer.  Done once outside the inner loops; the
    // slice + dims + format don't change during the call.
    const fb_bytes: []u8 = ctx.colorBufferBytesMut();
    const fb_dims: Vec2i = ctx.colorBufferDims();
    const fb_format: raster_pixel.PixelFormat = ctx.colorBufferFormat();

    // Pick the right writeColor codec.  This is a runtime lookup
    // because the framebuffer's format isn't known at comptime —
    // could be color_r8g8b8a8 (default) or any other.
    const writer: raster_pixel.WriteColorFn = blk: {
        if (raster_pixel.write_color_table.get(fb_format)) |fn_ptr| {
            break :blk fn_ptr;
        }
        // Format has no writer (depth-only or unsupported color
        // format).  Caller error; bail out silently — no pixels are
        // written.  Documented behavior: dispatcher is a no-op
        // against an incompatible framebuffer.
        return;
    };

    const stride_x: u32 = @intCast(raster_pixel.pixel_format_size.get(fb_format));

    // Clip rect to framebuffer.  `rect.x` may be negative; the
    // start indices clamp to 0.  `end_x` / `end_y` clamp to fb_dims.
    const start_x: i32 = @max(rect.x, 0);
    const start_y: i32 = @max(rect.y, 0);
    const end_x: i32 = @min(rect.x + rect.w, fb_dims[0]);
    const end_y: i32 = @min(rect.y + rect.h, fb_dims[1]);
    if (end_x <= start_x or end_y <= start_y) {
        return;
    }

    const rect_w_f: f32 = float(rect.w);
    const rect_h_f: f32 = float(rect.h);
    const fb_w: u32 = @intCast(fb_dims[0]);

    var py: i32 = start_y;
    while (py < end_y) : (py += 1) {
        const local_y: i32 = py - rect.y;
        // v with screen-BOTTOM = 0, screen-TOP = 1 — matching the GPU fullscreen
        // triangle's frag_tex_coord (drawFullscreenTriangle), so a shader that
        // reads frag_tex_coord renders the SAME orientation on the software
        // dispatcher and the GPU. (Row 0 is the top of the framebuffer, hence
        // 1 - row/height.) This is the single place the CPU<->GPU UV convention
        // is reconciled; do not add per-demo Y-flips.
        const v: f32 = 1.0 - float(local_y) / rect_h_f;
        var px: i32 = start_x;
        while (px < end_x) : (px += 1) {
            const local_x: i32 = px - rect.x;
            const u: f32 = float(local_x) / rect_w_f;

            var io: ShaderModule.Io = base_io;
            io.frag_tex_coord = .{ u, v };

            const out: ShaderModule.Out = ShaderModule.shaderMain(io);

            // Linear vec4 -> framebuffer bytes.  The Out struct's
            // color-output field is the FIRST `Vec` field
            // — by convention shaders have one such field per pixel
            // (e.g. `out_color`, `final_color`, `frag_out`).  Discover
            // it at comptime so the dispatcher works against any
            // shader on the new shape without naming conventions.
            //
            // Future: if a shader needs multiple render targets
            // (MRT), extend this to write all `Vec`
            // fields into successive color attachments.
            const out_field_name: []const u8 = comptime blk: {
                const oti = @typeInfo(ShaderModule.Out).@"struct";
                for (oti.field_names, oti.field_types) |fname, ftype| {
                    if (ftype == Vec) {
                        break :blk fname;
                    }
                }
                @compileError("Out struct must have a Vec field");
            };
            const out_color: Vec = @field(out, out_field_name);
            const color_arr: [4]f32 = .{
                out_color[0],
                out_color[1],
                out_color[2],
                out_color[3],
            };
            const idx: u32 = @as(u32, @intCast(py)) * fb_w + @as(u32, @intCast(px));
            // For 4-byte-per-pixel formats, writeColor expects `idx`
            // to be the pixel index (it multiplies internally).  For
            // 1-byte formats (grayscale) it expects a byte index.
            // We pass pixel index here, matching the canonical
            // color_r8g8b8a8 case.
            _ = stride_x; // reserved for non-canonical stride handling
            writer(fb_bytes, &color_arr, idx);
        }
    }
}

// ---- Vertex shader dispatch ----------------------------------------
//
// S7 of the software-shader plan.  The CPU dispatcher analogue for
// fragment shaders, but operating per-vertex.  Output is the
// transformed Out struct for each input vertex (including the
// auto-emitted `position: Vec` clip-space field).
// Callers feed this through the rasterizer below.

/// A single vertex's transformed Out + interpolation context.
/// The caller indexes into the array by vertex ID.
pub fn VertexOut(comptime ShaderModule: type) type {
    return ShaderModule.Out;
}

/// Run a VS over every vertex of an indexed mesh.  Writes results
/// into `vertex_outs` (caller-allocated, length == vertex_count).
///
/// `vertex_attrs_fn` is a comptime callback that produces the
/// per-vertex Io.  Lets the caller decide how to source attributes
/// (interleaved buffer, separate streams, generated procedurally,
/// etc.) without forcing a single layout.
///
/// Pattern:
/// ```zig
/// var outs: [vertex_count]ShaderModule.Out = undefined;
/// dispatchVertexShader(ShaderModule, &outs, base_io,
///     vertex_count, struct {
///         pub fn attrs(vid: u32, io: *ShaderModule.Io) void {
///             io.vertex_position = positions[vid];
///             io.vertex_tex_coord = uvs[vid];
///         }
///     }.attrs);
/// ```
pub fn dispatchVertexShader(
    comptime ShaderModule: type,
    vertex_outs: []ShaderModule.Out,
    base_io: ShaderModule.Io,
    vertex_count: u32,
    comptime fillAttrs: fn (u32, *ShaderModule.Io) void,
) void {
    var vid: u32 = 0;
    while (vid < vertex_count) : (vid += 1) {
        var io: ShaderModule.Io = base_io;
        fillAttrs(vid, &io);
        vertex_outs[vid] = ShaderModule.shaderMain(io);
    }
}

// ---- Triangle rasterizer ------------------------------------------
//
// Takes the dispatchVertexShader output + an index buffer + a
// fragment ShaderModule, produces pixels.  Edge-function approach
// (Pineda 1988) — robust against degenerate triangles, easy to
// SIMD-ify later.  Perspective-correct varying interpolation via
// 1/w lerping.

/// Rasterize an indexed triangle mesh.  `vertex_outs` comes from
/// dispatchVertexShader; `indices` references it.  For each
/// triangle, the rasterizer:
///   1. Performs clip-space → NDC → screen-space division.
///   2. Computes triangle bounding box, clips to viewport.
///   3. For each pixel in the box, computes barycentric coords
///      via edge functions.
///   4. If all three are non-negative (inside the triangle),
///      perspective-correctly interpolates the varyings and calls
///      the FS.
///
/// `connect(vs_out)` builds the FS Io from a single interpolated VS
/// Out — caller-supplied so the FS can have a different Io shape
/// than the VS Out (e.g. additional uniforms not in the VS).
/// Winding-order convention for `rasterizeTriangles`.
///
/// `.ccw` (default) matches **wgpu's clip-space CCW front face** — the
/// same convention OpenGL uses with `glFrontFace(GL_CCW)`.  Triangles
/// wound CCW in clip space are front-facing and rendered; CW are
/// back-faces and culled.
///
/// `.cw` flips the rule: clip-space CW is the front face.  Use this if
/// porting code that was hand-tuned to CW geometry.
///
/// `.none` disables back-face culling entirely (renders both faces).
pub const WindingOrder = enum { ccw, cw, none };

/// Depth comparison for `RasterizeOpts.depth_test`. `.less` is the opaque wgpu
/// convention (pass when strictly nearer); `.less_equal` also passes at equal
/// depth, for overlay passes that re-draw the same geometry (decals).
pub const DepthCompare = enum { less, less_equal };

pub const RasterizeOpts = struct {
    /// Front-face convention in CLIP space.  Default matches wgpu/
    /// modern-OpenGL convention so callers don't have to think about
    /// the screen-space Y-flip when laying out vertices.
    front_face: WindingOrder = .ccw,
    /// Depth-test fragments against the context's depth attachment
    /// (compare `.less`, write on pass — the wgpu 3D pipelines'
    /// convention).  NDC z is the wgpu [0, 1] range, interpolated
    /// screen-linearly (z/w is affine in screen space, so the raw
    /// barycentric weights are correct — no perspective division).
    /// Caller clears via `ctx.clearDepth(1.0)` + `ctx.clear(.{ .depth
    /// = true })` between frames, same as the fixed-function path.
    depth_test: bool = false,
    /// Depth comparison used when `depth_test` is on. `.less` (the default)
    /// matches the wgpu 3D pipelines: a fragment passes when it is strictly
    /// nearer than what's stored. `.less_equal` also passes at EQUAL depth —
    /// needed by overlay passes that re-draw the same geometry (e.g. the decal
    /// receiver, whose fragment depth is bit-identical to the surface it paints
    /// onto), matching the GPU's `.less_equal` decal pipeline.
    depth_compare: DepthCompare = .less,
    /// Whether a passing fragment WRITES its depth back. `true` (default) is the
    /// opaque convention. `false` leaves the depth buffer untouched — the
    /// overlay convention (the decal uses `.less_equal_no_write` on the GPU so
    /// stacked decals don't occlude each other or re-fight the surface).
    depth_write: bool = true,
    /// Alpha-blend each fragment OVER the destination using the fixed-
    /// function `src_alpha, one_minus_src_alpha` recipe
    /// (`out = src·src.a + dst·(1-src.a)`), reading the existing colour
    /// back per pixel.  `false` overwrites — matching a wgpu pipeline
    /// with blending disabled, and leaving the depth-only path bit-for-
    /// bit as it was.  Only alpha-over is wired (the retired fixed-
    /// function `triangleKernel` inlined only that recipe too); a non-
    /// alpha-over GL factor pair would route through `ctx.blend_func`.
    blend: bool = false,
};

/// Linear interpolation of a whole VS `Out` (every field, `position`
/// included) between two vertices at parameter `t`.  Same field-type
/// contract as `lerpAny`: `f32` and `@Vector(N, f32)` only.
fn lerpVertex2(comptime Out: type, a: Out, b: Out, t: f32) Out {
    var r: Out = undefined;
    const info = @typeInfo(Out).@"struct";
    inline for (info.field_names, info.field_types) |fname, FieldT| {
        const va: FieldT = @field(a, fname);
        const vb: FieldT = @field(b, fname);
        if (FieldT == f32) {
            @field(r, fname) = va + (vb - va) * t;
        } else {
            const fti = @typeInfo(FieldT);
            if (fti == .vector and fti.vector.child == f32) {
                const ts: FieldT = @splat(t);
                @field(r, fname) = va + (vb - va) * ts;
            } else {
                @compileError("lerpVertex2: unsupported field type " ++ @typeName(FieldT));
            }
        }
    }
    return r;
}

/// Clip a triangle (three VS `Out`s with clip-space `position`) against
/// the near plane `clip.z >= 0`.  Writes up to two triangles into
/// `out_tris` and returns the count (0, 1, or 2).
fn clipTriangleNearPlane(
    comptime Out: type,
    v0: Out,
    v1: Out,
    v2: Out,
    out_tris: *[2][3]Out,
) usize {
    const verts = [3]Out{ v0, v1, v2 };
    // A triangle clipped by one plane yields at most a 4-gon; +1 slot of
    // margin for the on-plane duplicate-vertex case.
    var poly: [5]Out = undefined;
    var n: usize = 0;
    inline for (0..3) |k| {
        const a: Out = verts[k];
        const b: Out = verts[(k + 1) % 3];
        const da: f32 = a.position[2]; // signed distance to the near plane
        const db: f32 = b.position[2];
        const a_in: bool = da >= 0.0;
        const b_in: bool = db >= 0.0;
        if (a_in and n < poly.len) {
            poly[n] = a;
            n += 1;
        }
        if (a_in != b_in and n < poly.len) {
            // one endpoint is strictly behind the plane, so da != db
            const denom: f32 = da - db;
            var t: f32 = 0.0;
            if (denom != 0.0) {
                t = da / denom;
            }
            poly[n] = lerpVertex2(Out, a, b, t);
            n += 1;
        }
    }
    if (n < 3) {
        return 0;
    }
    out_tris[0] = .{ poly[0], poly[1], poly[2] };
    if (n >= 4) {
        out_tris[1] = .{ poly[0], poly[2], poly[3] };
        return 2;
    }
    return 1;
}

/// One triangle edge as an integer edge function E(x,y) = a*x + b*y + c,
/// carrying its top-left fill bias (0 for top/left edges, -1 otherwise).
/// For an edge A->B, E(P) = cross(B-A, P-A).
const EdgeFn = struct {
    a: i64,
    b: i64,
    c: i64,
    bias: i64,

    fn eval(self: EdgeFn, x: i64, y: i64) i64 {
        return self.a * x + self.b * y + self.c;
    }
};

/// Subpixel grid: 4 fractional bits => 1/16 px snapping.
const subpixel_one: i64 = 16;

const subpixel_half: i64 = subpixel_one >> 1;

/// The three edges of a triangle plus its positive doubled area, for
/// watertight integer coverage.  Vertices are snapped from screen-space floats
/// and reordered to positive winding; `swapped` records whether v1/v2 were
/// exchanged so callers can map barycentric weights back to original vertices
/// (lambda_A = e0/area2 for the unchanged v0; e1/e2 follow `swapped`).
const TriCoverage = struct {
    e0: EdgeFn,
    e1: EdgeFn,
    e2: EdgeFn,
    area2: i64,
    swapped: bool,

    /// Sample at the centre of pixel (px,py); true if covered (top-left rule).
    fn covers(self: TriCoverage, px: i32, py: i32) bool {
        const sx: i64 = @as(i64, px) * subpixel_one + subpixel_half;
        const sy: i64 = @as(i64, py) * subpixel_one + subpixel_half;
        const w0: i64 = self.e0.eval(sx, sy) + self.e0.bias;
        const w1: i64 = self.e1.eval(sx, sy) + self.e1.bias;
        const w2: i64 = self.e2.eval(sx, sy) + self.e2.bias;
        return w0 >= 0 and w1 >= 0 and w2 >= 0;
    }

    /// Barycentric weights at the centre of pixel (px,py), mapped back to the
    /// ORIGINAL vertex order passed to `setupTriCoverage` (so [0]=v0, [1]=v1,
    /// [2]=v2).  The top-left bias is excluded here (it is a coverage-only
    /// tie-break); for covered pixels the result is non-negative and sums to 1,
    /// and is the input to perspective-correct interpolation.  f64 division
    /// preserves precision across the large subpixel-squared edge magnitudes.
    fn weights(self: TriCoverage, px: i32, py: i32) [3]f32 {
        const sx: i64 = @as(i64, px) * subpixel_one + subpixel_half;
        const sy: i64 = @as(i64, py) * subpixel_one + subpixel_half;
        const inv_area2: f64 = 1.0 / float64(self.area2);
        const wa: f32 = @floatCast(float64(self.e0.eval(sx, sy)) * inv_area2);
        const wb: f32 = @floatCast(float64(self.e1.eval(sx, sy)) * inv_area2);
        const wc: f32 = @floatCast(float64(self.e2.eval(sx, sy)) * inv_area2);
        if (self.swapped) {
            return .{ wa, wc, wb };
        }
        return .{ wa, wb, wc };
    }
};

const subpixel_one_f: f32 = 16.0;

/// Snap a screen-space coordinate to the integer subpixel grid.
fn snapToSubpixel(v: f32) i64 {
    return roundi(i64, v * subpixel_one_f);
}

/// Build the edge A->B (integer subpixel coords).  Inside is `E >= 0` once the
/// triangle is canonicalised to positive area.  y-DOWN screen space: a top
/// edge is horizontal heading left (dy == 0, dx < 0); a left edge heads
/// downward (dy > 0).  Boundary pixels are filled only on top/left edges.
fn makeEdgeFn(
    ax: i64,
    ay: i64,
    bx: i64,
    by: i64,
) EdgeFn {
    const dx: i64 = bx - ax;
    const dy: i64 = by - ay;
    const top_left: bool = (dy == 0 and dx < 0) or (dy > 0);
    return .{
        .a = ay - by,
        .b = bx - ax,
        .c = ax * by - ay * bx,
        .bias = if (top_left) 0 else -1,
    };
}

/// Build coverage for a triangle from its screen-space vertex positions.
/// Returns null for degenerate (zero-area) triangles.
fn setupTriCoverage(
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
) ?TriCoverage {
    const ax: i64 = snapToSubpixel(x0);
    const ay: i64 = snapToSubpixel(y0);
    var bx: i64 = snapToSubpixel(x1);
    var by: i64 = snapToSubpixel(y1);
    var cx: i64 = snapToSubpixel(x2);
    var cy: i64 = snapToSubpixel(y2);
    var area2: i64 = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
    if (area2 == 0) {
        return null;
    }
    var swapped: bool = false;
    if (area2 < 0) {
        const tx: i64 = bx;
        const ty: i64 = by;
        bx = cx;
        by = cy;
        cx = tx;
        cy = ty;
        area2 = -area2;
        swapped = true;
    }
    return .{
        .e0 = makeEdgeFn(bx, by, cx, cy),
        .e1 = makeEdgeFn(cx, cy, ax, ay),
        .e2 = makeEdgeFn(ax, ay, bx, by),
        .area2 = area2,
        .swapped = swapped,
    };
}

/// Comptime-generic barycentric interpolation for any varying type.
/// Handles `@Vector(N, f32)` and `f32`.  Other types will fail to
/// compile — extend as needed.
fn lerpAny(
    comptime T: type,
    v0: T,
    v1: T,
    v2: T,
    w0: f32,
    w1: f32,
    w2: f32,
) T {
    if (T == f32) {
        return v0 * w0 + v1 * w1 + v2 * w2;
    }
    const info = @typeInfo(T);
    if (info == .vector and info.vector.child == f32) {
        const splat0: T = @splat(w0);
        const splat1: T = @splat(w1);
        const splat_w2: T = @splat(w2);
        return v0 * splat0 + v1 * splat1 + v2 * splat_w2;
    }
    @compileError("lerpAny: unsupported varying type " ++ @typeName(T));
}

/// `connect(vs_out)` builds the FS Io from a single interpolated VS
/// Out — caller-supplied so the FS can have a different Io shape
/// than the VS Out (e.g. additional uniforms not in the VS).
pub fn rasterizeTriangles(
    comptime VsModule: type,
    comptime FsModule: type,
    ctx: *raster.Context,
    vertex_outs: []const VsModule.Out,
    indices: []const u32,
    base_fs_io: FsModule.Io,
    comptime connect: fn (VsModule.Out, *FsModule.Io) void,
    comptime opts: RasterizeOpts,
) void {
    const fb_bytes: []u8 = ctx.colorBufferBytesMut();
    const fb_dims: Vec2i = ctx.colorBufferDims();
    const fb_format: raster_pixel.PixelFormat = ctx.colorBufferFormat();
    const writer: raster_pixel.WriteColorFn = blk: {
        if (raster_pixel.write_color_table.get(fb_format)) |fn_ptr| {
            break :blk fn_ptr;
        }
        return;
    };
    // Depth attachment + codecs, resolved once.  Comptime-gated so a
    // depth-less rasterize compiles to exactly the old code.
    const depth_bytes: []u8 = if (comptime opts.depth_test) ctx.depthBufferBytesMut() else &.{};
    const depth_reader: raster_pixel.ReadDepthFn, const depth_writer: raster_pixel.WriteDepthFn =
        if (comptime opts.depth_test) blk: {
            const depth_format: raster_pixel.PixelFormat = ctx.depthBufferFormat();
            const rd: ?raster_pixel.ReadDepthFn = raster_pixel.read_depth_table.get(depth_format);
            const wr: ?raster_pixel.WriteDepthFn = raster_pixel.write_depth_table.get(depth_format);
            if (rd == null or wr == null) {
                // No depth codec for this attachment format — a caller
                // error; documented no-op like the color-writer bail.
                return;
            }
            break :blk .{ rd.?, wr.? };
        } else .{ undefined, undefined };
    // Colour read-back for blending.  Comptime-gated so a non-blended
    // rasterize never touches the framebuffer for reads; same format as
    // `writer`.  A missing codec is the same documented no-op bail.
    const color_reader: raster_pixel.ReadColorFn = if (comptime opts.blend) blk: {
        if (raster_pixel.read_color_table.get(fb_format)) |rd| {
            break :blk rd;
        }
        return;
    } else undefined;
    const fb_w_i: i32 = fb_dims[0];
    const fb_h_i: i32 = fb_dims[1];
    const fb_w_f: f32 = float(fb_w_i);
    const fb_h_f: f32 = float(fb_h_i);
    const fb_w_u: u32 = @intCast(fb_w_i);
    // Effective scissor/clip rect — full colour-buffer bounds when
    // `.scissor_test` is off (a no-op clamp), the scissor ∩ framebuffer
    // when on.  Honoured by clamping each triangle's bbox below, the
    // same way the fixed-function `triangleKernel` does.
    const scissor: raster.Context.PixelRect = ctx.scissorPixelRect();

    // Comptime-discover the FS output color field name (same trick as
    // dispatchFragmentShader — first Vec in Out).
    const out_field_name: []const u8 = comptime blk: {
        const oti = @typeInfo(FsModule.Out).@"struct";
        for (oti.field_names, oti.field_types) |fname, ftype| {
            if (ftype == Vec) {
                break :blk fname;
            }
        }
        @compileError("FS Out must have a Vec field");
    };

    var i: usize = 0;
    while (i + 2 < indices.len) : (i += 3) {
        const src0: VsModule.Out = vertex_outs[indices[i]];
        const src1: VsModule.Out = vertex_outs[indices[i + 1]];
        const src2: VsModule.Out = vertex_outs[indices[i + 2]];

        // Near-plane clip (wgpu `clip.z >= 0`): a triangle straddling the
        // camera plane is split into 0/1/2 in-front triangles rather than
        // dropped, and every surviving vertex has w > 0 so the divide is
        // well-defined.
        var clipped_tris: [2][3]VsModule.Out = undefined;
        const n_clipped: usize = clipTriangleNearPlane(VsModule.Out, src0, src1, src2, &clipped_tris);
        for (clipped_tris[0..n_clipped]) |tri| {
            const vo0: VsModule.Out = tri[0];
            const vo1: VsModule.Out = tri[1];
            const vo2: VsModule.Out = tri[2];

            const p0: Vec = vo0.position;
            const p1: Vec = vo1.position;
            const p2: Vec = vo2.position;

            // Clipping guarantees w > 0; this only guards FP-degenerate slivers.
            if (p0[3] <= 1e-7 or p1[3] <= 1e-7 or p2[3] <= 1e-7) {
                continue;
            }
            const inv_w0: f32 = 1.0 / p0[3];
            const inv_w1: f32 = 1.0 / p1[3];
            const inv_w2: f32 = 1.0 / p2[3];
            // W=1 affine fast-path: 2D / ortho geometry has w==1 at every vertex
            // (checked on the original w), so perspective-correct interpolation
            // collapses to plain barycentric.  Loop-invariant (per-triangle) so
            // LLVM can unswitch the pixel loop.  The fast path uses the raw
            // barycentric weights directly — they sum to ≈1 (the same ones the
            // depth interp uses raw) — skipping the per-pixel normalize-DIVIDE,
            // worth ≈7% of this path; that shifts ≤1 per channel vs the
            // normalized form (the factor is 1±~6e-8), within GPU-parity bounds.
            const affine: bool = (p0[3] == 1.0 and p1[3] == 1.0 and p2[3] == 1.0);
            const ndc_x0: f32 = p0[0] * inv_w0;
            const ndc_y0: f32 = p0[1] * inv_w0;
            const ndc_x1: f32 = p1[0] * inv_w1;
            const ndc_y1: f32 = p1[1] * inv_w1;
            const ndc_x2: f32 = p2[0] * inv_w2;
            const ndc_y2: f32 = p2[1] * inv_w2;
            // NDC z (wgpu [0,1] range) — only the depth test reads these.
            const ndc_z0: f32 = p0[2] * inv_w0;
            const ndc_z1: f32 = p1[2] * inv_w1;
            const ndc_z2: f32 = p2[2] * inv_w2;

            // NDC → screen (Y-flip: GL +Y up, framebuffer +Y down).
            const sx0: f32 = (ndc_x0 + 1.0) * 0.5 * fb_w_f;
            const sy0: f32 = (1.0 - (ndc_y0 + 1.0) * 0.5) * fb_h_f;
            const sx1: f32 = (ndc_x1 + 1.0) * 0.5 * fb_w_f;
            const sy1: f32 = (1.0 - (ndc_y1 + 1.0) * 0.5) * fb_h_f;
            const sx2: f32 = (ndc_x2 + 1.0) * 0.5 * fb_w_f;
            const sy2: f32 = (1.0 - (ndc_y2 + 1.0) * 0.5) * fb_h_f;

            // Triangle area in screen space (2 × signed area).
            //
            // Sign reasoning: after the NDC→screen Y-flip, a clip-space
            // CCW triangle becomes CW in screen space, producing
            // negative signed area.  So:
            //   `opts.front_face == .ccw` → accept area2 < 0
            //   `opts.front_face == .cw`  → accept area2 > 0
            //   `opts.front_face == .none` → accept either sign (no cull)
            //
            // Degenerate triangles (area == 0) are always skipped to
            // avoid div-by-zero in the barycentric setup.
            //
            // Coverage uses fixed-point integer edge functions on the subpixel
            // grid with the top-left rule (§3), so shared edges are covered
            // exactly once.  `setupTriCoverage` canonicalises to positive area;
            // `cov.swapped` recovers the original screen winding (per the sign
            // reasoning above) for front-face culling.
            const cov: TriCoverage = setupTriCoverage(sx0, sy0, sx1, sy1, sx2, sy2) orelse continue;
            switch (comptime opts.front_face) {
                .ccw => if (!cov.swapped) continue,
                .cw => if (cov.swapped) continue,
                .none => {},
            }

            // Bounding box, clamped to the scissor rect (which is the
            // full viewport when scissor_test is off — so this stays a
            // viewport clamp in the common case).
            const min_x_f: f32 = @min(@min(sx0, sx1), sx2);
            const min_y_f: f32 = @min(@min(sy0, sy1), sy2);
            const max_x_f: f32 = @max(@max(sx0, sx1), sx2);
            const max_y_f: f32 = @max(@max(sy0, sy1), sy2);
            const min_x: i32 = @max(floori(i32, min_x_f), scissor.min_x);
            const min_y: i32 = @max(floori(i32, min_y_f), scissor.min_y);
            const max_x: i32 = @min(ceili(i32, max_x_f), scissor.max_x);
            const max_y: i32 = @min(ceili(i32, max_y_f), scissor.max_y);
            if (max_x <= min_x or max_y <= min_y) {
                continue;
            }

            var py: i32 = min_y;
            while (py < max_y) : (py += 1) {
                var px: i32 = min_x;
                while (px < max_x) : (px += 1) {
                    // Integer coverage (top-left rule) gates the pixel; the
                    // barycentric weights are derived from the same edges and
                    // re-mapped to original v0/v1/v2 order.
                    if (!cov.covers(px, py)) {
                        continue;
                    }
                    const bw: [3]f32 = cov.weights(px, py);
                    const w0: f32 = bw[0];
                    const w1: f32 = bw[1];
                    const w2: f32 = bw[2];

                    const pixel_index: u32 = @as(u32, @intCast(py)) * fb_w_u + @as(u32, @intCast(px));

                    // Early-z: test (and, for opaque passes, write) BEFORE the
                    // varying interpolation and the FS call. `.less` + clip
                    // rejection of the [0,1] NDC band matches the wgpu opaque
                    // pipeline state; `.less_equal` + `depth_write = false` is
                    // the overlay convention (decals re-draw the same surface).
                    // Alpha masking in an overlay FS zeroes out-of-box fragments
                    // via the blend, so skipping the depth write keeps stacked
                    // overlays from occluding each other — the early test stays
                    // sound because no depth is written.
                    if (comptime opts.depth_test) {
                        const frag_z: f32 = w0 * ndc_z0 + w1 * ndc_z1 + w2 * ndc_z2;
                        if (frag_z < 0.0 or frag_z > 1.0) {
                            continue;
                        }
                        const stored_z: f32 = depth_reader(depth_bytes, pixel_index);
                        const fails: bool = switch (comptime opts.depth_compare) {
                            .less => frag_z >= stored_z,
                            .less_equal => frag_z > stored_z,
                        };
                        if (fails) {
                            continue;
                        }
                        if (comptime opts.depth_write) {
                            depth_writer(depth_bytes, frag_z, pixel_index);
                        }
                    }

                    // Perspective-correct interpolation: weights divided
                    // by per-vertex w, normalized by sum.  Saves a per-
                    // varying division by carrying the normalized weights.
                    const pw0: f32, const pw1: f32, const pw2: f32 = if (affine)
                        .{ w0, w1, w2 } // 2D: raw bw (sum≈1), no normalize-divide
                    else persp_blk: {
                        const persp_w0: f32 = w0 * inv_w0;
                        const persp_w1: f32 = w1 * inv_w1;
                        const persp_w2: f32 = w2 * inv_w2;
                        const persp_inv_sum: f32 = 1.0 / (persp_w0 + persp_w1 + persp_w2);
                        break :persp_blk .{
                            persp_w0 * persp_inv_sum,
                            persp_w1 * persp_inv_sum,
                            persp_w2 * persp_inv_sum,
                        };
                    };

                    // Interpolate every field of the VS Out (except
                    // `position`, which we already used for rasterization).
                    // The dispatcher builds an interpolated VS Out, then
                    // calls `connect` to map it to the FS Io.
                    var interp_vo: VsModule.Out = undefined;
                    interp_vo.position = .{ 0, 0, 0, 0 }; // unused downstream
                    const vti = @typeInfo(VsModule.Out).@"struct";
                    inline for (vti.field_names, vti.field_types) |field_name, field_type| {
                        if (comptime eql(u8, field_name, "position")) {
                            continue;
                        }
                        const v0: field_type = @field(vo0, field_name);
                        const v1: field_type = @field(vo1, field_name);
                        const v2: field_type = @field(vo2, field_name);
                        @field(interp_vo, field_name) = lerpAny(field_type, v0, v1, v2, pw0, pw1, pw2);
                    }

                    var fs_io: FsModule.Io = base_fs_io;
                    connect(interp_vo, &fs_io);
                    const out: FsModule.Out = FsModule.shaderMain(fs_io);
                    const out_color: Vec = @field(out, out_field_name);

                    if (comptime opts.blend) {
                        // Alpha-over (src_alpha, one_minus_src_alpha),
                        // mirroring triangleKernel: out = src·a + dst·(1-a).
                        var dst: [4]f32 = undefined;
                        color_reader(&dst, fb_bytes, pixel_index);
                        const src_a: f32 = out_color[3];
                        const inv_a: f32 = 1.0 - src_a;
                        const blended: [4]f32 = .{
                            out_color[0] * src_a + dst[0] * inv_a,
                            out_color[1] * src_a + dst[1] * inv_a,
                            out_color[2] * src_a + dst[2] * inv_a,
                            src_a + dst[3] * inv_a,
                        };
                        writer(fb_bytes, &blended, pixel_index);
                    } else {
                        const color_arr: [4]f32 = .{
                            out_color[0],
                            out_color[1],
                            out_color[2],
                            out_color[3],
                        };
                        writer(fb_bytes, &color_arr, pixel_index);
                    }
                }
            }
        }
    }
}

/// Runtime-state → comptime-opts dispatcher.  The fixed-function caller
/// (the immediate-mode `ff_triangle` bridge) holds depth/blend/cull as
/// RUNTIME `raster.Context` flags, but `rasterizeTriangles` takes `opts`
/// at comptime.  This mirrors how the retired `triangleKernel` selected
/// among its monomorphized `RasterCfg` variants via `inline 0...15`:
/// pack the three booleans into a 3-bit index and `inline`-expand the
/// switch so every arm calls `rasterizeTriangles` with a comptime
/// `RasterizeOpts`.  Texture and scissor are NOT comptime opts here —
/// `rasterizeTriangles` samples `_texture0` and reads
/// `ctx.scissorPixelRect()` at runtime — so this is 2³ = 8 variants,
/// not the kernel's 2⁴ = 16.
///
/// `cull` true maps to the default `.ccw` front face (clip-space CCW =
/// front, so clip-space-CW back faces are dropped); false disables
/// culling (`.none`, both faces drawn).  Depth and blend forward
/// straight through to the matching `RasterizeOpts` fields.
pub fn rasterizeWithRuntimeOpts(
    comptime VsModule: type,
    comptime FsModule: type,
    ctx: *raster.Context,
    vertex_outs: []const VsModule.Out,
    indices: []const u32,
    base_fs_io: FsModule.Io,
    comptime connect: fn (VsModule.Out, *FsModule.Io) void,
    depth_test: bool,
    blend: bool,
    cull: bool,
) void {
    const sel: u3 =
        (@as(u3, @intFromBool(depth_test)) << 2) |
        (@as(u3, @intFromBool(blend)) << 1) |
        @as(u3, @intFromBool(cull));
    switch (sel) {
        inline 0...7 => |s| {
            const opts: RasterizeOpts = .{
                .depth_test = (s & 0b100) != 0,
                .blend = (s & 0b010) != 0,
                .front_face = if ((s & 0b001) != 0) .ccw else .none,
            };
            rasterizeTriangles(VsModule, FsModule, ctx, vertex_outs, indices, base_fs_io, connect, opts);
        },
    }
}

/// Pure-function sibling of `rasterizeTriangles`: same edge-function math,
/// same perspective-correct interpolation, same `.less` depth semantics —
/// but no `raster.Context` and no runtime codec fn pointers, so it runs AT
/// COMPTIME.  This is what bakes a geometry demo's "third target" corner
/// (the helmet side-by-side): the compiler itself rasterizes a proxy mesh
/// through the same `shaderMain` pair the GPU and the live CPU half run.
/// Depth is an internal z-buffer (always on — a comptime bake of solid
/// geometry without depth would be draw-order soup).  Returns row-major
/// RGBA8, `clear` as the background.  Runtime-callable too, which is how
/// the differential test pins it to `rasterizeTriangles`.
pub fn rasterizeToImage(
    comptime VsModule: type,
    comptime FsModule: type,
    comptime width: usize,
    comptime height: usize,
    vertex_outs: []const VsModule.Out,
    indices: []const u32,
    base_fs_io: FsModule.Io,
    comptime connect: fn (VsModule.Out, *FsModule.Io) void,
    comptime opts: RasterizeOpts,
    clear: [4]u8,
) [width * height][4]u8 {
    var img: [width * height][4]u8 = @splat(clear);
    var depth: [width * height]f32 = @splat(1.0);
    rasterizeToTarget(VsModule, FsModule, width, height, vertex_outs, indices, base_fs_io, connect, opts, &img, &depth);
    return img;
}

/// The DRAW-CALL core under `rasterizeToImage`: rasterize one object into
/// CALLER-OWNED color + depth buffers WITHOUT clearing them.  Clearing once
/// and then calling this N times with different uniforms/geometry is a
/// software render PASS with per-draw state — the exact shape of a GPU pass
/// (`beginTextureModeRaw` + N `drawIndexed`) — and it runs at comptime, so a
/// baked corner can draw several objects with per-object uniform blocks just
/// like the live halves do.  `rasterizeTriangles` is the same multi-draw
/// idea over a runtime `raster.Context`; this is its pure-function twin.
pub fn rasterizeToTarget(
    comptime VsModule: type,
    comptime FsModule: type,
    comptime width: usize,
    comptime height: usize,
    vertex_outs: []const VsModule.Out,
    indices: []const u32,
    base_fs_io: FsModule.Io,
    comptime connect: fn (VsModule.Out, *FsModule.Io) void,
    comptime opts: RasterizeOpts,
    img: *[width * height][4]u8,
    depth: *[width * height]f32,
) void {
    const fb_w_f: f32 = float(width);
    const fb_h_f: f32 = float(height);

    const out_field_name: []const u8 = comptime blk: {
        const oti = @typeInfo(FsModule.Out).@"struct";
        for (oti.field_names, oti.field_types) |fname, ftype| {
            if (ftype == Vec) {
                break :blk fname;
            }
        }
        @compileError("FS Out must have a Vec field");
    };

    var i: usize = 0;
    while (i + 2 < indices.len) : (i += 3) {
        const src0: VsModule.Out = vertex_outs[indices[i]];
        const src1: VsModule.Out = vertex_outs[indices[i + 1]];
        const src2: VsModule.Out = vertex_outs[indices[i + 2]];

        // Near-plane clip — identical to the runtime path so the comptime
        // bake matches `rasterizeTriangles` (the differential test pins them).
        var clipped_tris: [2][3]VsModule.Out = undefined;
        const n_clipped: usize = clipTriangleNearPlane(VsModule.Out, src0, src1, src2, &clipped_tris);
        for (clipped_tris[0..n_clipped]) |tri| {
            const vo0: VsModule.Out = tri[0];
            const vo1: VsModule.Out = tri[1];
            const vo2: VsModule.Out = tri[2];
            const p0: Vec = vo0.position;
            const p1: Vec = vo1.position;
            const p2: Vec = vo2.position;
            if (p0[3] <= 1e-7 or p1[3] <= 1e-7 or p2[3] <= 1e-7) {
                continue;
            }
            const inv_w0: f32 = 1.0 / p0[3];
            const inv_w1: f32 = 1.0 / p1[3];
            const inv_w2: f32 = 1.0 / p2[3];
            // W=1 affine fast-path: 2D / ortho geometry has w==1 at every vertex
            // (checked on the original w), so perspective-correct interpolation
            // collapses to plain barycentric.  Loop-invariant (per-triangle) so
            // LLVM can unswitch the pixel loop.  The fast path uses the raw
            // barycentric weights directly — they sum to ≈1 (the same ones the
            // depth interp uses raw) — skipping the per-pixel normalize-DIVIDE,
            // worth ≈7% of this path; that shifts ≤1 per channel vs the
            // normalized form (the factor is 1±~6e-8), within GPU-parity bounds.
            const affine: bool = (p0[3] == 1.0 and p1[3] == 1.0 and p2[3] == 1.0);
            const sx0: f32 = (p0[0] * inv_w0 + 1.0) * 0.5 * fb_w_f;
            const sy0: f32 = (1.0 - (p0[1] * inv_w0 + 1.0) * 0.5) * fb_h_f;
            const sx1: f32 = (p1[0] * inv_w1 + 1.0) * 0.5 * fb_w_f;
            const sy1: f32 = (1.0 - (p1[1] * inv_w1 + 1.0) * 0.5) * fb_h_f;
            const sx2: f32 = (p2[0] * inv_w2 + 1.0) * 0.5 * fb_w_f;
            const sy2: f32 = (1.0 - (p2[1] * inv_w2 + 1.0) * 0.5) * fb_h_f;
            const ndc_z0: f32 = p0[2] * inv_w0;
            const ndc_z1: f32 = p1[2] * inv_w1;
            const ndc_z2: f32 = p2[2] * inv_w2;

            const cov: TriCoverage = setupTriCoverage(sx0, sy0, sx1, sy1, sx2, sy2) orelse continue;
            switch (comptime opts.front_face) {
                .ccw => if (!cov.swapped) {
                    continue;
                },
                .cw => if (cov.swapped) {
                    continue;
                },
                .none => {},
            }

            const min_x: i32 = @max(floori(i32, @min(@min(sx0, sx1), sx2)), 0);
            const min_y: i32 = @max(floori(i32, @min(@min(sy0, sy1), sy2)), 0);
            const max_x: i32 = @min(ceili(i32, @max(@max(sx0, sx1), sx2)), @as(i32, @intCast(width)));
            const max_y: i32 = @min(ceili(i32, @max(@max(sy0, sy1), sy2)), @as(i32, @intCast(height)));
            if (max_x <= min_x or max_y <= min_y) {
                continue;
            }

            var py: i32 = min_y;
            while (py < max_y) : (py += 1) {
                var px: i32 = min_x;
                while (px < max_x) : (px += 1) {
                    if (!cov.covers(px, py)) {
                        continue;
                    }
                    const bw: [3]f32 = cov.weights(px, py);
                    const w0: f32 = bw[0];
                    const w1: f32 = bw[1];
                    const w2: f32 = bw[2];
                    const pixel_index: usize = @as(usize, @intCast(py)) * width + @as(usize, @intCast(px));
                    const frag_z: f32 = w0 * ndc_z0 + w1 * ndc_z1 + w2 * ndc_z2;
                    if (frag_z < 0.0 or frag_z > 1.0 or frag_z >= depth[pixel_index]) {
                        continue;
                    }
                    depth[pixel_index] = frag_z;

                    const pw0: f32, const pw1: f32, const pw2: f32 = if (affine)
                        .{ w0, w1, w2 } // 2D: raw bw (sum≈1), no normalize-divide
                    else persp_blk: {
                        const persp_w0: f32 = w0 * inv_w0;
                        const persp_w1: f32 = w1 * inv_w1;
                        const persp_w2: f32 = w2 * inv_w2;
                        const persp_inv_sum: f32 = 1.0 / (persp_w0 + persp_w1 + persp_w2);
                        break :persp_blk .{
                            persp_w0 * persp_inv_sum,
                            persp_w1 * persp_inv_sum,
                            persp_w2 * persp_inv_sum,
                        };
                    };

                    var interp_vo: VsModule.Out = undefined;
                    interp_vo.position = .{ 0, 0, 0, 0 };
                    const vti = @typeInfo(VsModule.Out).@"struct";
                    inline for (vti.field_names, vti.field_types) |field_name, field_type| {
                        if (comptime eql(u8, field_name, "position")) {
                            continue;
                        }
                        @field(interp_vo, field_name) = lerpAny(
                            field_type,
                            @field(vo0, field_name),
                            @field(vo1, field_name),
                            @field(vo2, field_name),
                            pw0,
                            pw1,
                            pw2,
                        );
                    }

                    var fs_io: FsModule.Io = base_fs_io;
                    connect(interp_vo, &fs_io);
                    const out: FsModule.Out = FsModule.shaderMain(fs_io);
                    const c: Vec = @field(out, out_field_name);
                    img[pixel_index] = .{
                        @trunc(std.math.clamp(c[0], 0.0, 1.0) * 255.0),
                        @trunc(std.math.clamp(c[1], 0.0, 1.0) * 255.0),
                        @trunc(std.math.clamp(c[2], 0.0, 1.0) * 255.0),
                        @trunc(std.math.clamp(c[3], 0.0, 1.0) * 255.0),
                    };
                }
            }
        }
    }
}

// ---- Near-plane clipping (Sutherland-Hodgman, single plane) --------
//
// Clips one triangle against the wgpu near plane `clip.z >= 0`, emitting
// 0, 1, or 2 in-front triangles.  This replaces the old "any vertex with
// w <= 0 -> drop the whole triangle": geometry straddling the camera
// plane is now split instead of vanishing, and every vertex that survives
// has clip.z >= 0 -- hence (for a standard projection) clip.w > 0 -- so
// the perspective divide downstream is always well-defined.  The
// clip-space `position` AND every varying are linearly interpolated at
// the introduced vertices, so a clip vertex carries correct interpolants.
//
// Pure + allocation-free, so it runs at comptime too: `rasterizeToImage`
// (the comptime baker) and `rasterizeTriangles` (the runtime path) clip
// identically, which the differential test between them relies on.

// ---------------------------------------------------------------------------
// Fixed-point subpixel coverage (§3 of software_rasterizer_oracle.md).
//
// Watertight triangle coverage via integer edge functions on a subpixel grid
// plus the top-left rule, so shared edges between adjacent triangles are
// covered exactly once (no gaps, no double-hits).  These pure helpers are the
// coverage core that `rasterizeTriangles` / `rasterizeToImage` gate on; the
// barycentric weights for interpolation are derived as `edge / area2` (both
// integer), so one edge evaluation drives coverage and interpolation alike.
// ---------------------------------------------------------------------------

test "setupTriCoverage: inside / outside sanity" {
    const tri: TriCoverage = setupTriCoverage(10, 10, 50, 10, 10, 50).?;
    try expect(tri.covers(15, 15));
    try expect(!tri.covers(40, 40));
    try expect(!tri.covers(2, 2));
}

test "setupTriCoverage: winding-independent coverage" {
    const a: TriCoverage = setupTriCoverage(10, 10, 50, 10, 10, 50).?;
    const b: TriCoverage = setupTriCoverage(10, 10, 10, 50, 50, 10).?;
    var py: i32 = 0;
    while (py < 64) : (py += 1) {
        var px: i32 = 0;
        while (px < 64) : (px += 1) {
            try expectEqual(a.covers(px, py), b.covers(px, py));
        }
    }
}

test "setupTriCoverage: two triangles tiling a rect cover each pixel exactly once" {
    const ta: TriCoverage = setupTriCoverage(0, 0, 8, 0, 0, 8).?;
    const tb: TriCoverage = setupTriCoverage(8, 0, 8, 8, 0, 8).?;
    var py: i32 = 0;
    while (py < 8) : (py += 1) {
        var px: i32 = 0;
        while (px < 8) : (px += 1) {
            const n: u32 = @as(u32, @intFromBool(ta.covers(px, py))) +
                @as(u32, @intFromBool(tb.covers(px, py)));
            try expectEqual(@as(u32, 1), n);
        }
    }
}

test "TriCoverage.weights: barycentric weights map to original vertices (both windings)" {
    const tol: f32 = 0.01;
    // Triangle v0=(0,0) v1=(12,0) v2=(0,12); asymmetric sample so v1 != v2.
    // Pixel (6,1) centre (6.5,1.5): lambda ~ (1/3, 0.5417, 0.125).
    const a: TriCoverage = setupTriCoverage(0, 0, 12, 0, 0, 12).?;
    const wa: [3]f32 = a.weights(6, 1);
    try expectApproxEqAbs(@as(f32, 1.0 / 3.0), wa[0], tol);
    try expectApproxEqAbs(@as(f32, 0.5417), wa[1], tol);
    try expectApproxEqAbs(@as(f32, 0.125), wa[2], tol);
    try expectApproxEqAbs(@as(f32, 1.0), wa[0] + wa[1] + wa[2], 1e-4);
    // Same triangle but v1/v2 swapped in input order: the `swapped` re-map must
    // put v1=(0,12)->0.125 at [1] and v2=(12,0)->0.5417 at [2].
    const b: TriCoverage = setupTriCoverage(0, 0, 0, 12, 12, 0).?;
    const wb: [3]f32 = b.weights(6, 1);
    try expectApproxEqAbs(@as(f32, 1.0 / 3.0), wb[0], tol);
    try expectApproxEqAbs(@as(f32, 0.125), wb[1], tol);
    try expectApproxEqAbs(@as(f32, 0.5417), wb[2], tol);
}

test "clipTriangleNearPlane: vertex counts for in-front / straddle / behind" {
    const V = struct {
        position: Vec,
        uv: Vec2,
    };
    const mk = struct {
        pub fn v(zz: f32) V {
            return .{ .position = .{ 0.0, 0.0, zz, 1.0 }, .uv = .{ 0, 0 } };
        }
    }.v;
    const f: f32 = 0.5; // in front of the near plane (z >= 0)
    const b: f32 = -0.5; // behind it (z < 0)
    var out: [2][3]V = undefined;
    // all in front -> one triangle, unchanged
    try expectEqual(@as(usize, 1), clipTriangleNearPlane(V, mk(f), mk(f), mk(f), &out));
    // two in front, one behind -> a 4-gon -> two triangles
    try expectEqual(@as(usize, 2), clipTriangleNearPlane(V, mk(f), mk(f), mk(b), &out));
    // one in front, two behind -> one triangle
    try expectEqual(@as(usize, 1), clipTriangleNearPlane(V, mk(f), mk(b), mk(b), &out));
    // all behind -> fully clipped
    try expectEqual(@as(usize, 0), clipTriangleNearPlane(V, mk(b), mk(b), mk(b), &out));
}

test "near-plane clip renders the in-front part of a straddling triangle" {
    const Vs = struct {
        pub const Out = struct {
            position: Vec,
            color: Vec,
        };
    };
    const Fs = struct {
        pub const Io = struct {
            color: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.color };
        }
    };
    const connectFn = struct {
        pub fn f(vo: Vs.Out, io: *Fs.Io) void {
            io.color = vo.color;
        }
    }.f;
    const white: Vec = .{ 1, 1, 1, 1 };
    // v2 sits behind the eye (w < 0): the pre-clip path dropped the whole
    // triangle on `w <= 0`, so this used to render nothing at all. The two
    // in-front vertices sit at distinct NDC y, so the clipped polygon has
    // real area (verified: NDC y spans -0.8..0.0).
    const verts = [_]Vs.Out{
        .{ .position = .{ -0.5, -0.7, 0.5, 1.0 }, .color = white },
        .{ .position = .{ 0.5, -0.3, 0.5, 1.0 }, .color = white },
        .{ .position = .{ 0.0, 0.6, -1.0, -1.0 }, .color = white },
    };
    const indices = [_]u32{ 0, 1, 2 };
    const w_px: usize = 32;
    const h_px: usize = 32;
    const img = rasterizeToImage(
        Vs,
        Fs,
        w_px,
        h_px,
        &verts,
        &indices,
        .{ .color = white },
        connectFn,
        .{ .front_face = .none },
        .{ 0, 0, 0, 0 },
    );
    var lit: usize = 0;
    for (img) |px| {
        if (px[0] > 0) {
            lit += 1;
        }
    }
    try expect(lit > 0);
}

test "dispatchFragmentShader fills the framebuffer for a constant-color shader" {
    const gpa: Allocator = std.testing.allocator;

    // A trivial shader inline: no inputs, no UBO; just emits red.
    const ConstantRed = struct {
        pub const Io = struct {
            frag_tex_coord: Vec2,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            _ = io;
            return .{ .out_color = .{ 1.0, 0.0, 0.0, 1.0 } };
        }
    };

    var ctx: raster.Context = try .init(gpa, 16, 16);
    defer ctx.deinit(gpa);

    const base_io: ConstantRed.Io = .{ .frag_tex_coord = .{ 0, 0 } };
    dispatchFragmentShader(&ctx, ConstantRed, base_io, .{ .x = 0, .y = 0, .w = 16, .h = 16 });

    const bytes: []const u8 = ctx.colorBufferBytes();
    // First pixel should be RGBA = (255, 0, 0, 255).
    try expectEqual(@as(u8, 255), bytes[0]);
    try expectEqual(@as(u8, 0), bytes[1]);
    try expectEqual(@as(u8, 0), bytes[2]);
    try expectEqual(@as(u8, 255), bytes[3]);
    // Last pixel in 16x16 buffer at byte offset (15*16 + 15) * 4 = 1020.
    try expectEqual(@as(u8, 255), bytes[1020]);
}

test "dispatchFragmentShader handles UV-based shader" {
    const gpa: Allocator = std.testing.allocator;

    // Returns the UV as RGB.  Pixel at (0, 0) should be (0, 0, ...);
    // pixel at (W-1, H-1) should be near (1, 1, ...).
    const UvShader = struct {
        pub const Io = struct {
            frag_tex_coord: Vec2,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = .{
                io.frag_tex_coord[0],
                io.frag_tex_coord[1],
                0.0,
                1.0,
            } };
        }
    };

    var ctx: raster.Context = try .init(gpa, 8, 8);
    defer ctx.deinit(gpa);

    const base_io: UvShader.Io = .{ .frag_tex_coord = .{ 0, 0 } };
    dispatchFragmentShader(&ctx, UvShader, base_io, .{ .x = 0, .y = 0, .w = 8, .h = 8 });

    const bytes: []const u8 = ctx.colorBufferBytes();
    // v now uses screen-top = 1 (matches the GPU fullscreen triangle's
    // frag_tex_coord). Row 0 is the TOP: u=0 -> R=0, v=1 -> G ~= 255.
    try expectEqual(@as(u8, 0), bytes[0]); // R = u = 0
    try expect(bytes[1] >= 250); // G = v = 1 at the top row

    // Column 7, row 7 (bottom-right): u = 7/8 ~= 0.875 -> R ~= 223;
    // v = 1 - 7/8 = 0.125 -> G ~= 31.
    const last_off: usize = (7 * 8 + 7) * 4;
    try expect(bytes[last_off] >= 220); // R
    try expect(bytes[last_off] <= 225);
    try expect(bytes[last_off + 1] >= 28); // G = v ~= 0.125
    try expect(bytes[last_off + 1] <= 35);
}

test "rasterizeTriangles draws a clip-space full-screen triangle" {
    const gpa: Allocator = std.testing.allocator;

    // A trivial VS that emits three vertices forming a triangle
    // covering most of the framebuffer.  No attributes input — the
    // vertex_id is the only signal.
    const TrivialVs = struct {
        pub const Io = struct {};
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            _ = io;
            return undefined;
        }
    };
    const SolidGreenFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };

    var ctx: raster.Context = try .init(gpa, 32, 32);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    ctx.clear(.{ .color = true });

    // Triangle covers the lower-left portion of the canvas (after the
    // NDC→screen Y-flip).  The clip-space winding must be CCW so the
    // default `.ccw` front-face rule keeps it (a CCW NDC triangle has
    // positive NDC signed area; after the Y-flip it becomes negative
    // screen area, which `.ccw` accepts).  NDC order (-1,-1) → (+1,-1)
    // → (-1,+1) is CCW (signed area +4); it maps to screen corners
    // (0,32) → (32,32) → (0,0) — the triangle below the diagonal y=x.
    var vertex_outs: [3]TrivialVs.Out = .{
        .{ .position = .{ -1.0, -1.0, 0, 1.0 }, .vcolor = .{ 0, 1, 0, 1 } },
        .{ .position = .{ 1.0, -1.0, 0, 1.0 }, .vcolor = .{ 0, 1, 0, 1 } },
        .{ .position = .{ -1.0, 1.0, 0, 1.0 }, .vcolor = .{ 0, 1, 0, 1 } },
    };
    const indices = [_]u32{ 0, 1, 2 };
    const Connector = struct {
        pub fn connect(vo: TrivialVs.Out, fs_io: *SolidGreenFs.Io) void {
            fs_io.vcolor = vo.vcolor;
        }
    };
    const base_fs_io: SolidGreenFs.Io = .{ .vcolor = .{ 0, 0, 0, 0 } };
    rasterizeTriangles(
        TrivialVs,
        SolidGreenFs,
        &ctx,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{}, // default: clip-space CCW (matches wgpu front face)
    );

    const bytes: []const u8 = ctx.colorBufferBytes();
    // Triangle screen corners are (0,32), (0,0), (32,32): bottom-
    // left triangle below the diagonal y=x.  Inside: y >= x.
    // Pixel (4, 8): y=8 > x=4, deep inside — should be green.
    const inside_off: usize = (8 * 32 + 4) * 4;
    try expectEqual(@as(u8, 0), bytes[inside_off]); // R
    try expectEqual(@as(u8, 255), bytes[inside_off + 1]); // G
    try expectEqual(@as(u8, 0), bytes[inside_off + 2]); // B
    // Pixel (28, 4): y=4 < x=28, deep outside — should be black.
    const outside_off: usize = (4 * 32 + 28) * 4;
    try expectEqual(@as(u8, 0), bytes[outside_off + 1]); // not green
}

test "rasterizeTriangles depth test: nearer fragment wins regardless of draw order" {
    const gpa: Allocator = std.testing.allocator;

    const FlatVs = struct {
        pub const Io = struct {};
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            _ = io;
            return undefined;
        }
    };
    const FlatFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };

    var ctx: raster.Context = try .init(gpa, 16, 16);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    ctx.clearDepth(1.0);
    ctx.clear(.{ .color = true, .depth = true });

    // Two full-screen CCW triangles at constant depths: GREEN near
    // (z = 0.25) drawn FIRST, RED far (z = 0.75) drawn SECOND.  With
    // the depth test on, red must lose everywhere it overlaps green.
    const green: Vec = .{ 0, 1, 0, 1 };
    const red: Vec = .{ 1, 0, 0, 1 };
    var vertex_outs: [6]FlatVs.Out = .{
        .{ .position = .{ -1.0, -1.0, 0.25, 1.0 }, .vcolor = green },
        .{ .position = .{ 3.0, -1.0, 0.25, 1.0 }, .vcolor = green },
        .{ .position = .{ -1.0, 3.0, 0.25, 1.0 }, .vcolor = green },
        .{ .position = .{ -1.0, -1.0, 0.75, 1.0 }, .vcolor = red },
        .{ .position = .{ 3.0, -1.0, 0.75, 1.0 }, .vcolor = red },
        .{ .position = .{ -1.0, 3.0, 0.75, 1.0 }, .vcolor = red },
    };
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const Connector = struct {
        pub fn connect(vo: FlatVs.Out, fs_io: *FlatFs.Io) void {
            fs_io.vcolor = vo.vcolor;
        }
    };
    const base_fs_io: FlatFs.Io = .{ .vcolor = .{ 0, 0, 0, 0 } };
    rasterizeTriangles(
        FlatVs,
        FlatFs,
        &ctx,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{ .depth_test = true },
    );

    // Center pixel must stay GREEN (the near surface) even though red
    // was rasterized after it.
    const bytes: []const u8 = ctx.colorBufferBytes();
    const center_off: usize = (8 * 16 + 8) * 4;
    try expectEqual(@as(u8, 0), bytes[center_off]); // R
    try expectEqual(@as(u8, 255), bytes[center_off + 1]); // G

    // And the depth attachment holds the NEAR z at that pixel.
    const depth_bytes: []const u8 = ctx.depthBufferBytesMut();
    const depth_reader: raster_pixel.ReadDepthFn = raster_pixel.read_depth_table.get(ctx.depthBufferFormat()).?;
    const center_depth: f32 = depth_reader(depth_bytes, 8 * 16 + 8);
    try expectApproxEqAbs(@as(f32, 0.25), center_depth, 0.001);
}

test "rasterizeTriangles: alpha-over blend composites src over dst" {
    const gpa: Allocator = std.testing.allocator;

    const BlendVs = struct {
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
    };
    const BlendFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };

    var ctx: raster.Context = try .init(gpa, 16, 16);
    defer ctx.deinit(gpa);
    // Opaque RED background (raylib-style u8 Color).
    ctx.clearColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    ctx.clear(.{ .color = true });

    // One full-screen CCW triangle, GREEN at 50% alpha, blended OVER red.
    const green_half: Vec = .{ 0, 1, 0, 0.5 };
    var vertex_outs: [3]BlendVs.Out = .{
        .{ .position = .{ -1.0, -1.0, 0.0, 1.0 }, .vcolor = green_half },
        .{ .position = .{ 3.0, -1.0, 0.0, 1.0 }, .vcolor = green_half },
        .{ .position = .{ -1.0, 3.0, 0.0, 1.0 }, .vcolor = green_half },
    };
    const indices = [_]u32{ 0, 1, 2 };
    const Connector = struct {
        pub fn connect(vo: BlendVs.Out, fs_io: *BlendFs.Io) void {
            fs_io.vcolor = vo.vcolor;
        }
    };
    const base_fs_io: BlendFs.Io = .{ .vcolor = .{ 0, 0, 0, 0 } };
    rasterizeTriangles(
        BlendVs,
        BlendFs,
        &ctx,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{ .blend = true },
    );

    // Center = green·0.5 over red·0.5 ≈ (0.5, 0.5, 0): NOT pure green
    // (an overwrite) and NOT pure red (no blend) — proves the composite.
    const bytes: []const u8 = ctx.colorBufferBytes();
    const center_off: usize = (8 * 16 + 8) * 4;
    try expect(bytes[center_off] >= 120 and bytes[center_off] <= 135);
    try expect(bytes[center_off + 1] >= 120 and bytes[center_off + 1] <= 135);
    try expect(bytes[center_off + 2] <= 5);
}

test "rasterizeTriangles: scissor clips fragments to the scissor rect" {
    const gpa: Allocator = std.testing.allocator;

    const ScVs = struct {
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
    };
    const ScFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };

    var ctx: raster.Context = try .init(gpa, 16, 16);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    ctx.clear(.{ .color = true });
    // Scissor to the RIGHT half: [8, 16) × [0, 16).
    ctx.enable(.scissor_test);
    ctx.scissor(8, 0, 8, 16);

    // A full-screen GREEN triangle — only the right half may survive.
    const green: Vec = .{ 0, 1, 0, 1 };
    var vertex_outs: [3]ScVs.Out = .{
        .{ .position = .{ -1.0, -1.0, 0.0, 1.0 }, .vcolor = green },
        .{ .position = .{ 3.0, -1.0, 0.0, 1.0 }, .vcolor = green },
        .{ .position = .{ -1.0, 3.0, 0.0, 1.0 }, .vcolor = green },
    };
    const indices = [_]u32{ 0, 1, 2 };
    const Connector = struct {
        pub fn connect(vo: ScVs.Out, fs_io: *ScFs.Io) void {
            fs_io.vcolor = vo.vcolor;
        }
    };
    const base_fs_io: ScFs.Io = .{ .vcolor = .{ 0, 0, 0, 0 } };
    rasterizeTriangles(
        ScVs,
        ScFs,
        &ctx,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{},
    );

    // Left half (x=4) stays BLACK (clipped out); right half (x=12) GREEN.
    const bytes: []const u8 = ctx.colorBufferBytes();
    const left_off: usize = (8 * 16 + 4) * 4;
    const right_off: usize = (8 * 16 + 12) * 4;
    try expectEqual(@as(u8, 0), bytes[left_off + 1]);
    try expectEqual(@as(u8, 255), bytes[right_off + 1]);
}

test "raster.Context.ff_triangle routes immediate-mode triangles through rasterizeTriangles" {
    const HookVs = struct {
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
    };
    const HookFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };
    const Hook = struct {
        fn tri(
            ctx_opaque: *anyopaque,
            v0: *const raster.Vertex,
            v1: *const raster.Vertex,
            v2: *const raster.Vertex,
        ) void {
            const ctx: *raster.Context = @ptrCast(@alignCast(ctx_opaque));
            const vouts: [3]HookVs.Out = .{
                .{ .position = v0.position, .vcolor = v0.color },
                .{ .position = v1.position, .vcolor = v1.color },
                .{ .position = v2.position, .vcolor = v2.color },
            };
            const idx: [3]u32 = .{ 0, 1, 2 };
            const Connector = struct {
                pub fn connect(vo: HookVs.Out, io: *HookFs.Io) void {
                    io.vcolor = vo.vcolor;
                }
            };
            rasterizeTriangles(
                HookVs,
                HookFs,
                ctx,
                &vouts,
                &idx,
                .{ .vcolor = .{ 0, 0, 0, 0 } },
                Connector.connect,
                .{},
            );
        }
    };

    const gpa: Allocator = std.testing.allocator;
    var ctx: raster.Context = try .init(gpa, 16, 16);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    ctx.clear(.{ .color = true });
    ctx.ff_triangle = Hook.tri;

    // Immediate-mode full-screen GREEN triangle — must render via the hook,
    // not the built-in triangleKernel.
    ctx.begin(.triangles);
    ctx.color4ub(0, 255, 0, 255);
    ctx.vertex2f(-1.0, -1.0);
    ctx.vertex2f(3.0, -1.0);
    ctx.vertex2f(-1.0, 3.0);
    ctx.end();

    const bytes: []const u8 = ctx.colorBufferBytes();
    const center_off: usize = (8 * 16 + 8) * 4;
    try expectEqual(@as(u8, 255), bytes[center_off + 1]);
}

test "rasterizeWithRuntimeOpts maps runtime cull/blend flags to comptime opts" {
    const FlatVs = struct {
        pub const Out = struct {
            position: Vec,
            tint: Vec,
        };
    };
    const FlatFs = struct {
        pub const Io = struct {
            tint: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.tint };
        }
    };
    const Connector = struct {
        pub fn connect(vo: FlatVs.Out, io: *FlatFs.Io) void {
            io.tint = vo.tint;
        }
    };
    const connect: fn (FlatVs.Out, *FlatFs.Io) void = Connector.connect;
    const base_io: FlatFs.Io = .{ .tint = .{ 0, 0, 0, 0 } };
    const idx: [3]u32 = .{ 0, 1, 2 };
    const gpa: Allocator = std.testing.allocator;
    const center: usize = (8 * 16 + 8) * 4;

    // A clip-space CW triangle (reverse of the usual CCW full-screen
    // tri).  With cull on (→ .ccw front) it is a BACK face → dropped;
    // with cull off (→ .none) it must draw.
    const green: Vec = .{ 0, 1, 0, 1 };
    const cw_tri: [3]FlatVs.Out = .{
        .{ .position = .{ -1, -1, 0, 1 }, .tint = green },
        .{ .position = .{ -1, 3, 0, 1 }, .tint = green },
        .{ .position = .{ 3, -1, 0, 1 }, .tint = green },
    };

    // cull = true → back face dropped → center stays background.
    {
        var ctx: raster.Context = try .init(gpa, 16, 16);
        defer ctx.deinit(gpa);
        ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        ctx.clear(.{ .color = true });
        rasterizeWithRuntimeOpts(FlatVs, FlatFs, &ctx, &cw_tri, &idx, base_io, connect, false, false, true);
        try expectEqual(@as(u8, 0), ctx.colorBufferBytes()[center + 1]);
    }
    // cull = false → both faces drawn → center is green.
    {
        var ctx: raster.Context = try .init(gpa, 16, 16);
        defer ctx.deinit(gpa);
        ctx.clearColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        ctx.clear(.{ .color = true });
        rasterizeWithRuntimeOpts(FlatVs, FlatFs, &ctx, &cw_tri, &idx, base_io, connect, false, false, false);
        try expectEqual(@as(u8, 255), ctx.colorBufferBytes()[center + 1]);
    }
    // blend = true → 50%-alpha green over a red background composites
    // (R falls, G rises toward ~127 each).  CCW (front) winding.
    {
        var ctx: raster.Context = try .init(gpa, 16, 16);
        defer ctx.deinit(gpa);
        ctx.clearColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
        ctx.clear(.{ .color = true });
        const half_green: Vec = .{ 0, 1, 0, 0.5 };
        const ccw_tri: [3]FlatVs.Out = .{
            .{ .position = .{ -1, -1, 0, 1 }, .tint = half_green },
            .{ .position = .{ 3, -1, 0, 1 }, .tint = half_green },
            .{ .position = .{ -1, 3, 0, 1 }, .tint = half_green },
        };
        rasterizeWithRuntimeOpts(FlatVs, FlatFs, &ctx, &ccw_tri, &idx, base_io, connect, false, true, false);
        const px: []const u8 = ctx.colorBufferBytes();
        try expect(px[center + 0] > 100 and px[center + 0] < 160);
        try expect(px[center + 1] > 100 and px[center + 1] < 160);
    }
}

/// FNV-1a over raw framebuffer bytes — a stable absolute pin for golden tests
/// (Phase 2.5 Turn-2).  No `@setFloatMode` anywhere in the rasteriser, so float
/// results are strict-IEEE-identical across optimize modes; this hash is
/// therefore mode-independent.  Any pixel change flips it — exactly what guards
/// the upcoming rasteriser gap-closing from silently altering output.
fn goldenChecksum(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x00000100000001b3;
    }
    return h;
}

test "rasterizeToImage matches rasterizeTriangles pixel-for-pixel" {
    const gpa: Allocator = std.testing.allocator;

    // Two overlapping triangles with distinct depths and interpolated
    // colors, drawn FAR-LAST so only a correct depth test produces the
    // right image.  The pure rasterizer must reproduce the Context one
    // byte-for-byte: same edge functions, same perspective weights, same
    // truncating float→u8 quantization as the rgba8 codec.
    const TrivialVs = struct {
        pub const Io = struct {};
        pub const Out = struct {
            position: Vec,
            vcolor: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            _ = io;
            return undefined;
        }
    };
    const GradientFs = struct {
        pub const Io = struct {
            vcolor: Vec,
        };
        pub const Out = struct {
            out_color: Vec,
        };
        pub fn shaderMain(io: Io) Out {
            return .{ .out_color = io.vcolor };
        }
    };
    const Connector = struct {
        pub fn connect(vo: TrivialVs.Out, fs_io: *GradientFs.Io) void {
            fs_io.vcolor = vo.vcolor;
        }
    };

    const w_px: usize = 16;
    const h_px: usize = 16;
    // NEAR triangle (z=0.25, CCW in NDC like the full-screen test) drawn
    // FIRST; FAR one (z=0.75, shifted right) drawn SECOND.  w=2 on the far
    // triangle exercises the perspective-correct weight path.
    var vertex_outs: [6]TrivialVs.Out = .{
        .{ .position = .{ -1.0, -1.0, 0.25, 1.0 }, .vcolor = .{ 1, 0, 0, 1 } },
        .{ .position = .{ 0.6, -1.0, 0.25, 1.0 }, .vcolor = .{ 0, 1, 0, 1 } },
        .{ .position = .{ -1.0, 0.6, 0.25, 1.0 }, .vcolor = .{ 0, 0, 1, 1 } },
        .{ .position = .{ -1.2, -2.0, 1.5, 2.0 }, .vcolor = .{ 1, 1, 0, 1 } },
        .{ .position = .{ 2.0, -2.0, 1.5, 2.0 }, .vcolor = .{ 0, 1, 1, 1 } },
        .{ .position = .{ -1.2, 2.0, 1.5, 2.0 }, .vcolor = .{ 1, 0, 1, 1 } },
    };
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const base_fs_io: GradientFs.Io = .{ .vcolor = .{ 0, 0, 0, 0 } };

    var ctx: raster.Context = try .init(gpa, w_px, h_px);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 7, .g = 9, .b = 11, .a = 255 });
    ctx.clearDepth(1.0);
    ctx.clear(.{ .color = true, .depth = true });
    rasterizeTriangles(
        TrivialVs,
        GradientFs,
        &ctx,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{ .depth_test = true },
    );

    const img: [w_px * h_px][4]u8 = rasterizeToImage(
        TrivialVs,
        GradientFs,
        w_px,
        h_px,
        &vertex_outs,
        &indices,
        base_fs_io,
        Connector.connect,
        .{ .depth_test = true },
        .{ 7, 9, 11, 255 },
    );

    const ctx_bytes: []const u8 = ctx.colorBufferBytes();
    try expectEqualSlices(u8, ctx_bytes, @as([*]const u8, @ptrCast(&img))[0 .. w_px * h_px * 4]);

    // Absolute pin (Phase 2.5 Turn-2): the differential check above is RELATIVE
    // (the two cores match each other); so is the sw_engine_shader proof.  This
    // pins the ACTUAL pixels, catching a regression that changes both cores
    // together.  Updated ONCE when the W=1 affine fast-path took raw barycentric
    // weights (skipping the perspective normalize-divide for 2D — ≤1 ULP, see
    // rasterizeTriangles); output-preserving work (SIMD, refactors) must hold it
    // from here, so a change then means a bug.
    const golden: u64 = 7380277600522244912; // FNV-1a of the 16×16 render
    try expectEqual(golden, goldenChecksum(ctx_bytes));
}
