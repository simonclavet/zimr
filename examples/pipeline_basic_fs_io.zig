//! examples/pipeline_basic_fs_io.zig - typed interface for the pipeline_basic
//! fragment shader. Companion to `pipeline_basic_fs.zig`. No Ubo, no Samplers.
//! `Inputs` must match `pipeline_basic_vs_io.Outputs` field-for-field.

const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from the VS: the per-vertex colour.
pub const Inputs = struct {
    frag_color: Vec,
};

/// Stage output - the final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
