//! src/shaders/skybox_common_io.zig - the varyings shared by `skybox_vs` and
//! `skybox_fs`. The VS forwards the world-space view ray plus the two sky
//! gradient colours; the FS reads only these varyings, so it needs no UBO of
//! its own. That keeps the whole skybox pipeline on a single group-0 uniform
//! (read by the VS), matching the host's one-bind-group layout.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;

/// View ray (`dir`) plus the gradient endpoints (`sky_bottom`, `sky_top`)
/// forwarded from the VS so the FS is UBO-free.
pub const Interp = struct {
    dir: Vec3,
    sky_bottom: Vec,
    sky_top: Vec,
};
