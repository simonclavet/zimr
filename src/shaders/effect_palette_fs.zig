//! src/shaders/effect_palette_fs.zig - indexed-palette recolor,
//! raylib's `palette_switch.fs` ported (their `shaders_palette_switch`).
//!
//! raylib's version reads an 8-bit INDEXED sprite and uses the red
//! channel as a palette index.  The gallery's source is a live
//! full-color scene, so the index comes from quantizing the texel's
//! NTSC luminance into `active_colors` buckets - the same table lookup,
//! doubling as a posterizer.  Swap the table, recolor the world; the
//! example ships a few palettes to cycle (that IS the raylib demo).
//!
//! The lookup is a branchless select-by-match over the fixed 8 slots -
//! uniform control flow, no dynamic indexing into the uniform array
//! (some drivers hate that; a sum of masked entries never can).

const zm = @import("zm");
const Vec = zm.Vec;
const clamp = zm.clamp;
const shader_io = @import("effect_palette_fs_io.zig");
const shader_externs = @import("effect_palette_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const texel: Vec = io_in.texture0(io_in.frag_uv);
    const lum: f32 = 0.299 * texel[0] + 0.587 * texel[1] + 0.114 * texel[2];

    const n: f32 = clamp(io_in.u.params[0], 1.0, 8.0);
    const index: f32 = @min(@floor(lum * n), n - 1.0);

    // Branchless table walk: each slot contributes iff its index matches.
    var color: Vec = .{ 0, 0, 0, 0 };
    inline for (0..shader_io.palette_len) |i| {
        const fi: f32 = @floatFromInt(i);
        const d: f32 = index - fi;
        const hit: f32 = if (d * d < 0.25) 1.0 else 0.0;
        color += io_in.u.palette[i] * @as(Vec, @splat(hit));
    }

    out.final_color = .{ color[0], color[1], color[2], texel[3] };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
