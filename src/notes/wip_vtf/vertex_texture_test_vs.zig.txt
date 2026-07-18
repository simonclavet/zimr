//! examples/vertex_texture_test_vs.zig — the vertex shader that samples a
//! texture IN THE VERTEX STAGE. `warpLevel` is the explicit-LOD accessor
//! (→ textureSampleLevel), which needs no derivatives and is legal here.
const zm = @import("zm");
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("vertex_texture_test_vs_io.zig");
const shader_externs = @import("vertex_texture_test_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const uv: zm.Vec2 = io_in.vertex_uv;
    // Vertex-stage texture fetch. Offset the 2D vertex by the sampled colour.
    const warp: zm.Vec = io_in.warpLevel(uv, 0.0);
    const off_x: f32 = (warp[0] - 0.5) * 0.35;
    const off_y: f32 = (warp[1] - 0.5) * 0.35;
    const p: Vec3 = .{ io_in.vertex_position[0] + off_x, io_in.vertex_position[1] + off_y, 0.0 };
    out.position = mulMatPoint(io_in.u.transform, p);
    out.frag_color = .{ warp[0], warp[1], warp[2], 1.0 };
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
