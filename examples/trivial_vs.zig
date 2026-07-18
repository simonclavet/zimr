//! examples/trivial_vs.zig — minimal vertex shader for the
//! wgpu_bringup's Phase D1 validation.  Pass-through: caller pushes
//! clip-space positions; VS forwards them with w=1.  UV varies to
//! the FS unchanged.
//!
//! Schema: `trivial_vs_io.zig`.  No Ubo, no Samplers.

const zm = @import("zm");
const vec4 = zm.vec4;
const shader_io = @import("trivial_vs_io.zig");
const shader_externs = @import("trivial_vs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.position = vec4(
        io_in.vertex_position[0],
        io_in.vertex_position[1],
        0.0,
        1.0,
    );
    out.frag_tex_coord = io_in.vertex_tex_coord;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
