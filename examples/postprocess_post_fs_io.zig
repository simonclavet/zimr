//! examples/postprocess_post_fs_io.zig — schema for the postprocess demo's
//! FULLSCREEN post-processing fragment shader. Declares Inputs / Samplers /
//! Outputs; no Ubo (the effect is parameter-free).
//!
//! `Inputs.frag_tex_coord` MUST match `trivial_vs_io.Outputs` field-for-
//! field — the post pass reuses the trivial fullscreen VS, which emits a single
//! `frag_tex_coord` varying. The `scene` sampler is the previous pass's
//! RenderTexture (bound by name in `desc.textures`).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader = @import("shader_interface");

/// Varying from the fullscreen VS — the screen UV (0..1).
pub const Inputs = struct {
    frag_tex_coord: Vec2,
};

/// The scene texture to post-process. Bound by name: `.textures = .{ .scene =
/// rt.asTexture() }`. The field name becomes the sampling method `io.scene(uv)`.
pub const Samplers = struct {
    scene: shader.Sampler2D(.albedo, .{}),
};

/// Final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
