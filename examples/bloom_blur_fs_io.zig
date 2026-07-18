//! examples/bloom_blur_fs_io.zig — typed interface for the bloom separable-
//! Gaussian blur pass. ONE shader serves both the horizontal and vertical
//! passes: the blur direction (and texel size) is a per-pass UBO value rather
//! than an override constant, so the same compiled shader is reused for both
//! directions by writing a different `dir` — no spec-constant authoring needed.
//! Body in `bloom_blur_fs.zig`.
//!
//! Layout: a post-process pass has no material group, so everything lives in
//! group 0 — the per-pass UBO at binding 0, the source texture + sampler pinned
//! just after it at bindings 1 and 2. `ubo_group = 0` keeps the UBO in the same
//! group as the pinned texture so the whole pass is one bind group.

const shader = @import("shader_interface");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec = zm.Vec;

/// Pin the UBO to group 0 (post passes have no material group; the source
/// texture shares group 0 too).
pub const ubo_group: u32 = 0;

/// Interpolated screen UV from the shared fullscreen VS (structural varying).
pub const Inputs = struct {
    v_uv: Vec2,
};

/// group(0) binding(0): the per-pass blur direction scaled by texel size.
pub const Ubo = struct {
    /// {dir_x * texel, dir_y * texel, 0, 0} — the horizontal pass writes
    /// {texel, 0, ..}, the vertical pass writes {0, texel, ..}.
    dir: Vec,
};

/// The source texture to blur, pinned to group 0 right after the UBO (texture
/// @binding 1, sampler @binding 2).
pub const Samplers = struct {
    src: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 0, .binding = 1 } }),
};

/// Stage output — the blurred colour.
pub const Outputs = struct {
    final_color: Vec,
};
