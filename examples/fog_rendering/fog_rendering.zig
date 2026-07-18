//! fog_rendering — raylib's `shaders_fog_rendering`, the zimr way.
//!
//! A trio of generated meshes (torus / cube / sphere) plus a long row of
//! toruses marching off into exponential-squared distance fog — the row
//! is the whole demo: you watch geometry dissolve into atmosphere, and
//! the fog-density slider moves the wall of nothing closer or further.
//!
//! Shader-sharing flex: there is NO fog vertex shader.  The vertex stage
//! is `gbuffer_vs` — the deferred G-buffer's — reused verbatim, because
//! "clip position + world position + world normal" is what EVERY
//! world-space-lit forward material wants.  `fog_fs` just consumes the
//! same varyings (`gbuffer_common_io.Interp`) and adds Lambert + Blinn +
//! the fog fold.  One vertex shader, a growing family of materials.
//!
//! Phone-first upgrades over the raylib original: drag to orbit,
//! pinch/wheel to zoom, and the KEY_UP/KEY_DOWN density nudging became
//! an actual slider.  The center torus tumbles so the lighting reads as
//! live, and fog color == clear color so the horizon dissolves without
//! a silhouette halo (raylib ships the mismatch).

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const translation = zm.translation;
const vec = zm.vec;

const fog_vs = z.deferred_shaders.gbuffer_vs; // REUSED — see the doc comment
const fog_fs = z.fog_shader;

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const fog_fs_wgsl = @embedFile("fog_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const FogVsUbo = @FieldType(fog_vs.Io, "u");
const FogFsUbo = @FieldType(fog_fs.Io, "u");

/// The fog IS the sky: one color for the pass clear and the shader's
/// fog fold, so distant geometry melts into the background seamlessly.
const fog_rgb: [3]f32 = .{ 0.33, 0.36, 0.44 };
const fog_clear: Color = .{
    .r = @intFromFloat(fog_rgb[0] * 255.0),
    .g = @intFromFloat(fog_rgb[1] * 255.0),
    .b = @intFromFloat(fog_rgb[2] * 255.0),
    .a = 255,
};

/// One directional light, high and a little forward.
const sun_dir: [3]f32 = .{ 0.35, 0.8, 0.45 };

// ============================================================================
// Staging — the raylib line-up: trio up front, torus row into the murk.
// ============================================================================

const torus_row_len: usize = 21; // raylib: i = -20..20 step 2
const total_objects: usize = 3 + torus_row_len;

const Placement = struct {
    mesh: enum { torus, cube, sphere },
    center: [3]f32,
    spin_rate: f32,
    base_color: [4]f32,
};

const placements: [total_objects]Placement = buildPlacements();

fn buildPlacements() [total_objects]Placement {
    var out: [total_objects]Placement = undefined;
    // The showcase trio (raylib's modelA/B/C at 0 / -2.6 / +2.6).
    out[0] = .{ .mesh = .torus, .center = .{ 0, 0, 0 }, .spin_rate = 0.6, .base_color = .{ 0.9, 0.55, 0.35, 1 } };
    out[1] = .{ .mesh = .cube, .center = .{ -2.6, 0, 0 }, .spin_rate = -0.4, .base_color = .{ 0.45, 0.7, 0.9, 1 } };
    out[2] = .{ .mesh = .sphere, .center = .{ 2.6, 0, 0 }, .spin_rate = 0, .base_color = .{ 0.55, 0.85, 0.55, 1 } };
    // The fog ruler: identical toruses every 2 units — the eye reads the
    // density directly off how many survive.
    for (out[3..], 0..) |*p, i| {
        const x: f32 = float(i) * 2.0 - 20.0;
        p.* = .{ .mesh = .torus, .center = .{ x, 0, 2 }, .spin_rate = 0, .base_color = .{ 0.8, 0.78, 0.72, 1 } };
    }
    return out;
}

// ============================================================================
// GPU plumbing — one pipeline, per-object uniform pairs.
// ============================================================================

/// A generated mesh, uploaded: interleaved position+normal VBO + u32 IBO.
const GpuMesh = struct {
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
};

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

/// Interleave a raylib-shaped `types.Mesh` (separate positions/normals,
/// optional u16 indices) into the engine's position+normal vertex layout
/// and upload.  Generated meshes sometimes ship WITHOUT indices (pure
/// triangle soup) — then the index buffer is just 0..N.
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
    empty_bg: z.wgpu.BindGroupHandle, // group 1 hole (no samplers in this material)
    rt: z.RenderTexture,
    objs: [total_objects]Obj,
    meshes: [3]GpuMesh, // torus, cube, sphere — shared across objs, freed once
    ui_host: z.UiHost,
    font: z.Font,

    fog_density: f32 = 0.15, // raylib's default

    cam_yaw: f32 = 1.35,
    cam_pitch: f32 = 0.3,
    cam_dist: f32 = 9.0,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (&s.objs) |*o| {
        z.wgpu.destroyBuffer(o.vs_ubo);
        z.wgpu.destroyBuffer(o.fs_ubo);
        z.wgpu.destroyBindGroup(o.g0_bg);
        z.wgpu.destroyBindGroup(o.g2_bg);
    }
    for (&s.meshes) |*m| {
        z.wgpu.destroyBuffer(m.vbo);
        z.wgpu.destroyBuffer(m.ibo);
    }
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyRenderPipeline(s.pipeline);
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

    // ---- generated geometry, the same raylib generators (ported) ----
    const torus_mesh: z.Mesh = try z.genMeshTorus(gpa, 0.4, 1.0, 16, 32);
    defer z.unloadMesh(gpa, torus_mesh);
    const cube_mesh: z.Mesh = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    defer z.unloadMesh(gpa, cube_mesh);
    const sphere_mesh: z.Mesh = try z.genMeshSphere(gpa, 0.6, 24, 24);
    defer z.unloadMesh(gpa, sphere_mesh);

    const torus: GpuMesh = try uploadMesh(gpa, device, queue, torus_mesh, "fog_torus");
    const cube: GpuMesh = try uploadMesh(gpa, device, queue, cube_mesh, "fog_cube");
    const sphere: GpuMesh = try uploadMesh(gpa, device, queue, sphere_mesh, "fog_sphere");

    // ---- pipeline: gbuffer_vs (reused) + fog_fs, single rgba8 target ----
    const pos_normal_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(MeshVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FogVsUbo), .{ .vertex = true }, "fog_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FogFsUbo), .{ .fragment = true }, "fog_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "fog_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "fog_empty_bg");

    const pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, g2_bgl },
        "fog_pl",
    );
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fog_fs_wgsl, "fog_fs");
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_normal_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
    });
    defer gpa.free(pipe_blob);
    const pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        pl,
        vs_mod,
        fs_mod,
        pipe_blob,
        "fog_pipe",
    );

    // ---- per-object uniform pairs ----
    var objs: [total_objects]Obj = undefined;
    for (&objs, placements) |*slot, p| {
        const gm: GpuMesh = switch (p.mesh) {
            .torus => torus,
            .cube => cube,
            .sphere => sphere,
        };
        const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(FogVsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(FogFsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        slot.* = .{
            .mesh = gm,
            .vs_ubo = vs_ubo,
            .g0_bg = try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(FogVsUbo), "fog_g0_bg"),
            .fs_ubo = fs_ubo,
            .g2_bg = try uniformBindGroup(gpa, device, g2_bgl, fs_ubo, @sizeOf(FogFsUbo), "fog_g2_bg"),
        };
    }

    // Build-only intermediates: with the pipeline + per-object bind groups built,
    // their source layouts/modules are no longer needed — release them now. Only
    // the runtime handles below survive into State (freed in deinit).
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(g2_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
    z.wgpu.destroyPipelineLayout(pl);
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .pipeline = pipeline,
        .empty_bg = empty_bg,
        .rt = .{},
        .objs = objs,
        .meshes = .{ torus, cube, sphere },
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
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.02, 4.0, 18.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.05, 1.4);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.5, 4.0, 18.0);
    }
}

fn writeUniforms(
    f: *z.Frame,
    s: *State,
    t: f32,
    cam_vp: Mat,
    cam_eye: Vec,
) void {
    for (&s.objs, placements) |*obj, p| {
        const spin: Mat = rotationY(p.spin_rate * t);
        const model: Mat = mulMat(translation(p.center[0], p.center[1], p.center[2]), spin);

        var vs_io: fog_vs.Io = undefined;
        vs_io.u = .{
            .mvp = mulMat(cam_vp, model),
            .model = model,
            .normal_matrix = spin,
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

        var fs_io: fog_fs.Io = undefined;
        fs_io.u = .{
            .base_color = p.base_color,
            .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
            .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
            .fog_color = .{ fog_rgb[0], fog_rgb[1], fog_rgb[2], 1 },
            .params = .{ s.fog_density, 0, 0, 0 },
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.fs_ubo, 0, std.mem.asBytes(&fs_io.u));
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    // ---- camera ----
    const cam_target: Vec = vec(0, 0.4, 0);
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
    const cam_proj: Mat = perspectiveFovRh(0.8, vw / vh, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    writeUniforms(f, s, t, cam_vp, cam_eye);
    const Backend: type = z.WgpuBackend;

    // ---- the one pass: forward fog material into the canvas RTT ----
    z.beginTextureModeRaw(f.gl, s.rt, fog_clear);
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

    const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // SCREEN PASS: open once, composite, then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, fog_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    // ---- UI: the fog dial ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 96 }, .{});
    u.setNextWindowSize(.{ panel_w, 88 }, .{});
    if (u.window("fog", .{})) |w| {
        defer w.close();
        _ = u.slider("density", &s.fog_density, .{ .min = 0.0, .max = 0.45 });
        u.text("drag orbits - pinch zooms", .{});
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - distance fog (shared gbuffer_vs)",
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
