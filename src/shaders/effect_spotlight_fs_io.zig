//! src/shaders/effect_spotlight_fs_io.zig — spotlight-mask effect
//! schema.  Companion to `effect_spotlight_fs.zig`; shared shape in
//! `effect_common_io.zig` (this file only adds the Ubo).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

pub const max_spots: usize = 3;

/// Three spots + the darkness floor:
///   spots[i]: {x_px, y_px, inner_px, radius_px} in SOURCE pixel coords
///   params:   {dark_level, tex_w, tex_h, 0} — dark_level is how much of
///             the scene survives OUTSIDE any spot (raylib caps the mask
///             at 0.9, i.e. 10% bleed-through; the gallery makes it a
///             slider).
pub const Ubo = struct {
    spots: [max_spots]Vec,
    params: Vec = .{ 0.1, 1, 1, 0 },
};
