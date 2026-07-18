//! src/shaders/outline_hull_vs.zig — inverted-hull outline vertex
//! shader.
//!
//! Inflate the mesh along its normals by `thickness`, project, and hand
//! the FS a flat ink color.  Paired with FRONT-face culling, the
//! inflated shell only shows where it pokes out past the real model —
//! the silhouette — because everywhere else the model's own (closer)
//! fragments win the depth test.
//!
//! FS partner: `depth_fs` (reused — a pure color-varying passthrough).
//! Schema in `outline_hull_vs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const normalize = zm.normalize;
const shader_io = @import("outline_hull_vs_io.zig");
const shader_externs = @import("outline_hull_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Extrude in model space (raylib's outline_hull.vs, verbatim math):
    // vertex + normal·thickness, THEN project.  Normalizing first makes
    // the width immune to un-normalized art normals.
    const n: Vec3 = normalize(io_in.vertex_normal);
    const thickness: f32 = io_in.u.params[0];
    const puffed: Vec3 = io_in.vertex_position + n * @as(Vec3, @splat(thickness));
    out.position = mulMatPoint(io_in.u.mvp, puffed);

    // The ink, riding the frag_gray varying into depth_fs's passthrough.
    out.frag_gray = io_in.u.ink_color;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
