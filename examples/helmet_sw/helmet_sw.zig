//! helmet_sw — ONE Zig PBR shader, THREE targets, side by side.
//!
//! `src/shaders/pbr_vs.zig` + `pbr_fs.zig` are compiled three ways from the
//! same source:
//!   - RIGHT (GPU): Zig → SPIR-V → WGSL, run by `z.pbr3d`'s WebGPU pipeline
//!     into an offscreen render texture, composited as 2D.
//!   - LEFT (CPU): the same files compiled for wasm32 (re-exported as
//!     `z.pbr_shaders`) and run per-vertex / per-fragment by the programmable
//!     software rasterizer (`raster_shader.rasterizeTriangles`, depth-tested),
//!     sampling the same five glTF maps through CPU `TextureRef`s.
//!   - CORNER (COMPTIME): the Zig compiler itself rasterizes a build-baked
//!     decimated proxy through the same two `shaderMain`s and the result
//!     ships as a const — see the `corner_image` block below.
//! Same mesh (`pbr3d.buildCpuMesh` feeds CPU+GPU; the corner's proxy is a
//! decimation of it), same maps (`decodeMaterialMap` feeds both live
//! halves; the corner's 64² base color is a downsample of the same data),
//! same camera, same Ubo values.  Cook-Torrance, normal mapping, AO,
//! emissive — written once, in Zig, run by hardware, software, and the
//! compiler.
//!
//! Drag to orbit, wheel/pinch to zoom; the splitter follows the pointer.
//! Known v1 divergences, visible if you look closely: the CPU half renders
//! at reduced resolution, samples nearest (GPU is bilinear), and uses
//! downsampled maps.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2i = zm.Vec2i;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const identity = zm.identity;
const lookAtRh = zm.lookAtRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationX = zm.rotationX;
const vec = zm.vec;
const pbr = z.pbr_shaders;

const helmet_glb = @embedFile("DamagedHelmet.glb");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

// CPU half renders a CONSTANT PIXEL BUDGET at whatever aspect the live
// canvas has (portrait, landscape, resized window — the dims re-derive
// every frame in `ensureTargets`), so rotating the phone never stretches
// and never changes the per-frame CPU cost.  ~27k px ≈ the old 220×124.
const cpu_pixel_budget: f32 = 27_000;
// GPU half renders into a render texture recreated at the canvas's
// BACKING size (CSS × devicePixelRatio) whenever it changes — pixel-
// perfect at any orientation.
// CPU material maps are downsampled to this edge — at ~200px render
// width, 512² nearest-sampled maps are indistinguishable from 2048².
const cpu_map_edge: u32 = 512;

const cam_target: Vec = vec(0, 0, 0);
const fovy: f32 = 0.8;
const z_near: f32 = 0.1;
const z_far: f32 = 100.0;

// One light for ALL THREE evaluations (pbr3d normalizes the direction
// before writing its Ubo; `buildUboFromFactors` does the same so they
// stay numerically equal).
const light_dir: [3]f32 = .{ -0.5, -0.6, -0.6 };
const light_color: [3]f32 = .{ 1, 1, 1 };
const light_ambient: [3]f32 = .{ 0.2, 0.22, 0.26 };

// Initial orbit camera — shared by the runtime state AND the comptime
// corner (the corner is FROZEN at this pose, like the rt/mandel insets).
const initial_yaw: f32 = 0.6;
const initial_pitch: f32 = 0.15;
const initial_dist: f32 = 3.2;

// ---- Comptime corner: the SAME shader pair, run by the Zig COMPILER ----
// Geometry can't comptime-parse (the GLB is allocator-based, and 15k tris
// is far past any comptime budget), so a build step (tools/mesh_bake.zig)
// pre-bakes a vertex-cluster-decimated proxy (~1k clusters / ~2k tris) and
// the base-color map at 64² into the `helmet_proxy` module.  Here the
// compiler runs pbr_vs.shaderMain over every proxy vertex at the frozen
// initial camera, then `rasterizeToImage` (the pure sibling of the runtime
// rasterizer, differentially tested against it) runs pbr_fs.shaderMain per
// covered pixel — same Ubo values, same sRGB sampling — and the image
// bakes into the binary as a const.
//
// Corner-only material simplifications: a flat 1×1 normal map (the TBN
// then collapses to the geometric normal, so the proxy carries NO real
// tangents — `(1,0,0,1)` placeholders suffice), matte metallic-roughness,
// white AO, and BLACK emissive (the helmet's emissive_factor is (1,1,1);
// a white fallback would glow everywhere, black zeroes the term).
const proxy = @import("helmet_proxy");
const corner_size: usize = 48;
/// The Ubo every CPU-side evaluation feeds the shader — the live half from
/// the runtime glTF material, the comptime corner from the baked proxy's
/// factors.  Pure, so the compiler can call it too.  Same struct the GPU's
/// std140 block is generated from; same light values pbr3d.buildUbo writes.
fn buildUboFromFactors(
    base_color_factor: [4]f32,
    metallic_factor: f32,
    roughness_factor: f32,
    emissive_factor: [3]f32,
    eye: Vec,
) pbr.fs.Ubo {
    const len: f32 = @sqrt(light_dir[0] * light_dir[0] +
        light_dir[1] * light_dir[1] + light_dir[2] * light_dir[2]);
    const inv_len: f32 = 1.0 / len;
    var ubo: pbr.fs.Ubo = .{
        .col_diffuse = .{
            base_color_factor[0],
            base_color_factor[1],
            base_color_factor[2],
            base_color_factor[3],
        },
        .view_pos = .{ eye[0], eye[1], eye[2], 0 },
        .ambient_color = .{ light_ambient[0], light_ambient[1], light_ambient[2], 0 },
        .emissive_factor = .{ emissive_factor[0], emissive_factor[1], emissive_factor[2], 0 },
        .metallic_factor = metallic_factor,
        .roughness_factor = roughness_factor,
        .directional_light_count = 1,
        .fog_far = 100,
    };
    ubo.directional_light_dir[0] = .{
        light_dir[0] * inv_len,
        light_dir[1] * inv_len,
        light_dir[2] * inv_len,
        0,
    };
    ubo.directional_light_color[0] = .{ light_color[0], light_color[1], light_color[2], 1 };
    return ubo;
}

/// Raw RGBA8 — uploaded ONCE to a small texture at init and drawn as a
/// single quad.  (v1 drew it as a 2304-rect grid like the rt inset; on the
/// phone that batch cost was the difference between 60 and 16 fps.)
const corner_image: [corner_size * corner_size * 4]u8 = blk: {
    @setEvalBranchQuota(2_000_000_000);
    const cp: f32 = @cos(initial_pitch);
    const eye: Vec = vec(
        initial_dist * cp * @sin(initial_yaw),
        initial_dist * @sin(initial_pitch),
        initial_dist * cp * @cos(initial_yaw),
    );
    const view: Mat = lookAtRh(eye, cam_target, vec(0, 1, 0));
    const proj_m: Mat = perspectiveFovRh(fovy, 1.0, z_near, z_far);
    const model_m: Mat = rotationX(1.5707963);

    var vs_io: pbr.vs.Io = undefined;
    vs_io.mat_model = model_m;
    vs_io.mat_view = view;
    vs_io.mat_projection = proj_m;
    vs_io.mat_normal = model_m;
    vs_io.light_space_matrix = identity();
    var vs_outs: [proxy.vertex_count]pbr.vs.Out = undefined;
    for (&vs_outs, 0..) |*out, i| {
        vs_io.vertex_position = .{ proxy.positions[i][0], proxy.positions[i][1], proxy.positions[i][2] };
        vs_io.vertex_tex_coord = .{ proxy.uvs[i][0], proxy.uvs[i][1] };
        vs_io.vertex_normal = .{ proxy.normals[i][0], proxy.normals[i][1], proxy.normals[i][2] };
        vs_io.vertex_color = .{ 1, 1, 1, 1 };
        vs_io.vertex_tangent = .{ 1, 0, 0, 1 };
        out.* = pbr.vs.shaderMain(vs_io);
    }

    var indices_u32: [proxy.indices.len]u32 = undefined;
    for (proxy.indices, 0..) |index_value, i| {
        indices_u32[i] = index_value;
    }

    const flat_normal = [_]u8{ 128, 128, 255, 255 };
    const matte_mr = [_]u8{ 255, 255, 0, 255 };
    const white_px = [_]u8{ 255, 255, 255, 255 };
    const black_px = [_]u8{ 0, 0, 0, 255 };
    var base_fs_io: pbr.fs.Io = undefined;
    base_fs_io.u = buildUboFromFactors(
        proxy.base_color_factor,
        proxy.metallic_factor,
        proxy.roughness_factor,
        .{ 0, 0, 0 },
        eye,
    );
    base_fs_io._texture0 = .{
        .pixels = &proxy.base_color,
        .width = proxy.tex_edge,
        .height = proxy.tex_edge,
        .srgb = true,
    };
    base_fs_io._metallic_roughness = .{ .pixels = &matte_mr, .width = 1, .height = 1 };
    base_fs_io._normal = .{ .pixels = &flat_normal, .width = 1, .height = 1 };
    base_fs_io._occlusion = .{ .pixels = &white_px, .width = 1, .height = 1 };
    base_fs_io._emissive = .{ .pixels = &black_px, .width = 1, .height = 1, .srgb = true };
    base_fs_io._shadow_map = .{ .pixels = &white_px, .width = 1, .height = 1 };

    const connect: fn (pbr.vs.Out, *pbr.fs.Io) void = z.shader.autoConnect(pbr.vs.Out, pbr.fs.Io);
    const img: [corner_size * corner_size][4]u8 = z.raster_shader.rasterizeToImage(
        pbr.vs,
        pbr.fs,
        corner_size,
        corner_size,
        &vs_outs,
        &indices_u32,
        base_fs_io,
        connect,
        .{ .depth_test = true },
        .{ 10, 12, 20, 255 },
    );
    break :blk @bitCast(img);
};

/// One CPU-side material map: owned RGBA8 pixels + dims, handed to the
/// fragment shader as a `TextureRef`.  `srgb` mirrors pbr3d's per-slot
/// format choice (base color + emissive upload as `rgba8_unorm_srgb`),
/// so the CPU sampler applies the same sRGB→linear conversion the GPU
/// view does and the shader body sees identical values.
const CpuMap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    srgb: bool = false,

    fn ref(self: CpuMap) pbr.fs.TextureRef {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height, .srgb = self.srgb };
    }
};

const State = struct {
    gpa: Allocator,
    // ---- GPU half ----
    renderer: z.pbr3d.Renderer,
    model: z.pbr3d.Model,
    rt: z.RenderTexture,
    // ---- CPU half ----
    mesh: z.pbr3d.CpuMesh,
    indices_u32: []u32,
    vs_outs: []pbr.vs.Out,
    maps: [5]CpuMap,
    base_color_factor: [4]f32,
    metallic_factor: f32,
    roughness_factor: f32,
    emissive_factor: [3]f32,
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,
    // ---- shared ----
    font: z.Font,
    cam_yaw: f32,
    cam_pitch: f32,
    cam_dist: f32,
    dragging: bool,
    prev_pinch_dist: f32,
    /// Splitter as a FRACTION of the canvas width (not pixels) so it
    /// stays put across rotations/resizes.  Follows the pointer.
    divider_frac: f32,
    last_mouse: Vec2,
    /// The comptime-baked corner, uploaded once at init.
    corner_fb: z.CpuFramebuffer,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.mesh.deinit(gpa);
    gpa.free(s.indices_u32);
    gpa.free(s.vs_outs);
    for (s.maps) |m| {
        gpa.free(m.pixels);
    }
    s.sw.deinit(gpa);
    s.model.deinit();
    s.renderer.deinit();
    s.rt.deinit();
    s.sw_fb.deinit();
    s.corner_fb.deinit();
}

/// Box-filter `src` down to at most `max_edge` per side (power-of-two
/// integer factor; a 2048² helmet map at max_edge 512 averages 4×4 blocks).
/// Factor-1 inputs are duped so the caller uniformly owns the result.
fn downsampleRgba8(
    gpa: Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    max_edge: u32,
) !CpuMap {
    var factor: u32 = 1;
    while (src_w / (factor * 2) >= max_edge and src_h / (factor * 2) >= max_edge) {
        factor *= 2;
    }
    if (factor == 1) {
        return .{ .pixels = try gpa.dupe(u8, src), .width = src_w, .height = src_h };
    }
    const dst_w: u32 = src_w / factor;
    const dst_h: u32 = src_h / factor;
    const dst: []u8 = try gpa.alloc(u8, @as(usize, dst_w) * dst_h * 4);
    const samples: u32 = factor * factor;
    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            var sy: u32 = 0;
            while (sy < factor) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < factor) : (sx += 1) {
                    const si: usize = (@as(usize, dy * factor + sy) * src_w + (dx * factor + sx)) * 4;
                    acc[0] += src[si];
                    acc[1] += src[si + 1];
                    acc[2] += src[si + 2];
                    acc[3] += src[si + 3];
                }
            }
            const di: usize = (@as(usize, dy) * dst_w + dx) * 4;
            dst[di] = @intCast(acc[0] / samples);
            dst[di + 1] = @intCast(acc[1] / samples);
            dst[di + 2] = @intCast(acc[2] / samples);
            dst[di + 3] = @intCast(acc[3] / samples);
        }
    }
    return .{ .pixels = dst, .width = dst_w, .height = dst_h };
}

/// Decode one material map for the CPU half, downsampled to `cpu_map_edge`.
/// Slots without a map get the SAME 1×1 neutral the GPU fallbacks use
/// (white / flat-normal / matte-dielectric MR), so absent maps shade
/// identically on both halves.
fn loadCpuMap(
    gpa: Allocator,
    document: z.codecs.gltf.Data,
    material: ?z.codecs.gltf.Material,
    slot: z.pbr3d.MaterialSlot,
) !CpuMap {
    // Color maps are sRGB-encoded; data maps (MR / normal / AO) are linear —
    // the same split pbr3d uses when picking the GPU texture format.
    const is_srgb: bool = switch (slot) {
        .base_color, .emissive => true,
        .metallic_roughness, .normal, .occlusion => false,
    };
    if (z.pbr3d.decodeMaterialMap(gpa, document, material, slot)) |decoded| {
        defer decoded.deinit(gpa);
        var map: CpuMap = try downsampleRgba8(gpa, decoded.pixels, decoded.width, decoded.height, cpu_map_edge);
        map.srgb = is_srgb;
        return map;
    }
    const neutral: [4]u8 = switch (slot) {
        .normal => .{ 128, 128, 255, 255 },
        .metallic_roughness => .{ 255, 255, 0, 255 }, // matte dielectric: roughness G=1, metallic B=0
        else => .{ 255, 255, 255, 255 },
    };
    return .{ .pixels = try gpa.dupe(u8, &neutral), .width = 1, .height = 1, .srgb = is_srgb };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // ---- GPU half: pbr3d renderer targeting the RTT's format ----
    const gf: *z.GpuFrame = f.gpu;
    var renderer: z.pbr3d.Renderer = try z.pbr3d.Renderer.init(.{
        .device = gf.device,
        .queue = gf.queue,
        .gpa = gpa,
        // Drawn into a render texture (rgba8), not the backbuffer.
        .surface_format = .rgba8_unorm,
        .depth_format = .depth24_plus,
        .vs_wgsl = pbr_vs_wgsl,
        .fs_wgsl = pbr_fs_wgsl,
        .cull_mode = .back,
    });
    const model: z.pbr3d.Model = try renderer.loadGltf(helmet_glb);

    // ---- CPU half: the SAME geometry + maps, kept on the CPU ----
    var document: z.codecs.gltf.Data = try z.codecs.gltf.parse(gpa, helmet_glb);
    defer document.deinit();
    const mesh: z.pbr3d.CpuMesh = try z.pbr3d.buildCpuMesh(gpa, document);
    const indices_u32: []u32 = try gpa.alloc(u32, mesh.indices.len);
    for (mesh.indices, indices_u32) |i16v, *i32v| {
        i32v.* = i16v;
    }
    const vs_outs: []pbr.vs.Out = try gpa.alloc(pbr.vs.Out, mesh.vertices.len);

    const material: ?z.codecs.gltf.Material = z.pbr3d.firstPrimitiveMaterial(document);
    const maps: [5]CpuMap = .{
        try loadCpuMap(gpa, document, material, .base_color),
        try loadCpuMap(gpa, document, material, .metallic_roughness),
        try loadCpuMap(gpa, document, material, .normal),
        try loadCpuMap(gpa, document, material, .occlusion),
        try loadCpuMap(gpa, document, material, .emissive),
    };
    var base_color_factor: [4]f32 = .{ 1, 1, 1, 1 };
    var metallic_factor: f32 = 1;
    var roughness_factor: f32 = 1;
    var emissive_factor: [3]f32 = .{ 0, 0, 0 };
    if (material) |m| {
        base_color_factor = .{
            m.base_color_factor[0],
            m.base_color_factor[1],
            m.base_color_factor[2],
            m.base_color_factor[3],
        };
        metallic_factor = m.metallic_factor;
        roughness_factor = m.roughness_factor;
        emissive_factor = .{ m.emissive_factor[0], m.emissive_factor[1], m.emissive_factor[2] };
    }

    // Placeholder dims — `ensureTargets` re-derives both halves' sizes from
    // the live canvas on the first frame (and every rotation/resize after).
    const sw: z.raster.Context = try z.raster.Context.init(gpa, 220, 124);
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        220,
        124,
        sw.colorBufferBytes(),
        "helmet_sw",
    );
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .renderer = renderer,
        .model = model,
        .rt = .{},
        .mesh = mesh,
        .indices_u32 = indices_u32,
        .vs_outs = vs_outs,
        .maps = maps,
        .base_color_factor = base_color_factor,
        .metallic_factor = metallic_factor,
        .roughness_factor = roughness_factor,
        .emissive_factor = emissive_factor,
        .sw = sw,
        .sw_fb = sw_fb,
        .font = font,
        .cam_yaw = initial_yaw,
        .cam_pitch = initial_pitch,
        .cam_dist = initial_dist,
        .dragging = false,
        .prev_pinch_dist = 0,
        .divider_frac = 0.5,
        .last_mouse = .{ -1, -1 },
        .corner_fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            corner_size,
            corner_size,
            &corner_image,
            "comptime_corner",
        ),
    };
}

/// Keep both halves' render targets matched to the LIVE canvas: the GPU
/// render texture at the surface's backing size (CSS × DPR — pixel-perfect,
/// recreated only when the size actually changes), and the CPU raster buffer
/// at `cpu_pixel_budget` pixels shaped to the canvas aspect (constant cost
/// at any orientation).  Cheap no-op when nothing changed.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: i32 = @intCast(@max(backing.width, 1));
    const bh: i32 = @intCast(@max(backing.height, 1));
    if (s.rt.color == .invalid or s.rt.width != backing.width or s.rt.height != backing.height) {
        if (s.rt.color != .invalid) {
            z.unloadRenderTexture(f.gl, &s.rt);
        }
        s.rt = z.loadRenderTexture(f.gl, bw, bh);
    }

    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const aspect: f32 = vw / vh;
    const want_w: i32 = @trunc(@max(@round(@sqrt(cpu_pixel_budget * aspect)), 16));
    const want_h: i32 = @trunc(@max(@round(float(want_w) / aspect), 16));
    const dims: Vec2i = s.sw.colorBufferDims();
    if (dims[0] != want_w or dims[1] != want_h) {
        s.sw.resize(s.gpa, want_w, want_h) catch return;
        s.sw_fb.resize(f.gl, @intCast(want_w), @intCast(want_h), s.sw.colorBufferBytes(), "helmet_sw");
    }
}

fn clampDist(s: *State) void {
    s.cam_dist = clamp(s.cam_dist, 1.5, 9.0);
}

fn handleInput(f: *z.Frame, s: *State) void {
    const touch_count: i32 = z.getTouchPointCount(f.input);
    if (touch_count >= 2) {
        const t0: Vec2 = z.getTouchPosition(f.input, 0);
        const t1: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = t1[0] - t0[0];
        const dy: f32 = t1[1] - t0[1];
        const d: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch_dist < 1.0 or d < 1.0) {
            s.prev_pinch_dist = d;
        } else {
            s.cam_dist *= s.prev_pinch_dist / d;
            s.prev_pinch_dist = d;
            clampDist(s);
        }
        s.dragging = false;
        return;
    }
    s.prev_pinch_dist = 0;

    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist *= (1.0 - wheel * 0.1);
        clampDist(s);
    }

    if (z.isMouseButtonDown(f.input, .left)) {
        const d: Vec2 = z.getMouseDelta(f.input);
        if (s.dragging) {
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, -1.45, 1.45);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
}

/// The FS uniform block, built with the SAME values pbr3d's `buildUbo`
/// writes for the GPU draw (one normalized directional light + ambient +
/// the glTF material factors).  Because `pbr.fs.Ubo` IS the shader's
/// uniform struct, the CPU half reads bit-identical uniforms.
fn buildCpuUbo(s: *const State, eye: Vec) pbr.fs.Ubo {
    return buildUboFromFactors(
        s.base_color_factor,
        s.metallic_factor,
        s.roughness_factor,
        s.emissive_factor,
        eye,
    );
}

/// Run pbr_vs.shaderMain over every vertex, then rasterize the triangles
/// through pbr_fs.shaderMain with depth testing — the software mirror of
/// what the GPU pipeline does with the same two files.
fn renderCpuHelmet(
    s: *State,
    view: Mat,
    proj: Mat,
    model_m: Mat,
    eye: Vec,
) void {
    s.sw.clearColor(.{ .r = 10, .g = 12, .b = 20, .a = 255 });
    s.sw.clearDepth(1.0);
    s.sw.clear(.{ .color = true, .depth = true });

    // ---- vertex stage: one shaderMain call per vertex ----
    var vs_io: pbr.vs.Io = undefined;
    vs_io.mat_model = model_m;
    vs_io.mat_view = view;
    vs_io.mat_projection = proj;
    vs_io.mat_normal = model_m; // uniform scale: normal matrix == model
    vs_io.light_space_matrix = identity(); // shadows gated off
    for (s.mesh.vertices, s.vs_outs) |v, *out| {
        vs_io.vertex_position = .{ v.position[0], v.position[1], v.position[2] };
        vs_io.vertex_tex_coord = .{ v.tex_coord[0], v.tex_coord[1] };
        vs_io.vertex_normal = .{ v.normal[0], v.normal[1], v.normal[2] };
        vs_io.vertex_color = .{ v.color[0], v.color[1], v.color[2], v.color[3] };
        vs_io.vertex_tangent = .{ v.tangent[0], v.tangent[1], v.tangent[2], v.tangent[3] };
        out.* = pbr.vs.shaderMain(vs_io);
    }

    // ---- fragment stage: depth-tested rasterization, sampling the five
    //      maps through CPU TextureRefs ----
    var base_fs_io: pbr.fs.Io = undefined;
    base_fs_io.u = buildCpuUbo(s, eye);
    base_fs_io._texture0 = s.maps[0].ref();
    base_fs_io._metallic_roughness = s.maps[1].ref();
    base_fs_io._normal = s.maps[2].ref();
    base_fs_io._occlusion = s.maps[3].ref();
    base_fs_io._emissive = s.maps[4].ref();
    // Shadows are gated off (shadow_enabled = 0); the unconditional sample
    // at the shader's uniform top still happens, so bind a white 1×1.
    const white_px = [_]u8{ 255, 255, 255, 255 };
    base_fs_io._shadow_map = .{ .pixels = &white_px, .width = 1, .height = 1 };

    const connect: fn (pbr.vs.Out, *pbr.fs.Io) void = comptime z.shader.autoConnect(pbr.vs.Out, pbr.fs.Io);
    z.raster_shader.rasterizeTriangles(
        pbr.vs,
        pbr.fs,
        &s.sw,
        s.vs_outs,
        s.indices_u32,
        base_fs_io,
        connect,
        .{ .depth_test = true },
    );
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    handleInput(f, s);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // ---- Shared orbit camera — BOTH halves consume these matrices.
    //      The projection aspect is the LIVE canvas aspect, so portrait,
    //      landscape, and mid-rotation frames all render undistorted. ----
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const sy: f32 = @sin(s.cam_yaw);
    const cyaw: f32 = @cos(s.cam_yaw);
    const eye: Vec = vec(s.cam_dist * cp * sy, s.cam_dist * sp, s.cam_dist * cp * cyaw);
    const view: Mat = lookAtRh(eye, cam_target, vec(0, 1, 0));
    const aspect: f32 = vw / vh;
    const proj: Mat = perspectiveFovRh(fovy, aspect, z_near, z_far);
    // glTF helmet is Z-up; stand it upright.
    const model_m: Mat = rotationX(1.5707963);

    // ---- CPU: pbr_vs + pbr_fs on the software rasterizer ----
    renderCpuHelmet(s, view, proj, model_m, eye);
    s.sw_fb.update(f.gpu.queue, s.sw.colorBufferBytes());

    // ---- GPU: the SAME shaders via WGSL, into the render texture ----
    z.beginTextureMode(f.gl, s.rt, .{ .r = 10, .g = 12, .b = 20, .a = 255 });
    s.renderer.drawIntoPass(f.gl.pass, f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ eye[0], eye[1], eye[2] } },
        .light = .{ .dir = light_dir, .color = light_color, .ambient = light_ambient },
    }, s.model, model_m);
    z.endTextureMode(f.gl);

    // ---- SCREEN PASS: open once, clear, then composite. ----
    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 8, .g = 9, .b = 14, .a = 255 });

    // ---- Composite: GPU full-surface, CPU over the left of the splitter.
    //      The divider lives as a width FRACTION (rotation-stable) and
    //      follows the pointer whenever it reports a new position. ----
    f.gl.texture(
        .{ .x = 0, .y = 0, .width = vw, .height = vh },
        s.rt.asTexture(),
        .{ .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );
    const m: Vec2 = z.getMousePosition(f.input);
    // Ignore the pre-input (0,0) report (no pointer event yet) so the
    // divider stays at its center default until a real position arrives.
    const is_first_zero: bool = s.last_mouse[0] < 0 and m[0] == 0 and m[1] == 0;
    if (!is_first_zero and (m[0] != s.last_mouse[0] or m[1] != s.last_mouse[1])) {
        s.last_mouse = m;
        s.divider_frac = clamp(m[0] / vw, 0.0, 1.0);
    }
    const divider_x: f32 = s.divider_frac * vw;
    z.beginScissorMode(f.gl, 0, 0, divider_x, vh);
    s.sw_fb.present(f.gl, 0, 0, vw, vh);
    z.endScissorMode(f.gl);
    f.gl.rect(
        .{ .x = divider_x - 1.5, .y = 0, .width = 3, .height = vh },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    f.gl.text(
        .{ 16, 14 },
        "CPU pbr_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 122, 14 },
        "GPU pbr_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    // ---- Comptime corner inset (bottom-right): the third target ----------
    // One textured quad of the const image baked above (frozen at the
    // initial camera while the live halves orbit).
    const inset_w: f32 = clamp(@min(vw, vh) * 0.30, 84, 190);
    const ix: f32 = vw - inset_w - 12;
    const iy: f32 = vh - inset_w - 12;
    s.corner_fb.present(f.gl, ix, iy, inset_w, inset_w);
    f.gl.rect(
        .{ .x = ix - 1, .y = iy - 1, .width = inset_w + 2, .height = inset_w + 2 },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .outline = 1.0 },
    );
    f.gl.text(
        .{ ix, iy - 22 },
        "comptime pbr_fs",
        .{ .size = 16, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    // Close the frame. As a launcher child this no-ops (the runner closes it),
    // so a host can still overlay its own UI on top of this app's frame.
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - one PBR shader: CPU | GPU",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            // 2D pipelines carry depth so beginTextureMode can give the RTT a
            // depth attachment for pbr3d to test against.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // Renders CPU/GPU/comptime targets before opening the screen (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
    .memory = .managed,
};
