//! examples/pipeline_uniforms_fs.zig — pipeline_uniforms fragment shader body.
//! Emits the interpolated colour straight through.

const shader_io = @import("pipeline_uniforms_fs_io.zig");
const shader_externs = @import("pipeline_uniforms_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.final_color = io_in.frag_color;
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
