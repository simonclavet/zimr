//! lint:alias wgpu
// src/wgpu.zig - WebGPU JS bridge: typed handles + extern decls + thin wrappers.
// WebGPU architecture is documented centrally in src/zimr.zig
// (the module-level `//!` doc) - read that before changing wgpu code.
//
//
// This module is the bottom-most layer of the WebGPU stack.  It does
// three things:
//
//   1. Declares typed handle wrappers (BufferHandle, TextureHandle,
//      etc.) - each is a distinct `enum(u32)` so the type system
//      catches "passed a texture where a buffer was expected" at
//      compile time.  The 0 value is reserved as "null/invalid."
//
//   2. Declares the `extern "wgpu"` JS bridge functions.  These are
//      the low-level calls the TS side implements in `src/bridge.zig`.
//      Each `js_X` function takes only u32 / u64 / pointer args (the
//      wasm <-> JS boundary doesn't pass structs).
//
//   3. Wraps each `js_X` in a Zig-friendly `pub fn` that takes a
//      descriptor struct and returns a typed handle.  These are the
//      functions the rest of zimr's code uses.
//
// Host (non-wasm) builds get null-handle stubs so the host test
// binary can link.  Same pattern as `src/web.zig` uses for DOM/WebGL.
//
// Convention: every JS-bridge function name starts with `js_`.  Every
// Zig wrapper goes through the typed handle layer.  Direct `js_X`
// access from outside this file is discouraged.
//
// Status: SCAFFOLDING.  The extern decls are committed; the TS side
// `src/bridge.zig` is a stub.  Shader module creation from raw
// WGSL works today; shader module creation from Zig source is blocked
// on the SPIR-V -> WGSL transpiler.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const refAllDecls = std.testing.refAllDecls;
const sliceAsBytes = std.mem.sliceAsBytes;
const expect = std.testing.expect;
const zm = @import("zm");
const assertf = zm.assertf;
const assert = zm.assert;
const gpu_abi = @import("gpu_abi.zig");
const host = @import("host.zig");
/// The native GPU host. Imports are lazy: web and test builds only ever take its functions' types (the check below).
/// The native host, for a program that starts it itself: `vulkan_host.startHeadless()` before `initDevice` gives a
/// host without a window (the host's tests), and `messageCounts` / `isValidating` report the validation layer.
pub const vulkan_host = @import("wgpu_vulkan.zig");

// ============================================================================
// SECTION 1 - typed handles
// ============================================================================

/// Distinct `enum(u32)` per WebGPU object kind.  Passing a
/// `BufferHandle` where a `TextureHandle` is expected is a compile
/// error.  The underlying `u32` is the JS-side handle-table index;
/// 0 is reserved as "null/invalid."
pub const DeviceHandle = enum(u32) { invalid = 0, _ };
pub const QueueHandle = enum(u32) { invalid = 0, _ };
pub const SurfaceHandle = enum(u32) { invalid = 0, _ };
pub const BufferHandle = enum(u32) { invalid = 0, _ };
pub const TextureHandle = enum(u32) { invalid = 0, _ };
pub const TextureViewHandle = enum(u32) { invalid = 0, _ };
pub const SamplerHandle = enum(u32) { invalid = 0, _ };
pub const ShaderModuleHandle = enum(u32) { invalid = 0, _ };
pub const BindGroupLayoutHandle = enum(u32) { invalid = 0, _ };
pub const BindGroupHandle = enum(u32) { invalid = 0, _ };
pub const PipelineLayoutHandle = enum(u32) { invalid = 0, _ };
pub const RenderPipelineHandle = enum(u32) { invalid = 0, _ };
pub const ComputePipelineHandle = enum(u32) { invalid = 0, _ };
pub const CommandEncoderHandle = enum(u32) { invalid = 0, _ };
pub const RenderPassEncoderHandle = enum(u32) { invalid = 0, _ };
pub const ComputePassEncoderHandle = enum(u32) { invalid = 0, _ };
pub const CommandBufferHandle = enum(u32) { invalid = 0, _ };

/// Check if a handle is the invalid sentinel.
pub inline fn isValid(handle: anytype) bool {
    return @backingInt(handle) != 0;
}

// ============================================================================
// SECTION 2 - enums + packed flag types
// ============================================================================

// The enumerations and flag words are the ABI between the engine and its GPU hosts. They live in `gpu_abi.zig`, which
// the Vulkan host imports directly (importing this file would close an import cycle); engine code keeps naming them
// here.
pub const TextureFormat = gpu_abi.TextureFormat;
pub const BufferUsage = gpu_abi.BufferUsage;
pub const TextureUsage = gpu_abi.TextureUsage;
pub const ShaderStage = gpu_abi.ShaderStage;
/// What a bind-group layout entry binds, what a bind-group entry's handle names, and a texture binding's view - the
/// words of the layout and group blobs (`gpu_abi`).
pub const BindingKind = gpu_abi.BindingKind;
pub const BindingResource = gpu_abi.BindingResource;
pub const TextureViewDimension = gpu_abi.TextureViewDimension;
pub const LoadOp = gpu_abi.LoadOp;
pub const StoreOp = gpu_abi.StoreOp;
pub const PrimitiveTopology = gpu_abi.PrimitiveTopology;
pub const CullMode = gpu_abi.CullMode;
pub const BlendMode = gpu_abi.BlendMode;
pub const DepthMode = gpu_abi.DepthMode;
pub const VertexFormat = gpu_abi.VertexFormat;
pub const VertexStepMode = gpu_abi.VertexStepMode;
pub const IndexFormat = gpu_abi.IndexFormat;
pub const ColorF32 = gpu_abi.ColorF32;

// ============================================================================
// SECTION 3 - extern JS bridge declarations
// ============================================================================

// All `js_` functions cross the wasm <-> JS boundary.  They take
// only u32 / u64 / pointer arguments (no structs).  Return values
// are u32 (handles) or void.

// --- Device / Queue / Surface ---
extern "wgpu" fn js_init_device() u32;
extern "wgpu" fn js_device_get_queue(device: u32) u32;
extern "wgpu" fn js_get_surface() u32;
extern "wgpu" fn js_surface_get_current_texture(surface: u32) u32;
extern "wgpu" fn js_surface_present(surface: u32) void;
extern "wgpu" fn js_surface_get_format(surface: u32) u32;
extern "wgpu" fn js_surface_get_size(surface: u32) u32;
extern "wgpu" fn js_surface_get_css_size(surface: u32) u32;
extern "wgpu" fn js_now_ms() f64;
extern "wgpu" fn js_gpu_ms_last() f64;

// --- Buffer ---
extern "wgpu" fn js_device_create_buffer(
    device: u32,
    size: u64,
    usage: u32,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;
extern "wgpu" fn js_buffer_destroy(buffer: u32) void;
extern "wgpu" fn js_queue_write_buffer(
    queue: u32,
    buffer: u32,
    offset: u64,
    data_ptr: [*]const u8,
    data_len: usize,
) void;

// --- Texture ---
extern "wgpu" fn js_device_create_texture(
    device: u32,
    width: u32,
    height: u32,
    format: u32,
    usage: u32,
    label_ptr: [*]const u8,
    label_len: usize,
    sample_count: u32,
    mip_level_count: u32,
    array_layers: u32,
) u32;
extern "wgpu" fn js_texture_create_view(texture: u32) u32;
extern "wgpu" fn js_texture_create_view_mip(
    texture: u32,
    base_mip: u32,
    mip_count: u32,
) u32;
extern "wgpu" fn js_texture_create_view_array(texture: u32, layer_count: u32) u32;
extern "wgpu" fn js_texture_create_view_layer(texture: u32, layer: u32) u32;
extern "wgpu" fn js_texture_destroy(texture: u32) void;
extern "wgpu" fn js_bind_group_destroy(id: u32) void;
extern "wgpu" fn js_bind_group_layout_destroy(id: u32) void;
extern "wgpu" fn js_pipeline_layout_destroy(id: u32) void;
extern "wgpu" fn js_render_pipeline_destroy(id: u32) void;
extern "wgpu" fn js_compute_pipeline_destroy(id: u32) void;
extern "wgpu" fn js_sampler_destroy(id: u32) void;
extern "wgpu" fn js_shader_module_destroy(id: u32) void;
extern "wgpu" fn js_texture_view_destroy(id: u32) void;
extern "wgpu" fn js_queue_write_texture(
    queue: u32,
    texture: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data_ptr: [*]const u8,
    data_len: usize,
    mip_level: u32,
) void;
extern "wgpu" fn js_queue_write_texture_region(
    queue: u32,
    texture: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data_ptr: [*]const u8,
    data_len: usize,
) void;

// --- Sampler ---
extern "wgpu" fn js_device_create_sampler(
    device: u32,
    mag_filter_linear: u32,
    min_filter_linear: u32,
    address_mode: u32,
    mipmap_filter_linear: u32,
) u32;

// --- Shader module ---
extern "wgpu" fn js_device_create_shader_module_wgsl(
    device: u32,
    wgsl_ptr: [*]const u8,
    wgsl_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;

// --- Bind group layout / bind group ---
// Bind group layout entries are passed as a packed binary blob.  See
// `BindGroupCache.zig` for the serialization format.
extern "wgpu" fn js_device_create_bind_group_layout(
    device: u32,
    entries_ptr: [*]const u8,
    entries_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;
extern "wgpu" fn js_device_create_bind_group(
    device: u32,
    layout: u32,
    entries_ptr: [*]const u8,
    entries_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;

// --- Pipeline layout ---
extern "wgpu" fn js_device_create_pipeline_layout(
    device: u32,
    bgls_ptr: [*]const u32,
    bgls_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;

// --- Render pipeline ---
// Pipeline descriptor is passed as a packed binary blob (see
// `pipeline_cache.zig`).
//
// Two shader modules: `vs_module` and `fs_module`.  They can be the
// SAME handle when one WGSL source contains both `@vertex` and
// `@fragment` entry points (the historical Renderer2D shape), or
// DIFFERENT handles when the engine emits separate VS and FS WGSL
// files from the typed shader pipeline (Phase C of the wgpu plan).
// The descriptor blob's `vs_entry_point` resolves against `vs_module`,
// `fs_entry_point` against `fs_module`.
extern "wgpu" fn js_device_create_render_pipeline(
    device: u32,
    layout: u32,
    vs_module: u32,
    fs_module: u32,
    descriptor_ptr: [*]const u8,
    descriptor_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;

// --- Compute pipeline ---
extern "wgpu" fn js_device_create_compute_pipeline(
    device: u32,
    layout: u32,
    shader_module: u32,
    entry_point_ptr: [*]const u8,
    entry_point_len: usize,
    label_ptr: [*]const u8,
    label_len: usize,
) u32;

// --- Command encoder ---
extern "wgpu" fn js_device_create_command_encoder(device: u32) u32;
extern "wgpu" fn js_command_encoder_finish(encoder: u32) u32;
extern "wgpu" fn js_encoder_copy_buffer_to_buffer(
    encoder: u32,
    src: u32,
    src_off: u32,
    dst: u32,
    dst_off: u32,
    size: u32,
) void;
// Async buffer readback (poll-based, mirrors the GL fetch pattern): start a
// map+read of `size` bytes from `buf`, returns a read-handle (0 = failed). Poll
// until ready, then copy into wasm memory.
extern "wgpu" fn js_buffer_read_start(buf: u32, size: u32) u32;
extern "wgpu" fn js_buffer_read_poll(handle: u32) u32; // 0 pending, 1 ready
extern "wgpu" fn js_buffer_read_into(
    handle: u32,
    ptr: [*]u8,
    len: u32,
) void;
extern "wgpu" fn js_buffer_read_release(handle: u32) void;
extern "wgpu" fn js_adapter_info(ptr: [*]u8, cap: u32) u32;
extern "wgpu" fn js_encoder_copy_texture_to_buffer(
    encoder: u32,
    texture: u32,
    dst: u32,
    bytes_per_row: u32,
    width: u32,
    height: u32,
) void;
extern "wgpu" fn js_queue_submit(queue: u32, cmd_buffer: u32) void;

// --- Render pass encoder ---
extern "wgpu" fn js_encoder_begin_render_pass(
    encoder: u32,
    color_view: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    load_op: u32,
    store_op: u32,
    depth_view: u32, // 0 = no depth
    resolve_view: u32, // 0 = no MSAA resolve
) u32;
// MRT sibling: N color attachments in one pass.  `views_ptr` points at a
// wasm-memory array of `views_len` u32 texture-view HANDLES (the same table
// handles the single-view call takes); one clear/load/store applies to all.
extern "wgpu" fn js_encoder_begin_render_pass_mrt(
    encoder: u32,
    views_ptr: [*]const u32,
    views_len: usize,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    load_op: u32,
    store_op: u32,
    depth_view: u32, // 0 = no depth
) u32;
extern "wgpu" fn js_render_pass_set_pipeline(pass: u32, pipeline: u32) void;
extern "wgpu" fn js_render_pass_set_bind_group(
    pass: u32,
    group_index: u32,
    bind_group: u32,
) void;
extern "wgpu" fn js_render_pass_set_vertex_buffer(
    pass: u32,
    slot: u32,
    buffer: u32,
    offset: u64,
    size: u64,
) void;
extern "wgpu" fn js_render_pass_set_index_buffer(
    pass: u32,
    buffer: u32,
    format: u32, // 0 = uint16, 1 = uint32
    offset: u64,
    size: u64,
) void;
extern "wgpu" fn js_render_pass_draw(
    pass: u32,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;
extern "wgpu" fn js_render_pass_draw_indexed(
    pass: u32,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) void;
extern "wgpu" fn js_render_pass_set_scissor_rect(
    pass: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) void;
extern "wgpu" fn js_render_pass_end(pass: u32) void;

// --- Compute pass encoder ---
extern "wgpu" fn js_encoder_begin_compute_pass(encoder: u32) u32;
extern "wgpu" fn js_compute_pass_set_pipeline(pass: u32, pipeline: u32) void;
extern "wgpu" fn js_compute_pass_set_bind_group(
    pass: u32,
    group_index: u32,
    bind_group: u32,
) void;
extern "wgpu" fn js_compute_pass_dispatch_workgroups(
    pass: u32,
    x: u32,
    y: u32,
    z: u32,
) void;
extern "wgpu" fn js_compute_pass_end(pass: u32) void;

// ============================================================================
// SECTION 3b - the GPU host: the browser's externs above, or the Vulkan host
// ============================================================================

/// The browser's side of each call, under the host-neutral name every GPU host declares: the extern's name without
/// `js_`. On the web `gpu_host` IS this namespace, so every wrapper's call compiles to the same wasm import as before.
const web_host = struct {
    pub const initDevice = js_init_device;
    pub const deviceGetQueue = js_device_get_queue;
    pub const getSurface = js_get_surface;
    pub const surfaceGetCurrentTexture = js_surface_get_current_texture;
    pub const surfacePresent = js_surface_present;
    pub const surfaceGetFormat = js_surface_get_format;
    pub const surfaceGetSize = js_surface_get_size;
    pub const surfaceGetCssSize = js_surface_get_css_size;
    pub const nowMs = js_now_ms;
    pub const gpuMsLast = js_gpu_ms_last;
    pub const deviceCreateBuffer = js_device_create_buffer;
    pub const bufferDestroy = js_buffer_destroy;
    pub const queueWriteBuffer = js_queue_write_buffer;
    pub const deviceCreateTexture = js_device_create_texture;
    pub const textureCreateView = js_texture_create_view;
    pub const textureCreateViewMip = js_texture_create_view_mip;
    pub const textureCreateViewArray = js_texture_create_view_array;
    pub const textureCreateViewLayer = js_texture_create_view_layer;
    pub const textureDestroy = js_texture_destroy;
    pub const bindGroupDestroy = js_bind_group_destroy;
    pub const bindGroupLayoutDestroy = js_bind_group_layout_destroy;
    pub const pipelineLayoutDestroy = js_pipeline_layout_destroy;
    pub const renderPipelineDestroy = js_render_pipeline_destroy;
    pub const computePipelineDestroy = js_compute_pipeline_destroy;
    pub const samplerDestroy = js_sampler_destroy;
    pub const shaderModuleDestroy = js_shader_module_destroy;
    pub const textureViewDestroy = js_texture_view_destroy;
    pub const queueWriteTexture = js_queue_write_texture;
    pub const queueWriteTextureRegion = js_queue_write_texture_region;
    pub const deviceCreateSampler = js_device_create_sampler;
    pub const deviceCreateShaderModuleWgsl = js_device_create_shader_module_wgsl;
    pub const deviceCreateBindGroupLayout = js_device_create_bind_group_layout;
    pub const deviceCreateBindGroup = js_device_create_bind_group;
    pub const deviceCreatePipelineLayout = js_device_create_pipeline_layout;
    pub const deviceCreateRenderPipeline = js_device_create_render_pipeline;
    pub const deviceCreateComputePipeline = js_device_create_compute_pipeline;
    pub const deviceCreateCommandEncoder = js_device_create_command_encoder;
    pub const commandEncoderFinish = js_command_encoder_finish;
    pub const encoderCopyBufferToBuffer = js_encoder_copy_buffer_to_buffer;
    pub const bufferReadStart = js_buffer_read_start;
    pub const bufferReadPoll = js_buffer_read_poll;
    pub const bufferReadInto = js_buffer_read_into;
    pub const bufferReadRelease = js_buffer_read_release;
    pub const adapterInfo = js_adapter_info;
    pub const encoderCopyTextureToBuffer = js_encoder_copy_texture_to_buffer;
    pub const queueSubmit = js_queue_submit;
    pub const encoderBeginRenderPass = js_encoder_begin_render_pass;
    pub const encoderBeginRenderPassMrt = js_encoder_begin_render_pass_mrt;
    pub const renderPassSetPipeline = js_render_pass_set_pipeline;
    pub const renderPassSetBindGroup = js_render_pass_set_bind_group;
    pub const renderPassSetVertexBuffer = js_render_pass_set_vertex_buffer;
    pub const renderPassSetIndexBuffer = js_render_pass_set_index_buffer;
    pub const renderPassDraw = js_render_pass_draw;
    pub const renderPassDrawIndexed = js_render_pass_draw_indexed;
    pub const renderPassSetScissorRect = js_render_pass_set_scissor_rect;
    pub const renderPassEnd = js_render_pass_end;
    pub const encoderBeginComputePass = js_encoder_begin_compute_pass;
    pub const computePassSetPipeline = js_compute_pass_set_pipeline;
    pub const computePassSetBindGroup = js_compute_pass_set_bind_group;
    pub const computePassDispatchWorkgroups = js_compute_pass_dispatch_workgroups;
    pub const computePassEnd = js_compute_pass_end;
};

/// The host every wrapper calls, chosen at compile time: WebGPU through the browser bridge on the web, Vulkan
/// natively. Without a GPU (host tests, tools) each wrapper returns its invalid default before reaching it.
const gpu_host = switch (host.kind) {
    .native, .headless => vulkan_host,
    .web, .none => web_host,
};

/// `Host` declares each of `web_host`'s calls with the same parameter types and result type (calling convention
/// aside: the browser's are wasm imports).
fn checkHostInterface(comptime Host: type) void {
    for (@typeInfo(web_host).@"struct".decl_names) |name| {
        if (!@hasDecl(Host, name)) {
            @compileError("the Vulkan host does not declare `" ++ name ++ "`");
        }
        const browser: std.lang.Type.Fn = @typeInfo(@TypeOf(@field(web_host, name))).@"fn";
        const declared: std.lang.Type.Fn = @typeInfo(@TypeOf(@field(Host, name))).@"fn";
        if (browser.param_types.len != declared.param_types.len) {
            @compileError("the Vulkan host's `" ++ name ++ "` takes a different number of parameters");
        }
        for (browser.param_types, declared.param_types) |browser_param, declared_param| {
            if (browser_param.? != declared_param.?) {
                @compileError("the Vulkan host's `" ++ name ++ "` takes a parameter of another type");
            }
        }
        if (browser.return_type.? != declared.return_type.?) {
            @compileError("the Vulkan host's `" ++ name ++ "` returns another type");
        }
    }
}

comptime {
    // Every call the browser takes, the Vulkan host declares with the same parameters and result, so a call it lacks
    // fails the build by name. Checked in web builds only: anywhere else, naming an
    // `extern "wgpu"` function - even only for its type - would make the program link against a library "wgpu".
    if (host.kind == .web) {
        checkHostInterface(vulkan_host);
    }
}

// ============================================================================
// SECTION 4 - Zig-friendly wrappers
// ============================================================================

/// Initialize the WebGPU device.  Returns an invalid handle on host
/// builds; the wasm side asynchronously acquires the device on first
/// call (the JS side blocks the async boundary by deferring the
/// first wasm tick until the device is ready).
pub fn initDevice() DeviceHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.initDevice()));
}

pub fn getQueue(device: DeviceHandle) QueueHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.deviceGetQueue(@backingInt(device))));
}

pub fn getSurface() SurfaceHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.getSurface()));
}

pub fn getSurfaceFormat(surface: SurfaceHandle) TextureFormat {
    if (comptime !host.has_gpu) {
        return .undefined_;
    }
    return @fromBackingInt(@intCast(gpu_host.surfaceGetFormat(@backingInt(surface))));
}

/// Backing-pixel dimensions of a surface's canvas.
pub const SurfaceSize = struct { width: u32, height: u32 };

/// The backing-pixel size of the surface's canvas. The depth attachment must
/// equal this every frame or WebGPU rejects the whole render pass, so the
/// frame loop polls it. Returns `.{ 1, 1 }` on native (no surface).
pub fn getSurfaceSize(surface: SurfaceHandle) SurfaceSize {
    if (comptime !host.has_gpu) {
        return .{ .width = 1, .height = 1 };
    }
    const packed_size: u32 = gpu_host.surfaceGetSize(@backingInt(surface));
    return .{ .width = packed_size >> 16, .height = packed_size & 0xffff };
}

/// The LOGICAL (CSS-pixel) size of the surface's canvas. This is the
/// coordinate space the 2D ortho + `f.window` use (logical px == CSS px in
/// responsive mode), so drawing coordinates match input coordinates (which the
/// bridge delivers as CSS px). Distinct from `getSurfaceSize` (backing px, for
/// the depth attachment). Returns `.{ 1, 1 }` on native.
pub fn getSurfaceCssSize(surface: SurfaceHandle) SurfaceSize {
    if (comptime !host.has_gpu) {
        return .{ .width = 1, .height = 1 };
    }
    const packed_size: u32 = gpu_host.surfaceGetCssSize(@backingInt(surface));
    return .{ .width = packed_size >> 16, .height = packed_size & 0xffff };
}

/// Monotonic-ish wall clock in milliseconds (browser `performance.now()`).
/// Used by the app run-loop for elapsed time + delta_time. 0 on native.
pub fn nowMs() f64 {
    if (comptime !host.has_gpu) {
        return 0;
    }
    return gpu_host.nowMs();
}

/// Most recent GPU pass time (ms) from timestamp-query, or 0 when unsupported.
pub fn gpuMs() f64 {
    if (comptime !host.has_gpu) {
        return 0;
    }
    return gpu_host.gpuMsLast();
}

pub fn getCurrentTextureView(surface: SurfaceHandle) TextureViewHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.surfaceGetCurrentTexture(@backingInt(surface))));
}

pub fn surfacePresent(surface: SurfaceHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.surfacePresent(@backingInt(surface));
}

/// Create a buffer.  Caller owns the returned handle.
pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsage,
    label: []const u8 = "",
};

// ---- GPU-handle leak canary (Phase 1b) --------------------------------------
// Per-kind live count (created - destroyed), maintained by the create*/destroy*
// wrappers below. Independent of the smoke mock, so it works in EVERY build
// (device, launcher, standalone) - the backstop for device-only leaks the mock
// can't see. `handleBaseline` snapshots after engine init; `liveHandleReport`
// formats the delta vs a baseline (non-zero only) for the launcher/leak-test to
// log at teardown. NOT auto-logged at exit (engine resources are legitimately
// live until then; a bare non-zero would be a false positive).
pub const HandleKind = enum(u8) {
    texture,
    buffer,
    bind_group,
    bind_group_layout,
    pipeline_layout,
    render_pipeline,
    compute_pipeline,
    sampler,
    shader_module,
    texture_view,
};

// A census indexed by HandleKind - sized to the enum automatically (no manual
// count), and named via @tagName in the report (no parallel names array).
pub const HandleCensus = std.enums.EnumArray(HandleKind, i64);

// lint:off module-var: process-wide GPU-handle census for the leak canary
var live_handles: HandleCensus = .initFill(0);

fn bumpHandle(kind: HandleKind, delta: i64) void {
    live_handles.getPtr(kind).* += delta;
}

pub fn createBuffer(device: DeviceHandle, desc: BufferDesc) BufferHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.buffer, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateBuffer(
        @backingInt(device),
        desc.size,
        @bitCast(desc.usage),
        desc.label.ptr,
        desc.label.len,
    )));
}

/// Snapshot the current per-kind live counts (call after engine init, before an
/// example's init, to get the baseline the example's teardown must return to).
pub fn handleBaseline() HandleCensus {
    return live_handles;
}

/// Format `live - baseline` per kind (non-zero only) into `buf`. Empty result
/// means no leak vs baseline. Used by the launcher/leak-test after a deinit.
pub fn liveHandleReport(baseline: HandleCensus, buf: []u8) []const u8 {
    var w: usize = 0;
    for (std.enums.values(HandleKind)) |kind| {
        const delta: i64 = live_handles.get(kind) - baseline.get(kind);
        if (delta != 0) {
            const seg: []const u8 = bufPrint(buf[w..], "{s}={d} ", .{ @tagName(kind), delta }) catch break;
            w += seg.len;
        }
    }
    return buf[0..w];
}

pub fn destroyBuffer(buffer: BufferHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.buffer, -1);
    gpu_host.bufferDestroy(@backingInt(buffer));
}

/// Fetch the adapter's vendor/architecture/device/description string -
/// the on-device answer to "which WebGPU backend did this page get?"
/// (t1178: Vulkan vs compat/GLES is the live coherency question).
pub fn adapterInfo(buf: []u8) []const u8 {
    if (comptime !host.has_gpu) {
        return "native";
    }
    const n: u32 = gpu_host.adapterInfo(buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

pub fn queueWriteBuffer(
    queue: QueueHandle,
    buffer: BufferHandle,
    offset: u64,
    data: []const u8,
) void {
    // WebGPU requires both the destination offset and the byte count to be
    // multiples of 4; a violation is a `writeBuffer` OperationError at
    // runtime in the browser. Assert here so the failure points at the
    // offending call in debug builds instead of surfacing as an opaque GPU
    // error. `createBufferInit` pads uploads so odd-length data still lands
    // 4-aligned; use it for anything whose length isn't statically a
    // multiple of 4 (e.g. u16 index buffers with an odd index count).
    assertf(offset % 4 == 0, @src(), "queueWriteBuffer: offset {d} must be a multiple of 4", .{offset});
    assertf(
        data.len % 4 == 0,
        @src(),
        "queueWriteBuffer: byte count {d} must be a multiple of 4 (use createBufferInit, which pads)",
        .{data.len},
    );
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.queueWriteBuffer(
        @backingInt(queue),
        @backingInt(buffer),
        offset,
        data.ptr,
        data.len,
    );
}

/// Create a buffer and upload `bytes` into it, padding the allocation and the
/// write up to the next multiple of 4 so WebGPU's `writeBuffer` alignment rule
/// is always satisfied - even when `bytes.len` is odd (e.g. a u16 index buffer
/// with an odd index count: 3*triangles*2 bytes == 2 mod 4). Pad bytes are
/// zero and never referenced (draw counts use the real element count). No
/// allocator needed: the aligned prefix is written directly and a <=3-byte
/// tail is zero-extended into a 4-byte stack write. `usage` must include
/// `copy_dst`.
/// The buffer size `createBufferInit` will allocate for `bytes`: rounded up to the next
/// multiple of four.
///
/// Exposed so callers that must record the buffer's size cannot compute it differently from
/// the function that creates it - the two disagreeing is how a padded buffer ends up with an
/// unpadded length recorded against it.
pub fn alignedBufferSize(byte_count: usize) u64 {
    return (@as(u64, byte_count) + 3) & ~@as(u64, 3);
}

pub fn createBufferInit(
    device: DeviceHandle,
    queue: QueueHandle,
    bytes: []const u8,
    usage: BufferUsage,
    label: []const u8,
) BufferHandle {
    const aligned: usize = bytes.len & ~@as(usize, 3);
    const rem: usize = bytes.len - aligned;
    const total: u64 = if (rem == 0) bytes.len else @as(u64, aligned) + 4;
    const buffer: BufferHandle = createBuffer(device, .{
        .size = total,
        .usage = usage,
        .label = label,
    });
    if (aligned > 0) {
        queueWriteBuffer(queue, buffer, 0, bytes[0..aligned]);
    }
    if (rem != 0) {
        var tail: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(tail[0..rem], bytes[aligned..]);
        queueWriteBuffer(queue, buffer, aligned, tail[0..]);
    }
    return buffer;
}

/// Create a shader module from raw WGSL text.  This is the bottom of
/// the shader pipeline; the typed-schema path produces WGSL via the
/// SPIR-V -> WGSL transpiler, then calls this function.  The raw-WGSL
/// escape path calls this directly.
pub fn createShaderModuleWgsl(
    device: DeviceHandle,
    wgsl: []const u8,
    label: []const u8,
) ShaderModuleHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.shader_module, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateShaderModuleWgsl(
        @backingInt(device),
        wgsl.ptr,
        wgsl.len,
        label.ptr,
        label.len,
    )));
}

/// Create a command encoder.  One per frame.  Caller calls `finish`
/// at frame end to produce a CommandBuffer.
pub fn createCommandEncoder(device: DeviceHandle) CommandEncoderHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.deviceCreateCommandEncoder(@backingInt(device))));
}

/// Copy `size` bytes between two GPU buffers (src must be COPY_SRC, dst COPY_DST).
pub fn copyBufferToBuffer(
    encoder: CommandEncoderHandle,
    src: BufferHandle,
    src_off: u32,
    dst: BufferHandle,
    dst_off: u32,
    size: u32,
) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.encoderCopyBufferToBuffer(
        @backingInt(encoder),
        @backingInt(src),
        src_off,
        @backingInt(dst),
        dst_off,
        size,
    );
}

/// A pending GPU->CPU buffer read (poll-based, like the GL fetch pattern).
pub const BufferRead = enum(u32) { invalid = 0, _ };

/// Start mapping+reading `size` bytes from `buf` (must be MAP_READ). Returns a
/// handle to poll. The mapped buffer becomes readable once `poll` returns 1.
/// Record a texture->buffer copy (the readback front half: pair the
/// destination - a COPY_DST|MAP_READ staging buffer - with the
/// `bufferRead*` poll family).  `bytes_per_row` MUST be 256-aligned per the
/// WebGPU spec; callers pad rows and strip the padding after `readInto`.
pub fn copyTextureToBuffer(
    encoder: CommandEncoderHandle,
    texture: TextureHandle,
    dst: BufferHandle,
    bytes_per_row: u32,
    width: u32,
    height: u32,
) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.encoderCopyTextureToBuffer(
        @backingInt(encoder),
        @backingInt(texture),
        @backingInt(dst),
        bytes_per_row,
        width,
        height,
    );
}

pub fn bufferReadStart(buf: BufferHandle, size: u32) BufferRead {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.bufferReadStart(@backingInt(buf), size)));
}

/// 0 = still mapping, 1 = data ready to copy via `bufferReadInto`.
pub fn bufferReadPoll(handle: BufferRead) bool {
    if (comptime !host.has_gpu) {
        return false;
    }
    return gpu_host.bufferReadPoll(@backingInt(handle)) != 0;
}

/// Copy the mapped bytes into `dst` (only valid after poll==true).
pub fn bufferReadInto(handle: BufferRead, dst: []u8) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.bufferReadInto(@backingInt(handle), dst.ptr, @intCast(dst.len));
}

/// Unmap + free the read handle.
pub fn bufferReadRelease(handle: BufferRead) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.bufferReadRelease(@backingInt(handle));
}

pub fn finishCommandEncoder(encoder: CommandEncoderHandle) CommandBufferHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    return @fromBackingInt(@intCast(gpu_host.commandEncoderFinish(@backingInt(encoder))));
}

pub fn queueSubmit(queue: QueueHandle, cmd_buffer: CommandBufferHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.queueSubmit(@backingInt(queue), @backingInt(cmd_buffer));
}

/// Create a bind group layout from a pre-serialized entries blob.
/// See `descriptor_encoder.encodeBindGroupLayoutEntries` for the
/// encoder.  The caller owns `entries_blob` and must keep it alive
/// for the duration of the call (it's deserialized synchronously on
/// the JS side).
pub fn createBindGroupLayout(
    device: DeviceHandle,
    entries_blob: []const u8,
    label: []const u8,
) BindGroupLayoutHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.bind_group_layout, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateBindGroupLayout(
        @backingInt(device),
        entries_blob.ptr,
        entries_blob.len,
        label.ptr,
        label.len,
    )));
}

/// Create a bind group from a pre-serialized entries blob.  See
/// `descriptor_encoder.encodeBindGroupEntries` for the encoder.
pub fn createBindGroup(
    device: DeviceHandle,
    layout: BindGroupLayoutHandle,
    entries_blob: []const u8,
    label: []const u8,
) BindGroupHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.bind_group, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateBindGroup(
        @backingInt(device),
        @backingInt(layout),
        entries_blob.ptr,
        entries_blob.len,
        label.ptr,
        label.len,
    )));
}

/// Create a pipeline layout from a slice of bind group layout
/// handles.  The slice is passed directly to the JS side as a u32
/// array (no encoding needed).
pub fn createPipelineLayout(
    device: DeviceHandle,
    bind_group_layouts: []const BindGroupLayoutHandle,
    label: []const u8,
) PipelineLayoutHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.pipeline_layout, 1);
    // BindGroupLayoutHandle is enum(u32), so its pointer casts straight to u32s. Not via
    // `sliceAsBytes`: it returns a 1-aligned `&[0]u8{}` for an empty slice, which fails the
    // `@alignCast` back to u32 (a layout-less shader has zero groups).
    return @fromBackingInt(@intCast(gpu_host.deviceCreatePipelineLayout(
        @backingInt(device),
        @ptrCast(bind_group_layouts.ptr),
        bind_group_layouts.len,
        label.ptr,
        label.len,
    )));
}

/// Create a render pipeline.  Descriptor passed as a pre-serialized
/// blob - see `descriptor_encoder.encodeRenderPipelineDescriptor`.
///
/// Takes TWO shader modules: a vertex stage and a fragment stage.
/// Pass the same handle twice when one WGSL source contains both
/// stages (e.g., a hand-written file with `vs_main` and `fs_main`).
/// Pass different handles when VS and FS come from separate WGSL
/// files - the engine's typed shader pipeline produces this shape.
/// The descriptor's `vs_entry_point` and `fs_entry_point` resolve
/// against their respective modules.
pub fn createRenderPipeline(
    device: DeviceHandle,
    layout: PipelineLayoutHandle,
    vs_module: ShaderModuleHandle,
    fs_module: ShaderModuleHandle,
    descriptor_blob: []const u8,
    label: []const u8,
) RenderPipelineHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.render_pipeline, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateRenderPipeline(
        @backingInt(device),
        @backingInt(layout),
        @backingInt(vs_module),
        @backingInt(fs_module),
        descriptor_blob.ptr,
        descriptor_blob.len,
        label.ptr,
        label.len,
    )));
}

/// Create a compute pipeline.  Compute pipelines use only one entry
/// point; no descriptor blob needed.
pub fn createComputePipeline(
    device: DeviceHandle,
    layout: PipelineLayoutHandle,
    shader_module: ShaderModuleHandle,
    entry_point: []const u8,
    label: []const u8,
) ComputePipelineHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.compute_pipeline, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateComputePipeline(
        @backingInt(device),
        @backingInt(layout),
        @backingInt(shader_module),
        entry_point.ptr,
        entry_point.len,
        label.ptr,
        label.len,
    )));
}

// --- Texture / Sampler ---

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: TextureUsage,
    /// MSAA sample count (1 = no multisampling). Multisampled textures are
    /// render-attachment only (not directly sampleable); resolve into a
    /// 1-sample texture to read them.
    sample_count: u32 = 1,
    /// Number of mip levels (1 = no mip chain). Levels above 0 must be filled
    /// (e.g. via per-level views); WebGPU does not auto-generate them.
    mip_level_count: u32 = 1,
    /// Array layer count (1 = single layer). >1 makes a 2d-array texture.
    array_layers: u32 = 1,
    label: []const u8 = "",
};

pub fn createTexture(device: DeviceHandle, desc: TextureDesc) TextureHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.texture, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateTexture(
        @backingInt(device),
        desc.width,
        desc.height,
        @backingInt(desc.format),
        @bitCast(desc.usage),
        desc.label.ptr,
        desc.label.len,
        desc.sample_count,
        desc.mip_level_count,
        desc.array_layers,
    )));
}

pub fn createTextureView(texture: TextureHandle) TextureViewHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.texture_view, 1);
    return @fromBackingInt(@intCast(gpu_host.textureCreateView(@backingInt(texture))));
}

/// A view of a single mip level (base_mip_level = `base_mip`, count 1) - used to
/// bind one mip level as a storage/render target. Default `createTextureView`
/// views the whole chain for sampling.
pub fn createTextureViewMip(
    texture: TextureHandle,
    base_mip: u32,
    mip_count: u32,
) TextureViewHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.texture_view, 1);
    return @fromBackingInt(@intCast(gpu_host.textureCreateViewMip(@backingInt(texture), base_mip, mip_count)));
}

/// A 2d-array view covering `layer_count` layers (base layer 0). Bind it as a
/// `texture_2d_array` (sampled) or `texture_storage_2d_array` (compute write).
pub fn createTextureViewArray(texture: TextureHandle, layer_count: u32) TextureViewHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.texture_view, 1);
    return @fromBackingInt(@intCast(gpu_host.textureCreateViewArray(@backingInt(texture), layer_count)));
}

/// A 2D view of the one layer `layer` of an array texture, at its first mip level: what a render pass draws into,
/// layer by layer (a render target is one layer), and what a shader samples as an ordinary 2D texture.
pub fn createTextureViewLayer(texture: TextureHandle, layer: u32) TextureViewHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.texture_view, 1);
    return @fromBackingInt(@intCast(gpu_host.textureCreateViewLayer(@backingInt(texture), layer)));
}

pub fn destroyTexture(texture: TextureHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.texture, -1);
    gpu_host.textureDestroy(@backingInt(texture));
}

// Explicit destroys for the remaining GPU resource types (WebGPU GC's these
// once the JS handle table drops its ref; the bridge just releases the slot).
pub fn destroyBindGroup(handle: BindGroupHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.bind_group, -1);
    gpu_host.bindGroupDestroy(@backingInt(handle));
}
pub fn destroyBindGroupLayout(handle: BindGroupLayoutHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.bind_group_layout, -1);
    gpu_host.bindGroupLayoutDestroy(@backingInt(handle));
}
pub fn destroyPipelineLayout(handle: PipelineLayoutHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.pipeline_layout, -1);
    gpu_host.pipelineLayoutDestroy(@backingInt(handle));
}
pub fn destroyRenderPipeline(handle: RenderPipelineHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.render_pipeline, -1);
    gpu_host.renderPipelineDestroy(@backingInt(handle));
}
pub fn destroyComputePipeline(handle: ComputePipelineHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.compute_pipeline, -1);
    gpu_host.computePipelineDestroy(@backingInt(handle));
}
pub fn destroySampler(handle: SamplerHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.sampler, -1);
    gpu_host.samplerDestroy(@backingInt(handle));
}
pub fn destroyShaderModule(handle: ShaderModuleHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.shader_module, -1);
    gpu_host.shaderModuleDestroy(@backingInt(handle));
}
pub fn destroyTextureView(handle: TextureViewHandle) void {
    if (comptime !host.has_gpu) {
        return;
    }
    bumpHandle(.texture_view, -1);
    gpu_host.textureViewDestroy(@backingInt(handle));
}

/// Like `queueWriteTexture` but targets an explicit `mip_level` of the texture
/// (level 0 is the base image). Used to upload a CPU-generated mip chain.
pub fn queueWriteTextureLevel(
    queue: QueueHandle,
    texture: TextureHandle,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data: []const u8,
    mip_level: u32,
) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.queueWriteTexture(
        @backingInt(queue),
        @backingInt(texture),
        width,
        height,
        bytes_per_row,
        data.ptr,
        data.len,
        mip_level,
    );
}

pub fn queueWriteTexture(
    queue: QueueHandle,
    texture: TextureHandle,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data: []const u8,
) void {
    queueWriteTextureLevel(queue, texture, width, height, bytes_per_row, data, 0);
}

/// Write a `width`x`height` rectangle of mip level 0 at (`x`, `y`), leaving the
/// rest of the texture untouched - the partial upload a glyph cache needs (one
/// freshly rasterized glyph into a shared atlas page). `data` holds exactly the
/// rectangle, `bytes_per_row` apart.
pub fn queueWriteTextureRegion(
    queue: QueueHandle,
    texture: TextureHandle,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data: []const u8,
) void {
    if (comptime !host.has_gpu) {
        return;
    }
    gpu_host.queueWriteTextureRegion(
        @backingInt(queue),
        @backingInt(texture),
        x,
        y,
        width,
        height,
        bytes_per_row,
        data.ptr,
        data.len,
    );
}

pub const SamplerDesc = struct {
    mag_filter_linear: bool = false,
    min_filter_linear: bool = false,
    mipmap_filter_linear: bool = false,
    address_mode: AddressMode = .clamp_to_edge,

    pub const AddressMode = gpu_abi.AddressMode;
};

pub fn createSampler(device: DeviceHandle, desc: SamplerDesc) SamplerHandle {
    if (comptime !host.has_gpu) {
        return .invalid;
    }
    bumpHandle(.sampler, 1);
    return @fromBackingInt(@intCast(gpu_host.deviceCreateSampler(
        @backingInt(device),
        @intFromBool(desc.mag_filter_linear),
        @intFromBool(desc.min_filter_linear),
        @backingInt(desc.address_mode),
        @intFromBool(desc.mipmap_filter_linear),
    )));
}

// Render pass / compute pass helpers live in `render_pass.zig` and
// `compute_pass.zig` respectively - they wrap the lower-level js_*
// calls above with state-tracking on the GpuFrame.

// ============================================================================
// SECTION 5 - sanity checks
// ============================================================================

comptime {
    // Catch the alignment surprise: packed flag types must serialize
    // as u32 across the JS boundary.
    if (@sizeOf(BufferUsage) != 4) {
        @compileError("BufferUsage must serialize as 4 bytes across the JS boundary");
    }
    if (@sizeOf(TextureUsage) != 4) {
        @compileError("TextureUsage must serialize as 4 bytes across the JS boundary");
    }
    if (@sizeOf(ShaderStage) != 4) {
        @compileError("ShaderStage must serialize as 4 bytes across the JS boundary");
    }
    if (@sizeOf(ColorF32) != 16) {
        @compileError("ColorF32 must be 16 bytes");
    }
}

test "refAllDecls: every decl compiles (catches removed-API / non-generic breakage)" {
    // refAllDecls forces semantic analysis of each top-level decl, so a removed
    // stdlib API in a non-generic fn (e.g. the Zig 0.17 bufPrintZ/dupeZ/meta.Int
    // removals) fails here instead of silently slipping through. NOTE: it does
    // NOT analyze generic fn bodies until they're instantiated, so it's a
    // partial net -- real generic coverage comes from tests that call them.
    refAllDecls(@This());
}

// ===========================================================================
// RENDER PASSES - the `render_pass` namespace, public as `z.render_pass`
// through the umbrella's re-exports. It depends only on declarations above
// it, never on what follows.
// ===========================================================================
pub const render_pass = struct {
    // src/render_pass.zig - render pass lifecycle helpers.
    // WebGPU architecture is documented centrally in src/zimr.zig
    // (the module-level `//!` doc) - read that before changing wgpu code.
    //
    //
    // A WebGPU render pass is bracketed: `encoder.beginRenderPass(desc)`
    // returns a `RenderPassEncoder`, the user records draw calls on it,
    // then `pass.end()` finishes it.  Only ONE render pass can be open
    // on an encoder at a time.
    //
    // This module provides:
    //
    //   1. `beginRenderPass(...)` - convenience wrapper that constructs
    //      the color-attachment descriptor and invokes the JS bridge.
    //
    //   2. State-tracked helpers (`setPipeline`, `setBindGroup`, `draw`,
    //      `drawIndexed`) that go through the typed handles and check
    //      pass validity in debug mode.
    //
    //   3. `endRenderPass(...)` - explicit close.  Asserts the pass is
    //      open and not in a nested state.
    //
    // State tracking: the active pass lives on a `PassState` value the
    // caller holds (see `gpu_iface.zig`).  These helpers take the raw
    // pass handle as an explicit parameter rather than reaching into any
    // struct - keeps them usable in contexts where the PassState isn't
    // in scope (e.g., low-level test code) and matches WebGPU's own
    // shape where the pass encoder is itself the receiver.

    /// Begin a render pass on the given encoder, drawing to `color_view`
    /// (typically the surface's current backbuffer view, or a render-
    /// texture view for offscreen rendering).
    pub const BeginDesc = struct {
        encoder: CommandEncoderHandle,
        color_view: TextureViewHandle,
        clear: ?ColorF32 = null,
        load_op: LoadOp = .load,
        store_op: StoreOp = .store,
        depth_view: ?TextureViewHandle = null,
        /// MSAA resolve target: when set, the multisampled `color_view` is
        /// resolved into this 1-sample, sampleable view at pass end.
        resolve_view: ?TextureViewHandle = null,
        label: []const u8 = "render_pass",
    };

    pub fn begin(desc: BeginDesc) RenderPassEncoderHandle {
        // If a clear color is set, override load_op to .clear.
        const load_op: LoadOp = if (desc.clear != null) LoadOp.clear else desc.load_op;
        const clear = desc.clear orelse ColorF32{ .r = 0, .g = 0, .b = 0, .a = 1 };

        return @fromBackingInt(@intCast(wgpu_js.beginRenderPass(
            @backingInt(desc.encoder),
            @backingInt(desc.color_view),
            clear.r,
            clear.g,
            clear.b,
            clear.a,
            @backingInt(load_op),
            @backingInt(desc.store_op),
            if (desc.depth_view) |dv| @backingInt(dv) else 0,
            if (desc.resolve_view) |rv| @backingInt(rv) else 0,
        )));
    }

    pub fn end(pass: RenderPassEncoderHandle) void {
        wgpu_js.renderPassEnd(@backingInt(pass));
    }

    /// Begin an MRT render pass: `color_views` (up to 8 - WebGPU's
    /// maxColorAttachments floor) all cleared/loaded together, sharing one
    /// depth attachment.  The G-buffer pass of deferred rendering is the
    /// canonical caller: three attachments, one geometry walk.
    pub const BeginMrtDesc = struct {
        encoder: CommandEncoderHandle,
        color_views: []const TextureViewHandle,
        clear: ?ColorF32 = null,
        load_op: LoadOp = .load,
        store_op: StoreOp = .store,
        depth_view: ?TextureViewHandle = null,
        label: []const u8 = "mrt_render_pass",
    };

    pub fn beginMrt(desc: BeginMrtDesc) RenderPassEncoderHandle {
        const load_op: LoadOp = if (desc.clear != null) LoadOp.clear else desc.load_op;
        const clear = desc.clear orelse ColorF32{ .r = 0, .g = 0, .b = 0, .a = 1 };
        // Handles are enum(u32) - reinterpret the slice as the raw u32 array
        // the bridge reads from wasm memory (max 8, on the stack).
        var raw: [8]u32 = undefined;
        const n: usize = @min(desc.color_views.len, raw.len);
        for (desc.color_views[0..n], raw[0..n]) |v, *r| {
            r.* = @backingInt(v);
        }
        return @fromBackingInt(@intCast(wgpu_js.beginRenderPassMrt(
            @backingInt(desc.encoder),
            raw[0..n],
            clear.r,
            clear.g,
            clear.b,
            clear.a,
            @backingInt(load_op),
            @backingInt(desc.store_op),
            if (desc.depth_view) |dv| @backingInt(dv) else 0,
        )));
    }

    pub fn setPipeline(
        pass: RenderPassEncoderHandle,
        pipeline: RenderPipelineHandle,
    ) void {
        wgpu_js.renderPassSetPipeline(
            @backingInt(pass),
            @backingInt(pipeline),
        );
    }

    pub fn setBindGroup(
        pass: RenderPassEncoderHandle,
        group_index: u32,
        bind_group: BindGroupHandle,
    ) void {
        wgpu_js.renderPassSetBindGroup(
            @backingInt(pass),
            group_index,
            @backingInt(bind_group),
        );
    }

    pub const VertexBufferBinding = struct {
        slot: u32,
        buffer: BufferHandle,
        offset: u64 = 0,
        size: u64 = ~@as(u64, 0), // sentinel meaning "rest of buffer"
    };

    pub fn setVertexBuffer(
        pass: RenderPassEncoderHandle,
        binding: VertexBufferBinding,
    ) void {
        wgpu_js.renderPassSetVertexBuffer(
            @backingInt(pass),
            binding.slot,
            @backingInt(binding.buffer),
            binding.offset,
            binding.size,
        );
    }

    pub const IndexBufferBinding = struct {
        buffer: BufferHandle,
        format: IndexFormat,
        offset: u64 = 0,
        size: u64 = ~@as(u64, 0),
    };

    pub fn setIndexBuffer(
        pass: RenderPassEncoderHandle,
        binding: IndexBufferBinding,
    ) void {
        wgpu_js.renderPassSetIndexBuffer(
            @backingInt(pass),
            @backingInt(binding.buffer),
            @backingInt(binding.format),
            binding.offset,
            binding.size,
        );
    }

    pub const DrawDesc = struct {
        vertex_count: u32,
        instance_count: u32 = 1,
        first_vertex: u32 = 0,
        first_instance: u32 = 0,
    };

    pub fn draw(pass: RenderPassEncoderHandle, desc: DrawDesc) void {
        wgpu_js.renderPassDraw(
            @backingInt(pass),
            desc.vertex_count,
            desc.instance_count,
            desc.first_vertex,
            desc.first_instance,
        );
    }

    pub const DrawIndexedDesc = struct {
        index_count: u32,
        instance_count: u32 = 1,
        first_index: u32 = 0,
        base_vertex: i32 = 0,
        first_instance: u32 = 0,
    };

    pub fn drawIndexed(pass: RenderPassEncoderHandle, desc: DrawIndexedDesc) void {
        wgpu_js.renderPassDrawIndexed(
            @backingInt(pass),
            desc.index_count,
            desc.instance_count,
            desc.first_index,
            desc.base_vertex,
            desc.first_instance,
        );
    }

    /// Restrict subsequent draws to the rect (x, y, w, h) in BACKING pixels
    /// (origin top-left). The caller computes backing px from logical coords.
    pub fn setScissorRect(
        pass: RenderPassEncoderHandle,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) void {
        wgpu_js.renderPassSetScissorRect(@backingInt(pass), x, y, w, h);
    }

    // ============================================================================
    // Internal - JS-bridge thunks
    // ============================================================================
    //
    // The render-pass calls go through this `wgpu_js` namespace so the file can be
    // tested on the build machine without a GPU. With one - the browser's, or the
    // Vulkan host's - each forwards to the host's call (`gpu_host`); in a build
    // without a GPU (`host.has_gpu` false) each does nothing and returns 0.

    const wgpu_js = struct {
        inline fn beginRenderPass(
            encoder: u32,
            color_view: u32,
            clear_r: f32,
            clear_g: f32,
            clear_b: f32,
            clear_a: f32,
            load_op: u32,
            store_op: u32,
            depth_view: u32,
            resolve_view: u32,
        ) u32 {
            if (comptime !host.has_gpu) {
                return 0;
            }
            return gpu_host.encoderBeginRenderPass(
                encoder,
                color_view,
                clear_r,
                clear_g,
                clear_b,
                clear_a,
                load_op,
                store_op,
                depth_view,
                resolve_view,
            );
        }

        inline fn beginRenderPassMrt(
            encoder: u32,
            views: []const u32,
            clear_r: f32,
            clear_g: f32,
            clear_b: f32,
            clear_a: f32,
            load_op: u32,
            store_op: u32,
            depth_view: u32,
        ) u32 {
            if (comptime !host.has_gpu) {
                return 0;
            }
            return gpu_host.encoderBeginRenderPassMrt(
                encoder,
                views.ptr,
                views.len,
                clear_r,
                clear_g,
                clear_b,
                clear_a,
                load_op,
                store_op,
                depth_view,
            );
        }

        inline fn renderPassEnd(pass: u32) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassEnd(pass);
        }

        inline fn renderPassSetPipeline(pass: u32, pipeline: u32) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassSetPipeline(pass, pipeline);
        }

        inline fn renderPassSetBindGroup(
            pass: u32,
            group_index: u32,
            bind_group: u32,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassSetBindGroup(pass, group_index, bind_group);
        }

        inline fn renderPassSetVertexBuffer(
            pass: u32,
            slot: u32,
            buffer: u32,
            offset: u64,
            size: u64,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassSetVertexBuffer(pass, slot, buffer, offset, size);
        }

        inline fn renderPassSetIndexBuffer(
            pass: u32,
            buffer: u32,
            format: u32,
            offset: u64,
            size: u64,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassSetIndexBuffer(pass, buffer, format, offset, size);
        }

        inline fn renderPassDraw(
            pass: u32,
            vc: u32,
            ic: u32,
            fv: u32,
            fi: u32,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassDraw(pass, vc, ic, fv, fi);
        }

        inline fn renderPassDrawIndexed(
            pass: u32,
            ic: u32,
            instc: u32,
            fi: u32,
            bv: i32,
            finst: u32,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassDrawIndexed(pass, ic, instc, fi, bv, finst);
        }

        inline fn renderPassSetScissorRect(
            pass: u32,
            x: u32,
            y: u32,
            w: u32,
            h: u32,
        ) void {
            if (comptime !host.has_gpu) {
                return;
            }
            gpu_host.renderPassSetScissorRect(pass, x, y, w, h);
        }
    };

    test "refAllDecls: every decl compiles (catches removed-API / non-generic breakage)" {
        // refAllDecls forces semantic analysis of each top-level decl, so a removed
        // stdlib API in a non-generic fn (e.g. the Zig 0.17 bufPrintZ/dupeZ/meta.Int
        // removals) fails here instead of silently slipping through. NOTE: it does
        // NOT analyze generic fn bodies until they're instantiated, so it's a
        // partial net -- real generic coverage comes from tests that call them.
        refAllDecls(@This());
    }
};

// ===========================================================================
// COMPUTE PASSES - the `compute_pass` namespace, public as `z.compute_pass`
// through the umbrella's re-exports. It depends only on declarations above
// it, never on what follows.
// ===========================================================================
pub const compute_pass = struct {
    // src/compute_pass.zig - compute pass lifecycle helpers.
    //
    // Compute passes are simpler than render passes - no attachments, no
    // blend state, just a sequence of pipeline binds + dispatches.
    //
    // Key constraint: compute and render passes can't be open at the same
    // time on a single encoder.  Begin/end ordering is the user's (or
    // `GpuFrame.beginComputePass` helper's) responsibility.

    pub fn begin(encoder: CommandEncoderHandle) ComputePassEncoderHandle {
        if (comptime !host.has_gpu) {
            return .invalid;
        }
        return @fromBackingInt(@intCast(gpu_host.encoderBeginComputePass(@backingInt(encoder))));
    }

    pub fn end(pass: ComputePassEncoderHandle) void {
        if (comptime !host.has_gpu) {
            return;
        }
        gpu_host.computePassEnd(@backingInt(pass));
    }

    pub fn setPipeline(
        pass: ComputePassEncoderHandle,
        pipeline: ComputePipelineHandle,
    ) void {
        if (comptime !host.has_gpu) {
            return;
        }
        gpu_host.computePassSetPipeline(
            @backingInt(pass),
            @backingInt(pipeline),
        );
    }

    pub fn setBindGroup(
        pass: ComputePassEncoderHandle,
        group_index: u32,
        bind_group: BindGroupHandle,
    ) void {
        if (comptime !host.has_gpu) {
            return;
        }
        gpu_host.computePassSetBindGroup(
            @backingInt(pass),
            group_index,
            @backingInt(bind_group),
        );
    }

    pub const Dispatch = struct { x: u32, y: u32 = 1, z: u32 = 1 };

    pub fn dispatchWorkgroups(
        pass: ComputePassEncoderHandle,
        d: Dispatch,
    ) void {
        if (comptime !host.has_gpu) {
            return;
        }
        gpu_host.computePassDispatchWorkgroups(
            @backingInt(pass),
            d.x,
            d.y,
            d.z,
        );
    }

    test "refAllDecls: every decl compiles (catches removed-API / non-generic breakage)" {
        // refAllDecls forces semantic analysis of each top-level decl, so a removed
        // stdlib API in a non-generic fn (e.g. the Zig 0.17 bufPrintZ/dupeZ/meta.Int
        // removals) fails here instead of silently slipping through. NOTE: it does
        // NOT analyze generic fn bodies until they're instantiated, so it's a
        // partial net -- real generic coverage comes from tests that call them.
        refAllDecls(@This());
    }
};

// ===========================================================================
// STORAGE BUFFERS - the `storage_buffer` namespace, public as
// `z.storage_buffer` through the umbrella's re-exports. It depends only on
// what is above it.
// ===========================================================================
pub const storage_buffer = struct {
    // src/storage_buffer.zig - typed storage buffer wrapper for compute + instancing.
    //
    // `StorageBuffer(T)` is a generic wrapper around a WebGPU buffer with
    // `storage` usage flag set.  Used in two main contexts:
    //
    //   1. Compute shader I/O - read/write arrays of T, accessible to
    //      compute kernels via `@group(N) @binding(M) var<storage,
    //      read_write> data: array<T>` in WGSL.
    //
    //   2. Instanced rendering - vertex shader reads per-instance data
    //      out of a storage buffer indexed by `vertex_index / 6` (for
    //      quad batches) or `instance_index` (for instanced draws).
    //
    // The wrapper carries the element count so callers can do safe
    // bounds-checked size queries.  GPU memory layout is std430-ish
    // (WebGPU's storage layout) - vec2 is 8 bytes, vec3 is 16 bytes
    // (padded), vec4 is 16 bytes, structs follow the inner field alignment.
    //
    // Lifecycle:
    //   1. `create(device, gpa, .{ .count = N, .usage = ... })` - allocate
    //      empty.
    //   2. `createWithData(device, queue, gpa, .{ .data = ... })` -
    //      allocate + initial-write in one call.
    //   3. `write(queue, offset_elements, data)` - overwrite a range.
    //   4. `binding()` - produce the metadata blob needed for bind-group
    //      construction.
    //   5. `deinit()` - release the underlying GPU buffer.
    //
    // This file does NOT depend on GpuFrame - callers pass device + queue
    // explicitly.  This keeps StorageBuffer testable without spinning up
    // a full frame.

    /// Generic typed storage buffer.  `T` is the element type.
    pub fn StorageBuffer(comptime T: type) type {
        return struct {
            const Self = @This();

            buffer: BufferHandle = .invalid,
            count: u32 = 0,
            gpa: ?Allocator = null,

            pub const ElementType = T;
            pub const element_size: u32 = @sizeOf(T);

            pub const CreateDesc = struct {
                count: u32,
                usage: BufferUsage = .{ .storage = true, .copy_dst = true },
                label: []const u8 = "storage_buf",
            };

            pub const CreateWithDataDesc = struct {
                data: []const T,
                usage: BufferUsage = .{ .storage = true, .copy_dst = true },
                label: []const u8 = "storage_buf",
            };

            /// Allocate the underlying GPU buffer.  `count` elements of `T`.
            /// Initial contents undefined.
            pub fn create(
                device: DeviceHandle,
                gpa: Allocator,
                desc: CreateDesc,
            ) Self {
                const size_bytes = @as(u64, desc.count) * element_size;
                const buf: BufferHandle = createBuffer(device, .{
                    .size = size_bytes,
                    .usage = desc.usage,
                    .label = desc.label,
                });
                return .{ .buffer = buf, .count = desc.count, .gpa = gpa };
            }

            /// Allocate + initial-upload.  Convenience for the common case.
            pub fn createWithData(
                device: DeviceHandle,
                queue: QueueHandle,
                gpa: Allocator,
                desc: CreateWithDataDesc,
            ) Self {
                const self: Self = create(device, gpa, .{
                    .count = @intCast(desc.data.len),
                    .usage = desc.usage,
                    .label = desc.label,
                });
                queueWriteBuffer(
                    queue,
                    self.buffer,
                    0,
                    sliceAsBytes(desc.data),
                );
                return self;
            }

            /// Overwrite `data.len` elements starting at `offset_elements`.
            pub fn write(
                self: Self,
                queue: QueueHandle,
                offset_elements: u32,
                data: []const T,
            ) void {
                assert(offset_elements + data.len <= self.count, @src());
                queueWriteBuffer(
                    queue,
                    self.buffer,
                    @as(u64, offset_elements) * element_size,
                    sliceAsBytes(data),
                );
            }

            /// Byte size of the buffer.
            pub inline fn sizeBytes(self: Self) u64 {
                return @as(u64, self.count) * element_size;
            }

            /// Bind metadata used when assembling a BindGroup.  See
            /// `BindGroupCache.zig` for the consuming side.
            pub fn binding(self: Self) StorageBufferBinding {
                return .{
                    .buffer = self.buffer,
                    .offset = 0,
                    .size = self.sizeBytes(),
                };
            }

            pub fn deinit(self: *Self) void {
                if (self.gpa != null) {
                    destroyBuffer(self.buffer);
                    self.* = .{};
                }
            }
        };
    }

    /// Bind metadata produced by `StorageBuffer(T).binding()`.  Type-erased
    /// because bind groups can hold storage buffers of any element type
    /// at the same binding slot.
    pub const StorageBufferBinding = struct {
        buffer: BufferHandle,
        offset: u64,
        size: u64,
    };

    // ============================================================================
    // Tests
    // ============================================================================

    test "StorageBuffer(f32) has sane element size" {
        try expectEqual(@as(u32, 4), StorageBuffer(f32).element_size);
    }

    test "StorageBuffer(extern struct { ... }) preserves layout" {
        const Particle = extern struct {
            pos: [2]f32,
            vel: [2]f32,
        };
        try expectEqual(@as(u32, 16), StorageBuffer(Particle).element_size);
    }

    test "sizeBytes scales with count" {
        var sb: StorageBuffer(f32) = .{};
        sb.count = 100;
        try expectEqual(@as(u64, 400), sb.sizeBytes());
    }
};

const expectTrue = expect;

test "alignedBufferSize rounds up to four, which is what queueWriteBuffer requires" {
    // * THE SHAPE OF A REAL BUG, pinned.
    //
    // `queueWriteBuffer` requires a byte count that is a multiple of four. A u16 index
    // buffer meets that only when the index COUNT is even - and indices come in threes, so
    // ANY mesh with an odd triangle count fails. A KUKA arm link has 2759 triangles: 8277
    // indices, 16554 bytes, rejected by WebGPU with an error that surfaces in the browser
    // rather than at the call site.
    //
    // The bug had already been found once and fixed LOCALLY at one of the three index-upload
    // sites, leaving the other two broken. This asserts the arithmetic every one of them now
    // shares.

    // The exact case that failed, in the field.
    try expectTrue(alignedBufferSize(2759 * 3 * @sizeOf(u16)) == 16556);
    // Already aligned: untouched.
    try expectTrue(alignedBufferSize(16) == 16);
    try expectTrue(alignedBufferSize(0) == 0);
    // Every remainder rounds up, never down - a short buffer would be worse than an
    // unaligned one, since the tail of the data would simply be missing.
    for (1..64) |n| {
        const padded: u64 = alignedBufferSize(n);
        try expectTrue(padded % 4 == 0);
        try expectTrue(padded >= n);
        try expectTrue(padded - n < 4);
    }
    // And an odd count of u16 is ALWAYS unaligned, which is the property that makes this a
    // rule about triangle counts rather than a coincidence.
    for (0..32) |triangles| {
        const indices: usize = triangles * 3;
        const bytes: usize = indices * @sizeOf(u16);
        try expectTrue((bytes % 4 == 0) == (indices % 2 == 0));
    }
}
