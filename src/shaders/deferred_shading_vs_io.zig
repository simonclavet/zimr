//! src/shaders/deferred_shading_vs_io.zig — typed interface for the
//! deferred lighting pass's vertex shader.  Companion to
//! `deferred_shading_vs.zig`.
//!
//! No uniforms at all: the geometry is a screen-covering pair of
//! triangles whose positions are ALREADY in NDC ([-1,1]²).  The VS just
//! passes them through and derives the G-buffer UV.  raylib routes this
//! through its mvp-fitted quad helper; skipping the matrix entirely is
//! one less thing that can be wrong.

const shader = @import("shader_interface");
const common = @import("deferred_shading_common_io.zig");

/// One attribute: a 2D NDC position (z is implied 0, w implied 1).
pub const Attributes = struct {
    vertex_ndc_pos: shader.Attr(.vec2, 0),
};

/// Varying outputs — aliases the shared `Interp`.
pub const Outputs = common.Interp;
