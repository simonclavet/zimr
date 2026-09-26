//! examples/rt_fs.zig — a ray-tracing FRAGMENT SHADER.
//!
//! One `shaderMain(io) Out` that path-traces the Ubo's sphere scene for the
//! pixel at `frag_tex_coord`. Compiles three ways (the zimr shader contract):
//! to WGSL (GPU), to native Zig (raster software dispatcher), and to SPIR-V — so
//! the SAME shader can drive both halves of a CPU|GPU side-by-side demo.
//!
//! Constraints that shape the code (SPIR-V / WGSL safe):
//!   - NO recursion → the bounce trace is an explicit bounded loop with an
//!     accumulated attenuation + a running ray.
//!   - NO dynamic allocation, no pointers into the scene → spheres come from
//!     the Ubo's fixed array; the hit search is a bounded loop.
//!   - A cheap per-pixel PRNG (PCG-ish hash) seeded from pixel coord +
//!     u.frame_seed gives the diffuse scatter / metal fuzz / dielectric jitter.

const zm = @import("zm");
const Vec = zm.Vec;
const dot3 = zm.dot3;
const float = zm.float;
const int = zm.int;
const lengthSq3 = zm.lengthSq3;
const pi = zm.pi;
const pow = zm.pow;
const reflect3 = zm.reflect3;
const safeNormalize3 = zm.safeNormalize3;
const splat = zm.splat;
const vec = zm.vec;
const vec4 = zm.vec4;
const shader_io = @import("rt_fs_io.zig");
const shader_externs = @import("rt_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

const max_bounces: u32 = 8;
const max_spheres: u32 = shader_io.max_spheres;

// ---- tiny PRNG: pure functions threading a u32 state by VALUE ---------------
// No `*Rng` methods / pointer params: the SPIR-V->WGSL translator can't lower
// calls that pass a pointer to a by-value param (out-params are lost). So the
// RNG is functional — each call takes the state and returns the next state;
// `randF` also returns a float. Keeps the shader translatable AND identical on
// the CPU dispatcher.
fn hashU32(x_in: u32) u32 {
    var x: u32 = x_in;
    x ^= x >> 16;
    x = x *% 0x7feb352d;
    x ^= x >> 15;
    x = x *% 0x846ca68b;
    x ^= x >> 16;
    return x;
}

/// Advance the state; the new state is also the raw random bits.
fn rngNext(state: u32) u32 {
    return hashU32(state);
}

/// A float in [0,1) from a state word (top 24 bits).
fn stateToF(state: u32) f32 {
    return float(state >> 8) * (1.0 / 16777216.0);
}

/// A random unit vector from a state word that has ALREADY been advanced twice
/// by the caller (s0, s1). No struct return (the translator names struct temps
/// `result`, which collide when inlined); the caller threads the two states.
fn unitVecFrom(s0: u32, s1: u32) Vec {
    const z_: f32 = stateToF(s0) * 2.0 - 1.0;
    const a: f32 = stateToF(s1) * 2.0 * pi;
    const r: f32 = @sqrt(@max(0.0, 1.0 - z_ * z_));
    return vec(r * @cos(a), r * @sin(a), z_);
}

// ---- ray/sphere intersection ------------------------------------------------
// Returns t of the nearest hit in (t_min, t_max), or -1 if none.
fn hitSphere(
    center: Vec,
    radius: f32,
    ro: Vec,
    rd: Vec,
    t_min: f32,
    t_max: f32,
) f32 {
    const oc: Vec = center - ro;
    const a: f32 = dot3(rd, rd);
    const h: f32 = dot3(oc, rd);
    const c: f32 = dot3(oc, oc) - radius * radius;
    const disc: f32 = h * h - a * c;
    if (disc < 0.0) {
        return -1.0;
    }
    const sq: f32 = @sqrt(disc);
    var root: f32 = (h - sq) / a;
    if (root <= t_min or root >= t_max) {
        root = (h + sq) / a;
        if (root <= t_min or root >= t_max) {
            return -1.0;
        }
    }
    return root;
}

fn skyColor(rd: Vec) Vec {
    const unit: Vec = safeNormalize3(rd, vec(0, 1, 0));
    const t: f32 = 0.5 * (unit[1] + 1.0);
    const white: Vec = vec(1.0, 1.0, 1.0);
    const blue: Vec = vec(0.5, 0.7, 1.0);
    return white * splat(1.0 - t) + blue * splat(t);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Pixel coordinate (integer-ish) for the RNG seed.
    const px: f32 = io_in.frag_tex_coord[0] * io_in.u.resolution[0];
    const py: f32 = io_in.frag_tex_coord[1] * io_in.u.resolution[1];
    const seed: u32 = (int(u32, px) *% 1973) ^
        (int(u32, py) *% 9277) ^
        (int(u32, io_in.u.frame_seed) *% 26699);
    var rng_state: u32 = hashU32(seed | 1);

    // Primary ray through this pixel (+ a sub-pixel jitter for AA over frames).
    rng_state = rngNext(rng_state);
    const jx: f32 = stateToF(rng_state) - 0.5;
    rng_state = rngNext(rng_state);
    const jy: f32 = stateToF(rng_state) - 0.5;
    const ro0: Vec = io_in.u.cam_origin;
    const pixel_center: Vec = io_in.u.px00 +
        io_in.u.pdu * splat(px + jx) +
        io_in.u.pdv * splat(py + jy);
    var ro: Vec = ro0;
    var rd: Vec = safeNormalize3(pixel_center - ro0, vec(0, 0, -1));

    var attenuation: Vec = vec(1.0, 1.0, 1.0);
    var color: Vec = vec(0.0, 0.0, 0.0);

    const count: u32 = @trunc(io_in.u.sphere_count);

    var bounce: u32 = 0;
    while (bounce < max_bounces) : (bounce += 1) {
        // Find nearest sphere hit.
        var best_t: f32 = 1.0e30;
        const NO_HIT: u32 = 0xffffffff;
        var hit_i: u32 = NO_HIT;
        var i: u32 = 0;
        while (i < max_spheres) : (i += 1) {
            if (i >= count) {
                break;
            }
            const geom: Vec = io_in.u.sphere_geom[i];
            const radius: f32 = geom[3];
            if (radius <= 0.0) {
                continue;
            }
            const center: Vec = vec(geom[0], geom[1], geom[2]);
            const t: f32 = hitSphere(center, radius, ro, rd, 0.001, best_t);
            if (t > 0.0) {
                best_t = t;
                hit_i = i;
            }
        }

        if (hit_i == NO_HIT) {
            // Miss → sky, modulated by attenuation so far.
            color = color + attenuation * skyColor(rd);
            break;
        }

        const hi: u32 = hit_i;
        const geom: Vec = io_in.u.sphere_geom[hi];
        const center: Vec = vec(geom[0], geom[1], geom[2]);
        const radius: f32 = geom[3];
        const point: Vec = ro + rd * splat(best_t);
        var normal: Vec = (point - center) * splat(1.0 / radius);
        const front_face: bool = dot3(rd, normal) < 0.0;
        if (!front_face) {
            normal = -normal;
        }
        const am: Vec = io_in.u.sphere_albedo[hi];
        const albedo: Vec = vec(am[0], am[1], am[2]);
        const mat: f32 = am[3];
        const param: f32 = io_in.u.sphere_extra[hi][0];

        if (mat < 0.5) {
            // Lambertian: scatter around the normal.
            const s0: u32 = rngNext(rng_state);
            const s1: u32 = rngNext(s0);
            rng_state = s1;
            var dir: Vec = normal + unitVecFrom(s0, s1);
            if (lengthSq3(dir) < 1.0e-6) {
                dir = normal;
            }
            ro = point;
            rd = safeNormalize3(dir, normal);
            attenuation = attenuation * albedo;
        } else if (mat < 1.5) {
            // Metal: reflect with fuzz.
            const refl: Vec = reflect3(safeNormalize3(rd, normal), normal);
            const m0: u32 = rngNext(rng_state);
            const m1: u32 = rngNext(m0);
            rng_state = m1;
            const fuzzed: Vec = refl + unitVecFrom(m0, m1) * splat(param);
            ro = point;
            rd = safeNormalize3(fuzzed, normal);
            attenuation = attenuation * albedo;
            if (dot3(rd, normal) <= 0.0) {
                // Absorbed (scattered below surface).
                break;
            }
        } else {
            // Dielectric: refract or reflect (Schlick).
            const ior: f32 = param;
            const ratio: f32 = if (front_face) (1.0 / ior) else ior;
            const unit_dir: Vec = safeNormalize3(rd, normal);
            const cos_theta: f32 = @min(dot3(-unit_dir, normal), 1.0);
            const sin_theta: f32 = @sqrt(@max(0.0, 1.0 - cos_theta * cos_theta));
            // Schlick reflectance.
            var r0: f32 = (1.0 - ratio) / (1.0 + ratio);
            r0 = r0 * r0;
            const reflectance: f32 = r0 + (1.0 - r0) * pow(1.0 - cos_theta, 5.0);
            var new_dir: Vec = undefined;
            rng_state = rngNext(rng_state);
            if (ratio * sin_theta > 1.0 or reflectance > stateToF(rng_state)) {
                new_dir = reflect3(unit_dir, normal);
            } else {
                // Refract (Snell).
                const perp: Vec = (unit_dir + normal * splat(cos_theta)) * splat(ratio);
                const parallel: Vec = normal * splat(-@sqrt(@max(0.0, 1.0 - lengthSq3(perp))));
                new_dir = perp + parallel;
            }
            ro = point;
            rd = safeNormalize3(new_dir, normal);
            // glass doesn't tint (attenuation unchanged)
        }
    }

    // Gamma (sqrt) + clamp to [0,1]. Inline the clamp as min(max(..)) rather
    // than zm.clamp: clamp's inlined `result` temp collides across the 3 calls
    // in the WGSL emitter (a translator name-uniquing gap; tracked separately).
    const cr: f32 = @min(@max(@sqrt(@max(0.0, color[0])), 0.0), 1.0);
    const cg: f32 = @min(@max(@sqrt(@max(0.0, color[1])), 0.0), 1.0);
    const cb: f32 = @min(@max(@sqrt(@max(0.0, color[2])), 0.0), 1.0);
    out.out_color = vec4(cr, cg, cb, 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
