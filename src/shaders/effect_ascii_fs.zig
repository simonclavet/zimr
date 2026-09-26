//! src/shaders/effect_ascii_fs.zig - ASCII-art post effect (raylib's
//! `shaders_ascii_rendering` ported into the engine's 2D effect family).
//!
//! The scene is diced into character CELLS. Each cell takes ONE sample from the
//! source texture - at the cell's centre - and that single sample is what makes
//! it a quantisation: everything inside the cell collapses to one brightness, the
//! way a terminal collapses a region to one character. That brightness then picks
//! a glyph from a ramp that gets denser as it gets brighter:
//!
//!     (blank)  .  :  -  +  x  #  (solid block)
//!
//! The glyphs are drawn with PURE FLOAT MATH - discs and bars over the cell's
//! local coordinates - rather than sampled from a bitmap font. That is deliberate:
//! a bitmap font would need a second sampler plus u32 bit-twiddling to unpack the
//! rows, and neither dynamic bit-shifts nor `@intFromFloat` are exercised anywhere
//! else in this shader family, so they are unproven on the SPIR-V->WGSL path. Float
//! primitives are proven, they antialias for free, and they scale to any cell size.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const smoothstep = zm.smoothstep;
const vec2 = zm.vec2;
const vec3 = zm.vec3;
const vec4 = zm.vec4;
const shader_io = @import("effect_ascii_fs_io.zig");
const shader_externs = @import("effect_ascii_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

/// Soft-edged filled disc. `aa` is the antialias width, in the same units as the
/// cell-local coordinates, so glyphs stay smooth at any cell size.
fn disc(px: f32, py: f32, cx: f32, cy: f32, radius: f32, aa: f32) f32 {
    const dx: f32 = px - cx;
    const dy: f32 = py - cy;
    const d: f32 = @sqrt(dx * dx + dy * dy);
    return 1.0 - smoothstep(radius - aa, radius + aa, d);
}

/// Soft-edged bar: 1 where |v - centre| < half.
fn bar(v: f32, centre: f32, half: f32, aa: f32) f32 {
    const d: f32 = @abs(v - centre);
    return 1.0 - smoothstep(half - aa, half + aa, d);
}

/// The glyph ramp. `level` is 0..7; higher = more ink. Built from discs and bars
/// so the whole ladder is one branchy but allocation-free expression.
fn glyph(level: f32, px: f32, py: f32, aa: f32) f32 {
    const t: f32 = 0.075; // stroke half-width
    var m: f32 = 0.0;

    if (level < 0.5) {
        m = 0.0; // ' '
    } else if (level < 1.5) {
        m = disc(px, py, 0.5, 0.72, 0.09, aa); // '.'
    } else if (level < 2.5) {
        m = @max( // ':'
            disc(px, py, 0.5, 0.34, 0.09, aa),
            disc(px, py, 0.5, 0.70, 0.09, aa),
        );
    } else if (level < 3.5) {
        m = bar(py, 0.5, t, aa) * bar(px, 0.5, 0.30, aa); // '-'
    } else if (level < 4.5) {
        m = @max( // '+'
            bar(py, 0.5, t, aa) * bar(px, 0.5, 0.30, aa),
            bar(px, 0.5, t, aa) * bar(py, 0.5, 0.30, aa),
        );
    } else if (level < 5.5) {
        // 'x' - two diagonals. |x-y| and |x+y-1| are the distances to them.
        const d1: f32 = bar(px - py, 0.0, t * 1.4, aa);
        const d2: f32 = bar(px + py - 1.0, 0.0, t * 1.4, aa);
        const inside: f32 = bar(px, 0.5, 0.34, aa) * bar(py, 0.5, 0.34, aa);
        m = @max(d1, d2) * inside;
    } else if (level < 6.5) {
        // '#' - two verticals, two horizontals.
        const v: f32 = @max(bar(px, 0.34, t, aa), bar(px, 0.66, t, aa));
        const h: f32 = @max(bar(py, 0.34, t, aa), bar(py, 0.66, t, aa));
        m = @max(v, h) * bar(px, 0.5, 0.42, aa) * bar(py, 0.5, 0.42, aa);
    } else {
        m = bar(px, 0.5, 0.42, aa) * bar(py, 0.5, 0.42, aa); // solid block
    }
    return clamp01(m);
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const cell: f32 = @max(io_in.u.params[0], 3.0);
    const color_mix: f32 = clamp01(io_in.u.params[1]);
    const res: Vec2 = vec2(io_in.u.resolution[0], io_in.u.resolution[1]);

    // UV -> pixels -> cell index. The grid is defined in pixels so the characters
    // stay square whatever the window's aspect ratio is.
    const px: Vec2 = io_in.frag_uv * res;
    const cx: f32 = @floor(px[0] / cell);
    const cy: f32 = @floor(px[1] / cell);

    // ONE sample per cell, taken at its centre. This single sample is the
    // quantisation: the whole cell now has one brightness, like a terminal.
    const centre_uv: Vec2 = vec2(
        (cx * cell + cell * 0.5) / res[0],
        (cy * cell + cell * 0.5) / res[1],
    );
    const src: Vec = io_in.texture0(centre_uv);
    const lum: f32 = clamp01(0.299 * src[0] + 0.587 * src[1] + 0.114 * src[2]);

    // Brightness -> glyph. floor(lum * 8) clamped to the top rung.
    const level: f32 = @min(@floor(lum * 8.0), 7.0);

    // Cell-local coordinates, 0..1.
    const local_x: f32 = (px[0] - cx * cell) / cell;
    const local_y: f32 = (px[1] - cy * cell) / cell;

    // Antialias width in cell-local units: one pixel, expressed in the cell's
    // coordinate system, so small cells don't turn into aliased mush.
    const aa: f32 = 1.0 / cell;
    const ink: f32 = glyph(level, local_x, local_y, aa);

    // Classic terminal green, or the scene's own colour - `color_mix` crossfades.
    const term: Vec3 = vec3(0.36, 1.0, 0.42);
    const tint: Vec3 = vec3(
        term[0] + (src[0] - term[0]) * color_mix,
        term[1] + (src[1] - term[1]) * color_mix,
        term[2] + (src[2] - term[2]) * color_mix,
    );
    const bg: Vec3 = vec3(0.03, 0.05, 0.04);
    const rgb: Vec3 = vec3(
        bg[0] + (tint[0] - bg[0]) * ink,
        bg[1] + (tint[1] - bg[1]) * ink,
        bg[2] + (tint[2] - bg[2]) * ink,
    );

    out.final_color = vec4(rgb[0], rgb[1], rgb[2], 1.0);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
