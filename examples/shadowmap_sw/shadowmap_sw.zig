//! shadowmap_sw — ONE shadow-map shader source, THREE renderers, live.
//!
//!   - LEFT  (CPU): the software rasterizer runs `depth_vs/fs` +
//!     `lit_shadow_vs/fs` — the actual engine shader FILES — as plain Zig,
//!     two passes per frame (light-view depth into an rgba8 map, then the
//!     lit pass sampling it through a nearest `TextureRef`).
//!   - RIGHT (GPU): the SAME four files, compiled shadermath → SPIR-V →
//!     WGSL at build time, run as two WebGPU passes (rgba16_float shadow
//!     RTT + the lit pipeline sampling it).
//!   - CORNER (COMPTIME): the Zig COMPILER evaluates the same two passes
//!     over a build-baked decimated bunny proxy (`scene.bakeCorner`) and the
//!     result ships in the binary as a const — a shadow-mapped still no
//!     runtime ever rendered.
//!
//! Everything the renderers agree on — geometry, staging, the orbiting
//! light, spin animation, uniform-block builders, the software passes —
//! lives in `scene.zig`.  This file is only the plumbing each backend
//! needs: GPU pipelines/buffers/bind groups on one side, two
//! `raster.Context`s on the other, and the helmet-style split-screen
//! composite (drag the divider; drag empty space to orbit; pinch/wheel to
//! zoom).  The scene animates — objects spin, the light circles — so every
//! varying and uniform is exercised live on both halves, while the corner
//! stays frozen at `scene.corner_time`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const scene = @import("scene.zig");

const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec2i = zm.Vec2i;
const clamp = zm.clamp;
const float = zm.float;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const vec = zm.vec;

const shadow = scene.shadow;

// The app-bridge instance: the one sanctioned wasm entry-point handle.
pub var zimr_app: z.App = .{};

const depth_vs_wgsl = @embedFile("depth_vs.wgsl");
const depth_fs_wgsl = @embedFile("depth_fs.wgsl");
const lit_vs_wgsl = @embedFile("lit_shadow_vs.wgsl");
const lit_fs_wgsl = @embedFile("lit_shadow_fs.wgsl");
const bunny_obj = @embedFile("bunny.obj");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// ---- Uniform block types: taken FROM the shader Io schemas, so the GPU
//      buffers and the software `shaderMain` calls cannot drift. ----
const DepthUbo = @FieldType(shadow.depth_vs.Io, "u");
const LitVsUbo = @FieldType(shadow.lit_vs.Io, "u");
const LitFsUbo = @FieldType(shadow.lit_fs.Io, "u");

const shadow_rt_size: i32 = 1024; // GPU shadow map (rgba16_float)
const cpu_shadow_res: usize = 144; // CPU shadow map (rgba8 Context)
const cpu_pixel_budget: f32 = 24_000; // CPU lit image, shaped to the canvas

// ---- The comptime corner: baked by the compiler at these dimensions. ----
const corner_sm: usize = 64;
const corner_w: usize = 96;
const corner_h: usize = 72;
const corner: scene.CornerBake(corner_sm, corner_w, corner_h) = blk: {
    @setEvalBranchQuota(2_000_000_000);
    break :blk scene.bakeCorner(corner_sm, corner_w, corner_h);
};

// One drawable object on the GPU: geometry buffers + a private set of the
// three uniform blocks (depth / lit-VS / lit-FS) and their bind groups.  The
// two cubes share buffers but carry their own uniforms — same on the CPU,
// where the "uniforms" are just the Io structs passed per draw.
const Obj = struct {
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,

    depth_ubo: z.wgpu.BufferHandle,
    depth_bg: z.wgpu.BindGroupHandle,
    lit_vs_ubo: z.wgpu.BufferHandle,
    lit_g0_bg: z.wgpu.BindGroupHandle,
    lit_fs_ubo: z.wgpu.BufferHandle,
    lit_g2_bg: z.wgpu.BindGroupHandle,
};

const State = struct {
    gpa: Allocator,

    // ---- GPU half ----
    depth_pipeline: z.wgpu.RenderPipelineHandle,
    lit_pipeline: z.wgpu.RenderPipelineHandle,
    shadow_rt: z.RenderTexture, // light-view depth (rgba16_float, fixed size)
    lit_g1_bg: z.wgpu.BindGroupHandle, // shared shadow-map sampler
    floor_vbo: z.wgpu.BufferHandle,
    floor_ibo: z.wgpu.BufferHandle,
    cube_vbo: z.wgpu.BufferHandle,
    cube_ibo: z.wgpu.BufferHandle,
    bunny_vbo: z.wgpu.BufferHandle,
    bunny_ibo: z.wgpu.BufferHandle,
    shadow_sampler: z.wgpu.SamplerHandle,
    rt: z.RenderTexture, // camera-view target at canvas size
    objs: [scene.objects.len]Obj,

    // ---- CPU half: the same bunny mesh kept on the CPU + two Contexts ----
    bunny_verts: []scene.SceneVertex,
    bunny_indices: []u32,
    bunny_frame: scene.BunnyFrame,
    depth_outs: []shadow.depth_vs.Out,
    lit_outs: []shadow.lit_vs.Out,
    sm_ctx: z.raster.Context, // pass 1 target (cpu_shadow_res²)
    sw: z.raster.Context, // pass 2 target (canvas-shaped)
    sw_fb: z.CpuFramebuffer,

    // ---- shared ----
    font: z.Font,
    cam_yaw: f32 = 0.7,
    cam_pitch: f32 = 0.42,
    cam_dist: f32 = 12.0,
    dragging: bool = false,
    prev_pinch: f32 = 0,
    divider_frac: f32 = 0.5,
    last_mouse: Vec2 = .{ -1, -1 },
    corner_fb: z.CpuFramebuffer, // the comptime bake, uploaded once
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    gpa.free(s.bunny_verts);
    gpa.free(s.bunny_indices);
    gpa.free(s.depth_outs);
    gpa.free(s.lit_outs);
    s.sm_ctx.deinit(gpa);
    s.sw.deinit(gpa);
    for (&s.objs) |*o| {
        z.wgpu.destroyBuffer(o.depth_ubo);
        z.wgpu.destroyBuffer(o.lit_vs_ubo);
        z.wgpu.destroyBuffer(o.lit_fs_ubo);
        z.wgpu.destroyBindGroup(o.depth_bg);
        z.wgpu.destroyBindGroup(o.lit_g0_bg);
        z.wgpu.destroyBindGroup(o.lit_g2_bg);
    }
    z.wgpu.destroyBuffer(s.floor_vbo);
    z.wgpu.destroyBuffer(s.floor_ibo);
    z.wgpu.destroyBuffer(s.cube_vbo);
    z.wgpu.destroyBuffer(s.cube_ibo);
    z.wgpu.destroyBuffer(s.bunny_vbo);
    z.wgpu.destroyBuffer(s.bunny_ibo);
    z.wgpu.destroyBindGroup(s.lit_g1_bg);
    z.wgpu.destroySampler(s.shadow_sampler);
    z.wgpu.destroyRenderPipeline(s.depth_pipeline);
    z.wgpu.destroyRenderPipeline(s.lit_pipeline);
    s.shadow_rt.deinit();
    s.rt.deinit();
    s.sw_fb.deinit();
    s.corner_fb.deinit();
}

fn uniformLayout(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    min_size: u64,
    vis: z.wgpu.ShaderStage,
    label: []const u8,
) !z.wgpu.BindGroupLayoutHandle {
    const entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = vis, .resource = .{ .uniform_buffer = .{ .min_size = min_size } } },
    };
    const blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &entries);
    defer gpa.free(blob);
    return z.wgpu.createBindGroupLayout(device, blob, label);
}

fn uniformBindGroup(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    bgl: z.wgpu.BindGroupLayoutHandle,
    buffer: z.wgpu.BufferHandle,
    size: u64,
    label: []const u8,
) !z.wgpu.BindGroupHandle {
    const entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = buffer, .size = size } } },
    };
    const blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &entries);
    defer gpa.free(blob);
    return z.wgpu.createBindGroup(device, bgl, blob, label);
}

const Bgls = struct {
    depth_g0: z.wgpu.BindGroupLayoutHandle,
    lit_g0: z.wgpu.BindGroupLayoutHandle,
    lit_g2: z.wgpu.BindGroupLayoutHandle,
};

/// Per-object GPU state: three uniform buffers + bind groups over shared
/// geometry buffers.
fn makeObj(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    bgls: Bgls,
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
) !Obj {
    const depth_sz: u64 = z.shader.wireSizeOf(DepthUbo);
    const lit_vs_sz: u64 = z.shader.wireSizeOf(LitVsUbo);
    const lit_fs_sz: u64 = z.shader.wireSizeOf(LitFsUbo);
    const depth_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = depth_sz,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const lit_vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = lit_vs_sz,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const lit_fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = lit_fs_sz,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    return .{
        .vbo = vbo,
        .ibo = ibo,
        .vbo_bytes = vbo_bytes,
        .ibo_bytes = ibo_bytes,
        .icount = icount,
        .depth_ubo = depth_ubo,
        .depth_bg = try uniformBindGroup(gpa, device, bgls.depth_g0, depth_ubo, depth_sz, "smsw_depth_bg"),
        .lit_vs_ubo = lit_vs_ubo,
        .lit_g0_bg = try uniformBindGroup(gpa, device, bgls.lit_g0, lit_vs_ubo, lit_vs_sz, "smsw_g0_bg"),
        .lit_fs_ubo = lit_fs_ubo,
        .lit_g2_bg = try uniformBindGroup(gpa, device, bgls.lit_g2, lit_fs_ubo, lit_fs_sz, "smsw_g2_bg"),
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;

    // ---- The bunny, parsed ONCE: the same vertex array is uploaded to the
    //      GPU and kept on the CPU (the corner uses its baked proxy). ----
    var bunny_data: z.codecs.obj.Data = try z.codecs.obj.parse(gpa, bunny_obj);
    defer bunny_data.deinit(gpa);
    const bunny_mesh: z.codecs.obj.Mesh = try bunny_data.toMesh(gpa);
    defer bunny_mesh.deinit(gpa);

    const bvc: usize = bunny_mesh.vertexCount();
    const bunny_verts: []scene.SceneVertex = try gpa.alloc(scene.SceneVertex, bvc);
    var mn: [3]f32 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var mx: [3]f32 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (bunny_verts, 0..) |*sv, i| {
        const p: [3]f32 = .{
            bunny_mesh.positions[i * 3 + 0],
            bunny_mesh.positions[i * 3 + 1],
            bunny_mesh.positions[i * 3 + 2],
        };
        sv.* = .{ .position = p, .normal = .{
            bunny_mesh.normals[i * 3 + 0],
            bunny_mesh.normals[i * 3 + 1],
            bunny_mesh.normals[i * 3 + 2],
        } };
        var a: usize = 0;
        while (a < 3) : (a += 1) {
            mn[a] = @min(mn[a], p[a]);
            mx[a] = @max(mx[a], p[a]);
        }
    }
    const bunny_indices: []u32 = try gpa.dupe(u32, bunny_mesh.indices);

    // ---- GPU geometry buffers (floor + unit cube + bunny) ----
    const floor_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(scene.floor_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "smsw_floor_vbo",
    );
    const floor_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(scene.floor_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "smsw_floor_ibo",
    );
    const cube_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(scene.cube_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "smsw_cube_vbo",
    );
    const cube_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(scene.cube_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "smsw_cube_ibo",
    );
    const bunny_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(bunny_verts),
        .{ .vertex = true, .copy_dst = true },
        "smsw_bunny_vbo",
    );
    const bunny_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(bunny_indices),
        .{ .index = true, .copy_dst = true },
        "smsw_bunny_ibo",
    );

    // ---- GPU shadow map: rgba16_float + NEAREST sampler (linear filtering
    //      would blend depths across silhouettes and corrupt the compare) ----
    const shadow_rt: z.RenderTexture = z.RenderTexture.create(device, .{
        .width = @intCast(shadow_rt_size),
        .height = @intCast(shadow_rt_size),
        .format = .rgba16_float,
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "smsw_shadow_rt",
    });
    const shadow_sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .address_mode = .clamp_to_edge,
    });

    // ---- Vertex layouts: the depth pass reads position only ----
    const pos_only_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(scene.SceneVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        },
    };
    const pos_normal_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(scene.SceneVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };

    // ---- Bind-group layouts + the shared shadow-sampler group ----
    const bgls: Bgls = .{
        .depth_g0 = try uniformLayout(gpa, device, z.shader.wireSizeOf(DepthUbo), .{ .vertex = true }, "smsw_depth_g0"),
        .lit_g0 = try uniformLayout(gpa, device, z.shader.wireSizeOf(LitVsUbo), .{ .vertex = true }, "smsw_lit_g0"),
        .lit_g2 = try uniformLayout(gpa, device, z.shader.wireSizeOf(LitFsUbo), .{ .fragment = true }, "smsw_lit_g2"),
    };
    const shadow_tex: z.WgpuTexture = shadow_rt.asTexture();
    const g1_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_layout_entries);
    defer gpa.free(g1_layout_blob);
    const lit_g1_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, g1_layout_blob, "smsw_lit_g1");
    const g1_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = shadow_tex.view } },
        .{ .binding = 1, .resource = .{ .sampler = shadow_sampler } },
    };
    const g1_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g1_entries);
    defer gpa.free(g1_blob);
    const lit_g1_bg: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, lit_g1_bgl, g1_blob, "smsw_lit_g1_bg");

    // ---- Depth pass pipeline (targets the rgba16_float shadow RTT) ----
    const depth_bgls: [1]z.wgpu.BindGroupLayoutHandle = .{bgls.depth_g0};
    const depth_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, depth_bgls[0..], "smsw_depth_pl");
    const depth_vs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, depth_vs_wgsl, "depth_vs");
    const depth_fs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, depth_fs_wgsl, "depth_fs");
    const depth_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none,
        .rgba16_float,
        .depth24_plus,
        1,
    );
    const depth_pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_only_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = depth_combo,
    });
    defer gpa.free(depth_pipe_blob);
    const depth_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        depth_pl,
        depth_vs_mod,
        depth_fs_mod,
        depth_pipe_blob,
        "smsw_depth_pipe",
    );

    // ---- Lit pass pipeline (targets the rgba8 camera-view RTT) ----
    const lit_bgls: [3]z.wgpu.BindGroupLayoutHandle = .{ bgls.lit_g0, lit_g1_bgl, bgls.lit_g2 };
    const lit_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, lit_bgls[0..], "smsw_lit_pl");
    const lit_vs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lit_vs_wgsl, "lit_shadow_vs");
    const lit_fs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lit_fs_wgsl, "lit_shadow_fs");
    // Cull .none: the winding of every caster matches the GPU shadowmap
    // example, whose back faces are depth-occluded anyway.
    const lit_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less,
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const lit_pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_normal_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = lit_combo,
    });
    defer gpa.free(lit_pipe_blob);
    const lit_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        lit_pl,
        lit_vs_mod,
        lit_fs_mod,
        lit_pipe_blob,
        "smsw_lit_pipe",
    );

    // ---- Per-object GPU state, in `scene.objects` order ----
    var objs: [scene.objects.len]Obj = undefined;
    for (scene.objects, &objs) |o, *slot| {
        switch (o) {
            .floor => {
                slot.* = try makeObj(
                    gpa,
                    device,
                    bgls,
                    floor_vbo,
                    floor_ibo,
                    @sizeOf(@TypeOf(scene.floor_verts)),
                    @sizeOf(@TypeOf(scene.floor_indices)),
                    scene.floor_indices.len,
                );
            },
            .pillar, .receiver => {
                slot.* = try makeObj(
                    gpa,
                    device,
                    bgls,
                    cube_vbo,
                    cube_ibo,
                    @sizeOf(@TypeOf(scene.cube_verts)),
                    @sizeOf(@TypeOf(scene.cube_indices)),
                    scene.cube_indices.len,
                );
            },
            .bunny => {
                slot.* = try makeObj(
                    gpa,
                    device,
                    bgls,
                    bunny_vbo,
                    bunny_ibo,
                    bunny_verts.len * @sizeOf(scene.SceneVertex),
                    bunny_indices.len * @sizeOf(u32),
                    @intCast(bunny_indices.len),
                );
            },
        }
    }

    // ---- CPU half: two Contexts + shared VS-out scratch (bunny-sized) ----
    const sm_ctx: z.raster.Context = try z.raster.Context.init(gpa, cpu_shadow_res, cpu_shadow_res);
    const sw: z.raster.Context = try z.raster.Context.init(gpa, 220, 124);
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(device, queue, 220, 124, sw.colorBufferBytes(), "smsw_cpu");

    z.wgpu.destroyBindGroupLayout(bgls.depth_g0);
    z.wgpu.destroyBindGroupLayout(bgls.lit_g0);
    z.wgpu.destroyBindGroupLayout(bgls.lit_g2);
    z.wgpu.destroyBindGroupLayout(lit_g1_bgl);
    z.wgpu.destroyPipelineLayout(depth_pl);
    z.wgpu.destroyPipelineLayout(lit_pl);
    z.wgpu.destroyShaderModule(depth_vs_mod);
    z.wgpu.destroyShaderModule(depth_fs_mod);
    z.wgpu.destroyShaderModule(lit_vs_mod);
    z.wgpu.destroyShaderModule(lit_fs_mod);

    s.* = .{
        .gpa = gpa,
        .depth_pipeline = depth_pipeline,
        .lit_pipeline = lit_pipeline,
        .shadow_rt = shadow_rt,
        .lit_g1_bg = lit_g1_bg,
        .floor_vbo = floor_vbo,
        .floor_ibo = floor_ibo,
        .cube_vbo = cube_vbo,
        .cube_ibo = cube_ibo,
        .bunny_vbo = bunny_vbo,
        .bunny_ibo = bunny_ibo,
        .shadow_sampler = shadow_sampler,
        .rt = .{},
        .objs = objs,
        .bunny_verts = bunny_verts,
        .bunny_indices = bunny_indices,
        .bunny_frame = scene.bunnyFrame(mn, mx),
        .depth_outs = try gpa.alloc(shadow.depth_vs.Out, bvc),
        .lit_outs = try gpa.alloc(shadow.lit_vs.Out, bvc),
        .sm_ctx = sm_ctx,
        .sw = sw,
        .sw_fb = sw_fb,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .corner_fb = z.CpuFramebuffer.init(device, queue, corner_w, corner_h, &corner.image, "smsw_corner"),
    };
}

/// Keep both halves' targets matched to the LIVE canvas (helmet pattern):
/// the GPU camera-view RTT at the surface's backing size, the CPU lit
/// buffer at `cpu_pixel_budget` pixels shaped to the canvas aspect.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: i32 = @intCast(@max(backing.width, 1));
    const bh: i32 = @intCast(@max(backing.height, 1));
    if (s.rt.color == .invalid or s.rt.width != backing.width or s.rt.height != backing.height) {
        if (s.rt.color != .invalid) {
            z.unloadRenderTexture(f.gl, &s.rt);
        }
        s.rt = z.loadRenderTexture(f.gl, bw, bh);
    }

    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const aspect: f32 = vw / vh;
    const want_w: i32 = @trunc(@max(@round(@sqrt(cpu_pixel_budget * aspect)), 16));
    const want_h: i32 = @trunc(@max(@round(float(want_w) / aspect), 16));
    const dims: Vec2i = s.sw.colorBufferDims();
    if (dims[0] != want_w or dims[1] != want_h) {
        s.sw.resize(s.gpa, want_w, want_h) catch return;
        s.sw_fb.resize(f.gl, @intCast(want_w), @intCast(want_h), s.sw.colorBufferBytes(), "smsw_cpu");
    }
}

fn handleInput(f: *z.Frame, s: *State) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.02, 6.0, 24.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left)) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.08, 1.45);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.6, 6.0, 24.0);
    }
}

/// GPU per-object uniforms — built by the SAME `scene` Ubo builders the
/// software targets pass into `shaderMain`, uploaded verbatim.
fn writeObjUniforms(
    f: *z.Frame,
    s: *State,
    t: f32,
    cam_vp: Mat,
    rig: scene.LightRig,
) void {
    for (scene.objects, &s.objs) |o, *obj| {
        const model: Mat = scene.modelMatrix(o, t, s.bunny_frame);
        const depth_io: shadow.depth_vs.Io = scene.depthUbo(model, rig.vp);
        const depth_bytes: [z.shader.wireSizeOf(DepthUbo)]u8 = z.shader.wireOf(DepthUbo, &depth_io.u);
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.depth_ubo, 0, &depth_bytes);
        const lit_vs_io: shadow.lit_vs.Io = scene.litVsUbo(model, cam_vp, rig.vp, scene.normalMatrix(o, t));
        const lit_vs_bytes: [z.shader.wireSizeOf(LitVsUbo)]u8 = z.shader.wireOf(LitVsUbo, &lit_vs_io.u);
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.lit_vs_ubo, 0, &lit_vs_bytes);
        // GPU map is rgba16_float → the Ubo's default (fine) bias.
        const lit_fs_io: shadow.lit_fs.Io = scene.litFsUbo(o, rig.to_light, .{ 0.0025, 0.0008, 0, 0 });
        const lit_fs_bytes: [z.shader.wireSizeOf(LitFsUbo)]u8 = z.shader.wireOf(LitFsUbo, &lit_fs_io.u);
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.lit_fs_ubo, 0, &lit_fs_bytes);
    }
}

fn drawMesh(rps: *z.PassState, obj: *const Obj) void {
    z.render_pass.setVertexBuffer(rps.pass, .{ .slot = 0, .buffer = obj.vbo, .offset = 0, .size = obj.vbo_bytes });
    z.render_pass.setIndexBuffer(rps.pass, .{
        .buffer = obj.ibo,
        .format = .uint32,
        .offset = 0,
        .size = obj.ibo_bytes,
    });
    z.render_pass.drawIndexed(rps.pass, .{
        .index_count = obj.icount,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    });
}

/// The CPU frame: the same two passes as the GPU, per-object draws through
/// the same shader files, over two software Contexts.
fn renderCpu(s: *State, t: f32, cam_vp: Mat, rig: scene.LightRig) void {
    // ---- PASS 1: light-view depth into the rgba8 shadow map ----
    s.sm_ctx.clearColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 }); // far
    s.sm_ctx.clearDepth(1.0);
    s.sm_ctx.clear(.{ .color = true, .depth = true });
    for (scene.objects) |o| {
        const g: scene.Geometry = geometryOf(s, o);
        const io: shadow.depth_vs.Io = scene.depthUbo(scene.modelMatrix(o, t, s.bunny_frame), rig.vp);
        scene.drawDepth(&s.sm_ctx, g.verts, g.indices, io, s.depth_outs);
    }

    // ---- PASS 2: lit + shadow-tested, sampling pass 1 (nearest) ----
    s.sw.clearColor(.{ .r = 12, .g = 12, .b = 28, .a = 255 });
    s.sw.clearDepth(1.0);
    s.sw.clear(.{ .color = true, .depth = true });
    for (scene.objects) |o| {
        const g: scene.Geometry = geometryOf(s, o);
        const vs_io: shadow.lit_vs.Io = scene.litVsUbo(
            scene.modelMatrix(o, t, s.bunny_frame),
            cam_vp,
            rig.vp,
            scene.normalMatrix(o, t),
        );
        var fs_io: shadow.lit_fs.Io = scene.litFsUbo(o, rig.to_light, scene.soft_bias);
        fs_io._shadow_map = .{
            .pixels = s.sm_ctx.colorBufferBytes(),
            .width = cpu_shadow_res,
            .height = cpu_shadow_res,
            .linear = false, // nearest — depth comparisons must not blend texels
        };
        scene.drawLit(&s.sw, g.verts, g.indices, vs_io, fs_io, s.lit_outs);
    }
}

fn geometryOf(s: *State, o: scene.Object) scene.Geometry {
    return switch (o) {
        .floor => .{ .verts = &scene.floor_verts, .indices = &scene.floor_indices },
        .pillar, .receiver => .{ .verts = &scene.cube_verts, .indices = &scene.cube_indices },
        .bunny => .{ .verts = s.bunny_verts, .indices = s.bunny_indices },
    };
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    handleInput(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).

    // ---- The shared frame inputs: orbiting light + orbit camera ----
    const rig: scene.LightRig = scene.lightRig(t);
    const cam_target: Vec = vec(0, 1.0, 0);
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const cy: f32 = @cos(s.cam_yaw);
    const sy: f32 = @sin(s.cam_yaw);
    const cam_eye: Vec = vec(
        cam_target[0] + s.cam_dist * cp * sy,
        cam_target[1] + s.cam_dist * sp,
        cam_target[2] + s.cam_dist * cp * cy,
    );
    const cam_view: Mat = lookAtRh(cam_eye, cam_target, vec(0, 1, 0));
    const cam_proj: Mat = perspectiveFovRh(0.8, vw / @max(vh, 1.0), 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    // ---- CPU: two software passes through the engine shaders ----
    renderCpu(s, t, cam_vp, rig);
    s.sw_fb.update(f.gpu.queue, s.sw.colorBufferBytes());

    // ---- GPU: the same two passes through the same files (as WGSL) ----
    writeObjUniforms(f, s, t, cam_vp, rig);
    const Backend: type = z.WgpuBackend;

    // PASS 1: shadow map (light's eye → rgba16_float RTT). Raw pass: our own
    // pipeline, so beginTextureMode must not bind the rgba8 2D pipeline here.
    z.beginTextureModeRaw(f.gl, s.shadow_rt, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const p1: *z.PassState = f.gl.pass;
    Backend.setPipeline(p1, z.shader.RenderPipeline(void, void){ .gpu_handle = s.depth_pipeline });
    for (&s.objs) |*obj| {
        Backend.setBindGroup(p1, 0, obj.depth_bg);
        drawMesh(p1, obj);
    }
    z.endTextureModeRaw(f.gl);

    // PASS 2: lit scene (camera → canvas-sized rgba8 RTT), sampling pass 1.
    z.beginTextureModeRaw(f.gl, s.rt, .{ .r = 12, .g = 12, .b = 28, .a = 255 });
    const p2: *z.PassState = f.gl.pass;
    Backend.setPipeline(p2, z.shader.RenderPipeline(void, void){ .gpu_handle = s.lit_pipeline });
    Backend.setBindGroup(p2, 1, s.lit_g1_bg);
    for (&s.objs) |*obj| {
        Backend.setBindGroup(p2, 0, obj.lit_g0_bg);
        Backend.setBindGroup(p2, 2, obj.lit_g2_bg);
        drawMesh(p2, obj);
    }
    z.endTextureModeRaw(f.gl);

    // ---- Composite (helmet-style): GPU full-surface, CPU left of the
    //      divider, comptime corner inset bottom-right ----
    // SCREEN PASS: open once, composite the GPU result + CPU/comptime insets.
    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 8, .g = 9, .b = 14, .a = 255 });
    f.gl.texture(
        .{ .x = 0, .y = 0, .width = vw, .height = vh },
        s.rt.asTexture(),
        .{ .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );
    const m: Vec2 = z.getMousePosition(f.input);
    const is_first_zero: bool = s.last_mouse[0] < 0 and m[0] == 0 and m[1] == 0;
    if (!is_first_zero and (m[0] != s.last_mouse[0] or m[1] != s.last_mouse[1])) {
        s.last_mouse = m;
        s.divider_frac = clamp(m[0] / vw, 0.0, 1.0);
    }
    const divider_x: f32 = s.divider_frac * vw;
    z.beginScissorMode(f.gl, 0, 0, divider_x, vh);
    s.sw_fb.present(f.gl, 0, 0, vw, vh);
    z.endScissorMode(f.gl);
    f.gl.rect(
        .{ .x = divider_x - 1.5, .y = 0, .width = 3, .height = vh },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    f.gl.text(
        .{ 16, 14 },
        "CPU lit_shadow_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 210, 14 },
        "GPU lit_shadow_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    // The comptime corner: baked by the compiler, frozen at scene.corner_time.
    const inset_h: f32 = clamp(@min(vw, vh) * 0.26, 72, 160);
    const inset_w: f32 = inset_h * (float(corner_w) / float(corner_h));
    const ix: f32 = vw - inset_w - 12;
    const iy: f32 = vh - inset_h - 12;
    s.corner_fb.present(f.gl, ix, iy, inset_w, inset_h);
    f.gl.rect(
        .{ .x = ix - 1, .y = iy - 1, .width = inset_w + 2, .height = inset_h + 2 },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .outline = 1.0 },
    );
    f.gl.text(
        .{ ix - 60, iy - 22 },
        "comptime lit_shadow_fs",
        .{ .size = 16, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    // NB: no explicit endDrawing — the runner closes the frame (idempotent),
    // which lets the launcher overlay its switch pill on this app's frame.

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - one shadow shader: CPU | GPU | comptime",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            // 2D pipelines carry depth so loadRenderTexture attaches a depth
            // buffer the raw lit pass can test against.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // CPU/GPU/comptime shadow targets rendered offscreen before the screen opens
    // (tile-based-GPU safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
    .memory = .managed,
};
