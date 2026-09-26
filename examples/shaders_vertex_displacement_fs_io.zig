//! examples/shaders_vertex_displacement_fs_io.zig - fragment schema: consume the
//! VS varyings (surface normal, world position + height, view direction) and
//! light the surface.
const zm = @import("zm");
const Vec = zm.Vec;

pub const Inputs = struct {
    frag_normal: Vec,
    frag_world: Vec,
    frag_view: Vec,
};

pub const Outputs = struct {
    final_color: Vec,
};
