//! src/shaders/shapes_filter_fs_io.zig — the schema for a USER 2D shader.
//!
//! This is raylib's `BeginShaderMode` / `EndShaderMode`: a fragment shader that runs over the
//! ORDINARY 2D batch — every `rect`, `circle`, `text` and `texture` draw between the two calls
//! — rather than over a fullscreen quad (which is what `effects2d` does).
//!
//! The `Inputs` and `Samplers` are IDENTICAL to `default_shapes_fs_io` ON PURPOSE, and that is
//! the whole trick: a pipeline built from this schema is layout-compatible with the engine's
//! own shapes pipeline, so `Renderer2D` can swap one in for the other mid-pass without
//! rebuilding a single bind group. The vertex stage is the engine's, unchanged.
//!
//! The one addition is `Ubo`. Under the engine's group convention (vertex uniforms group 0,
//! samplers group 1, fragment uniforms group 2) a FRAGMENT uniform lands at group 2 — which is
//! exactly the hole the shapes layout leaves open. So a user shader gets parameters without
//! disturbing the projection at group 0 or the texture at group 1.
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("default_shapes_common_io.zig");

/// The batch's varyings — the SAME ones the engine's own shapes shader receives.
pub const Inputs = common.Interp;

/// Whatever texture the draw bound. For an untextured `rect` or `circle` this is the engine's
/// 1x1 white texture, so `texture0(uv) * frag_color` is just the tint — which is why one
/// shader can filter shapes and images alike.
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Fragment uniforms -> group 2. Free, because the shapes layout uses only 0 and 1.
///
/// ONE Vec, not `[4]f32`. A std140 uniform array has a 16-byte element stride, so `[4]f32`
/// would occupy 64 bytes with three-quarters of it padding — and the layout validator in
/// `shader_interface` rejects it outright rather than letting the CPU and GPU disagree about
/// where `params[1]` lives.
pub const Ubo = struct {
    /// x: mix from the untouched color (0) to the fully filtered one (1).
    /// y: seconds, for anything that moves.
    /// z, w: free for the effect.
    params: Vec = .{ 0, 0, 0, 0 },
};

pub const Outputs = struct {
    out_color: Vec,
};
