//! src/shaders/fluid_discs_fs.zig - instanced SDF-disc FS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Draws a soft-edged disc inside
//! the quad: distance from centre `r = length(corner)`, faded by `smoothstep`.
//!
//! The original WGSL `if (r > 1.0) { discard; }` is reproduced WITHOUT an OpKill:
//! `smoothstep(0.8, 1.0, r)` saturates to 1 for r >= 1 (it clamps), so the edge
//! term - and therefore the output alpha - is exactly 0 outside the inscribed
//! disc. Under the pipeline's straight-alpha blend a 0-alpha fragment
//! contributes nothing (identical to a discard), and the pass writes no depth
//! (passive `.always`), so the discard has no other observable effect. The
//! `r > 1.0` guard is kept explicit for parity. Schema in `fluid_discs_fs_io.zig`.

const zm = @import("zm");
const length = zm.length;
const smoothstep = zm.smoothstep;
const shader_externs = @import("fluid_discs_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const corner: zm.Vec2 = io_in.corner;
    const r: f32 = length(corner);
    const edge: f32 = if (r > 1.0) 0.0 else 1.0 - smoothstep(0.8, 1.0, r);
    const c: zm.Vec = io_in.col;
    out.final_color = .{ c[0], c[1], c[2], c[3] * edge };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
