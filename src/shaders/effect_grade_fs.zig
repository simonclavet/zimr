//! src/shaders/effect_grade_fs.zig - color correction (contrast /
//! brightness / saturation), raylib's `color_correction.fs` ported.
//!
//! Three classic grading knobs applied in raylib's order: pivot the
//! color around mid-gray for contrast, shift for brightness, then push
//! away from (or toward) the NTSC luminance for saturation.  At
//! saturation -1 this IS raylib's `grayscale.fs` - one shader, two of
//! their examples.

const zm = @import("zm");
const Vec = zm.Vec;
const clamp01 = zm.clamp01;
const shader_io = @import("effect_grade_fs_io.zig");
const shader_externs = @import("effect_grade_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    var texel: Vec = io_in.texture0(io_in.frag_uv);
    const contrast: f32 = io_in.u.params[0];
    const brightness: f32 = io_in.u.params[1];
    const saturation: f32 = io_in.u.params[2];

    // Contrast: pivot around 0.5 (raylib: (rgb-0.5)*(c+1)+0.5).
    const gain: f32 = contrast + 1.0;
    texel[0] = (texel[0] - 0.5) * gain + 0.5;
    texel[1] = (texel[1] - 0.5) * gain + 0.5;
    texel[2] = (texel[2] - 0.5) * gain + 0.5;

    // Brightness: plain shift.
    texel[0] += brightness;
    texel[1] += brightness;
    texel[2] += brightness;

    // Saturation: push away from the NTSC luminance (raylib's
    // (rgb-I)*s + rgb - at s = -1 the color collapses onto I: grayscale).
    const lum: f32 = 0.299 * texel[0] + 0.587 * texel[1] + 0.114 * texel[2];
    texel[0] = (texel[0] - lum) * saturation + texel[0];
    texel[1] = (texel[1] - lum) * saturation + texel[1];
    texel[2] = (texel[2] - lum) * saturation + texel[2];

    out.final_color = .{ clamp01(texel[0]), clamp01(texel[1]), clamp01(texel[2]), texel[3] };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
