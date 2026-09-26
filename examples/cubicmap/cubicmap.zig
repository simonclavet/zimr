//! cubicmap - raylib's `models_cubicmap_rendering`, the zimr way.
//!
//! A pixel map (white = wall, black = corridor) is turned into a
//! cube-walled maze mesh by `genMeshCubicmap` (ported this port - each
//! white cell becomes a cube, and only walls facing empty cells are
//! emitted, so the interior is hollow and cheap). It's drawn with the
//! face-shaded `maze_fs` on the shared `gbuffer_vs`: floor, ceiling,
//! and the two wall orientations each get a distinct tone, so the
//! layout reads from any angle with NO atlas texture.
//!
//! raylib loads a PNG map and drapes an atlas texture over the walls;
//! this port generates the maze procedurally (a randomized DFS carve,
//! so the standalone needs no asset) and reads color from face
//! orientation instead of sampling. "regen" carves a fresh maze into
//! the same GPU buffer. The source map is shown as a corner thumbnail
//! so you can see the grid the walls came from.
//!
//! Phone-first: slow auto-orbit; one finger drags to take over, pinch
//! zooms.

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
const float = zm.float;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const vec = zm.vec;

const mat_vs = z.deferred_shaders.gbuffer_vs;
const mat_fs = z.maze_shader;

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const maze_fs_wgsl = @embedFile("maze_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const VsUbo = @FieldType(mat_vs.Io, "u");
const FsUbo = @FieldType(mat_fs.Io, "u");

const bg_clear: Color = .{ .r = 20, .g = 22, .b = 28, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const sun_dir: [3]f32 = .{ 0.45, 0.8, 0.4 };

// Maze grid: odd dims so the DFS carve leaves a clean 1-cell wall border.
const grid_w: i32 = 17;
const grid_h: i32 = 17;
const cube_size: [3]f32 = .{ 1.0, 1.0, 1.0 };

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const GpuMesh = struct {
    vbo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    vcount: u32,
};

/// Carve a maze into an RGBA8 image: start all-wall (white), then a
/// randomized DFS knocks out corridors (black) on a 2-step lattice.
fn carveMaze(gpa: Allocator, rng: *std.Random.DefaultPrng, offset: i32) !z.Image {
    _ = offset;
    const img: z.Image = try z.genImageColor(gpa, grid_w, grid_h, white);
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));
    const w: usize = @intCast(grid_w);
    const h: usize = @intCast(grid_h);
    const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const rand: std.Random = rng.random();
    // Stack of visited cells (odd coords). Start at (1,1).
    var stack: std.ArrayList([2]usize) = .empty;
    defer stack.deinit(gpa);
    px[1 * w + 1] = black;
    try stack.append(gpa, .{ 1, 1 });

    while (stack.items.len > 0) {
        const cur: [2]usize = stack.items[stack.items.len - 1];
        const cx: usize = cur[0];
        const cz: usize = cur[1];
        // Unvisited neighbors two cells away.
        var dirs: [4][2]i32 = .{ .{ 2, 0 }, .{ -2, 0 }, .{ 0, 2 }, .{ 0, -2 } };
        rand.shuffle([2]i32, &dirs);
        var advanced: bool = false;
        for (dirs) |d| {
            const nx_i: i32 = @as(i32, @intCast(cx)) + d[0];
            const nz_i: i32 = @as(i32, @intCast(cz)) + d[1];
            if (nx_i <= 0 or nz_i <= 0 or nx_i >= grid_w - 1 or nz_i >= grid_h - 1) {
                continue;
            }
            const nx: usize = @intCast(nx_i);
            const nz: usize = @intCast(nz_i);
            if (px[nz * w + nx].r == 0) {
                continue; // already carved
            }
            // Knock out the wall between and the target cell.
            const mx: usize = @intCast(@as(i32, @intCast(cx)) + @divTrunc(d[0], 2));
            const mz: usize = @intCast(@as(i32, @intCast(cz)) + @divTrunc(d[1], 2));
            px[mz * w + mx] = black;
            px[nz * w + nx] = black;
            try stack.append(gpa, .{ nx, nz });
            advanced = true;
            break;
        }
        if (!advanced) {
            _ = stack.pop();
        }
    }
    _ = h;
    return img;
}

fn fillMesh(
    queue: z.wgpu.QueueHandle,
    vbo: z.wgpu.BufferHandle,
    mesh: z.Mesh,
    scratch: []MeshVertex,
) u32 {
    const vcount: usize = @intCast(mesh.vertexCount);
    for (scratch[0..vcount], 0..) |*v, i| {
        v.* = .{
            .position = .{ mesh.vertices[i * 3 + 0], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2] },
            .normal = .{ mesh.normals[i * 3 + 0], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2] },
        };
    }
    z.wgpu.queueWriteBuffer(queue, vbo, 0, std.mem.sliceAsBytes(scratch[0..vcount]));
    return @intCast(vcount);
}

/// Carve a fresh maze, refresh the corner preview, and rebuild the mesh.
fn regen(
    gpa: Allocator,
    f: *z.Frame,
    rng: *std.Random.DefaultPrng,
    vbo: z.wgpu.BufferHandle,
    scratch: []MeshVertex,
    preview: *z.WgpuTexture,
    offset: i32,
) !u32 {
    const img: z.Image = try carveMaze(gpa, rng, offset);
    defer z.unloadImage(gpa, img);

    if (preview.handle != .invalid) {
        preview.deinit();
    }
    preview.* = z.loadTextureFromImage(f.gl, img);

    const mesh: z.Mesh = try z.genMeshCubicmap(gpa, img, vec(cube_size[0], cube_size[1], cube_size[2]));
    defer z.unloadMesh(gpa, mesh);
    return fillMesh(f.gpu.queue, vbo, mesh, scratch);
}

const State = struct {
    gpa: Allocator,
    pipeline: z.wgpu.RenderPipelineHandle,
    empty_bg: z.wgpu.BindGroupHandle,
    mesh: GpuMesh,
    scratch: []MeshVertex,
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    fs_ubo: z.wgpu.BufferHandle,
    g2_bg: z.wgpu.BindGroupHandle,
    preview: z.WgpuTexture = .{},

    rng: std.Random.DefaultPrng,
    offset: i32 = 0,
    regen_requested: bool = false,

    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    cam_yaw: f32 = 0.7,
    cam_pitch: f32 = 0.85,
    cam_dist: f32 = 26.0,
    auto_orbit: bool = true,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    gpa.free(s.scratch);
    if (s.preview.handle != .invalid) {
        s.preview.deinit();
    }
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyBindGroup(s.g0_bg);
    z.wgpu.destroyBindGroup(s.g2_bg);
    z.wgpu.destroyBuffer(s.mesh.vbo);
    z.wgpu.destroyBuffer(s.vs_ubo);
    z.wgpu.destroyBuffer(s.fs_ubo);
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

    // Worst case vertex budget: every cell a full cube (12 tris * 3 verts).
    const cap: usize = @as(usize, @intCast(grid_w)) * @as(usize, @intCast(grid_h)) * 12 * 3;
    const scratch: []MeshVertex = try gpa.alloc(MeshVertex, cap);
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = cap * @sizeOf(MeshVertex),
        .usage = .{ .vertex = true, .copy_dst = true },
    });

    const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(VsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(FsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "cm_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FsUbo), .{ .fragment = true }, "cm_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "cm_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "cm_empty_bg");

    const g0_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "cm_g0_bg");
    const g2_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, g2_bgl, fs_ubo, @sizeOf(FsUbo), "cm_g2_bg");

    const pl: z.wgpu.PipelineLayoutHandle =
        z.wgpu.createPipelineLayout(device, &.{ g0_bgl, empty_bgl, g2_bgl }, "cm_pl");
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, maze_fs_wgsl, "maze_fs");
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
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "cm_pipe");

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .pipeline = pipeline,
        .empty_bg = empty_bg,
        .mesh = .{ .vbo = vbo, .vbo_bytes = cap * @sizeOf(MeshVertex), .vcount = 0 },
        .scratch = scratch,
        .vs_ubo = vs_ubo,
        .g0_bg = g0_bg,
        .fs_ubo = fs_ubo,
        .g2_bg = g2_bg,
        .rng = std.Random.DefaultPrng.init(0xC0FFEE13579),
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
    s.mesh.vcount = try regen(gpa, f, &s.rng, vbo, scratch, &s.preview, s.offset);

    // Build-only intermediates: internalized into the pipeline + bind groups above.
    z.wgpu.destroyBindGroupLayout(g0_bgl);
    z.wgpu.destroyBindGroupLayout(g2_bgl);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
    z.wgpu.destroyPipelineLayout(pl);
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
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
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.05, 8.0, 44.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.15, 1.45);
            s.auto_orbit = false;
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 1.0, 8.0, 44.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const dt: f32 = @floatCast(f.time.delta_time);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag, imperceptible).

    // Run a requested regen HERE, before the RTT (mesh) and composite (preview)
    // reference them - never destroy a texture already recorded into the submit.
    if (s.regen_requested) {
        s.regen_requested = false;
        s.mesh.vcount = regen(s.gpa, f, &s.rng, s.mesh.vbo, s.scratch, &s.preview, s.offset) catch s.mesh.vcount;
    }

    if (s.auto_orbit) {
        s.cam_yaw += dt * 0.2;
    }

    // ---- camera, centered on the maze middle ----
    // genMeshCubicmap lays cubes at w*(i-0.5), so a grid_wxgrid_h maze spans
    // ~-0.5..(grid-1.5); its center is here, NOT the origin.
    const cx: f32 = cube_size[0] * (float(grid_w) - 2.0) * 0.5;
    const cz: f32 = cube_size[2] * (float(grid_h) - 2.0) * 0.5;
    const center: Vec = vec(cx, cube_size[1] * 0.5, cz);
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const cy: f32 = @cos(s.cam_yaw);
    const sy: f32 = @sin(s.cam_yaw);
    const cam_eye: Vec = vec(
        center[0] + s.cam_dist * cp * sy,
        center[1] + s.cam_dist * sp,
        center[2] + s.cam_dist * cp * cy,
    );
    const cam_view: Mat = lookAtRh(cam_eye, center, vec(0, 1, 0));
    const cam_proj: Mat = perspectiveFovRh(1.0, vw / vh, 0.1, 200.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    var vs_io: mat_vs.Io = undefined;
    vs_io.u = .{ .mvp = cam_vp, .model = zm.identity(), .normal_matrix = zm.identity() };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

    var fs_io: mat_fs.Io = undefined;
    fs_io.u = .{
        .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        .col_top = .{ 0.85, 0.86, 0.90, 1 }, // floor / cube tops (bright)
        .col_bottom = .{ 0.20, 0.22, 0.28, 1 }, // ceilings / undersides (dark)
        .col_wall_x = .{ 0.40, 0.55, 0.80, 1 }, // walls facing +/-X (blue)
        .col_wall_z = .{ 0.80, 0.50, 0.38, 1 }, // walls facing +/-Z (terracotta)
    };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.fs_ubo, 0, std.mem.asBytes(&fs_io.u));

    // ---- the maze pass ----
    const Backend: type = z.WgpuBackend;
    z.beginTextureModeRaw(f.gl, s.rt, bg_clear);
    const pa: *z.PassState = f.gl.pass;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.pipeline });
    Backend.setBindGroup(pa, 0, s.g0_bg);
    Backend.setBindGroup(pa, 1, s.empty_bg);
    Backend.setBindGroup(pa, 2, s.g2_bg);
    z.render_pass.setVertexBuffer(pa.pass, .{
        .slot = 0,
        .buffer = s.mesh.vbo,
        .offset = 0,
        .size = @as(u64, s.mesh.vcount) * @sizeOf(MeshVertex),
    });
    z.render_pass.draw(pa.pass, .{
        .vertex_count = s.mesh.vcount,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    z.endTextureModeRaw(f.gl);

    // SCREEN PASS: open once, composite (+ preview), then UI.
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });

    // Corner preview of the source map the maze came from.
    if (s.preview.handle != .invalid) {
        const pv: f32 = @min(vw, vh) * 0.22;
        f.gl.texture(.{ .x = vw - pv - 8, .y = 8, .width = pv, .height = pv }, s.preview, .{ .tint = white });
    }

    // ---- UI ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 120 }, .{});
    u.setNextWindowSize(.{ panel_w, 112 }, .{});
    if (u.window("cubicmap", .{})) |w| {
        defer w.close();
        u.text("image -> genMeshCubicmap", .{});
        if (u.button("regen", .{})) {
            s.offset += 1;
            // Deferred: this frame's RTT + preview blit still reference the
            // current mesh/texture, so regenerate at the TOP of next frame.
            s.regen_requested = true;
        }
        u.sameLine(.{});
        _ = u.checkbox("orbit", &s.auto_orbit);
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - cubicmap maze",
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
