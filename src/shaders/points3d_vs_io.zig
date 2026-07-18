//! src/shaders/points3d_vs_io.zig — typed interface for the unlit 3D
//! point-cloud vertex shader.  Companion to `points3d_vs.zig`.
//!
//! Same single-UBO shape as `cube3d_vs` (one camera view-projection,
//! set once per pass) but the attribute stream is just position +
//! colour: point clouds have no meaningful normals and raylib draws
//! them full-bright, so there is nothing to light.  Outputs alias the
//! cube3d `Interp`, which is what lets this stage pair with the
//! existing `cube3d_fs` passthrough with varying compatibility by
//! construction — a point-cloud pipeline costs one vertex shader and
//! zero new fragment shaders.

const shader = @import("shader_interface");
const common = @import("cube3d_common_io.zig");

/// Vertex attributes: world-space position + per-point colour.
/// Locations match the interleaved P3F + C4U8 vertex the example packs
/// (the unorm8x4 attribute arrives here normalized to [0,1]).
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_color: shader.Attr(.vec4, 1),
};

/// Single uniform block (group 0, binding 0): the camera
/// view-projection.
pub const Ubo = struct {
    view_projection: [4]@Vector(4, f32),
};

/// Varying outputs — aliases the cube3d `Interp` (one colour), so
/// `cube3d_fs` is the matching fragment stage.
pub const Outputs = common.Interp;
