//! examples/pipeline_basic_vs.zig — pipeline_basic vertex shader body, in Zig.
//!
//! Pass-through: forwards the clip-space position with w=1 and hands the
//! per-vertex colour to the fragment stage. Compiles to SPIR-V -> WGSL at build
//! time; the app never sees WGSL. Schema: `pipeline_basic_vs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const vec4 = zm.vec4;
const shader_io = @import("pipeline_basic_vs_io.zig");
const shader_externs = @import("pipeline_basic_vs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    out.position = vec4(io_in.vertex_position[0], io_in.vertex_position[1], 0.0, 1.0);
    const c: Vec3 = io_in.vertex_color;
    out.frag_color = vec4(c[0], c[1], c[2], 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
