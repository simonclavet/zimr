//! lightmap_vs_io.zig — IO schema for the lightmap vertex shader. Two UV sets:
//! `vertex_uv` (base texture, may tile) and `vertex_uv2` at the reserved
//! texcoord2 location 5 (the lightmap, one 0..1 span over the whole surface).
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_uv: shader.Attr(.vec2, 1),
    vertex_uv2: shader.Attr(.vec2, 5),
};

pub const Ubo = struct {
    mvp: [4]Vec,
};

pub const Outputs = struct {
    frag_uv: Vec, // xy = base uv
    frag_uv2: Vec, // xy = lightmap uv
};
