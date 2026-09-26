//! examples/trivial_fs.zig - minimal fragment shader for the
//! wgpu_bringup's Phase D1 validation.  Reads the interpolated UV from
//! the VS; emits a UV-gradient color (R = U, G = V, B = 0.5).  No
//! Ubo, no Samplers.
//!
//! Schema: `trivial_fs_io.zig`.

const zm = @import("zm");
const vec4 = zm.vec4;
const shader_io = @import("trivial_fs_io.zig");
const shader_externs = @import("trivial_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    // Time-modulated color: pulse the brightness by sin(time).
    // Validates the typed Ubo path - if the UBO buffer isn't being
    // written correctly, the output color won't pulse.
    const pulse: f32 = 0.5 + 0.5 * @sin(io_in.u.time);
    out.out_color = vec4(
        io_in.frag_tex_coord[0] * pulse, // R = U x pulse
        io_in.frag_tex_coord[1] * pulse, // G = V x pulse
        0.5 * pulse, // B = 0.5 x pulse
        1.0, // A
    );
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
