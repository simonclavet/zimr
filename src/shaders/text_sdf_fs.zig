//! src/shaders/text_sdf_fs.zig - the SDF text fragment shader (raylib's sdf.fs).
//!
//! Runs over the ordinary 2D batch, so `gl.text(sdf_font, ...)` between
//! `beginShaderMode(this)` and `endShaderMode` renders each glyph quad through
//! here. `texture0` is an SDF atlas (signed distance in alpha, 0.5 = the glyph
//! edge; see `image.coverageToSdf`). Instead of using the sampled value AS the
//! coverage - which blurs when the glyph is magnified past the atlas
//! resolution - it thresholds the distance with a `smoothstep` around 0.5, so
//! the edge stays a crisp ~1px transition at ANY on-screen size. That is the
//! entire reason SDF text exists.
//!
//! raylib's `resources/shaders/glsl330/sdf.fs` hard-codes `smoothing = 1/16`;
//! here it is `params[0]` so the example can show the edge sharpen/soften live.
const zm = @import("zm");
const Vec = zm.Vec;
const clamp01 = zm.clamp01;
const shader_externs = @import("text_sdf_fs_externs");

pub const Io = shader_externs.IoT(@import("text_sdf_fs_io.zig").Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    // The signed distance lives in the atlas alpha channel; RGB is white.
    const dist: f32 = io_in.texture0(io_in.frag_tex_coord)[3];
    const tint: Vec = io_in.frag_color;
    // Smoothing half-width (SDF units). Clamp away from 0 so the divide inside
    // the smoothstep can't produce NaN when the caller leaves params[0] unset.
    const smoothing: f32 = @max(io_in.u.params[0], 0.001);
    const e0: f32 = 0.5 - smoothing;
    const e1: f32 = 0.5 + smoothing;
    const t: f32 = clamp01((dist - e0) / (e1 - e0));
    const alpha: f32 = t * t * (3.0 - 2.0 * t);
    out.out_color = .{ tint[0], tint[1], tint[2], tint[3] * alpha };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
