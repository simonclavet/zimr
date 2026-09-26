//! src/shaders/depth_write_fs_io.zig - manual-depth material schema.
//! Companion to `depth_write_fs.zig`; rides `gbuffer_vs` like every
//! forward material (shared varyings from `gbuffer_common_io.zig`).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

/// Interpolated inputs - the gbuffer pair's varyings, verbatim.
pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).
pub const Ubo = struct {
    /// Flat material color; the BLUE channel doubles as the depth key.
    base_color: Vec,
    /// World-space direction TO the light (.w spare) - a little Lambert
    /// so the cubes still read as solid shapes.
    light_dir: Vec,
};

/// Stage outputs: the color at location 0, plus the FragDepth builtin -
/// the field name `frag_depth` is magic (no location; the SPIR-V
/// backend decorates it BuiltIn FragDepth, and spv2wgsl emits
/// `@builtin(frag_depth)`).
pub const Outputs = struct {
    final_color: Vec,
    frag_depth: f32,
};
