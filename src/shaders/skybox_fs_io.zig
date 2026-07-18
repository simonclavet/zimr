//! src/shaders/skybox_fs_io.zig — typed interface for the gradient-skybox FS.
//! Reads only the interpolated varyings (view ray + sky colours forwarded by
//! the VS), so it needs no UBO — the whole pipeline stays on one group-0
//! uniform. Mixes the two sky colours by the ray's vertical component. Body in
//! `skybox_fs.zig`.

const common = @import("skybox_common_io.zig");
const zm = @import("zm");
const Vec = zm.Vec;

/// Interpolated inputs from the VS — aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Stage output — the final sky colour.
pub const Outputs = struct {
    final_color: Vec,
};
