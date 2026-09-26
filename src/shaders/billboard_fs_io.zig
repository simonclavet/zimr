//! src/shaders/billboard_fs_io.zig - typed interface for the billboard FS.
//! Samples one texture at group 1 and tints by the interpolated vertex colour.
//! Body in `billboard_fs.zig`.

const common = @import("billboard_common_io.zig");
const shader = @import("shader_interface");
const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from the VS - aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// One material texture at group 1 (texture @binding 0, sampler @binding 1).
pub const Samplers = struct {
    tex: shader.Sampler2D(.albedo, .{}),
};

/// Stage output - the final tinted fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
