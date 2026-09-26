//! src/shaders/lambert_vs.zig - Lambert vertex shader body.
//!
//! Behavior parity with the prior GLSL: position via MVP, world-space
//! normal via `mat_model * vertex_normal` as a direction (w=0,
//! rotation only - non-uniform scale would need the inverse-transpose,
//! intentionally omitted to keep it small), texcoord passthrough.
//!
//! Standard typed-shader form: the schema lives in `lambert_vs_io.zig`;
//! `shaderMain(io) Out` runs on SPIR-V (-> WGSL/GLSL -> GPU) AND wasm32
//! (-> CPU dispatch).  `installSpirvEntry` materializes the SPIR-V
//! `entry` on GPU targets and is a no-op on native.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const mulMatVec = zm.mulMatVec;
const normalize = zm.normalize;
const vec3 = zm.vec3;
const vec4 = zm.vec4;
const shader_io = @import("lambert_vs_io.zig");
const shader_externs = @import("lambert_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Uniforms);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Clip-space position: project the vertex through MVP (w=1 point).
    out.position = mulMatPoint(io_in.mvp, io_in.vertex_position);

    // Texcoord passthrough - interpolated to the FS per fragment.
    out.frag_tex_coord = io_in.vertex_tex_coord;

    // World-space normal: transform by mat_model as a direction (w=0,
    // so only rotation contributes), then normalize.  Non-uniform
    // scale skews this (no inverse-transpose) - matches the source.
    const n: Vec3 = io_in.vertex_normal;
    const world_n4: Vec = mulMatVec(io_in.mat_model, vec4(n[0], n[1], n[2], 0.0));
    const world_n3: Vec3 = vec3(world_n4[0], world_n4[1], world_n4[2]);
    out.frag_normal = normalize(world_n3);

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
