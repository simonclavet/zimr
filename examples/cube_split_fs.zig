//! examples/cube_split_fs.zig — fragment shader for the cube_split demo.
//!
//! Samples `texture0` at `frag_tex_coord` (interpolated barycentric-
//! ally from the three vertices of the current triangle), emits the
//! result as the fragment color.  Same source runs on GPU (via SPIR-V
//! → GLSL → WebGL) and CPU (via `raster_shader.rasterizeTriangles`
//! calling this `shaderMain` per pixel).
//!
//! Schema (Inputs / Samplers / Outputs) lives in `cube_split_fs_io.zig`.

const shader_io = @import("cube_split_fs_io.zig");
const shader_externs = @import("cube_split_fs_externs");

// IoT(void) — no Ubo, texture binding is all we need.
pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

// Silence unused-import warnings — shader_io's types are accessed
// only indirectly through the externs IoT instantiation above.
comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.out_color = io_in.texture0(io_in.frag_tex_coord);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
