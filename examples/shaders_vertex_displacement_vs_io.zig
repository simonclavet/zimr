//! examples/shaders_vertex_displacement_vs_io.zig — schema for the GPU vertex-
//! displacement showcase. A Perlin heightfield is sampled IN THE VERTEX STAGE
//! (a vertex-visible sampler) to push a flat grid into a lit, animated 3D
//! surface; the surface normal is computed from three vertex-stage samples per
//! vertex. This is what vertex texture fetch is FOR.
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0), // world XZ in the ground plane
    vertex_uv: shader.Attr(.vec2, 1), // [0,1] lookup into the heightfield
};

pub const Ubo = struct {
    mvp: [4]Vec, // view*projection (model is identity — grid is world-space)
    wave: Vec, // x=time, y=amplitude, z=frequency, w=texel step for normals
    cam: Vec, // xyz=camera position (specular), w=slope scale for the gradient
};

/// The heightfield, marked VERTEX-VISIBLE — the whole point of the demo. Read
/// only by the vertex shader (via the explicit-LOD `heightLevel` accessor),
/// never the fragment stage.
pub const Samplers = struct {
    height: shader.Sampler2D(.albedo, .{ .stages = .{ .vertex = true, .fragment = false } }),
};

pub const Outputs = struct {
    frag_normal: Vec, // world-space surface normal (xyz)
    frag_world: Vec, // xyz=world position, w=height in [0,1] (for colouring)
    frag_view: Vec, // world-space view direction (xyz), for the specular glint
};
