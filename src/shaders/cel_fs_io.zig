//! src/shaders/cel_fs_io.zig — typed interface for the cel-shading
//! fragment material.  Companion to `cel_fs.zig`.
//!
//! Third member of the forward-material family riding on `gbuffer_vs`
//! (after fog_fs): same world-position + world-normal varyings, new
//! fragment math.  The material knob is `bands` — how many discrete
//! brightness steps the diffuse ramp is quantized into.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

/// Interpolated inputs — the gbuffer pair's varyings, verbatim.
pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).
pub const Ubo = struct {
    /// Flat material color (rgb; .a spare).
    base_color: Vec,
    /// World-space direction TO the light (one directional; .w spare).
    light_dir: Vec,
    /// {bands, 0, 0, 0} — the toon ramp's step count.  2 = comic-book
    /// hard shadow, ~10 = raylib's default, high values converge back
    /// to smooth Lambert (the joke writes itself).
    params: Vec,
};

/// Stage output — the toon-shaded fragment.
pub const Outputs = struct {
    final_color: Vec,
};
