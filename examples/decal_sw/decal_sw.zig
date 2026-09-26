//! decal_sw - ONE Zig decal shader, TWO renderers, side by side.
//!
//! `src/shaders/decal_vs.zig` + `decal_fs.zig` are the SAME files the build
//! compiles to SPIR-V -> WGSL for the GPU decal pipeline. Here they are also
//! imported as plain Zig (`z.decal_shaders`) and run by the software rasterizer
//! per vertex / per fragment, so the projector math - world -> decal-box space,
//! the inside-box mask, the facing mask - runs bit-identically on hardware and
//! in software:
//!   - RIGHT (GPU): the receiver sphere is drawn flat, then the decals are
//!     painted by `z.drawDecal`'s WebGPU pipeline, into an offscreen render
//!     texture composited as 2D.
//!   - LEFT (CPU): the same sphere is filled flat, then the SAME decal_vs /
//!     decal_fs `shaderMain`s run over the receiver triangles through
//!     `raster_shader.rasterizeTriangles`, depth-tested `.less_equal` with no
//!     depth write and alpha-over blend - matching the GPU decal pipeline's
//!     `.less_equal_no_write` overlay state.
//! Same mesh, same projector matrices, same DecalUbo values, same decal
//! texture, same camera. The base surface is a flat unlit colour on both sides
//! (trivially identical) so every visible difference is the decal itself.
//!
//! Drag to orbit, wheel/pinch to zoom; the splitter follows the pointer. The
//! known v1 divergence, visible if you look closely: the CPU half renders at a
//! reduced pixel budget and samples the decal texture nearest (the GPU view is
//! bilinear).

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const Vec2i = zm.Vec2i;
const Mat = zm.Mat;
const vec = zm.vec;
const clamp = zm.clamp;
const lookAtRh = zm.lookAtRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationZ = zm.rotationZ;
const compose = zm.compose;
const radFromDeg = zm.radFromDeg;
const Color = zm.Color;

const decal = z.decal_shaders;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// The CPU half renders a constant pixel budget shaped to the live canvas
// aspect, so rotating the phone never stretches and never changes the per-frame
// CPU cost. ~30k px ~ 220x136.
const cpu_pixel_budget: f32 = 30_000;

const decal_tex_edge: u32 = 64;
const decal_size: f32 = 0.7; // world-space edge of the decal projector box
const max_decals: u32 = 24;
const sphere_radius: f32 = 1.0;

const cam_target: Vec = vec(0, 0, 0);
const fovy: f32 = 0.85;
const z_near: f32 = 0.05;
const z_far: f32 = 100.0;

const base_color: Color = .{ .r = 120, .g = 130, .b = 150, .a = 255 };
const bg_clear: Color = .{ .r = 10, .g = 12, .b = 20, .a = 255 };

/// A recorded decal: the world->box projector, the projector facing dir (the
/// surface normal at the hit), and its tint. Both halves consume these.
const Decal = struct {
    projector: Mat,
    forward: Vec,
    color: Color,
};

/// The fragment-stage uniform the decal FS reads, built ONCE per decal and fed
/// to both renderers. Mirrors `draw3d`'s `DecalUbo` field-for-field (the same
/// `params = {half_size, 1/size, 0, 0}` recipe `drawDecal` writes on the GPU).
fn buildDecalUbo(d: Decal) decal.fs.Ubo {
    const col: [4]f32 = Color.toFloats(d.color);
    const half_size: f32 = 0.5 * decal_size;
    return .{
        .projector = d.projector,
        .color = .{ col[0], col[1], col[2], col[3] },
        .params = .{ half_size, 1.0 / decal_size, 0, 0 },
        .forward = d.forward,
    };
}

/// Build the world->box projector for a hit point + surface normal, spun a
/// deterministic amount about its own axis - the SAME construction the decals
/// example uses (look from just outside the surface toward the hit, then spin
/// in-plane). `compose(first, then)` reads in application order.
fn buildProjector(hit_point: Vec, hit_normal: Vec, spin_deg: f32) Mat {
    const eye: Vec = vec(
        hit_point[0] + hit_normal[0],
        hit_point[1] + hit_normal[1],
        hit_point[2] + hit_normal[2],
    );
    const look: Mat = lookAtRh(hit_point, eye, vec(0, 1, 0));
    return compose(look, rotationZ(radFromDeg(spin_deg)));
}

/// One CPU-side decal texture: owned RGBA8 pixels handed to the fragment shader
/// as a `TextureRef`. The GPU view is `rgba8_unorm` (linear), so no sRGB here.
const CpuTex = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    fn ref(self: CpuTex) decal.fs.TextureRef {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height, .srgb = false };
    }
};

/// A de-indexed triangle-soup copy of the receiver mesh (position + normal per
/// vertex), matching how `uploadDecalReceiver` de-indexes for the GPU - so the
/// CPU decal pass rasterizes the exact same triangles.
const CpuReceiver = struct {
    positions: [][3]f32,
    normals: [][3]f32,
    vcount: u32,

    fn deinit(self: *CpuReceiver, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
    }
};

const State = struct {
    gpa: Allocator,
    // ---- GPU half ----
    sphere_model: z.Model,
    receiver: u32, // decal-receiver handle
    decal_tex: z.WgpuTexture,
    // ---- CPU half ----
    cpu_recv: CpuReceiver,
    cpu_tex: CpuTex,
    vs_outs: []decal.vs.Out,
    indices_u32: []u32,
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,
    // ---- shared scene ----
    decals: [max_decals]Decal,
    decal_count: u32,
    place_timer: f32,
    place_index: u32,
    // ---- shared camera / UI ----
    font: z.Font,
    cam_yaw: f32,
    cam_pitch: f32,
    cam_dist: f32,
    dragging: bool,
    prev_pinch_dist: f32,
    last_mouse: Vec2,
    divider_frac: f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.sphere_model);
    s.decal_tex.deinit();
    s.sw_fb.deinit();
    s.cpu_recv.deinit(gpa);
    gpa.free(s.cpu_tex.pixels);
    gpa.free(s.vs_outs);
    gpa.free(s.indices_u32);
    s.sw.deinit(gpa);
}

/// The procedural decal texture as raw RGBA8 bytes - a concentric-ring target
/// that fades to transparent well inside the box edge, so the box clip only
/// ever cuts already-transparent texels. Returns owned pixels; the GPU half
/// wraps the same data in an `z.Image`.
fn makeDecalPixels(gpa: Allocator) ![]u8 {
    const n: usize = decal_tex_edge;
    const px: []u8 = try gpa.alloc(u8, n * n * 4);
    const c: f32 = float(@as(u32, @intCast(n))) * 0.5 - 0.5;
    for (0..n) |y| {
        for (0..n) |x| {
            const dx: f32 = float(@as(i32, @intCast(x))) - c;
            const dy: f32 = float(@as(i32, @intCast(y))) - c;
            const r: f32 = @sqrt(dx * dx + dy * dy) / c;
            var a: u8 = 0;
            var col: [3]u8 = .{ 255, 220, 60 };
            if (r < 0.72) {
                a = 255;
                const band: f32 = @mod(r * 5.0, 1.0);
                col = if (band < 0.5) .{ 230, 60, 60 } else .{ 255, 220, 60 };
                if (r > 0.55) {
                    a = @round(255.0 * (0.72 - r) / 0.17);
                }
            }
            const i: usize = (y * n + x) * 4;
            px[i + 0] = col[0];
            px[i + 1] = col[1];
            px[i + 2] = col[2];
            px[i + 3] = a;
        }
    }
    return px;
}

/// De-index a sphere mesh into a triangle soup of positions + normals, matching
/// `uploadDecalReceiver`'s de-indexing so both halves rasterize identical
/// triangles.
fn buildCpuReceiver(gpa: Allocator, mesh: z.types.Mesh) !CpuReceiver {
    const tri_count: usize = @intCast(mesh.triangleCount);
    const vcount: usize = tri_count * 3;
    const positions: [][3]f32 = try gpa.alloc([3]f32, vcount);
    errdefer gpa.free(positions);
    const normals: [][3]f32 = try gpa.alloc([3]f32, vcount);
    errdefer gpa.free(normals);
    const verts: [*c]f32 = mesh.vertices;
    const norms: [*c]f32 = mesh.normals;
    const idx: [*c]u16 = mesh.indices;
    var i: usize = 0;
    while (i < vcount) : (i += 1) {
        const vi: usize = if (idx != null) @intCast(idx[i]) else i;
        positions[i] = .{ verts[vi * 3 + 0], verts[vi * 3 + 1], verts[vi * 3 + 2] };
        if (norms != null) {
            normals[i] = .{ norms[vi * 3 + 0], norms[vi * 3 + 1], norms[vi * 3 + 2] };
        } else {
            normals[i] = .{ 0, 1, 0 };
        }
    }
    return .{ .positions = positions, .normals = normals, .vcount = @intCast(vcount) };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // ---- Receiver mesh: one sphere, used by BOTH halves ----
    const mesh: z.types.Mesh = try z.genMeshSphere(gpa, sphere_radius, 32, 24);

    // GPU: a drawable model + a decal receiver from the same mesh.
    const sphere_model: z.Model = try z.loadModelFromMesh(f.gl, gpa, mesh);
    const receiver: u32 = z.uploadDecalReceiver(f.gl, mesh) orelse return error.DecalReceiverFailed;

    // CPU: a de-indexed triangle soup of the same mesh.
    var cpu_recv: CpuReceiver = try buildCpuReceiver(gpa, mesh);
    errdefer cpu_recv.deinit(gpa);

    // ---- Decal texture: one procedural target, shared by both halves ----
    const tex_pixels: []u8 = try makeDecalPixels(gpa);
    errdefer gpa.free(tex_pixels);
    const cpu_tex: CpuTex = .{ .pixels = tex_pixels, .width = decal_tex_edge, .height = decal_tex_edge };
    // GPU texture wraps a COPY of the same bytes (genImageColor owns its data).
    const img: z.Image = try z.genImageColor(
        gpa,
        @intCast(decal_tex_edge),
        @intCast(decal_tex_edge),
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    );
    @memcpy(@as([*]u8, @ptrCast(img.data.?))[0 .. decal_tex_edge * decal_tex_edge * 4], tex_pixels);
    const decal_tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    defer z.unloadImage(gpa, img);

    // Per-vertex VS output scratch + u32 index list for the CPU decal pass
    // (the receiver soup is already de-indexed, so indices are 0, 1, 2, ...).
    const vs_outs: []decal.vs.Out = try gpa.alloc(decal.vs.Out, cpu_recv.vcount);
    errdefer gpa.free(vs_outs);
    const indices_u32: []u32 = try gpa.alloc(u32, cpu_recv.vcount);
    errdefer gpa.free(indices_u32);
    for (indices_u32, 0..) |*iv, i| {
        iv.* = @intCast(i);
    }

    const sw: z.raster.Context = try z.raster.Context.init(gpa, 220, 136);
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        220,
        136,
        sw.colorBufferBytes(),
        "decal_sw",
    );
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);

    s.* = .{
        .gpa = gpa,
        .sphere_model = sphere_model,
        .receiver = receiver,
        .decal_tex = decal_tex,
        .cpu_recv = cpu_recv,
        .cpu_tex = cpu_tex,
        .vs_outs = vs_outs,
        .indices_u32 = indices_u32,
        .sw = sw,
        .sw_fb = sw_fb,
        .decals = undefined,
        .decal_count = 0,
        .place_timer = 0,
        .place_index = 0,
        .font = font,
        .cam_yaw = 0.7,
        .cam_pitch = 0.35,
        .cam_dist = 3.6,
        .dragging = false,
        .prev_pinch_dist = 0,
        .last_mouse = .{ -1, -1 },
        .divider_frac = 0.5,
    };
}

/// Scatter decals around the sphere over time, one every ~0.35 s, at
/// deterministic points on the surface (a spiral of directions), so both
/// halves paint the exact same set. Each projector faces along the surface
/// normal (= the outward direction on a unit sphere).
fn maybePlaceDecal(s: *State, dt: f32) void {
    if (s.decal_count >= max_decals) {
        return;
    }
    s.place_timer += dt;
    if (s.place_timer < 0.35) {
        return;
    }
    s.place_timer = 0;

    // Fibonacci-ish spiral of surface points: deterministic, well-spread.
    const i: f32 = float(@as(i32, @intCast(s.place_index)));
    const golden: f32 = 2.399963; // golden angle in radians
    const yv: f32 = 1.0 - 2.0 * (i + 0.5) / float(max_decals);
    const rr: f32 = @sqrt(@max(0.0, 1.0 - yv * yv));
    const spiral_angle: f32 = i * golden;
    const dir: Vec3 = .{ rr * @cos(spiral_angle), yv, rr * @sin(spiral_angle) };
    const normal: Vec = vec(dir[0], dir[1], dir[2]);
    const point: Vec = vec(dir[0] * sphere_radius, dir[1] * sphere_radius, dir[2] * sphere_radius);
    const spin_deg: f32 = @mod(i * 47.0, 360.0) - 180.0;

    s.decals[s.decal_count] = .{
        .projector = buildProjector(point, normal, spin_deg),
        .forward = normal,
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    s.decal_count += 1;
    s.place_index += 1;
}

/// The CPU half: fill the sphere flat, then run decal_vs + decal_fs over the
/// receiver triangles once per decal, depth-tested `.less_equal` (no write) and
/// alpha-blended over - the software mirror of the GPU decal overlay.
fn renderCpu(s: *State, view: Mat, proj: Mat) void {
    s.sw.clearColor(bg_clear);
    s.sw.clearDepth(1.0);
    s.sw.clear(.{ .color = true, .depth = true });

    // ---- Base surface: flat unlit fill of the sphere, depth-writing so the
    //      decal overlay can depth-test against it. Runs decal_vs for the
    //      geometry (position + world varyings), and a trivial flat FS. ----
    const vp: Mat = compose(view, proj); // apply view then projection

    var vs_io: decal.vs.Io = undefined;
    vs_io.u = .{ .vp = vp };
    for (0..s.cpu_recv.vcount) |i| {
        vs_io.p = s.cpu_recv.positions[i];
        vs_io.n = s.cpu_recv.normals[i];
        s.vs_outs[i] = decal.vs.shaderMain(vs_io);
    }

    // Base pass: same VS outputs, a flat colour FS, depth write ON so the
    // sphere occludes its own back and the decals depth-test against it.
    const base_rgba: [4]f32 = colorToLinear(base_color);
    fillTrianglesFlat(s, base_rgba);

    // ---- Decal overlay: the SHARED decal_fs, once per decal. ----
    const connect: fn (decal.vs.Out, *decal.fs.Io) void = comptime z.shader.autoConnect(decal.vs.Out, decal.fs.Io);
    var base_fs_io: decal.fs.Io = undefined;
    base_fs_io._decal = s.cpu_tex.ref();
    var di: u32 = 0;
    while (di < s.decal_count) : (di += 1) {
        base_fs_io.u = buildDecalUbo(s.decals[di]);
        z.raster_shader.rasterizeTriangles(
            decal.vs,
            decal.fs,
            &s.sw,
            s.vs_outs,
            s.indices_u32,
            base_fs_io,
            connect,
            .{
                .front_face = .none, // sphere winding varies; the facing mask handles culling
                .depth_test = true,
                .depth_compare = .less_equal,
                .depth_write = false,
                .blend = true,
            },
        );
    }
}

fn colorToLinear(c: Color) [4]f32 {
    const f: [4]f32 = Color.toFloats(c);
    return .{ f[0], f[1], f[2], f[3] };
}

/// Flat-fill the receiver triangles into the CPU colour+depth buffer (base
/// surface), depth-writing with `.less` so the sphere is solid. Uses the shared
/// rasterizer with a constant-colour path by writing directly - a tiny inline
/// FS-free fill keeps the base trivially identical to the GPU's flat draw.
fn fillTrianglesFlat(s: *State, rgba: [4]f32) void {
    const connect: fn (decal.vs.Out, *FlatFs.Io) void = comptime z.shader.autoConnect(decal.vs.Out, FlatFs.Io);
    const fs_io: FlatFs.Io = .{ .u = .{ .rgba = rgba }, .o_world = .{ 0, 0, 0 }, .o_normal = .{ 0, 0, 0 } };
    z.raster_shader.rasterizeTriangles(
        decal.vs,
        FlatFs,
        &s.sw,
        s.vs_outs,
        s.indices_u32,
        fs_io,
        connect,
        .{
            .front_face = .none,
            .depth_test = true,
            .depth_compare = .less,
            .depth_write = true,
            .blend = false,
        },
    );
}

/// A trivial flat-colour fragment shader for the base sphere fill, sharing the
/// decal VS's `Out` (it reads no varyings, just writes a constant). Written in
/// the same `shaderMain` shape the rasterizer expects, so the base pass goes
/// through the identical code path as the overlay.
const FlatFs = struct {
    pub const Ubo = struct { rgba: [4]f32 };
    pub const Io = struct {
        u: FlatFs.Ubo,
        o_world: Vec3,
        o_normal: Vec3,
        /// The rasterizer reads `Io.Ubo` (mirroring the generated IoT); alias
        /// the outer type so `buildDecalUbo`-style callers and the rasterizer
        /// agree on one uniform type.
        pub const Ubo = FlatFs.Ubo;
    };
    pub const Out = struct { final_color: Vec };
    pub fn shaderMain(io_in: Io) Out {
        return .{ .final_color = io_in.u.rgba };
    }
};

fn clampDist(s: *State) void {
    s.cam_dist = clamp(s.cam_dist, 1.8, 8.0);
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
        s.cam_dist *= 1.0 - wheel * 0.1;
        clampDist(s);
    }

    const down: bool = z.isMouseButtonDown(f.input, .left);
    const m: Vec2 = z.getMousePosition(f.input);
    if (down and s.dragging) {
        const ddx: f32 = m[0] - s.last_mouse[0];
        const ddy: f32 = m[1] - s.last_mouse[1];
        s.cam_yaw -= ddx * 0.01;
        s.cam_pitch = clamp(s.cam_pitch - ddy * 0.01, -1.4, 1.4);
    }
    s.dragging = down;
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    handleInput(f, s);
    maybePlaceDecal(s, 1.0 / 60.0);

    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, .{ .r = 8, .g = 9, .b = 14, .a = 255 });

    // ---- Shared orbit camera - BOTH halves consume these matrices ----
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const sy: f32 = @sin(s.cam_yaw);
    const cyaw: f32 = @cos(s.cam_yaw);
    const eye: Vec = vec(s.cam_dist * cp * sy, s.cam_dist * sp, s.cam_dist * cp * cyaw);
    const view: Mat = lookAtRh(eye, cam_target, vec(0, 1, 0));
    const aspect: f32 = vw / vh;
    const proj: Mat = perspectiveFovRh(fovy, aspect, z_near, z_far);

    // ---- CPU: flat sphere + decal_vs/decal_fs on the software rasterizer ----
    renderCpu(s, view, proj);
    s.sw_fb.update(f.gpu.queue, s.sw.colorBufferBytes());

    // ---- GPU: flat sphere + the SAME decal shaders via WGSL, drawn directly
    //      into the live frame across the full canvas (the immediate-3D path
    //      renders to the main framebuffer; the CPU half then composites over
    //      the left of the splitter). ----
    z.beginMode3D(f.gl, .{
        .position = .{ eye[0], eye[1], eye[2], 0 },
        .target = .{ 0, 0, 0, 0 },
        .up = .{ 0, 1, 0, 0 },
        .fovy_deg = fovy * 57.29578,
    });
    z.drawModel(f.gl, s.sphere_model, .{ 0, 0, 0, 0 }, 1.0, base_color);
    var di: u32 = 0;
    while (di < s.decal_count) : (di += 1) {
        const d: Decal = s.decals[di];
        z.drawDecal(f.gl, s.receiver, d.projector, s.decal_tex, .{
            .size = decal_size,
            .tint = d.color,
            .forward = d.forward,
        });
    }
    z.endMode3D(f.gl);

    // ---- Composite: the GPU scene fills the frame; draw the CPU framebuffer
    //      over the left of the splitter. ----
    const m: Vec2 = z.getMousePosition(f.input);
    const is_first_zero: bool = s.last_mouse[0] < 0 and m[0] == 0 and m[1] == 0;
    if (!is_first_zero and !s.dragging and (m[0] != s.last_mouse[0] or m[1] != s.last_mouse[1])) {
        s.divider_frac = clamp(m[0] / vw, 0.0, 1.0);
    }
    s.last_mouse = m;
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
        "CPU decal_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 150, 14 },
        "GPU decal_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
}

/// Keep the CPU raster buffer matched to the live canvas: `cpu_pixel_budget`
/// pixels shaped to the canvas aspect (constant cost at any orientation). The
/// GPU half draws straight into the live frame, so it needs no target here.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const aspect: f32 = vw / vh;
    const want_w: i32 = @trunc(@max(@round(@sqrt(cpu_pixel_budget * aspect)), 16));
    const want_h: i32 = @trunc(@max(@round(float(want_w) / aspect), 16));
    const dims: Vec2i = s.sw.colorBufferDims();
    if (dims[0] != want_w or dims[1] != want_h) {
        s.sw.resize(s.gpa, want_w, want_h) catch return;
        s.sw_fb.resize(f.gl, @intCast(want_w), @intCast(want_h), s.sw.colorBufferBytes(), "decal_sw");
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "decal_sw — one decal shader, CPU vs GPU",
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .update = update,
    .deinit = deinit,
};

pub fn main() !void {
    try z.run(app);
}
