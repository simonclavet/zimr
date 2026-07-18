//! examples/pipeline_msaa_fs_io.zig — typed interface for the pipeline_msaa
//! fragment shader. No inputs (constant colour); the empty `Inputs` matches the
//! empty VS `Outputs`.

const zm = @import("zm");
const Vec = zm.Vec;

pub const Inputs = struct {};

pub const Outputs = struct {
    final_color: Vec,
};
