//! examples/trivial_vs_io.zig - schema for the trivial VS used
//! by the wgpu_bringup to validate Phase D1 (loadShader) end-to-end.
//!
//! No Ubo, no Samplers - purest possible shape.  Vertex positions
//! arrive already in clip space (-1..+1); the VS passes them through.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const shader = @import("shader_interface");

/// Vertex attributes - matches the Vertex2D layout that loadShader
/// hardcodes: pos: vec2 at location 0, uv: vec2 at location 1.
/// The color attribute at location 2 is part of the layout (so the
/// vertex buffer stride matches) but not consumed by this VS.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_tex_coord: shader.Attr(.vec2, 1),
};

/// Pass-through outputs.  frag_tex_coord becomes a varying to the FS.
pub const Outputs = struct {
    frag_tex_coord: Vec2,
};
