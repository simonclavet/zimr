//! examples/four_ways/escape.zig - THE function.
//!
//! Read it. There is nothing here about threads, or GPUs, or compile time. No annotation,
//! no attribute, no `#pragma`, no `__device__`, no `[numthreads]`. It is a Zig function.
//!
//! It runs on four machines:
//!
//!   * at COMPILE TIME, producing an ASCII fractal that is baked into the binary - the
//!     program never executes this loop at all;
//!   * on the CPU's main thread, where it is expensive enough to visibly hitch the frame;
//!   * on a CPU worker thread, doing the same work without hitching anything;
//!   * on the GPU, as SPIR-V, transpiled to WGSL, across thousands of invocations.
//!
//! The demo is not "look, four fractals". The demo is: **look how little the code changed.**
const std = @import("std");
const expectEqual = std.testing.expectEqual;

/// Iterations before the orbit of z -> z^2 + c escapes the disc of radius 2, capped at
/// `max`. The Mandelbrot set is the points that never escape.
///
/// Deliberately written the boring way: plain f32, one loop, no vectors, no comptime
/// cleverness. The claim being made is about WHERE it can run, and any cleverness here
/// would muddy it.
pub fn escape(cx: f32, cy: f32, max: u32) u32 {
    var x: f32 = 0.0;
    var y: f32 = 0.0;
    var i: u32 = 0;
    while (i < max and x * x + y * y < 4.0) : (i += 1) {
        const t: f32 = x * x - y * y + cx;
        y = 2.0 * x * y + cy;
        x = t;
    }
    return i;
}

test "escape: the origin never escapes, and 2+0i leaves immediately" {
    // 0 is in the set: the orbit is 0, 0, 0, ... so it runs out the cap.
    try expectEqual(@as(u32, 64), escape(0.0, 0.0, 64));
    // 2 is not: |2| = 2, so x*x + y*y = 4 is not < 4 and it never enters the loop.
    try expectEqual(@as(u32, 0), escape(2.0, 0.0, 64));
}
