//! src/shaders/deferred_shading_common_io.zig — the one varying shared
//! by `deferred_shading_vs` and `deferred_shading_fs`.
//!
//! Deferred rendering, pass 2 of 2: a single fullscreen quad whose
//! fragment shader re-lights the whole frame from the G-buffer.  The
//! only thing the vertex stage owes the fragment stage is WHERE in the
//! G-buffer to look — one UV.

const zm = @import("zm");
const Vec2 = zm.Vec2;

/// Interpolated values flowing from `deferred_shading_vs` to `_fs`.
/// Field order = `layout(location = N)` on both stages.
pub const Interp = struct {
    /// Texture coordinate into the three G-buffer maps ([0,1]²,
    /// top-left origin — the VS flips from NDC's bottom-left +y).
    frag_uv: Vec2,
};
