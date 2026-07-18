//! src/shaders/effect_cubes_fs_io.zig — the panning-cubes procedural pattern.
//! Companion to `effect_cubes_fs.zig`; shares the effect family's shape and adds
//! only its own Ubo.
//!
//! Note this effect declares `Samplers` (via the common schema) but never SAMPLES
//! them: it generates every pixel from the UV and the clock. That mirrors raylib's
//! `shaders_texture_rendering`, which draws a BLANK texture through the shader —
//! the texture is only a canvas to rasterise over. Keeping the sampler in the
//! schema means the effect still satisfies the family's binding contract, so
//! `effects2d` can run it with no special case.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// `params` = {time_seconds, divisions, fill, 0}
///   time_seconds — drives both the pan and the periodic rotation
///   divisions    — how many cubes across the canvas
///   fill         — the square's size within its cell, 0..1
pub const Ubo = struct {
    params: Vec = .{ 0, 5, 0.216, 0 },
};
