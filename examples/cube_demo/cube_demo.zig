// examples/cube_demo/cube_demo.zig
//
// The unlit cube (section 4.A / section 4(a) of the architecture doc): a SINGLE-UBO
// 3D demo using the Resources(Schema) path.  WebGPU architecture is
// documented centrally in src/zimr.zig - read that first.
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
const si = @import("shader_interface");

// ============================================================================
// Cube geometry (reused from examples/cube_split.zig)
// ============================================================================
//
// 24 vertices (4 per face) so each face gets clean UVs; 36 indices.
// Interleaved position(vec3) + tex_coord(vec2) -> ONE vertex buffer,
// stride 20 bytes (3*4 + 2*4).  CCW winding from outside.

const CubeVertex = extern struct {
    position: [3]f32,
    tex_coord: [2]f32,
};

const half_size: f32 = 0.7;

const cube_vertices = [_]CubeVertex{
    // +Z face (front)
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 0, 0 } },
    // -Z face (back)
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 } },
    // +X face (right)
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 0, 0 } },
    // -X face (left)
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 } },
    // +Y face (top)
    .{ .position = .{ -half_size, half_size, half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ half_size, half_size, half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ half_size, half_size, -half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ -half_size, half_size, -half_size }, .tex_coord = .{ 0, 0 } },
    // -Y face (bottom)
    .{ .position = .{ -half_size, -half_size, -half_size }, .tex_coord = .{ 0, 1 } },
    .{ .position = .{ half_size, -half_size, -half_size }, .tex_coord = .{ 1, 1 } },
    .{ .position = .{ half_size, -half_size, half_size }, .tex_coord = .{ 1, 0 } },
    .{ .position = .{ -half_size, -half_size, half_size }, .tex_coord = .{ 0, 0 } },
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
// use `Resources(CubeSchema)` + an explicit pipeline, exactly like
// Renderer2D: the schema declares BOTH `Ubo` and `Samplers`, Resources
// builds a bind-group-layout per group (bg_layouts[0]=UBO,
// bg_layouts[1]=sampler), and we chain both into the pipeline layout.
const CubeSchema = struct {
    /// VS UBO - the MVP matrix (group 0, binding 0).  Same shape as
    /// cube_split_vs_io.Ubo (mat4 = [4]@Vector(4,f32)).
    pub const Ubo = struct {
        mvp: [4]Vec = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };
    /// FS texture (group 1) - the cube's albedo map.
    pub const Samplers = struct {
        texture0: si.Sampler2D(.albedo, .{}),
    };
};

// ============================================================================
// Persistent state
// ============================================================================

pub var zimr_app: z.App = .{};

const State = struct {
    resources: z.shader.Resources(CubeSchema),
    pipeline: z.wgpu.RenderPipelineHandle,
    pipeline_layout: z.wgpu.PipelineLayoutHandle,
    vs_module: z.wgpu.ShaderModuleHandle,
    fs_module: z.wgpu.ShaderModuleHandle,
    cube_texture: z.WgpuTexture,

    vertex_buffer: z.wgpu.BufferHandle,
    index_buffer: z.wgpu.BufferHandle,
};

const cube_vs_wgsl = @embedFile("cube_split_vs.wgsl");
const cube_fs_wgsl = @embedFile("cube_split_fs.wgsl");

// ============================================================================
// Init
// ============================================================================

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    // The frame already carries device/queue/surface/format + the frame-owned
    // depth target via its GpuFrame; build the cube pipeline from it.
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;
    const fmt: z.wgpu.TextureFormat = f.gpu.backbuffer_format;
    // The depth format lives on the GpuFrame, which now OWNS the depth texture
    // and auto-resizes it to the surface each frame. Just set the format; the
    // frame creates + matches the depth attachment (see GpuFrame.ensureDepth).
    f.gpu.depth_format = .depth24_plus;

    // ---- Checkerboard texture (stand-in for a real albedo map) ----
    const cube_texture: z.WgpuTexture = try z.WgpuTexture.createCheckerboard(
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
        .array_stride = @sizeOf(CubeVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
        },
    };

    // ---- Resources: builds the UBO (group 0) + sampler (group 1) BGLs ----
    // Mirrors Renderer2D: the solver assigns group 0 to the Ubo and
    // group 1 to the Sampler2D, matching cube_split's WGSL layout.
    const resources = try z.shader.Resources(CubeSchema).init(
        gpa,
        f.gpu,
        .{
            .initial_ubo = .{}, // identity; per-frame writeUbo replaces with MVP
            .texture0 = cube_texture,
        },
    );

    // ---- Pipeline layout chains both bind-group layouts ----
    const bgls: [2]z.wgpu.BindGroupLayoutHandle = .{
        resources.bg_layouts[0],
        resources.bg_layouts[1],
    };
    const pipeline_layout: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(device, bgls[0..], "cube_pl");

    // ---- Shader modules ----
    const vs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, cube_vs_wgsl, "cube_vs");
    const fs_module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, cube_fs_wgsl, "cube_fs");

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
        "cube_pipe",
    );
    s.* = .{
        .resources = resources,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .vs_module = vs_module,
        .fs_module = fs_module,
        .cube_texture = cube_texture,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
    };
}

fn update(f: *z.Frame, s: *State) void {
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

    // Push to the VS UBO (group 0, binding 0).  CubeSchema.Ubo.mvp is a
    // mat4 (=[4]@Vector(4,f32)); our zm.Mat is exactly that shape.
    s.resources.writeUbo(.{ .mvp = mvp });

    // ---- Frame ----
    const fctx = Backend.beginFrame(f.gpu);
    var ps = Backend.beginRenderPass(fctx.encoder, .{
        .color_view = fctx.surface_view,
        .clear = .{ .r = 0.05, .g = 0.06, .b = 0.10, .a = 1.0 },
        .depth_view = fctx.depth_view,
    });
    ps.queue = f.gpu.queue;

    // Bind the cube pipeline + both bind groups (UBO group 0 + texture group 1).
    Backend.setPipeline(&ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    s.resources.bind(&ps);

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
    Backend.endFrame(f.gpu);
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{ .title = "zimr - WebGPU - depth-tested cube", .width = 800, .height = 600 },
    }, State, initState, update);
}

// ============================================================================
// Frame
// ============================================================================
