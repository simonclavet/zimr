//! src/shaders/effect_palette_fs_io.zig - indexed-palette effect schema.
//! Companion to `effect_palette_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

pub const palette_len: usize = 8;

/// Eight palette entries (rgb in [0,1]; .a spare) + params
/// {active_colors, 0, 0, 0}.  raylib's `palette_switch.fs` indexes an
/// 8-bit indexed sprite by its red channel; our gallery source is live
/// full-color, so the index is the texel's LUMINANCE quantized into
/// `active_colors` buckets - same lookup, honest posterize-to-palette.
pub const Ubo = struct {
    palette: [palette_len]Vec,
    params: Vec = .{ palette_len, 0, 0, 0 },
};
