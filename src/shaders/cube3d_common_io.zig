//! src/shaders/cube3d_common_io.zig - Interp varyings shared by
//! `cube3d_vs` and `cube3d_fs`.
//!
//! The cube carries per-face normals (four identical-normal corners per
//! face), so per-vertex lighting in the VS is exactly flat shading - there is
//! no within-face gradient to lose by not doing it per fragment. The VS folds
//! the directional-light term into a single pre-lit colour and the FS just
//! emits it, keeping the fragment stage a trivial pass-through (and the whole
//! shader to one group-0 uniform). Single source of truth: VS Outputs and FS
//! Inputs both alias this.

const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated values flowing from `cube3d_vs` to `cube3d_fs`. Field order is
/// the `layout(location = N)` decoration on both stages.
pub const Interp = struct {
    frag_color: Vec,
};
