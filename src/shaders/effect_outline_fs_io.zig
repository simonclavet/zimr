//! src/shaders/effect_outline_fs_io.zig - alpha-edge outline effect
//! schema.  Companion to `effect_outline_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// raylib's outline.fs uniforms:
///   outline_color: the ink
///   params: {outline_size_px, tex_w, tex_h, 0}
pub const Ubo = struct {
    outline_color: Vec = .{ 1, 0.4, 0, 1 },
    params: Vec = .{ 2, 1, 1, 0 },
};
