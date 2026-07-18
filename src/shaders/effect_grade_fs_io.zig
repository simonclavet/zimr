//! src/shaders/effect_grade_fs_io.zig — color-correction effect schema.
//! Companion to `effect_grade_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// {contrast, brightness, saturation, 0} — raylib's color_correction.fs
/// semantics with the /100 pre-applied: contrast/brightness are [-1,1]
/// offsets, saturation is the same [-1,1] "extra saturation" knob (0 =
/// unchanged, -1 = grayscale, +1 = doubled color distance).
pub const Ubo = struct {
    params: Vec = .{ 0, 0, 0, 0 },
};
