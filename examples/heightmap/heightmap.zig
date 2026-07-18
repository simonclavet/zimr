//! heightmap — raylib's `models_heightmap`, the zimr way.
//!
//! A Perlin-noise image is turned into a terrain mesh by
//! `genMeshHeightmap` (already in the engine — each pixel's grayscale
//! becomes a vertex height), then drawn with the new height-banded
//! `terrain_fs` on the shared `gbuffer_vs`, so the landscape colours
//! itself water→grass→rock→snow from its own shape with no texture
//! upload.  A "regen" button rolls a fresh noise field (new offset)
//! and rebuilds the mesh into the same GPU buffers.
//!
//! raylib loads a PNG heightmap and maps a matching PNG as the
//! surface texture; this port generates the field procedurally (so the
//! standalone needs no asset) and reads height as colour instead of
//! sampling a texture — the terrain look falls out of the geometry.
//!
//! Phone-first: slow auto-orbit; one finger drags to take over, pinch
//! zooms.  The little source-noise image is shown in the corner via
//! `drawTextureRec` so you can see the map the mesh came from.

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
const vec = zm.vec;

const mat_vs = z.deferred_shaders.gbuffer_vs;
const mat_fs = z.terrain_shader;

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const terrain_fs_wgsl = @embedFile("terrain_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const VsUbo = @FieldType(mat_vs.Io, "u");
const FsUbo = @FieldType(mat_fs.Io, "u");

const bg_clear: Color = .{ .r = 18, .g = 22, .b = 30, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
const sun_dir: [3]f32 = .{ 0.5, 0.8, 0.35 };

const map_dim: i32 = 64; // heightmap resolution (raylib uses ~128 PNG)
const terrain_size: [3]f32 = .{ 16.0, 5.0, 16.0 }; // world extents (x, max height, z)

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const GpuMesh = struct {
    vbo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    vcount: u32,
};

/// Turn the engine's heightmap mesh (separate pos/normal float arrays)
/// into our interleaved P3N3 stream and (re)fill the GPU buffer.  The
/// vertex count is fixed by map_dim, so one allocation serves every
/// regen.
fn fillMesh(
    gpa: Allocator,
    queue: z.wgpu.QueueHandle,
    vbo: z.wgpu.BufferHandle,
    mesh: z.Mesh,
    scratch: []MeshVertex,
) void {
    _ = gpa;
    const vcount: usize = @intCast(mesh.vertexCount);
    for (scratch[0..vcount], 0..) |*v, i| {
        v.* = .{
            .position = .{ mesh.vertices[i * 3 + 0], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2] },
            .normal = .{ mesh.normals[i * 3 + 0], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2] },
        };
    }
    z.wgpu.queueWriteBuffer(queue, vbo, 0, std.mem.sliceAsBytes(scratch[0..vcount]));
}

/// Build a fresh Perlin field at `offset`, upload it to `preview`, and
/// regenerate the terrain mesh from it.
fn regen(
    gpa: Allocator,
    f: *z.Frame,
    vbo: z.wgpu.BufferHandle,
    scratch: []MeshVertex,
    preview: *z.WgpuTexture,
    offset: i32,
) !u32 {
    const img: z.Image = try z.genImagePerlinNoise(gpa, map_dim, map_dim, offset, offset, 4.0);
    defer z.unloadImage(gpa, img);

    // Refresh the little corner preview of the source noise.
    if (preview.handle != .invalid) {
        preview.deinit();
    }
    preview.* = z.loadTextureFromImage(f.gl, img);

    const mesh: z.Mesh = try z.genMeshHeightmap(gpa, img, vec(
        terrain_size[0],
        terrain_size[1],
        terrain_size[2],
    ));
    defer z.unloadMesh(gpa, mesh);
    fillMesh(gpa, f.gpu.queue, vbo, mesh, scratch);
    return @intCast(mesh.vertexCount);
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

    offset: i32 = 0,

    rt: z.RenderTexture,
    ui_host: z.UiHost,
    font: z.Font,

    cam_yaw: f32 = 0.7,
    cam_pitch: f32 = 0.6,
    cam_dist: f32 = 26.0,
    auto_orbit: bool = true,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.wgpu.destroyRenderPipeline(s.pipeline);
    z.wgpu.destroyBindGroup(s.empty_bg);
    z.wgpu.destroyBindGroup(s.g0_bg);
    z.wgpu.destroyBindGroup(s.g2_bg);
    z.wgpu.destroyBuffer(s.mesh.vbo);
    z.wgpu.destroyBuffer(s.vs_ubo);
    z.wgpu.destroyBuffer(s.fs_ubo);
    s.preview.deinit();
    s.rt.deinit();
    gpa.free(s.scratch);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    // (map_dim-1)^2 quads * 2 tris * 3 verts — the fixed vertex budget.
    const cap: usize = @as(usize, @intCast(map_dim - 1)) * @as(usize, @intCast(map_dim - 1)) * 6;
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

    const g0_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(VsUbo) } },
        },
    };
    const g0_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g0_entries);
    defer gpa.free(g0_blob);
    const g0_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g0_blob, "hm_g0");
    const g2_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{
            .binding = 0,
            .visibility = .{ .fragment = true },
            .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(FsUbo) } },
        },
    };
    const g2_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g2_entries);
    defer gpa.free(g2_blob);
    const g2_bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(device, g2_blob, "hm_g2");
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "hm_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "hm_empty_bg");

    const g0_bg_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = vs_ubo, .size = @sizeOf(VsUbo) } } },
    };
    const g0_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g0_bg_entries);
    defer gpa.free(g0_bg_blob);
    const g0_bg: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g0_bgl, g0_bg_blob, "hm_g0_bg");
    const g2_bg_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = fs_ubo, .size = @sizeOf(FsUbo) } } },
    };
    const g2_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g2_bg_entries);
    defer gpa.free(g2_bg_blob);
    const g2_bg: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(device, g2_bgl, g2_bg_blob, "hm_g2_bg");

    const pl: z.wgpu.PipelineLayoutHandle =
        z.wgpu.createPipelineLayout(device, &.{ g0_bgl, empty_bgl, g2_bgl }, "hm_pl");
    const vs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(device, terrain_fs_wgsl, "terrain_fs");
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
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, pipe_blob, "hm_pipe");

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
        .rt = .{},
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
    s.mesh.vcount = try regen(gpa, f, vbo, scratch, &s.preview, s.offset);

    // Build-only intermediates: the pipeline + bind groups have internalized
    // what they reference, so these locals can be released now.
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

fn handleInput(f: *z.Frame, s: *State, ui_wants_mouse: bool) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.05, 10.0, 48.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.1, 1.4);
            s.auto_orbit = false;
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 1.0, 10.0, 48.0);
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
        s.cam_yaw += dt * 0.2;
    }

    // ---- camera, centered on the terrain's middle ----
    const cx: f32 = terrain_size[0] * 0.5;
    const cz: f32 = terrain_size[2] * 0.5;
    const center: Vec = vec(cx, terrain_size[1] * 0.35, cz);
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
        .band_lo = .{ 0.16, 0.30, 0.55, 1 }, // deep water
        .band_mid = .{ 0.30, 0.62, 0.32, 1 }, // grass
        .band_hi = .{ 0.48, 0.40, 0.30, 1 }, // rock
        .band_top = .{ 0.95, 0.95, 0.98, 1 }, // snow
        .params = .{ 0.0, terrain_size[1], 0, 0 },
    };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.fs_ubo, 0, std.mem.asBytes(&fs_io.u));

    // ---- the terrain pass ----
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

    // Corner preview of the source noise the mesh came from.
    if (s.preview.handle != .invalid) {
        const pv: f32 = @min(vw, vh) * 0.22;
        f.gl.texture(.{ .x = vw - pv - 8, .y = 8, .width = pv, .height = pv }, s.preview, .{ .tint = white });
    }

    // ---- UI ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 120 }, .{});
    u.setNextWindowSize(.{ panel_w, 112 }, .{});
    if (u.window("heightmap", .{})) |w| {
        defer w.close();
        u.text("perlin -> genMeshHeightmap", .{});
        if (u.button("regen", .{})) {
            s.offset += 137; // new slice of the noise field
            s.mesh.vcount = regen(s.gpa, f, s.mesh.vbo, s.scratch, &s.preview, s.offset) catch s.mesh.vcount;
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
            .title = "zimr - WebGPU - heightmap terrain",
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
