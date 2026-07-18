//! examples/pipeline_uniforms_vs.zig — pipeline_uniforms vertex shader body.
//!
//! Transforms each 2D vertex by the UBO's 4x4 matrix and passes the colour
//! through. The matrix (host-supplied) spins the triangle and squashes it
//! aspect-correct, replacing the CPU vertex-rewrite the basic example used.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("pipeline_uniforms_vs_io.zig");
const shader_externs = @import("pipeline_uniforms_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // mat4 * vec4(p.xy, 0, 1): treat the 2D vertex as a point on the z=0 plane.
    const p: Vec3 = .{ io_in.vertex_position[0], io_in.vertex_position[1], 0.0 };
    out.position = mulMatPoint(io_in.u.transform, p);

    const c: Vec3 = io_in.vertex_color;
    out.frag_color = .{ c[0], c[1], c[2], 1.0 };

    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
