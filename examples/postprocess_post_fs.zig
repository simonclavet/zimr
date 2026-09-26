//! examples/postprocess_post_fs.zig - fullscreen post-processing fragment
//! shader for the postprocess demo. Samples the `scene` texture three times at
//! UV offsets along the radial direction (a chromatic-aberration RGB split),
//! then darkens toward the edges (vignette).
//!
//! This is the FIRST sampler shader to go through `z.shader.loadShaderVF`: the
//! schema's `Samplers` field drives a bind group built by the unified
//! `Resources` machinery, with no hand-built pipeline. Same authoring shape as
//! every other Zig shader - `io.scene(uv)` is the texture read.
//!
//! Schema (Inputs / Samplers / Outputs) lives in `postprocess_post_fs_io.zig`.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const shader_io = @import("postprocess_post_fs_io.zig");
const shader_externs = @import("postprocess_post_fs_externs");

// IoT(void) - no Ubo; the texture binding is all this stage needs.
pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

const smoothstep = zm.smoothstep;
const length = zm.length;

comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const uv: Vec2 = io_in.frag_tex_coord;
    const center: Vec2 = .{ 0.5, 0.5 };
    const dir: Vec2 = uv - center;

    // Chromatic aberration: pull R outward and B inward along `dir`.
    const off: Vec2 = dir * @as(Vec2, @splat(0.008));
    const r: f32 = io_in.scene(uv + off)[0];
    const g: f32 = io_in.scene(uv)[1];
    const b: f32 = io_in.scene(uv - off)[2];

    // Vignette: fade toward the edges (edge0 > edge1 -> bright center).
    const vig: f32 = smoothstep(0.85, 0.30, length(dir));

    out.final_color = .{ r * vig, g * vig, b * vig, 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
