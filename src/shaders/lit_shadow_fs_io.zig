//! src/shaders/lit_shadow_fs_io.zig - typed interface for the
//! shadow-mapped Lambert fragment shader. Companion to `lit_shadow_fs.zig`.
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig section 3:
//! VS uniforms->group 0, samplers->group 1, FS uniforms->group 2.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("lit_shadow_common_io.zig");

/// Interpolated inputs from `lit_shadow_vs`.
pub const Inputs = common.Interp;

/// Samplers (group 1). A single depth map (depth-in-red rgba8) written
/// by the light pass; bound manually to the render texture.
pub const Samplers = struct {
    shadow_map: shader.Sampler2D(.albedo, .{}),
};

/// FS uniform block (group 2, one binding). `light_dir` = world-space
/// direction TO the light (Lambert dot); `base_color` = flat albedo.
pub const Ubo = struct {
    light_dir: Vec,
    base_color: Vec,
    /// {bias_slope, bias_min, 0, 0} - the shadow-compare bias is DATA, not
    /// code, because it depends on the DEPTH MAP'S PRECISION, which differs
    /// per backend: the GPU renders the map into rgba16_float (defaults
    /// below), while the CPU/comptime software targets are rgba8 (256
    /// levels) and need roughly 8x more slack. One shader body serves all
    /// three backends; each hands in the bias its own map deserves.
    params: Vec = .{ 0.0025, 0.0008, 0, 0 },
};

/// Stage output - the final fragment color.
pub const Outputs = struct {
    final_color: Vec,
};
