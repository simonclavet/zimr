//! examples/pipeline_basic_fs.zig - pipeline_basic fragment shader body, in Zig.
//!
//! Emits the interpolated per-vertex colour. Schema: `pipeline_basic_fs_io.zig`.

const shader_io = @import("pipeline_basic_fs_io.zig");
const shader_externs = @import("pipeline_basic_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.final_color = io_in.frag_color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
