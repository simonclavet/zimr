//! src/shaders/fluid_discs_vs.zig — instanced SDF-disc VS body (IoT).
//!
//! Ported from the direct `@SpirvType` version to the typed IoT interface — the
//! hardest shader in the engine (two read-only storage buffers + both builtins).
//! Reads the particle centre from `io.positions(ii)` and a per-particle scalar
//! from `io.density(ii)`, expands a 6-vertex quad, maps sim-pixels → logical
//! pixels → NDC, and colours by density. Schema in `fluid_discs_vs_io.zig`; the
//! shared varyings in `fluid_discs_common_io.zig`.

const zm = @import("zm");
const clamp01 = zm.clamp01;
const shader_io = @import("fluid_discs_vs_io.zig");
const shader_externs = @import("fluid_discs_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const vi: u32 = io_in.vertex_index();
    const ii: u32 = io_in.instance_index();

    // Two-triangle quad corner for this vertex (matches the 6-corner array).
    const cx: f32 = if (vi == 1 or vi == 4 or vi == 5) 1.0 else -1.0;
    const cy: f32 = if (vi == 2 or vi == 3 or vi == 5) 1.0 else -1.0;

    const p: zm.Vec2 = io_in.positions(ii);
    const d: zm.Vec2 = io_in.density(ii);
    const uu = io_in.u;

    // sim px -> logical px (aspect-fit) -> NDC (y down -> y up).
    const lp_x: f32 = p[0] * uu.scale[0] + uu.offset[0] + cx * uu.half_px[0];
    const lp_y: f32 = p[1] * uu.scale[1] + uu.offset[1] + cy * uu.half_px[1];
    const center_x: f32 = lp_x * uu.inv_logical[0] * 2.0 - 1.0;
    const center_y: f32 = 1.0 - lp_y * uu.inv_logical[1] * 2.0;

    out.position = .{ center_x, center_y, 0.0, 1.0 };

    // Colour = mix(lo, hi, clamp(density.x * density_scale, 0, 1)).
    const tw: f32 = clamp01(d[0] * uu.density_scale);
    out.col = .{
        uu.lo[0] + (uu.hi[0] - uu.lo[0]) * tw,
        uu.lo[1] + (uu.hi[1] - uu.lo[1]) * tw,
        uu.lo[2] + (uu.hi[2] - uu.lo[2]) * tw,
        uu.lo[3] + (uu.hi[3] - uu.lo[3]) * tw,
    };
    out.corner = .{ cx, cy };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
