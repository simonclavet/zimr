//! cel_shading — raylib's `shaders_cel_shading`, the zimr way.
//!
//! Two draws of the same bunny:
//!
//!   1. THE HULL: the mesh inflated along its normals (`outline_hull_vs`)
//!      with FRONT faces culled — only the shell's silhouette survives
//!      the depth test, painted flat ink by `depth_fs` (reused).
//!   2. THE TOON: `cel_fs` on `gbuffer_vs` (both reused patterns — the
//!      forward-material vertex stage and the color-passthrough FS),
//!      Lambert snapped to N flat bands.
//!
//! Shader ledger for the whole example: cel_fs + outline_hull_vs are
//! new; gbuffer_vs and depth_fs are borrowed.  Two files for a
//! two-pass stylized renderer.
//!
//! raylib demos this on a car glb with Q/E band keys and a C outline
//! toggle; ours is the Stanford bunny with sliders for bands and ink
//! thickness, an outline checkbox, a slowly circling sun (bands sweep
//! across the fur live), drag-orbit and pinch-zoom.

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
const rotationY = zm.rotationY;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

const toon_vs = z.deferred_shaders.gbuffer_vs; // the forward-material VS
const toon_fs = z.toon_shaders.cel_fs;
const hull_vs = z.toon_shaders.outline_hull_vs;
// (the hull's FS is depth_fs — only its WGSL artifact is needed here)

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const cel_fs_wgsl = @embedFile("cel_fs.wgsl");
const outline_hull_vs_wgsl = @embedFile("outline_hull_vs.wgsl");
const depth_fs_wgsl = @embedFile("depth_fs.wgsl");
const bunny_obj = @embedFile("bunny.obj");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const ToonVsUbo = @FieldType(toon_vs.Io, "u");
const ToonFsUbo = @FieldType(toon_fs.Io, "u");
const HullUbo = @FieldType(hull_vs.Io, "u");

const bg_clear: Color = .{ .r = 245, .g = 245, .b = 246, .a = 255 }; // raylib's RAYWHITE
const bunny_albedo: [4]f32 = .{ 0.95, 0.62, 0.35, 1 }; // warm poster orange
const ink: [4]f32 = .{ 0.05, 0.05, 0.06, 1 }; // near-black

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const State = struct {
    gpa: Allocator,
    toon_pipeline: z.wgpu.RenderPipelineHandle, // cull back
    hull_pipeline: z.wgpu.RenderPipelineHandle, // cull FRONT — the trick

    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,

    toon_vs_ubo: z.wgpu.BufferHandle,
    toon_g0_bg: z.wgpu.BindGroupHandle,
    toon_fs_ubo: z.wgpu.BufferHandle,
    toon_g2_bg: z.wgpu.BindGroupHandle,
    hull_ubo: z.wgpu.BufferHandle,
    hull_g0_bg: z.wgpu.BindGroupHandle,
    empty_bg: z.wgpu.BindGroupHandle,

    // Bunny placement frame (center + scale-to-height), obj units.
    center: [3]f32,
    min_y: f32,
    scale: f32,

    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    bands: f32 = 4.0,
    thickness: f32 = 0.015, // WORLD units (converted to model space per frame)
    outline_on: bool = true,

    cam_yaw: f32 = 0.6,
    cam_pitch: f32 = 0.35,
    cam_dist: f32 = 5.5,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.ibo);
    z.wgpu.destroyBuffer(s.toon_vs_ubo);
    z.wgpu.destroyBuffer(s.toon_fs_ubo);
    z.wgpu.destroyBuffer(s.hull_ubo);
    z.wgpu.destroyBindGroup(s.toon_g0_bg);
    z.wgpu.destroyBindGroup(s.toon_g2_bg);
    z.wgpu.destroyBindGroup(s.hull_g0_bg);
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyRenderPipeline(s.toon_pipeline);
    z.wgpu.destroyRenderPipeline(s.hull_pipeline);
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

    // ---- the bunny, parsed + measured (shadowmap_sw's pattern) ----
    var bunny_data: z.codecs.obj.Data = try z.codecs.obj.parse(gpa, bunny_obj);
    defer bunny_data.deinit(gpa);
    const mesh: z.codecs.obj.Mesh = try bunny_data.toMesh(gpa);
    defer mesh.deinit(gpa);

    const vcount: usize = mesh.vertexCount();
    const verts: []MeshVertex = try gpa.alloc(MeshVertex, vcount);
    defer gpa.free(verts);
    var mn: [3]f32 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var mx: [3]f32 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (verts, 0..) |*sv, i| {
        const p: [3]f32 = .{
            mesh.positions[i * 3 + 0],
            mesh.positions[i * 3 + 1],
            mesh.positions[i * 3 + 2],
        };
        sv.* = .{ .position = p, .normal = .{
            mesh.normals[i * 3 + 0],
            mesh.normals[i * 3 + 1],
            mesh.normals[i * 3 + 2],
        } };
        var a: usize = 0;
        while (a < 3) : (a += 1) {
            mn[a] = @min(mn[a], p[a]);
            mx[a] = @max(mx[a], p[a]);
        }
    }

    const vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(verts),
        .{ .vertex = true, .copy_dst = true },
        "cel_vbo",
    );
    const ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(mesh.indices),
        .{ .index = true, .copy_dst = true },
        "cel_ibo",
    );

    // ---- pipelines: same layout shape, opposite cull faces ----
    const pos_normal_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(MeshVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    const toon_g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(ToonVsUbo), .{ .vertex = true }, "cel_g0");
    const toon_g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(ToonFsUbo), .{ .fragment = true }, "cel_g2");
    const hull_g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(HullUbo), .{ .vertex = true }, "hull_g0");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "cel_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "cel_empty_bg");

    const toon_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ toon_g0_bgl, empty_bgl, toon_g2_bgl },
        "cel_pl",
    );
    const hull_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{hull_g0_bgl},
        "hull_pl",
    );

    const toon_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const toon_fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, cel_fs_wgsl, "cel_fs");
    const hull_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, outline_hull_vs_wgsl, "outline_hull_vs");
    const ink_fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, depth_fs_wgsl, "depth_fs");

    const toon_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .back, // normal model pass
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const toon_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_normal_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = toon_combo,
    });
    defer gpa.free(toon_blob);
    const toon_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        toon_pl,
        toon_vs_mod,
        toon_fs_mod,
        toon_blob,
        "cel_pipe",
    );

    const hull_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .front, // THE inverted-hull trick: only the shell's far side draws
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const hull_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_normal_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = hull_combo,
    });
    defer gpa.free(hull_blob);
    const hull_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        hull_pl,
        hull_vs_mod,
        ink_fs_mod,
        hull_blob,
        "hull_pipe",
    );

    // ---- uniforms (one object, three blocks) ----
    const toon_vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(ToonVsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const toon_fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(ToonFsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const hull_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(HullUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    const toon_g0_bg = try uniformBindGroup(gpa, device, toon_g0_bgl, toon_vs_ubo, @sizeOf(ToonVsUbo), "cel_g0_bg");
    const toon_g2_bg = try uniformBindGroup(gpa, device, toon_g2_bgl, toon_fs_ubo, @sizeOf(ToonFsUbo), "cel_g2_bg");
    const hull_g0_bg = try uniformBindGroup(gpa, device, hull_g0_bgl, hull_ubo, @sizeOf(HullUbo), "hull_g0_bg");

    // Build-only intermediates consumed above — release them. createRenderPipeline is
    // direct/uncached, so the PIPELINES are example-owned and freed in deinit instead.
    z.wgpu.destroyBindGroupLayout(toon_g0_bgl);
    z.wgpu.destroyBindGroupLayout(toon_g2_bgl);
    z.wgpu.destroyBindGroupLayout(hull_g0_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
    z.wgpu.destroyPipelineLayout(toon_pl);
    z.wgpu.destroyPipelineLayout(hull_pl);
    z.wgpu.destroyShaderModule(toon_vs_mod);
    z.wgpu.destroyShaderModule(toon_fs_mod);
    z.wgpu.destroyShaderModule(hull_vs_mod);
    z.wgpu.destroyShaderModule(ink_fs_mod);

    const ui_font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .toon_pipeline = toon_pipeline,
        .hull_pipeline = hull_pipeline,
        .vbo = vbo,
        .ibo = ibo,
        .vbo_bytes = verts.len * @sizeOf(MeshVertex),
        .ibo_bytes = mesh.indices.len * @sizeOf(u32),
        .icount = @intCast(mesh.indices.len),
        .toon_vs_ubo = toon_vs_ubo,
        .toon_g0_bg = toon_g0_bg,
        .toon_fs_ubo = toon_fs_ubo,
        .toon_g2_bg = toon_g2_bg,
        .hull_ubo = hull_ubo,
        .hull_g0_bg = hull_g0_bg,
        .empty_bg = empty_bg,
        .center = .{ (mn[0] + mx[0]) * 0.5, 0, (mn[2] + mx[2]) * 0.5 },
        .min_y = mn[1],
        .scale = 2.2 / @max(mx[1] - mn[1], 1.0e-4),
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
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.015, 3.0, 12.0);
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
        s.cam_dist = clamp(s.cam_dist - wheel * 0.4, 3.0, 12.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    // ---- camera + the circling sun (bands sweep live) ----
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
    const cam_proj: Mat = perspectiveFovRh(0.8, vw / vh, 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    // raylib: one DIRECTIONAL light from (50,50,50) -> origin (45 deg
    // elevation), spinning at 0.5 rad/s opposite the orbital camera.
    const sun_angle: f32 = t * 0.5;
    const sun: [3]f32 = .{ @cos(sun_angle), 1.0, @sin(sun_angle) };

    // ---- model: recentered, floor-seated, spinning ----
    const spin: Mat = rotationY(t * 0.5);
    const center_it: Mat = translation(-s.center[0], -s.min_y, -s.center[2]);
    const scale_it: Mat = scaling(s.scale, s.scale, s.scale);
    const model: Mat = mulMat(spin, mulMat(scale_it, center_it));
    const mvp: Mat = mulMat(cam_vp, model);

    var toon_vs_io: toon_vs.Io = undefined;
    toon_vs_io.u = .{ .mvp = mvp, .model = model, .normal_matrix = spin };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.toon_vs_ubo, 0, std.mem.asBytes(&toon_vs_io.u));

    var toon_fs_io: toon_fs.Io = undefined;
    toon_fs_io.u = .{
        .base_color = bunny_albedo,
        .light_dir = .{ sun[0], sun[1], sun[2], 0 },
        .params = .{ @round(s.bands), 0, 0, 0 },
    };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.toon_fs_ubo, 0, std.mem.asBytes(&toon_fs_io.u));

    var hull_io: hull_vs.Io = undefined;
    // Slider is WORLD units; extrusion is MODEL-space pre-scale, so
    // convert (the raw value once inflated the hull ~14x into a blob).
    const thickness_model: f32 = s.thickness / s.scale;
    hull_io.u = .{ .mvp = mvp, .ink_color = ink, .params = .{ thickness_model, 0, 0, 0 } };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.hull_ubo, 0, std.mem.asBytes(&hull_io.u));

    const Backend: type = z.WgpuBackend;

    // ---- one pass, two draws: hull (ink) first, toon over it ----
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    z.render_pass.setVertexBuffer(pa.pass, .{ .slot = 0, .buffer = s.vbo, .offset = 0, .size = s.vbo_bytes });
    z.render_pass.setIndexBuffer(pa.pass, .{ .buffer = s.ibo, .format = .uint32, .offset = 0, .size = s.ibo_bytes });
    if (s.outline_on) {
        Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.hull_pipeline });
        Backend.setBindGroup(pa, 0, s.hull_g0_bg);
        z.render_pass.drawIndexed(pa.pass, .{
            .index_count = s.icount,
            .instance_count = 1,
            .first_index = 0,
            .base_vertex = 0,
            .first_instance = 0,
        });
    }
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.toon_pipeline });
    Backend.setBindGroup(pa, 0, s.toon_g0_bg);
    Backend.setBindGroup(pa, 1, s.empty_bg);
    Backend.setBindGroup(pa, 2, s.toon_g2_bg);
    z.render_pass.drawIndexed(pa.pass, .{
        .index_count = s.icount,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    });
    z.endTextureModeRaw(f.gl);

    const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // SCREEN PASS: open once, composite, then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    // ---- UI: bands / ink / outline ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 150 }, .{});
    u.setNextWindowSize(.{ panel_w, 142 }, .{});
    if (u.window("cel", .{})) |w| {
        defer w.close();
        _ = u.slider("bands", &s.bands, .{ .min = 2, .max = 12, .fmt = "{d:.0}" });
        _ = u.slider("ink width", &s.thickness, .{ .min = 0.0, .max = 0.05 });
        _ = u.checkbox("outline", &s.outline_on);
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - cel shading + inverted-hull ink",
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
