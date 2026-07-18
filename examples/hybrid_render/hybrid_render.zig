//! hybrid_render — raylib's `shaders_hybrid_rendering`, the zimr way
//! (and, with the cubes toggled off, `shaders_raymarching_rendering`).
//!
//! Two rendering methods share one depth buffer inside one pass:
//!
//!   1. A fullscreen quad whose fragment shader sphere-traces an SDF
//!      scene (three orbiting metaballs over a checkerboard floor) and
//!      writes each hit's TRUE depth through the FragDepth builtin —
//!      projected via the same view-projection the raster pass uses.
//!   2. Ordinary rasterized cubes (the honest `fog_fs` material at
//!      density 0) drawn afterwards with a normal depth test.
//!
//!   The cubes orbit THROUGH the metaball cluster, so every frame shows
//!   raster geometry slicing in front of and behind marched geometry —
//!   occlusion across two rendering methods, with zero depth-encoding
//!   coordination (raylib teaches both shaders a custom near/far
//!   linearization instead; ours agree by construction).
//!
//! Checkboxes isolate either method; drag orbits; pinch zooms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const cross = zm.cross;
const float = zm.float;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const normalize = zm.normalize;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

const march_fs = z.hybrid_raymarch_shader;
const mat_vs = z.deferred_shaders.gbuffer_vs;
const cube_fs = z.fog_shader; // density 0 == honest lambert+blinn

pub var zimr_app: z.App = .{};

const shading_vs_wgsl = @embedFile("deferred_shading_vs.wgsl");
const hybrid_raymarch_fs_wgsl = @embedFile("hybrid_raymarch_fs.wgsl");
const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const fog_fs_wgsl = @embedFile("fog_fs.wgsl");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const MarchUbo = @FieldType(march_fs.Io, "u");
const VsUbo = @FieldType(mat_vs.Io, "u");
const CubeUbo = @FieldType(cube_fs.Io, "u");

const fov_y: f32 = 0.9;
const sun_dir: [3]f32 = .{ 0.45, 0.75, 0.5 }; // matches the marcher's sun
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const bg_clear: Color = .{ .r = 28, .g = 32, .b = 48, .a = 255 };

const cube_count: usize = 3;

/// The cubes orbit through the metaball cluster at staggered phases —
/// the interpenetration is the demo.
fn cubeCenter(i: usize, t: f32) [3]f32 {
    const phase: f32 = float(i) * 2.0943951;
    const a: f32 = -t * 0.45 + phase; // counter-rotate vs the blobs
    return .{ 1.4 * @cos(a), 1.0 + 0.3 * @sin(t * 0.8 + phase), 1.4 * @sin(a) };
}

const cube_colors = [cube_count][4]f32{
    .{ 0.85, 0.75, 0.25, 1 },
    .{ 0.3, 0.75, 0.85, 1 },
    .{ 0.75, 0.35, 0.85, 1 },
};

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };
const cube_verts = [_]MeshVertex{
    .{ .position = .{ -1, -1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 1, 1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -1, 1, 1 }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -1, 1, -1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ 1, 1, -1 }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 1, 1, -1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ 1, 1, 1 }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -1, -1, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -1, 1, 1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -1, 1, -1 }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -1, 1, 1 }, .normal = up_n },
    .{ .position = .{ 1, 1, 1 }, .normal = up_n },
    .{ .position = .{ 1, 1, -1 }, .normal = up_n },
    .{ .position = .{ -1, 1, -1 }, .normal = up_n },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -1, -1, 1 }, .normal = .{ 0, -1, 0 } },
};
const cube_indices = [_]u32{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const fullscreen_verts = [_][2]f32{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 },
    .{ -1, -1 }, .{ 1, 1 },  .{ -1, 1 },
};

const CubeObj = struct {
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    fs_ubo: z.wgpu.BufferHandle,
    g2_bg: z.wgpu.BindGroupHandle,
};

const State = struct {
    gpa: Allocator,
    march_pipeline: z.wgpu.RenderPipelineHandle,
    cube_pipeline: z.wgpu.RenderPipelineHandle,
    empty_bg: z.wgpu.BindGroupHandle,

    quad_vbo: z.wgpu.BufferHandle,
    march_ubo: z.wgpu.BufferHandle,
    march_bg: z.wgpu.BindGroupHandle,

    cube_vbo: z.wgpu.BufferHandle,
    cube_ibo: z.wgpu.BufferHandle,
    cubes: [cube_count]CubeObj,

    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    show_march: bool = true,
    show_cubes: bool = true,

    cam_yaw: f32 = 0.7,
    cam_pitch: f32 = 0.32,
    cam_dist: f32 = 7.0,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (&s.cubes) |*c| {
        z.wgpu.destroyBuffer(c.vs_ubo);
        z.wgpu.destroyBuffer(c.fs_ubo);
        z.wgpu.destroyBindGroup(c.g0_bg);
        z.wgpu.destroyBindGroup(c.g2_bg);
    }
    z.wgpu.destroyBuffer(s.quad_vbo);
    z.wgpu.destroyBuffer(s.march_ubo);
    z.wgpu.destroyBuffer(s.cube_vbo);
    z.wgpu.destroyBuffer(s.cube_ibo);
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyBindGroup(s.march_bg);
    z.wgpu.destroyRenderPipeline(s.march_pipeline);
    z.wgpu.destroyRenderPipeline(s.cube_pipeline);
    s.rt.deinit();
    s.ui_host.deinit();
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

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;

    const quad_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(fullscreen_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "hy_quad",
    );
    const cube_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "hy_cube_vbo",
    );
    const cube_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "hy_cube_ibo",
    );

    // ---- layouts ----
    const march_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(MarchUbo), .{ .fragment = true }, "hy_march_g2");
    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "hy_g0");
    const cube_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(CubeUbo), .{ .fragment = true }, "hy_cube_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "hy_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "hy_empty_bg");

    // ---- the marcher: fullscreen quad, depth WRITTEN by the FS ----
    const march_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ empty_bgl, empty_bgl, march_bgl },
        "hy_march_pl",
    );
    const quad_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, shading_vs_wgsl, "deferred_shading_vs");
    const march_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, hybrid_raymarch_fs_wgsl, "hybrid_raymarch_fs");
    const march_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const march_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{.{
            .array_stride = 8,
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            },
        }},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = march_combo,
    });
    defer gpa.free(march_blob);
    const march_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        march_pl,
        quad_vs_mod,
        march_mod,
        march_blob,
        "hy_march",
    );
    const march_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(MarchUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    // ---- the raster cubes: the honest forward material, untouched ----
    const cube_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, cube_bgl },
        "hy_cube_pl",
    );
    const cube_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const cube_fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fog_fs_wgsl, "fog_fs");
    const cube_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .back,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const cube_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{.{
            .array_stride = @sizeOf(MeshVertex),
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
            },
        }},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = cube_combo,
    });
    defer gpa.free(cube_blob);
    const cube_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        cube_pl,
        cube_vs_mod,
        cube_fs_mod,
        cube_blob,
        "hy_cube",
    );

    var cubes: [cube_count]CubeObj = undefined;
    for (&cubes) |*obj| {
        const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(VsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(CubeUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        obj.* = .{
            .vs_ubo = vs_ubo,
            .g0_bg = try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "hy_g0_bg"),
            .fs_ubo = fs_ubo,
            .g2_bg = try uniformBindGroup(gpa, device, cube_bgl, fs_ubo, @sizeOf(CubeUbo), "hy_g2_bg"),
        };
    }

    const march_bg = try uniformBindGroup(gpa, device, march_bgl, march_ubo, @sizeOf(MarchUbo), "hy_march_bg");

    // Build-only intermediates consumed above — release them (pipelines are direct/uncached → owned).
    z.wgpu.destroyBindGroupLayout(march_bgl);
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(cube_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
    z.wgpu.destroyPipelineLayout(march_pl);
    z.wgpu.destroyPipelineLayout(cube_pl);
    z.wgpu.destroyShaderModule(quad_vs_mod);
    z.wgpu.destroyShaderModule(march_mod);
    z.wgpu.destroyShaderModule(cube_vs_mod);
    z.wgpu.destroyShaderModule(cube_fs_mod);

    const ui_font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .march_pipeline = march_pipeline,
        .cube_pipeline = cube_pipeline,
        .empty_bg = empty_bg,
        .quad_vbo = quad_vbo,
        .march_ubo = march_ubo,
        .march_bg = march_bg,
        .cube_vbo = cube_vbo,
        .cube_ibo = cube_ibo,
        .cubes = cubes,
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
}

fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: u32 = @max(backing.width, 1);
    const bh: u32 = @max(backing.height, 1);
    if (s.rt.color != .invalid and s.rt.width == bw and s.rt.height == bh) {
        return;
    }
    if (s.rt.color != .invalid) {
        z.unloadRenderTexture(f.gl, &s.rt);
    }
    s.rt = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
}

fn handleInput(f: *z.Frame, s: *State, ui_wants_mouse: bool) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.02, 4.0, 16.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.06, 1.35);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.5, 4.0, 16.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    // ---- ONE camera feeds both methods ----
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
    const aspect: f32 = vw / vh;
    const cam_proj: Mat = perspectiveFovRh(fov_y, aspect, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    // The marcher's ray basis, from the same eye/target the VP uses.
    // (zm.cross is Vec4-wide, zmath heritage — ride w = 0 through it.)
    const fwd3: Vec = normalize(cam_target - cam_eye);
    const right3: Vec = normalize(cross(fwd3, vec(0, 1, 0)));
    const up3: Vec = normalize(cross(right3, fwd3));

    var march_io: march_fs.Io = undefined;
    march_io.u = .{
        .vp = cam_vp,
        .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
        .cam_right = .{ right3[0], right3[1], right3[2], 0 },
        .cam_up = .{ up3[0], up3[1], up3[2], 0 },
        .cam_fwd = .{ fwd3[0], fwd3[1], fwd3[2], @tan(fov_y * 0.5) },
        .params = .{ aspect, t, 0, 0 },
    };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.march_ubo, 0, std.mem.asBytes(&march_io.u));

    for (&s.cubes, cube_colors, 0..) |*obj, color, i| {
        const c: [3]f32 = cubeCenter(i, t);
        const spin: Mat = rotationY(t * 0.6 + float(i));
        const model: Mat = mulMat(
            translation(c[0], c[1], c[2]),
            mulMat(spin, scaling(0.45, 0.45, 0.45)),
        );
        var vs_io: mat_vs.Io = undefined;
        vs_io.u = .{ .mvp = mulMat(cam_vp, model), .model = model, .normal_matrix = spin };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

        var fs_io: cube_fs.Io = undefined;
        fs_io.u = .{
            .base_color = color,
            .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
            .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
            .fog_color = .{ 0, 0, 0, 1 },
            .params = .{ 0, 0, 0, 0 },
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.fs_ubo, 0, std.mem.asBytes(&fs_io.u));
    }

    // ---- ONE pass, two rendering methods, one depth buffer ----
    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    if (s.show_march) {
        Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.march_pipeline });
        Backend.setBindGroup(pa, 0, s.empty_bg);
        Backend.setBindGroup(pa, 1, s.empty_bg);
        Backend.setBindGroup(pa, 2, s.march_bg);
        z.render_pass.setVertexBuffer(pa.pass, .{
            .slot = 0,
            .buffer = s.quad_vbo,
            .offset = 0,
            .size = @sizeOf(@TypeOf(fullscreen_verts)),
        });
        z.render_pass.draw(pa.pass, .{
            .vertex_count = 6,
            .instance_count = 1,
            .first_vertex = 0,
            .first_instance = 0,
        });
    }
    if (s.show_cubes) {
        Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.cube_pipeline });
        Backend.setBindGroup(pa, 1, s.empty_bg);
        z.render_pass.setVertexBuffer(pa.pass, .{
            .slot = 0,
            .buffer = s.cube_vbo,
            .offset = 0,
            .size = @sizeOf(@TypeOf(cube_verts)),
        });
        z.render_pass.setIndexBuffer(pa.pass, .{
            .buffer = s.cube_ibo,
            .format = .uint32,
            .offset = 0,
            .size = @sizeOf(@TypeOf(cube_indices)),
        });
        for (&s.cubes) |*obj| {
            Backend.setBindGroup(pa, 0, obj.g0_bg);
            Backend.setBindGroup(pa, 2, obj.g2_bg);
            z.render_pass.drawIndexed(pa.pass, .{
                .index_count = cube_indices.len,
                .instance_count = 1,
                .first_index = 0,
                .base_vertex = 0,
                .first_instance = 0,
            });
        }
    }
    z.endTextureModeRaw(f.gl);

    // SCREEN PASS: open once, composite, then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 120 }, .{});
    u.setNextWindowSize(.{ panel_w, 112 }, .{});
    if (u.window("hybrid", .{})) |w| {
        defer w.close();
        _ = u.checkbox("raymarched blobs", &s.show_march);
        _ = u.checkbox("raster cubes", &s.show_cubes);
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - hybrid raster + raymarch (shared depth)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // Renders offscreen before the screen opens (tile-based-GPU safe); owns
    // its own begin/endDrawing.
    .manages_own_frame = true,
    .memory = .managed,
};
