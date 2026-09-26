//! src/shaders/effect_sieve_fs_io.zig - Sieve of Eratosthenes effect schema.
//! Companion to `effect_sieve_fs.zig`; shared shape in `effect_common_io.zig`
//! (this file only adds the Ubo). Procedural - `texture0` is declared by the
//! shared Samplers but unused by this effect.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Samplers = common.Samplers;
pub const Outputs = common.Outputs;

/// params: {scale, 0, 0, 0} - the quad is a `scale`x`scale` grid of integers;
/// primes are white, composites tinted by their largest factor <= sqrt.
pub const Ubo = struct {
    params: Vec = .{ 220, 0, 0, 0 },
};
