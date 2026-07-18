//! examples/bloom_bright_fs.zig — bloom bright-pass FS body.
//!
//! Keeps only the part of each pixel brighter than `thresh`, remapped so the
//! threshold maps to black and white stays white (a soft knee). Feeds the blur
//! passes. Schema in `bloom_bright_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const shader_externs = @import("bloom_bright_fs_externs");

pub const Io = shader_externs.IoT(shader_externs.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const t: Vec = io_in.src(io_in.v_uv);
    const c: Vec3 = .{ t[0], t[1], t[2] };
    const lum: f32 = c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114;
    const thresh: f32 = io_in.u.params[0];
    const keep: f32 = @max(lum - thresh, 0.0) / @max(1.0 - thresh, 0.001);
    out.final_color = .{ c[0] * keep, c[1] * keep, c[2] * keep, 1.0 };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
