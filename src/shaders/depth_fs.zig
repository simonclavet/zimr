//! src/shaders/depth_fs.zig - depth-in-red fragment shader body.
//!
//! Pure pass-through: the VS already computed the grayscale depth and
//! folded it into `frag_gray`, so the fragment stage simply emits it.
//! No samplers, no uniforms. Schema lives in `depth_fs_io.zig`.

const shader_io = @import("depth_fs_io.zig");
const shader_externs = @import("depth_fs_externs");

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
    out.out_color = io_in.frag_gray;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
