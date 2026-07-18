//! examples/cube_split_vs_io.zig — schema for the cube_split demo's
//! vertex shader.  Declares Attributes / Ubo / Outputs consumed by
//! `cube_split_vs.zig` (shader body) and shared with the CPU host
//! `cube_split.zig`.
//!
//! Outputs become varyings to the fragment shader; the matching
//! `cube_split_fs_io.Inputs` must agree field-for-field (drift
//! produces a GLSL link error, not silent corruption).

const zm = @import("zm");
const Vec2 = zm.Vec2;
const shader = @import("shader_interface");

/// Vertex attributes consumed by this VS.  Position is 3D world-space;
/// tex_coord is the 2D UV.  Location 0 / 1 match the GPU side's
/// vertex-buffer layout (interleaved P3 + UV2, no normals — flat
/// shading via UV-driven texture).
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_tex_coord: shader.Attr(.vec2, 1),
};

/// UBO carrying the model-view-projection matrix.  Single source of
/// truth for both GPU push (via `loaded.ub.push(ubo)`) and CPU
/// dispatch (via `base_io.u = ubo`).
pub const Ubo = struct {
    /// Model-view-projection matrix.  4 columns × 4 rows = 16 f32.
    /// Standard GLSL column-major layout — `mat[col][row]`.
    /// `zm.mulMatVec` consumes this directly.
    mvp: [4]@Vector(4, f32),
};

/// Varying outputs to the fragment shader.  Just the UV — the cube
/// is flat-shaded against the texture, no normals.  Must match
/// `cube_split_fs_io.Inputs` field-for-field.
pub const Outputs = struct {
    frag_tex_coord: Vec2,
};
