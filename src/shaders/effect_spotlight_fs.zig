//! src/shaders/effect_spotlight_fs.zig - spotlight darkness mask,
//! raylib's `spotlight.fs` ported (their
//! `shaders_spotlight_rendering`).
//!
//! raylib renders the scene, then draws a fullscreen BLACK quad whose
//! alpha is 1 outside every spotlight, 0 inside a spot's inner circle,
//! and a linear ramp between.  A gallery effect samples the source
//! instead of overlaying it, so the same math becomes a direct filter:
//! `texel * mix(dark_level, 1, visibility)` - one pass, identical
//! picture.
//!
//! The nearest-spot search keeps raylib's wrinkle: the distance being
//! minimized is `dist(pos, spot_j) - radius_j + radius_i`, i.e. spots
//! are compared by how far the fragment is from each spot's EDGE, so a
//! big and a small spotlight blend correctly where they overlap.  The
//! loops are over a fixed uniform-sized array - uniform control flow,
//! Tint-friendly.

const zm = @import("zm");
const Vec = zm.Vec;
const clamp01 = zm.clamp01;
const shader_io = @import("effect_spotlight_fs_io.zig");
const shader_externs = @import("effect_spotlight_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

const max_spots = shader_io.max_spots;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const texel: Vec = io_in.texture0(io_in.frag_uv);
    const pos_x: f32 = io_in.frag_uv[0] * io_in.u.params[1];
    const pos_y: f32 = io_in.frag_uv[1] * io_in.u.params[2];

    // Nearest spot, radii-compensated (raylib's double loop, verbatim
    // in spirit: minimize edge distance normalized into spot i's frame).
    var best_d: f32 = 65000.0;
    var best_inner: f32 = 0.0;
    var best_radius: f32 = 1.0;
    inline for (0..max_spots) |i| {
        inline for (0..max_spots) |j| {
            const sj: Vec = io_in.u.spots[j];
            const si: Vec = io_in.u.spots[i];
            const dx: f32 = pos_x - sj[0];
            const dy: f32 = pos_y - sj[1];
            const dj: f32 = @sqrt(dx * dx + dy * dy) - sj[3] + si[3];
            if (dj < best_d) {
                best_d = dj;
                best_inner = si[2];
                best_radius = si[3];
            }
        }
    }

    // Visibility: 1 inside the inner circle, 0 past the radius, a
    // linear ramp between (raylib computes the mask's alpha; visibility
    // is its complement).
    const span: f32 = @max(best_radius - best_inner, 1.0);
    const ramp: f32 = (best_d - best_inner) / span;
    const mask: f32 = clamp01(ramp);
    const dark: f32 = io_in.u.params[0];
    const light: f32 = dark + (1.0 - dark) * (1.0 - mask);

    out.final_color = .{
        texel[0] * light,
        texel[1] * light,
        texel[2] * light,
        texel[3],
    };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
