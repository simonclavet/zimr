//! src/shaders/pbr_vs.zig - PBR vertex shader body.
//!
//! WebGPU architecture (esp. the stage-segregated binding model that
//! places these VS uniforms in group 0) is documented centrally in
//! src/zimr.zig - read that first.
//!
//! Standard typed-shader form (same as lambert_vs.zig): the schema
//! lives in `pbr_vs_io.zig`; `shaderMain(io) Out` runs on SPIR-V
//! (-> WGSL/GLSL -> GPU) AND wasm32 (-> CPU dispatch).  `installSpirvEntry`
//! materializes the SPIR-V `entry` on GPU targets, no-op on native.
//!
//! Computes: world-space position/normal/tangent (normal via
//! `mat_normal`, tangent via `mat_model` preserving handedness w),
//! texcoord/color passthrough, the light-space position for shadow
//! lookup, and the clip-space position (projection * view * world).
//! Varying-name discipline (snake_case engine vars, camelCase
//! literature notation) is documented in `pbr_fs.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const mulMatVec = zm.mulMatVec;
const normalize = zm.normalize;
const vec3 = zm.vec3;
const vec4 = zm.vec4;
const shader_io = @import("pbr_vs_io.zig");
const shader_externs = @import("pbr_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Uniforms);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // world_pos = mat_model * vec4(vertex_position, 1.0)
    const world_pos: Vec = mulMatPoint(io_in.mat_model, io_in.vertex_position);
    out.frag_world_pos = vec3(world_pos[0], world_pos[1], world_pos[2]);

    // normalize((mat_normal * vec4(vertex_normal, 0.0)).xyz)
    // w=0 form: transform direction, not point.
    const n: Vec3 = io_in.vertex_normal;
    const world_n4: Vec = mulMatVec(io_in.mat_normal, vec4(n[0], n[1], n[2], 0.0));
    const world_n3: Vec3 = vec3(world_n4[0], world_n4[1], world_n4[2]);
    out.frag_world_normal = normalize(world_n3);

    // Tangent through mat_model (tangents transform as direction
    // vectors; mat_model is correct unless the model has non-uniform
    // scale).  Preserve handedness (w) untouched so the FS can
    // reconstruct the bitangent.
    const t: Vec = io_in.vertex_tangent;
    const world_t4: Vec = mulMatVec(io_in.mat_model, vec4(t[0], t[1], t[2], 0.0));
    out.frag_world_tangent = vec4(world_t4[0], world_t4[1], world_t4[2], t[3]);

    // Passthroughs + shadow light-space position.
    out.frag_tex_coord = io_in.vertex_tex_coord;
    out.frag_color = io_in.vertex_color;
    out.frag_light_space_pos = mulMatVec(io_in.light_space_matrix, world_pos);

    // position = mat_projection * mat_view * world_pos
    const view_pos: Vec = mulMatVec(io_in.mat_view, world_pos);
    out.position = mulMatVec(io_in.mat_projection, view_pos);

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
