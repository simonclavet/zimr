//! src/shaders/effect_outline_fs.zig - alpha-silhouette outline,
//! raylib's `outline.fs` ported (their `shaders_texture_outline`).
//!
//! The 2D cousin of the inverted hull: sample the ALPHA channel at the
//! four diagonal neighbors `outline_size` pixels away; if any neighbor
//! is opaque, this transparent-ish texel is on the silhouette and gets
//! painted the outline color.  Opaque texels keep their own color (the
//! final mix by texel alpha), so the ink only shows in the halo the
//! sprite doesn't cover.  Needs a source with a real alpha channel -
//! the gallery draws its scene on a TRANSPARENT clear for exactly this.
//!
//! All four samples are unconditional (uniform control flow - Tint).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader_io = @import("effect_outline_fs_io.zig");
const shader_externs = @import("effect_outline_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const texel: Vec = io_in.texture0(io_in.frag_uv);
    const sx: f32 = io_in.u.params[0] / @max(io_in.u.params[1], 1.0);
    const sy: f32 = io_in.u.params[0] / @max(io_in.u.params[2], 1.0);
    const uv: Vec2 = io_in.frag_uv;

    // Four diagonal alpha taps (raylib samples exactly these corners).
    const a0: f32 = io_in.texture0(.{ uv[0] + sx, uv[1] + sy })[3];
    const a1: f32 = io_in.texture0(.{ uv[0] + sx, uv[1] - sy })[3];
    const a2: f32 = io_in.texture0(.{ uv[0] - sx, uv[1] + sy })[3];
    const a3: f32 = io_in.texture0(.{ uv[0] - sx, uv[1] - sy })[3];
    const outline: f32 = @min(a0 + a1 + a2 + a3, 1.0);

    // ink where neighbors are opaque, then the texel wins by its own
    // alpha - raylib's double mix, unrolled per channel.
    var color: Vec = .{
        io_in.u.outline_color[0] * outline,
        io_in.u.outline_color[1] * outline,
        io_in.u.outline_color[2] * outline,
        io_in.u.outline_color[3] * outline,
    };
    const a: f32 = texel[3];
    color[0] = color[0] + (texel[0] - color[0]) * a;
    color[1] = color[1] + (texel[1] - color[1]) * a;
    color[2] = color[2] + (texel[2] - color[2]) * a;
    color[3] = color[3] + (texel[3] - color[3]) * a;

    out.final_color = color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
