//! examples/bloom_composite_fs.zig - bloom composite FS body.
//!
//! Adds the blurred bloom highlights back onto the original scene, scaled by
//! `intensity`. The final tone-mapping-free combine that produces the glow.
//! Schema in `bloom_composite_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader_externs = @import("bloom_composite_fs_externs");

pub const Io = shader_externs.IoT(shader_externs.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const uv = io_in.v_uv;
    const s: Vec = io_in.scene(uv);
    const b: Vec = io_in.bloom(uv);
    const intensity: f32 = io_in.u.params[0];

    out.final_color = .{
        s[0] + b[0] * intensity,
        s[1] + b[1] * intensity,
        s[2] + b[2] * intensity,
        1.0,
    };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
