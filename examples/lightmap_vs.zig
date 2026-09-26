//! lightmap_vs.zig - transform the plane by MVP and pass BOTH uv sets through
//! to the fragment stage (base uv + lightmap uv2).
const zm = @import("zm");
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;

const shader_io = @import("lightmap_vs_io.zig");
const shader_externs = @import("lightmap_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const wp: Vec3 = .{ io_in.vertex_position[0], io_in.vertex_position[1], io_in.vertex_position[2] };
    out.position = mulMatPoint(io_in.u.mvp, wp);
    out.frag_uv = .{ io_in.vertex_uv[0], io_in.vertex_uv[1], 0.0, 0.0 };
    out.frag_uv2 = .{ io_in.vertex_uv2[0], io_in.vertex_uv2[1], 0.0, 0.0 };
    return out;
}
