//! examples/bloom_fullscreen_vs.zig - shared fullscreen-triangle VS body.
//!
//! Emits the standard oversized covering triangle - NDC corners (-1,-1),
//! (3,-1), (-1,3) - and derives a [0,1] y-down screen UV for the fragment
//! stage. Reused by every bloom effect pass (bright, blur, composite). Schema
//! in `bloom_fullscreen_vs_io.zig`.

const shader_externs = @import("bloom_fullscreen_vs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const vi: u32 = io_in.vertex_index();
    const cx: f32 = if (vi == 1) 3.0 else -1.0;
    const cy: f32 = if (vi == 2) 3.0 else -1.0;

    out.position = .{ cx, cy, 0.0, 1.0 };
    // NDC (-1..1, y-up) -> UV (0..1, y-down).
    out.v_uv = .{ (cx + 1.0) * 0.5, 1.0 - (cy + 1.0) * 0.5 };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
