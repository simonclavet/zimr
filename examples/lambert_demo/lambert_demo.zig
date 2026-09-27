// examples/lambert_demo/lambert_demo.zig
//
// Canonical MULTI-GROUP wgpu example (section 4(b) of the architecture doc):
// the Lambert-lit cube, binding VS uniforms (group 0), a sampler
// (group 1), and an FS uniform (group 2) by hand.  The WebGPU
// architecture - especially the stage-segregated binding model that
// makes this layout necessary - is documented centrally in
// src/zimr.zig.  Read that before changing this demo.
//
// The first 3D-on-wgpu demo: a textured spinning cube, depth-tested,
// drawn through the WebGPU backend (not GL).  This is section 4.A of
// `src/notes/finishing_webgpu.md` - the linchpin that proves the
// 3D draw path renders end-to-end before lambert/PBR/the helmet.
//
// What's new vs the 2D wgpu_bringup:
//   - a DEPTH texture (depth24plus) created + threaded into the
//     render pass (2D never needed depth);
//   - a 3D vertex-buffer layout (interleaved position+uv) passed via
//     ShaderDesc.vertex_buffer_layouts (the override added this arc);
//   - an MVP matrix pushed to the VS UBO each frame
//     (perspective x view x model-rotation).
//
// Reuses the cube_split VS+FS shader pair (already typed +
// naga-valid): cube_split_vs_io declares `Ubo.mvp`, cube_split_fs
// samples texture0.  Same source the GL+CPU cube_split demo uses -
// here it runs through spv2wgsl -> WGSL -> wgpu.
//
// Build:    zig build wgpu-cube-demo
// Serve:    bun run webtests/server.ts --web-dir=zig-out/wgpu-cube
// Browse:   http://localhost:8000/index.html
//
// CANNOT be verified in the sandbox (no GPU); Simon verifies the
// spinning cube in the browser.  The build-side contract: compiles
// clean, the embedded WGSL is naga-valid, lint 0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const vec = zm.vec;

// ============================================================================
// Cube geometry (reused from examples/cube_split.zig)
// ============================================================================
//
// 24 vertices (4 per face) so each face gets clean UVs; 36 indices.
// Interleaved position(vec3) + tex_coord(vec2) -> ONE vertex buffer,
// stride 20 bytes (3*4 + 2*4).  CCW winding from outside.

const LitVertex = extern struct {
    position: [3]f32,
    tex_coord: [2]f32,
    normal: [3]f32,
};

const half_size: f32 = 0.7;

const cube_vertices = [_]LitVertex{
    // +Z face (front)
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ 0, 0, 1 } },
    // -Z face (back)
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ 0, 0, -1 } },
    // +X face (right)
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ 1, 0, 0 } },
    // -X face (left)
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ -1, 0, 0 } },
    // +Y face (top)
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ 0, 1, 0 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ 0, 1, 0 } },
    // -Y face (bottom)
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 1, 0 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 0, 0 }, .normal = .{ 0, -1, 0 } },
};

const cube_indices = [_]u32{
    0, 1, 2, 0, 2, 3, // +Z
    4, 5, 6, 4, 6, 7, // -Z
    8, 9, 10, 8, 10, 11, // +X
    12, 13, 14, 12, 14, 15, // -X
    16, 17, 18, 16, 18, 19, // +Y
    20, 21, 22, 20, 22, 23, // -Y
};

// ============================================================================
// Combined cube schema (Ubo + Samplers -> two bind groups)
// ============================================================================
//
// cube_split's VS UBO (mvp) lands at @group(0) and its FS texture0 at
// @group(1) (the shader was built so the sampler sits in group 1 -
// confirmed in its WGSL).  loadShader's single-schema path only wires
// ONE bind group, so it can't drive this two-group layout.  Instead we
// use `Resources(LambertSchema)` + an explicit pipeline, exactly like
// Renderer2D: the schema declares BOTH `Ubo` and `Samplers`, Resources
// builds a bind-group-layout per group (bg_layouts[0]=UBO,
// bg_layouts[1]=sampler), and we chain both into the pipeline layout.
// ============================================================================
// Persistent state
// ============================================================================

pub var zimr_app: z.App = .{};

const State = struct {

    // The engine emits each loose uniform as its own binding (a one-field
    // uniform block per field), so lambert's VS uniforms are TWO bindings at
    // group 0 - `mvp` @binding(0) + `mat_model` @binding(1) - not one buffer.
    // (Confirmed in the emitted WGSL.)  `Resources` models one UBO
    // buffer per group, so it can't drive this; we build the bind
    // groups explicitly: two uniform buffers at group 0, texture+sampler
    // at group 1.  col_diffuse (@group0 @binding... in the FS) is a
    // third uniform - see init.
    mvp_buffer: z.wgpu.BufferHandle,
    model_buffer: z.wgpu.BufferHandle,
    col_diffuse_buffer: z.wgpu.BufferHandle,
    group0_bind_group: z.wgpu.BindGroupHandle,
    group1_bind_group: z.wgpu.BindGroupHandle,
    group2_bind_group: z.wgpu.BindGroupHandle,

    pipeline: z.wgpu.RenderPipelineHandle,
    pipeline_layout: z.wgpu.PipelineLayoutHandle,
    vs_module: z.wgpu.ShaderModuleHandle,
    fs_module: z.wgpu.ShaderModuleHandle,
    lit_texture: z.WgpuTexture,

    vertex_buffer: z.wgpu.BufferHandle,
    index_buffer: z.wgpu.BufferHandle,
};

const Mat4 = [4]@Vector(4, f32);
const mat4_bytes: u64 = @sizeOf(Mat4); // 64

const lambert_vs_wgsl = @embedFile("lambert_vs.wgsl");
const lambert_fs_wgsl = @embedFile("lambert_fs.wgsl");

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
    // The GpuFrame owns the depth texture and auto-resizes it to the surface
    // each frame; just set the format (see GpuFrame.ensureDepth).
    f.gpu.depth_format = .depth24_plus;

    // ---- Checkerboard texture (stand-in for a real albedo map) ----
    const lit_texture: z.WgpuTexture = try z.WgpuTexture.createCheckerboard(
        device,
        queue,
        gpa,
        .{ 0xff, 0xff, 0xff, 0xff },
        .{ 0x33, 0x66, 0xcc, 0xff },
        64,
        8,
    );

    // ---- Cube vertex + index buffers ----
    const vertex_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(@TypeOf(cube_vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "cube_vbo",
    });
    z.wgpu.queueWriteBuffer(queue, vertex_buffer, 0, std.mem.sliceAsBytes(&cube_vertices));

    const index_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(@TypeOf(cube_indices)),
        .usage = .{ .index = true, .copy_dst = true },
        .label = "cube_ibo",
    });
    z.wgpu.queueWriteBuffer(queue, index_buffer, 0, std.mem.sliceAsBytes(&cube_indices));

    // ---- 3D vertex-buffer layout: ONE interleaved buffer ----
    // slot 0, stride 20: position vec3 @0 (offset 0), tex_coord vec2 @1 (offset 12).
    const cube_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(LitVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
            .{ .format = .float32x3, .offset = 20, .shader_location = 2 },
        },
    };

    // ---- Explicit bind groups (NOT Resources - see note below) ----
    // The engine now emits stage-segregated uniform groups (the
    // toolchain fix for the cross-stage binding collision):
    //   group 0 = VS uniforms: mvp@0, mat_model@1
    //   group 1 = samplers:    texture0@0, sampler@1
    //   group 2 = FS uniforms:  col_diffuse@0
    // (Confirmed in the emitted, naga-valid WGSL.)  Resources models one
    // UBO buffer per group at a single binding, so it can't express the
    // multi-binding group 0 or the split across three groups - we build
    // the bind groups by hand.
    const mvp_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = mat4_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const model_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = mat4_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const col_diffuse_buffer: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(Vec),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    // White diffuse tint (col_diffuse stays constant this demo).
    const white: Vec = .{ 1, 1, 1, 1 };
    z.wgpu.queueWriteBuffer(queue, col_diffuse_buffer, 0, std.mem.asBytes(&white));

    // group 0 layout: VS uniforms - mvp@0, mat_model@1.
    const g0_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .resource = .{ .uniform_buffer = .{ .min_size = mat4_bytes } },
        },
        .{
            .binding = 1,
            .visibility = .{ .vertex = true },
            .resource = .{ .uniform_buffer = .{ .min_size = mat4_bytes } },
        },
    };
    const g0_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g0_layout_entries);
    defer gpa.free(g0_layout_blob);
    const g0_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g0_layout_blob, "lambert_g0");

    const g0_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = mvp_buffer, .size = mat4_bytes } } },
        .{ .binding = 1, .resource = .{ .buffer = .{ .handle = model_buffer, .size = mat4_bytes } } },
    };
    const g0_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g0_entries);
    defer gpa.free(g0_blob);
    const group0_bind_group: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g0_bgl, g0_blob, "lambert_g0_bg");

    // group 1 layout: texture0@0 + sampler@1.
    const g1_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_layout_entries);
    defer gpa.free(g1_layout_blob);
    const g1_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g1_layout_blob, "lambert_g1");

    const g1_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = lit_texture.view } },
        .{ .binding = 1, .resource = .{ .sampler = lit_texture.sampler } },
    };
    const g1_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g1_entries);
    defer gpa.free(g1_blob);
    const group1_bind_group: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g1_bgl, g1_blob, "lambert_g1_bg");

    // group 2 layout: FS uniform - col_diffuse@0.
    const g2_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .fragment = true },
            .resource = .{ .uniform_buffer = .{ .min_size = 16 } },
        },
    };
    const g2_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g2_layout_entries);
    defer gpa.free(g2_layout_blob);
    const g2_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g2_layout_blob, "lambert_g2");

    const g2_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = col_diffuse_buffer, .size = 16 } } },
    };
    const g2_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g2_entries);
    defer gpa.free(g2_blob);
    const group2_bind_group: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g2_bgl, g2_blob, "lambert_g2_bg");

    // ---- Pipeline layout chains all three bind-group layouts ----
    const bgls: [3]z.wgpu.BindGroupLayoutHandle = .{ g0_bgl, g1_bgl, g2_bgl };
    const pipeline_layout: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, bgls[0..], "lambert_pl");

    // ---- Shader modules ----
    const vs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lambert_vs_wgsl, "lambert_vs");
    const fs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, lambert_fs_wgsl, "lambert_fs");

    // ---- Render pipeline: depth-tested, back-face culled, 3D layout ----
    const state_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less, // depth test (LESS)
        .back, // cull back faces (cube_split is CCW-from-outside)
        fmt,
        .depth24_plus,
        1,
    );
    const pipe_desc = z.gpu.RenderPipelineDescriptor{
        .vertex_buffer_layouts = &.{cube_layout},
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
        "lambert_pipe",
    );
    s.* = .{
        .mvp_buffer = mvp_buffer,
        .model_buffer = model_buffer,
        .col_diffuse_buffer = col_diffuse_buffer,
        .group0_bind_group = group0_bind_group,
        .group1_bind_group = group1_bind_group,
        .group2_bind_group = group2_bind_group,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .vs_module = vs_module,
        .fs_module = fs_module,
        .lit_texture = lit_texture,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const gf: *z.GpuFrame = f.gpu;
    const Backend: type = z.WgpuBackend;

    // ---- MVP: perspective x view x model(rotate over time) ----
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    const model: Mat = mulMat(
        rotationY(t * 0.8),
        rotationX(t * 0.5),
    );
    const view: Mat = lookAtRh(
        vec(0, 0, 3.0), // eye, 3 units back
        vec(0, 0, 0), // target = origin
        vec(0, 1, 0), // up
    );
    const proj: Mat = perspectiveFovRh(
        0.9, // fovy radians (~52 deg)
        aspect,
        0.1, // near
        100.0, // far
    );
    const mvp: Mat = mulMat(proj, mulMat(view, model));

    // Push mvp + mat_model to their separate uniform buffers (the engine
    // emits one binding per uniform, so two buffers, not one struct).
    z.wgpu.queueWriteBuffer(gf.queue, s.mvp_buffer, 0, std.mem.asBytes(&mvp));
    z.wgpu.queueWriteBuffer(gf.queue, s.model_buffer, 0, std.mem.asBytes(&model));

    // ---- Frame ----
    const fctx = Backend.beginFrame(gf);
    var ps = Backend.beginRenderPass(fctx.encoder, .{
        .color_view = fctx.surface_view,
        .clear = .{ .r = 0.05, .g = 0.06, .b = 0.10, .a = 1.0 },
        .depth_view = fctx.depth_view,
    });
    ps.queue = gf.queue;

    // Bind the lambert pipeline + all three bind groups (group 0 = VS
    // uniforms, group 1 = texture+sampler, group 2 = FS uniform).
    Backend.setPipeline(&ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(&ps, 0, s.group0_bind_group);
    Backend.setBindGroup(&ps, 1, s.group1_bind_group);
    Backend.setBindGroup(&ps, 2, s.group2_bind_group);

    // Bind cube geometry + draw all 36 indices.
    z.render_pass.setVertexBuffer(ps.pass, .{
        .slot = 0,
        .buffer = s.vertex_buffer,
        .offset = 0,
        .size = @sizeOf(@TypeOf(cube_vertices)),
    });
    z.render_pass.setIndexBuffer(ps.pass, .{
        .buffer = s.index_buffer,
        .format = .uint32,
        .offset = 0,
        .size = @sizeOf(@TypeOf(cube_indices)),
    });
    z.render_pass.drawIndexed(ps.pass, .{
        .index_count = cube_indices.len,
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
        .window = .{ .title = "zimr - WebGPU - Lambert-lit cube", .width = 800, .height = 600 },
    }, State, initState, update);
}

// ============================================================================
// Frame
// ============================================================================
