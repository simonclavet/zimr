//! src/shaders/deferred_shading_fs.zig - deferred lighting fragment
//! shader.
//!
//! The payoff of the whole G-buffer detour: light EVERY pixel exactly
//! once, no matter how many cubes overdrew it in pass 1.  Read the
//! surface facts back out of the three maps, then run Blinn-Phong for
//! four point lights with distance attenuation.
//!
//! Faithful to raylib's `deferred_shading.fs` - same ambient, same
//! shininess, same attenuation curve - with one deliberate fix: raylib
//! dots the normal against the UN-normalized light vector, so its
//! diffuse quietly scales with distance a second time before the
//! attenuation term even runs.  We normalize.  (Their brightness
//! constants still look fine because the bug and the tuning co-evolved;
//! ours are re-tuned for the honest math.)
//!
//! All four lights are evaluated with straight-line math and the
//! contribution multiplied by the enabled flag - no per-light
//! branching, which keeps the control flow uniform (Tint cares) and is
//! exactly what a GPU would have done with the branch anyway.
//!
//! Schema in `deferred_shading_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("deferred_shading_fs_io.zig");
const shader_externs = @import("deferred_shading_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

/// raylib's attenuation polynomial: 1/(1 + LINEAR*d + QUADRATIC*d^2).
const linear_falloff: f32 = 0.09;
const quadratic_falloff: f32 = 0.032;
/// Ambient floor so unlit geometry still reads as shape, not void.
const ambient_strength: f32 = 0.1;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // ---- Read the surface back out of the G-buffer ----
    const uv: Vec2 = io_in.frag_uv;
    const pos_texel: Vec = io_in.g_world_pos(uv);
    const nrm_texel: Vec = io_in.g_world_normal(uv);
    const mat_texel: Vec = io_in.g_albedo_spec(uv);

    const world_pos: Vec3 = .{ pos_texel[0], pos_texel[1], pos_texel[2] };
    // Stored normalized, but normalize again: the float targets are
    // 16-bit and debug-minded paranoia is cheap here (once per pixel).
    const normal: Vec3 = normalize(Vec3{ nrm_texel[0], nrm_texel[1], nrm_texel[2] });
    const albedo: Vec3 = .{ mat_texel[0], mat_texel[1], mat_texel[2] };
    const spec_strength: f32 = mat_texel[3];

    const view_dir: Vec3 = normalize(Vec3{
        io_in.u.view_pos[0] - world_pos[0],
        io_in.u.view_pos[1] - world_pos[1],
        io_in.u.view_pos[2] - world_pos[2],
    });

    // ---- Ambient floor, then accumulate the four point lights ----
    var lit: Vec3 = albedo * @as(Vec3, @splat(ambient_strength));

    inline for (0..shader_io.max_lights) |i| {
        const lp: Vec = io_in.u.light_pos[i];
        const lc: Vec = io_in.u.light_color[i];
        const enabled: f32 = lc[3]; // 0 = off, 1 = on - multiplied in, no branch

        const to_light: Vec3 = .{
            lp[0] - world_pos[0],
            lp[1] - world_pos[1],
            lp[2] - world_pos[2],
        };
        const dist: f32 = @sqrt(@max(dot(to_light, to_light), 1.0e-8));
        const light_dir: Vec3 = to_light * @as(Vec3, @splat(1.0 / dist));

        // Diffuse - with the NORMALIZED light direction (the raylib fix).
        const n_dot_l: f32 = @max(dot(normal, light_dir), 0.0);

        // Blinn-Phong specular: half-vector, gated by the material's
        // stored spec strength (g_albedo_spec.a).
        const half_dir: Vec3 = normalize(light_dir + view_dir);
        const n_dot_h: f32 = @max(dot(normal, half_dir), 0.0);
        const spec: f32 = pow32(n_dot_h) * spec_strength;

        // raylib's falloff, scaled by the light's .w (1 = stock reach).
        const reach: f32 = @max(lp[3], 1.0e-3);
        const d: f32 = dist / reach;
        const attenuation: f32 = 1.0 / (1.0 + linear_falloff * d + quadratic_falloff * d * d);

        const gain: f32 = enabled * attenuation * (n_dot_l + spec);
        lit += Vec3{ lc[0], lc[1], lc[2] } * albedo * @as(Vec3, @splat(gain));
    }

    out.final_color = .{ lit[0], lit[1], lit[2], 1.0 };
    return out;
}

/// x^32 as five squarings - `pow` with a runtime exponent is a
/// transcendental on some GPUs; the fixed raylib shininess of 32 is a
/// power of two, so multiply it out.
fn pow32(x: f32) f32 {
    const x2: f32 = x * x;
    const x4: f32 = x2 * x2;
    const x8: f32 = x4 * x4;
    const x16: f32 = x8 * x8;
    return x16 * x16;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
