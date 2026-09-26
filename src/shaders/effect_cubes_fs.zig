//! src/shaders/effect_cubes_fs.zig - panning, snap-rotating cubes.
//! Ports raylib's `shaders_texture_rendering` (its `cubes_panning.fs`).
//!
//! Purely procedural: every pixel comes from the UV and the clock, nothing is
//! sampled. raylib draws a BLANK texture through this shader - the texture is
//! only a canvas to rasterise over - which is exactly what "render a texture with
//! a shader" means there.
//!
//! Two ideas stacked:
//!   PAN     the UV drifts with time, then multiplies up by `divisions`, so
//!           `floor` gives a cell index and `fract` gives coordinates INSIDE the
//!           cell. That is the whole tiling trick.
//!   SNAP    within each 1-second period the cell's contents rotate 0 -> 45deg
//!           -> hold -> back, eased with a sine on the two moving quarters. The
//!           result reads as a mechanism, not a spin.
//!
//! raylib's GLSL mutates a FILE-SCOPE `angle` from inside a function. That is
//! global state in a shader; here the angle is simply RETURNED, which is the same
//! maths with none of the spooky action.

const zm = @import("zm");
const sinTurns = zm.sinTurns;
const Vec2 = zm.Vec2;
const clamp01 = zm.clamp01;
const fract = zm.fract;
const step = zm.step;
const pi = zm.pi;
const vec2 = zm.vec2;
const vec4 = zm.vec4;
const shader_io = @import("effect_cubes_fs_io.zig");
const shader_externs = @import("effect_cubes_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

/// The rotation angle for this instant. 0 -> pi/4 -> hold -> 0 across one second,
/// with the two MOVING quarters eased by a sine so the snap has weight.
/// TURNS ALL THE WAY THROUGH, WHICH IS WHAT THIS FUNCTION WAS ALREADY DOING
///
/// `local_turns` is `fract(t)` - a turn count on [0, 1) - and the branch thresholds are quarter turns.
/// The two `@sin` calls converted that to radians and the library divided it back out. Now the
/// quarter-turn shift reads as `- 0.25` rather than `- pi / 2.0`, which is the same number said
/// in the same units as everything around it.
fn snapAngle(t: f32) f32 {
    const local_turns: f32 = fract(t);
    var a: f32 = 0.0;
    if (local_turns < 0.25) {
        a = 0.0;
    } else if (local_turns < 0.50) {
        // `local_turns` is already a turn, and so is the shift: `- pi/2` is a quarter turn back.
        a = (pi / 4.0) * sinTurns(local_turns - 0.25);
    } else if (local_turns < 0.75) {
        a = pi * 0.25;
    } else {
        a = (pi / 4.0) * sinTurns(local_turns);
    }
    return a;
}

/// Rotate a cell-local_turns coordinate about the cell's CENTRE (0.5, 0.5) - rotating
/// about the origin would swing the square out of its own cell.
fn rotateAboutCentre(v: Vec2, angle: f32) Vec2 {
    const c: f32 = @cos(angle);
    const s: f32 = @sin(angle);
    const p: Vec2 = v - vec2(0.5, 0.5);
    const r: Vec2 = vec2(c * p[0] - s * p[1], s * p[0] + c * p[1]);
    return r + vec2(0.5, 0.5);
}

/// An axis-aligned square inside the unit cell, as a product of four steps - the
/// classic branch-free rectangle.
fn square(st: Vec2, size: f32) f32 {
    const edge: f32 = 0.5 - size / 2.0;
    const left: f32 = step(edge, st[0]);
    const right: f32 = step(edge, 1.0 - st[0]);
    const top: f32 = step(edge, st[1]);
    const bottom: f32 = step(edge, 1.0 - st[1]);
    return left * right * top * bottom;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const t: f32 = io_in.u.params[0];
    const divisions: f32 = @max(io_in.u.params[1], 1.0);
    const fill: f32 = clamp01(io_in.u.params[2]);

    // Pan, then tile: floor = which cell, fract = where inside it.
    const panned: Vec2 = (io_in.frag_uv + vec2(t / 9.0, t / 9.0)) * vec2(divisions, divisions);
    const cell: Vec2 = vec2(@floor(panned[0]), @floor(panned[1]));
    var inner: Vec2 = vec2(fract(panned[0]), fract(panned[1]));

    inner = rotateAboutCentre(inner, snapAngle(t * 0.2));
    const alpha: f32 = square(inner, fill);

    // A checker tint off the CELL index, so the panning is readable - raylib's is
    // flat grey, which makes the drift hard to see on a phone.
    const checker: f32 = fract((cell[0] + cell[1]) * 0.5) * 2.0; // 0 or 1
    const warm: f32 = 0.35 + 0.25 * checker;

    const r: f32 = 0.10 + warm * 0.55;
    const g: f32 = 0.55 + warm * 0.35;
    const b: f32 = 0.85 - warm * 0.15;

    const bg: f32 = 0.06;
    out.final_color = vec4(
        bg + (r - bg) * alpha,
        bg + (g - bg) * alpha,
        bg + (b - bg) * alpha,
        1.0,
    );
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
