//! examples/sw_engine_shader.zig - render through zimr's ENGINE
//! shader pair (default_shapes_vs + default_shapes_fs) on the CPU,
//! producing a colored PNG.
//!
//! This is the headline proof that one Zig source IS the shader on
//! both backends.  The same files in `src/shaders/default_shapes_*.zig`
//! that compile to SPIR-V -> WGSL and drive `Renderer2D`'s wgpu
//! pipeline ALSO compile natively on x86_64 and run pixel-by-pixel
//! through `raster_shader.rasterizeTriangles`.  No transpiler, no
//! two-files-kept-in-sync, no drift.
//!
//! What this draws: three colored triangles using the engine's
//! standard vertex shape (position in screen pixels, tex_coord in
//! [0,1], color as RGBA).  The view-projection UBO is an orthographic
//! projection so positions are in screen-pixel units.  Textures use
//! the same 1x1 white-pixel convention as the wgpu Renderer2D -
//! untextured draws bind a 1x1 white TextureRef so `frag_color`
//! flows straight through unmodified.
//!
//! Run:
//!
//!   zig build sw-engine-shader
//!
//! Output: sw_engine_shader.png in the working directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
// GL-retirement P2: pulled via sw_runtime (one module owns renderer_2d.zig
// & friends; a separate default_shapes_bundle module now collides).
const sw_runtime = @import("sw_runtime");

const default_shapes = sw_runtime.default_shapes;
const shader = default_shapes.vs;
const shader_fs = default_shapes.fs;

const zm = @import("zm");
const float64 = zm.float64;
const float = zm.float;
const Mat = zm.Mat;
const raster = sw_runtime.raster;
const raster_shader = sw_runtime.raster_shader;
const codecs = sw_runtime.codecs;
const autoConnect = sw_runtime.autoConnect;

const width: u32 = 1280;
const height: u32 = 720;

/// Vertex in CPU-friendly form.  Same field shape as
/// `default_shapes_vs.Io` (which expects `vertex_position`,
/// `vertex_tex_coord`, `vertex_color` plus the UBO).
const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// The engine's ortho top-left projection (screen pixels -> clip space) -
/// the SAME function the wgpu side feeds into the engine UBO each frame.
/// (A stale local copy lived here until GL-retirement P2; it had rotted
/// to zm.Mat during math-unification while its caller kept [16]f32.)
const orthoTopLeft = sw_runtime.renderer_2d.orthoTopLeft;

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Fixed-function `ff_triangle` hook for the immediate-mode proof in
/// `main`: route ONE immediate-mode triangle through the SAME
/// `default_shapes` pair + `rasterizeTriangles` the direct path uses.
/// The vertex positions are ALREADY clip-space (raster transforms them at
/// submission), so the VS is bypassed and `Out` is built directly -
/// preserving the full vec4 position (matters for perspective 3D, not
/// only W=1 2D).  Untextured: the 1x1 white-pixel convention, so
/// `frag_color` flows straight through.
fn ffBridge(
    ctx_opaque: *anyopaque,
    v0: *const raster.Vertex,
    v1: *const raster.Vertex,
    v2: *const raster.Vertex,
) void {
    const ctx: *raster.Context = @ptrCast(@alignCast(ctx_opaque));
    const vs_outs: [3]shader.Out = .{
        .{ .position = v0.position, .frag_tex_coord = v0.texcoord, .frag_color = v0.color },
        .{ .position = v1.position, .frag_tex_coord = v1.texcoord, .frag_color = v1.color },
        .{ .position = v2.position, .frag_tex_coord = v2.texcoord, .frag_color = v2.color },
    };
    const idx: [3]u32 = .{ 0, 1, 2 };
    const white_px = [_]u8{ 255, 255, 255, 255 };
    const base_io: shader_fs.Io = .{
        .frag_tex_coord = .{ 0, 0 },
        .frag_color = .{ 1, 1, 1, 1 },
        ._texture0 = .{ .pixels = &white_px, .width = 1, .height = 1 },
    };
    const connect: fn (shader.Out, *shader_fs.Io) void = autoConnect(shader.Out, shader_fs.Io);
    raster_shader.rasterizeTriangles(shader, shader_fs, ctx, &vs_outs, &idx, base_io, connect, .{});
}

const bench_w: u32 = 480;

const bench_h: u32 = 270;

const bench_tau: f32 = 6.28318530717958647692;

fn benchFan(
    ctx: *raster.Context,
    cx: f32,
    cy: f32,
    r: f32,
    cr: u8,
    cg: u8,
    cb: u8,
) void {
    const segs: u32 = 24;
    ctx.color4ub(cr, cg, cb, 255);
    ctx.begin(.triangles);
    var i: u32 = 0;
    while (i < segs) : (i += 1) {
        const a0: f32 = float(i) * (bench_tau / float(segs));
        const a1: f32 = float(i + 1) * (bench_tau / float(segs));
        ctx.vertex2f(cx, cy);
        ctx.vertex2f(cx + r * @cos(a0), cy + r * @sin(a0));
        ctx.vertex2f(cx + r * @cos(a1), cy + r * @sin(a1));
    }
    ctx.end();
}

fn benchScene(ctx: *raster.Context, t: f32) void {
    ctx.clearColor(.{ .r = 12, .g = 14, .b = 22, .a = 255 });
    ctx.clear(.{ .color = true });
    ctx.matrixMode(.projection);
    ctx.loadIdentity();
    ctx.ortho(0, @floatFromInt(bench_w), @floatFromInt(bench_h), 0, -1, 1);
    ctx.matrixMode(.modelview);
    ctx.loadIdentity();
    ctx.enable(.blend);
    const cx: f32 = float(bench_w) * 0.5;
    const cy: f32 = float(bench_h) * 0.5;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const fi: f32 = float(i);
        const ang: f32 = t * 0.5 + fi * (bench_tau / 10.0);
        const orbit_r: f32 = 90.0 + 20.0 * @sin(t + fi);
        const px: f32 = cx + orbit_r * @cos(ang);
        const py: f32 = cy + orbit_r * @sin(ang);
        const rad: f32 = 12.0 + 7.0 * @sin(t * 2.0 + fi * 1.3);
        const cr: u8 = @intCast((i * 47) % 256);
        const cg: u8 = @intCast((i * 91) % 256);
        const cb: u8 = @intCast((i * 137) % 256);
        benchFan(ctx, px, py, rad, cr, cg, cb);
    }
    const poly_r: f32 = 60.0 + 12.0 * @sin(t * 1.3);
    ctx.color4ub(90, 130, 240, 230);
    ctx.begin(.triangles);
    var k: u32 = 0;
    while (k < 6) : (k += 1) {
        const a0: f32 = t * 0.8 + float(k) * (bench_tau / 6.0);
        const a1: f32 = t * 0.8 + float(k + 1) * (bench_tau / 6.0);
        ctx.vertex2f(cx, cy);
        ctx.vertex2f(cx + poly_r * @cos(a0), cy + poly_r * @sin(a0));
        ctx.vertex2f(cx + poly_r * @cos(a1), cy + poly_r * @sin(a1));
    }
    ctx.end();
    ctx.disable(.blend);
}

fn ffBridgeBench(
    ctx_opaque: *anyopaque,
    v0: *const raster.Vertex,
    v1: *const raster.Vertex,
    v2: *const raster.Vertex,
) void {
    const ctx: *raster.Context = @ptrCast(@alignCast(ctx_opaque));
    const vs_outs: [3]shader.Out = .{
        .{ .position = v0.position, .frag_tex_coord = v0.texcoord, .frag_color = v0.color },
        .{ .position = v1.position, .frag_tex_coord = v1.texcoord, .frag_color = v1.color },
        .{ .position = v2.position, .frag_tex_coord = v2.texcoord, .frag_color = v2.color },
    };
    const idx: [3]u32 = .{ 0, 1, 2 };
    const white_px: [4]u8 = .{ 255, 255, 255, 255 };
    const base_io: shader_fs.Io = .{
        .frag_tex_coord = .{ 0, 0 },
        .frag_color = .{ 1, 1, 1, 1 },
        ._texture0 = .{ .pixels = &white_px, .width = 1, .height = 1 },
    };
    const connect: fn (shader.Out, *shader_fs.Io) void = autoConnect(shader.Out, shader_fs.Io);
    if (ctx.blendEnabled()) {
        raster_shader.rasterizeTriangles(shader, shader_fs, ctx, &vs_outs, &idx, base_io, connect, .{
            .front_face = .none,
            .blend = true,
        });
    } else {
        raster_shader.rasterizeTriangles(shader, shader_fs, ctx, &vs_outs, &idx, base_io, connect, .{
            .front_face = .none,
            .blend = false,
        });
    }
}

fn runBenchmark(gpa: Allocator) !void {
    const n_frames: u32 = 1000;
    const tris_per_frame: u32 = 10 * 24 + 6;
    var ctx: raster.Context = try .init(gpa, bench_w, bench_h);
    defer ctx.deinit(gpa);

    // Warm-up both paths (fill caches; let the allocator settle).
    ctx.ff_triangle = null;
    var wi: u32 = 0;
    while (wi < 50) : (wi += 1) {
        benchScene(&ctx, @floatFromInt(wi));
    }
    ctx.ff_triangle = ffBridgeBench;
    wi = 0;
    while (wi < 50) : (wi += 1) {
        benchScene(&ctx, @floatFromInt(wi));
    }

    // Path A - fixed-function triangleKernel.
    ctx.ff_triangle = null;
    const a0: i128 = monotonicNs();
    var fa: u32 = 0;
    while (fa < n_frames) : (fa += 1) {
        benchScene(&ctx, @floatFromInt(fa));
    }
    const ns_a: i128 = monotonicNs() - a0;

    // Path B - programmable rasterizeTriangles + real default_shapes_fs.
    ctx.ff_triangle = ffBridgeBench;
    const b0: i128 = monotonicNs();
    var fb: u32 = 0;
    while (fb < n_frames) : (fb += 1) {
        benchScene(&ctx, @floatFromInt(fb));
    }
    const ns_b: i128 = monotonicNs() - b0;

    const total_tris: f64 = float64(@as(u64, n_frames) * tris_per_frame);
    const a_ms: f64 = float64(ns_a) / 1_000_000.0;
    const b_ms: f64 = float64(ns_b) / 1_000_000.0;
    const a_ns_tri: f64 = float64(ns_a) / total_tris;
    const b_ns_tri: f64 = float64(ns_b) / total_tris;
    std.debug.print(
        \\
        \\=== Phase 2.5 Turn-1 rasteriser benchmark ===
        \\  scene: sidebyside ({d}x{d}, {d} frames, {d} tris/frame, blend on)
        \\  A  triangleKernel (fixed-function)  : {d:.1} ms | {d:.2} ns/tri
        \\  B  rasterizeTriangles+default_shapes: {d:.1} ms | {d:.2} ns/tri
        \\  B/A = {d:.2}x  (B also pays per-triangle fn-ptr + rasterizeTriangles
        \\                 setup; the target's direct call removes that overhead)
        \\
    , .{ bench_w, bench_h, n_frames, tris_per_frame, a_ms, a_ns_tri, b_ms, b_ns_tri, b_ns_tri / a_ns_tri });
}

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa: Allocator = gpa_impl.allocator();

    // 1. Set up the raster context - the SW framebuffer.
    var ctx: raster.Context = try .init(gpa, width, height);
    defer ctx.deinit(gpa);
    ctx.clearColor(.{ .r = 24, .g = 24, .b = 32, .a = 255 });
    ctx.clear(.{ .color = true });

    // 2. Build the UBO - ortho projection so positions are in pixels.
    //    Same matrix the wgpu side feeds into the engine UBO each
    //    frame.  The VS multiplies vertex_position (vec2 in pixels)
    //    by this view_projection to produce clip-space vec4.
    // renderer_2d's matrix is the GPU-UBO byte layout ([16]f32); the typed
    // shader IO wants zm.Mat ([4]@Vector(4,f32)) - same bytes, row-major.
    const view_proj: Mat = @bitCast(orthoTopLeft(@floatFromInt(width), @floatFromInt(height)));
    const ubo: shader.Io = .{
        // vertex_* fields get overwritten per-vertex below.
        .vertex_position = .{ 0, 0 },
        .vertex_tex_coord = .{ 0, 0 },
        .vertex_color = .{ 1, 1, 1, 1 },
        .u = .{ .view_projection = view_proj },
    };

    // 3. Define three triangles - positions in SCREEN PIXELS.  The VS
    //    maps them through view_projection to clip space.  Winding:
    //    CCW in CLIP space (matching wgpu's default front-face rule).
    //    `rasterizeTriangles` now defaults to `.front_face = .ccw`
    //    (clip-space CCW), so the vertex order here matches what the
    //    wgpu side would render.
    const cx: f32 = float(width / 2);
    const cy: f32 = float(height / 2);
    const vertices = [_]Vertex{
        // Triangle 1: big RGB-gradient central, CCW in clip space.
        // After Y-flip to screen, this reads top -> bot-left -> bot-right.
        .{ .pos = .{ cx, cy - 220 }, .uv = .{ 0.5, 1.0 }, .color = .{ 1.0, 0.2, 0.2, 1.0 } },
        .{ .pos = .{ cx - 200, cy + 120 }, .uv = .{ 0.0, 0.0 }, .color = .{ 0.2, 1.0, 0.2, 1.0 } },
        .{ .pos = .{ cx + 200, cy + 120 }, .uv = .{ 1.0, 0.0 }, .color = .{ 0.2, 0.2, 1.0, 1.0 } },
        // Triangle 2: yellow->magenta->cyan, top-left flag
        .{ .pos = .{ 80, 80 }, .uv = .{ 0, 0 }, .color = .{ 1.0, 0.95, 0.2, 1.0 } },
        .{ .pos = .{ 80, 280 }, .uv = .{ 0, 1 }, .color = .{ 0.2, 0.9, 1.0, 1.0 } },
        .{ .pos = .{ 280, 180 }, .uv = .{ 1, 0.5 }, .color = .{ 0.95, 0.4, 0.95, 1.0 } },
        // Triangle 3: warm-palette wedge, bottom-right
        .{ .pos = .{ @floatFromInt(width - 280), 540 }, .uv = .{ 0, 0 }, .color = .{ 1.0, 0.6, 0.3, 1.0 } },
        .{ .pos = .{ @floatFromInt(width - 80), 660 }, .uv = .{ 1, 1 }, .color = .{ 0.9, 0.2, 0.5, 1.0 } },
        .{ .pos = .{ @floatFromInt(width - 80), 540 }, .uv = .{ 1, 0 }, .color = .{ 0.95, 0.85, 0.5, 1.0 } },
    };

    // 4. Run the VS on each vertex.  Same `shaderMain(io) Out` call
    //    pattern the wgpu wrapper would do on SPIR-V - but here we
    //    invoke it directly from native code.
    const t0: i128 = monotonicNs();
    var vs_outs: [vertices.len]shader.Out = undefined;
    for (vertices, 0..) |v, i| {
        const io: shader.Io = .{
            .vertex_position = .{ v.pos[0], v.pos[1] },
            .vertex_tex_coord = .{ v.uv[0], v.uv[1] },
            .vertex_color = .{ v.color[0], v.color[1], v.color[2], v.color[3] },
            .u = ubo.u,
        };
        vs_outs[i] = shader.shaderMain(io);
    }

    // 5. Build a 1x1 white texture for the FS to sample.  Matches the
    //    wgpu `createWhite1x1` convention so untextured draws produce
    //    the per-vertex color unmodified.
    const white_px = [_]u8{ 255, 255, 255, 255 };
    const texture0_ref: shader_fs.TextureRef = .{
        .pixels = &white_px,
        .width = 1,
        .height = 1,
    };

    // 6. Set up the FS's base Io.  The varyings (frag_tex_coord,
    //    frag_color) will be written per-pixel by the rasterizer;
    //    the texture binding lives on the Io struct's `_texture0`
    //    field (CPU-only field - on SPIR-V the field type is `void`).
    const base_fs_io: shader_fs.Io = .{
        .frag_tex_coord = .{ 0, 0 },
        .frag_color = .{ 1, 1, 1, 1 },
        ._texture0 = texture0_ref,
    };

    // 7. Rasterize.  `connect` is auto-generated at comptime by
    //    matching field names between VS Out and FS Io.  The
    //    rasterizer inlines `shader_fs.shaderMain` into its inner
    //    pixel loop for the same code quality as a hand-written
    //    SW rasterizer.
    const connect: fn (shader.Out, *shader_fs.Io) void = autoConnect(shader.Out, shader_fs.Io);
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    raster_shader.rasterizeTriangles(
        shader,
        shader_fs,
        &ctx,
        &vs_outs,
        &indices,
        base_fs_io,
        connect,
        .{}, // default: clip-space CCW (matches wgpu front face)
    );
    const t1: i128 = monotonicNs();

    // ---- PROOF: the immediate-mode fixed-function path is the SAME
    //      rasteriser.  Re-draw the identical triangles through raster's
    //      immediate-mode API + the `ff_triangle` hook (-> ffBridge ->
    //      the SAME default_shapes pair), then diff against the direct
    //      path above.  Both now flow through `rasterizeTriangles`, so
    //      a match proves fixed-function and programmable drawing are
    //      one rasteriser.  raster transforms vertices through its own
    //      matrices, so set the matching ortho first.
    var ctx_imm: raster.Context = try .init(gpa, width, height);
    defer ctx_imm.deinit(gpa);
    ctx_imm.clearColor(.{ .r = 24, .g = 24, .b = 32, .a = 255 });
    ctx_imm.clear(.{ .color = true });
    ctx_imm.ff_triangle = ffBridge;
    ctx_imm.matrixMode(.projection);
    ctx_imm.loadIdentity();
    ctx_imm.ortho(0, @floatFromInt(width), @floatFromInt(height), 0, -1, 1);
    ctx_imm.matrixMode(.modelview);
    ctx_imm.loadIdentity();
    ctx_imm.begin(.triangles);
    for (vertices) |v| {
        ctx_imm.color4ub(
            @round(v.color[0] * 255.0),
            @round(v.color[1] * 255.0),
            @round(v.color[2] * 255.0),
            @round(v.color[3] * 255.0),
        );
        ctx_imm.texCoord2f(v.uv[0], v.uv[1]);
        ctx_imm.vertex2f(v.pos[0], v.pos[1]);
    }
    ctx_imm.end();

    const direct_bytes: []const u8 = ctx.colorBufferBytes();
    const imm_bytes: []const u8 = ctx_imm.colorBufferBytes();
    var diff_count: u32 = 0;
    var max_delta: u32 = 0;
    var bi: usize = 0;
    while (bi < direct_bytes.len) : (bi += 1) {
        const da: i32 = direct_bytes[bi];
        const db: i32 = imm_bytes[bi];
        const delta: u32 = @intCast(@abs(da - db));
        if (delta > 2) {
            diff_count += 1;
        }
        if (delta > max_delta) {
            max_delta = delta;
        }
    }
    std.debug.print(
        \\
        \\immediate-mode hook PROOF (fixed-function via the ONE rasteriser):
        \\  direct vs immediate+hook — channels differing >2: {d} / {d}  (max delta {d})
        \\
    , .{ diff_count, direct_bytes.len, max_delta });

    const ms: f64 = float64(t1 - t0) / 1_000_000.0;

    // 8. Encode framebuffer -> PNG.
    const fb_bytes: []const u8 = ctx.colorBufferBytes();
    const png_bytes: []u8 = try codecs.png.encode(gpa, fb_bytes, width, height);
    defer gpa.free(png_bytes);

    const out_path: []const u8 = "sw_engine_shader.png";
    var io_threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const tio: std.Io = io_threaded.io();
    var f: std.Io.File = try std.Io.Dir.cwd().createFile(tio, out_path, .{});
    defer f.close(tio);
    try f.writeStreamingAll(tio, png_bytes);

    std.debug.print(
        \\sw_engine_shader — native CPU rendering through zimr's
        \\                    ENGINE shader pair (default_shapes_*)
        \\
        \\Same source as the wgpu side.  No transpiler.  No two-files.
        \\No drift.  Both backends call `shaderMain(io) Out` on the
        \\identical Zig file.
        \\
        \\Resolution:   {d}x{d}
        \\Triangles:    3 (9 vertices)
        \\VS+raster:    {d:.2} ms  (CPU, single-threaded, ReleaseFast)
        \\Output:       {s} ({d} bytes)
        \\
    , .{ width, height, ms, out_path, png_bytes.len });

    // Phase 2.5 Turn-1: rasteriser perf ground truth (fixed-function vs the
    // programmable path), both driven through the SAME immediate-mode API.
    try runBenchmark(gpa);
}

// ---- Phase 2.5 Turn-1: rasteriser perf ground truth -----------------------
// Renders the `sidebyside` scene (10 alpha-disc fans + a hexagon ~ 246
// triangles/frame, blend on) N times through the SAME immediate-mode driver,
// differing ONLY in `ff_triangle`: `null` routes to the fixed-function
// `triangleKernel`; `ffBridgeBench` routes to `rasterizeTriangles` + the REAL
// `default_shapes_fs`.  Apples-to-apples on the rasteriser; B additionally pays
// a per-triangle fn-ptr + `rasterizeTriangles`'s own clip/project/setup, so it
// is a CONSERVATIVE upper bound vs the target architecture's direct call.

// Blend-aware bridge for the benchmark (the proof's `ffBridge` stays `.{}`):
// reads the context's effective blend state and dispatches the matching
// comptime `RasterizeOpts`, with `front_face = .none` (the 2D scene never
// enables culling, matching `triangleKernel`) and a 1x1 white texture (the
// scene is untextured - `default_shapes_fs` still samples, exactly as on GPU).
