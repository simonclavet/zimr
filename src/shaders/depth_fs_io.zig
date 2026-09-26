//! src/shaders/depth_fs_io.zig - typed interface for the depth-in-red
//! fragment shader. Companion to `depth_fs.zig`.
//!
//! No samplers, no uniforms: the depth value was computed in the VS and
//! folded into `frag_gray`; this stage just emits it. `Inputs` aliases
//! the shared `Interp` so field order trivially matches VS `Outputs`.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("depth_common_io.zig");

/// Interpolated inputs from `depth_vs` - aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Stage output - the depth-as-colour buffer. `.r` is what
/// `pbr_fs.computeShadow` samples as `closest_depth` (mode 0).
pub const Outputs = struct {
    out_color: Vec,
};
