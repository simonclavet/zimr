//! examples/bloom_fullscreen_vs_io.zig - typed interface for the shared
//! fullscreen-triangle vertex shader used by every bloom effect pass. Emits a
//! single oversized triangle covering the viewport from `vertex_index`, with no
//! vertex buffer and no uniforms. Body in `bloom_fullscreen_vs.zig`.

const shader = @import("shader_interface");
const zm = @import("zm");
const Vec2 = zm.Vec2;

/// No vertex buffer - the triangle comes from `vertex_index`. Empty `Attributes`
/// marks the vertex stage. (There is no UBO; the effect passes are configured
/// entirely from the fragment stage.)
pub const Attributes = struct {};

/// The only builtin the body reads.
pub const Builtins = struct {
    vertex_index: shader.Builtin(.vertex_index),
};

/// Outputs to the FS - the screen UV varying (structural match with each FS's Inputs).
pub const Outputs = struct {
    v_uv: Vec2,
};
