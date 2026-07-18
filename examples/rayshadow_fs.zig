//! examples/rayshadow_fs.zig — a ray-traced HARD-SHADOW fragment shader.
//!
//! Per pixel: build the camera ray from the host-supplied basis, intersect a
//! bounded ground platform + two axis-aligned boxes, shade the nearest hit with
//! a fixed directional light, then cast a SHADOW RAY from the hit point toward
//! the light and darken to ambient if it strikes a box. Miss → gradient sky.
//!
//! The shadow is a second ray-scene intersection, NOT a shadow map — which is
//! exactly why the whole thing runs on all three zimr shader targets: WGSL
//! (GPU), native Zig (raster CPU dispatcher), and comptime (baked corner). A
//! shadow map would need a precomputed depth texture the CPU/comptime targets
//! can't produce. No recursion, no pointers-into-scene, no dynamic loops; the
//! scene is a fixed handful of primitives tested through small helper fns.
const zm = @import("zm");
const Vec = zm.Vec;
const safeNormalize3 = zm.safeNormalize3;
const splat = zm.splat;
const vec = zm.vec;
const vec4 = zm.vec4;
const shader_io = @import("rayshadow_fs_io.zig");
const shader_externs = @import("rayshadow_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

const miss_t: f32 = 1.0e30;

/// Slab ray-box against [bmin, bmax]. Returns the entry distance when the ray
/// enters the box ahead of the origin, else `miss_t`. Per-axis @min/@max avoids
/// a swap branch; axis-aligned rays give inf via 1/0 and stay correct.
fn hitBox(ro: Vec, rd: Vec, bmin: Vec, bmax: Vec) f32 {
    const ix: f32 = 1.0 / rd[0];
    const x0: f32 = (bmin[0] - ro[0]) * ix;
    const x1: f32 = (bmax[0] - ro[0]) * ix;
    const iy: f32 = 1.0 / rd[1];
    const y0: f32 = (bmin[1] - ro[1]) * iy;
    const y1: f32 = (bmax[1] - ro[1]) * iy;
    const iz: f32 = 1.0 / rd[2];
    const z0: f32 = (bmin[2] - ro[2]) * iz;
    const z1: f32 = (bmax[2] - ro[2]) * iz;
    const tmin: f32 = @max(@max(@min(x0, x1), @min(y0, y1)), @min(z0, z1));
    const tmax: f32 = @min(@min(@max(x0, x1), @max(y0, y1)), @max(z0, z1));
    if (tmax >= tmin and tmin > 0.0) {
        return tmin;
    }
    return miss_t;
}

/// Bounded ground platform at y=0 (an 8×8 square so sky shows around it).
fn hitPlatform(ro: Vec, rd: Vec) f32 {
    if (rd[1] > -1.0e-6) {
        return miss_t;
    }
    const t: f32 = -ro[1] / rd[1];
    if (t <= 0.0) {
        return miss_t;
    }
    const hx: f32 = ro[0] + rd[0] * t;
    const hz: f32 = ro[2] + rd[2] * t;
    if (hx < -4.0 or hx > 4.0 or hz < -4.0 or hz > 4.0) {
        return miss_t;
    }
    return t;
}

/// Outward normal of an axis-aligned box at surface point `p`: the axis whose
/// normalized offset from the center is largest is the hit face.
fn boxNormal(p: Vec, center: Vec, half: Vec) Vec {
    const dx: f32 = (p[0] - center[0]) / half[0];
    const dy: f32 = (p[1] - center[1]) / half[1];
    const dz: f32 = (p[2] - center[2]) / half[2];
    const ax: f32 = @abs(dx);
    const ay: f32 = @abs(dy);
    const az: f32 = @abs(dz);
    if (ax >= ay and ax >= az) {
        return vec(if (dx > 0.0) 1.0 else -1.0, 0.0, 0.0);
    }
    if (ay >= az) {
        return vec(0.0, if (dy > 0.0) 1.0 else -1.0, 0.0);
    }
    return vec(0.0, 0.0, if (dz > 0.0) 1.0 else -1.0);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const px: f32 = io_in.frag_tex_coord[0] * io_in.u.resolution[0];
    const py: f32 = io_in.frag_tex_coord[1] * io_in.u.resolution[1];
    const ro: Vec = io_in.u.cam_origin;
    const pixel_center: Vec = io_in.u.px00 +
        io_in.u.pdu * splat(px) +
        io_in.u.pdv * splat(py);
    const rd: Vec = safeNormalize3(pixel_center - ro, vec(0, 0, -1));

    // Scene: two boxes on the platform. Center + half-extent; box A taller/warm,
    // box B shorter/cool. Both rest on y=0.
    const a_center: Vec = vec(-1.05, 0.78, 0.10);
    const a_half: Vec = vec(0.72, 0.78, 0.72);
    const b_center: Vec = vec(1.05, 0.5, 0.25);
    const b_half: Vec = vec(0.66, 0.5, 0.62);
    const a_min: Vec = a_center - a_half;
    const a_max: Vec = a_center + a_half;
    const b_min: Vec = b_center - b_half;
    const b_max: Vec = b_center + b_half;

    // Fixed world light (direction TO the light).
    const light: Vec = safeNormalize3(vec(0.5, 0.9, 0.42), vec(0, 1, 0));

    // ---- Primary ray: nearest of platform / box A / box B ----
    const t_plat: f32 = hitPlatform(ro, rd);
    const t_a: f32 = hitBox(ro, rd, a_min, a_max);
    const t_b: f32 = hitBox(ro, rd, b_min, b_max);

    var best_t: f32 = miss_t;
    var kind: u32 = 0; // 0 miss, 1 platform, 2 box A, 3 box B
    if (t_plat < best_t) {
        best_t = t_plat;
        kind = 1;
    }
    if (t_a < best_t) {
        best_t = t_a;
        kind = 2;
    }
    if (t_b < best_t) {
        best_t = t_b;
        kind = 3;
    }

    var color: Vec = vec(0, 0, 0);
    if (kind == 0) {
        // Gradient sky (warm horizon → deep-blue zenith).
        const s: f32 = 0.5 * (rd[1] + 1.0);
        const bot: Vec = vec(0.85, 0.52, 0.32);
        const top: Vec = vec(0.12, 0.20, 0.48);
        color = bot * splat(1.0 - s) + top * splat(s);
    } else {
        const hit: Vec = ro + rd * splat(best_t);

        var normal: Vec = vec(0, 1, 0);
        var albedo: Vec = vec(0.72, 0.73, 0.78);
        if (kind == 2) {
            normal = boxNormal(hit, a_center, a_half);
            albedo = vec(0.86, 0.46, 0.40);
        } else if (kind == 3) {
            normal = boxNormal(hit, b_center, b_half);
            albedo = vec(0.44, 0.60, 0.86);
        }

        const ndl: f32 = @max(0.0, normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2]);

        // Shadow ray from just above the surface toward the light; either box
        // occludes. (The platform can't shadow — the light is above it.)
        const origin: Vec = hit + normal * splat(0.004);
        const sa: f32 = hitBox(origin, light, a_min, a_max);
        const sb: f32 = hitBox(origin, light, b_min, b_max);
        const shadow: f32 = if (sa < miss_t or sb < miss_t) 0.0 else 1.0;

        const ambient: f32 = 0.22;
        const lit: f32 = ambient + (1.0 - ambient) * ndl * shadow;
        color = albedo * splat(lit);
    }

    out.out_color = vec4(color[0], color[1], color[2], 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
