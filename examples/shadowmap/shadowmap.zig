// examples/shadowmap/shadowmap.zig
//
// shaders_shadowmap_rendering - the full two-pass shadow map. A floor, a
// handful of boxes and a slowly rotating Stanford bunny are lit by one
// directional light that casts real shadows, computed with classic shadow
// mapping:
//
//   PASS 1 (light's eye)  : render every caster from the light's ORTHOGRAPHIC
//                           point of view with the depth shader (mode 0, raw
//                           ndc*0.5+0.5) into a sampleable render texture -
//                           the "shadow map" (closest depth to the light).
//   PASS 2 (camera)       : render the scene from an orbiting perspective
//                           camera with `lit_shadow`, which projects each
//                           fragment into light space, samples the shadow
//                           map, and darkens fragments the light can't see.
//
// The static geometry (floor + boxes) is baked into one buffer drawn with an
// identity model. The bunny is a second object with its own buffers and a
// per-frame model matrix (spin about Y); `lit_shadow_vs` now carries a
// normal matrix so the bunny shades correctly as it turns. Two manual
// pipelines (depth + lit_shadow); the RTT round-trip uses the engine's
// `beginTextureMode`/`endTextureMode`. No inline WGSL - both shader pairs are
// authored in Zig (shadermath) and embedded as build artifacts.
//
// CANNOT be verified in the sandbox (no GPU); Simon verifies in the browser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const identity = zm.identity;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const normalize3 = zm.normalize3;
const orthographicRh = zm.orthographicRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

// The app-bridge instance: the one sanctioned wasm entry-point handle.
pub var zimr_app: z.App = .{};

// ============================================================================
// Scene geometry. `SceneVertex` (position + normal, stride 24) is shared by
// every object and by both pipelines.
// ============================================================================

const SceneVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };
const floor_half: f32 = 4.0;

const floor_verts = [_]SceneVertex{
    .{ .position = .{ -floor_half, 0, -floor_half }, .normal = up_n },
    .{ .position = .{ floor_half, 0, -floor_half }, .normal = up_n },
    .{ .position = .{ floor_half, 0, floor_half }, .normal = up_n },
    .{ .position = .{ -floor_half, 0, floor_half }, .normal = up_n },
};
const floor_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

// Unit-ish cube (half-extent `cs`); box placements scale it by `half / cs`.
const cs: f32 = 0.7;
const cube_verts = [_]SceneVertex{
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -cs, cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -cs, cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ cs, cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, cs, -cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, cs, cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, -cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, cs }, .normal = up_n },
    .{ .position = .{ cs, cs, cs }, .normal = up_n },
    .{ .position = .{ cs, cs, -cs }, .normal = up_n },
    .{ .position = .{ -cs, cs, -cs }, .normal = up_n },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ 0, -1, 0 } },
};
const cube_face_indices = [_]u16{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const CubePlace = struct { center: [3]f32, half: f32 };
const cubes = [_]CubePlace{
    .{ .center = .{ 2.3, 0.9, 1.4 }, .half = 0.9 },
    .{ .center = .{ 0.7, 1.7, -2.3 }, .half = 0.6 },
    .{ .center = .{ 2.7, 0.55, -2.5 }, .half = 0.55 },
    .{ .center = .{ -2.7, 1.15, -0.8 }, .half = 0.7 },
};

const static_vcount: usize = floor_verts.len + cubes.len * cube_verts.len;
const static_icount: usize = floor_indices.len + cubes.len * cube_face_indices.len;

// ---- Host mirrors of the shader uniform blocks -----------------------------

// depth_vs_io.Ubo (96 bytes) - light/depth pass.
const DepthUbo = struct {
    mvp: [4]Vec,
    params: Vec,
    mode: i32,
    pad0: i32 = 0,
    pad1: i32 = 0,
    pad2: i32 = 0,
};
// lit_shadow_vs_io.Ubo (192 bytes) - group 0.
const LitVsUbo = struct {
    mvp: [4]Vec,
    light_vp: [4]Vec,
    normal_matrix: [4]Vec,
};
// lit_shadow_fs_io.Ubo (32 bytes) - group 2.
const LitFsUbo = struct {
    light_dir: Vec,
    base_color: Vec,
    /// {bias_slope, bias_min, 0, 0} - f16-map bias (see lit_shadow_fs_io).
    params: Vec,
};

const depth_ubo_bytes: u64 = z.shader.wireSizeOf(DepthUbo);
const lit_vs_bytes: u64 = z.shader.wireSizeOf(LitVsUbo);
const lit_fs_bytes: u64 = z.shader.wireSizeOf(LitFsUbo);

const depth_vs_wgsl = @embedFile("depth_vs.wgsl");
const depth_fs_wgsl = @embedFile("depth_fs.wgsl");
const lit_vs_wgsl = @embedFile("lit_shadow_vs.wgsl");
const lit_fs_wgsl = @embedFile("lit_shadow_fs.wgsl");
const bunny_obj = @embedFile("bunny.obj");

const rt_size: i32 = 1024;

// One drawable object: its geometry buffers plus a private set of the three
// uniform blocks (depth / lit-VS / lit-FS) and their bind groups. The shadow
// sampler bind group (group 1 of the lit pass) is shared, not per-object.
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

    base_color: [4]f32,
};

const State = struct {
    rt: z.RenderTexture,

    // Interactive orbit camera (same behavior as damaged_helmet): drag to
    // orbit, wheel / pinch to zoom. The light stays fixed so the shadows are
    // stable while the camera moves around them.
    yaw: f32 = 0.7,
    pitch: f32 = 0.45,
    distance: f32 = 13.0,
    dragging: bool = false,
    prev_pinch: f32 = 0.0,

    depth_pipeline: z.wgpu.RenderPipelineHandle,
    lit_pipeline: z.wgpu.RenderPipelineHandle,
    lit_g1_bg: z.wgpu.BindGroupHandle, // shared shadow-map sampler (group 1)
    shadow_sampler: z.wgpu.SamplerHandle, // comparison sampler bound in lit_g1_bg

    static_obj: Obj, // floor + boxes, identity model
    bunny: Obj, // spinning caster, per-frame model matrix

    // Bunny placement: base-centered at load, spun about Y, scaled, seated.
    bunny_cx: f32,
    bunny_cz: f32,
    bunny_min_y: f32,
    bunny_scale: f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    // Two objects, each: vbo + ibo + three UBOs + three bind groups. Distinct
    // meshes, so no shared-handle double-free.
    for ([_]*const Obj{ &s.static_obj, &s.bunny }) |obj| {
        z.wgpu.destroyBuffer(obj.vbo);
        z.wgpu.destroyBuffer(obj.ibo);
        z.wgpu.destroyBuffer(obj.depth_ubo);
        z.wgpu.destroyBuffer(obj.lit_vs_ubo);
        z.wgpu.destroyBuffer(obj.lit_fs_ubo);
        z.wgpu.destroyBindGroup(obj.depth_bg);
        z.wgpu.destroyBindGroup(obj.lit_g0_bg);
        z.wgpu.destroyBindGroup(obj.lit_g2_bg);
    }
    z.wgpu.destroyBindGroup(s.lit_g1_bg);
    z.wgpu.destroyRenderPipeline(s.depth_pipeline);
    z.wgpu.destroyRenderPipeline(s.lit_pipeline);
    z.wgpu.destroySampler(s.shadow_sampler);
    s.rt.deinit();
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

// Create the three per-object uniform buffers + bind groups. Geometry buffers
// and base color are supplied by the caller.
fn makeObj(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    depth_bgl: z.wgpu.BindGroupLayoutHandle,
    lit_g0_bgl: z.wgpu.BindGroupLayoutHandle,
    lit_g2_bgl: z.wgpu.BindGroupLayoutHandle,
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
    base_color: [4]f32,
) !Obj {
    const depth_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = depth_ubo_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const depth_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, depth_bgl, depth_ubo, depth_ubo_bytes, "sm_obj_depth_bg");

    const lit_vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = lit_vs_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const lit_g0_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, lit_g0_bgl, lit_vs_ubo, lit_vs_bytes, "sm_obj_g0_bg");

    const lit_fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = lit_fs_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const lit_g2_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, lit_g2_bgl, lit_fs_ubo, lit_fs_bytes, "sm_obj_g2_bg");

    return .{
        .vbo = vbo,
        .ibo = ibo,
        .vbo_bytes = vbo_bytes,
        .ibo_bytes = ibo_bytes,
        .icount = icount,
        .depth_ubo = depth_ubo,
        .depth_bg = depth_bg,
        .lit_vs_ubo = lit_vs_ubo,
        .lit_g0_bg = lit_g0_bg,
        .lit_fs_ubo = lit_fs_ubo,
        .lit_g2_bg = lit_g2_bg,
        .base_color = base_color,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;
    const back_fmt: z.wgpu.TextureFormat = f.gpu.backbuffer_format;
    f.gpu.depth_format = .depth24_plus;

    // ---- Static geometry: floor + boxes into one world-space buffer ----
    var sverts: [static_vcount]SceneVertex = undefined;
    var sidxs: [static_icount]u16 = undefined;
    var vw: usize = 0;
    var iw: usize = 0;
    for (floor_verts) |v| {
        sverts[vw] = v;
        vw += 1;
    }
    for (floor_indices) |fi| {
        sidxs[iw] = fi;
        iw += 1;
    }
    for (cubes) |c| {
        const base: u16 = @intCast(vw);
        const sfac: f32 = c.half / cs;
        for (cube_verts) |v| {
            sverts[vw] = .{
                .position = .{
                    v.position[0] * sfac + c.center[0],
                    v.position[1] * sfac + c.center[1],
                    v.position[2] * sfac + c.center[2],
                },
                .normal = v.normal,
            };
            vw += 1;
        }
        for (cube_face_indices) |fi| {
            sidxs[iw] = base + fi;
            iw += 1;
        }
    }
    const static_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(sverts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "sm_static_vbo",
    );
    const static_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(sidxs[0..]),
        .{ .index = true, .copy_dst = true },
        "sm_static_ibo",
    );

    // ---- Bunny: parse OBJ, de-index + synthesize smooth normals, upload ----
    var bunny_data: z.codecs.obj.Data = try z.codecs.obj.parse(gpa, bunny_obj);
    defer bunny_data.deinit(gpa);
    const bunny_mesh: z.codecs.obj.Mesh = try bunny_data.toMesh(gpa);
    defer bunny_mesh.deinit(gpa);

    const bvc: usize = bunny_mesh.vertexCount();
    const bic: usize = bunny_mesh.indices.len;
    const bverts: []SceneVertex = try gpa.alloc(SceneVertex, bvc);
    defer gpa.free(bverts);

    var mn: [3]f32 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var mx: [3]f32 = .{ -1.0e30, -1.0e30, -1.0e30 };
    var vi: usize = 0;
    while (vi < bvc) : (vi += 1) {
        const p: [3]f32 = .{
            bunny_mesh.positions[vi * 3 + 0],
            bunny_mesh.positions[vi * 3 + 1],
            bunny_mesh.positions[vi * 3 + 2],
        };
        bverts[vi] = .{
            .position = p,
            .normal = .{
                bunny_mesh.normals[vi * 3 + 0],
                bunny_mesh.normals[vi * 3 + 1],
                bunny_mesh.normals[vi * 3 + 2],
            },
        };
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            if (p[k] < mn[k]) {
                mn[k] = p[k];
            }
            if (p[k] > mx[k]) {
                mx[k] = p[k];
            }
        }
    }
    const bidx: []u16 = try gpa.alloc(u16, bic);
    defer gpa.free(bidx);
    var ii: usize = 0;
    while (ii < bic) : (ii += 1) {
        bidx[ii] = @intCast(bunny_mesh.indices[ii]);
    }
    const bunny_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(bverts),
        .{ .vertex = true, .copy_dst = true },
        "sm_bunny_vbo",
    );
    // 208,353 indices * 2 bytes == 2 mod 4 -> createBufferInit pads the write.
    const bunny_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(bidx),
        .{ .index = true, .copy_dst = true },
        "sm_bunny_ibo",
    );

    const bunny_height: f32 = @max(mx[1] - mn[1], 1.0e-4);

    // ---- Render texture (shadow map): rgba16-FLOAT color + depth24plus.
    // A float color target stores the light-view depth at ~16-bit precision
    // (vs 256 levels for rgba8), which is what lets the shadow bias drop low
    // enough to avoid both acne and peter-panning. Sampled with a NEAREST
    // sampler below - linear filtering would blend depths across silhouette
    // edges and corrupt the comparison.
    const rt: z.RenderTexture = z.RenderTexture.create(device, .{
        .width = @intCast(rt_size),
        .height = @intCast(rt_size),
        .format = .rgba16_float,
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "sm_shadow_rt",
    });
    const shadow_sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .address_mode = .clamp_to_edge,
    });

    // ---- Vertex layouts (shared stride; depth reads position only) ----
    const pos_only_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(SceneVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        },
    };
    const pos_normal_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(SceneVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };

    // ---- Shared bind-group layouts ----
    const depth_g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, depth_ubo_bytes, .{ .vertex = true }, "sm_depth_g0");
    const lit_g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, lit_vs_bytes, .{ .vertex = true }, "sm_lit_g0");
    const lit_g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, lit_fs_bytes, .{ .fragment = true }, "sm_lit_g2");

    const shadow_tex: z.WgpuTexture = rt.asTexture();
    const g1_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_layout_entries);
    defer gpa.free(g1_layout_blob);
    const lit_g1_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g1_layout_blob, "sm_lit_g1");
    const g1_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = shadow_tex.view } },
        .{ .binding = 1, .resource = .{ .sampler = shadow_sampler } },
    };
    const g1_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g1_entries);
    defer gpa.free(g1_blob);
    const lit_g1_bg: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, lit_g1_bgl, g1_blob, "sm_lit_g1_bg");

    // ---- Depth / light pass pipeline ----
    const depth_bgls: [1]z.wgpu.BindGroupLayoutHandle = .{depth_g0_bgl};
    const depth_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, depth_bgls[0..], "sm_depth_pl");
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
        "sm_depth_pipe",
    );

    // ---- Main lit_shadow pass pipeline ----
    const lit_bgls: [3]z.wgpu.BindGroupLayoutHandle = .{ lit_g0_bgl, lit_g1_bgl, lit_g2_bgl };
    const lit_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, lit_bgls[0..], "sm_lit_pl");
    const lit_vs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lit_vs_wgsl, "lit_shadow_vs");
    const lit_fs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lit_fs_wgsl, "lit_shadow_fs");
    // Cull .none until the winding of every caster is device-confirmed; back
    // faces are depth-occluded anyway. Tighten to .back once verified clean.
    const lit_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less,
        .none,
        back_fmt,
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
        "sm_lit_pipe",
    );

    const static_obj: Obj = try makeObj(
        gpa,
        device,
        depth_g0_bgl,
        lit_g0_bgl,
        lit_g2_bgl,
        static_vbo,
        static_ibo,
        @sizeOf(@TypeOf(sverts)),
        @sizeOf(@TypeOf(sidxs)),
        @intCast(static_icount),
        .{ 0.82, 0.82, 0.88, 1.0 },
    );
    const bunny: Obj = try makeObj(
        gpa,
        device,
        depth_g0_bgl,
        lit_g0_bgl,
        lit_g2_bgl,
        bunny_vbo,
        bunny_ibo,
        bvc * @sizeOf(SceneVertex),
        bic * @sizeOf(u16),
        @intCast(bic),
        .{ 0.86, 0.72, 0.52, 1.0 },
    );

    s.* = .{
        .rt = rt,
        .depth_pipeline = depth_pipeline,
        .lit_pipeline = lit_pipeline,
        .lit_g1_bg = lit_g1_bg,
        .shadow_sampler = shadow_sampler,
        .static_obj = static_obj,
        .bunny = bunny,
        .bunny_cx = (mn[0] + mx[0]) * 0.5,
        .bunny_cz = (mn[2] + mx[2]) * 0.5,
        .bunny_min_y = mn[1],
        .bunny_scale = 2.8 / bunny_height,
    };

    // Build-only intermediates: the pipelines + bind groups have internalized
    // these layouts/modules, so they can be released now.
    z.wgpu.destroyShaderModule(depth_vs_mod);
    z.wgpu.destroyShaderModule(depth_fs_mod);
    z.wgpu.destroyShaderModule(lit_vs_mod);
    z.wgpu.destroyShaderModule(lit_fs_mod);
    z.wgpu.destroyPipelineLayout(depth_pl);
    z.wgpu.destroyPipelineLayout(lit_pl);
    z.wgpu.destroyBindGroupLayout(depth_g0_bgl);
    z.wgpu.destroyBindGroupLayout(lit_g0_bgl);
    z.wgpu.destroyBindGroupLayout(lit_g2_bgl);
    z.wgpu.destroyBindGroupLayout(lit_g1_bgl);
}

fn drawMesh(rps: *z.PassState, obj: *const Obj) void {
    z.render_pass.setVertexBuffer(rps.pass, .{
        .slot = 0,
        .buffer = obj.vbo,
        .offset = 0,
        .size = obj.vbo_bytes,
    });
    z.render_pass.setIndexBuffer(rps.pass, .{
        .buffer = obj.ibo,
        .format = .uint16,
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

fn writeObjUniforms(
    gf: *z.GpuFrame,
    obj: *const Obj,
    model: Mat,
    normal_matrix: Mat,
    cam_vp: Mat,
    light_vp: Mat,
    to_light: Vec,
) void {
    const depth_ubo: DepthUbo = .{
        .mvp = mulMat(light_vp, model),
        .params = .{ 1.0, 20.0, 0.0, 1.0 },
        .mode = 0,
    };
    const depth_bytes: [z.shader.wireSizeOf(DepthUbo)]u8 = z.shader.wireOf(DepthUbo, &depth_ubo);
    z.wgpu.queueWriteBuffer(gf.queue, obj.depth_ubo, 0, &depth_bytes);

    const lit_vs: LitVsUbo = .{
        .mvp = mulMat(cam_vp, model),
        .light_vp = mulMat(light_vp, model),
        .normal_matrix = normal_matrix,
    };
    const lit_vs_data: [z.shader.wireSizeOf(LitVsUbo)]u8 = z.shader.wireOf(LitVsUbo, &lit_vs);
    z.wgpu.queueWriteBuffer(gf.queue, obj.lit_vs_ubo, 0, &lit_vs_data);

    const lit_fs: LitFsUbo = .{
        .light_dir = .{ to_light[0], to_light[1], to_light[2], 0.0 },
        .base_color = obj.base_color,
        .params = .{ 0.0025, 0.0008, 0, 0 },
    };
    const lit_fs_data: [z.shader.wireSizeOf(LitFsUbo)]u8 = z.shader.wireOf(LitFsUbo, &lit_fs);
    z.wgpu.queueWriteBuffer(gf.queue, obj.lit_fs_ubo, 0, &lit_fs_data);
}

fn update(f: *z.Frame, s: *State) void {
    const gf: *z.GpuFrame = f.gpu;
    const Backend: type = z.WgpuBackend;
    const t: f32 = f.time.time;

    // Light target (kept at the verified framing so the shadow map is stable).
    const target: Vec = vec(0, 0.5, 0);

    // Fixed directional light (stable shadow) + orthographic frustum.
    const light_pos: Vec = vec(5.0, 7.0, 4.0);
    const light_view: Mat = lookAtRh(light_pos, target, vec(0, 1, 0));
    const light_proj: Mat = orthographicRh(13.0, 13.0, 1.0, 20.0);
    const light_vp: Mat = mulMat(light_proj, light_view);
    const to_light: Vec = normalize3(light_pos - target);

    // ---- Interactive orbit camera (same behavior as damaged_helmet):
    // pinch / wheel to zoom, one-finger / mouse drag to orbit.
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.distance = clamp(s.distance - (dist - s.prev_pinch) * 0.02, 5.0, 26.0);
        }
        s.prev_pinch = dist;
    } else {
        s.prev_pinch = 0;
    }
    if (touches < 2 and z.isMouseButtonDown(f.input, .left)) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.yaw -= d[0] * 0.008;
            s.pitch = clamp(s.pitch + d[1] * 0.008, 0.1, 1.45);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.distance = clamp(s.distance - wheel * 0.6, 5.0, 26.0);
    }

    const cam_target: Vec = vec(0, 1.0, 0);
    const cp: f32 = @cos(s.pitch);
    const sp: f32 = @sin(s.pitch);
    const cy: f32 = @cos(s.yaw);
    const sy: f32 = @sin(s.yaw);
    const cam_eye: Vec = vec(
        cam_target[0] + s.distance * cp * sy,
        cam_target[1] + s.distance * sp,
        cam_target[2] + s.distance * cp * cy,
    );
    const cam_view: Mat = lookAtRh(cam_eye, cam_target, vec(0, 1, 0));
    const aspect: f32 = f.window.widthf() / @max(f.window.heightf(), 1.0);
    const cam_proj: Mat = perspectiveFovRh(0.8, aspect, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    // ---- Object model matrices ----
    const id: Mat = identity();

    // Bunny: base-center -> spin about Y -> scale -> seat on the floor.
    const spin: Mat = rotationY(t * 0.6);
    const bunny_spot: Vec = vec(-1.4, 0.0, 1.7);
    const center_it: Mat = translation(-s.bunny_cx, -s.bunny_min_y, -s.bunny_cz);
    const scale_it: Mat = scaling(s.bunny_scale, s.bunny_scale, s.bunny_scale);
    const place_it: Mat = translation(bunny_spot[0], bunny_spot[1], bunny_spot[2]);
    const bunny_model: Mat = mulMat(place_it, mulMat(scale_it, mulMat(spin, center_it)));

    writeObjUniforms(gf, &s.static_obj, id, id, cam_vp, light_vp, to_light);
    writeObjUniforms(gf, &s.bunny, bunny_model, spin, cam_vp, light_vp, to_light);

    // ============ PASS 1: shadow map (light's eye -> RTT) ============
    // Raw offscreen pass: the shadow map is rgba16_float and we draw it with
    // our own depth pipeline, so we must NOT let beginTextureMode bind the 2D
    // (rgba8) pipeline into this pass - that is an attachment-format mismatch.
    z.beginTextureModeRaw(f.gl, s.rt, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const p1: *z.PassState = f.gl.pass;
    Backend.setPipeline(p1, z.shader.RenderPipeline(void, void){ .gpu_handle = s.depth_pipeline });
    Backend.setBindGroup(p1, 0, s.static_obj.depth_bg);
    drawMesh(p1, &s.static_obj);
    Backend.setBindGroup(p1, 0, s.bunny.depth_bg);
    drawMesh(p1, &s.bunny);
    z.endTextureModeRaw(f.gl);

    // ============ SCREEN: open the frame, PASS 2 renders the lit scene into it ======
    z.beginDrawing(f.gl);

    // ============ PASS 2: lit scene + shadow (camera -> screen) ======
    const p2: *z.PassState = f.gl.pass;
    p2.queue = gf.queue;
    Backend.setPipeline(p2, z.shader.RenderPipeline(void, void){ .gpu_handle = s.lit_pipeline });
    Backend.setBindGroup(p2, 1, s.lit_g1_bg);
    Backend.setBindGroup(p2, 0, s.static_obj.lit_g0_bg);
    Backend.setBindGroup(p2, 2, s.static_obj.lit_g2_bg);
    drawMesh(p2, &s.static_obj);
    Backend.setBindGroup(p2, 0, s.bunny.lit_g0_bg);
    Backend.setBindGroup(p2, 2, s.bunny.lit_g2_bg);
    drawMesh(p2, &s.bunny);

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - shadow map",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.10, .g = 0.11, .b = 0.14, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Shadow-map depth pass runs offscreen before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
