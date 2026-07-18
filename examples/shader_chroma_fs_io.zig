//! examples/shader_chroma_fs_io.zig — schema for the chroma-shift
//! fragment shader.  Declares Inputs / Samplers / Uniforms / Outputs.
//!
//! Inputs MUST match the engine default VS's outputs
//! (frag_tex_coord at loc 0, frag_color at loc 1); see
//! `src/shaders/default_vs.zig`.  No Ubo — sampler bindings and
//! loose uniforms (col_diffuse, u_offset, u_time) carry everything.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader = @import("shader_interface");

/// Varying inputs from the (default) vertex shader.  Field order
/// MUST match the default VS's `Outputs` (frag_tex_coord at loc 0,
/// frag_color at loc 1).
pub const Inputs = struct {
    frag_tex_coord: Vec2,
    frag_color: Vec,
};

/// Sampler used for the RTT-result image.  Reserved name (`texture0`)
/// → auto-bound to `MaterialMapIndex.albedo` slot by `loadShader`.
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Loose uniforms — one engine-reserved (`col_diffuse`, pushed by
/// rlgl on each draw) plus two example-specific scalar uniforms the
/// host pushes per frame.
pub const Uniforms = struct {
    /// Engine-managed.  Pushed by the rlgl batch system from the
    /// current draw's tint colour.
    col_diffuse: Vec = .{ 1, 1, 1, 1 },
    /// Maximum chroma offset in UV units.  Host pushes this each
    /// frame; the shader scales by a sinusoidal envelope on `u_time`.
    u_offset: f32 = 0,
    /// Current animation time in seconds.  Drives the chroma offset
    /// envelope.
    u_time: f32 = 0,
};

/// Stage output — the final fragment colour.
pub const Outputs = struct {
    final_color: Vec,
};
