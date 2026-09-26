//! src/shaders/cube3d_fs.zig - cube3d immediate-mode fragment shader body.
//!
//! Pass-through: the VS already folded the directional light into
//! `frag_color`, so the fragment stage simply emits the interpolated colour.
//! No samplers, no uniforms. Schema lives in `cube3d_fs_io.zig`.

const shader_io = @import("cube3d_fs_io.zig");
const shader_externs = @import("cube3d_fs_externs");

// IoT(void) - no Ubo, no texture; the only input is the colour varying.
pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

// Silence unused-import warnings - shader_io's types are reached only
// indirectly through the externs IoT instantiation above.
comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.final_color = io_in.frag_color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
