//! src/shaders/effect_sieve_fs.zig - the Sieve of Eratosthenes, raylib's
//! `eratosthenes.fs` ported (their `shaders_eratosthenes_sieve`, by ProfJski).
//!
//! The quad is a `scale`x`scale` grid of integers (cell = floor(uv*scale)).
//! Each fragment tests its cell's integer for primality by trial division up
//! to sqrt - the loop bound `i*i <= value` avoids a sqrt - painting primes
//! white and composites by a spectrum of their LARGEST factor <= sqrt (raylib
//! leaves the `break` commented, so the last factor found wins). Purely
//! procedural: it ignores `texture0` (the gallery still binds it; wgpu allows
//! an unused layout entry), so this slot is a pure fragment-compute demo.

const zm = @import("zm");
const sinTurns = zm.sinTurns;
const Vec = zm.Vec;
const shader_io = @import("effect_sieve_fs_io.zig");
const shader_externs = @import("effect_sieve_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

const smoothstep = zm.smoothstep;

/// raylib's Colorizer: a soft spectrum keyed on factor/scale.
fn colorizer(counter: f32, max_size: f32) Vec {
    const norm: f32 = counter / max_size;
    const red: f32 = smoothstep(0.3, 0.7, norm);
    // A HALF turn across the range, so the green channel peaks in the middle. `sinTurns` takes
    // the turn count, and `norm * 0.5` says "half a turn" where `3.14159 *` said it in radians.
    const green_turns: f32 = norm * 0.5;
    const green: f32 = sinTurns(green_turns);
    const blue: f32 = 1.0 - smoothstep(0.0, 0.4, norm);
    return .{ 0.8 * red, 0.8 * green, 0.8 * blue, 1.0 };
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const scale: f32 = io_in.u.params[0];
    const col: f32 = @floor(io_in.frag_uv[0] * scale);
    const row: f32 = @floor(io_in.frag_uv[1] * scale);
    const value: i32 = @trunc(scale * row + col);

    var color: Vec = .{ 1, 1, 1, 1 };
    if (value > 2) {
        var i: i32 = 2;
        while (i * i <= value) : (i += 1) {
            if (@mod(value, i) == 0) {
                color = colorizer(@floatFromInt(i), scale);
            }
        }
    }
    out.final_color = color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
