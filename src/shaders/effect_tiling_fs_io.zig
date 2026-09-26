//! src/shaders/effect_tiling_fs_io.zig - texture-tiling effect schema.
//! Companion to `effect_tiling_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// raylib's `tiling.fs` uniform: `tiling` (vec2) - how many times the source
/// image repeats across each axis. Packed into a vec4 (x,y used; z,w pad).
pub const Ubo = struct {
    tiling: Vec = .{ 3, 3, 0, 0 },
};
