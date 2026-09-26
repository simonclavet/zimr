//! lightmap_fs_io.zig - IO schema for the lightmap fragment shader: two
//! samplers (the base texture, sampled with uv, and the baked lightmap, sampled
//! with uv2) whose product is the lit surface colour.
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

pub const Inputs = struct {
    frag_uv: Vec,
    frag_uv2: Vec,
};

pub const Samplers = struct {
    base: shader.Sampler2D(.albedo, .{}),
    lightmap: shader.Sampler2D(.emission, .{}),
};

pub const Outputs = struct {
    final_color: Vec,
};
