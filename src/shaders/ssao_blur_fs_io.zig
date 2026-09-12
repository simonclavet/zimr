//! ssao_blur_fs_io — typed schema for the SSAO bilateral blur.
//!
//! One axis per pass; run it twice (horizontal, then vertical) ping-ponging between two
//! targets. Separable, so 2 x 7 taps buys the same reach as 49.
//!
//! ── ★ WHY THIS IS NOT `bloom_blur_fs` ──
//!
//! A bloom blur is a plain weighted average: every neighbour contributes by distance alone.
//! Doing that to an occlusion buffer BLEEDS AO ACROSS SILHOUETTES — a dark crease behind a
//! character smears onto the character, and the ground picks up shading from the figure
//! standing on it.
//!
//! This blur is BILATERAL: each tap's weight is scaled down when the neighbour's world
//! POSITION is far from the centre's, and again when its NORMAL points elsewhere. Samples that
//! belong to a different surface contribute almost nothing, so the noise averages away while
//! edges stay put. That is why it needs the G-buffer alongside the AO texture.

const shader = @import("shader_interface");
const common = @import("ssao_blur_common_io.zig");
const zm = @import("zm");

const Vec = zm.Vec;

pub const Inputs = common.Interp;

/// The AO texture being blurred, plus the two G-buffer channels that define an edge. All three
/// want NEAREST filtering — a filtered position or normal describes no real surface.
pub const Samplers = struct {
    src: shader.Sampler2D(.albedo, .{}),
    g_world_pos: shader.Sampler2D(.normal, .{}),
    g_world_normal: shader.Sampler2D(.emission, .{}),
};

/// Group 2, binding 0.
pub const Ubo = struct {
    /// {texel_x, texel_y, axis_x, axis_y}. The axis picks the pass: (1,0) horizontal,
    /// (0,1) vertical. Keeping it a uniform means ONE pipeline serves both passes.
    step: Vec,
    /// {position_falloff, normal_power, 0, 0}. `position_falloff` scales squared world
    /// distance before the exponential; `normal_power` sharpens the normal term.
    weights: Vec,
};

pub const Outputs = struct {
    blurred: Vec,
};
