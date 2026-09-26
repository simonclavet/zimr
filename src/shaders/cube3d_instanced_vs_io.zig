//! src/shaders/cube3d_instanced_vs_io.zig - typed interface for the INSTANCED
//! 3D vertex shader. Companion to `cube3d_instanced_vs.zig`.
//!
//! Unlike the immediate batch (cube3d_vs, where every primitive is transformed
//! to world space on the CPU), instancing keeps ONE mesh in local space and
//! supplies a per-instance model matrix + colour on the GPU, so N copies render
//! in a single instanced draw. The mesh position/normal arrive on shader
//! locations 0/1 (vertex step), and the 4x4 model matrix (as four vec4 columns)
//! plus the colour arrive on locations 2-6 (instance step). The host wires the
//! two vertex buffers + their step modes in `src/draw3d.zig`. Outputs alias the
//! same `Interp` as the immediate batch, so the existing `cube3d_fs` lights and
//! shades both paths identically.

const shader = @import("shader_interface");
const common = @import("cube3d_common_io.zig");

/// Vertex attributes. Locations 0/1 are per-vertex (the mesh); 2-5 are the four
/// columns of the per-instance model matrix and 6 is the per-instance colour
/// (both instance-step). The matching `VertexBufferLayout`s live in draw3d.zig.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_normal: shader.Attr(.vec3, 1),
    instance_model_c0: shader.Attr(.vec4, 2),
    instance_model_c1: shader.Attr(.vec4, 3),
    instance_model_c2: shader.Attr(.vec4, 4),
    instance_model_c3: shader.Attr(.vec4, 5),
    instance_color: shader.Attr(.vec4, 6),
};

/// Single uniform block (group 0, binding 0): the camera view-projection - the
/// SAME schema the immediate batch uses, so both share one `Resources` host.
pub const Ubo = struct {
    view_projection: [4]@Vector(4, f32),
};

/// Varying outputs to the fragment shader - aliases the shared `Interp`.
pub const Outputs = common.Interp;
