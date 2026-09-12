// examples/wgpu_bringup/wgpu_bringup.zig
//
// The first complete zimr-wgpu app: colored rectangles + a triangle,
// drawn via the raylib-parity API on top of the new wgpu stack.
// Uses ONLY hand-written WGSL (the engine defaults) — no transpiler
// needed.
//
// Build:    zig build wgpu-bringup
// Serve:    bun run webtests/server.ts --web-dir=zig-out/wgpu
// Browse:   http://localhost:8000/index.html
//
// The page (`examples/wgpu_bringup/index.html`) wires the wasm's
// `_initialize` (wasi reactor entry point) to run at startup, then
// drives `update(dt)` from requestAnimationFrame.

const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;

// ============================================================================
// Persistent state
// ============================================================================

// lint:off module-var: wasm app needs persistent allocator across frame callbacks
var gpa_storage: std.heap.DebugAllocator(.{}) = .{};
/// Schema for the trivial Phase D1 validation pipeline.  Carries
/// a one-f32 Ubo (time) to exercise the typed UBO path in loadShader.
/// Mirrors the FS's `trivial_fs_io.zig` schema.
const TrivialSchema = struct {
    pub const Ubo = struct {
        time: f32,
        _pad0: f32 = 0,
        _pad1: f32 = 0,
        _pad2: f32 = 0,
    };
};

/// Schema for the Mandelbrot wgpu pipeline.  Reuses the canonical
/// `mandelbrot_fs_io.Ubo` definition — the SAME struct the FS body
/// reads via its Io.  Same source of truth used by:
///   - the SPIR-V build of `mandelbrot_fs.zig`
///   - any future CPU rendering through that FS
///   - this wgpu-side typed UBO push
///
/// loadShader builds the bind-group layout from this schema, so
/// the runtime UBO bytes line up exactly with what the WGSL
/// shader expects.
/// The Mandelbrot FS schema lives in `mandelbrot_fs_io.zig`.  The
/// `loadShader` call uses it directly — no wrapper struct needed
/// because the io file already declares the `Ubo` (and `Samplers`,
/// where relevant) decls that `@hasDecl(SchemaT, ...)` introspection
/// looks for.
const mandelbrot_fs_io = @import("mandelbrot_fs_io.zig");

const julia_fs_io = @import("julia_fs_io.zig");

const mandel_julia_fs_io = @import("mandel_julia_fs_io.zig");

const State = struct {
    gpa: Allocator,
    gpu_frame: z.GpuFrame,
    pipeline_cache: z.PipelineCache,
    bind_group_cache: z.BindGroupCache,
    renderer: z.Renderer2D,

    /// Second material for the dual-texture path demo.
    checker_texture: z.WgpuTexture = .{},

    /// First real consumer of `loadShader` (Phase D1 validation).
    /// Pre-translated WGSL via `@embedFile`; no transpiler in the
    /// shipped wasm hot path.  Not drawn this frame yet — we just
    /// validate the load path runs to completion.
    trivial_shader: z.shader.LoadedShader(TrivialSchema) = undefined,

    /// Phase F kickoff: load the Mandelbrot FS through the
    /// `loadShader` API using the canonical engine VS (default_shapes_vs)
    /// as its partner.  Exercises the path with a realistic shader's
    /// Ubo (center, zoom, resolution, max_iter — 32 bytes, std140-padded).
    /// Not drawn yet; that requires pipeline-switching + bind-group
    /// rebinding plumbing that's a follow-up turn.
    mandelbrot_shader: z.shader.LoadedShader(mandelbrot_fs_io) = undefined,

    /// Companion Julia and Mandel-Julia pipelines.  Same engine VS,
    /// different FS modules + Ubo schemas.  Drawn side-by-side with
    /// Mandelbrot to mirror the layout of `sw_fractal_gallery.png` —
    /// proving the SAME three FS sources work on both backends.
    julia_shader: z.shader.LoadedShader(julia_fs_io) = undefined,
    mandel_julia_shader: z.shader.LoadedShader(mandel_julia_fs_io) = undefined,

    /// Dedicated vertex buffer for the fullscreen fractal triangle.
    ///
    /// WHY THIS EXISTS (and why the triangle is NOT drawn through the 2D shapes
    /// batch, which is how this file used to do it): `flushBatch` binds the
    /// batch's texture atlas at `gpu_iface.batch_reserved_group` (== 1) under
    /// WHATEVER pipeline is currently bound. Under the mandelbrot pipeline that
    /// group is an `empty_bgl` — `loadShader` mints one for every group below
    /// the highest group the schema uses, and this FS schema uses only group 2 —
    /// so the batch's flush hands WebGPU a bind group the bound layout does not
    /// declare, and WebGPU rejects the WHOLE command buffer at submit. Nothing
    /// renders, not even the pass clear: a black canvas.
    ///
    /// The engine's own answer to this is `wgpu_app.drawFullscreenShader`, which
    /// draws through the shader's OWN pipeline and an engine-owned fullscreen
    /// VBO and never lets the batch flush under a foreign pipeline. This demo
    /// drives `Backend` directly and never builds an `App`, so it cannot call
    /// that helper — it keeps its own equivalent buffer here instead.
    fullscreen_vbo: z.wgpu.BufferHandle = .invalid,

    frame_count: u32 = 0,
};

/// One clip-space triangle covering the viewport, in the default 2D vertex
/// layout (`pos: vec2, uv: vec2, color: u8x4_unorm` — the layout
/// `loadShader` builds its pipeline with). `trivial_vs` is pass-through, so
/// these positions ARE clip space; uv runs 0..2 so the inscribed 0..1 window
/// maps across the canvas. Identical to `wgpu_app.fullscreen_verts`.
const fullscreen_verts = [_]z.Vertex2D{
    .{ .pos = .{ -1, -1 }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 } },
    .{ .pos = .{ 3, -1 }, .uv = .{ 2, 0 }, .color = .{ 255, 255, 255, 255 } },
    .{ .pos = .{ -1, 3 }, .uv = .{ 0, 2 }, .color = .{ 255, 255, 255, 255 } },
};

// lint:off module-var: wasm app state must outlive each JS-driven frame tick
var state: ?State = null;

// ============================================================================
// Init (wasi reactor entry)
// ============================================================================

pub fn main() !void {
    const gpa: Allocator = gpa_storage.allocator();

    const device: z.wgpu.DeviceHandle = z.wgpu.initDevice();
    const queue: z.wgpu.QueueHandle = z.wgpu.getQueue(device);
    const surface: z.wgpu.SurfaceHandle = z.wgpu.getSurface();
    const fmt: z.wgpu.TextureFormat = z.wgpu.getSurfaceFormat(surface);

    // ★ BUILD `State` IN PLACE IN THE GLOBAL — never as a stack local that is
    // copied out at the end.
    //
    // `State` is SELF-REFERENTIAL: `GpuFrame.init` stores `&s.pipeline_cache`
    // and `&s.bind_group_cache`, `Renderer2D.init` stores `&s.gpu_frame`, and
    // every `loadShader(.{ .f = &s.gpu_frame })` keeps that pointer for the
    // program's life. Building into a local `var s: State` and then doing
    // `state = s;` copies the BYTES but leaves all of those pointers aimed at
    // the dead stack frame.
    //
    // It does not crash, which is what makes it nasty: the abandoned stack still
    // holds plausible values, so reads return whatever init left there. Concretely
    // it broke the one-write-per-frame UBO guard — `noteUboWrite` uses
    // `self.f.encoder` as its frame token, `beginFrame` updates that field on the
    // REAL GpuFrame, and the dangling `self.f` kept reading the stale `.invalid`
    // from the dead frame. The token never changed, so the per-frame counter
    // never reset and the assert fired on frame 2, then 3, then 4 — a counter
    // climbing with the frame number is the signature of this bug, not of a
    // genuine double write.
    //
    // Assigning the global FIRST and taking `s` as a pointer into it makes every
    // captured pointer permanent.
    state = .{
        .gpa = gpa,
        .gpu_frame = undefined,
        .pipeline_cache = z.PipelineCache.init(gpa, device),
        .bind_group_cache = z.BindGroupCache.init(gpa, device),
        .renderer = undefined,
    };
    const s: *State = &(state.?);
    s.gpu_frame = z.GpuFrame.init(
        device,
        queue,
        surface,
        fmt,
        &s.pipeline_cache,
        &s.bind_group_cache,
    );
    s.renderer = try z.Renderer2D.init(gpa, &s.gpu_frame);
    s.checker_texture = try z.WgpuTexture.createCheckerboard(
        device,
        queue,
        gpa,
        .{ 0xff, 0xff, 0xff, 0xff },
        .{ 0x00, 0x00, 0x00, 0xff },
        64,
        8,
    );
    // After the turn-1 Renderer2D refactor, swapping the engine's
    // active texture goes through `r.resources.set(.texture0, tex)`
    // rather than building a free-standing material BG.  The smoke
    // demo doesn't actually render with the checker (it's smoke-only,
    // just verifies the texture API path).  Sanity-update via the
    // typed API:
    _ = try s.renderer.resources.set(.texture0, s.checker_texture);
    // Restore the white texture so the demo's batched draws use the
    // pass-through path.
    _ = try s.renderer.resources.set(.texture0, s.renderer.white_tex);

    // Phase D1 validation: load a trivial VS+FS pair through the
    // typed `loadShader` API using PRE-TRANSLATED WGSL.  This is the
    // first real consumer of `loadShader` — proves the path from
    // `addShader` → spv2wgsl → @embedFile → loadShader → render
    // pipeline works end-to-end with a real wasm consumer.  The
    // shaders here have no Ubo and no Samplers — the simplest
    // possible schema.  Empty schema → loadShader's bind group +
    // UBO steps are skipped; we get back a LoadedShader with just
    // a render pipeline handle + dummy bind_group_layout.
    s.trivial_shader = try z.shader.loadShader(TrivialSchema, .{
        .f = &s.gpu_frame,
        .gpa = gpa,
        .vs_wgsl_source = @embedFile("trivial_vs.wgsl"),
        .fs_wgsl_source = @embedFile("trivial_fs.wgsl"),
        .label = "trivial",
    });

    // Mandelbrot fragment shader pipeline.  The Zig source in
    // `examples/mandelbrot_fs.zig` is compiled by the build to SPIR-V,
    // run through spv2wgsl's recursive walker (Turn 3.9), and the
    // resulting WGSL is embedded via @embedFile below.  Phase 6 of
    // the walker rewrite fixed the phi-overwrite-after-if bug that
    // previously made fractal colors render incorrectly; the diagnostic
    // `out_color = red` override is gone from the FS source.
    s.mandelbrot_shader = try z.shader.loadShader(mandelbrot_fs_io, .{
        .f = &s.gpu_frame,
        .gpa = gpa,
        .vs_wgsl_source = @embedFile("trivial_vs.wgsl"),
        .fs_wgsl_source = @embedFile("mandelbrot_fs.wgsl"),
        .label = "mandelbrot",
    });

    // The fullscreen triangle's own vertex buffer — see `State.fullscreen_vbo`
    // for why this demo must not route that triangle through the 2D shapes
    // batch. Uploaded once; the geometry is static in clip space.
    s.fullscreen_vbo = z.wgpu.createBufferInit(
        s.gpu_frame.device,
        s.gpu_frame.queue,
        std.mem.sliceAsBytes(&fullscreen_verts),
        .{ .vertex = true, .copy_dst = true },
        "bringup_fullscreen_vbo",
    );

    // NOTE: no `state = s;` here. `state` was assigned at the TOP of this
    // function and `s` points INTO it — see the comment there. Copying a
    // finished `State` out of a local is exactly the bug that comment describes.
}

// ============================================================================
// Frame
// ============================================================================

export fn update(dt_seconds: f32) void {
    _ = dt_seconds;
    const s: *State = if (state) |*ptr| ptr else return;
    s.frame_count += 1;

    const f: *z.GpuFrame = &s.gpu_frame;
    const Backend: type = z.WgpuBackend;

    // 1. Update the per-frame UBO with a screen-space ortho matrix.
    const view_proj: [16]f32 = z.orthoTopLeft(800, 600);
    s.renderer.updatePerFrame(f, .{ .view_projection = view_proj });

    // 1c. Push the three fractal pipelines' Ubos each frame.  Same
    // values the CPU gallery (sw_fractal_gallery.zig) uses, modulo
    // animation.  resolution = panel size (266×600 for a 3-panel split
    // of an 800×600 canvas).  Mandelbrot zoom oscillates over time so
    // a real-browser run is visibly alive.
    const t: f32 = float(s.frame_count) / 60.0;
    s.trivial_shader.pushUbo(f.queue, .{ .time = t });

    // Push mandelbrot UBO each frame.  Phase 8 (2026-05-29): with
    // the walker producing correct WGSL, we use a real fractal view
    // — center at (-0.5, 0), modest zoom showing the cardioid + main
    // body + first few bulbs, max_iter=512 so the boundary detail
    // resolves.  Earlier diagnostic settings (zoom 0.4, max_iter 64)
    // were tuned for "escape colors dominate" while debugging.
    const zoom: f32 = 1.2;
    s.mandelbrot_shader.pushUbo(f.queue, .{
        .center = .{ -0.5, 0.0 },
        .zoom = zoom,
        .resolution = .{ 800, 600 },
        .max_iter = 512,
    });

    // 2. Begin the frame; the returned FrameContext carries the
    //    encoder + surface view the rest of the frame threads
    //    explicitly.  Nothing is hidden on the GpuFrame.
    const fctx = Backend.beginFrame(f);

    // 3. Open a render pass.
    // NOTE: don't use `defer endRenderPass` — defers run in reverse
    // at scope exit, so the deferred call would land AFTER
    // `endFrame(f)` finishes the encoder, producing "Command buffer
    // recording ended before [RenderPassEncoder] was ended."
    // Explicit ordering: pass.end() THEN encoder.finish().
    var ps = Backend.beginRenderPass(fctx.encoder, .{
        .color_view = fctx.surface_view,
        .clear = .{ .r = 0.06, .g = 0.08, .b = 0.12, .a = 1.0 },
    });
    ps.queue = f.queue;
    ps.batch = &s.renderer.shapes_batch;

    // 4. Bind the renderer's pipeline + bind groups onto the pass.
    s.renderer.bindForPass(&ps);

    // 5. Engine pipeline: draw a few colored shapes through the
    //    shared `shapes_batch`.  Restored Phase 8 (2026-05-29): the
    //    spv2wgsl walker now produces correct mandelbrot WGSL, so we
    //    no longer need to hide everything except the fractal.  These
    //    shapes prove the engine pipeline coexists with the mandelbrot
    //    pipeline in the same render pass.
    //
    //    Screen-space coords (orthoTopLeft 800×600):
    //      - top-left blue square
    //      - top-right green square
    //      - centered magenta triangle
    Backend.drawQuadBatched(&ps, .{
        .pos = .{ .x = 16, .y = 16, .w = 96, .h = 96 },
        .uv = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .color = .{ 80, 140, 230, 220 },
    });
    Backend.drawQuadBatched(&ps, .{
        .pos = .{ .x = 800 - 16 - 96, .y = 16, .w = 96, .h = 96 },
        .uv = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .color = .{ 90, 200, 130, 220 },
    });
    Backend.drawTriangleBatched(&ps, .{
        .p0 = .{ 400, 540 - 80 },
        .p1 = .{ 400 - 70, 540 + 40 },
        .p2 = .{ 400 + 70, 540 + 40 },
        .uv0 = .{ 0.5, 0 },
        .uv1 = .{ 0, 1 },
        .uv2 = .{ 1, 1 },
        .colors = z.uniformColor(.{ 220, 100, 200, 230 }),
    });
    Backend.flushBatch(&ps);

    // 6. Draw a fullscreen-ish triangle through the mandelbrot pipeline.
    //
    // trivial_vs is pass-through — vertex_position goes straight to
    // clip-space position.  So we submit vertices in [-1, +1] clip
    // coords and the FS gets called for every pixel inside.  The FS
    // reads frag_tex_coord (which is varied across the triangle) and
    // produces the mandelbrot color.
    //
    // Big triangle covering most of the screen: (-1,-1), (3,-1), (-1,3).
    // Anything past clip space gets culled, so this efficiently covers
    // the whole [-1,+1]² canvas with one primitive.
    //
    // frag_tex_coord is set so it varies from (0,0) bottom-left to
    // (2,2) — the FS uses io_in.frag_tex_coord * io_in.u.resolution
    // for pixel coords, so this maps to 0..1600 horizontally and
    // 0..1200 vertically.  The mandelbrot center+zoom math handles
    // the rest.
    //
    // ★ DRAWN THROUGH THE SHADER'S OWN PIPELINE, NOT THE 2D SHAPES BATCH.
    // This used to be `drawTriangleBatched` + `flushBatch`, which put a batch
    // flush under a foreign pipeline: the flush binds the batch atlas at
    // `batch_reserved_group` (== 1), where the mandelbrot layout has an
    // `empty_bgl`, and WebGPU then rejects the ENTIRE command buffer at submit —
    // a black canvas, pass clear included. `flushBatch`'s assert names exactly
    // this and it was firing on frame 1. The step-5 `flushBatch` above still
    // runs, and correctly: it drains the 2D shapes while the 2D pipeline is
    // still bound, BEFORE the swap below.
    //
    // This mirrors `wgpu_app.drawFullscreenShader` — bind, set the shader's own
    // vertex buffer, draw non-indexed — which is the engine's general (and
    // documented "strictly safe") fullscreen path. This demo drives `Backend`
    // directly and never builds an `App`, so it cannot call that helper.
    s.mandelbrot_shader.bindForDraw(&ps);
    s.mandelbrot_shader.setVertex(&ps, 0, s.fullscreen_vbo, @sizeOf(@TypeOf(fullscreen_verts)));
    s.mandelbrot_shader.draw(&ps, 3, 1);

    // Restore the 2D shapes pipeline (and, with it, the batch's ownership
    // record) so any later 2D drawing in this pass is correctly owned and the
    // flush guard keeps its teeth. Nothing draws after this today; doing it
    // anyway keeps the bracket symmetric, exactly as `drawFullscreenShader`
    // ends with `bindForPass`.
    s.renderer.bindForPass(&ps);

    Backend.endRenderPass(&ps);
    Backend.endFrame(f);
}

// ============================================================================
// Tests
// ============================================================================

test "State has expected size + alignment" {
    try expect(@sizeOf(State) > 0);
}
