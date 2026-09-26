//! examples/pipeline_msaa_fs.zig - pipeline_msaa fragment shader body.
//! Emits one flat high-contrast colour so the MSAA edge quality is obvious.

const shader_io = @import("pipeline_msaa_fs_io.zig");
const shader_externs = @import("pipeline_msaa_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    _ = io_in;
    var out: Out = undefined;
    out.final_color = .{ 0.45, 0.85, 1.0, 1.0 };
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
