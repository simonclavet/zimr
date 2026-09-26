//! deferred_render - raylib's `shaders_deferred_rendering`, the zimr way.
//!
//! Two passes, zero lighting math wasted on overdraw:
//!
//!   PASS A (geometry -> G-buffer): one MRT render pass fills THREE
//!   textures at once through `gbuffer_vs/fs` - world position
//!   (rgba16_float), world normal (rgba16_float), albedo+spec
//!   (rgba8_unorm).  36 objects, one walk.
//!
//!   PASS B (lighting): a fullscreen quad through `deferred_shading_fs`
//!   reads the three maps back and runs Blinn-Phong for four point
//!   lights - once per screen pixel, however many cubes overdrew it.
//!
//! Phone-first upgrades over the raylib original: drag to orbit, pinch
//! or wheel to zoom; the four lights slowly circle the scene (motion is
//! what makes deferred lighting legible) with little glowing lamp cubes
//! riding along; and the keyboard toggles became a proper UI panel -
//! four light checkboxes plus a POSITION / NORMAL / ALBEDO / SHADING
//! mode switch that blits the raw G-buffer maps for inspection.

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
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

/// Plain white tint for the fullscreen blits - the maps ARE the picture.
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const gbuf_vs = z.deferred_shaders.gbuffer_vs;
const gbuf_fs = z.deferred_shaders.gbuffer_fs;
const shade_fs = z.deferred_shaders.shading_fs;

pub var zimr_app: z.App = .{};

const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const gbuffer_fs_wgsl = @embedFile("gbuffer_fs.wgsl");
const shading_vs_wgsl = @embedFile("deferred_shading_vs.wgsl");
const shading_fs_wgsl = @embedFile("deferred_shading_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Uniform block types come FROM the shader Io schemas - the GPU buffers
// and any future software run of these shaderMains cannot drift apart.
const GbufVsUbo = @FieldType(gbuf_vs.Io, "u");
const GbufFsUbo = @FieldType(gbuf_fs.Io, "u");
const LightsUbo = @FieldType(shade_fs.Io, "u");

const max_lights: usize = 4;
const tumbling_cubes: usize = 30;

/// What pass B (or the debug blit) puts on screen.
const ViewMode = enum { position, normal, albedo, shading };

// ============================================================================
// Geometry - the same position+normal layout the whole engine speaks.
// ============================================================================

const MeshVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };

/// 10x10 ground plane, matching raylib's GenMeshPlane(10, 10).
const plane_verts = [_]MeshVertex{
    .{ .position = .{ -5, 0, -5 }, .normal = up_n },
    .{ .position = .{ 5, 0, -5 }, .normal = up_n },
    .{ .position = .{ 5, 0, 5 }, .normal = up_n },
    .{ .position = .{ -5, 0, 5 }, .normal = up_n },
};
const plane_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

/// Unit cube (half-extent 1) with flat face normals; every cube in the
/// scene is this mesh under a different model matrix.
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

/// Fullscreen quad, positions ALREADY in NDC - `deferred_shading_vs`
/// passes them straight through, no matrix, nothing to get wrong.
const fullscreen_verts = [_][2]f32{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 },
    .{ -1, -1 }, .{ 1, 1 },  .{ -1, 1 },
};

// ============================================================================
// Staging - the seeded cube field + the light carousel.
// ============================================================================

/// One drawable: which mesh, where, what material, how it tumbles.
const Placement = struct {
    mesh: enum { plane, cube },
    center: [3]f32,
    half: [3]f32,
    spin_rate: f32, // radians/sec about Y; 0 = static
    albedo_spec: [4]f32, // rgb albedo + a spec strength - the G-buffer vec4
};

/// Tiny deterministic PRNG (xorshift) so the cube field is the SAME
/// composed scatter on every run - raylib reseeds rand() and gets a new
/// jumble each launch, which makes screenshots impossible to compare.
fn nextRand(state: *u32) f32 {
    var x: u32 = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return float(x & 0xFFFF) / 65535.0;
}

/// plane + center cube + 30 tumblers.  Lamp cubes are separate (they
/// track the moving lights, so their placement is computed per frame).
const scene_placements: [2 + tumbling_cubes]Placement = buildPlacements();

fn buildPlacements() [2 + tumbling_cubes]Placement {
    var out: [2 + tumbling_cubes]Placement = undefined;
    out[0] = .{
        .mesh = .plane,
        .center = .{ 0, 0, 0 },
        .half = .{ 1, 1, 1 },
        .spin_rate = 0,
        .albedo_spec = .{ 0.82, 0.82, 0.85, 0.15 }, // matte floor, faint sheen
    };
    out[1] = .{
        .mesh = .cube,
        .center = .{ 0, 1.0, 0 },
        .half = .{ 1.0, 1.0, 1.0 }, // raylib's 2.0 cube
        .spin_rate = 0.25,
        .albedo_spec = .{ 0.85, 0.83, 0.78, 0.6 }, // the shiny centerpiece
    };
    var rng: u32 = 0xC0FFEE;
    for (out[2..]) |*p| {
        // Scatter like raylib (x,z in [-5,5), y in [0,5)) but seeded, and
        // with per-cube tumble rates so the normals are alive on screen.
        const x: f32 = nextRand(&rng) * 10.0 - 5.0;
        const y: f32 = nextRand(&rng) * 4.0 + 0.25;
        const zz: f32 = nextRand(&rng) * 10.0 - 5.0;
        const tone: f32 = 0.55 + nextRand(&rng) * 0.35;
        p.* = .{
            .mesh = .cube,
            .center = .{ x, y, zz },
            .half = .{ 0.25, 0.25, 0.25 }, // raylib's CUBE_SCALE
            .spin_rate = (nextRand(&rng) - 0.5) * 1.6,
            .albedo_spec = .{ tone, tone, tone, 0.35 },
        };
    }
    return out;
}

/// Light homes + colors, straight from raylib's four CreateLight calls
/// (yellow/red/green/blue at the +/-2 corners) - but ours ORBIT: each
/// circles the scene center at its home radius with its own phase, so
/// shadow-free deferred lighting still reads as motion.
const light_color_table = [max_lights][3]f32{
    .{ 1.0, 0.9, 0.3 }, // yellow
    .{ 1.0, 0.32, 0.3 }, // red
    .{ 0.35, 1.0, 0.4 }, // green
    .{ 0.4, 0.55, 1.0 }, // blue
};
const light_orbit_speed: f32 = 0.35;
const light_reach: f32 = 4.0;

fn lightPosition(i: usize, t: f32) [3]f32 {
    // Radius sqrt8 ~ raylib's (+/-2,+/-2) corner distance; quarter-turn phase
    // per light keeps the original square formation, just rotating.
    const phase: f32 = float(i) * 1.5707964; // quarter turn per light
    const a: f32 = t * light_orbit_speed + phase;
    const r: f32 = 2.83;
    // A gentle bob so the floor highlight breathes.
    const y: f32 = 1.2 + 0.35 * @sin(t * 0.9 + phase * 2.0);
    return .{ r * @cos(a), y, r * @sin(a) };
}

// ============================================================================
// GPU plumbing - a G-buffer of three RTTs, two pipelines, per-object
// uniforms (shadowmap_sw's Obj pattern, two UBOs here instead of three).
// ============================================================================

const total_objects: usize = scene_placements.len + max_lights; // + lamp cubes

const Obj = struct {
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
    vs_ubo: z.wgpu.BufferHandle,
    g0_bg: z.wgpu.BindGroupHandle,
    fs_ubo: z.wgpu.BufferHandle,
    g2_bg: z.wgpu.BindGroupHandle,
};

const State = struct {
    gpa: Allocator,

    gbuffer_pipeline: z.wgpu.RenderPipelineHandle,
    shading_pipeline: z.wgpu.RenderPipelineHandle,

    // The G-buffer: [0] position (owns the depth), [1] normal, [2] albedo.
    // Recreated on canvas resize; .invalid before the first ensureTargets.
    g_rts: [3]z.RenderTexture,
    g_sampler: z.wgpu.SamplerHandle,
    g1_bgl: z.wgpu.BindGroupLayoutHandle,
    g1_bg: z.wgpu.BindGroupHandle, // gbuffer textures for pass B (rebuilt on resize)
    empty_bgl: z.wgpu.BindGroupLayoutHandle,
    empty_bg: z.wgpu.BindGroupHandle, // pass B group 0 (shading VS has no uniforms)

    rt: z.RenderTexture, // pass B target = what the screen shows in .shading

    objs: [total_objects]Obj,
    fullscreen_vbo: z.wgpu.BufferHandle,
    plane_vbo: z.wgpu.BufferHandle,
    plane_ibo: z.wgpu.BufferHandle,
    cube_vbo: z.wgpu.BufferHandle,
    cube_ibo: z.wgpu.BufferHandle,
    lights_ubo: z.wgpu.BufferHandle,
    lights_bg: z.wgpu.BindGroupHandle,

    ui_host: z.UiHost,
    font: z.Font,
    mode: ViewMode = .shading,
    light_on: [max_lights]bool = .{ true, true, true, true },

    cam_yaw: f32 = 0.8,
    cam_pitch: f32 = 0.45,
    cam_dist: f32 = 11.0,
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
    z.wgpu.destroyBuffer(s.plane_vbo);
    z.wgpu.destroyBuffer(s.plane_ibo);
    z.wgpu.destroyBuffer(s.cube_vbo);
    z.wgpu.destroyBuffer(s.cube_ibo);
    z.wgpu.destroyBuffer(s.fullscreen_vbo);
    z.wgpu.destroyBuffer(s.lights_ubo);
    z.wgpu.destroyBindGroup(s.lights_bg);
    z.wgpu.destroyBindGroup(s.empty_bg);
    if (s.g1_bg != .invalid) {
        z.wgpu.destroyBindGroup(s.g1_bg);
    }
    z.wgpu.destroyBindGroupLayout(s.g1_bgl);
    z.wgpu.destroyBindGroupLayout(s.empty_bgl);
    z.wgpu.destroySampler(s.g_sampler);
    for (&s.g_rts) |*g| {
        g.deinit();
    }
    s.rt.deinit();
    z.wgpu.destroyRenderPipeline(s.gbuffer_pipeline);
    z.wgpu.destroyRenderPipeline(s.shading_pipeline);
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

const Bgls = struct {
    gbuf_g0: z.wgpu.BindGroupLayoutHandle,
    gbuf_g2: z.wgpu.BindGroupLayoutHandle,
};

fn makeObj(
    gpa: Allocator,
    device: z.wgpu.DeviceHandle,
    bgls: Bgls,
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    vbo_bytes: u64,
    ibo_bytes: u64,
    icount: u32,
) !Obj {
    const vs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(GbufVsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    const fs_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(GbufFsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });
    return .{
        .vbo = vbo,
        .ibo = ibo,
        .vbo_bytes = vbo_bytes,
        .ibo_bytes = ibo_bytes,
        .icount = icount,
        .vs_ubo = vs_ubo,
        .g0_bg = try uniformBindGroup(gpa, device, bgls.gbuf_g0, vs_ubo, @sizeOf(GbufVsUbo), "dfr_g0"),
        .fs_ubo = fs_ubo,
        .g2_bg = try uniformBindGroup(gpa, device, bgls.gbuf_g2, fs_ubo, @sizeOf(GbufFsUbo), "dfr_g2"),
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;

    // ---- shared geometry buffers ----
    const plane_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(plane_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "dfr_plane_vbo",
    );
    const plane_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(plane_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "dfr_plane_ibo",
    );
    const cube_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "dfr_cube_vbo",
    );
    const cube_ibo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(cube_indices[0..]),
        .{ .index = true, .copy_dst = true },
        "dfr_cube_ibo",
    );
    const fullscreen_vbo: z.wgpu.BufferHandle = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(fullscreen_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "dfr_fullscreen_vbo",
    );

    // ---- vertex layouts ----
    const pos_normal_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(MeshVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    const ndc_pos_layout = z.gpu.VertexBufferLayout{
        .array_stride = 8,
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        },
    };

    // ---- bind group layouts ----
    const bgls: Bgls = .{
        .gbuf_g0 = try uniformLayout(gpa, device, @sizeOf(GbufVsUbo), .{ .vertex = true }, "dfr_gbuf_g0"),
        .gbuf_g2 = try uniformLayout(gpa, device, @sizeOf(GbufFsUbo), .{ .fragment = true }, "dfr_gbuf_g2"),
    };
    const lights_bgl: z.wgpu.BindGroupLayoutHandle =
        try uniformLayout(gpa, device, @sizeOf(LightsUbo), .{ .fragment = true }, "dfr_lights_g2");

    // Pass B's group 1: three {texture, sampler} pairs, interleaved exactly as
    // the generated WGSL declares them - texture at binding 2i, its sampler at
    // 2i+1 (the schema solver spaces each Sampler2D pair 2 apart). This MUST
    // match `deferred_shading_fs_io.Samplers` (g_world_pos, g_world_normal,
    // g_albedo_spec); the old "textures 0/1/2, samplers 3/4/5" block scheme
    // drifted from the interleaved WGSL and Dawn rejected the type mismatch.
    var g1_layout_entries: [6]z.shader_introspect.BindGroupLayoutEntry = undefined;
    for (0..3) |i| {
        g1_layout_entries[2 * i] = .{
            .binding = @intCast(2 * i),
            .visibility = .{ .fragment = true },
            .resource = .{ .texture = .{} },
        };
        g1_layout_entries[2 * i + 1] = .{
            .binding = @intCast(2 * i + 1),
            .visibility = .{ .fragment = true },
            .resource = .{ .sampler = .{} },
        };
    }
    const g1_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_layout_entries);
    defer gpa.free(g1_layout_blob);
    const g1_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, g1_layout_blob, "dfr_g1");

    // The shading VS declares NO group-0 uniforms, but the pipeline layout
    // array is positional - group 2 exists only if slots 0 and 1 do.  An
    // empty layout + empty bind group fills the hole honestly.
    const empty_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &.{});
    defer gpa.free(empty_blob);
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, empty_blob, "dfr_empty");
    const empty_bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &.{});
    defer gpa.free(empty_bg_blob);
    const empty_bg: z.wgpu.BindGroupHandle =
        z.wgpu.createBindGroup(device, empty_bgl, empty_bg_blob, "dfr_empty_bg");

    // Nearest sampling: the G-buffer is data, not a picture - bilinearly
    // mixing two world positions across a silhouette invents a third
    // position that exists on neither surface.
    const g_sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .address_mode = .clamp_to_edge,
    });

    // ---- PASS A pipeline: three color targets via the MRT tail ----
    const gbuf_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ bgls.gbuf_g0, empty_bgl, bgls.gbuf_g2 },
        "dfr_gbuf_pl",
    );
    const gbuf_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const gbuf_fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_fs_wgsl, "gbuffer_fs");
    const gbuf_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none, // no blend - G-buffers store data
        .less,
        .none,
        .rgba16_float, // location 0: world position
        .depth24_plus,
        1,
    );
    const gbuf_pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{pos_normal_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = gbuf_combo,
        .extra_color_formats = &.{ .rgba16_float, .rgba8_unorm }, // normal, albedo+spec
    });
    defer gpa.free(gbuf_pipe_blob);
    const gbuffer_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        gbuf_pl,
        gbuf_vs_mod,
        gbuf_fs_mod,
        gbuf_pipe_blob,
        "dfr_gbuf_pipe",
    );

    // ---- PASS B pipeline: fullscreen quad -> the rgba8 canvas RTT ----
    const shade_pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(
        device,
        &.{ empty_bgl, g1_bgl, lights_bgl },
        "dfr_shade_pl",
    );
    const shade_vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, shading_vs_wgsl, "deferred_shading_vs");
    const shade_fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, shading_fs_wgsl, "deferred_shading_fs");
    const shade_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less, // quad at z=0 vs cleared depth 1.0 - always passes
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const shade_pipe_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{ndc_pos_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = shade_combo,
    });
    defer gpa.free(shade_pipe_blob);
    const shading_pipeline: z.wgpu.RenderPipelineHandle = z.wgpu.createRenderPipeline(
        device,
        shade_pl,
        shade_vs_mod,
        shade_fs_mod,
        shade_pipe_blob,
        "dfr_shade_pipe",
    );

    // ---- per-object state (plane, cubes, lamp cubes) ----
    var objs: [total_objects]Obj = undefined;
    for (&objs, 0..) |*slot, i| {
        const is_plane: bool = i == 0;
        slot.* = try makeObj(
            gpa,
            device,
            bgls,
            if (is_plane) plane_vbo else cube_vbo,
            if (is_plane) plane_ibo else cube_ibo,
            if (is_plane) @sizeOf(@TypeOf(plane_verts)) else @sizeOf(@TypeOf(cube_verts)),
            if (is_plane) @sizeOf(@TypeOf(plane_indices)) else @sizeOf(@TypeOf(cube_indices)),
            if (is_plane) plane_indices.len else cube_indices.len,
        );
    }

    const lights_ubo: z.wgpu.BufferHandle = z.wgpu.createBuffer(device, .{
        .size = @sizeOf(LightsUbo),
        .usage = .{ .uniform = true, .copy_dst = true },
    });

    const lights_bg = try uniformBindGroup(gpa, device, lights_bgl, lights_ubo, @sizeOf(LightsUbo), "dfr_lights_bg");

    // Build-only intermediates consumed above - release (pipelines are direct/uncached -> owned).
    z.wgpu.destroyBindGroupLayout(bgls.gbuf_g0);
    z.wgpu.destroyBindGroupLayout(bgls.gbuf_g2);
    z.wgpu.destroyBindGroupLayout(lights_bgl);
    z.wgpu.destroyPipelineLayout(gbuf_pl);
    z.wgpu.destroyPipelineLayout(shade_pl);
    z.wgpu.destroyShaderModule(gbuf_vs_mod);
    z.wgpu.destroyShaderModule(gbuf_fs_mod);
    z.wgpu.destroyShaderModule(shade_vs_mod);
    z.wgpu.destroyShaderModule(shade_fs_mod);

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .gbuffer_pipeline = gbuffer_pipeline,
        .shading_pipeline = shading_pipeline,
        .g_rts = .{ .{}, .{}, .{} },
        .g_sampler = g_sampler,
        .g1_bgl = g1_bgl,
        .g1_bg = .invalid,
        .empty_bgl = empty_bgl,
        .empty_bg = empty_bg,
        .rt = .{},
        .objs = objs,
        .fullscreen_vbo = fullscreen_vbo,
        .plane_vbo = plane_vbo,
        .plane_ibo = plane_ibo,
        .cube_vbo = cube_vbo,
        .cube_ibo = cube_ibo,
        .lights_ubo = lights_ubo,
        .lights_bg = lights_bg,
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
}

/// Keep the G-buffer + the pass B target at the canvas backing size;
/// rebuild the G-buffer bind group whenever the texture views change.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: u32 = @max(backing.width, 1);
    const bh: u32 = @max(backing.height, 1);
    if (s.rt.color != .invalid and s.rt.width == bw and s.rt.height == bh) {
        return;
    }
    if (s.rt.color != .invalid) {
        z.unloadRenderTexture(f.gl, &s.rt);
        for (&s.g_rts) |*rt| {
            z.unloadRenderTexture(f.gl, rt);
        }
    }
    s.rt = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
    const formats = [3]z.wgpu.TextureFormat{ .rgba16_float, .rgba16_float, .rgba8_unorm };
    for (&s.g_rts, formats, 0..) |*rt, fmt, i| {
        rt.* = z.RenderTexture.create(f.gpu.device, .{
            .width = bw,
            .height = bh,
            .format = fmt,
            .with_depth = i == 0, // ONE depth, owned by the position target
            .depth_format = .depth24_plus,
            .label = "dfr_gbuf_rt",
        });
    }

    // Fresh views -> fresh pass B bind group. Interleaved to match the layout
    // and WGSL: g_rts[i]'s texture at binding 2i, the shared sampler at 2i+1.
    const g1_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = s.g_rts[0].asTexture().view } },
        .{ .binding = 1, .resource = .{ .sampler = s.g_sampler } },
        .{ .binding = 2, .resource = .{ .texture_view = s.g_rts[1].asTexture().view } },
        .{ .binding = 3, .resource = .{ .sampler = s.g_sampler } },
        .{ .binding = 4, .resource = .{ .texture_view = s.g_rts[2].asTexture().view } },
        .{ .binding = 5, .resource = .{ .sampler = s.g_sampler } },
    };
    const g1_blob: []const u8 = z.gpu.encodeBindGroupEntries(s.gpa, &g1_entries) catch return;
    defer s.gpa.free(g1_blob);
    if (s.g1_bg != .invalid) {
        z.wgpu.destroyBindGroup(s.g1_bg);
    }
    s.g1_bg = z.wgpu.createBindGroup(f.gpu.device, s.g1_bgl, g1_blob, "dfr_g1_bg");
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
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.02, 5.0, 22.0);
        }
        s.prev_pinch = dist;
        return;
    }
    s.prev_pinch = 0;
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, 0.08, 1.45);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.6, 5.0, 22.0);
    }
}

/// Model matrix for a placement: place o spin o scale.
fn placementModel(p: Placement, t: f32) Mat {
    const spin: Mat = rotationY(p.spin_rate * t);
    const scale_it: Mat = scaling(p.half[0], p.half[1], p.half[2]);
    const place_it: Mat = translation(p.center[0], p.center[1], p.center[2]);
    return mulMat(place_it, mulMat(spin, scale_it));
}

fn writeObjUniforms(f: *z.Frame, s: *State, t: f32, cam_vp: Mat) void {
    // Scene placements first, then the four lamp cubes riding the lights.
    for (&s.objs, 0..) |*obj, i| {
        var model: Mat = undefined;
        var normal_mat: Mat = undefined;
        var material: [4]f32 = undefined;
        if (i < scene_placements.len) {
            const p: Placement = scene_placements[i];
            model = placementModel(p, t);
            normal_mat = rotationY(p.spin_rate * t);
            material = p.albedo_spec;
        } else {
            const li: usize = i - scene_placements.len;
            const lp: [3]f32 = lightPosition(li, t);
            const c: [3]f32 = light_color_table[li];
            model = mulMat(translation(lp[0], lp[1], lp[2]), scaling(0.12, 0.12, 0.12));
            normal_mat = zm.identity();
            // Over-bright when on (reads emissive under its own light),
            // dim husk when toggled off - the lamp itself tells you.
            const gain: f32 = if (s.light_on[li]) 1.8 else 0.12;
            material = .{ c[0] * gain, c[1] * gain, c[2] * gain, 0.0 };
        }

        var vs_io: gbuf_vs.Io = undefined;
        vs_io.u = .{
            .mvp = mulMat(cam_vp, model),
            .model = model,
            .normal_matrix = normal_mat,
        };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.vs_ubo, 0, std.mem.asBytes(&vs_io.u));
        var fs_io: gbuf_fs.Io = undefined;
        fs_io.u = .{ .albedo_spec = material };
        z.wgpu.queueWriteBuffer(f.gpu.queue, obj.fs_ubo, 0, std.mem.asBytes(&fs_io.u));
    }
}

fn writeLightsUbo(f: *z.Frame, s: *State, t: f32, cam_eye: Vec) void {
    var u: LightsUbo = undefined;
    u.view_pos = .{ cam_eye[0], cam_eye[1], cam_eye[2], 0 };
    for (0..max_lights) |i| {
        const lp: [3]f32 = lightPosition(i, t);
        const c: [3]f32 = light_color_table[i];
        u.light_pos[i] = .{ lp[0], lp[1], lp[2], light_reach };
        u.light_color[i] = .{ c[0], c[1], c[2], if (s.light_on[i]) 1.0 else 0.0 };
    }
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.lights_ubo, 0, std.mem.asBytes(&u));
}

fn drawMesh(rps: *z.PassState, obj: *const Obj) void {
    z.render_pass.setVertexBuffer(rps.pass, .{ .slot = 0, .buffer = obj.vbo, .offset = 0, .size = obj.vbo_bytes });
    z.render_pass.setIndexBuffer(rps.pass, .{
        .buffer = obj.ibo,
        .format = .uint32,
        .offset = 0,
        .size = obj.ibo_bytes,
    });
    z.render_pass.drawIndexed(rps.pass, .{
        .index_count = obj.icount,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    });
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing; uses
    // last-frame UI state = 1-frame lag).

    // ---- camera ----
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
    const cam_proj: Mat = perspectiveFovRh(1.05, vw / vh, 0.1, 100.0); // ~raylib's 60 deg fovy
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    writeObjUniforms(f, s, t, cam_vp);
    writeLightsUbo(f, s, t, cam_eye);
    const Backend: type = z.WgpuBackend;

    // ---- PASS A: one MRT pass fills the whole G-buffer ----
    z.beginTextureModeMrtRaw(f.gl, s.g_rts[0..], .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const pa: *z.PassState = f.gl.pass;
    Backend.setPipeline(pa, z.shader.RenderPipeline(void, void){ .gpu_handle = s.gbuffer_pipeline });
    Backend.setBindGroup(pa, 1, s.empty_bg);
    for (&s.objs) |*obj| {
        Backend.setBindGroup(pa, 0, obj.g0_bg);
        Backend.setBindGroup(pa, 2, obj.g2_bg);
        drawMesh(pa, obj);
    }
    z.endTextureModeRaw(f.gl);

    // ---- PASS B (shading): render lighting into the RTT, OFFSCREEN ----
    if (s.mode == .shading) {
        z.beginTextureModeRaw(f.gl, s.rt, .{ .r = 6, .g = 7, .b = 12, .a = 255 });
        const pb: *z.PassState = f.gl.pass;
        Backend.setPipeline(pb, z.shader.RenderPipeline(void, void){ .gpu_handle = s.shading_pipeline });
        Backend.setBindGroup(pb, 0, s.empty_bg);
        Backend.setBindGroup(pb, 1, s.g1_bg);
        Backend.setBindGroup(pb, 2, s.lights_bg);
        z.render_pass.setVertexBuffer(pb.pass, .{
            .slot = 0,
            .buffer = s.fullscreen_vbo,
            .offset = 0,
            .size = @sizeOf(@TypeOf(fullscreen_verts)),
        });
        z.render_pass.draw(pb.pass, .{
            .vertex_count = 6,
            .instance_count = 1,
            .first_vertex = 0,
            .first_instance = 0,
        });
        z.endTextureModeRaw(f.gl);
    }

    // ---- SCREEN PASS: open once, composite the lit RTT or a raw G-buffer. ----
    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 6, .g = 7, .b = 12, .a = 255 });
    if (s.mode == .shading) {
        f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.rt.asTexture(), .{ .tint = white });
    } else {
        // Debug views: blit the raw map (values outside [0,1] clip on display).
        const which: usize = switch (s.mode) {
            .position => 0,
            .normal => 1,
            else => 2,
        };
        f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, s.g_rts[which].asTexture(), .{ .tint = white });
    }

    // ---- UI first: its capture flag gates the orbit drag ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(280, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 190 }, .{});
    u.setNextWindowSize(.{ panel_w, 182 }, .{});
    if (u.window("deferred", .{})) |w| {
        defer w.close();
        u.text("lights", .{});
        _ = u.checkbox("yellow", &s.light_on[0]);
        u.sameLine(.{});
        _ = u.checkbox("red", &s.light_on[1]);
        _ = u.checkbox("green", &s.light_on[2]);
        u.sameLine(.{});
        _ = u.checkbox("blue", &s.light_on[3]);
        u.separator();
        u.text("view: {s}", .{@tagName(s.mode)});
        if (u.button("position", .{})) {
            s.mode = .position;
        }
        u.sameLine(.{});
        if (u.button("normal", .{})) {
            s.mode = .normal;
        }
        u.sameLine(.{});
        if (u.button("albedo", .{})) {
            s.mode = .albedo;
        }
        u.sameLine(.{});
        if (u.button("shading", .{})) {
            s.mode = .shading;
        }
    }
    handleInput(f, s, u.wantCaptureMouse());
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - deferred rendering (MRT G-buffer)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // G-buffer + lighting rendered offscreen before the screen opens
    // (tile-based-GPU safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
    .memory = .managed,
};
