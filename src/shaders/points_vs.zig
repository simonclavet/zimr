//! src/shaders/points_vs.zig - instanced gradient points VS body (IoT).
//!
//! Ported from the direct `@SpirvType` version to the typed IoT interface. Reads
//! `io.positions(ii)` from a read-only storage buffer, `io.vertex_index()` /
//! `io.instance_index()` builtins, expands a quad per instance, colours by
//! height. Schema in `points_vs_io.zig`; the shared varying in
//! `points_common_io.zig`.

const zm = @import("zm");
const clamp01 = zm.clamp01;
const shader_io = @import("points_vs_io.zig");
const shader_externs = @import("points_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const vi: u32 = io_in.vertex_index();
    const ii: u32 = io_in.instance_index();

    // Two-triangle quad corner for this vertex.
    const cx: f32 = if (vi == 1 or vi == 4 or vi == 5) 1.0 else -1.0;
    const cy: f32 = if (vi == 2 or vi == 3 or vi == 5) 1.0 else -1.0;

    const p: zm.Vec2 = io_in.positions(ii);
    const uu = io_in.u;

    // Instance centre in NDC (y flipped), expanded by the per-quad corner.
    const center_x: f32 = p[0] * 2.0 - 1.0;
    const center_y: f32 = 1.0 - p[1] * 2.0;
    out.position = .{
        center_x + cx * uu.half_ndc[0],
        center_y + cy * uu.half_ndc[1],
        0.0,
        1.0,
    };

    // Colour = mix(top, bot, clamp(p.y, 0, 1)).
    const tw: f32 = clamp01(p[1]);
    out.col = .{
        uu.top[0] + (uu.bot[0] - uu.top[0]) * tw,
        uu.top[1] + (uu.bot[1] - uu.top[1]) * tw,
        uu.top[2] + (uu.bot[2] - uu.top[2]) * tw,
        uu.top[3] + (uu.bot[3] - uu.top[3]) * tw,
    };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
