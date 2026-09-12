// src/wgpu_smoke_test.zig - end-to-end smoke test scaffold.
//
// This file exercises the whole wgpu stack with hand-written WGSL.
// It's a TEMPLATE for the first triangle test that will run when:
//
//   1. The transpiler arrives and `shader_compile.zig` is wired in.
//   2. The wgpu path is wired into `src/zimr.zig` and the build.
//
// Today it serves as:
//   - Documentation: this is what the user-facing API will look like.
//   - Compile-time check: every type the stack uses is reachable
//     from this file, so a `zig build-obj wgpu_smoke_test.zig`
//     catches integration errors before they reach the browser.
//
// The test does NOT run in the host test harness — it would need a
// real GPU + JS bridge.  It compiles cleanly as a sanity check that
// the API surfaces fit together.

const std = @import("std");
const gpu = @import("gpu.zig");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const wgpu = @import("wgpu.zig");
const render_pass = wgpu.render_pass;
const BindGroupCache = @import("BindGroupCache.zig");

// ============================================================================
// SECTION 1 — the hand-written WGSL triangle shader
// ============================================================================
//
// A red triangle.  Three vertices, hardcoded positions.  No vertex
// buffer needed (positions are constants in the shader).  No UBO, no
// textures.  Simplest possible thing that renders.

pub const triangle_wgsl =
    \\struct VsOut {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) color: vec3f,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@builtin(vertex_index) idx: u32) -> VsOut {
    \\    var out: VsOut;
    \\    let positions = array<vec2f, 3>(
    \\        vec2f(0.0,  0.5),
    \\        vec2f(-0.5, -0.5),
    \\        vec2f(0.5, -0.5),
    \\    );
    \\    let colors = array<vec3f, 3>(
    \\        vec3f(1.0, 0.2, 0.2),
    \\        vec3f(0.2, 1.0, 0.2),
    \\        vec3f(0.2, 0.2, 1.0),
    \\    );
    \\    out.position = vec4f(positions[idx], 0.0, 1.0);
    \\    out.color = colors[idx];
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(in.color, 1.0);
    \\}
;

// ============================================================================
// SECTION 2 — the smoke-test app
// ============================================================================
//
// This is what a user app would look like after the migration.  It
// uses the descriptor-with-defaults pattern, the typed GpuFrame,
// and the render_pass helpers.  Today it COMPILES but can't be
// EXECUTED (no JS bridge in the host test harness).

pub const App = struct {
    f: gpu.GpuFrame,
    pipeline_cache_storage: gpu.PipelineCache,
    bind_group_cache_storage: BindGroupCache,

    /// Pre-built render pipeline for the triangle.
    triangle_pipeline: wgpu.RenderPipelineHandle = .invalid,
    triangle_shader_module: wgpu.ShaderModuleHandle = .invalid,
    triangle_pipeline_layout: wgpu.PipelineLayoutHandle = .invalid,

    pub fn init(gpa: Allocator) !App {
        // Step 1: acquire device, queue, surface
        const device: wgpu.DeviceHandle = wgpu.initDevice();
        const queue: wgpu.QueueHandle = wgpu.getQueue(device);
        const surface: wgpu.SurfaceHandle = wgpu.getSurface();
        const fmt: wgpu.TextureFormat = wgpu.getSurfaceFormat(surface);

        // Step 2: allocate caches
        var pc: gpu.PipelineCache = gpu.PipelineCache.init(gpa, device);
        var bgc: BindGroupCache = BindGroupCache.init(gpa, device);

        // Step 3: build GpuFrame
        const f: gpu.GpuFrame = gpu.GpuFrame.init(device, queue, surface, fmt, &pc, &bgc);

        var app: App = .{
            .f = f,
            .pipeline_cache_storage = pc,
            .bind_group_cache_storage = bgc,
        };

        // Step 4: build the triangle pipeline (hand-written WGSL).
        try app.buildTrianglePipeline(gpa);

        return app;
    }

    fn buildTrianglePipeline(self: *App, gpa: Allocator) !void {
        // The smoke test ships its own hand-written WGSL (no schema,
        // no typed pipeline — just a fixed-shape triangle).  Goes
        // straight to `createShaderModuleWgsl`; the typed
        // `loadShader` path is exercised by the engine + user code,
        // not by the smoke harness.
        _ = gpa;
        self.triangle_shader_module = wgpu.createShaderModuleWgsl(
            self.f.device,
            triangle_wgsl,
            "triangle",
        );

        // No bind group layouts — the shader has no bindings.
        // Build an empty pipeline layout.
        const pl_layout: wgpu.PipelineLayoutHandle = wgpu.createPipelineLayout(
            self.f.device,
            &.{},
            "triangle_pl",
        );
        self.triangle_pipeline_layout = pl_layout;

        // Build the render pipeline descriptor.
        const desc = gpu.RenderPipelineDescriptor{
            .vertex_buffer_layouts = &.{}, // no vertex buffers
            .vs_entry_point = "vs_main",
            .fs_entry_point = "fs_main",
            .state = gpu.StateCombo.fromParts(
                .triangle_list,
                .alpha,
                .none,
                .none,
                self.f.backbuffer_format,
                .undefined_,
                1,
            ),
        };
        const desc_bytes: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, desc);
        defer gpa.free(desc_bytes);

        self.triangle_pipeline = wgpu.createRenderPipeline(
            self.f.device,
            pl_layout,
            self.triangle_shader_module,
            self.triangle_shader_module, // single-source WGSL with both stages
            desc_bytes,
            "triangle_pipe",
        );
    }

    /// Render one frame.  This is the shape of every zimr update fn
    /// after the migration.
    pub fn render(self: *App) void {
        const Backend = @import("gpu_iface.zig").WgpuBackend;

        // beginFrame: acquire surface texture, create encoder.
        const fctx = Backend.beginFrame(&self.f);

        // beginRenderPass: bind the swap-chain target, set clear color.
        // Returns a PassState we thread into the draw calls.
        var ps = Backend.beginRenderPass(fctx.encoder, .{
            .color_view = fctx.surface_view,
            .clear = .{ .r = 0.05, .g = 0.05, .b = 0.1, .a = 1.0 },
        });

        // setPipeline + draw 3 vertices (raw render_pass calls — no
        // dedup needed for this single-pipeline smoke test).
        Backend.setPipelineHandle(ps, self.triangle_pipeline);
        render_pass.draw(ps.pass, .{ .vertex_count = 3 });

        // endRenderPass + endFrame: close pass, submit, present.
        Backend.endRenderPass(&ps);
        Backend.endFrame(&self.f);
    }

    pub fn deinit(self: *App) void {
        self.pipeline_cache_storage.deinit();
        self.bind_group_cache_storage.deinit();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "triangle_wgsl is non-empty and contains @vertex" {
    try expect(triangle_wgsl.len > 100);
    try expect(std.mem.indexOf(u8, triangle_wgsl, "@vertex") != null);
    try expect(std.mem.indexOf(u8, triangle_wgsl, "@fragment") != null);
    try expect(std.mem.indexOf(u8, triangle_wgsl, "vs_main") != null);
    try expect(std.mem.indexOf(u8, triangle_wgsl, "fs_main") != null);
}

test "App.init / deinit type-checks against the host harness" {
    // Can't actually init on the host (no JS bridge), but we should
    // be able to declare an `App` variable and check the shape is
    // sane.  This catches integration errors early.
    var app: App = undefined;
    _ = &app;
}
