//! src/shaders/decal_common_io.zig — the varyings shared by `decal_vs` and
//! `decal_fs`. The VS forwards the receiver fragment's WORLD position and WORLD
//! normal; the FS needs the world position to project into decal-box space and
//! the normal for the facing test. Aliasing one struct keeps the two stages
//! matched by construction.

const zm = @import("zm");
const Vec3 = zm.Vec3;

/// World-space position (`o_world`) + world-space normal (`o_normal`) of the
/// receiver fragment.
pub const Interp = struct {
    o_world: Vec3,
    o_normal: Vec3,
};
