//! examples/pipeline_uniforms_fs_io.zig - typed interface for the
//! pipeline_uniforms fragment shader. Companion to `pipeline_uniforms_fs.zig`.
//!
//! Pure pass-through: the fragment stage has no uniforms (the transform lives in
//! the vertex schema) - it just emits the interpolated colour. `Inputs` mirrors
//! the VS `Outputs` field-for-field (structural match).

const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from `pipeline_uniforms_vs`.
pub const Inputs = struct {
    frag_color: Vec,
};

/// Stage output - the final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
