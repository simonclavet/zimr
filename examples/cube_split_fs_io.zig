//! examples/cube_split_fs_io.zig — schema for the cube_split demo's
//! fragment shader.  Declares Inputs / Samplers / Outputs.
//!
//! `Inputs.frag_tex_coord` MUST match `cube_split_vs_io.Outputs`
//! field-for-field (varying link).  No Ubo — texture binding is all
//! we need.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader = @import("shader_interface");

/// Varying inputs from the vertex shader.  Field order MUST match
/// `cube_split_vs_io.Outputs` (frag_tex_coord at location 0).
pub const Inputs = struct {
    frag_tex_coord: Vec2,
};

/// Sampler.  Reserved name `texture0` → auto-bound to slot 0 by
/// `loadShader`'s schema scan.  On CPU the dispatcher populates
/// `io._texture0: TextureRef` from the user's `gpu.Texture`.
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Stage output.  `out_color` matches the convention; the
/// raster_shader dispatcher's comptime introspection looks for the
/// first `Vec` field in Out, but a consistent name aids
/// grep.
pub const Outputs = struct {
    out_color: Vec,
};
