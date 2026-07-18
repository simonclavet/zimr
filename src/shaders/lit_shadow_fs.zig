//! src/shaders/lit_shadow_fs.zig — shadow-mapped Lambert fragment shader.
//!
//! Lambertian diffuse + ambient with a single directional light, gated
//! by a hard shadow test against the light-view depth map. The depth map
//! stores `ndc_z*0.5+0.5` (depth pass `mode = 0`), so this FS remaps the
//! fragment's light-space z the same way and compares. Slope-scaled bias
//! suppresses acne; a constant floor catches flat surfaces. Fragments
//! outside the light frustum are treated as lit (no hard cutoff edge).
//!
//! The shadow map is sampled ONCE at the top (uniform control flow — Tint
//! requires texture samples outside non-uniform branches), then the
//! branch only compares scalars.
//!
//! Schema in `lit_shadow_fs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("lit_shadow_fs_io.zig");
const shader_externs = @import("lit_shadow_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

/// Perspective-divide the light-space position and remap NDC xy/z from
/// [-1,1] to [0,1] — matching the depth map's stored `ndc_z*0.5+0.5`.
fn shadowProjCoords(io_in: Io) Vec3 {
    const inv_w: f32 = 1.0 / io_in.frag_light_space_pos[3];
    var proj: Vec3 = .{
        io_in.frag_light_space_pos[0] * inv_w,
        io_in.frag_light_space_pos[1] * inv_w,
        io_in.frag_light_space_pos[2] * inv_w,
    };
    proj = proj * @as(Vec3, @splat(0.5)) + @as(Vec3, @splat(0.5));
    // WebGPU render-texture origin is top-left, but NDC +y is up, so the
    // shadow map is stored y-flipped relative to the projected coordinate.
    // Flip v for the texel lookup (z stays — it's the depth we compare).
    proj[1] = 1.0 - proj[1];
    return proj;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const nrm: Vec3 = normalize(io_in.frag_normal);
    const n_dot_l: f32 = @max(dot(nrm, light_dir), 0.0);

    // Sample the depth map ONCE, unconditionally (uniform control flow).
    const proj: Vec3 = shadowProjCoords(io_in);
    const closest: f32 = io_in.shadow_map(.{ proj[0], proj[1] })[0];
    const current: f32 = proj[2];
    // Slope-scaled bias from the UNIFORMS (`params` = {slope, floor}): the
    // right bias depends on the depth map's precision, which differs per
    // backend (GPU rgba16_float vs CPU/comptime rgba8), so it's per-draw
    // DATA rather than a baked constant — the same shader body serves all
    // three backends and each supplies the slack its own map deserves.
    const bias: f32 = @max(io_in.u.params[0] * (1.0 - n_dot_l), io_in.u.params[1]);

    // Scalar-only branch: outside the frustum = lit; else depth compare.
    var shadow: f32 = 1.0;
    if (proj[0] < 0.0 or proj[0] > 1.0 or
        proj[1] < 0.0 or proj[1] > 1.0 or
        proj[2] > 1.0)
    {
        shadow = 1.0;
    } else if ((current - bias) > closest) {
        shadow = 0.0;
    }

    // Shadow gates the diffuse term only; ambient always contributes so
    // shadowed regions read as dim, not black.
    const ambient: f32 = 0.25;
    const lighting: f32 = ambient + (1.0 - ambient) * n_dot_l * shadow;

    out.final_color = .{
        io_in.u.base_color[0] * lighting,
        io_in.u.base_color[1] * lighting,
        io_in.u.base_color[2] * lighting,
        1.0,
    };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
