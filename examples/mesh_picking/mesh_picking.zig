//! mesh_picking - raylib's `models_mesh_picking`, the zimr way.
//!
//! Tap anything: the tap becomes a world-space ray
//! (`getScreenToWorldRay`, new this port), and the ray is tested
//! against each object with the collision routine that fits it - the
//! ground through `getRayCollisionQuad`, the cube through
//! `getRayCollisionBox` (its AABB), the sphere analytically through
//! `getRayCollisionSphere`, and the spinning torus through the real
//! thing, `getRayCollisionMesh`, which walks the triangles with the
//! torus's live model matrix so the hit is exact WHILE it rotates.
//! Closest hit wins; the winner glows, a small marker cube sits on the
//! hit point, and the panel reports what you hit and how far away.
//!
//! Phone-first: raylib picks on hover, which fingers don't have.  Here
//! a PICK is a tap - press and release with less than a knuckle of
//! drag - so the one-finger orbit and pinch zoom keep working.
//! Rendering is the shared forward stack: `gbuffer_vs` + `fog_fs` at
//! density 0 (plain Lambert), one pipeline for everything including
//! the marker.

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
const rotationY = zm.rotationY;
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
const fovy_rad: f32 = 0.8;

/// Which pickable a draw slot is; the marker rides along as a slot too.
const Pickable = enum { ground, cube, sphere, torus, marker };
const pick_names = [_][]const u8{ "ground", "cube", "sphere", "torus", "-" };

const cube_center: [3]f32 = .{ -1.6, 0.5, 0.2 };
const cube_half: f32 = 0.5;
const sphere_center: [3]f32 = .{ 1.6, 0.62, 0.3 };
const sphere_radius: f32 = 0.62;
const torus_center: [3]f32 = .{ 0.0, 0.55, -1.6 };

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };
const ground_half: f32 = 4.0;
const ground_verts = [_]MeshVertex{
    .{ .position = .{ -ground_half, 0, -ground_half }, .normal = up_n },
    .{ .position = .{ ground_half, 0, -ground_half }, .normal = up_n },
    .{ .position = .{ ground_half, 0, ground_half }, .normal = up_n },
    .{ .position = .{ -ground_half, 0, ground_half }, .normal = up_n },
};
const ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

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

/// A generated mesh uploaded to the GPU (interleaved pos+normal + u32 ibo).
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
    objs: [5]Obj, // ground, cube, sphere, torus, marker

    // The torus's CPU-side triangles STAY resident - getRayCollisionMesh
    // walks them on every tap (the GPU copy can't be read back cheaply).
    torus_cpu: z.Mesh,

    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    picked: Pickable = .marker, // .marker doubles as "nothing yet"
    hit_point: [3]f32 = .{ 0, 0, 0 },
    hit_distance: f32 = 0,

    // Tap detection: press position + accumulated drag.
    press_pos: Vec2 = .{ 0, 0 },
    pressed: bool = false,
    drag_total: f32 = 0,

    cam_yaw: f32 = 0.7,
    cam_pitch: f32 = 0.5,
    cam_dist: f32 = 8.0,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    // objs 0-3 own unique meshes; obj 4 (the marker) reuses obj 1 (cube)'s mesh
    // handles, so freeing all five would double-free - free the four unique ones.
    for (s.objs[0..4]) |obj| {
        z.wgpu.destroyBuffer(obj.mesh.vbo);
        z.wgpu.destroyBuffer(obj.mesh.ibo);
    }
    // Every obj has its OWN per-object UBOs + bind groups (built in the loop).
    for (&s.objs) |*obj| {
        z.wgpu.destroyBuffer(obj.vs_ubo);
        z.wgpu.destroyBuffer(obj.fs_ubo);
        z.wgpu.destroyBindGroup(obj.g0_bg);
        z.wgpu.destroyBindGroup(obj.g2_bg);
    }
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBindGroup(s.empty_bg);
    s.rt.deinit();
    z.unloadMesh(gpa, s.torus_cpu);
    z.unloadFont(gpa, s.font);
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

    // ---- geometry: two hand-rolled, two generated ----
    const ground: GpuMesh = .{
        .vbo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(ground_verts[0..]),
            .{ .vertex = true, .copy_dst = true },
            "pick_ground_vbo",
        ),
        .ibo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(ground_indices[0..]),
            .{ .index = true, .copy_dst = true },
            "pick_ground_ibo",
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
            "pick_cube_vbo",
        ),
        .ibo = z.wgpu.createBufferInit(
            device,
            queue,
            std.mem.sliceAsBytes(cube_indices[0..]),
            .{ .index = true, .copy_dst = true },
            "pick_cube_ibo",
        ),
        .vbo_bytes = @sizeOf(@TypeOf(cube_verts)),
        .ibo_bytes = @sizeOf(@TypeOf(cube_indices)),
        .icount = cube_indices.len,
    };
    const sphere_cpu: z.Mesh = try z.genMeshSphere(gpa, 1.0, 24, 20);
    defer z.unloadMesh(gpa, sphere_cpu);
    const sphere: GpuMesh = try uploadMesh(gpa, device, queue, sphere_cpu, "pick_sphere");
    // Torus CPU mesh outlives init - it's the pick target.
    const torus_cpu: z.Mesh = try z.genMeshTorus(gpa, 0.35, 1.0, 14, 28);
    const torus: GpuMesh = try uploadMesh(gpa, device, queue, torus_cpu, "pick_torus");

    // ---- one pipeline for everything ----
    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "pick_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FsUbo), .{ .fragment = true }, "pick_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "pick_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "pick_empty_bg");
    const pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, g2_bgl },
        "pick_pl",
    );
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fog_fs_wgsl, "fog_fs");
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none, // torus interior shows through its hole - keep both faces
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
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "pick_pipe");

    var objs: [5]Obj = undefined;
    const meshes = [5]GpuMesh{ ground, cube, sphere, torus, cube };
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
            .g0_bg = try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "pick_g0_bg"),
            .fs_ubo = fs_ubo,
            .g2_bg = try uniformBindGroup(gpa, device, g2_bgl, fs_ubo, @sizeOf(FsUbo), "pick_g2_bg"),
        };
    }

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .pipeline = pipeline,
        .empty_bg = empty_bg,
        .objs = objs,
        .torus_cpu = torus_cpu,
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };

    // Build-only intermediates: the pipeline + per-obj bind groups have
    // internalized these, so the layouts and modules can be released now.
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
    z.wgpu.destroyPipelineLayout(pl);
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(g2_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
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

/// Cast the tap and race all four pickables; closest hit wins.
fn pick(
    s: *State,
    tap: Vec2,
    cam: zm.Camera3D,
    vw: f32,
    vh: f32,
    torus_model: Mat,
) void {
    const ray: zm.Ray = z.getScreenToWorldRay(tap, cam, vw, vh);

    var best: Pickable = .marker;
    var best_hit: zm.RayCollision = .{
        .hit = false,
        .distance = 1.0e30,
        .point = vec(0, 0, 0),
        .normal = vec(0, 0, 0),
    };

    const candidates = [4]struct { which: Pickable, c: zm.RayCollision }{
        .{ .which = .ground, .c = z.getRayCollisionQuad(
            ray,
            vec(-ground_half, 0, -ground_half),
            vec(-ground_half, 0, ground_half),
            vec(ground_half, 0, ground_half),
            vec(ground_half, 0, -ground_half),
        ) },
        .{ .which = .cube, .c = z.getRayCollisionBox(ray, .{
            .min = vec(cube_center[0] - cube_half, cube_center[1] - cube_half, cube_center[2] - cube_half),
            .max = vec(cube_center[0] + cube_half, cube_center[1] + cube_half, cube_center[2] + cube_half),
        }) },
        .{ .which = .sphere, .c = z.getRayCollisionSphere(
            ray,
            vec(sphere_center[0], sphere_center[1], sphere_center[2]),
            sphere_radius,
        ) },
        .{ .which = .torus, .c = z.getRayCollisionMesh(ray, s.torus_cpu, torus_model) },
    };
    for (candidates) |cand| {
        if (cand.c.hit and cand.c.distance < best_hit.distance) {
            best_hit = cand.c;
            best = cand.which;
        }
    }

    s.picked = best;
    if (best != .marker) {
        s.hit_point = .{ best_hit.point[0], best_hit.point[1], best_hit.point[2] };
        s.hit_distance = best_hit.distance;
    }
}

fn handleInput(
    f: *z.Frame,
    s: *State,
    ui_wants_mouse: bool,
    cam: zm.Camera3D,
    vw: f32,
    vh: f32,
    torus_model: Mat,
) void {
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
        s.pressed = false; // a pinch is never a tap
        return;
    }
    s.prev_pinch = 0;

    const mp: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.05, 1.4);
            s.drag_total += @abs(d[0]) + @abs(d[1]);
        } else {
            s.press_pos = mp;
            s.drag_total = 0;
            s.pressed = true;
        }
        s.dragging = true;
    } else {
        // Release: a press that never turned into a real drag is a TAP.
        if (s.dragging and s.pressed and s.drag_total < 10.0) {
            pick(s, s.press_pos, cam, vw, vh, torus_model);
        }
        s.dragging = false;
        s.pressed = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.5, 4.0, 16.0);
    }
}

fn writeObj(
    f: *z.Frame,
    obj: *Obj,
    model: Mat,
    normal_mat: Mat,
    cam_vp: Mat,
    cam_eye: Vec,
    color: [4]f32,
) void {
    var vs_io: mat_vs.Io = undefined;
    vs_io.u = .{ .mvp = mulMat(cam_vp, model), .model = model, .normal_matrix = normal_mat };
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

/// Base color, brightened when this slot is the picked one.
fn tint(base: [4]f32, hot: bool) [4]f32 {
    if (!hot) {
        return base;
    }
    return .{
        @min(base[0] * 1.5 + 0.15, 1.0),
        @min(base[1] * 1.5 + 0.15, 1.0),
        @min(base[2] * 1.5 + 0.15, 1.0),
        1.0,
    };
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // Uses last-frame pick/camera state (1-frame lag, imperceptible); the UI
    // below updates it for next frame.
    // ---- camera (both the render matrices and the picking Camera3D) ----
    const cam_target: Vec = vec(0, 0.5, 0);
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
    const cam_proj: Mat = perspectiveFovRh(fovy_rad, vw / vh, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);
    const cam3d: zm.Camera3D = .{
        .position = cam_eye,
        .target = cam_target,
        .up = vec(0, 1, 0),
        .fovy_deg = fovy_rad * 180.0 / pi,
    };

    // The torus spins; its model matrix feeds BOTH the draw and the pick.
    const torus_spin: Mat = rotationY(t * 0.6);
    const torus_model: Mat = mulMat(
        translation(torus_center[0], torus_center[1], torus_center[2]),
        torus_spin,
    );

    // ---- uniforms ----
    const idm: Mat = zm.identity();
    writeObj(f, &s.objs[0], idm, idm, cam_vp, cam_eye, tint(.{ 0.5, 0.52, 0.56, 1 }, s.picked == .ground));
    const cube_model: Mat = mulMat(
        translation(cube_center[0], cube_center[1], cube_center[2]),
        scaling(cube_half, cube_half, cube_half),
    );
    writeObj(f, &s.objs[1], cube_model, idm, cam_vp, cam_eye, tint(.{ 0.85, 0.45, 0.3, 1 }, s.picked == .cube));
    const sphere_model: Mat = mulMat(
        translation(sphere_center[0], sphere_center[1], sphere_center[2]),
        scaling(sphere_radius, sphere_radius, sphere_radius),
    );
    writeObj(f, &s.objs[2], sphere_model, idm, cam_vp, cam_eye, tint(.{ 0.35, 0.65, 0.9, 1 }, s.picked == .sphere));
    const torus_hot: bool = s.picked == .torus;
    writeObj(f, &s.objs[3], torus_model, torus_spin, cam_vp, cam_eye, tint(.{ 0.55, 0.85, 0.45, 1 }, torus_hot));
    // The marker: a tiny white cube parked on the hit point.
    const marker_model: Mat = mulMat(
        translation(s.hit_point[0], s.hit_point[1], s.hit_point[2]),
        scaling(0.07, 0.07, 0.07),
    );
    writeObj(f, &s.objs[4], marker_model, idm, cam_vp, cam_eye, .{ 1, 1, 1, 1 });

    // ---- the pass ----
    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(pa, 1, s.empty_bg);
    const draw_count: usize = if (s.picked == .marker) 4 else 5; // no marker before first pick
    for (s.objs[0..draw_count]) |*obj| {
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

    // ---- SCREEN PASS: open once, composite the RTT, then the UI. ----
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });

    // ---- UI + input (tap picks, drag orbits) ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 118 }, .{});
    u.setNextWindowSize(.{ panel_w, 110 }, .{});
    if (u.window("mesh picking", .{})) |w| {
        defer w.close();
        u.text("tap an object to pick it", .{});
        if (s.picked == .marker) {
            u.text("picked: nothing yet", .{});
        } else {
            u.text("picked: {s}  ({d:.2} away)", .{ pick_names[@backingInt(s.picked)], s.hit_distance });
        }
    }
    handleInput(f, s, u.wantCaptureMouse(), cam3d, vw, vh, torus_model);
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - mesh picking (tap to pick)",
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
    // Renders the pick scene offscreen before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
