//! examples/instancing_vs_io.zig — typed interface for the instancing vertex
//! shader. Companion to `instancing_vs.zig`.
//!
//! Demonstrates INSTANCED drawing with a multi-buffer vertex layout: one buffer
//! holds the per-vertex triangle shape (slot 0), two more hold per-instance data
//! (offset @1, colour @2). The three `Attributes` declare only the @locations;
//! the per-vertex-vs-per-instance step modes live in the hand-built
//! `vertex_buffer_layouts` the host passes to `loadShaderVF` (the schema can't
//! express step rate, so instanced layouts are built by hand — see the example).
//!
//! The `Ubo` (a 4x4 transform for aspect-correction) is declared here in the
//! vertex schema, so the codegen binds it at @group(0) and `loadShaderVF` routes
//! it automatically. The fragment stage is shared with `pipeline_uniforms_fs`
//! (pure colour pass-through), so this file only defines the vertex side.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");

/// Vertex attributes across THREE buffers (step rate set host-side):
///   - `vertex_position` (slot 0, per-vertex): the shared triangle shape.
///   - `instance_offset`  (slot 1, per-instance): where to place each copy.
///   - `instance_color`   (slot 2, per-instance): each copy's colour.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    instance_offset: shader.Attr(.vec2, 1),
    instance_color: shader.Attr(.vec3, 2),
};

/// Single uniform block (group 0, binding 0): a 4x4 aspect-correction transform,
/// rewritten by the host each frame. mat4 == [4]Vec (std140 rows).
pub const Ubo = struct {
    transform: [4]Vec,
};

/// Varying to the fragment stage — the interpolated colour. Matches
/// `pipeline_uniforms_fs_io.Inputs` field-for-field (structural reuse).
pub const Outputs = struct {
    frag_color: Vec,
};
