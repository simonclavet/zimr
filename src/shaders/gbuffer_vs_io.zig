//! src/shaders/gbuffer_vs_io.zig - typed interface for the G-buffer
//! vertex shader.  Companion to `gbuffer_vs.zig`.
//!
//! One uniform block, three matrices: the full `mvp` for the clip
//! position, the bare `model` so the FS can get honest WORLD-space
//! fragment positions (raylib calls this matModel), and the model's
//! `normal_matrix` (inverse-transpose of model - for our rotate+uniform-
//! scale objects that's just the rotation, but the slot keeps the math
//! correct if a scene ever shears).

const shader = @import("shader_interface");
const common = @import("gbuffer_common_io.zig");

/// Vertex attributes: the standard position+normal pair, matching the
/// leading vec3s of every lit mesh layout in the engine.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_normal: shader.Attr(.vec3, 1),
};

/// Single uniform block (group 0, binding 0), std140-friendly: three
/// column-major mat4s back to back, no padding games.
pub const Ubo = struct {
    /// projection * view * model - the one-hop route to clip space.
    mvp: [4]@Vector(4, f32),
    /// model alone - vertex -> WORLD space, the space lighting lives in.
    model: [4]@Vector(4, f32),
    /// inverse-transpose(model) for normals; rotation-only scenes can
    /// pass the rotation itself.
    normal_matrix: [4]@Vector(4, f32),
};

/// Varying outputs - aliases the shared `Interp`.
pub const Outputs = common.Interp;
