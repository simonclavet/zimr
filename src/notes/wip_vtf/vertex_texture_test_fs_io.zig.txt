//! examples/vertex_texture_test_fs_io.zig — fragment schema (pass-through).
const zm = @import("zm");
const Vec = zm.Vec;

pub const Inputs = struct {
    frag_color: Vec,
};

pub const Outputs = struct {
    final_color: Vec,
};
