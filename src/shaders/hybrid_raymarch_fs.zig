//! src/shaders/hybrid_raymarch_fs.zig - sphere-traced SDF scene with
//! true depth output, the marcher behind `shaders_hybrid_rendering`
//! (and, alone on screen, `shaders_raymarching_rendering`).
//!
//! The scene: three metaballs orbiting each other (polynomial
//! smooth-min union) over an analytically-intersected checkerboard
//! floor.  Shading is a tetrahedron-gradient normal, Lambert from a
//! fixed sun, a rim term on the blobs, and distance fade on the floor.
//!
//! The hybrid trick: on a hit, the world-space point is projected
//! through the SAME view-projection the raster pass uses and
//! `clip.z / clip.w` goes out through the FragDepth builtin - so
//! rasterized cubes and these marched blobs depth-test against each
//! other with zero coordination.  A miss writes the sky and depth 1.0
//! (behind everything real).
//!
//! Vertex stage: `deferred_shading_vs` (fullscreen quad), reused.
//! Schema in `hybrid_raymarch_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const float = zm.float;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("hybrid_raymarch_fs_io.zig");
const shader_externs = @import("hybrid_raymarch_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

const max_steps: u32 = 64;
const t_max: f32 = 24.0;
const sun: Vec3 = .{ 0.45, 0.75, 0.5 };

fn splat3(x: f32) Vec3 {
    return @splat(x);
}

fn vlen(v: Vec3) f32 {
    return @sqrt(@max(dot(v, v), 1.0e-12));
}

/// Polynomial smooth minimum (iq) - what makes metaballs meta.
fn smin(a: f32, b: f32, k: f32) f32 {
    const h: f32 = clamp01(0.5 + 0.5 * (b - a) / k);
    return b + (a - b) * h - k * h * (1.0 - h);
}

/// One ball's center at time t. Each ball drifts at its OWN angular speed (so
/// they don't stay rigidly 120 deg apart) on a radius that CHURNS between ~0 and
/// ~1 using two out-of-phase frequencies. When a ball's radius shrinks it dives
/// toward the center; because the phases are staggered per ball, they
/// periodically pile into the middle and MERGE (smooth-union) into one metaball,
/// then spread back out - organic, near-non-repeating clustering rather than a
/// rigid ring that never touches.
fn ballCenter(i: f32, t: f32) Vec3 {
    const a: f32 = i * 2.0943951 + t * (0.5 + i * 0.17);
    const r: f32 = 0.5 + 0.32 * @sin(t * 0.6 + i * 2.4) + 0.16 * @sin(t * 1.27 + i * 1.1);
    return .{
        r * @cos(a),
        1.15 + 0.3 * @sin(t * 0.83 + i * 1.9),
        r * @sin(a),
    };
}

/// The SDF: smooth union of the three balls.
fn mapScene(p: Vec3, t: f32) f32 {
    var d: f32 = 1.0e9;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const c: Vec3 = ballCenter(float(i), t);
        const bd: f32 = vlen(p - c) - 0.55;
        d = smin(d, bd, 0.45);
    }
    return d;
}

/// Tetrahedron-gradient normal - four taps, no branches.
fn sceneNormal(p: Vec3, t: f32) Vec3 {
    const e: f32 = 0.0015;
    const k0: Vec3 = .{ 1.0, -1.0, -1.0 };
    const k1: Vec3 = .{ -1.0, -1.0, 1.0 };
    const k2: Vec3 = .{ -1.0, 1.0, -1.0 };
    const k3: Vec3 = .{ 1.0, 1.0, 1.0 };
    const g: Vec3 = k0 * splat3(mapScene(p + k0 * splat3(e), t)) +
        k1 * splat3(mapScene(p + k1 * splat3(e), t)) +
        k2 * splat3(mapScene(p + k2 * splat3(e), t)) +
        k3 * splat3(mapScene(p + k3 * splat3(e), t));
    return normalize(g);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const t: f32 = io_in.u.params[1];
    const aspect: f32 = io_in.u.params[0];
    const tan_half: f32 = io_in.u.cam_fwd[3];

    // ---- the camera ray (uv origin is top-left; flip y into NDC) ----
    const ndc_x: f32 = io_in.frag_uv[0] * 2.0 - 1.0;
    const ndc_y: f32 = 1.0 - io_in.frag_uv[1] * 2.0;
    const right: Vec3 = .{ io_in.u.cam_right[0], io_in.u.cam_right[1], io_in.u.cam_right[2] };
    const up: Vec3 = .{ io_in.u.cam_up[0], io_in.u.cam_up[1], io_in.u.cam_up[2] };
    const fwd: Vec3 = .{ io_in.u.cam_fwd[0], io_in.u.cam_fwd[1], io_in.u.cam_fwd[2] };
    const ro: Vec3 = .{ io_in.u.view_pos[0], io_in.u.view_pos[1], io_in.u.view_pos[2] };
    const rd: Vec3 = normalize(fwd +
        right * splat3(ndc_x * tan_half * aspect) +
        up * splat3(ndc_y * tan_half));

    // ---- analytic floor (y = 0) bounds the march, raylib-style ----
    var t_far: f32 = t_max;
    var floor_t: f32 = -1.0;
    if (rd[1] < -1.0e-4) {
        floor_t = -ro[1] / rd[1];
        t_far = @min(t_far, floor_t);
    }

    // ---- sphere trace the blobs ----
    var hit_t: f32 = -1.0;
    var td: f32 = 0.05;
    var step: u32 = 0;
    while (step < max_steps) : (step += 1) {
        if (td > t_far) {
            break;
        }
        const d: f32 = mapScene(ro + rd * splat3(td), t);
        if (d < 0.001 * td + 0.0005) {
            hit_t = td;
            break;
        }
        td += d;
    }

    // ---- shade: blobs beat floor beats sky ----
    var color: Vec3 = undefined;
    var world_t: f32 = -1.0;
    if (hit_t > 0.0) {
        const p: Vec3 = ro + rd * splat3(hit_t);
        const n: Vec3 = sceneNormal(p, t);
        const l: Vec3 = normalize(sun);
        const lambert: f32 = @max(dot(n, l), 0.0);
        const rim: f32 = 1.0 - @max(dot(n, -rd), 0.0);
        const base: Vec3 = .{ 0.95, 0.42, 0.3 }; // molten orange
        color = base * splat3(0.22 + 0.78 * lambert) +
            Vec3{ 0.35, 0.5, 0.9 } * splat3(rim * rim * 0.5);
        world_t = hit_t;
    } else if (floor_t > 0.0 and floor_t < t_max) {
        const p: Vec3 = ro + rd * splat3(floor_t);
        // Checkerboard by parity of the floored cell coordinates.
        const cx: f32 = @floor(p[0]);
        const cz: f32 = @floor(p[2]);
        const sum: f32 = cx + cz;
        const parity: f32 = sum - 2.0 * @floor(sum * 0.5);
        const check: f32 = if (parity < 1.0) 0.72 else 0.38;
        // Distance fade into the sky color.
        const fade: f32 = clamp01(floor_t / t_max);
        const g: f32 = check * (1.0 - fade) + 0.62 * fade;
        color = .{ g, g, g * 1.04 };
        world_t = floor_t;
    } else {
        // Sky: a soft vertical gradient.
        const sky_up: f32 = clamp01(rd[1] * 0.5 + 0.5);
        color = Vec3{ 0.5, 0.6, 0.75 } * splat3(1.0 - sky_up * 0.35) +
            Vec3{ 0.1, 0.12, 0.2 } * splat3(sky_up);
    }

    // ---- the hybrid handshake: TRUE depth via the shared VP ----
    if (world_t > 0.0) {
        const p: Vec3 = ro + rd * splat3(world_t);
        const m: [4]Vec = io_in.u.vp;
        const hx: Vec = .{ p[0], p[1], p[2], 1.0 };
        const clip_z: f32 = m[0][2] * hx[0] + m[1][2] * hx[1] + m[2][2] * hx[2] + m[3][2];
        const clip_w: f32 = m[0][3] * hx[0] + m[1][3] * hx[1] + m[2][3] * hx[2] + m[3][3];
        out.frag_depth = clamp01(clip_z / @max(clip_w, 1.0e-6));
    } else {
        out.frag_depth = 1.0; // sky: behind everything real
    }

    out.final_color = .{ color[0], color[1], color[2], 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
