//! examples/cube_split_vs.zig - vertex shader for the cube_split demo.
//!
//! Standard vertex transform: project world-space position through
//! the MVP matrix; pass UV through to the fragment shader.  Same
//! source compiles for SPIR-V (-> GLSL -> GPU) AND wasm32 (-> CPU
//! dispatch via `raster_shader.dispatchVertexShader`).
//!
//! Schema (Attributes / Ubo / Outputs) lives in `cube_split_vs_io.zig`.

const zm = @import("zm");
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("cube_split_vs_io.zig");
const shader_externs = @import("cube_split_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    // Project the vertex position through MVP.  `mulMatPoint`
    // assumes w=1 (a point, not a direction) and returns a
    // homogeneous Vec4 ready for the perspective divide that the
    // rasterizer (GPU or CPU) performs downstream.
    out.position = mulMatPoint(io_in.u.mvp, io_in.vertex_position);
    // Pass the UV through unchanged - interpolation happens between
    // here and the FS via per-fragment barycentric weights.
    out.frag_tex_coord = io_in.vertex_tex_coord;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
