//! examples/pipeline_uniforms_vs_io.zig - typed interface for the
//! pipeline_uniforms vertex shader. Companion to `pipeline_uniforms_vs.zig`.
//!
//! Demonstrates a VERTEX-STAGE uniform: the only uniform is a 4x4 transform the
//! host rewrites every frame, so the triangle spins and stays aspect-correct.
//! Because the `Ubo` is declared here (the vertex schema), the codegen binds it
//! at @group(0) and `loadShaderVF` routes it there automatically - the host
//! never names a group.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

/// Vertex attributes: clip-ish position (the matrix finishes the transform) and
/// a per-vertex colour. Locations match the interleaved vertex buffer; the
/// layout is DERIVED from these via `z.shader.vertexLayout`.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_color: shader.Attr(.vec3, 1),
};

/// Single uniform block (group 0, binding 0): a 4x4 transform.
/// mat4 == [4]Vec (std140 rows; uploaded raw, read by the shader as
/// `mulMatPoint`, which matches WGSL `m * vec4(p, 1)`).
pub const Ubo = struct {
    transform: [4]Vec,
};

/// Varying to the fragment stage - the interpolated colour (inlined, not shared,
/// so the vs/fs io files stay in separate modules; the match is structural).
pub const Outputs = struct {
    frag_color: Vec,
};
