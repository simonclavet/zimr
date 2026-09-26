//! examples/pipeline_settings_vs.zig - pipeline_settings vertex shader body.
//!
//! Applies the UBO's per-axis scale and x-offset, then passes the RGBA colour
//! through (its alpha drives whichever blend mode the pipeline was built with).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader_io = @import("pipeline_settings_vs_io.zig");
const shader_externs = @import("pipeline_settings_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const pos: Vec2 = io_in.vertex_position;
    const u: Vec = io_in.u.p;
    // pos.x * scale_x + offset, pos.y * scale_y, on the z = 0 plane.
    out.position = .{ pos[0] * u[0] + u[2], pos[1] * u[1], 0.0, 1.0 };
    out.frag_color = io_in.vertex_color;

    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
