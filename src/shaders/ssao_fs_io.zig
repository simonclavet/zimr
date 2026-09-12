//! ssao_fs_io — typed schema for the screen-space ambient occlusion pass.
//!
//! Reads the world-position and world-normal halves of the G-buffer and writes a single
//! occlusion factor: 1 = fully open, 0 = fully occluded. The result is meant to be MULTIPLIED
//! over an already-lit image, so it is written to all three colour channels.
//!
//! ── ★ WHY THIS IS SIMPLER THAN THE REFERENCE ──
//!
//! GenoView's `ssao.fs` reconstructs each sample's view-space position from a DEPTH buffer,
//! which costs it an inverse-projection matrix, an inverse view-projection matrix, and two
//! depth-linearisation helpers. zimr's G-buffer already stores WORLD POSITION outright
//! (`gbuffer_fs`'s `g_world_pos`), so all of that disappears: this shader reads positions
//! directly and needs only the view matrix, to measure occlusion in view space where the
//! radius has a consistent meaning.
//!
//! ★ The estimator is Scalable Ambient Obscurance (McGuire et al.): sample a spiral around the
//! pixel, and for each sample accumulate `max(r*r - vv, 0)^3 * max(vn / (0.001 + vv), 0)`,
//! normalised by `r^6`. The cubic falloff is what keeps distant geometry from darkening a
//! surface it merely passes behind.

const shader = @import("shader_interface");
const common = @import("ssao_common_io.zig");
const zm = @import("zm");

const Vec = zm.Vec;

pub const Inputs = common.Interp;

/// The two G-buffer channels this pass consumes. Both must be sampled with NEAREST filtering:
/// a filtered world position is a point on no surface, and the occlusion test against it is
/// meaningless — the same reason the shadow map wants a nearest sampler.
pub const Samplers = struct {
    g_world_pos: shader.Sampler2D(.albedo, .{}),
    g_world_normal: shader.Sampler2D(.normal, .{}),
};

/// Group 2, binding 0.
pub const Ubo = struct {
    /// Camera view matrix: occlusion is measured in VIEW space so that `radius` means the same
    /// thing regardless of where the camera is standing.
    view: [4]Vec,
    /// {radius, bias, intensity, sample_count}. Defaults follow GenoView: radius 0.5 world
    /// units, bias 0.025 to stop a surface occluding itself, intensity 0.15.
    params: Vec,
    /// {turns, inv_width, inv_height, unused}. `turns` is how many times the sample spiral
    /// winds — 7 is the reference's value and is chosen to be coprime with the sample count so
    /// the samples do not line up into visible spokes.
    spiral: Vec,
};

pub const Outputs = struct {
    occlusion: Vec,
};
