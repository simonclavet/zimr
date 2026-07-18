//! examples/raycube_fs.zig — a ray-traced-cube FRAGMENT SHADER.
//!
//! Per pixel: build the camera ray from the host-supplied basis, rotate it INTO
//! the cube's local frame (the cube spins by `u.time` about Y), slab-method
//! ray-box intersect the unit cube [-1,1]^3, and shade the hit by its face axis
//! (red/green/blue) with a fixed-light lambert term — or a vertical gradient sky
//! on a miss. Compiles three ways (the zimr shader contract): WGSL (GPU), native
//! Zig (raster CPU dispatcher), and SPIR-V — and is cheap enough to also run at
//! comptime (no loops, just three unrolled slabs).
//!
//! SPIR-V / WGSL safe: no recursion, no pointers-into-scene, no dynamic loops;
//! the dot product is spelled out (no API surprises across targets).
const zm = @import("zm");
const Vec = zm.Vec;
const safeNormalize3 = zm.safeNormalize3;
const splat = zm.splat;
const vec = zm.vec;
const vec4 = zm.vec4;
const shader_io = @import("raycube_fs_io.zig");
const shader_externs = @import("raycube_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const px: f32 = io_in.frag_tex_coord[0] * io_in.u.resolution[0];
    const py: f32 = io_in.frag_tex_coord[1] * io_in.u.resolution[1];

    // Primary ray through this pixel, from the host-built (orbiting) camera
    // basis. The cube is a fixed axis-aligned box and the CAMERA orbits, so no
    // per-fragment rotation is needed — we ray-box directly in world space.
    const ro: Vec = io_in.u.cam_origin;
    const pixel_center: Vec = io_in.u.px00 +
        io_in.u.pdu * splat(px) +
        io_in.u.pdv * splat(py);
    const rd: Vec = safeNormalize3(pixel_center - ro, vec(0, 0, -1));

    // Slab ray-box against the unit cube [-1, 1]^3. Track the entry axis for the
    // surface normal. Axis-aligned rays give inf via 1/0 — the min/max ordering
    // and comparisons stay correct (standard robust-slab behaviour).
    var tmin: f32 = -1.0e30;
    var tmax: f32 = 1.0e30;
    var hit_axis: u32 = 0;

    // Three slabs. The SPIR-V→WGSL lowering flattens Zig block scopes without
    // renaming, so each axis uses DISTINCT locals (shared names would become a
    // WGSL redeclaration). @min/@max avoid a swap branch.
    const invx: f32 = 1.0 / rd[0];
    const ax0: f32 = (-1.0 - ro[0]) * invx;
    const ax1: f32 = (1.0 - ro[0]) * invx;
    const nx: f32 = @min(ax0, ax1);
    const fx: f32 = @max(ax0, ax1);
    if (nx > tmin) {
        tmin = nx;
        hit_axis = 0;
    }
    if (fx < tmax) {
        tmax = fx;
    }

    const invy: f32 = 1.0 / rd[1];
    const ay0: f32 = (-1.0 - ro[1]) * invy;
    const ay1: f32 = (1.0 - ro[1]) * invy;
    const ny: f32 = @min(ay0, ay1);
    const fy: f32 = @max(ay0, ay1);
    if (ny > tmin) {
        tmin = ny;
        hit_axis = 1;
    }
    if (fy < tmax) {
        tmax = fy;
    }

    const invz: f32 = 1.0 / rd[2];
    const az0: f32 = (-1.0 - ro[2]) * invz;
    const az1: f32 = (1.0 - ro[2]) * invz;
    const nz: f32 = @min(az0, az1);
    const fz: f32 = @max(az0, az1);
    if (nz > tmin) {
        tmin = nz;
        hit_axis = 2;
    }
    if (fz < tmax) {
        tmax = fz;
    }

    var color: Vec = vec(0, 0, 0);
    if (tmax >= tmin and tmin > 0.0) {
        // Local surface normal: along the entry axis, pointing against the ray.
        var n: Vec = vec(0, 0, 0);
        if (hit_axis == 0) {
            const sgn: f32 = if (rd[0] > 0.0) -1.0 else 1.0;
            n = vec(sgn, 0, 0);
        } else if (hit_axis == 1) {
            const sgn: f32 = if (rd[1] > 0.0) -1.0 else 1.0;
            n = vec(0, sgn, 0);
        } else {
            const sgn: f32 = if (rd[2] > 0.0) -1.0 else 1.0;
            n = vec(0, 0, sgn);
        }

        // Face tint by axis: X red, Y green, Z blue.
        var face: Vec = vec(0.90, 0.30, 0.30);
        if (hit_axis == 1) {
            face = vec(0.32, 0.85, 0.40);
        }
        if (hit_axis == 2) {
            face = vec(0.34, 0.52, 0.95);
        }

        // The cube is axis-aligned in world, so the slab normal IS the world
        // normal. Lambert from a fixed (pre-normalised) world light.
        const nw: Vec = n;
        const lx: f32 = 0.488;
        const ly: f32 = 0.781;
        const lz: f32 = 0.390;
        const ndl: f32 = @max(0.0, nw[0] * lx + nw[1] * ly + nw[2] * lz);
        const lit: f32 = 0.25 + 0.75 * ndl;
        color = face * splat(lit);
    } else {
        // Gradient sky on a miss (warm horizon → deep-blue zenith).
        const t: f32 = 0.5 * (rd[1] + 1.0);
        const bot: Vec = vec(0.85, 0.52, 0.32);
        const top: Vec = vec(0.12, 0.20, 0.48);
        color = bot * splat(1.0 - t) + top * splat(t);
    }

    out.out_color = vec4(color[0], color[1], color[2], 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
