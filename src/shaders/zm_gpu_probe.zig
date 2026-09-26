//! A shader whose only job is to fail the build if `zm` stops working on the GPU.
//!
//! WHY THIS FILE EXISTS
//!
//! `zimrmath` is the one module allowed to touch `std.math`, and the deal is that every function
//! it wraps is gated on `comptime !is_gpu` with a hand-rolled GPU branch, **verified to compile
//! for a shader**. That last clause had no mechanism behind it. A function was "verified" if some
//! shader in the tree happened to call it, which meant the least-used helpers - exactly the ones
//! most likely to have a broken GPU branch - were the least verified.
//!
//! It caught a real gap the first time it was written. `nan`, `inf`, `floatMax`, `floatMin` and
//! `floatEps` take a TYPE rather than a value, so `perLane` could not help them, and every one
//! answered `@compileError` for a vector type. A shader's working type IS a vector, so
//! `zm.floatEps(zm.Vec)` - a per-lane tolerance, the obvious thing to want - did not
//! compile at all. They splat now, and this file is what keeps them splatting.
//!
//! HOW TO ADD TO IT: call the function on a vector type and fold the result into `acc`. Anything
//! reachable from the entry point is compiled; anything folded into the output survives dead-code
//! elimination at `-O ReleaseFast`, which is how the build runs it. A call whose result is
//! discarded proves nothing, because the optimiser is entitled to delete it.

const zm = @import("zm");
const clamp = zm.clamp;

/// `zm.Vec` IS `@Vector(4, f32)` - four lanes of f32, what a fragment shader actually computes
/// in, and the case the type-parameterized helpers used to reject.
const Vec = zm.Vec;
const nan = zm.nan;
const inf = zm.inf;

export fn zmGpuProbe(
    out: *addrspace(.storage_buffer) Vec,
    x: Vec,
) callconv(.{ .spirv_fragment = .{} }) void {
    // The five constant helpers, on a VECTOR type. Each one was a compile error here until the
    // `splatTo` change; none of them has a CPU-only path to fall back on.
    var acc: Vec = zm.floatEps(Vec);
    acc += zm.floatMin(Vec);

    // Clamped against the vector `floatMax`, which is the shape a saturating accumulate wants.
    acc = clamp(x + acc, @as(Vec, @splat(0.0)), zm.floatMax(Vec));

    // `isFinite` returns a vector of bools for a vector input, which is what makes the NaN guard
    // a `@select` rather than a branch - branches are what a shader cannot afford per lane.
    acc = @select(f32, zm.isFinite(acc), acc, @as(Vec, @splat(0.0)));

    // A NaN and an infinity built on the GPU side, then selected away. If `nan`/`inf` stopped
    // compiling for a vector type this line would fail before anything ran.
    const poisoned: Vec = nan(Vec) + inf(Vec);
    acc = @select(f32, zm.isNan(poisoned), acc, acc + @as(Vec, @splat(1.0)));

    // Folded into the output so ReleaseFast cannot delete the whole thing and call it verified.
    out.* = acc;
}
