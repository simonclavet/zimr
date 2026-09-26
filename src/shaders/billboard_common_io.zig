//! src/shaders/billboard_common_io.zig - the `Interp` varyings shared by
//! `billboard_vs` and `billboard_fs`. The interpolated uv + vertex colour flow
//! from the vertex stage to the fragment stage; aliasing one struct keeps them
//! matched by construction.
//!
//! Field names are prefixed `o_` (o_uv, o_col) to avoid colliding with the VS
//! vertex-attribute names (`uv`, `col`) - the codegen emits both attributes and
//! outputs into one namespace, so a shared name would be a duplicate member.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

/// Interpolated texture coordinate (`o_uv`) + vertex colour (`o_col`).
pub const Interp = struct {
    o_uv: Vec2,
    o_col: Vec,
};
