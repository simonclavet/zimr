//! src/shaders/billboard_fs.zig - textured-3D / billboard FS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Samples the material texture and
//! tints by the interpolated vertex colour. Schema in `billboard_fs_io.zig`.

const zm = @import("zm");
const shader_externs = @import("billboard_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const t: zm.Vec = io_in.tex(io_in.o_uv);
    const c: zm.Vec = io_in.o_col;
    out.final_color = .{ t[0] * c[0], t[1] * c[1], t[2] * c[2], t[3] * c[3] };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
