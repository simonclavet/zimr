//! src/shaders/text_sdf_fs_io.zig - schema for the SDF text fragment shader.
//!
//! A USER 2D shader (raylib `BeginShaderMode`), layout-identical to
//! `default_shapes_fs_io` / `shapes_filter_fs_io` on purpose: the pipeline it
//! builds is bind-group-compatible with the engine's shapes pipeline, so
//! `Renderer2D` swaps it in mid-pass for text drawn between `beginShaderMode`
//! and `endShaderMode`. `texture0` is the glyph atlas - but an SDF atlas, with
//! the signed distance in the alpha channel (0.5 = edge). The one fragment
//! uniform lands at group 2 (the hole the shapes layout leaves open).
const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("default_shapes_common_io.zig");

pub const Inputs = common.Interp;

pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

pub const Ubo = struct {
    /// x: edge smoothing half-width in SDF units (bigger = softer edge; a good
    /// default is ~0.04-0.10). y, z, w: free.
    params: Vec = .{ 0, 0, 0, 0 },
};

pub const Outputs = struct {
    out_color: Vec,
};
