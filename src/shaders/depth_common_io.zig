//! src/shaders/depth_common_io.zig — Interp varyings shared by
//! `depth_vs` and `depth_fs`.
//!
//! The "depth-in-red" primitive: the VS computes each vertex's depth
//! value and folds it into a grayscale colour (r=g=b=depth, a=1); the
//! FS just emits it (cube3d-style pass-through, so the whole shader is
//! one group-0 uniform and no scalar varyings). Two consumers select
//! behaviour via `Ubo.mode`:
//!   * mode 1 — `shaders_depth_rendering`: linearized, normalized
//!     grayscale depth visualisation (near dark, far light).
//!   * mode 0 — the shadow-map light PASS: raw `ndc_z*0.5+0.5`, the
//!     exact value `pbr_fs.computeShadow` compares as `closest_depth`
//!     (a directional light uses an orthographic projection, so this
//!     raw depth is already linear and the comparison is exact).

const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated values flowing from `depth_vs` to `depth_fs`. Field
/// order is the `layout(location = N)` decoration on both stages.
pub const Interp = struct {
    /// Grayscale depth colour computed in the VS. `.r` is the shadow
    /// map's stored `closest_depth` in mode 0.
    frag_gray: Vec,
};
