//! src/shaders/points_fs.zig — instanced points FS body (IoT).
//! Pass-through: emits the interpolated colour. Schema in `points_fs_io.zig`.

const shader_externs = @import("points_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.final_color = io_in.col;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
