//! src/shaders/fog_fs_io.zig - typed interface for the fog fragment
//! shader.  Companion to `fog_fs.zig`.
//!
//! The vertex stage is `gbuffer_vs`, REUSED - its outputs (world
//! position + world normal) are exactly what any world-space-lit
//! forward material needs, so `Inputs` aliases the same `Interp` the
//! G-buffer pair shares.  One vertex shader, growing family of
//! fragment materials.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

/// Interpolated inputs - the gbuffer pair's varyings, verbatim.
pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).  All vec4s, std140-exact.
pub const Ubo = struct {
    /// Flat material color (rgb; .a spare).
    base_color: Vec,
    /// Camera position in world space (.w spare) - fog distance and the
    /// specular view vector both start here.
    view_pos: Vec,
    /// World-space direction TO the light (one directional light, like
    /// the raylib demo effectively uses; .w spare).
    light_dir: Vec,
    /// What the world dissolves into.  Match the pass clear color and
    /// distant geometry vanishes seamlessly - mismatch it and every
    /// silhouette wears a halo.
    fog_color: Vec,
    /// {fog_density, 0, 0, 0} - raylib's exponential-squared curve:
    /// visibility = 1/e^((d*density)^2).
    params: Vec,
};

/// Stage output - the fogged fragment.
pub const Outputs = struct {
    final_color: Vec,
};
