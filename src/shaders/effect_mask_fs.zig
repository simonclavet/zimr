//! src/shaders/effect_mask_fs.zig - blend two sources, by a mask or by a divider.
//!
//! Ports the *shading* half of raylib's `shaders_simple_mask` and
//! `shaders_multi_sample2d` in one shader, because they are the same shader:
//! sample two textures, produce a blend factor, mix. The only difference is where
//! the blend factor comes from -
//!
//!   MASK    - a third texture's luminance (raylib's simple_mask, which keys on a
//!             mask image; here it is any texture, so a live one works too).
//!   DIVIDER - a position along x (raylib's multi_sample2d, which wipes between two
//!             textures at a draggable split).
//!
//! Both branches sample BOTH sources unconditionally. That is deliberate: a
//! fragment shader that samples inside a branch has non-uniform control flow, which
//! is exactly the class of bug that produced Chrome/Tint's uniformity errors on
//! this project before. Sampling both and mixing is branch-free where it matters
//! and costs one extra fetch.

const zm = @import("zm");
const Vec = zm.Vec;
const clamp01 = zm.clamp01;
const smoothstep = zm.smoothstep;
const vec4 = zm.vec4;
const shader_io = @import("effect_mask_fs_io.zig");
const shader_externs = @import("effect_mask_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const uv = io_in.frag_uv;

    // Sample everything up front - see the note above on uniform control flow.
    const a: Vec = io_in.tex_a(uv);
    const b: Vec = io_in.tex_b(uv);
    const m: Vec = io_in.tex_mask(uv);

    const mode: f32 = io_in.u.params[0];
    const divider: f32 = io_in.u.params[1];
    const softness: f32 = io_in.u.params[2];

    // MASK: the mask's luminance is the blend factor.
    const mask_t: f32 = clamp01(0.299 * m[0] + 0.587 * m[1] + 0.114 * m[2]);

    // DIVIDER: a wipe along x. `softness` = 0 gives raylib's hard cut; feathering
    // it is strictly nicer and costs nothing.
    const half: f32 = @max(softness, 0.0005); // never a zero-width smoothstep
    const div_t: f32 = smoothstep(divider - half, divider + half, uv[0]);

    // Select without branching on a sampled value.
    const t: f32 = if (mode < 0.5) mask_t else div_t;

    out.final_color = vec4(
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        1.0,
    );
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
