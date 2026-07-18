//! src/shaders/lambert_fs_io.zig — typed interface for the Lambert
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! fragment shader.  Companion to `lambert_fs.zig`.
//!
//! Lambertian + ambient, sampled albedo.  Single fixed directional
//! light in world space (no light-direction uniform — it's hardcoded
//! in the body for the same fixture-y "small debug shader" reason
//! the prior `lambert.fs.glsl` had it inline).  25% ambient floor so
//! back-facing surfaces stay visible during model rotation.
//!
//! Migrated from `examples/shared/shaders/lambert.fs.glsl`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("lambert_common_io.zig");

/// Interpolated inputs from `lambert_vs`.  Aliases `common.Interp`
/// so field order trivially matches VS Outputs.
pub const Inputs = common.Interp;

/// Texture samplers.  Single albedo sampler at slot 0.
/// `loadShader` reads this struct at load time and binds the sampler
/// uniform to the matching material-map slot — no manual
/// `glUniform1i` needed.
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Uniforms.  `col_diffuse` is RESERVED — engine pushes the current
/// draw tint each draw.
pub const Uniforms = struct {
    col_diffuse: Vec = .{ 1, 1, 1, 1 },
};

/// Stage output — the final fragment color.
pub const Outputs = struct {
    final_color: Vec,
};
