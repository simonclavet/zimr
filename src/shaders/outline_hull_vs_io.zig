//! src/shaders/outline_hull_vs_io.zig - typed interface for the
//! inverted-hull outline vertex shader.  Companion to
//! `outline_hull_vs.zig`.
//!
//! The classic toon silhouette trick: draw the mesh a SECOND time,
//! puffed up along its normals and with FRONT faces culled - only the
//! inflated shell's back faces survive, peeking out around the real
//! model's silhouette as a constant-ish-width outline.
//!
//! The FS side is `depth_fs`, reused - it's a pure "emit the color
//! varying" passthrough, which is exactly what a flat ink line needs.
//! So the whole outline pass costs ONE new shader file: this one.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("depth_common_io.zig");

/// The standard position + normal pair (the normal is the extrusion
/// direction - this pass reads it in the VERTEX stage, unusually).
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_normal: shader.Attr(.vec3, 1),
};

/// Single uniform block (group 0, binding 0).
pub const Ubo = struct {
    /// Full camera MVP - extrusion happens in MODEL space, before this.
    mvp: [4]Vec,
    /// The ink color the hull is painted in (flat, unlit).
    ink_color: Vec,
    /// {thickness, 0, 0, 0} - model-space extrusion distance.  raylib's
    /// default is 0.005 for a car-sized model; scale to your mesh.
    params: Vec,
};

/// Varying outputs - depth_fs's Interp (frag_gray), carrying the ink.
pub const Outputs = common.Interp;
