//! first_person_maze — raylib's `models_first_person_maze`, the zimr way.
//!
//! The same cubicmap maze as `cubicmap.zig` (white pixel = wall column,
//! black = corridor), but you WALK it in first person instead of
//! orbiting. The maze mesh comes from `genMeshCubicmap` and is drawn
//! with the face-shaded `maze_fs` on the shared `gbuffer_vs`; the map
//! pixels stay resident on the CPU so we can collide the player against
//! wall cells.
//!
//! Movement + collision follow raylib: store the old camera position,
//! move, then if the player's collision circle overlaps any WALL cell
//! in the 3×3 neighborhood around it, snap back — so you slide along
//! walls and can't clip through. raylib uses WASD + locked-mouse look;
//! phone-first here means a left thumb-zone drag turns you (and a nudge
//! forward walks), while a right-side "walk" toggle auto-advances so
//! one thumb is enough. A minimap in the corner shows the maze from
//! above with a red dot for the player.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const vec = zm.vec;
const float = zm.float;

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
const wall_dot: Color = .{ .r = 150, .g = 155, .b = 165, .a = 255 };
const floor_dot: Color = .{ .r = 34, .g = 38, .b = 48, .a = 255 };
const player_dot: Color = .{ .r = 230, .g = 60, .b = 60, .a = 255 };
const sun_dir: [3]f32 = .{ 0.45, 0.8, 0.4 };

// Odd dims so the DFS carve leaves a clean 1-cell wall border.
const grid_w: i32 = 17;
const grid_h: i32 = 17;
const cube_size: [3]f32 = .{ 1.0, 1.0, 1.0 };
// genMeshCubicmap places cell (cx,cz) centered at world (cx, ·, cz)
// directly — the mesh spans world 0..(grid-1), it is NOT centered on the
// origin. So the cell<->world map is the identity (cell centers ARE integer
// world coords) and wall AABBs are unit squares around them.
const eye_height: f32 = 0.45;
const player_radius: f32 = 0.28;
const move_speed: f32 = 2.6; // world units / second
const turn_speed: f32 = 2.4; // radians / second

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
fn carveMaze(gpa: Allocator, rng: *std.Random.DefaultPrng) !z.Image {
    const img: z.Image = try z.genImageColor(gpa, grid_w, grid_h, white);
    const px: [*]Color = @ptrCast(@alignCast(img.data.?));
    const w: usize = @intCast(grid_w);
    const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const rand: std.Random = rng.random();
    var stack: std.ArrayList([2]usize) = .empty;
    defer stack.deinit(gpa);
    px[1 * w + 1] = black;
    try stack.append(gpa, .{ 1, 1 });

    while (stack.items.len > 0) {
        const cur: [2]usize = stack.items[stack.items.len - 1];
        const cx: usize = cur[0];
        const cz: usize = cur[1];
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
                continue;
            }
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

    // Resident maze pixels for collision (true = wall cell).
    walls: [@intCast(grid_w * grid_h)]bool = undefined,

    rng: std.Random.DefaultPrng,
    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    // First-person state: position on the floor plane + facing angle.
    px_pos: f32 = 0,
    pz_pos: f32 = 0,
    yaw: f32 = 0,
    regen_requested: bool = false,
    dragging: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyBindGroup(s.g0_bg);
    z.wgpu.destroyBindGroup(s.g2_bg);
    z.wgpu.destroyBuffer(s.vs_ubo);
    z.wgpu.destroyBuffer(s.fs_ubo);
    z.wgpu.destroyBuffer(s.mesh.vbo);
    s.rt.deinit();
    gpa.free(s.scratch);
    s.ui_host.deinit();
}

fn isWall(s: *const State, cx: i32, cz: i32) bool {
    if (cx < 0 or cz < 0 or cx >= grid_w or cz >= grid_h) {
        return true; // out of bounds reads as solid
    }
    return s.walls[@intCast(cz * grid_w + cx)];
}

/// World x/z → cell index. Cell centers sit at integer world coords, so
/// the nearest cell is just the rounded world coordinate.
fn worldToCellX(wx: f32) i32 {
    const c: i32 = @round(wx);
    return c;
}
fn worldToCellZ(wz: f32) i32 {
    const c: i32 = @round(wz);
    return c;
}
fn cellCenterWorldX(cx: i32) f32 {
    return float(cx);
}
fn cellCenterWorldZ(cz: i32) f32 {
    return float(cz);
}

/// Drop the player at the first open (corridor) cell, facing +Z.
fn placePlayer(s: *State) void {
    var cz: i32 = 1;
    while (cz < grid_h - 1) : (cz += 1) {
        var cx: i32 = 1;
        while (cx < grid_w - 1) : (cx += 1) {
            if (!isWall(s, cx, cz)) {
                s.px_pos = cellCenterWorldX(cx);
                s.pz_pos = cellCenterWorldZ(cz);
                s.yaw = 0;
                return;
            }
        }
    }
}

/// Carve a fresh maze, cache its wall bits, rebuild the mesh, and
/// respawn the player in an open cell.
fn regen(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try carveMaze(gpa, &s.rng);
    defer z.unloadImage(gpa, img);

    const px: [*]const Color = @ptrCast(@alignCast(img.data.?));
    for (0..@intCast(grid_w * grid_h)) |i| {
        s.walls[i] = px[i].r == 255;
    }

    const mesh: z.Mesh = try z.genMeshCubicmap(gpa, img, vec(cube_size[0], cube_size[1], cube_size[2]));
    defer z.unloadMesh(gpa, mesh);
    s.mesh.vcount = fillMesh(f.gpu.queue, s.mesh.vbo, mesh, s.scratch);

    placePlayer(s);
}

/// Would the player's circle at (wx,wz) overlap a wall cell? Checks the
/// 3×3 neighborhood around the player's cell (raylib's approach).
fn blocked(s: *const State, wx: f32, wz: f32) bool {
    const pcx: i32 = worldToCellX(wx);
    const pcz: i32 = worldToCellZ(wz);
    var cz: i32 = pcz - 1;
    while (cz <= pcz + 1) : (cz += 1) {
        var cx: i32 = pcx - 1;
        while (cx <= pcx + 1) : (cx += 1) {
            if (!isWall(s, cx, cz)) {
                continue;
            }
            // Wall cell's world-space AABB (a unit square centered on it).
            const rect: z.Rectangle = .{
                .x = cellCenterWorldX(cx) - 0.5,
                .y = cellCenterWorldZ(cz) - 0.5,
                .width = 1.0,
                .height = 1.0,
            };
            if (z.checkCollisionCircleRec(.{ wx, wz }, player_radius, rect)) {
                return true;
            }
        }
    }
    return false;
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
        try uniformLayout(gpa, device, @sizeOf(VsUbo), .{ .vertex = true }, "fm_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(FsUbo), .{ .fragment = true }, "fm_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "fm_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "fm_empty_bg");

    const g0_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, g0_bgl, vs_ubo, @sizeOf(VsUbo), "fm_g0_bg");
    const g2_bg: z.wgpu.BindGroupHandle =
        try uniformBindGroup(gpa, device, g2_bgl, fs_ubo, @sizeOf(FsUbo), "fm_g2_bg");

    const pl: z.wgpu.PipelineLayoutHandle =
        z.wgpu.createPipelineLayout(device, &.{ g0_bgl, empty_bgl, g2_bgl }, "fm_pl");
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
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "fm_pipe");

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
        .rng = std.Random.DefaultPrng.init(0x5EED_1A2E),
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
    try regen(gpa, f, s);

    // Build-only intermediates: the pipeline + bind groups are created and
    // internalize what they reference, so these locals can be released now.
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

/// Attempt a move to (nx,nz); on collision, slide by trying each axis
/// independently (so you glide along walls instead of sticking).
fn tryMove(s: *State, nx: f32, nz: f32) void {
    if (!blocked(s, nx, nz)) {
        s.px_pos = nx;
        s.pz_pos = nz;
        return;
    }
    if (!blocked(s, nx, s.pz_pos)) {
        s.px_pos = nx;
        return;
    }
    if (!blocked(s, s.px_pos, nz)) {
        s.pz_pos = nz;
    }
}

/// Drag anywhere outside the UI turns you (yaw only). Looking is
/// horizontal — vertical drag is ignored so you can't tilt off the floor.
fn handleLook(f: *z.Frame, s: *State, ui_wants_mouse: bool) void {
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.yaw -= d[0] * 0.006;
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const dt: f32 = @floatCast(f.time.delta_time);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; camera uses
    // last-frame player state = 1-frame lag). Deferred regen runs here, before any
    // recorded draw references the mesh it rebuilds.
    if (s.regen_requested) {
        s.regen_requested = false;
        regen(s.gpa, f, s) catch {};
    }

    // ---- first-person camera ----
    const eye: Vec = vec(s.px_pos, eye_height, s.pz_pos);
    const target: Vec = vec(s.px_pos + @sin(s.yaw), eye_height, s.pz_pos + @cos(s.yaw));
    const cam_view: Mat = lookAtRh(eye, target, vec(0, 1, 0));
    const cam_proj: Mat = perspectiveFovRh(1.0, vw / vh, 0.02, 200.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    var vs_io: mat_vs.Io = undefined;
    vs_io.u = .{ .mvp = cam_vp, .model = zm.identity(), .normal_matrix = zm.identity() };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.vs_ubo, 0, std.mem.asBytes(&vs_io.u));

    var fs_io: mat_fs.Io = undefined;
    fs_io.u = .{
        .light_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        .col_top = .{ 0.85, 0.86, 0.90, 1 },
        .col_bottom = .{ 0.20, 0.22, 0.28, 1 },
        .col_wall_x = .{ 0.40, 0.55, 0.80, 1 },
        .col_wall_z = .{ 0.80, 0.50, 0.38, 1 },
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

    // ---- SCREEN PASS: open once, composite + minimap, then UI + movement. ----
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });

    // ---- minimap: top-down grid + player dot ----
    drawMinimap(f, s, vw);

    // ---- UI: hold FORWARD to walk, turn buttons, drag to look ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(340, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 122 }, .{});
    u.setNextWindowSize(.{ panel_w, 114 }, .{});
    var hold_forward: bool = false;
    if (u.window("first person maze", .{})) |w| {
        defer w.close();
        u.text("HOLD forward to walk; drag to look", .{});
        // Hold-to-move: the button doesn't need to "fire" — we walk every
        // frame it's held down, read via isItemActive right after it.
        _ = u.button("  forward  ", .{});
        hold_forward = u.isItemActive();
        u.sameLine(.{});
        if (u.button("turn L", .{})) {
            s.yaw += 0.28;
        }
        u.sameLine(.{});
        if (u.button("turn R", .{})) {
            s.yaw -= 0.28;
        }
        u.sameLine(.{});
        if (u.button("new maze", .{})) {
            s.regen_requested = true;
        }
    }
    handleLook(f, s, u.wantCaptureMouse());

    // Walk forward while the forward button (or W) is held.
    const step: f32 = move_speed * dt;
    if (hold_forward or z.isKeyDown(f.input, .w)) {
        tryMove(s, s.px_pos + @sin(s.yaw) * step, s.pz_pos + @cos(s.yaw) * step);
    }
    // Desktop extras: S walks back, A/D turn.
    if (z.isKeyDown(f.input, .s)) {
        tryMove(s, s.px_pos - @sin(s.yaw) * step, s.pz_pos - @cos(s.yaw) * step);
    }
    if (z.isKeyDown(f.input, .a)) {
        s.yaw += turn_speed * dt;
    }
    if (z.isKeyDown(f.input, .d)) {
        s.yaw -= turn_speed * dt;
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

/// A small top-down map in the corner: a cell per pixel-block, walls
/// light, corridors dark, the player a red dot at their cell.
fn drawMinimap(f: *z.Frame, s: *State, vw: f32) void {
    const cell_px: f32 = @max(@min(vw, 480) / 60.0, 4.0);
    const pad: f32 = 8;
    const map_w: f32 = float(grid_w) * cell_px;
    const ox: f32 = vw - map_w - pad;
    const oy: f32 = pad;

    var cz: i32 = 0;
    while (cz < grid_h) : (cz += 1) {
        var cx: i32 = 0;
        while (cx < grid_w) : (cx += 1) {
            const col: Color = if (isWall(s, cx, cz)) wall_dot else floor_dot;
            const cell_pos: Vec2 = .{ ox + float(cx) * cell_px, oy + float(cz) * cell_px };
            f.gl.rect(
                .{ .x = cell_pos[0], .y = cell_pos[1], .width = cell_px - 1, .height = cell_px - 1 },
                .{ .color = col },
            );
        }
    }
    // Player dot at their current cell.
    const pcx: i32 = worldToCellX(s.px_pos);
    const pcz: i32 = worldToCellZ(s.pz_pos);
    const dot_pos: Vec2 = .{ ox + (float(pcx) + 0.5) * cell_px, oy + (float(pcz) + 0.5) * cell_px };
    f.gl.circle(dot_pos, cell_px * 0.5, .{ .color = player_dot, .segments = 14 });
    // A short facing tick.
    f.gl.line(.{ ox + (float(pcx) + 0.5) * cell_px, oy + (float(pcz) + 0.5) * cell_px }, .{
        ox + (float(pcx) + 0.5 + @sin(s.yaw)) * cell_px,
        oy + (float(pcz) + 0.5 + @cos(s.yaw)) * cell_px,
    }, .{ .color = player_dot, .thickness = 2.0 });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - first person maze",
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
    // Renders the maze offscreen before the screen opens (tile-based-GPU safe);
    // owns its own begin/endDrawing.
    .manages_own_frame = true,
};
