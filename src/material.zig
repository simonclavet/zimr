//! lint:alias material
//! material.zig - the public custom-pipeline API ("complete WebGPU control").
//!
//! This is the keystone of `src/notes/webgpu_control.md`. It collapses the ~90
//! lines of pipeline plumbing that `cube_demo` hand-rolls - create shader_runtime
//! module -> pipeline layout -> `StateCombo` -> encode descriptor -> create
//! pipeline, then `setPipeline` -> `setVertexBuffer` -> draw - into one `Pipeline`
//! an app builds with a designated struct literal and draws with one call,
//! inside the normal frame pass.
//!
//! Raw WGSL is the escape hatch (the zimr default is a Zig shader_runtime; both reach
//! the same descriptor). A SINGLE WGSL module serves both the vertex and the
//! fragment stage, matching raygpu's `LoadPipeline(source)` shape: the module
//! declares `@vertex fn vs_main` and `@fragment fn fs_main`.
//!
//! Built on the layers zimr already had but never surfaced to apps: `wgpu.zig`
//! (handles + render-pass ops), `gpu.zig` (descriptor encoder + `StateCombo`),
//! `gpu_iface.WgpuBackend` (pass binding), and the typed `RenderPipeline`
//! wrapper from `shader_runtime.zig`.
//!
//! Composition: a `Pipeline` is depthLESS by default, so it draws into the
//! engine's 2D frame pass and composites with `drawCircle`/`drawText` in the
//! same `beginDrawing` frame. For a depth-tested 3D pass, set `.depth` here AND
//! `f.gpu.depth_format` on the frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wgpu = @import("wgpu.zig");
const gpu = @import("gpu.zig");
const gpu_iface = @import("gpu_iface.zig");
const shader_runtime = @import("shader_runtime_wgpu.zig");
const shader_introspect = @import("shader_introspect.zig");

const render_pass = wgpu.render_pass;
const PassState = gpu_iface.PassState;
const Backend = gpu_iface.WgpuBackend;

// ---------------------------------------------------------------------------
// Convenience re-exports - an app needs only `z.Pipeline` + these enums/types,
// not direct `z.gpu`/`z.wgpu` reaching for the common cases.
// ---------------------------------------------------------------------------
pub const VertexFormat = wgpu.VertexFormat;
pub const Topology = wgpu.PrimitiveTopology;
pub const Blend = wgpu.BlendMode;
pub const Cull = wgpu.CullMode;
pub const Depth = wgpu.DepthMode;
pub const VertexAttribute = gpu.VertexAttribute;
pub const VertexBufferLayout = gpu.VertexBufferLayout;
/// One WGSL pipeline-overridable constant (`override name = value`).
pub const Constant = gpu.PipelineConstant;
/// Which shader_runtime stages a binding is visible to, e.g. `.{ .vertex = true }`.
pub const ShaderStage = wgpu.ShaderStage;
/// One bind-group-layout entry (uniform/storage/sampler/texture/storage texture).
pub const LayoutEntry = shader_introspect.BindGroupLayoutEntry;
/// Reflect the resource bindings out of WGSL source - the "shader_runtime inspection"
/// surface. Returns owned `WgslBinding`s (free with `freeWgslBindings`).
pub const WgslBinding = shader_introspect.WgslBinding;
pub const reflectWgslBindings = shader_introspect.reflectWgslBindings;
pub const freeWgslBindings = shader_introspect.freeWgslBindings;
/// One bind-group entry (the concrete buffer/sampler/texture-view to bind).
pub const BindEntry = gpu.BindGroupEntry;

/// Everything needed to build a custom render pipeline, as one designated
/// literal. `wgsl` is a single module declaring both entry points. Provide
/// `bind_group_layouts` when the shader_runtime has bindings (see the uniforms
/// example); leave empty for a self-contained shader_runtime. State is data, not
/// setters.
pub const PipelineOptions = struct {
    wgsl: []const u8,
    vs_entry: []const u8 = "vs_main",
    fs_entry: []const u8 = "fs_main",
    /// One entry per bound vertex buffer (raygpu's VAO). Empty = no vertex
    /// input (a shader_runtime that synthesises positions from `@builtin(vertex_index)`).
    layouts: []const VertexBufferLayout = &.{},
    bind_group_layouts: []const wgpu.BindGroupLayoutHandle = &.{},
    topology: Topology = .triangle_list,
    blend: Blend = .alpha,
    depth: Depth = .none,
    cull: Cull = .none,
    /// MSAA sample count; must match the render target's sample count.
    samples: u4 = 1,
    /// WGSL pipeline-overridable constants (raygpu `override`) set at creation.
    constants: []const gpu.PipelineConstant = &.{},
    label: []const u8 = "pipeline",
};

/// A built render pipeline plus the module/layout backing it. Hold one in app
/// `State`; `bind` it then `drawArrays`/`drawIndexed` inside the frame.
pub const Pipeline = struct {
    handle: wgpu.RenderPipelineHandle,
    layout: wgpu.PipelineLayoutHandle,
    module: wgpu.ShaderModuleHandle,

    /// Build the pipeline from the live frame. Reads the surface colour format
    /// (and the depth format, if the app opted into one) off `f.gpu` so the
    /// pipeline is compatible with the pass it will draw into. `f` is `anytype`
    /// to keep this module a leaf (no dependency on the app runner); it must
    /// expose `f.gpu.device`, `f.gpu.backbuffer_format`, and `f.gpu.depth_format`.
    pub fn init(gpa: Allocator, f: anytype, opts: PipelineOptions) !Pipeline {
        const device: wgpu.DeviceHandle = f.gpu.device;
        const color_fmt: wgpu.TextureFormat = f.gpu.backbuffer_format;
        const depth_fmt: wgpu.TextureFormat = f.gpu.depth_format orelse .undefined_;

        // One module, both stages - raygpu's LoadPipeline shape.
        const module: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, opts.wgsl, opts.label);

        const pl: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, opts.bind_group_layouts, opts.label);

        const state: gpu.StateCombo = gpu.StateCombo.fromParts(
            opts.topology,
            opts.blend,
            opts.depth,
            opts.cull,
            color_fmt,
            depth_fmt,
            opts.samples,
        );
        const desc: gpu.RenderPipelineDescriptor = .{
            .vertex_buffer_layouts = opts.layouts,
            .vs_entry_point = opts.vs_entry,
            .fs_entry_point = opts.fs_entry,
            .state = state,
            .constants = opts.constants,
        };
        const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, desc);
        defer gpa.free(blob);

        const handle: wgpu.RenderPipelineHandle = wgpu.createRenderPipeline(
            device,
            pl,
            module,
            module,
            blob,
            opts.label,
        );
        return .{ .handle = handle, .layout = pl, .module = module };
    }

    /// Free the render pipeline, its pipeline layout, and its shader_runtime module.
    /// The app owns the `Pipeline` and calls this from its own `deinit` -
    /// managed memory means every GPU handle has a named owner that releases
    /// it. (Unlike `loadShaderVF`, this pipeline is built directly, not shared
    /// through the pipeline cache, so destroying it here is correct.)
    pub fn deinit(self: *Pipeline) void {
        if (self.handle != .invalid) {
            wgpu.destroyRenderPipeline(self.handle);
        }
        if (self.layout != .invalid) {
            wgpu.destroyPipelineLayout(self.layout);
        }
        if (self.module != .invalid) {
            wgpu.destroyShaderModule(self.module);
        }
        self.handle = .invalid;
        self.layout = .invalid;
        self.module = .invalid;
    }

    /// Bind this pipeline on the pass. Call before binding groups / drawing.
    pub fn bind(self: Pipeline, ps: *PassState) void {
        const wrapper: shader_runtime.RenderPipeline(void, void) = .{ .gpu_handle = self.handle };
        Backend.setPipeline(ps, wrapper);
    }

    /// Bind a resource group for the next draw (raygpu's SetShader* bindings,
    /// but explicit: the app owns the bind group). `group` is the WGSL
    /// `@group(N)` index.
    pub fn setBindGroup(
        self: Pipeline,
        ps: *PassState,
        group: u32,
        bind_group: wgpu.BindGroupHandle,
    ) void {
        _ = self;
        Backend.setBindGroup(ps, group, bind_group);
    }

    /// Bind a vertex buffer into `slot` for the next draw (raygpu's
    /// BindShaderVertexArray, one buffer at a time so multi-buffer VAOs are
    /// just repeated calls).
    pub fn setVertex(
        self: Pipeline,
        ps: *PassState,
        slot: u32,
        buffer: wgpu.BufferHandle,
        size: u64,
    ) void {
        _ = self;
        render_pass.setVertexBuffer(ps.pass, .{
            .slot = slot,
            .buffer = buffer,
            .offset = 0,
            .size = size,
        });
    }

    /// Non-indexed draw (raygpu DrawArrays / DrawArraysInstanced).
    pub fn drawArrays(
        self: Pipeline,
        ps: *PassState,
        vertex_count: u32,
        instance_count: u32,
    ) void {
        _ = self;
        render_pass.draw(ps.pass, .{
            .vertex_count = vertex_count,
            .instance_count = instance_count,
        });
    }

    /// Indexed draw (raygpu DrawArraysIndexed / DrawArraysIndexedInstanced).
    /// `index_size` is the byte length of the index buffer; indices are u32.
    pub fn drawIndexed(
        self: Pipeline,
        ps: *PassState,
        index_buffer: wgpu.BufferHandle,
        index_count: u32,
        index_size: u64,
        instance_count: u32,
    ) void {
        _ = self;
        render_pass.setIndexBuffer(ps.pass, .{
            .buffer = index_buffer,
            .format = .uint32,
            .offset = 0,
            .size = index_size,
        });
        render_pass.drawIndexed(ps.pass, .{
            .index_count = index_count,
            .instance_count = instance_count,
        });
    }
};

// ---------------------------------------------------------------------------
// Bind-group helpers - wrap the encode + create boilerplate for the common
// "build a layout, build a group" path so an app states only the entries. The
// raw `z.gpu.encode*` + `z.wgpu.create*` calls remain available for full
// control (e.g. dynamic offsets, multi-binding groups built incrementally).
// ---------------------------------------------------------------------------

/// Build a bind-group LAYOUT from its entries. Pass the returned handle to
/// `PipelineOptions.bind_group_layouts`.
pub fn bindGroupLayout(
    gpa: Allocator,
    f: anytype,
    entries: []const LayoutEntry,
    label: []const u8,
) !wgpu.BindGroupLayoutHandle {
    const blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, entries);
    defer gpa.free(blob);
    return wgpu.createBindGroupLayout(f.gpu.device, blob, label);
}

/// Build a bind GROUP (the concrete resources) for a given layout. Bind it at
/// draw time with `pipeline.setBindGroup(ps, group_index, bg)`.
pub fn bindGroup(
    gpa: Allocator,
    f: anytype,
    layout: wgpu.BindGroupLayoutHandle,
    entries: []const BindEntry,
    label: []const u8,
) !wgpu.BindGroupHandle {
    const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, entries);
    defer gpa.free(blob);
    return wgpu.createBindGroup(f.gpu.device, layout, blob, label);
}

/// Create a uniform buffer (UNIFORM | COPY_DST) sized to `bytes` and upload the
/// initial contents. Update later with `z.wgpu.queueWriteBuffer`.
pub fn uniformBuffer(
    f: anytype,
    bytes: []const u8,
    label: []const u8,
) wgpu.BufferHandle {
    const buf: wgpu.BufferHandle = wgpu.createBuffer(f.gpu.device, .{
        .size = bytes.len,
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = label,
    });
    wgpu.queueWriteBuffer(f.gpu.queue, buf, 0, bytes);
    return buf;
}

/// A write-only storage texture (rgba8unorm) usable as a compute target and
/// then as a sampled texture in a render pass. Bind its `view` as a
/// `storage_texture` (write_only) entry for compute, and as a `texture` entry
/// for sampling.
pub const StorageTexture = struct {
    texture: wgpu.TextureHandle,
    view: wgpu.TextureViewHandle,
    width: u32,
    height: u32,

    /// Free the texture + view this owns. The app calls this from its `deinit`
    /// (managed memory: every GPU handle has a named owner that releases it).
    pub fn deinit(self: *StorageTexture) void {
        if (self.view != .invalid) {
            wgpu.destroyTextureView(self.view);
        }
        if (self.texture != .invalid) {
            wgpu.destroyTexture(self.texture);
        }
        self.view = .invalid;
        self.texture = .invalid;
    }
};

/// Create a `StorageTexture` (usage STORAGE_BINDING | TEXTURE_BINDING). The
/// rgba8unorm format is the core WebGPU write-only storage format and is also
/// filterable for sampling, so one texture serves both the compute write and
/// the render read.
pub fn storageTexture(
    f: anytype,
    width: u32,
    height: u32,
    label: []const u8,
) StorageTexture {
    const tex: wgpu.TextureHandle = wgpu.createTexture(f.gpu.device, .{
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .storage_binding = true, .texture_binding = true },
        .label = label,
    });
    return .{
        .texture = tex,
        .view = wgpu.createTextureView(tex),
        .width = width,
        .height = height,
    };
}

/// Options for `fillStorageView`. Only `wgsl` + `groups` are required; the rest
/// default to the common case (rgba8unorm, a plain 2D view).
pub const StorageFill = struct {
    wgsl: []const u8,
    groups: wgpu.compute_pass.Dispatch,
    format: wgpu.TextureFormat = .rgba8_unorm,
    view_dimension: LayoutEntry.ViewDimension = .d2,
    label: []const u8 = "storage_fill",
};

/// One-shot compute fill of a storage-texture `view`: build a compute pipeline
/// from `opts.wgsl` with a single write-only storage-texture binding at
/// `@group(0) @binding(0)` bound to `view`, dispatch `opts.groups`, then release
/// EVERYTHING it created (pipeline, bind group, layout). Self-contained: no
/// handle escapes this call, so there is nothing for the caller to track or free
/// afterwards - only the texture behind `view` persists, and the caller already
/// owns that. This is the leak-safe way to paint a storage texture (or one mip
/// level, or an array layer set) exactly once.
pub fn fillStorageView(
    gpa: Allocator,
    f: anytype,
    view: wgpu.TextureViewHandle,
    opts: StorageFill,
) !void {
    const bgl: wgpu.BindGroupLayoutHandle = try bindGroupLayout(gpa, f, &.{
        .{
            .binding = 0,
            .visibility = .{ .compute = true },
            .resource = .{ .storage_texture = .{
                .access = .write_only,
                .format = opts.format,
                .view_dimension = opts.view_dimension,
            } },
        },
    }, opts.label);
    const bg: wgpu.BindGroupHandle = try bindGroup(gpa, f, bgl, &.{
        .{ .binding = 0, .resource = .{ .texture_view = view } },
    }, opts.label);
    var pipe: ComputePipeline = ComputePipeline.init(gpa, f, .{
        .wgsl = opts.wgsl,
        .bind_group_layouts = &.{bgl},
        .label = opts.label,
    });
    pipe.dispatch(f, bg, opts.groups);
    // The fill is submitted; the pipeline + bind group / layout were all only
    // needed to build and dispatch it. Release them - nothing escapes.
    pipe.deinit();
    wgpu.destroyBindGroup(bg);
    wgpu.destroyBindGroupLayout(bgl);
}

/// Create a 2D `StorageTexture` and paint it once via `wgsl`, dispatched over an
/// 8x8 workgroup grid covering `width`x`height`. Returns the OWNED texture -
/// free it with `.deinit()`. The compute scaffolding used to fill it is created
/// and released internally (see `fillStorageView`), so this returns the single
/// thing the caller must track.
pub fn storageTextureFilled(
    gpa: Allocator,
    f: anytype,
    width: u32,
    height: u32,
    wgsl: []const u8,
    label: []const u8,
) !StorageTexture {
    const st: StorageTexture = storageTexture(f, width, height, label);
    const gx: u32 = (width + 7) / 8;
    const gy: u32 = (height + 7) / 8;
    try fillStorageView(gpa, f, st.view, .{
        .wgsl = wgsl,
        .groups = .{ .x = gx, .y = gy },
        .label = label,
    });
    return st;
}

/// A compute pipeline - the compute-side companion to `Pipeline`. One WGSL
/// module with a `@compute` entry, plus the bind group layouts it samples /
/// writes. `dispatch` runs it ONCE on its own command encoder, which is the
/// right shape for filling a texture or buffer outside the frame's render pass
/// (compute and render passes cannot be open on the same encoder at once).
pub const ComputePipeline = struct {
    handle: wgpu.ComputePipelineHandle,
    layout: wgpu.PipelineLayoutHandle,

    pub const Options = struct {
        wgsl: []const u8,
        entry: []const u8 = "cs_main",
        bind_group_layouts: []const wgpu.BindGroupLayoutHandle = &.{},
        label: []const u8 = "compute_pipeline",
    };

    pub fn init(gpa: Allocator, f: anytype, opts: Options) ComputePipeline {
        _ = gpa;
        const device: wgpu.DeviceHandle = f.gpu.device;
        const module: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, opts.wgsl, opts.label);
        const pl: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, opts.bind_group_layouts, opts.label);
        const handle: wgpu.ComputePipelineHandle =
            wgpu.createComputePipeline(device, pl, module, opts.entry, opts.label);
        // Build-only: the pipeline retains the module internally, so release the
        // source handle now (it is not stored on the struct).
        wgpu.destroyShaderModule(module);
        return .{ .handle = handle, .layout = pl };
    }

    /// Free the compute pipeline + its layout. The app owns the ComputePipeline
    /// and calls this from its `deinit` (managed memory). A compute pipeline
    /// used only to fill a texture once can be deinit'd right after the fill
    /// dispatch is submitted.
    pub fn deinit(self: *ComputePipeline) void {
        if (self.handle != .invalid) {
            wgpu.destroyComputePipeline(self.handle);
        }
        if (self.layout != .invalid) {
            wgpu.destroyPipelineLayout(self.layout);
        }
        self.handle = .invalid;
        self.layout = .invalid;
    }

    /// Run the pipeline once with `bind_group` at index 0 over `groups`
    /// workgroups, on a dedicated encoder submitted immediately.
    pub fn dispatch(
        self: ComputePipeline,
        f: anytype,
        bind_group: wgpu.BindGroupHandle,
        groups: wgpu.compute_pass.Dispatch,
    ) void {
        const device: wgpu.DeviceHandle = f.gpu.device;
        const enc: wgpu.CommandEncoderHandle = wgpu.createCommandEncoder(device);
        const cp: wgpu.ComputePassEncoderHandle = wgpu.compute_pass.begin(enc);
        wgpu.compute_pass.setPipeline(cp, self.handle);
        wgpu.compute_pass.setBindGroup(cp, 0, bind_group);
        wgpu.compute_pass.dispatchWorkgroups(cp, groups);
        wgpu.compute_pass.end(cp);
        const cmd: wgpu.CommandBufferHandle = wgpu.finishCommandEncoder(enc);
        wgpu.queueSubmit(f.gpu.queue, cmd);
    }
};
