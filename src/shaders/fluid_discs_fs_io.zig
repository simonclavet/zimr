//! src/shaders/fluid_discs_fs_io.zig — typed interface for the SDF-disc FS.
//! Reads the interpolated colour + corner, draws a soft-edged disc. Body in
//! `fluid_discs_fs.zig`.

const common = @import("fluid_discs_common_io.zig");
const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from the VS — aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Stage output — the final fragment colour (straight-alpha).
pub const Outputs = struct {
    final_color: Vec,
};
