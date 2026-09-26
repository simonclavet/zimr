//! examples/pipeline_basic_vs_io.zig - typed interface for the pipeline_basic
//! vertex shader. Companion to `pipeline_basic_vs.zig`.
//!
//! The vertex layout is DECLARED here as typed `Attributes`; the example's
//! vertex buffer mirrors it. No Ubo, no Samplers - the purest geometry shape.
//! `Outputs` must match `pipeline_basic_fs_io.Inputs` field-for-field.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

/// Interleaved vertex: clip-space position (vec2) + colour (vec3).
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_color: shader.Attr(.vec3, 1),
};

/// Varying outputs to the fragment shader: the interpolated colour.
pub const Outputs = struct {
    frag_color: Vec,
};
