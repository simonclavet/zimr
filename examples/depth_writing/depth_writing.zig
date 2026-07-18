//! depth_writing — raylib's `shaders_depth_writing`, the zimr way.
//!
//! The material LIES to the depth buffer:
//! `frag_depth = 1 - shaded.blue` (`depth_write_fs`, raylib's exact
//! gag).  The purple cube (blue ≈ 1) claims depth ≈ 0 and pops in
//! FRONT of everything; the yellow cube (blue = 0) claims depth 1 and
//! sinks BEHIND everything; the teal cube floats between.  Real
//! positions say otherwise, and the impossible occlusion holds up as
//! the camera orbits — that's the whole demo.
//!
//! Upgrade over raylib: a "lie to depth" checkbox.  Off, the same
//! three cubes draw through `fog_fs` at density 0 (an honest Lambert
//! material on the same shared `gbuffer_vs`), so you can flip between
//! physical occlusion and the fraud and watch exactly which edges
//! change.  Drag orbits, pinch zooms.

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

const mat_vs = z.deferred_shaders.gbuffer_vs; // the forward-material VS
const lie_fs = z.depth_write_shader;
const honest_fs = z.fog_shader; // density 0 == plain lambert+blinn

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const depth_write_fs_wgsl = @embedFile("depth_write_fs.wgsl");
const fog_fs_wgsl = @embedFile("fog_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const VsUbo = @FieldType(mat_vs.Io, "u");
const LieUbo = @FieldType(lie_fs.Io, "u");
const HonestUbo = @FieldType(honest_fs.Io, "u");

const bg_clear: Color = .{ .r = 26, .g = 26, .b = 34, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const sun_dir: [3]f32 = .{ 0.4, 0.85, 0.5 };

// Three cubes staggered along z so their REAL depth order (yellow
// nearest, purple farthest at the start pose) is the OPPOSITE of what
// the blue channel claims — maximum fraud visibility.
const Placement = struct {
    center: [3]f32,
    half: f32,
    spin_rate: f32,
    color: [4]f32,
};
const placements = [3]Placement{
    // purple: blue ~0.95 -> claims FRONT
    .{ .center = .{ 0.0, 0.6, -1.4 }, .half = 0.6, .spin_rate = 0.3, .color = .{ 0.75, 0.25, 0.95, 1 } },
    // teal: mid blue -> floats between
    .{ .center = .{ 0.25, 0.6, 0.0 }, .half = 0.6, .spin_rate = -0.25, .color = .{ 0.2, 0.85, 0.85, 1 } },
    // yellow: blue 0 -> claims BACK
    .{ .center = .{ 0.5, 0.6, 1.4 }, .half = 0.6, .spin_rate = 0.35, .color = .{ 0.95, 0.85, 0.05, 1 } },
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

const Obj = struct {
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    lie_ubo: z.wgpu.BufferHandle,
    lie_bg: z.wgpu.BindGroupHandle,
    honest_ubo: z.wgpu.BufferHandle,
    honest_bg: z.wgpu.BindGroupHandle,
};

const State = struct {
    gpa: Allocator,
    lie_pipeline: z.wgpu.RenderPipelineHandle,
    honest_pipeline: z.wgpu.RenderPipelineHandle,
    empty_bg: z.wgpu.BindGroupHandle,
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    objs: [3]Obj,
    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    lie: bool = true,

    cam_yaw: f32 = 0.9,
    cam_pitch: f32 = 0.35,
    cam_dist: f32 = 6.5,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (&s.objs) |*obj| {
        z.wgpu.destroyBuffer(obj.vs_ubo);
        z.wgpu.destroyBuffer(obj.lie_ubo);
        z.wgpu.destroyBuffer(obj.honest_ubo);
        z.wgpu.destroyBindGroup(obj.g0_bg);
        z.wgpu.destroyBindGroup(obj.lie_bg);
        z.wgpu.destroyBindGroup(obj.honest_bg);
    }
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.ibo);
    z.wgpu.destroyRenderPipeline(s.lie_pipeline);
    z.wgpu.destroyRenderPipeline(s.honest_pipeline);
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

fn makePipeline(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    layout: z.wgpu.PipelineLayoutHandle,
    vs_mod: z.wgpu.ShaderModuleHandle,
    fs_mod: z.wgpu.ShaderModuleHandle,
    label: []const u8,
) !z.wgpu.RenderPipelineHandle {
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .back,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
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
    defer gpa.free(blob);
    return z.wgpu.createRenderPipeline(device, layout, vs_mod, fs_mod, blob, label);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;

    const vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "dw_vbo",
    );
    const ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "dw_ibo",
    );

    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "dw_g0");
    const lie_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(LieUbo), .{ .fragment = true }, "dw_lie_g2");
    const honest_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(HonestUbo), .{ .fragment = true }, "dw_hon_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "dw_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "dw_empty_bg");

    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const lie_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, depth_write_fs_wgsl, "depth_write_fs");
    const honest_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fog_fs_wgsl, "fog_fs");

    const lie_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, lie_bgl },
        "dw_lie_pl",
    );
    const honest_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ g0_bgl, empty_bgl, honest_bgl },
        "dw_hon_pl",
    );

    var objs: [3]Obj = undefined;
    for (&objs) |*obj| {
        const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(VsUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const lie_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(LieUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        const honest_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
            .size = @sizeOf(HonestUbo),
            .usage = .{ .uniform = true, .copy_dst = true },
        });
        obj.* = .{
            .vs_ubo = vs_ubo,
            .g0_bg = try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "dw_g0_bg"),
            .lie_ubo = lie_ubo,
            .lie_bg = try uniformBindGroup(gpa, device, lie_bgl, lie_ubo, @sizeOf(LieUbo), "dw_lie_bg"),
            .honest_ubo = honest_ubo,
            .honest_bg = try uniformBindGroup(gpa, device, honest_bgl, honest_ubo, @sizeOf(HonestUbo), "dw_hon_bg"),
        };
    }

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .lie_pipeline = try makePipeline(gpa, device, lie_pl, vs_mod, lie_mod, "dw_lie"),
        .honest_pipeline = try makePipeline(gpa, device, honest_pl, vs_mod, honest_mod, "dw_honest"),
        .empty_bg = empty_bg,
        .vbo = vbo,
        .ibo = ibo,
        .objs = objs,
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };

    // Build-only intermediates: the pipelines + bind groups have been created
    // and internalize what they reference, so these locals (never stored in
    // State) can be released now.
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(lie_mod);
    z.wgpu.destroyShaderModule(honest_mod);
    z.wgpu.destroyPipelineLayout(lie_pl);
    z.wgpu.destroyPipelineLayout(honest_pl);
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(lie_bgl);
    z.wgpu.destroyBindGroupLayout(honest_bgl);
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

fn handleInput(f: *z.Frame, s: *State, ui_wants_mouse: bool) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.02, 3.5, 14.0);
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
        s.cam_dist = clamp(s.cam_dist - wheel * 0.5, 3.5, 14.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    const cam_target: Vec = vec(0.25, 0.6, 0);
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

    for (&s.objs, placements) |*obj, p| {
        const spin: Mat = rotationY(p.spin_rate * t);
        const model: Mat = mulMat(
            translation(p.center[0], p.center[1], p.center[2]),
            mulMat(spin, scaling(p.half, p.half, p.half)),
        );
        var vs_io: mat_vs.Io = undefined;
        vs_io.u = .{ .mvp = mulMat(cam_vp, model), .model = model, .normal_matrix = spin };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

        var lie_io: lie_fs.Io = undefined;
        lie_io.u = .{
            .base_color = p.color,
            .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.lie_ubo, 0, std.mem.asBytes(&lie_io.u));

        var hon_io: honest_fs.Io = undefined;
        hon_io.u = .{
            .base_color = p.color,
            .view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 },
            .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
            .fog_color = .{ 0, 0, 0, 1 },
            .params = .{ 0, 0, 0, 0 }, // density 0: fog_fs degrades to plain lambert+blinn
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.honest_ubo, 0, std.mem.asBytes(&hon_io.u));
    }

    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    const pipe: z.wgpu.RenderPipelineHandle = if (s.lie) s.lie_pipeline else s.honest_pipeline;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = pipe });
    Backend.setBindGroup(pa, 1, s.empty_bg);
    z.render_pass.setVertexBuffer(pa.pass, .{
        .slot = 0,
        .buffer = s.vbo,
        .offset = 0,
        .size = @sizeOf(@TypeOf(cube_verts)),
    });
    z.render_pass.setIndexBuffer(pa.pass, .{
        .buffer = s.ibo,
        .format = .uint32,
        .offset = 0,
        .size = @sizeOf(@TypeOf(cube_indices)),
    });
    for (&s.objs) |*obj| {
        Backend.setBindGroup(pa, 0, obj.g0_bg);
        Backend.setBindGroup(pa, 2, if (s.lie) obj.lie_bg else obj.honest_bg);
        z.render_pass.drawIndexed(pa.pass, .{
            .index_count = cube_indices.len,
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
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 118 }, .{});
    u.setNextWindowSize(.{ panel_w, 110 }, .{});
    if (u.window("depth writing", .{})) |w| {
        defer w.close();
        _ = u.checkbox("lie to depth", &s.lie);
        const caption: []const u8 = if (s.lie)
            "purple claims FRONT, yellow BACK"
        else
            "honest occlusion";
        u.text("{s}", .{caption});
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - fragment depth writing",
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
