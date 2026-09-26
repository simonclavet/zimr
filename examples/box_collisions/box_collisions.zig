//! box_collisions - raylib's `models_box_collisions`, the zimr way.
//!
//! A green player box slides around an arena holding a gray enemy cube
//! and a gray enemy sphere.  Every frame the player's AABB is tested
//! against both (`checkCollisionBoxes`, `checkCollisionBoxSphere` -
//! raylib's exact predicates, re-exported this port); on any overlap
//! the player flashes RED and the panel says which enemy it's touching.
//!
//! Phone-first: raylib steers with arrow keys.  Here you DRAG - one
//! finger anywhere slides the player to the ground point under it,
//! computed by casting `getScreenToWorldRay` (last port's engine
//! addition) against the ground plane.  The camera is fixed like
//! raylib's, so dragging never fights an orbit; pinch still zooms.
//! Rendering is the shared forward stack (`gbuffer_vs` + `fog_fs` at
//! density 0), one pipeline for the four draws.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const pi = zm.pi;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

const mat_vs = z.deferred_shaders.gbuffer_vs;
const mat_fs = z.fog_shader; // density 0 = plain lambert+blinn

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const fog_fs_wgsl = @embedFile("fog_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const VsUbo = @FieldType(mat_vs.Io, "u");
const FsUbo = @FieldType(mat_fs.Io, "u");

const bg_clear: Color = .{ .r = 24, .g = 26, .b = 32, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const sun_dir: [3]f32 = .{ 0.4, 0.85, 0.5 };
const fovy_rad: f32 = 1.0;

// raylib's cast, verbatim: sizes are FULL extents.
const player_size: [3]f32 = .{ 1.0, 2.0, 1.0 };
const enemy_box_pos: [3]f32 = .{ -4.0, 1.0, 0.0 };
const enemy_box_size: f32 = 2.0;
const enemy_sphere_pos: [3]f32 = .{ 4.0, 0.0, 0.0 };
const enemy_sphere_r: f32 = 1.5;
const arena_half: f32 = 6.0;

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };
const ground_verts = [_]MeshVertex{
    .{ .position = .{ -arena_half, 0, -arena_half }, .normal = up_n },
    .{ .position = .{ arena_half, 0, -arena_half }, .normal = up_n },
    .{ .position = .{ arena_half, 0, arena_half }, .normal = up_n },
    .{ .position = .{ -arena_half, 0, arena_half }, .normal = up_n },
};
const ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

/// Unit cube (half-extent 1), flat face normals.
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

const GpuMesh = struct {
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
};

fn uploadMesh(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    queue: z.wgpu.QueueHandle,
    mesh: z.Mesh,
    label: []const u8,
) !GpuMesh {
    const vcount: usize = @intCast(mesh.vertexCount);
    const verts: []MeshVertex = try gpa.alloc(MeshVertex, vcount);
    defer gpa.free(verts);
    for (verts, 0..) |*v, i| {
        v.* = .{
            .position = .{ mesh.vertices[i * 3 + 0], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2] },
            .normal = .{ mesh.normals[i * 3 + 0], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2] },
        };
    }
    const icount: usize = @as(usize, @intCast(mesh.triangleCount)) * 3;
    const indices: []u32 = try gpa.alloc(u32, icount);
    defer gpa.free(indices);
    if (mesh.indices != null) {
        for (indices, 0..) |*ix, i| {
            ix.* = mesh.indices[i];
        }
    } else {
        for (indices, 0..) |*ix, i| {
            ix.* = @intCast(i);
        }
    }
    return .{
        .vbo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(verts),
            .{ .vertex = true, .copy_dst = true },
            label,
        ),
        .ibo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(indices),
            .{ .index = true, .copy_dst = true },
            label,
        ),
        .vbo_bytes = verts.len * @sizeOf(MeshVertex),
        .ibo_bytes = indices.len * @sizeOf(u32),
        .icount = @intCast(icount),
    };
}

const Obj = struct {
    mesh: GpuMesh,
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    fs_ubo: z.wgpu.BufferHandle,
    g2_bg: z.wgpu.BindGroupHandle,
};

const State = struct {
    gpa: Allocator,
    pipeline: z.wgpu.RenderPipelineHandle,
    empty_bg: z.wgpu.BindGroupHandle,
    objs: [4]Obj, // ground, enemy cube, enemy sphere, player
    meshes: [3]GpuMesh, // the 3 UNIQUE meshes (cube is shared by objs[1] & objs[3])

    player_pos: [3]f32 = .{ 0, 1, 2 }, // raylib's start
    hit_box: bool = false,
    hit_sphere: bool = false,

    rt: z.RenderTexture,
    ui_host: z.UiHost,

    cam_dist_scale: f32 = 1.0, // pinch zoom scales the fixed camera
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    // Per-object uniforms + bind groups (NOT obj.mesh - those alias s.meshes below).
    for (s.objs) |o| {
        z.wgpu.destroyBuffer(o.vs_ubo);
        z.wgpu.destroyBuffer(o.fs_ubo);
        z.wgpu.destroyBindGroup(o.g0_bg);
        z.wgpu.destroyBindGroup(o.g2_bg);
    }
    // The 3 unique meshes (freeing per-obj would double-destroy the shared cube).
    for (s.meshes) |m| {
        z.wgpu.destroyBuffer(m.vbo);
        z.wgpu.destroyBuffer(m.ibo);
    }
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBindGroup(s.empty_bg);
    s.rt.deinit(); // color+depth textures/views + sampler (no-op when empty)
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

    const ground: GpuMesh = .{
        .vbo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(ground_verts[0..]),
            .{ .vertex = true, .copy_dst = true },
            "bc_ground_vbo",
        ),
        .ibo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(ground_indices[0..]),
            .{ .index = true, .copy_dst = true },
            "bc_ground_ibo",
        ),
        .vbo_bytes = @sizeOf(@TypeOf(ground_verts)),
        .ibo_bytes = @sizeOf(@TypeOf(ground_indices)),
        .icount = ground_indices.len,
    };
    const cube: GpuMesh = .{
        .vbo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(cube_verts[0..]),
            .{ .vertex = true, .copy_dst = true },
            "bc_cube_vbo",
        ),
        .ibo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(cube_indices[0..]),
            .{ .index = true, .copy_dst = true },
            "bc_cube_ibo",
        ),
        .vbo_bytes = @sizeOf(@TypeOf(cube_verts)),
        .ibo_bytes = @sizeOf(@TypeOf(cube_indices)),
        .icount = cube_indices.len,
    };
    const sphere_cpu: z.Mesh = try z.genMeshSphere(gpa, 1.0, 24, 20);
    defer z.unloadMesh(gpa, sphere_cpu);
    const sphere: GpuMesh = try uploadMesh(gpa, device, queue, sphere_cpu, "bc_sphere");

    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "bc_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FsUbo), .{ .fragment = true }, "bc_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "bc_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "bc_empty_bg");
    const pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, g2_bgl },
        "bc_pl",
    );
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fog_fs_wgsl, "fog_fs");
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .back,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
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
        .state = combo,
    });
    defer gpa.free(pipe_blob);
    const pipeline: z.wgpu.RenderPipelineHandle =
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "bc_pipe");

    var objs: [4]Obj = undefined;
    const meshes = [4]GpuMesh{ ground, cube, sphere, cube };
    for (&objs, meshes) |*obj, gm| {
        const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(VsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(FsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        obj.* = .{
            .mesh = gm,
            .vs_ubo = vs_ubo,
            .g0_bg = try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "bc_g0_bg"),
            .fs_ubo = fs_ubo,
            .g2_bg = try uniformBindGroup(gpa, device, g2_bgl, fs_ubo, @sizeOf(FsUbo), "bc_g2_bg"),
        };
    }

    // The layouts, pipeline layout, and shader modules are only needed to build
    // the pipeline and bind groups; WebGPU keeps its own internal refs, so we can
    // release these build intermediates now rather than leak them for the app's life.
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(g2_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
    z.wgpu.destroyPipelineLayout(pl);
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);

    s.* = .{
        .gpa = gpa,
        .pipeline = pipeline,
        .empty_bg = empty_bg,
        .objs = objs,
        .meshes = .{ ground, cube, sphere }, // 3 unique; obj mesh fields alias these

        .rt = .{},
        .ui_host = z.UiHost.init(gpa, try z.loadFont(f, gpa, atkinson_mono_ttf, 22)),
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

/// Drag anywhere: the finger's ray hits the ground plane and the player
/// glides there (clamped to the arena).
fn handleInput(
    f: *z.Frame,
    s: *State,
    ui_wants_mouse: bool,
    cam: zm.Camera3D,
    vw: f32,
    vh: f32,
) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist_scale = clamp(s.cam_dist_scale - (dist - s.prev_pinch) * 0.002, 0.6, 1.8);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        const mp: Vec2 = z.getMousePosition(f.input);
        const ray: zm.Ray = z.getScreenToWorldRay(mp, cam, vw, vh);
        const hit: zm.RayCollision = z.getRayCollisionQuad(
            ray,
            vec(-100, 0, -100),
            vec(-100, 0, 100),
            vec(100, 0, 100),
            vec(100, 0, -100),
        );
        if (hit.hit) {
            s.player_pos[0] = clamp(hit.point[0], -arena_half + 0.5, arena_half - 0.5);
            s.player_pos[2] = clamp(hit.point[2], -arena_half + 0.5, arena_half - 0.5);
        }
    }
}

fn writeObj(
    f: *z.Frame,
    obj: *Obj,
    model: Mat,
    cam_vp: Mat,
    cam_eye: Vec,
    color: [4]f32,
) void {
    var vs_io: mat_vs.Io = undefined;
    vs_io.u = .{ .mvp = mulMat(cam_vp, model), .model = model, .normal_matrix = zm.identity() };
    z.wgpu.queueWriteBuffer(f.gpu.queue, obj.vs_ubo, 0, std.mem.asBytes(&vs_io.u));
    var fs_io: mat_fs.Io = undefined;
    fs_io.u = .{
        .base_color = color,
        .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
        .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        .fog_color = .{ 0, 0, 0, 1 },
        .params = .{ 0, 0, 0, 0 },
    };
    z.wgpu.queueWriteBuffer(f.gpu.queue, obj.fs_ubo, 0, std.mem.asBytes(&fs_io.u));
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    // raylib's fixed camera at (0,10,10), pinch-scaled.
    const cam_eye: Vec = vec(0, 15.0 * s.cam_dist_scale, 20.0 * s.cam_dist_scale);
    const cam_target: Vec = vec(0, 0, 0);
    const cam_view: Mat = lookAtRh(cam_eye, cam_target, vec(0, 1, 0));
    const cam_proj: Mat = perspectiveFovRh(fovy_rad, vw / vh, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);
    const cam3d: zm.Camera3D = .{
        .position = cam_eye,
        .target = cam_target,
        .up = vec(0, 1, 0),
        .fovy_deg = fovy_rad * 180.0 / pi,
    };

    // ---- the collision tests, raylib's predicates verbatim ----
    const player_box: z.BoundingBox = .{
        .min = vec(
            s.player_pos[0] - player_size[0] * 0.5,
            s.player_pos[1] - player_size[1] * 0.5,
            s.player_pos[2] - player_size[2] * 0.5,
        ),
        .max = vec(
            s.player_pos[0] + player_size[0] * 0.5,
            s.player_pos[1] + player_size[1] * 0.5,
            s.player_pos[2] + player_size[2] * 0.5,
        ),
    };
    const enemy_box: z.BoundingBox = .{
        .min = vec(
            enemy_box_pos[0] - enemy_box_size * 0.5,
            enemy_box_pos[1] - enemy_box_size * 0.5,
            enemy_box_pos[2] - enemy_box_size * 0.5,
        ),
        .max = vec(
            enemy_box_pos[0] + enemy_box_size * 0.5,
            enemy_box_pos[1] + enemy_box_size * 0.5,
            enemy_box_pos[2] + enemy_box_size * 0.5,
        ),
    };
    s.hit_box = z.checkCollisionBoxes(player_box, enemy_box);
    s.hit_sphere = z.checkCollisionBoxSphere(
        player_box,
        vec(enemy_sphere_pos[0], enemy_sphere_pos[1], enemy_sphere_pos[2]),
        enemy_sphere_r,
    );
    const colliding: bool = s.hit_box or s.hit_sphere;

    // ---- uniforms: ground, enemies, then the player (green or RED) ----
    writeObj(f, &s.objs[0], zm.identity(), cam_vp, cam_eye, .{ 0.5, 0.52, 0.56, 1 });
    const ebox_model: Mat = mulMat(
        translation(enemy_box_pos[0], enemy_box_pos[1], enemy_box_pos[2]),
        scaling(enemy_box_size * 0.5, enemy_box_size * 0.5, enemy_box_size * 0.5),
    );
    writeObj(f, &s.objs[1], ebox_model, cam_vp, cam_eye, .{ 0.55, 0.55, 0.58, 1 });
    const esph_model: Mat = mulMat(
        translation(enemy_sphere_pos[0], enemy_sphere_pos[1], enemy_sphere_pos[2]),
        scaling(enemy_sphere_r, enemy_sphere_r, enemy_sphere_r),
    );
    writeObj(f, &s.objs[2], esph_model, cam_vp, cam_eye, .{ 0.55, 0.55, 0.58, 1 });
    const player_model: Mat = mulMat(
        translation(s.player_pos[0], s.player_pos[1], s.player_pos[2]),
        scaling(player_size[0] * 0.5, player_size[1] * 0.5, player_size[2] * 0.5),
    );
    const player_color: [4]f32 = if (colliding) .{ 0.95, 0.2, 0.2, 1 } else .{ 0.25, 0.85, 0.35, 1 };
    writeObj(f, &s.objs[3], player_model, cam_vp, cam_eye, player_color);

    // ---- the pass ----
    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(pa, 1, s.empty_bg);
    for (&s.objs) |*obj| {
        Backend.setBindGroup(pa, 0, obj.g0_bg);
        Backend.setBindGroup(pa, 2, obj.g2_bg);
        z.render_pass.setVertexBuffer(pa.pass, .{
            .slot = 0,
            .buffer = obj.mesh.vbo,
            .offset = 0,
            .size = obj.mesh.vbo_bytes,
        });
        z.render_pass.setIndexBuffer(pa.pass, .{
            .buffer = obj.mesh.ibo,
            .format = .uint32,
            .offset = 0,
            .size = obj.mesh.ibo_bytes,
        });
        z.render_pass.drawIndexed(pa.pass, .{
            .index_count = obj.mesh.icount,
            .instance_count = 1,
            .first_index = 0,
            .base_vertex = 0,
            .first_instance = 0,
        });
    }
    z.endTextureModeRaw(f.gl);

    // SCREEN PASS: open once, composite, then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    // ---- UI first (its capture flag gates the drag) ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 118 }, .{});
    u.setNextWindowSize(.{ panel_w, 110 }, .{});
    if (u.window("box collisions", .{})) |w| {
        defer w.close();
        u.text("drag to slide the player", .{});
        const status: []const u8 = if (s.hit_box and s.hit_sphere)
            "COLLISION: box + sphere!"
        else if (s.hit_box)
            "COLLISION: enemy box!"
        else if (s.hit_sphere)
            "COLLISION: enemy sphere!"
        else
            "clear";
        u.text("{s}", .{status});
    }
    handleInput(f, s, u.wantCaptureMouse(), cam3d, vw, vh);
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - box collisions (drag the player)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Renders offscreen before the screen opens (tile-based-GPU safe); owns
    // its own begin/endDrawing.
    .manages_own_frame = true,
};
