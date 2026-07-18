//! point_rendering — raylib's `models_point_rendering`, the zimr way.
//!
//! A random spherical point cloud (raylib's exact distribution: uniform
//! theta/phi/radius, so the density bunches toward the core and the
//! poles — that look is part of the original) with each point coloured
//! `colorFromHSV(r * 360, 1, 1)`: the hue wraps ten times over the
//! 10-unit radius, giving the signature rainbow shells.  Rendered as a
//! single `point_list` draw through the new `points3d_vs` (unlit, one
//! VP uniform) + the existing `cube3d_fs` passthrough.
//!
//! raylib steps the count 1k → 10M by tens and toggles between a GPU
//! point-mesh and a CPU `DrawPoint3D` loop (a GL point-mode lesson
//! with no WebGPU analogue — there is only one honest way to draw
//! points here).  This port keeps the count stepping (capped at 1M:
//! one point is 16 bytes, so 1M = a 16MB vertex buffer — the ceiling a
//! phone should be asked to hold), with live FPS so the cost curve is
//! still the demo.  The buffer is allocated ONCE at the 1M cap;
//! stepping the count regenerates points into the same buffer via
//! `queueWriteBuffer` and changes only the draw's vertex_count — no
//! per-step allocation churn.
//!
//! raylib's yellow wire sphere landmark is here too, translated into
//! the medium: three great-circle rings of yellow POINTS riding the
//! same pipeline (r = 1, at the origin, inside the cloud).
//!
//! Phone-first: slow auto-orbit like raylib's CAMERA_ORBITAL; one
//! finger drags to take over the orbit, pinch zooms.

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
const pi = zm.pi;
const vec = zm.vec;

const pts_vs = z.points3d_shader;

pub var zimr_app: z.App = .{};

const points3d_vs_wgsl = @embedFile("points3d_vs.wgsl");
const cube3d_fs_wgsl = @embedFile("cube3d_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const VsUbo = @FieldType(pts_vs.Io, "u");

const bg_clear: Color = .{ .r = 8, .g = 8, .b = 12, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const fovy_rad: f32 = 0.8;

const min_points: u32 = 1_000;
const max_points: u32 = 1_000_000;
/// Yellow "wire" landmark: 3 rings x ring_segs points, appended after
/// the cloud in the same buffer.
const ring_segs: u32 = 96;
const marker_points: u32 = 3 * ring_segs;

/// One point: world position + rgba8 colour.  The unorm8x4 attribute
/// arrives in the shader normalized to [0,1].
const PointVertex = extern struct {
    position: [3]f32,
    color: [4]u8,
};

const State = struct {
    gpa: Allocator,
    pipeline: z.wgpu.RenderPipelineHandle,
    vbo: z.wgpu.BufferHandle,
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    scratch: []PointVertex, // CPU staging for regeneration (max size)

    num_points: u32 = 1_000,
    rng: std.Random.DefaultPrng,

    rt: z.RenderTexture,
    ui_host: z.UiHost,

    cam_yaw: f32 = 0.8,
    cam_pitch: f32 = 0.6,
    cam_dist: f32 = 14.0,
    auto_orbit: bool = true,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.scratch);
    s.ui_host.deinit();
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.vs_ubo);
    z.wgpu.destroyBindGroup(s.g0_bg);
    s.rt.deinit();
}

/// raylib's GenMeshPoints, verbatim distribution: uniform theta in
/// [0,pi], phi in [0,2pi], r in [0,10]; colour = HSV(r*360, 1, 1).
fn regenPoints(s: *State, f: *z.Frame) void {
    const rand: std.Random = s.rng.random();
    var i: u32 = 0;
    while (i < s.num_points) : (i += 1) {
        const theta: f32 = pi * rand.float(f32);
        const phi: f32 = 2.0 * pi * rand.float(f32);
        const r: f32 = 10.0 * rand.float(f32);
        const c: Color = z.colorFromHSV(r * 360.0, 1.0, 1.0);
        s.scratch[i] = .{
            .position = .{
                r * @sin(theta) * @cos(phi),
                r * @sin(theta) * @sin(phi),
                r * @cos(theta),
            },
            .color = .{ c.r, c.g, c.b, 255 },
        };
    }
    // The landmark rides after the cloud: three unit great circles
    // (XY, XZ, YZ) of yellow points — raylib's wire sphere, pointified.
    var m: u32 = 0;
    while (m < marker_points) : (m += 1) {
        const ring: u32 = m / ring_segs;
        const a: f32 = 2.0 * pi * float(m % ring_segs) / float(ring_segs);
        const ca: f32 = @cos(a);
        const sa: f32 = @sin(a);
        const p: [3]f32 = switch (ring) {
            0 => .{ ca, sa, 0 },
            1 => .{ ca, 0, sa },
            else => .{ 0, ca, sa },
        };
        s.scratch[s.num_points + m] = .{ .position = p, .color = .{ 253, 249, 0, 255 } };
    }
    const used: usize = s.num_points + marker_points;
    z.wgpu.queueWriteBuffer(
        f.gpu.queue,
        s.vbo,
        0,
        std.mem.sliceAsBytes(s.scratch[0..used]),
    );
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    const cap: usize = max_points + marker_points;
    const scratch: []PointVertex = try gpa.alloc(PointVertex, cap);
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = cap * @sizeOf(PointVertex),
        .usage = .{ .vertex = true, .copy_dst = true },
    });
    const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(VsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    const entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(VsUbo) } },
        },
    };
    const bgl_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &entries);
    defer gpa.free(bgl_blob);
    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, bgl_blob, "pts_g0");
    const bg_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = vs_ubo, .size = @sizeOf(VsUbo) } } },
    };
    const bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &bg_entries);
    defer gpa.free(bg_blob);
    const g0_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, g0_bgl, bg_blob, "pts_g0_bg");

    const pl: z.wgpu.PipelineLayoutHandle =
        z.wgpu.createPipelineLayout(device, &.{g0_bgl}, "pts_pl");
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, points3d_vs_wgsl, "points3d_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, cube3d_fs_wgsl, "cube3d_fs");
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .point_list,
        .none,
        .less,
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{.{
            .array_stride = @sizeOf(PointVertex),
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .uint8x4_unorm, .offset = 12, .shader_location = 1 },
            },
        }},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
    });
    defer gpa.free(pipe_blob);
    const pipeline: z.wgpu.RenderPipelineHandle =
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "pts_pipe");

    s.* = .{
        .gpa = gpa,
        .pipeline = pipeline,
        .vbo = vbo,
        .vs_ubo = vs_ubo,
        .g0_bg = g0_bg,
        .scratch = scratch,
        .rng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15),
        .rt = .{},
        .ui_host = z.UiHost.init(gpa, try z.loadFont(f, gpa, atkinson_mono_ttf, 22)),
    };
    regenPoints(s, f);

    // Build-only intermediates internalized by the pipeline + bind group.
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
    z.wgpu.destroyPipelineLayout(pl);
    z.wgpu.destroyBindGroupLayout(g0_bgl);
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
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.04, 4.0, 30.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, -1.4, 1.4);
            s.auto_orbit = false; // a touch takes the wheel
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.8, 4.0, 30.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const dt: f32 = @floatCast(f.time.delta_time);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    if (s.auto_orbit) {
        s.cam_yaw += dt * 0.25; // raylib's CAMERA_ORBITAL pace
    }

    // ---- camera + the one uniform ----
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const cy: f32 = @cos(s.cam_yaw);
    const sy: f32 = @sin(s.cam_yaw);
    const cam_eye: Vec = vec(
        s.cam_dist * cp * sy,
        s.cam_dist * sp,
        s.cam_dist * cp * cy,
    );
    const cam_view: Mat = lookAtRh(cam_eye, vec(0, 0, 0), vec(0, 1, 0));
    const cam_proj: Mat = perspectiveFovRh(fovy_rad, vw / vh, 0.1, 200.0);
    var vs_io: pts_vs.Io = undefined;
    vs_io.u = .{ .view_projection = mulMat(cam_proj, cam_view) };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

    // ---- one point_list draw for cloud + landmark ----
    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(pa, 0, s.g0_bg);
    z.render_pass.setVertexBuffer(pa.pass, .{
        .slot = 0,
        .buffer = s.vbo,
        .offset = 0,
        .size = (@as(u64, s.num_points) + marker_points) * @sizeOf(PointVertex),
    });
    z.render_pass.draw(pa.pass, .{
        .vertex_count = s.num_points + marker_points,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    z.endTextureModeRaw(f.gl);

    // SCREEN PASS: open once, composite, then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    // ---- UI ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 148 }, .{});
    u.setNextWindowSize(.{ panel_w, 140 }, .{});
    if (u.window("point rendering", .{})) |w| {
        defer w.close();
        u.text("points: {d}", .{s.num_points});
        const fps: f32 = if (dt > 0.0001) 1.0 / dt else 0.0;
        u.text("fps: {d:.0}", .{fps});
        var changed: bool = false;
        if (u.button("x10", .{})) {
            s.num_points = @min(s.num_points * 10, max_points);
            changed = true;
        }
        u.sameLine(.{});
        if (u.button("/10", .{})) {
            s.num_points = @max(s.num_points / 10, min_points);
            changed = true;
        }
        u.sameLine(.{});
        _ = u.checkbox("orbit", &s.auto_orbit);
        if (changed) {
            regenPoints(s, f);
        }
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - point rendering (1k to 1M points)",
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
