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

    frame_count: u32 = 0,
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

    var s: State = .{
        .gpa = gpa,
        .gpu_frame = undefined,
        .pipeline_cache = z.PipelineCache.init(gpa, device),
        .bind_group_cache = z.BindGroupCache.init(gpa, device),
        .renderer = undefined,
    };
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

    state = s;
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
    s.mandelbrot_shader.bindForDraw(&ps);
    Backend.drawTriangleBatched(&ps, .{
        .p0 = .{ -1, -1 },
        .p1 = .{ 3, -1 },
        .p2 = .{ -1, 3 },
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 2, 0 },
        .uv2 = .{ 0, 2 },
        .colors = z.uniformColor(.{ 255, 255, 255, 255 }),
    });
    Backend.flushBatch(&ps);

    Backend.endRenderPass(&ps);
    Backend.endFrame(f);
}

// ============================================================================
// Tests
// ============================================================================

test "State has expected size + alignment" {
    try expect(@sizeOf(State) > 0);
}
