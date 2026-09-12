//! src/shaders/ssao_blur_common_io.zig — the varying shared by the SSAO blur's stages.
//!
//! Reuses `deferred_shading_vs` as its vertex stage, like `ssao_fs` does: same fullscreen
//! quad, same UV flip, so the interp layout must match it exactly.

const zm = @import("zm");
const Vec2 = zm.Vec2;

/// Interpolated values flowing into `ssao_blur_fs`. Field order = `layout(location = N)`.
pub const Interp = struct {
    /// Texture coordinate into the AO and G-buffer maps ([0,1]², top-left origin).
    frag_uv: Vec2,
};
