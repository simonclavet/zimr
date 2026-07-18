// examples/depth_rendering/depth_rendering.zig
//
// shaders_depth_rendering (Route 1: depth-as-colour). Renders a
// depth-tested 3D scene and writes each fragment's normalized device
// depth straight into the colour buffer as grayscale (near = dark, far
// = light). This is the per-PIXEL depth port (distinct from the
// per-OBJECT `depth_cue` CPU tint): the depth comes out of the depth
// shader's fragment stage.
//
// Why this exists as a milestone: the `depth_vs` + `depth_fs` pair it
// drives is the SAME "depth-in-red" primitive the shadow-map light
// pass needs (pbr_fs.computeShadow samples exactly this value as
// `closest_depth`). Proving it renders here de-risks the shadow pass.
//
// Custom single-group pipeline (simpler than lambert_demo — no
// samplers, no FS uniforms; the only binding is the VS's mvp UBO at
// group 0). The WebGPU binding model is documented in src/zimr.zig.
//
// CANNOT be verified in the sandbox (no GPU); Simon verifies in the
// browser. Build-side contract: compiles clean, embedded WGSL is
// naga-valid (wgsl_strict), node link-check instantiates, lint 0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const vec = zm.vec;

// ============================================================================
// Scene geometry: three unit cubes staggered in depth so the grayscale
// gradient reads clearly (a nearer cube is visibly darker than a far one).
// Positions are baked into ONE world-space vertex buffer and drawn in a
// single call, so the shader needs only view-projection (no per-object
// model uniform, which a single shared UBO could not express per draw).
// ============================================================================

const DepthVertex = extern struct {
    position: [3]f32,
};

const hs: f32 = 0.6;

// 24 corners (4 per face) of a unit cube centred at the origin, CCW from
// outside. Only position is needed — the depth shader reads location 0.
const cube_corners = [_][3]f32{
    // +Z
    .{ -hs, -hs, hs },  .{ hs, -hs, hs },   .{ hs, hs, hs },   .{ -hs, hs, hs },
    // -Z
    .{ hs, -hs, -hs },  .{ -hs, -hs, -hs }, .{ -hs, hs, -hs }, .{ hs, hs, -hs },
    // +X
    .{ hs, -hs, hs },   .{ hs, -hs, -hs },  .{ hs, hs, -hs },  .{ hs, hs, hs },
    // -X
    .{ -hs, -hs, -hs }, .{ -hs, -hs, hs },  .{ -hs, hs, hs },  .{ -hs, hs, -hs },
    // +Y
    .{ -hs, hs, hs },   .{ hs, hs, hs },    .{ hs, hs, -hs },  .{ -hs, hs, -hs },
    // -Y
    .{ -hs, -hs, -hs }, .{ hs, -hs, -hs },  .{ hs, -hs, hs },  .{ -hs, -hs, hs },
};

const face_indices = [_]u16{
    0, 1, 2, 0, 2, 3, // +Z
    4, 5, 6, 4, 6, 7, // -Z
    8, 9, 10, 8, 10, 11, // +X
    12, 13, 14, 12, 14, 15, // -X
    16, 17, 18, 16, 18, 19, // +Y
    20, 21, 22, 20, 22, 23, // -Y
};

// World placements: near-centre, far-left, far-right.
const cube_offsets = [_][3]f32{
    .{ 0.0, 0.0, 1.6 },
    .{ -1.7, 0.0, -1.8 },
    .{ 1.7, 0.0, -1.8 },
};

const vertex_count: usize = cube_corners.len * cube_offsets.len;
const index_count: usize = face_indices.len * cube_offsets.len;

// Host mirror of `depth_vs_io.Ubo` — must match byte-for-byte (96 bytes).
const DepthUbo = struct {
    mvp: [4]Vec,
    params: Vec,
    mode: i32,
    pad0: i32 = 0,
    pad1: i32 = 0,
    pad2: i32 = 0,
};
const ubo_bytes: u64 = z.shader.wireSizeOf(DepthUbo); // 96

const depth_vs_wgsl = @embedFile("depth_vs.wgsl");
const depth_fs_wgsl = @embedFile("depth_fs.wgsl");

// ============================================================================
// Persistent state
// ============================================================================

pub var zimr_app: z.App = .{};

const State = struct {
    ubo_buffer: z.wgpu.BufferHandle,
    group0_bind_group: z.wgpu.BindGroupHandle,
    pipeline: z.wgpu.RenderPipelineHandle,
    pipeline_layout: z.wgpu.PipelineLayoutHandle,
    vs_module: z.wgpu.ShaderModuleHandle,
    fs_module: z.wgpu.ShaderModuleHandle,
    vertex_buffer: z.wgpu.BufferHandle,
    index_buffer: z.wgpu.BufferHandle,
};

// ============================================================================
// Init
// ============================================================================

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;
    const fmt: z.wgpu.TextureFormat = f.gpu.backbuffer_format;
    f.gpu.depth_format = .depth24_plus;

    // ---- Bake the three cubes into one world-space vertex + index buffer ----
    var verts: [vertex_count]DepthVertex = undefined;
    var idxs: [index_count]u16 = undefined;
    var vw: usize = 0;
    var iw: usize = 0;
    for (cube_offsets) |off| {
        const base: u16 = @intCast(vw);
        for (cube_corners) |c| {
            verts[vw] = .{ .position = .{ c[0] + off[0], c[1] + off[1], c[2] + off[2] } };
            vw += 1;
        }
        for (face_indices) |fi| {
            idxs[iw] = base + fi;
            iw += 1;
        }
    }

    const vertex_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(@TypeOf(verts)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "depth_vbo",
    });
    z.wgpu.queueWriteBuffer(queue, vertex_buffer, 0, std.mem.sliceAsBytes(&verts));

    const index_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(@TypeOf(idxs)),
        .usage = .{ .index = true, .copy_dst = true },
        .label = "depth_ibo",
    });
    z.wgpu.queueWriteBuffer(queue, index_buffer, 0, std.mem.sliceAsBytes(&idxs));

    // ---- Vertex layout: position only (location 0). ----
    const depth_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(DepthVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        },
    };

    // ---- group 0: the VS mvp UBO (single binding, vertex-visible). ----
    const ubo_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = ubo_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const g0_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .resource = .{ .uniform_buffer = .{ .min_size = ubo_bytes } },
        },
    };
    const g0_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g0_layout_entries);
    defer gpa.free(g0_layout_blob);
    const g0_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g0_layout_blob, "depth_g0");

    const g0_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = ubo_buffer, .size = ubo_bytes } } },
    };
    const g0_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g0_entries);
    defer gpa.free(g0_blob);
    const group0_bind_group: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g0_bgl, g0_blob, "depth_g0_bg");

    // ---- Pipeline layout: single bind group. ----
    const bgls: [1]z.wgpu.BindGroupLayoutHandle = .{g0_bgl};
    const pipeline_layout: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, bgls[0..], "depth_pl");

    const vs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, depth_vs_wgsl, "depth_vs");
    const fs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, depth_fs_wgsl, "depth_fs");

    const state_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less, // depth test LESS
        .back, // cull back faces (CCW from outside)
        fmt,
        .depth24_plus,
        1,
    );
    const pipe_desc = z.gpu.RenderPipelineDescriptor{
        .vertex_buffer_layouts = &.{depth_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = state_combo,
    };
    const pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, pipe_desc);
    defer gpa.free(pipe_blob);
    const pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        pipeline_layout,
        vs_module,
        fs_module,
        pipe_blob,
        "depth_pipe",
    );

    s.* = .{
        .ubo_buffer = ubo_buffer,
        .group0_bind_group = group0_bind_group,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .vs_module = vs_module,
        .fs_module = fs_module,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
    };
}

// ============================================================================
// Frame
// ============================================================================

fn update(f: *z.Frame, s: *State) void {
    const gf: *z.GpuFrame = f.gpu;
    const Backend: type = z.WgpuBackend;

    // Slowly orbit the camera so the depth ordering of the cubes is legible.
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();
    const eye_spin: Mat = rotationY(t * 0.3);
    const eye0: Vec = .{ 0.0, 2.2, 5.2, 1.0 };
    const eye4: Vec = mulMatVec(eye_spin, eye0);

    const view: Mat = lookAtRh(
        vec(eye4[0], eye4[1], eye4[2]),
        vec(0, 0, 0),
        vec(0, 1, 0),
    );
    const cam_near: f32 = 0.5;
    const cam_far: f32 = 20.0;
    const proj: Mat = perspectiveFovRh(0.9, aspect, cam_near, cam_far);
    const mvp: Mat = mulMat(proj, view);

    // mode 1 = linearized/normalized viz. The viz window [3.5, 8.5]
    // tightly brackets the cubes' view-space distances so the grayscale
    // gradient uses the full range (near cube dark, far cubes light).
    const ubo: DepthUbo = .{
        .mvp = mvp,
        .params = .{ cam_near, cam_far, 3.0, 11.0 },
        .mode = 1,
    };
    const ubo_bytes_buf: [z.shader.wireSizeOf(DepthUbo)]u8 = z.shader.wireOf(DepthUbo, &ubo);
    z.wgpu.queueWriteBuffer(gf.queue, s.ubo_buffer, 0, &ubo_bytes_buf);

    const fctx = Backend.beginFrame(gf);
    var ps = Backend.beginRenderPass(fctx.encoder, .{
        .color_view = fctx.surface_view,
        .clear = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
        .depth_view = fctx.depth_view,
    });
    ps.queue = gf.queue;

    Backend.setPipeline(&ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(&ps, 0, s.group0_bind_group);

    z.render_pass.setVertexBuffer(ps.pass, .{
        .slot = 0,
        .buffer = s.vertex_buffer,
        .offset = 0,
        .size = @sizeOf([vertex_count]DepthVertex),
    });
    z.render_pass.setIndexBuffer(ps.pass, .{
        .buffer = s.index_buffer,
        .format = .uint16,
        .offset = 0,
        .size = @sizeOf([index_count]u16),
    });
    z.render_pass.drawIndexed(ps.pass, .{
        .index_count = index_count,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    });

    Backend.endRenderPass(&ps);
    Backend.endFrame(gf);
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{ .title = "zimr - WebGPU - depth rendering", .width = 800, .height = 600 },
    }, State, initState, update);
}
