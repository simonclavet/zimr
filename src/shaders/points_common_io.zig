//! src/shaders/points_common_io.zig - the `Interp` varyings shared by
//! `points_vs` and `points_fs`. Single source of truth: VS Outputs and FS
//! Inputs both alias this, so they can't drift.

const zm = @import("zm");
const Vec = zm.Vec;

/// The per-vertex colour flowing from `points_vs` to `points_fs`.
pub const Interp = struct {
    col: Vec,
};
