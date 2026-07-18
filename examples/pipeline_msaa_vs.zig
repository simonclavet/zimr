//! examples/pipeline_msaa_vs.zig — pipeline_msaa vertex shader body.
//! Transforms the 2D triangle by the UBO matrix; no varyings out.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("pipeline_msaa_vs_io.zig");
const shader_externs = @import("pipeline_msaa_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const p: Vec3 = .{ io_in.vertex_position[0], io_in.vertex_position[1], 0.0 };
    out.position = mulMatPoint(io_in.u.transform, p);
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
