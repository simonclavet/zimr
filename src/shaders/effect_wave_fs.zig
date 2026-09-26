//! src/shaders/effect_wave_fs.zig - animated sinusoidal UV distortion,
//! raylib's `wave.fs` ported (their `shaders_texture_waves`).
//!
//! Each axis of the sample coordinate gets a traveling sine offset
//! driven by the OTHER axis - x sways by a cosine of y, y by a sine of
//! x - so the image ripples like fabric instead of just sliding.
//! Frequencies/amplitudes/speeds and even the magic 750 divisor are
//! raylib's numbers verbatim; amplitude is expressed in source PIXELS
//! (hence the size uniform), which keeps the wobble constant when the
//! source resolution changes.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const shader_io = @import("effect_wave_fs_io.zig");
const shader_externs = @import("effect_wave_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const seconds: f32 = io_in.u.drive[0];
    const freq_x: f32 = io_in.u.drive[1];
    const freq_y: f32 = io_in.u.drive[2];
    const amp_x: f32 = io_in.u.motion[0];
    const amp_y: f32 = io_in.u.motion[1];
    const speed_x: f32 = io_in.u.motion[2];
    const speed_y: f32 = io_in.u.motion[3];

    const pixel_w: f32 = 1.0 / @max(io_in.u.size[0], 1.0);
    const pixel_h: f32 = 1.0 / @max(io_in.u.size[1], 1.0);
    const aspect: f32 = pixel_h / pixel_w;

    // raylib's wave.fs body, variable names deciphered: phase runs along
    // the perpendicular axis, time scrolls it, amplitude is in texels.
    var p: Vec2 = io_in.frag_uv;
    p[0] += @cos(io_in.frag_uv[1] * freq_x / (pixel_w * 750.0) + seconds * speed_x) * amp_x * pixel_w;
    p[1] += @sin(io_in.frag_uv[0] * freq_y * aspect / (pixel_h * 750.0) + seconds * speed_y) * amp_y * pixel_h;

    out.final_color = io_in.texture0(p);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
