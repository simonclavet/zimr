//! src/shaders/points3d_vs.zig - unlit 3D point-cloud vertex shader.
//!
//! One job: project the point through the camera view-projection and
//! hand its colour straight to the passthrough fragment stage
//! (`cube3d_fs`).  Deliberately UNLIT - raylib's point rendering is
//! full-bright, and a point has no meaningful normal to light anyway.
//! Contrast with `cube3d_vs`, which folds a directional Lambert into
//! the colour; that would uniformly dim a cloud by ~13% for nothing.
//!
//! Drawn at `point_list` topology: one vertex, one framebuffer pixel.
//! Schema lives in `points3d_vs_io.zig`.

const zm = @import("zm");
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("points3d_vs_io.zig");
const shader_externs = @import("points3d_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.position = mulMatPoint(io_in.u.view_projection, io_in.vertex_position);
    out.frag_color = io_in.vertex_color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
