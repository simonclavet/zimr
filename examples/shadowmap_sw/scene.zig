//! scene.zig — THE shared scene of the shadow-map side-by-side.
//!
//! Everything the three renderers must agree on lives in this one file:
//!
//!   * the GEOMETRY (floor quad, unit cube, and the bunny's placement frame),
//!   * the ANIMATION (orbiting light, spinning objects — pure functions of t),
//!   * the UNIFORM BLOCKS (built with the engine shaders' own `Ubo` types, so
//!     every backend reads bit-identical uniform layouts), and
//!   * the SOFTWARE TWO-PASS RENDER (vertex loops + per-object draws through
//!     the REAL engine shaders `depth_vs/fs` + `lit_shadow_vs/fs`).
//!
//! The GPU half of the app consumes the same geometry/animation/Ubo builders
//! and runs the same four shader FILES via their WGSL build artifacts.  The
//! CPU half calls `drawDepth`/`drawLit` per object over a `raster.Context`.
//! The comptime corner calls `bakeCorner`, whose per-object draws go through
//! `rasterizeToTarget` — same clear-once-draw-N pass shape, evaluated by the
//! Zig compiler.  One scene, one animation, one shader source; three
//! executors.

const z = @import("zimr");
const zm = @import("zm");
const proxy = @import("bunny_proxy");

const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const float = zm.float;
const identity = zm.identity;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const normalize3 = zm.normalize3;
const orthographicRh = zm.orthographicRh;
const rotationY = zm.rotationY;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

/// The engine shadow-shader quartet — the SAME four files the GPU compiles
/// to WGSL, imported as callable Zig for the software targets.
pub const shadow = z.shadow_shaders;

// ============================================================================
// Geometry — position + normal, stride 24; shared verbatim with the GPU
// vertex buffers (the app uploads these very arrays).
// ============================================================================

pub const SceneVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
};

const up_n: [3]f32 = .{ 0, 1, 0 };
pub const floor_half: f32 = 4.0;

pub const floor_verts = [_]SceneVertex{
    .{ .position = .{ -floor_half, 0, -floor_half }, .normal = up_n },
    .{ .position = .{ floor_half, 0, -floor_half }, .normal = up_n },
    .{ .position = .{ floor_half, 0, floor_half }, .normal = up_n },
    .{ .position = .{ -floor_half, 0, floor_half }, .normal = up_n },
};
pub const floor_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

/// Unit-ish cube (half-extent `cs`) with FLAT per-face normals — shadow
/// mapping wants honest face normals.  Placements scale it per axis.
pub const cs: f32 = 0.7;
pub const cube_verts = [_]SceneVertex{
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ -cs, cs, cs }, .normal = .{ 0, 0, 1 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ -cs, cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ cs, cs, -cs }, .normal = .{ 0, 0, -1 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, cs, -cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ cs, cs, cs }, .normal = .{ 1, 0, 0 } },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, -cs }, .normal = .{ -1, 0, 0 } },
    .{ .position = .{ -cs, cs, cs }, .normal = up_n },
    .{ .position = .{ cs, cs, cs }, .normal = up_n },
    .{ .position = .{ cs, cs, -cs }, .normal = up_n },
    .{ .position = .{ -cs, cs, -cs }, .normal = up_n },
    .{ .position = .{ -cs, -cs, -cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ cs, -cs, -cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ cs, -cs, cs }, .normal = .{ 0, -1, 0 } },
    .{ .position = .{ -cs, -cs, cs }, .normal = .{ 0, -1, 0 } },
};
pub const cube_indices = [_]u32{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

// ============================================================================
// Staging + animation — pure functions of time, shared by all three
// renderers (the corner freezes them at `corner_time`).
// ============================================================================

/// The four drawables. The two cubes share the cube buffers; each object
/// gets its own model matrix + color + (on the GPU) uniform buffers.
pub const Object = enum { floor, pillar, receiver, bunny };
pub const objects = [_]Object{ .floor, .pillar, .receiver, .bunny };

/// Tall slim pillar beside the bunny: as the light orbits behind it, its
/// shadow stripe sweeps ACROSS the bunny.  Low wide receiver on the other
/// side: the bunny's silhouette lands on it half an orbit later.  The
/// bunny's own ears self-shadow its back at grazing light angles.
pub const pillar_center: Vec3 = .{ 2.2, 1.0, 0.3 };
pub const pillar_half: Vec3 = .{ 0.22, 1.0, 0.22 };
pub const receiver_center: Vec3 = .{ -2.3, 0.5, -0.5 };
pub const receiver_half: Vec3 = .{ 0.5, 0.5, 0.5 };
pub const bunny_spot: Vec3 = .{ 0.0, 0.0, 0.2 };
pub const bunny_target_height: f32 = 2.0;

pub fn baseColor(o: Object) [4]f32 {
    return switch (o) {
        .floor => .{ 0.80, 0.80, 0.86, 1.0 },
        .pillar => .{ 0.55, 0.70, 0.88, 1.0 },
        .receiver => .{ 0.62, 0.84, 0.62, 1.0 },
        .bunny => .{ 0.87, 0.72, 0.53, 1.0 },
    };
}

/// The bunny's normalization frame — computed from whichever bunny mesh a
/// backend renders (the FULL 69k-tri OBJ live, the baked proxy at comptime),
/// so the same placement math seats both identically.
pub const BunnyFrame = struct {
    cx: f32,
    min_y: f32,
    cz: f32,
    scale: f32,
};

pub fn bunnyFrame(mn: [3]f32, mx: [3]f32) BunnyFrame {
    return .{
        .cx = (mn[0] + mx[0]) * 0.5,
        .min_y = mn[1],
        .cz = (mn[2] + mx[2]) * 0.5,
        .scale = bunny_target_height / @max(mx[1] - mn[1], 1.0e-4),
    };
}

/// Per-object spin about Y (the "rotation" varyings tour: every object's
/// normal matrix is live).  The floor stays put.
fn spinAngle(o: Object, t: f32) f32 {
    return switch (o) {
        .floor => 0.0,
        .pillar => t * 0.9,
        .receiver => -t * 0.7,
        .bunny => t * 0.6,
    };
}

/// Model matrix: place ∘ spin ∘ scale (cubes scale the unit cube to their
/// half-extents; the bunny additionally re-centers its mesh frame first).
pub fn modelMatrix(o: Object, t: f32, bunny: BunnyFrame) Mat {
    const spin: Mat = rotationY(spinAngle(o, t));
    switch (o) {
        .floor => return identity(),
        .pillar, .receiver => {
            const c: Vec3 = if (o == .pillar) pillar_center else receiver_center;
            const h: Vec3 = if (o == .pillar) pillar_half else receiver_half;
            const scale_it: Mat = scaling(h[0] / cs, h[1] / cs, h[2] / cs);
            const place_it: Mat = translation(c[0], c[1], c[2]);
            return mulMat(place_it, mulMat(spin, scale_it));
        },
        .bunny => {
            const center_it: Mat = translation(-bunny.cx, -bunny.min_y, -bunny.cz);
            const scale_it: Mat = scaling(bunny.scale, bunny.scale, bunny.scale);
            const place_it: Mat = translation(bunny_spot[0], bunny_spot[1], bunny_spot[2]);
            return mulMat(place_it, mulMat(spin, mulMat(scale_it, center_it)));
        },
    }
}

/// Normal matrix — the spin rotation alone.  Correct here even for the
/// non-uniformly scaled cubes: their face normals are axis-aligned, and a
/// diagonal scale preserves axis directions, so only the rotation matters.
pub fn normalMatrix(o: Object, t: f32) Mat {
    return rotationY(spinAngle(o, t));
}

/// The directional light ORBITS the scene: shadows sweep continuously,
/// the pillar stripe crosses the bunny once per revolution, the bunny's
/// silhouette walks across the receiver and floor, and the bunny's ears
/// self-shadow at grazing angles.
pub const light_orbit_radius: f32 = 7.0;
pub const light_height: f32 = 6.5;
pub const light_speed: f32 = 0.45;
const light_target: Vec = .{ 0, 0.5, 0, 1 };

pub const LightRig = struct {
    vp: Mat,
    to_light: Vec,
};

pub fn lightRig(t: f32) LightRig {
    const a: f32 = t * light_speed + 0.35;
    const eye: Vec = vec(
        light_target[0] + light_orbit_radius * @cos(a),
        light_height,
        light_target[2] + light_orbit_radius * @sin(a),
    );
    const view: Mat = lookAtRh(eye, light_target, vec(0, 1, 0));
    const projection: Mat = orthographicRh(13.0, 13.0, 1.0, 20.0);
    return .{ .vp = mulMat(projection, view), .to_light = normalize3(eye - light_target) };
}

// ============================================================================
// Uniform blocks — built with the SHADERS' OWN Ubo types, so all three
// backends read bit-identical layouts (the GPU uploads these structs
// verbatim; the software targets pass them straight into `shaderMain`).
// ============================================================================

/// 8-bit shadow-map bias for the SOFTWARE targets (their map is rgba8 —
/// 256 depth levels — so the compare needs ~8× the slack of the GPU's
/// rgba16_float map, whose bias is the Ubo default).  Same shader; the
/// precision difference is data.
pub const soft_bias: Vec = .{ 0.018, 0.010, 0, 0 };

pub fn depthUbo(model: Mat, light_vp: Mat) shadow.depth_vs.Io {
    var io: shadow.depth_vs.Io = undefined;
    io.u = .{ .mvp = mulMat(light_vp, model), .params = .{ 1.0, 20.0, 0.0, 1.0 }, .mode = 0 };
    return io;
}

pub fn litVsUbo(
    model: Mat,
    cam_vp: Mat,
    light_vp: Mat,
    normal_mat: Mat,
) shadow.lit_vs.Io {
    var io: shadow.lit_vs.Io = undefined;
    io.u = .{
        .mvp = mulMat(cam_vp, model),
        .light_vp = mulMat(light_vp, model),
        .normal_matrix = normal_mat,
    };
    return io;
}

pub fn litFsUbo(o: Object, to_light: Vec, bias: Vec) shadow.lit_fs.Io {
    var io: shadow.lit_fs.Io = undefined;
    io.u = .{
        .light_dir = .{ to_light[0], to_light[1], to_light[2], 0.0 },
        .base_color = baseColor(o),
        .params = bias,
    };
    return io;
}

// ============================================================================
// Software passes — the vertex loops + per-object draws every software
// target shares.  `drawDepth`/`drawLit` render one object into a runtime
// `raster.Context` (the live CPU half); `bakeCorner` runs the SAME loops
// through `rasterizeToTarget` so the whole two-pass render happens at
// comptime.  Both are "clear once, draw N objects" — a GPU pass in shape.
// ============================================================================

pub fn runDepthVs(
    verts: []const SceneVertex,
    base_io: shadow.depth_vs.Io,
    outs: []shadow.depth_vs.Out,
) void {
    var io: shadow.depth_vs.Io = base_io;
    for (verts, outs) |v, *out| {
        io.vertex_position = .{ v.position[0], v.position[1], v.position[2] };
        out.* = shadow.depth_vs.shaderMain(io);
    }
}

pub fn runLitVs(
    verts: []const SceneVertex,
    base_io: shadow.lit_vs.Io,
    outs: []shadow.lit_vs.Out,
) void {
    var io: shadow.lit_vs.Io = base_io;
    for (verts, outs) |v, *out| {
        io.vertex_position = .{ v.position[0], v.position[1], v.position[2] };
        io.vertex_normal = .{ v.normal[0], v.normal[1], v.normal[2] };
        out.* = shadow.lit_vs.shaderMain(io);
    }
}

pub const connect_depth: fn (shadow.depth_vs.Out, *shadow.depth_fs.Io) void =
    z.shader.autoConnect(shadow.depth_vs.Out, shadow.depth_fs.Io);
pub const connect_lit: fn (shadow.lit_vs.Out, *shadow.lit_fs.Io) void =
    z.shader.autoConnect(shadow.lit_vs.Out, shadow.lit_fs.Io);

/// Draw one object into the light-view depth pass (runtime Context sink).
pub fn drawDepth(
    ctx: *z.raster.Context,
    verts: []const SceneVertex,
    indices: []const u32,
    io: shadow.depth_vs.Io,
    outs: []shadow.depth_vs.Out,
) void {
    runDepthVs(verts, io, outs[0..verts.len]);
    const fs_io: shadow.depth_fs.Io = undefined;
    z.raster_shader.rasterizeTriangles(
        shadow.depth_vs,
        shadow.depth_fs,
        ctx,
        outs[0..verts.len],
        indices,
        fs_io,
        connect_depth,
        .{ .front_face = .none, .depth_test = true },
    );
}

/// Draw one object into the lit pass, sampling `shadow_map` (runtime sink).
pub fn drawLit(
    ctx: *z.raster.Context,
    verts: []const SceneVertex,
    indices: []const u32,
    vs_io: shadow.lit_vs.Io,
    fs_io_in: shadow.lit_fs.Io,
    outs: []shadow.lit_vs.Out,
) void {
    runLitVs(verts, vs_io, outs[0..verts.len]);
    z.raster_shader.rasterizeTriangles(
        shadow.lit_vs,
        shadow.lit_fs,
        ctx,
        outs[0..verts.len],
        indices,
        fs_io_in,
        connect_lit,
        .{ .front_face = .none, .depth_test = true },
    );
}

// ============================================================================
// The comptime corner — the whole two-pass shadow render as a pure function
// the COMPILER evaluates.  Same placements, same animation functions (frozen
// at `corner_time`), same Ubo builders, same engine shaders; the bunny is the
// build-baked decimated proxy (`mesh_bake` OBJ path) because 69k triangles
// is past any sane comptime budget while ~700 reads as THE bunny at inset
// size.  Runtime-callable too — `native_verify.zig` uses that to pin the
// comptime bake byte-for-byte against a runtime evaluation of this very
// function.
// ============================================================================

pub const corner_time: f32 = 3.6;

pub fn CornerBake(comptime sm_res: usize, comptime w: usize, comptime h: usize) type {
    return struct {
        shadow_map: [sm_res * sm_res * 4]u8,
        image: [w * h * 4]u8,
    };
}

pub fn bakeCorner(
    comptime sm_res: usize,
    comptime w: usize,
    comptime h: usize,
) CornerBake(sm_res, w, h) {
    // ---- the proxy bunny, flattened + measured (u16 → u32, [N][3] → flat) --
    var bunny_verts: [proxy.vertex_count]SceneVertex = undefined;
    var mn: [3]f32 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var mx: [3]f32 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (proxy.positions, proxy.normals, &bunny_verts) |p, n, *sv| {
        sv.* = .{ .position = p, .normal = n };
        var a: usize = 0;
        while (a < 3) : (a += 1) {
            mn[a] = @min(mn[a], p[a]);
            mx[a] = @max(mx[a], p[a]);
        }
    }
    var bunny_idx: [proxy.indices.len]u32 = undefined;
    for (proxy.indices, &bunny_idx) |i16v, *i32v| {
        i32v.* = i16v;
    }
    const bunny: BunnyFrame = bunnyFrame(mn, mx);

    const t: f32 = corner_time;
    const rig: LightRig = lightRig(t);

    // Frozen corner camera (the live halves orbit; the corner is a still).
    const cam_eye: Vec = vec(6.4, 4.6, 8.0);
    const cam_view: Mat = lookAtRh(cam_eye, vec(0, 1.0, 0), vec(0, 1, 0));
    const cam_proj: Mat = zm.perspectiveFovRh(0.8, float(w) / float(h), 0.1, 100.0);
    const cam_vp: Mat = mulMat(cam_proj, cam_view);

    var outs: [proxy.vertex_count]shadow.depth_vs.Out = undefined;
    var lit_outs: [proxy.vertex_count]shadow.lit_vs.Out = undefined;

    var bake: CornerBake(sm_res, w, h) = undefined;

    // ---- PASS 1: light-view depth, one draw per object into one target ----
    {
        var img: [sm_res * sm_res][4]u8 = @splat(.{ 255, 255, 255, 255 }); // clear = far
        var depth: [sm_res * sm_res]f32 = @splat(1.0);
        for (objects) |o| {
            const g: Geometry = geometryOf(o, &bunny_verts, &bunny_idx);
            const io: shadow.depth_vs.Io = depthUbo(modelMatrix(o, t, bunny), rig.vp);
            runDepthVs(g.verts, io, outs[0..g.verts.len]);
            const fs_io: shadow.depth_fs.Io = undefined;
            z.raster_shader.rasterizeToTarget(
                shadow.depth_vs,
                shadow.depth_fs,
                sm_res,
                sm_res,
                outs[0..g.verts.len],
                g.indices,
                fs_io,
                connect_depth,
                .{ .front_face = .none, .depth_test = true },
                &img,
                &depth,
            );
        }
        bake.shadow_map = @bitCast(img);
    }

    // ---- PASS 2: lit + shadow-tested, sampling pass 1 through the same
    //      nearest-filtered `TextureRef` the live CPU half binds ----
    {
        var img: [w * h][4]u8 = @splat(.{ 12, 12, 28, 255 }); // clear = dark sky
        var depth: [w * h]f32 = @splat(1.0);
        for (objects) |o| {
            const g: Geometry = geometryOf(o, &bunny_verts, &bunny_idx);
            const vs_io: shadow.lit_vs.Io = litVsUbo(
                modelMatrix(o, t, bunny),
                cam_vp,
                rig.vp,
                normalMatrix(o, t),
            );
            var fs_io: shadow.lit_fs.Io = litFsUbo(o, rig.to_light, soft_bias);
            fs_io._shadow_map = .{
                .pixels = &bake.shadow_map,
                .width = sm_res,
                .height = sm_res,
                .linear = false, // nearest — depth comparisons must not blend texels
            };
            runLitVs(g.verts, vs_io, lit_outs[0..g.verts.len]);
            z.raster_shader.rasterizeToTarget(
                shadow.lit_vs,
                shadow.lit_fs,
                w,
                h,
                lit_outs[0..g.verts.len],
                g.indices,
                fs_io,
                connect_lit,
                .{ .front_face = .none, .depth_test = true },
                &img,
                &depth,
            );
        }
        bake.image = @bitCast(img);
    }
    return bake;
}

/// One object's geometry — a named pair so every renderer's object loop
/// reads the same way.
pub const Geometry = struct {
    verts: []const SceneVertex,
    indices: []const u32,
};

fn geometryOf(
    o: Object,
    bunny_verts: []const SceneVertex,
    bunny_idx: []const u32,
) Geometry {
    return switch (o) {
        .floor => .{ .verts = &floor_verts, .indices = &floor_indices },
        .pillar, .receiver => .{ .verts = &cube_verts, .indices = &cube_indices },
        .bunny => .{ .verts = bunny_verts, .indices = bunny_idx },
    };
}
