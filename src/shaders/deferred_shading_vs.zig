//! src/shaders/deferred_shading_vs.zig - deferred lighting vertex shader.
//!
//! The least interesting vertex shader in the engine, on purpose: the
//! incoming positions are already NDC (a fullscreen quad), so clip
//! position is a pass-through, and the G-buffer UV is just that same
//! position remapped from [-1,1] to [0,1] with a v-flip (NDC +y is up,
//! texture +v is down - the same flip every RTT sampler in the engine
//! does).  All the drama lives in `deferred_shading_fs`.

const shader_io = @import("deferred_shading_vs_io.zig");
const shader_externs = @import("deferred_shading_vs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

// Silence unused-import warnings - the schema types are reached only
// through the externs IoT instantiation above.
comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const x: f32 = io_in.vertex_ndc_pos[0];
    const y: f32 = io_in.vertex_ndc_pos[1];
    out.position = .{ x, y, 0.0, 1.0 };

    // NDC -> texture UV: [-1,1] -> [0,1], v flipped so uv (0,0) is the
    // G-buffer's top-left texel.
    out.frag_uv = .{ x * 0.5 + 0.5, 1.0 - (y * 0.5 + 0.5) };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
