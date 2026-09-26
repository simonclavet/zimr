//! examples/pipeline_msaa_vs_io.zig - typed interface for the pipeline_msaa
//! vertex shader. A position-only triangle transformed by a vertex-stage UBO;
//! there are NO varyings (the fragment stage emits a constant colour), so
//! `Outputs` is empty and matches the empty FS `Inputs`.

const shader = @import("shader_interface");

pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
};

/// Vertex-stage uniform (group 0): a 4x4 rotation the host spins each frame.
pub const Ubo = struct {
    transform: [4]@Vector(4, f32),
};

/// No varyings - the fragment shader takes no interpolated inputs.
pub const Outputs = struct {};
