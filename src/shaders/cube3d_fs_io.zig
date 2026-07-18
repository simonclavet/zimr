//! src/shaders/cube3d_fs_io.zig — typed interface for the cube3d
//! immediate-mode fragment shader. Companion to `cube3d_fs.zig`.
//!
//! Pure pass-through: lighting already happened in the VS, so the fragment
//! stage has no uniforms and no samplers — it just emits the interpolated
//! (flat, per-face) colour. `Inputs` aliases the shared `Interp` so field
//! order trivially matches VS Outputs.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("cube3d_common_io.zig");

/// Interpolated inputs from `cube3d_vs` — aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Stage output — the final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
