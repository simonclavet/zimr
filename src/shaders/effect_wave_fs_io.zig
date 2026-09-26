//! src/shaders/effect_wave_fs_io.zig - sinusoidal UV-warp effect schema.
//! Companion to `effect_wave_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// raylib's wave.fs uniforms, packed into three vec4s:
///   drive:  {seconds, freq_x, freq_y, 0}
///   motion: {amp_x, amp_y, speed_x, speed_y}   (amps in SOURCE pixels)
///   size:   {tex_w, tex_h, 0, 0}
pub const Ubo = struct {
    drive: Vec = .{ 0, 25, 25, 0 },
    motion: Vec = .{ 5, 5, 8, 8 },
    size: Vec = .{ 1, 1, 0, 0 },
};
