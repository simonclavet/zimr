//! examples/pipeline_settings_vs_io.zig — typed interface for the
//! pipeline_settings vertex shader. Companion to `pipeline_settings_vs.zig`.
//!
//! The fragment stage is the shared pass-through (`pipeline_uniforms_fs`), so
//! only the VS is bespoke here. The vertex-stage `Ubo` packs an aspect-correct
//! scale and an x-offset into one vec4, letting the two blend pipelines place
//! their cluster on opposite halves of the screen from the same geometry.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

/// Vertex attributes: 2D position + an RGBA colour whose alpha drives the blend.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_color: shader.Attr(.vec4, 1),
};

/// Vertex-stage uniform (group 0): `p.xy` = (scale_x, scale_y), `p.z` = x-offset
/// (the host pushes a different offset to each blend pipeline), `p.w` unused.
pub const Ubo = struct {
    p: Vec,
};

/// Varying to the fragment stage — the RGBA colour (matches the shared
/// pass-through FS `Inputs.frag_color`).
pub const Outputs = struct {
    frag_color: Vec,
};
