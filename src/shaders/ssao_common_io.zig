//! src/shaders/ssao_common_io.zig - the one varying shared by the SSAO pass's stages.
//!
//! Like `deferred_shading`, the SSAO pass is a single fullscreen quad and the only thing the
//! vertex stage owes the fragment stage is WHERE in the G-buffer to look.
//!
//! It reuses `deferred_shading_vs` as its vertex stage rather than shipping its own - the
//! quad, the UV flip and the interp layout are identical, and a second copy would be a second
//! thing to keep in step.

const zm = @import("zm");
const Vec2 = zm.Vec2;

/// Interpolated values flowing into `ssao_fs`. Field order = `layout(location = N)`.
pub const Interp = struct {
    /// Texture coordinate into the G-buffer maps ([0,1]^2, top-left origin).
    frag_uv: Vec2,
};
