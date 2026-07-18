//! src/shaders/skybox_fs.zig — gradient-skybox FS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Mixes the two sky colours (both
//! forwarded from the VS as varyings — no UBO here) by the view ray's vertical
//! component. Schema in `skybox_fs_io.zig`.

const zm = @import("zm");
const normalize = zm.normalize;
const clamp01 = zm.clamp01;
const shader_externs = @import("skybox_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const d: zm.Vec3 = normalize(io_in.dir);
    const t: f32 = clamp01(d[1] * 0.5 + 0.5);
    const b: zm.Vec = io_in.sky_bottom;
    const tp: zm.Vec = io_in.sky_top;
    out.final_color = .{
        b[0] + (tp[0] - b[0]) * t,
        b[1] + (tp[1] - b[1]) * t,
        b[2] + (tp[2] - b[2]) * t,
        1.0,
    };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
