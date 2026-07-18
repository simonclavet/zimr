//! src/shaders/fluid_discs_common_io.zig — the `Interp` varyings shared by
//! `fluid_discs_vs` and `fluid_discs_fs`. Single source of truth: the VS
//! Outputs and FS Inputs both alias this, so the per-instance colour and the
//! quad-corner offset can never drift between the two stages.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

/// Per-vertex disc colour (`col`) plus the two-triangle quad corner offset
/// (`corner`, in [-1, 1]²) the FS uses for the SDF-disc falloff.
pub const Interp = struct {
    col: Vec,
    corner: Vec2,
};
