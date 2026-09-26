//! src/shaders/billboard_vs.zig - textured-3D / billboard VS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Transforms the vertex position
//! by the shared camera view-projection and passes uv + colour through to the
//! fragment stage. Schema in `billboard_vs_io.zig`; shared varyings in
//! `billboard_common_io.zig`.

const zm = @import("zm");
const mulMatVec = zm.mulMatVec;
const shader_io = @import("billboard_vs_io.zig");
const shader_externs = @import("billboard_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const p: zm.Vec3 = io_in.p;
    out.position = mulMatVec(io_in.u.vp, .{ p[0], p[1], p[2], 1.0 });
    out.o_uv = io_in.uv;
    out.o_col = io_in.col;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
