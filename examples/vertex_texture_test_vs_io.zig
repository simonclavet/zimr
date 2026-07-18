//! examples/vertex_texture_test_vs_io.zig — schema for the vertex-texture-fetch
//! smoke test. The novel bit: a sampler declared VERTEX-VISIBLE, so the vertex
//! shader can read it (via the explicit-LOD `warpLevel` accessor) to warp the
//! grid — proving zimr can sample textures in the vertex stage.
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_uv: shader.Attr(.vec2, 1),
};

pub const Ubo = struct {
    transform: [4]Vec,
};

/// The warp texture, marked visible to the VERTEX stage. Fragment stays off —
/// this binding is read only by the VS.
pub const Samplers = struct {
    warp: shader.Sampler2D(.albedo, .{ .stages = .{ .vertex = true, .fragment = false } }),
};

pub const Outputs = struct {
    frag_color: Vec,
};
