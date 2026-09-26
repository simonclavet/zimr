//! src/shaders/effect_ascii_fs_io.zig - ASCII-art effect schema.
//! Companion to `effect_ascii_fs.zig`; shares the effect family's shape
//! (`effect_common_io.zig`) and only adds its own Ubo.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// `params` = {cell_px, color_mix, 0, 0}
///   cell_px    - size of one character cell, in PIXELS
///   color_mix  - 0 = classic monochrome terminal green, 1 = tint each glyph
///                with the colour of the scene underneath it
///
/// `resolution` = {width_px, height_px, 0, 0}
///   The fullscreen quad only gives the shader a 0..1 UV, but the cell grid has
///   to be defined in PIXELS - otherwise the characters stretch with the window's
///   aspect ratio instead of staying square. So the resolution has to be told to
///   the shader; it cannot be derived from the UV.
pub const Ubo = struct {
    params: Vec = .{ 8, 1, 0, 0 },
    resolution: Vec = .{ 800, 450, 0, 0 },
};
