//! Minimal reproducer v2: a loop with TWO sequential conditional breaks (the
//! second setting a flag), matching the mandelbrot escape loop structure that
//! mis-emits the if-merge phi (phi335 written, phi337 read).
const std = @import("std");
const zm = @import("zm");
const shader_externs = @import("loop_fs_externs");
const io = @import("loop_fs_io.zig");

pub const Io = shader_externs.IoT(io.Ubo);

pub fn shaderMain(io_in: Io) io.Outputs {
    var out: io.Outputs = undefined;

    var acc: f32 = io_in.frag_tex_coord[0];
    var n: f32 = 0;
    var escaped: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i +%= 1) {
        // Break #1: iteration gate.
        if (@as(f32, @floatFromInt(i)) >= io_in.u.threshold) {
            break;
        }
        // Break #2: escape with a side-effect flag (this is the shape that
        // creates the mis-numbered if-merge phi).
        if (acc > 4.0) {
            escaped = 1;
            break;
        }
        acc = acc * acc + 0.5;
        n += 1.0;
    }

    const g: f32 = if (escaped == 1) n / 256.0 else 0.0;
    out.out_color = zm.vec4(g, g, g, 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
