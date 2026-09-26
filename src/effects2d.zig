//! lint:alias effects2d
//! src/effects2d.zig - the 2D fullscreen fragment-effect runner.
//!
//! raylib does post-processing like this:
//!
//!     BeginTextureMode(target);  DrawScene();  EndTextureMode();
//!     BeginShaderMode(shader);
//!         DrawTextureRec(target.texture, ..., WHITE);
//!     EndShaderMode();
//!
//! This module is that, for the wgpu backend - and it exists because the shape of
//! it was previously HAND-ROLLED in the example: every effect gallery had to build
//! its own bind-group layouts, uniform buffers, pipeline layout, fullscreen quad,
//! and then drive `setPipeline` / `setBindGroup` x3 / `setVertexBuffer` / `draw`
//! by hand. That is engine work living in userland; the fifth copy of it would
//! have been the fifth chance to get a binding index wrong.
//!
//! The binding contract every effect fragment shader must satisfy (it is what
//! `effect_common_io.zig` declares, so any shader in that family already does):
//!
//!     @group(0)             - empty (reserved for the engine's per-frame slot)
//!     @group(1) @binding(0) - source texture      (the thing being post-processed)
//!     @group(1) @binding(1) - its sampler
//!     @group(2) @binding(0) - the effect's own uniform block
//!
//! The vertex stage is supplied by the caller as WGSL (in practice the engine's
//! fullscreen-quad VS). The engine cannot `@embedFile` it here: the generated
//! `.wgsl` is a BUILD ARTIFACT, handed to modules by `wireEngineWgsl`, so taking
//! it as a parameter is what keeps this module free of build-graph knowledge.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gpu = @import("gpu.zig");
const gpu_iface = @import("gpu_iface.zig");
const shader_introspect = @import("shader_introspect.zig");
const shader_runtime = @import("shader_runtime_wgpu.zig");
const wgpu = @import("wgpu.zig");
const wgpu_app = @import("wgpu_app.zig");
const WgpuGl = @import("WgpuGl.zig");

const Backend = gpu_iface.WgpuBackend;

/// The fullscreen quad: two triangles, NDC positions ONLY.
///
/// No UVs. The shared vertex stage (`deferred_shading_vs`) derives the UV from
/// the clip position itself, so shipping a UV attribute here would not just be
/// redundant - it would not match the VS's declared inputs, and the pipeline
/// would fail validation.
const quad_verts = [_][2]f32{
    .{ -1.0, -1.0 }, .{ 1.0, -1.0 }, .{ 1.0, 1.0 },
    .{ -1.0, -1.0 }, .{ 1.0, 1.0 },  .{ -1.0, 1.0 },
};

/// One loaded effect: a pipeline plus the uniform block it reads.
pub const Effect = struct {
    pipeline: wgpu.RenderPipelineHandle = .invalid,
    ubo: wgpu.BufferHandle = .invalid,
    bind_group: wgpu.BindGroupHandle = .invalid,
    // Owned so `deinit` is HONEST. Creating a pipeline also creates a bind-group
    // layout, a pipeline layout and a shader module; a deinit that frees only the
    // buffer and the bind group leaks the other three, which is exactly what the
    // smoke leak-checker caught the first time this ran.
    ubo_layout: wgpu.BindGroupLayoutHandle = .invalid,
    pipeline_layout: wgpu.PipelineLayoutHandle = .invalid,
    fs_mod: wgpu.ShaderModuleHandle = .invalid,

    /// raylib's `SetShaderValue`, but typed and whole-struct: push the effect's
    /// entire uniform block. Partial updates are a bug farm - the block is small
    /// and std140-padded, so there is nothing to gain by writing it piecemeal.
    pub fn setValues(self: Effect, queue: wgpu.QueueHandle, values: anytype) void {
        wgpu.queueWriteBuffer(queue, self.ubo, 0, std.mem.asBytes(values));
    }

    pub fn deinit(self: Effect) void {
        if (self.bind_group != .invalid) {
            wgpu.destroyBindGroup(self.bind_group);
        }
        if (self.ubo != .invalid) {
            wgpu.destroyBuffer(self.ubo);
        }
        if (self.pipeline != .invalid) {
            wgpu.destroyRenderPipeline(self.pipeline);
        }
        if (self.pipeline_layout != .invalid) {
            wgpu.destroyPipelineLayout(self.pipeline_layout);
        }
        if (self.ubo_layout != .invalid) {
            wgpu.destroyBindGroupLayout(self.ubo_layout);
        }
        if (self.fs_mod != .invalid) {
            wgpu.destroyShaderModule(self.fs_mod);
        }
    }
};

/// How many source textures the effects read. One is the common case (a post
/// effect over the scene); a mask/blend shader wants two or three.
pub const HostOptions = struct {
    /// Source textures bound into @group(1). Each takes TWO bindings -
    /// texture at 2i, its sampler at 2i+1 - which is exactly the layout the
    /// shader DSL generates for N `Sampler2D` fields (verified against the PBR
    /// shader's WGSL, which binds texture0/1/2 at 0,2,4 and their samplers at
    /// 1,3,5).
    textures: u32 = 1,
};

/// Everything the effect family SHARES: the quad, the vertex stage, the layouts,
/// and the currently-bound source textures. Build one; load many effects from it.
pub const Host = struct {
    empty_bgl: wgpu.BindGroupLayoutHandle,
    source_bgl: wgpu.BindGroupLayoutHandle,
    vs_mod: wgpu.ShaderModuleHandle,
    quad_layout: gpu.VertexBufferLayout,
    vbo: wgpu.BufferHandle,
    empty_bg: wgpu.BindGroupHandle,
    /// How many textures @group(1) expects - the bind group must match exactly.
    tex_count: u32 = 1,
    /// The depth format of the passes these effects will be bound into - read
    /// from the app, NOT assumed. A pipeline built with a depth attachment cannot
    /// be bound into a depth-less pass (WebGPU rejects the setPipeline), and an
    /// effect renders into a render texture whose depth comes from the SAME app
    /// config, so the app is the single source of truth. Hardcoding this was a
    /// real bug: pipelines carried Depth24Plus into `depth_format = null` apps.
    depth_format: ?wgpu.TextureFormat = null,
    /// Rebuilt whenever the source textures change (a resize, a new target).
    source_bg: wgpu.BindGroupHandle = .invalid,

    /// Takes the `gl` rather than a bare device ON PURPOSE: the device, the queue
    /// and the DEPTH FORMAT all have to come from the same app, and asking the
    /// caller to pass them separately is asking them to get it wrong.
    pub fn init(
        gpa: Allocator,
        gl: *WgpuGl,
        vs_wgsl: []const u8,
        opts: HostOptions,
    ) !Host {
        const app: *wgpu_app.App = wgpu_app.appOf(gl);
        const device: wgpu.DeviceHandle = app.gpu_frame.device;
        const depth_format: ?wgpu.TextureFormat = app.gpu_frame.depth_format;
        const empty_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &.{});
        defer gpa.free(empty_blob);
        const empty_bgl: wgpu.BindGroupLayoutHandle =
            wgpu.createBindGroupLayout(device, empty_blob, "fx_g0");

        // Two bindings per texture: the texture at 2i, its sampler at 2i+1.
        const tex_count: u32 = @max(opts.textures, 1);
        const src_entries: []shader_introspect.BindGroupLayoutEntry =
            try gpa.alloc(shader_introspect.BindGroupLayoutEntry, tex_count * 2);
        defer gpa.free(src_entries);
        for (0..tex_count) |i| {
            const b: u32 = @intCast(i * 2);
            src_entries[i * 2] = .{
                .binding = b,
                .visibility = .{ .fragment = true },
                .resource = .{ .texture = .{} },
            };
            src_entries[i * 2 + 1] = .{
                .binding = b + 1,
                .visibility = .{ .fragment = true },
                .resource = .{ .sampler = .{} },
            };
        }
        const src_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, src_entries);
        defer gpa.free(src_blob);
        const source_bgl: wgpu.BindGroupLayoutHandle =
            wgpu.createBindGroupLayout(device, src_blob, "fx_g1");

        const empty_bg_blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &.{});
        defer gpa.free(empty_bg_blob);

        const vbo: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @sizeOf(@TypeOf(quad_verts)),
            .usage = .{ .vertex = true, .copy_dst = true },
        });
        wgpu.queueWriteBuffer(
            wgpu.getQueue(device),
            vbo,
            0,
            std.mem.sliceAsBytes(quad_verts[0..]),
        );

        return .{
            .empty_bgl = empty_bgl,
            .source_bgl = source_bgl,
            .vs_mod = wgpu.createShaderModuleWgsl(device, vs_wgsl, "fx_vs"),
            .quad_layout = .{
                .array_stride = @sizeOf([2]f32),
                .attributes = &.{
                    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                },
            },
            .vbo = vbo,
            .tex_count = tex_count,
            .depth_format = depth_format,
            .empty_bg = wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "fx_g0_bg"),
        };
    }

    /// Compile one effect: its own uniform layout, pipeline layout, pipeline, ubo.
    /// `ubo_size` is `@sizeOf(TheShader.Ubo)` - pass it and the layout's `min_size`
    /// will reject a shader whose block is bigger than the buffer, at creation
    /// rather than as corrupt uniforms later.
    pub fn load(
        self: Host,
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        fs_wgsl: []const u8,
        ubo_size: u64,
        label: []const u8,
    ) !Effect {
        // `device` stays a parameter for symmetry with the rest of the wgpu API,
        // but the DEPTH state comes from the Host - see `depth_format` above.
        const u_entries = [_]shader_introspect.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .resource = .{ .uniform_buffer = .{ .min_size = ubo_size } },
            },
        };
        const u_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &u_entries);
        defer gpa.free(u_blob);
        const u_bgl: wgpu.BindGroupLayoutHandle =
            wgpu.createBindGroupLayout(device, u_blob, label);

        const pl: wgpu.PipelineLayoutHandle = wgpu.createPipelineLayout(
            device,
            &.{ self.empty_bgl, self.source_bgl, u_bgl },
            label,
        );
        const fs_mod: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, fs_wgsl, label);

        // Mirror renderer_2d exactly: when the app has no depth, the pipeline must
        // declare NO depth state (`.none` + `.undefined_`), or it is incompatible
        // with the depth-less pass it gets bound into.
        const combo: gpu.StateCombo = gpu.StateCombo.fromParts(
            .triangle_list,
            .alpha, // effects carry the source's alpha; blend onto the clear
            if (self.depth_format != null) .always else .none,
            .none,
            .rgba8_unorm,
            self.depth_format orelse .undefined_,
            1,
        );
        const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, .{
            .vertex_buffer_layouts = &.{self.quad_layout},
            .vs_entry_point = "entry",
            .fs_entry_point = "entry",
            .state = combo,
        });
        defer gpa.free(blob);

        const ubo: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = ubo_size,
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const bg_entries = [_]gpu.BindGroupEntry{
            .{ .binding = 0, .resource = .{ .buffer = .{ .handle = ubo, .size = ubo_size } } },
        };
        const bg_blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &bg_entries);
        defer gpa.free(bg_blob);

        return .{
            .pipeline = wgpu.createRenderPipeline(device, pl, self.vs_mod, fs_mod, blob, label),
            .ubo = ubo,
            .bind_group = wgpu.createBindGroup(device, u_bgl, bg_blob, label),
            .ubo_layout = u_bgl,
            .pipeline_layout = pl,
            .fs_mod = fs_mod,
        };
    }

    /// Point the effects at new source textures (call on resize / target swap).
    /// `views.len` MUST equal the `textures` the Host was built with - a bind group
    /// that doesn't match its layout is a WebGPU validation error, so it is caught
    /// here as a plain error instead.
    /// The old bind group is destroyed, so re-targeting cannot leak.
    pub fn setSources(
        self: *Host,
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        views: []const wgpu.TextureViewHandle,
        sampler: wgpu.SamplerHandle,
    ) !void {
        if (views.len != self.tex_count) {
            return error.SourceCountMismatch;
        }
        const entries: []gpu.BindGroupEntry = try gpa.alloc(gpu.BindGroupEntry, views.len * 2);
        defer gpa.free(entries);
        for (views, 0..) |v, i| {
            const b: u32 = @intCast(i * 2);
            entries[i * 2] = .{ .binding = b, .resource = .{ .texture_view = v } };
            entries[i * 2 + 1] = .{ .binding = b + 1, .resource = .{ .sampler = sampler } };
        }
        const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, entries);
        defer gpa.free(blob);
        if (self.source_bg != .invalid) {
            wgpu.destroyBindGroup(self.source_bg);
        }
        self.source_bg = wgpu.createBindGroup(device, self.source_bgl, blob, "fx_g1_bg");
    }

    /// The one-texture case, which is most post effects.
    pub fn setSource(
        self: *Host,
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        view: wgpu.TextureViewHandle,
        sampler: wgpu.SamplerHandle,
    ) !void {
        try self.setSources(gpa, device, &.{view}, sampler);
    }

    pub fn deinit(self: *Host) void {
        if (self.source_bg != .invalid) {
            wgpu.destroyBindGroup(self.source_bg);
            self.source_bg = .invalid;
        }
        if (self.empty_bg != .invalid) {
            wgpu.destroyBindGroup(self.empty_bg);
        }
        if (self.vbo != .invalid) {
            wgpu.destroyBuffer(self.vbo);
        }
        if (self.source_bgl != .invalid) {
            wgpu.destroyBindGroupLayout(self.source_bgl);
        }
        if (self.empty_bgl != .invalid) {
            wgpu.destroyBindGroupLayout(self.empty_bgl);
        }
        if (self.vs_mod != .invalid) {
            wgpu.destroyShaderModule(self.vs_mod);
        }
    }
};

/// raylib's `BeginShaderMode(shader)` - bind the effect's pipeline, the source
/// texture, and the effect's uniforms into the OPEN pass.
///
/// Silently no-ops when no source is bound: an effect with an unbound source would
/// otherwise be a WebGPU validation error, and a missing `setSource` is a caller
/// bug that should not take the whole frame down.
pub fn beginShaderMode(gl: *WgpuGl, host: *const Host, fx: Effect) void {
    if (host.source_bg == .invalid or fx.pipeline == .invalid) {
        return;
    }
    const pa: *gpu_iface.PassState = gl.pass;
    Backend.setPipeline(pa, shader_runtime.RenderPipeline(void, void){ .gpu_handle = fx.pipeline });
    Backend.setBindGroup(pa, 0, host.empty_bg);
    Backend.setBindGroup(pa, 1, host.source_bg);
    Backend.setBindGroup(pa, 2, fx.bind_group);
    wgpu.render_pass.setVertexBuffer(pa.pass, .{
        .slot = 0,
        .buffer = host.vbo,
        .offset = 0,
        .size = @sizeOf(@TypeOf(quad_verts)),
    });
}

/// raylib's `DrawTextureRec(target.texture, ...)` inside a shader mode - the
/// fullscreen blit the effect actually runs over.
pub fn drawFullscreen(gl: *WgpuGl) void {
    wgpu.render_pass.draw(gl.pass.pass, .{
        .vertex_count = quad_verts.len,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
}

/// raylib's `EndShaderMode()`. The 2D renderer re-binds its own pipeline on the
/// next shape it draws, so there is nothing to restore - but the call exists so
/// the begin/end pairing reads the way raylib's does, and so a future
/// state-restoring implementation has a place to live.
pub fn endShaderMode(gl: *WgpuGl) void {
    _ = gl;
}
