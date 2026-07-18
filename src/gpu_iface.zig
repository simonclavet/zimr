// src/gpu_iface.zig - the pass-based GPU trait, neither WebGL nor WebGPU shaped.
// WebGPU architecture is documented centrally in src/zimr.zig
// (the module-level `//!` doc) — read that before changing wgpu code.
//
//
// `renderer_trait.zig` (the existing file) defines the IMMEDIATE-MODE trait
// — `begin(.triangles)`, `vertex2f(x, y)`, `end()`.  That's the
// surface the software rasterizer and the WebGL backend both share.
//
// This file (`gpu_iface.zig`) defines the PASS-BASED trait — the
// shape WebGPU actually wants, at zimr's chosen abstraction height
// (per D7).  It's neither WebGL-shaped (no immediate-mode vertex
// submission) nor WebGPU-shaped at the raw level (no manual bind
// group construction at the call site).  It's zimr-shaped:
// **everything that affects what gets drawn is a value the user
// holds**, never a hidden flag on a framework-owned struct.
//
// The big design decision (May 2026, "mach move"):  there is NO
// hidden state machine.  `beginRenderPass` RETURNS a `PassState`
// value; the caller threads it explicitly into every subsequent
// draw / set / flush call.  Compare to the old design which stashed
// `current_pass` / `current_pipeline` / `current_bind_groups[4]`
// onto `GpuFrame` and let callers mutate them implicitly — that
// model looked explicit (you could see the fields) but functioned
// implicitly (`drawQuadBatched(f, ...)` would read+write them
// silently).  We took the mach view: passes are values.
//
// The trait is implemented by two backends:
//
//   - `WgpuBackend` — issues real WebGPU calls via `wgpu.zig` and
//     `render_pass.zig`.
//
//   - `SwBackend` — translates the trait calls into the software
//     rasterizer's API.  Reuses zimr's existing `raster.zig`.
//
// User code that wants SW-compatibility goes through this trait:
//
//   ```
//   const fctx = z.WgpuBackend.beginFrame(&f);
//   var ps = z.WgpuBackend.beginRenderPass(fctx.encoder, .{ ... });
//   ps.batch = &renderer.shapes_batch;  // opt in to batched helpers
//   ps.queue = f.queue;                 // flushBatch needs this
//   defer z.WgpuBackend.endRenderPass(&ps);
//
//   renderer.bindForPass(&ps);
//   z.WgpuBackend.drawQuadBatched(&ps, .{ ... });
//   z.WgpuBackend.flushBatch(&ps);
//   ```
//
// User code that needs WebGPU-only features (render bundles,
// indirect draws, etc.) reads `ps.pass` and calls
// `render_pass.X(ps.pass, ...)` directly — no abstraction wall.
//
// STATUS: scaffolding.  `WgpuBackend` is the path the wgpu engine
// uses.  `SwBackend` is the path the software renderer will use
// once Phase E lands.

const std = @import("std");
const gpu = @import("gpu.zig");
const zm = @import("zm");
const assert = zm.assert;
const assertf = zm.assertf;
const wgpu = @import("wgpu.zig");

// ===========================================================================
// The 2D batch data layer (moved from renderer_2d.zig, structure-plan S0):
// Vertex2D, ShapesBatch and the ring/batch capacities are PASS-level data
// the backend flushes — defining them here makes gpu_iface a leaf (the
// renderer re-exports these names, so its API is unchanged).
// ===========================================================================
pub const max_batch_vertices: u32 = 8192;
pub const max_batch_indices: u32 = 12288;
/// GPU ring-buffer capacity (vertices/indices) — MUCH larger than the CPU
/// staging arrays. Within a frame the batch auto-flushes every
/// max_batch_vertices and APPENDS at a running offset (distinct region per
/// flush, since same-pass draws still reference earlier regions — no wrap). So
/// the GPU buffer must hold a WHOLE FRAME's geometry. A mid-frame flush that
/// reused offset 0 would corrupt earlier same-pass draws; truly freeing a region
/// would require a mid-frame submit + render-pass restart, which on a tiled
/// mobile GPU forces a full attachment store+reload and is unsafe in the shared
/// depth pass — so instead the ring is sized generously for the whole frame and
/// flushBatch asserts (rather than corrupts) if a frame ever exceeds it.
/// Heaviest known frame: Benchmark|Barrel 2.4 (3380 cubes) with the contact
/// overlay on (each contact point is a small filled circle) peaks around ~235K
/// verts / ~475K indices; these caps leave roughly 4x headroom.
pub const vbo_ring_vertices: u32 = 1048576;
pub const ibo_ring_indices: u32 = 1572864;

/// CPU-side vertex format used by the default 2D shapes batch.
pub const Vertex2D = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

/// The @group index the 2D shapes batch binds its texture/sampler at (see
/// `flushBatch`, which does `setBindGroup(ps, batch_reserved_group, atlas)` on
/// every flush; the shapes FS WGSL is built with `--sampler-group=1`). Any
/// fullscreen shader drawn THROUGH the batch (`drawFullscreenTriangle`) must
/// NOT use this group, or the flush silently clobbers its binding. The
/// comptime guard in `bindFullscreenShader` enforces this; centralize the
/// number here so the guard and the batch can never drift apart.
///
/// The OTHER trap this number creates: a custom `LoadedShader.bindForDraw`
/// that happens to place a resource at THIS group (e.g. a vertex-visible
/// sampler) and then lets 2D immediate mode run again on the same pass. The
/// next `flushBatch` binds the atlas here under the still-bound custom
/// pipeline → "BindGroupLayout does not match at group index 1" and the whole
/// command buffer is rejected. That one CAN'T be a comptime guard (the pass
/// mixing is a runtime sequence, not a static property), so `flushBatch`
/// carries a runtime assert instead — see `PassState.batch_owner_pipeline`.
/// The fix at the call site is to bracket the custom draw:
/// `f.gl.flushBeforeMaterialSwap()` before it, `f.gl.renderer().bindForPass(ps)`
/// after it. `pipeline_basic` gets away without the bracket only because its
/// shader binds no resources at all; `pipeline_sampler` only because it puts
/// its sampler at group 0. `vertex_texture_test` is the worked example of the
/// bracket done right.
pub const batch_reserved_group: u32 = 1;

/// Whether it is safe for `flushBatch` to drain the 2D shapes batch under
/// `current_pipeline`, given the `batch_owner` the 2D renderer last recorded
/// (via `bindForPass` / `setBlend` / `setUserShader` / `clearUserShader`).
///
/// Safe when the owner is unknown — the 2D renderer hasn't bound a batch
/// pipeline this pass, so we refuse to guess — OR the bound pipeline IS that
/// owner. A `false` here means a FOREIGN pipeline (a custom `bindForDraw` that
/// wasn't followed by `renderer().bindForPass`) is bound, and the flush would
/// bind the atlas at group `batch_reserved_group` against a pipeline that
/// expects something else there. Named + unit-tested (see the test just below)
/// so the invariant lives somewhere testable, not only inside an assert
/// expression that a refactor could quietly invert.
pub fn batchFlushPipelineOk(
    current_pipeline: ?wgpu.RenderPipelineHandle,
    batch_owner: ?wgpu.RenderPipelineHandle,
) bool {
    const owner: wgpu.RenderPipelineHandle = batch_owner orelse return true;
    return current_pipeline == owner;
}

test "batchFlushPipelineOk: catches a foreign pipeline, allows the batch owner" {
    const t: type = std.testing;
    const shapes: wgpu.RenderPipelineHandle = @enumFromInt(1);
    const foreign: wgpu.RenderPipelineHandle = @enumFromInt(2);
    // Owner unknown → don't guess (some other bug catches a truly-unbound draw).
    try t.expect(batchFlushPipelineOk(null, null));
    try t.expect(batchFlushPipelineOk(shapes, null));
    // Owner known and bound → safe (the normal 2D path, and BeginShaderMode).
    try t.expect(batchFlushPipelineOk(shapes, shapes));
    // Owner known but a FOREIGN pipeline is bound → the bug we guard against.
    try t.expect(!batchFlushPipelineOk(foreign, shapes));
    // Owner known but nothing bound → also wrong (missing restore).
    try t.expect(!batchFlushPipelineOk(null, shapes));
}

/// Accumulating shapes batch.  Vertices accumulate into the CPU
/// arrays; on flush they're uploaded to `vbo`/`ibo` and emitted as a
/// single indexed draw call.  See `gpu_iface.flushBatch`.
///
/// Flush triggers: texture switch, shader switch, blend mode switch,
/// batch full, end of pass.
pub const ShapesBatch = struct {
    // GPU side (long-lived, allocated at app init by Renderer2D)
    vbo: wgpu.BufferHandle = .invalid,
    ibo: wgpu.BufferHandle = .invalid,

    // CPU staging (mutated by drawQuadBatched / drawTriangleBatched)
    vertices: [max_batch_vertices]Vertex2D = undefined,
    indices: [max_batch_indices]u16 = undefined,
    vertex_count: u32 = 0,
    index_count: u32 = 0,

    // Running byte offsets into vbo/ibo for the CURRENT frame. Multiple flushes
    // per frame (a material/texture swap forces one) must each write to a
    // DISTINCT region of the buffer: queueWriteBuffer lands on the queue
    // timeline (before any encoder draw), so writing every flush to offset 0
    // would make all draws read only the last flush's data. flushBatch appends
    // at these offsets + draws with base_vertex/first_index, then advances them.
    // beginDrawing resets them to 0 each frame. (Vertices written so far this
    // frame; used as base_vertex.)
    vbo_vertex_base: u32 = 0,
    ibo_index_base: u32 = 0,

    // State machine — which material is being accumulated.  A switch
    // here forces a flush (else the batch would mix textures).
    current_texture: wgpu.TextureHandle = .invalid,
    current_texture_view: wgpu.TextureViewHandle = .invalid,
    current_texture_bind_group: wgpu.BindGroupHandle = .invalid,
    current_shader: wgpu.RenderPipelineHandle = .invalid,

    current_blend: wgpu.BlendMode = .alpha,

    /// Change the material bind group SAFELY. The batch resolves the bind group
    /// lazily at flush/submit time, so changing it while geometry is staged
    /// (`vertex_count > 0`) would retroactively re-bind ALREADY-RECORDED
    /// vertices to the new texture — the deferred-draw aliasing class (turn 909
    /// black-shapes). Callers MUST flush first; this asserts they did. In debug
    /// it panics at the offending call instead of silently corrupting; in
    /// release it's a no-cost direct store. (The texture-bind paths in
    /// WgpuGl.zig flush via flushBeforeMaterialSwap before calling this.)
    pub fn bindTextureGroup(self: *ShapesBatch, bg: wgpu.BindGroupHandle) void {
        assert(self.vertex_count == 0, @src()); // flush before swapping material
        self.current_texture_bind_group = bg;
    }
};

const GpuFrame = gpu.GpuFrame;

// ============================================================================
// SECTION 1 — required method list (comptime trait check)
// ============================================================================

const required_methods: []const []const u8 = &.{
    // Frame lifecycle
    "beginFrame",
    "endFrame",

    // Pass lifecycle
    "beginRenderPass",
    "endRenderPass",
    "beginComputePass",
    "endComputePass",

    // Common 2D primitives — every one takes `*PassState`
    "drawQuadBatched",
    "drawTriangleBatched",
    "flushBatch",

    // Pipeline / bind-group state — every one takes `*PassState`
    "setPipeline",
    "setBindGroup",

    // NOTE: setMatrix and clearColor are NOT part of the trait.
    // setMatrix is drawing-layer state (lives on Renderer2D's
    // matrix_stack; user calls `renderer.matrix_stack.setCurrent(m)`
    // directly).  clearColor is set via `BeginRenderPassDesc.clear`
    // — there's no need for a deferred "set this for next pass"
    // method, since the caller controls beginRenderPass.
};

/// Compile-time check that `T` implements the trait.  Emits a clear
/// `@compileError` naming the type AND the missing method when a
/// backend is incomplete.  Better than the "no field named X" errors
/// raw `anytype` would produce at the use site.
pub fn assertIsGpuBackend(comptime T: type) void {
    inline for (required_methods) |name| {
        if (!@hasDecl(T, name)) {
            @compileError("gpu_iface: type `" ++ @typeName(T) ++
                "` is missing required method `" ++ name ++ "`.");
        }
    }
}

// ============================================================================
// SECTION 2 — descriptor / value types
// ============================================================================

pub const ClearDesc = struct {
    color: wgpu.ColorF32,
};

/// 2D rectangle for positions and texture-coordinate windows.
/// Used as the basic shape primitive for `QuadDesc`.  Field order
/// matches the convention `{ x, y, w, h }` — top-left + size.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const QuadDesc = struct {
    /// World-space rectangle the quad covers.
    pos: Rect,
    /// UV rectangle sampled from the bound texture.  Default is the
    /// full-texture window (0, 0, 1, 1) — what the caller wants for
    /// the common case of sampling an entire texture once.
    uv: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    /// Per-vertex tint (uniform across the four corners).  RGBA bytes.
    color: [4]u8 = .{ 255, 255, 255, 255 },
};

/// Quick helper for the common case of three vertices sharing a color.
/// Use as `.colors = uniformColor(.{ 255, 0, 0, 255 })`.
pub fn uniformColor(c: [4]u8) [3][4]u8 {
    return .{ c, c, c };
}

pub const TriangleDesc = struct {
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 0, 0 },
    uv2: [2]f32 = .{ 0, 0 },
    /// Per-vertex colors.  `frag_color` varying interpolates them
    /// across the triangle.  For uniform color, use the
    /// `uniformColor` helper: `.colors = uniformColor(.{ r, g, b, a })`.
    /// Default: white on all three vertices.
    colors: [3][4]u8 = .{
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
        .{ 255, 255, 255, 255 },
    },
};

pub const BeginRenderPassDesc = struct {
    color_view: wgpu.TextureViewHandle,
    clear: ?wgpu.ColorF32 = null,
    depth_view: ?wgpu.TextureViewHandle = null,
    resolve_view: ?wgpu.TextureViewHandle = null,
    label: []const u8 = "render",
};

/// `beginRenderPassMrt` options: N color views, one clear for all, one
/// shared depth.  No MSAA resolve — the G-buffer is 1-sample by nature
/// (you can't meaningfully resolve world positions).
pub const BeginRenderPassMrtDesc = struct {
    color_views: []const wgpu.TextureViewHandle,
    clear: ?wgpu.ColorF32 = null,
    depth_view: ?wgpu.TextureViewHandle = null,
    label: []const u8 = "mrt_render",
};

/// Returned by `beginFrame`.  Carries the values the rest of the
/// frame's draw code needs to thread through every call.  The
/// user assigns this to a local; it's not stashed on `GpuFrame`.
/// (`GpuFrame.encoder` and `GpuFrame.surface_view` are also set as
/// a convenience copy for callers that prefer the older accessor
/// style; both ARE the values returned here.)
pub const FrameContext = struct {
    encoder: wgpu.CommandEncoderHandle,
    surface_view: wgpu.TextureViewHandle,
    /// The frame-owned depth view (matched to the surface size each frame).
    /// `.invalid` when the frame has no depth_format. Pass this straight to
    /// `beginRenderPass(.{ ..., .depth_view = fctx.depth_view })`.
    depth_view: wgpu.TextureViewHandle = .invalid,
};

/// SW dispatch vtable, stored as a comptime const per
/// `RenderPipeline(VsT, FsT)` type.  One pointer-deref away from
/// `PassState.sw_dispatch`; turn 3's `SwBackend.flushBatch` calls
/// through it.
///
/// The vtable lives inside `RenderPipeline(VsT, FsT)` as
/// `pub const sw_dispatch = ...` so:
///   - It's per-TYPE, not per-instance — no allocation, no per-pipe
///     setup cost.
///   - `setPipeline` records the pointer with `&@TypeOf(pipe).sw_dispatch`.
///   - The functions inside are comptime-specialized with VsT and FsT
///     captured in their closures.
///
/// Why a vtable rather than a single function pointer:
/// future SW operations (drawIndirect, drawNonIndexed, etc.) can be
/// added as new fields without re-architecting.  Today it carries
/// `flushBatch` only.
pub const SwPipelineDispatch = struct {
    /// SW counterpart of `SwBackend.flushBatch`.  Iterates the
    /// pass's ShapesBatch, applies the VS view-projection inline,
    /// rasterizes triangles with `raster_shader.rasterizeTriangles`,
    /// dispatches the FS per pixel.  All called types
    /// (VsT.Out, FsT.Io, etc.) are captured at comptime in the
    /// closure that produced this pointer.
    ///
    /// Args type-erased because the function-pointer signature
    /// can't carry `comptime VsT, comptime FsT`; the closure has
    /// them already.
    flush_batch: *const fn (ctx_opaque: *anyopaque, ps_opaque: *anyopaque) void,
};

/// Live state for ONE render pass.  Created by `beginRenderPass`,
/// threaded by reference into every draw / set call, ended by
/// `endRenderPass`.  Composes the WebGPU pass handle with the
/// dedup cache, the user-chosen target batch, and the queue
/// handle for batch uploads.
///
/// Every field is set by the user (directly, or via the methods
/// that return `PassState`).  Nothing the framework writes to is
/// hidden; nothing the framework reads from comes from globals.
///
/// Typical lifetime:
///
/// ```
/// var ps = WgpuBackend.beginRenderPass(encoder, .{ ... });
/// ps.queue = f.queue;
/// ps.batch = &renderer.shapes_batch;
/// defer WgpuBackend.endRenderPass(&ps);
/// // ... draw calls take `&ps` ...
/// ```
pub const PassState = struct {
    /// The underlying WebGPU pass.  User code that needs raw
    /// `render_pass.X(ps.pass, ...)` calls reads this directly.
    pass: wgpu.RenderPassEncoderHandle,

    /// Whether this pass has a depth attachment (set by beginRenderPass). The
    /// shapes batch (a depth-LESS pipeline) asserts this is false in debug:
    /// binding a no-depth pipeline to a depth pass is the cryptic
    /// "Attachment state ... not compatible" GPU error -> black frame. The
    /// assert turns it into a clear, located panic. (Can't be a COMPILE error:
    /// the pass's depth attachment is a runtime decision and the pipeline handle
    /// is opaque — no comptime expression spans both. This is the loud-runtime
    /// guard, same as the bind-group + scissor asserts.)
    has_depth: bool = false,

    /// Queue handle — needed by `flushBatch` to upload accumulated
    /// vertex/index data.  Optional only because not every pass
    /// uses the batched helpers; required if `flushBatch` is called.
    queue: wgpu.QueueHandle = .invalid,

    /// Shapes batch the batched draw helpers operate on.  Set by
    /// the caller (typically `Renderer2D.bindForPass` or directly
    /// in user code).  When null, `drawQuadBatched` /
    /// `drawTriangleBatched` / `flushBatch` are no-ops.
    batch: ?*ShapesBatch = null,

    /// Most recently set pipeline.  `setPipeline` consults this
    /// to suppress redundant binds within the same pass; reset
    /// to null whenever a new pass starts (WebGPU spec: new pass
    /// = no pipeline bound).
    current_pipeline: ?wgpu.RenderPipelineHandle = null,

    /// SW dispatch vtable for the current pipeline.  Populated by
    /// `setPipeline` from `@TypeOf(pipeline).sw_dispatch` (comptime
    /// const on `RenderPipeline(VsT, FsT)`).  `null` when the
    /// pipeline can't be SW-dispatched (wgpu-only).
    ///
    /// `SwBackend.flushBatch` calls through `sw_dispatch.?.flush_batch`
    /// to do the actual rasterization.  The wgpu path ignores it.
    sw_dispatch: ?*const SwPipelineDispatch = null,

    /// Most recently set bind group, per group index.  Same
    /// dedup semantics as `current_pipeline`.
    current_bind_groups: [4]?wgpu.BindGroupHandle = .{ null, null, null, null },

    /// The pipeline that OWNS the 2D shapes batch — set by
    /// `Renderer2D.bindForPass` to the shapes pipeline handle whenever it
    /// binds that pipeline at pass start (and on blend/material swaps).
    ///
    /// This exists purely so `flushBatch` can ASSERT that the pipeline bound
    /// at drain time is the batch's owner — NOT to auto-rebind it (binding
    /// stays the consumer's explicit job; see flushBatch). It's the diagnostic
    /// half of the "pipeline binding is the consumer's responsibility" rule.
    ///
    /// The trap it guards: `flushBatch` binds the batch's texture atlas at
    /// group `batch_reserved_group` (== 1). If you do a custom
    /// `LoadedShader.bindForDraw` (which binds YOUR pipeline + YOUR group-1
    /// resource) and then issue a 2D immediate call (text/caption/clearViewport)
    /// without restoring the 2D pipeline, the next material-swap flush drains
    /// the batch while YOUR pipeline is still bound — so the atlas lands at
    /// group 1 against a pipeline that expects something else there. WebGPU
    /// rejects the whole command buffer with the opaque "BindGroupLayout
    /// 'resources_bgl' ... does not match ... at group index 1". The assert in
    /// flushBatch turns that into a located panic naming the fix. Runtime-only
    /// for the same reason as `has_depth`: the bound pipeline is an opaque
    /// handle chosen at runtime, so no comptime expression can span the check.
    batch_owner_pipeline: ?wgpu.RenderPipelineHandle = null,
};

// ============================================================================
// SECTION 3 — WgpuBackend (the real thing)
// ============================================================================

/// The wgpu-backed implementation of the trait.  Every method takes
/// explicit arguments — no hidden state on `GpuFrame`.
///
/// History: pre-2026-05 this stashed `current_pass`, `current_pipeline`,
/// and `current_bind_groups[4]` on `GpuFrame` and mutated them
/// implicitly.  The "mach move" took those out — passes return
/// values; dedup state lives on `PassState`; the user threads
/// everything.  Bigger call sites, smaller magic.
pub const WgpuBackend = struct {
    /// Begin a frame.  Acquires the surface texture view, creates a
    /// fresh command encoder, returns both as a `FrameContext` the
    /// caller threads into `beginRenderPass`.
    ///
    /// As a convenience the same two values are also written back
    /// to `f.surface_view` and `f.encoder` — older call sites that
    /// reach for `f.encoder` still find it.  Both are equivalent;
    /// using the returned `FrameContext` is preferred.
    ///
    /// Drawing-layer state (matrix stack, shapes batch) lives on
    /// `Renderer2D`, not on `GpuFrame`, so it's NOT reset here.
    /// Callers that want a fresh batch / identity matrix call
    /// `renderer.matrix_stack.reset()` and reset
    /// `renderer.shapes_batch.vertex_count`/`index_count`
    /// themselves (or rely on `flushBatch` having drained the batch
    /// at the previous pass's end).
    pub fn beginFrame(f: *GpuFrame) FrameContext {
        f.surface_view = wgpu.getCurrentTextureView(f.surface);
        f.encoder = wgpu.createCommandEncoder(f.device);
        // Make the owned depth texture exist + match the surface size (no-op
        // when the frame has no depth_format). This is what guarantees the
        // depth attachment can never mismatch the color attachment.
        f.ensureDepth();
        return .{
            .encoder = f.encoder,
            .surface_view = f.surface_view,
            .depth_view = f.depth_view,
        };
    }

    /// End the frame.  Finishes the encoder, submits the command
    /// buffer, presents the surface.  All open passes MUST be
    /// closed by the caller (via `endRenderPass` / `endComputePass`)
    /// before this is called.  In debug builds, the encoder.finish
    /// path would surface a WebGPU validation error if a pass were
    /// left open — we don't pre-check here because the validation
    /// message is more diagnostic than a Zig panic would be.
    pub fn endFrame(f: *GpuFrame) void {
        const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(f.encoder);
        wgpu.queueSubmit(f.queue, cmd);
        wgpu.surfacePresent(f.surface);
    }

    /// Begin a render pass.  Returns a `PassState` carrying the
    /// underlying pass handle and the dedup cache.  Caller fills in
    /// `.queue` and `.batch` before calling the batched draw helpers
    /// (or leaves them at defaults to use only the lower-level
    /// `setPipeline` / `setBindGroup` / direct-`render_pass.X` calls).
    pub fn beginRenderPass(
        encoder: wgpu.CommandEncoderHandle,
        desc: BeginRenderPassDesc,
    ) PassState {
        const pass = @import("wgpu.zig").render_pass.begin(.{
            .encoder = encoder,
            .color_view = desc.color_view,
            .clear = desc.clear,
            .depth_view = desc.depth_view,
            .resolve_view = desc.resolve_view,
            .label = desc.label,
        });
        // depth_view is set to .invalid (wrapped, not null) when the frame has
        // no depth attachment — so check the sentinel, not just optional-null.
        const has_depth: bool = if (desc.depth_view) |dv| dv != .invalid else false;
        return .{ .pass = pass, .has_depth = has_depth };
    }

    /// MRT sibling of `beginRenderPass`: one pass, several color
    /// attachments (fragment `@location(N)` → `color_views[N]`), one
    /// shared depth.  Same PassState contract as the single-view path.
    pub fn beginRenderPassMrt(
        encoder: wgpu.CommandEncoderHandle,
        desc: BeginRenderPassMrtDesc,
    ) PassState {
        const pass = @import("wgpu.zig").render_pass.beginMrt(.{
            .encoder = encoder,
            .color_views = desc.color_views,
            .clear = desc.clear,
            .depth_view = desc.depth_view,
            .label = desc.label,
        });
        const has_depth: bool = if (desc.depth_view) |dv| dv != .invalid else false;
        return .{ .pass = pass, .has_depth = has_depth };
    }

    pub fn endRenderPass(ps: *PassState) void {
        @import("wgpu.zig").render_pass.end(ps.pass);
        // Zero the dedup cache — a stale PassState reused without a
        // fresh beginRenderPass would otherwise silently skip the
        // first bind on the next pass.  The user is supposed to drop
        // the value, but defensive zeroing makes accidental reuse
        // produce correct (just slightly slower) behavior.
        ps.current_pipeline = null;
        ps.current_bind_groups = .{ null, null, null, null };
    }

    /// Begin a compute pass.  Symmetric to `beginRenderPass` but
    /// without the dedup state (compute passes are typically one-
    /// dispatch and don't need pipeline-bind dedup).  Returns the
    /// raw pass handle; user calls `render_pass.X(handle, ...)`
    /// directly.  The richer ComputePassState shape can land if a
    /// real use case for dedup emerges.
    pub fn beginComputePass(
        encoder: wgpu.CommandEncoderHandle,
    ) wgpu.ComputePassEncoderHandle {
        return @import("wgpu.zig").compute_pass.begin(encoder);
    }

    pub fn endComputePass(pass: wgpu.ComputePassEncoderHandle) void {
        @import("wgpu.zig").compute_pass.end(pass);
    }

    /// Accumulate a quad into the user-chosen batch.  Flushes
    /// transparently if the batch would overflow.  No-op when
    /// `ps.batch == null` (caller forgot to set it).
    pub fn drawQuadBatched(ps: *PassState, desc: QuadDesc) void {
        const b: *ShapesBatch = ps.batch orelse return;
        if (b.vertex_count + 4 > max_batch_vertices or
            b.index_count + 6 > max_batch_indices)
        {
            flushBatch(ps);
        }
        const base: u16 = @intCast(b.vertex_count);
        const c: [4]u8 = desc.color;
        const p: Rect = desc.pos;
        const uv: Rect = desc.uv;
        b.vertices[b.vertex_count + 0] = .{
            .pos = .{ p.x, p.y },
            .uv = .{ uv.x, uv.y },
            .color = c,
        };
        b.vertices[b.vertex_count + 1] = .{
            .pos = .{ p.x + p.w, p.y },
            .uv = .{ uv.x + uv.w, uv.y },
            .color = c,
        };
        b.vertices[b.vertex_count + 2] = .{
            .pos = .{ p.x + p.w, p.y + p.h },
            .uv = .{ uv.x + uv.w, uv.y + uv.h },
            .color = c,
        };
        b.vertices[b.vertex_count + 3] = .{
            .pos = .{ p.x, p.y + p.h },
            .uv = .{ uv.x, uv.y + uv.h },
            .color = c,
        };
        b.indices[b.index_count + 0] = base + 0;
        b.indices[b.index_count + 1] = base + 1;
        b.indices[b.index_count + 2] = base + 2;
        b.indices[b.index_count + 3] = base + 0;
        b.indices[b.index_count + 4] = base + 2;
        b.indices[b.index_count + 5] = base + 3;
        b.vertex_count += 4;
        b.index_count += 6;
    }

    pub fn drawTriangleBatched(ps: *PassState, desc: TriangleDesc) void {
        const b: *ShapesBatch = ps.batch orelse return;
        if (b.vertex_count + 3 > max_batch_vertices or
            b.index_count + 3 > max_batch_indices)
        {
            flushBatch(ps);
        }
        const base: u16 = @intCast(b.vertex_count);
        b.vertices[b.vertex_count + 0] = .{ .pos = desc.p0, .uv = desc.uv0, .color = desc.colors[0] };
        b.vertices[b.vertex_count + 1] = .{ .pos = desc.p1, .uv = desc.uv1, .color = desc.colors[1] };
        b.vertices[b.vertex_count + 2] = .{ .pos = desc.p2, .uv = desc.uv2, .color = desc.colors[2] };
        b.indices[b.index_count + 0] = base + 0;
        b.indices[b.index_count + 1] = base + 1;
        b.indices[b.index_count + 2] = base + 2;
        b.vertex_count += 3;
        b.index_count += 3;
    }

    /// Flush the batched draw queue.  Uploads accumulated vertex /
    /// index data, sets the batch's pipeline + material bind group
    /// (deduped via PassState), and issues a single indexed draw.
    /// No-op when `ps.batch == null` or the batch is empty.
    pub fn flushBatch(ps: *PassState) void {
        const b: *ShapesBatch = ps.batch orelse return;
        if (b.vertex_count == 0) {
            return;
        }
        // The 2D shapes pipeline now carries a matching depth state
        // (compare=always, see renderer_2d) whenever a depth target exists, so
        // flushing the batch into the depth-attached *shared* pass — the one the
        // 3D immediate path renders into — is valid (the 2D draws compose on top
        // of the depth-tested 3D). When there's no depth target, both pipeline
        // and pass are depth-free. The pipeline's depth state tracks the pass,
        // so no assert is needed here.

        // Vertex buffer: 20 bytes/vertex × N — always a multiple of 4.
        // Append at the running offset (NOT 0): multiple flushes/frame share
        // one buffer and each must occupy a distinct region, else the
        // queue-timeline writes clobber each other (only the last survives).
        // NOTE: this means a single frame's geometry must fit in
        // max_batch_vertices/INDICES (no wrap — wrapping would overwrite a
        // region an earlier same-pass draw still references). The buffers are
        // sized generously for that.
        {
            // A whole frame's 2D geometry must fit in the ring (see vbo_ring_vertices): the
            // running offset can't wrap, because earlier same-pass draws still reference their
            // regions. If a frame exceeds it, assertf surfaces it — debug @panics, release logs
            // to the page's log overlay and keeps running, ship compiles the check out — and we
            // then drop this batch (abort its draw) rather than wrap and clobber earlier geometry.
            // The ring has generous headroom for the heaviest known frame, so this isn't hit in
            // normal use; reaching it means a scene needs a bigger ring.
            const fits: bool = b.vbo_vertex_base + b.vertex_count <= vbo_ring_vertices and
                b.ibo_index_base + b.index_count <= ibo_ring_indices;
            assertf(
                fits,
                @src(),
                "2D shapes ring overflow: a frame needs more than {d} verts / {d} indices " ++
                    "(at base {d}/{d}, adding {d}/{d}); dropping a batch. " ++
                    "Raise vbo_ring_vertices/ibo_ring_indices.",
                .{
                    vbo_ring_vertices,
                    ibo_ring_indices,
                    b.vbo_vertex_base,
                    b.ibo_index_base,
                    b.vertex_count,
                    b.index_count,
                },
            );
            if (fits == false) {
                b.vertex_count = 0;
                b.index_count = 0;
                return;
            }
        }
        const vbyte_off: u64 = @as(u64, b.vbo_vertex_base) * @sizeOf(Vertex2D);
        wgpu.queueWriteBuffer(ps.queue, b.vbo, vbyte_off, std.mem.sliceAsBytes(b.vertices[0..b.vertex_count]));

        // Index buffer: u16 × N.  WebGPU requires `queueWriteBuffer`
        // size to be a multiple of 4, so odd index counts (e.g. 9
        // for 3 triangles → 18 bytes) fail validation with
        // `OperationError: Number of bytes to write must be a
        // multiple of 4`.  Round the slice length up; the index
        // buffer is sized with the same rounding via createBuffer
        // so the trailing 2 bytes land inside the buffer.  The
        // drawIndexed call below uses `index_count`, so the extra
        // 0 index doesn't draw anything spurious.
        const ibyte_off: u64 = @as(u64, b.ibo_index_base) * 2;
        const raw_indices_bytes: []const u8 = std.mem.sliceAsBytes(b.indices[0..b.index_count]);
        const padded_len = (raw_indices_bytes.len + 3) & ~@as(usize, 3);
        if (padded_len == raw_indices_bytes.len) {
            wgpu.queueWriteBuffer(ps.queue, b.ibo, ibyte_off, raw_indices_bytes);
        } else {
            // Read one extra u16 past `index_count`.  Safe because
            // `b.indices` is a fixed-size array sized to
            // `max_batch_indices` (much larger than `index_count`)
            // and the trailing value is zeroed/ignored by the GPU
            // since `drawIndexed` uses `index_count`, not the
            // buffer's full byte length.
            const padded_bytes: []const u8 = std.mem.sliceAsBytes(b.indices[0 .. b.index_count + 1]);
            wgpu.queueWriteBuffer(ps.queue, b.ibo, ibyte_off, padded_bytes[0..padded_len]);
        }

        const rp = @import("wgpu.zig").render_pass;
        // Pipeline binding is the consumer's responsibility (typically
        // `Renderer2D.bindForPass` at pass start) — flushBatch does
        // NOT re-bind the pipeline.  Pre-turn-2 the defensive bind
        // here used a raw handle field on `ShapesBatch`; with the
        // typed-pipeline rule in turn 2, the right answer is to make
        // pipeline-binding the consumer's job and have flushBatch
        // only drain the batch.  setBindGroup is still here because
        // material swaps between flushes (white tex ↔ user texture)
        // require it — that state lives on the batch itself.
        // GUARD (loud, located — sibling to the `has_depth` guard above).
        // We are about to bind the batch's texture atlas at group
        // `batch_reserved_group` (== 1) under whatever pipeline is CURRENTLY
        // bound, then drawIndexed. That pipeline must be the one the 2D
        // renderer last bound for batch drawing — `bindForPass` / `setBlend` /
        // `setUserShader` / `clearUserShader` each record it in
        // `ps.batch_owner_pipeline`. If a custom `LoadedShader.bindForDraw`
        // bound its own pipeline and no `f.gl.renderer().bindForPass(ps)`
        // restored the 2D pipeline before this 2D op, they differ — and the
        // atlas would bind at group 1 against a pipeline that expects something
        // else there (e.g. a vertex-visible sampler). WebGPU then rejects the
        // WHOLE command buffer at submit with the opaque "BindGroupLayout
        // 'resources_bgl' ... does not match ... at group index 1". This turns
        // that into a located panic (debug) / page-overlay log (release) that
        // names the fix. Only checked once the 2D renderer has bound a batch
        // pipeline this pass (owner set) so we never guess. Runtime-only for the
        // same reason as `has_depth`: the bound pipeline is an opaque handle
        // chosen at runtime — no comptime expression spans the two.
        if (ps.batch_owner_pipeline) |batch_owner| {
            assertf(
                batchFlushPipelineOk(ps.current_pipeline, batch_owner),
                @src(),
                "2D shapes batch flushed while a foreign pipeline is bound. The batch " ++
                    "binds its atlas at group {d}, but the bound pipeline is not the 2D " ++
                    "renderer's — so the atlas would land at group {d} against a pipeline " ++
                    "that expects a different resource there, and WebGPU rejects the whole " ++
                    "command buffer (\"BindGroupLayout does not match at group index {d}\"). " ++
                    "Cause: a custom `shader.bindForDraw(ps)` followed by a 2D immediate call " ++
                    "(text / caption / clearViewport / any shape) without restoring the 2D " ++
                    "pipeline. Fix: bracket the custom draw — `f.gl.flushBeforeMaterialSwap()` " ++
                    "BEFORE it (drain queued 2D under the 2D pipeline), then " ++
                    "`f.gl.renderer().bindForPass(ps)` AFTER it (restore the 2D pipeline) " ++
                    "before any further 2D drawing. Same bracketing draw3d.zig uses around " ++
                    "its point/decal draws.",
                .{ batch_reserved_group, batch_reserved_group, batch_reserved_group },
            );
        }
        setBindGroup(ps, batch_reserved_group, b.current_texture_bind_group);
        rp.setVertexBuffer(ps.pass, .{ .slot = 0, .buffer = b.vbo });
        rp.setIndexBuffer(ps.pass, .{ .buffer = b.ibo, .format = .uint16 });
        rp.drawIndexed(ps.pass, .{
            .index_count = b.index_count,
            .first_index = b.ibo_index_base,
            .base_vertex = @intCast(b.vbo_vertex_base),
        });

        b.vbo_vertex_base += b.vertex_count;
        b.ibo_index_base += b.index_count;
        if (b.ibo_index_base & 1 != 0) {
            b.ibo_index_base += 1;
        }
        b.vertex_count = 0;
        b.index_count = 0;
    }

    /// Bind a render pipeline to this pass.  Accepts ONLY
    /// `RenderPipeline(VsT, FsT)` — comptime-asserted via the
    /// presence of `Vs` and `Fs` decls.  Raw handles are rejected
    /// at compile time with a clear error.
    ///
    /// Wgpu-only consumers pick `RenderPipeline(void, void)`;
    /// SW-aware consumers use real shader types.  Both go through
    /// the same path here.
    ///
    /// Side effect on `PassState`:
    /// - `current_pipeline` set to the raw gpu handle (for dedup)
    /// - `sw_dispatch` set to `&@TypeOf(pipeline).sw_dispatch` —
    ///   the per-pipeline-type comptime vtable.  Null for wgpu-only
    ///   pipelines.
    pub fn setPipeline(ps: *PassState, pipeline: anytype) void {
        const T = @TypeOf(pipeline);
        if (!@hasDecl(T, "Vs") or !@hasDecl(T, "Fs")) {
            @compileError("setPipeline expects RenderPipeline(VsT, FsT); " ++
                "got `" ++ @typeName(T) ++ "`.  Wrap raw handles in " ++
                "`RenderPipeline(void, void){ .gpu_handle = h }` for " ++
                "wgpu-only pipelines, or use real shader types for " ++
                "SW-dispatchable pipelines.");
        }
        if (ps.current_pipeline) |cur| {
            if (cur == pipeline.gpu_handle) {
                return; // already bound — skip
            }
        }
        @import("wgpu.zig").render_pass.setPipeline(ps.pass, pipeline.gpu_handle);
        ps.current_pipeline = pipeline.gpu_handle;
        // Pull the SW vtable from the pipeline TYPE (comptime const,
        // no runtime cost).  Null for wgpu-only pipelines.
        ps.sw_dispatch = T.sw_dispatch;
    }

    /// Cache-aware pipeline bind for a RAW wgpu pipeline handle — wgpu-only
    /// pipelines that carry no SW-dispatch vtable (DrawPoints, FluidDiscs, decals,
    /// etc.). This is the sanctioned alternative to calling
    /// `render_pass.setPipeline` directly: it keeps `ps.current_pipeline` in sync,
    /// so a later dedup'd rebind (e.g. `Renderer2D.bindForPass`) actually restores
    /// the 2D pipeline instead of skipping and leaving this one bound. Binding raw
    /// without going through here is the class of bug that produced the
    /// "draw_points_pl vs ortho_ring at group 0" validation error; the
    /// `raw-pass-state-bind` lint forbids it. Prefer typed `setPipeline` where a
    /// `RenderPipeline(Vs,Fs)` exists (it also wires the SW dispatch vtable).
    pub fn setPipelineHandle(ps: *PassState, handle: wgpu.RenderPipelineHandle) void {
        if (ps.current_pipeline) |cur| {
            if (cur == handle) {
                return; // already bound — skip
            }
        }
        @import("wgpu.zig").render_pass.setPipeline(ps.pass, handle);
        ps.current_pipeline = handle;
        ps.sw_dispatch = null; // a raw wgpu pipeline has no SW dispatch path
    }

    pub fn setBindGroup(
        ps: *PassState,
        group_index: u32,
        bind_group: wgpu.BindGroupHandle,
    ) void {
        if (group_index < ps.current_bind_groups.len) {
            if (ps.current_bind_groups[group_index]) |cur| {
                if (cur == bind_group) {
                    return; // already bound — skip
                }
            }
        }
        @import("wgpu.zig").render_pass.setBindGroup(ps.pass, group_index, bind_group);
        if (group_index < ps.current_bind_groups.len) {
            ps.current_bind_groups[group_index] = bind_group;
        }
    }
};

// Comptime sanity check — WgpuBackend must implement the trait
comptime {
    assertIsGpuBackend(WgpuBackend);
}

// ============================================================================
// SECTION 4 — SwBackend skeleton (placeholder)
// ============================================================================
//
// The SW backend is fully wired in Phase E of the migration.  For now
// it's a skeleton with method stubs whose signatures match WgpuBackend
// so `assertIsGpuBackend(SwBackend)` passes at compile time.  When
// Phase E lands, each method dispatches into `raster.X` /
// `raster_shader.dispatchFragmentShader`.

pub const SwBackend = struct {
    pub fn beginFrame(f: *GpuFrame) FrameContext {
        _ = f;
        return .{ .encoder = .invalid, .surface_view = .invalid };
    }
    pub fn endFrame(f: *GpuFrame) void {
        _ = f;
    }

    pub fn beginRenderPass(
        encoder: wgpu.CommandEncoderHandle,
        desc: BeginRenderPassDesc,
    ) PassState {
        _ = encoder;
        _ = desc;
        return .{ .pass = .invalid };
    }
    pub fn endRenderPass(ps: *PassState) void {
        _ = ps;
    }
    pub fn beginComputePass(
        encoder: wgpu.CommandEncoderHandle,
    ) wgpu.ComputePassEncoderHandle {
        _ = encoder;
        return .invalid;
    }
    pub fn endComputePass(pass: wgpu.ComputePassEncoderHandle) void {
        _ = pass;
    }

    pub fn drawQuadBatched(ps: *PassState, desc: QuadDesc) void {
        _ = ps;
        _ = desc;
    }
    pub fn drawTriangleBatched(ps: *PassState, desc: TriangleDesc) void {
        _ = ps;
        _ = desc;
    }
    pub fn flushBatch(ps: *PassState) void {
        _ = ps;
    }

    pub fn setPipeline(ps: *PassState, pipeline: anytype) void {
        const T = @TypeOf(pipeline);
        if (!@hasDecl(T, "Vs") or !@hasDecl(T, "Fs")) {
            @compileError("setPipeline expects RenderPipeline(VsT, FsT); " ++
                "got `" ++ @typeName(T) ++ "`.");
        }
        ps.current_pipeline = pipeline.gpu_handle;
        ps.sw_dispatch = T.sw_dispatch;
    }
    pub fn setBindGroup(
        ps: *PassState,
        g: u32,
        bg: wgpu.BindGroupHandle,
    ) void {
        _ = ps;
        _ = g;
        _ = bg;
    }
};

comptime {
    assertIsGpuBackend(SwBackend);
}

test "TriangleDesc default colors are all white" {
    const t: type = std.testing;
    const desc: TriangleDesc = .{
        .p0 = .{ 0, 0 },
        .p1 = .{ 1, 0 },
        .p2 = .{ 0, 1 },
    };
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, desc.colors[0]);
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, desc.colors[1]);
    try t.expectEqual([4]u8{ 255, 255, 255, 255 }, desc.colors[2]);
}

test "uniformColor helper produces 3-vertex array of same color" {
    const t: type = std.testing;
    const c: [3][4]u8 = uniformColor(.{ 255, 0, 0, 255 });
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, c[0]);
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, c[1]);
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, c[2]);
}

test "TriangleDesc carries per-vertex colors when supplied" {
    const t: type = std.testing;
    const desc: TriangleDesc = .{
        .p0 = .{ 0, 0 },
        .p1 = .{ 1, 0 },
        .p2 = .{ 0, 1 },
        .colors = .{
            .{ 255, 0, 0, 255 },
            .{ 0, 255, 0, 255 },
            .{ 0, 0, 255, 255 },
        },
    };
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, desc.colors[0]);
    try t.expectEqual([4]u8{ 0, 255, 0, 255 }, desc.colors[1]);
    try t.expectEqual([4]u8{ 0, 0, 255, 255 }, desc.colors[2]);
}
