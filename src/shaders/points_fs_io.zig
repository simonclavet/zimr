//! src/shaders/points_fs_io.zig - typed interface for the points FS.
//! Pass-through: emits the interpolated colour. Body in `points_fs.zig`.

const common = @import("points_common_io.zig");
const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from `points_vs` - aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Stage output - the final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
