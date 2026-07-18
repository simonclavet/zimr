// src/easings.zig - pure-CPU easing curves for tween animation.
// What's here: 28 functions named `<family><Mode>`, where `family` is
// one of {linear, sine, circ, quad, cubic, expo, back, bounce,
// elastic} and `mode` is one of {In, Out, InOut}.  (Linear has only
// one variant, since in/out/inout all collapse to identity.)
// Signature contract:
//   fn(t: f32) f32
// Input `t` is normalised time in `[0, 1]`.  Output is the eased
// progress, also typically in `[0, 1]`, with three exceptions
// (documented per-function below):
//   * `backIn`, `backOut`, `backInOut` overshoot by ~10% on the
//     "leaving" side of each endpoint.
//   * `elasticIn`, `elasticOut`, `elasticInOut` oscillate
//     multiple times before settling, with amplitude up to ~30%.
//   * `bounceIn`, `bounceOut`, `bounceInOut` stay non-negative
//     but include local maxima that touch but don't exceed 1.
// Standard usage pattern - the easing function picks the curve,
// and the *caller* does the lerp:
//   const t01 = zm.clamp(elapsed / duration, 0, 1);
//   const eased = easings.quadInOut(t01);
//   const value = start + eased * (end - start);
// Equivalent if you prefer `zm.lerp`:
//   const value = zm.lerp(start, end, easings.quadInOut(t01));
// All functions are pure: no allocations, no side effects, no
// dependencies beyond `std.math`.  Safe to call from any context.
// In/Out/InOut convention is Robert Penner's standard:
//   In       - slow at the start, accelerating toward the end
//   Out      - fast at the start, decelerating toward the end
//   InOut    - slow at both ends, fast in the middle
// The naming is independent of overshoot: `backOut` means
// "decelerating, with an overshoot near t=1 before settling
// back".  Penner's families chose the curve geometry first, then
// In/Out is just which end of the curve faces the slow side.
// Why pure `fn(t: f32) f32` and not the raylib 4-arg form?
// raylib's `reasings.h` uses `f(currentTime, startValue, change,
// duration)`.  That signature bakes the lerp into the easing
// function itself, which makes composition awkward - you can't
// easily compose two easings, you can't compute an easing once and
// reuse the result for multiple lerps (e.g. animating both X and
// Y of a position with the same curve), and you have to plumb
// start/change everywhere.  The `[0, 1] -> [0, 1]` form is the
// modern convention used by every CSS engine, every game-tween
// library after ~2015, and is the form Penner himself recommends
// in the writeup.  Cleaner.  The 28 functions below are 1:1
// translations of the raylib formulas, just with the `(t, b, c, d)
// -> (t/d) -> [0,1]` step folded out.

const std = @import("std");
const expect = std.testing.expect;
const zm = @import("zm");
const float = zm.float;
const isFinite = zm.isFinite;
const pow = zm.pow;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const pi: f32 = zm.pi;
const half_pi: f32 = pi / 2.0;

// ============================================================================
// Linear
// ============================================================================
// Identity function.  In/Out/InOut are all the same shape.

pub fn linear(t: f32) f32 {
    return t;
}

// ============================================================================
// Sine
// ============================================================================
// Quarter-circle on the unit hypotenuse.  Looks smoother than
// `quad` to the eye but is computationally similar.

pub fn sineIn(t: f32) f32 {
    // 1 - cos(t·π/2): starts at 0, accelerates to 1 with infinite
    // derivative at t=1.
    return 1.0 - @cos(t * half_pi);
}

pub fn sineOut(t: f32) f32 {
    // sin(t·π/2): inverse-shape of sineIn.  Fast start, decelerating.
    return @sin(t * half_pi);
}

pub fn sineInOut(t: f32) f32 {
    // -(cos(π·t) - 1) / 2: full half-cosine, slow→fast→slow.
    return -(@cos(pi * t) - 1.0) / 2.0;
}

// ============================================================================
// Circ (circular)
// ============================================================================
// Quarter of a unit circle, traced from one axis to the
// perpendicular axis.  Visually "snappy" - the derivative is
// infinite at the slow end, so the motion appears to "jump" in.

pub fn circIn(t: f32) f32 {
    return 1.0 - @sqrt(1.0 - t * t);
}

pub fn circOut(t: f32) f32 {
    const x: f32 = t - 1.0;
    return @sqrt(1.0 - x * x);
}

pub fn circInOut(t: f32) f32 {
    if (t < 0.5) {
        const x: f32 = 2.0 * t;
        return (1.0 - @sqrt(1.0 - x * x)) / 2.0;
    }
    const x: f32 = 2.0 * t - 2.0;
    return (@sqrt(1.0 - x * x) + 1.0) / 2.0;
}

// ============================================================================
// Quad (t²)
// ============================================================================
// Simplest polynomial easing.  Cheap to compute; widely used as
// a default "ease" for UI animations.

pub fn quadIn(t: f32) f32 {
    return t * t;
}

pub fn quadOut(t: f32) f32 {
    // Reflected parabola: -t·(t - 2) = 1 - (1 - t)².
    return -t * (t - 2.0);
}

pub fn quadInOut(t: f32) f32 {
    if (t < 0.5) {
        return 2.0 * t * t;
    }
    // 1 - 2·(1-t)² hits 1 at t=1 with zero derivative.
    const x: f32 = 1.0 - t;
    return 1.0 - 2.0 * x * x;
}

// ============================================================================
// Cubic (t³)
// ============================================================================
// Stronger ease than quad - t³ pulls the curve harder into both
// ends.  Good for "settling" motions where you want a clearly
// non-linear feel without overshoot.

pub fn cubicIn(t: f32) f32 {
    return t * t * t;
}

pub fn cubicOut(t: f32) f32 {
    const x: f32 = t - 1.0;
    return x * x * x + 1.0;
}

pub fn cubicInOut(t: f32) f32 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    }
    const x: f32 = 2.0 * t - 2.0;
    return (x * x * x + 2.0) / 2.0;
}

// ============================================================================
// Expo (2^...)
// ============================================================================
// Exponential - *very* strong ease.  Almost flat for most of the
// duration, then snaps to the endpoint near the end (or start, for
// Out).  Common in UI for "drawer slides closed" effects.

pub fn expoIn(t: f32) f32 {
    // raylib's source explicitly returns 0 at t=0 because pow(2,
    // -inf) is technically epsilon, not zero.  We do the same so
    // the curve hits its endpoint exactly.
    if (t == 0.0) {
        return 0.0;
    }
    return pow(2.0, 10.0 * (t - 1.0));
}

pub fn expoOut(t: f32) f32 {
    if (t == 1.0) {
        return 1.0;
    }
    return 1.0 - pow(2.0, -10.0 * t);
}

pub fn expoInOut(t: f32) f32 {
    if (t == 0.0) {
        return 0.0;
    }
    if (t == 1.0) {
        return 1.0;
    }
    if (t < 0.5) {
        return pow(2.0, 20.0 * t - 10.0) / 2.0;
    }
    return 1.0 - pow(2.0, -20.0 * t + 10.0) / 2.0;
}

// ============================================================================
// Back (overshoot)
// ============================================================================
// Cubic with a "pullback" before the easing direction.  Overshoots
// by about 10% past the endpoint before settling.  `s = 1.70158`
// is Penner's traditional overshoot constant - chosen so the
// overshoot is the canonical "feels right" amount; bigger `s`
// = bigger overshoot.
// `s_io = 1.70158 * 1.525` for the InOut variant.  The 1.525
// multiplier compensates for the InOut being a stitched half-and-
// half curve, so each half overshoots by the same visible amount
// as a single In or Out would.

const back_s: f32 = 1.70158;
const back_s_io: f32 = 1.70158 * 1.525;

pub fn backIn(t: f32) f32 {
    // (s+1)·t³ - s·t².  Goes briefly negative around t ≈ 0.15.
    return t * t * ((back_s + 1.0) * t - back_s);
}

pub fn backOut(t: f32) f32 {
    // Reflection of backIn - overshoots past 1.0 around t ≈ 0.85
    // before settling to 1.0 at t=1.
    const x: f32 = t - 1.0;
    return x * x * ((back_s + 1.0) * x + back_s) + 1.0;
}

pub fn backInOut(t: f32) f32 {
    if (t < 0.5) {
        const x: f32 = 2.0 * t;
        return (x * x * ((back_s_io + 1.0) * x - back_s_io)) / 2.0;
    }
    const x: f32 = 2.0 * t - 2.0;
    return (x * x * ((back_s_io + 1.0) * x + back_s_io) + 2.0) / 2.0;
}

// ============================================================================
// Bounce
// ============================================================================
// Four-segment piecewise parabolic curve that mimics a ball
// bouncing on a hard floor with decreasing amplitude.  The magic
// numbers come from solving for "parabolas that touch a unit
// height at four progressively-narrower intervals", yielding the
// constant `n = 7.5625`.
// Each segment is `n · x² + offset` for some local x.  The
// boundary points are 1/d, 2/d, 2.5/d, where d = 2.75; these
// are tuned so each segment's tail matches the next segment's
// head at the boundary.  The 0.984375 = 63/64 at the final
// segment's high point ensures the last "bounce" doesn't quite
// reach 1.0 (mimicking energy loss in a real bounce - though it
// does reach exactly 1.0 at t=1 because the curve's right edge
// is `n · 0² + 1.0`).

pub fn bounceOut(t: f32) f32 {
    const n: f32 = 7.5625;
    const d: f32 = 2.75;
    if (t < 1.0 / d) {
        return n * t * t;
    } else if (t < 2.0 / d) {
        const x: f32 = t - 1.5 / d;
        return n * x * x + 0.75;
    } else if (t < 2.5 / d) {
        const x: f32 = t - 2.25 / d;
        return n * x * x + 0.9375;
    }
    const x: f32 = t - 2.625 / d;
    return n * x * x + 0.984375;
}

pub fn bounceIn(t: f32) f32 {
    // Reflection: bounce becomes "shrinking pre-bounces leading
    // into the slam at t=1".
    return 1.0 - bounceOut(1.0 - t);
}

pub fn bounceInOut(t: f32) f32 {
    // First half is a half-amplitude bounceIn, second half is a
    // half-amplitude bounceOut, stitched at t=0.5 -> 0.5.
    if (t < 0.5) {
        return bounceIn(t * 2.0) / 2.0;
    }
    return bounceOut(t * 2.0 - 1.0) / 2.0 + 0.5;
}

// ============================================================================
// Elastic
// ============================================================================
// Spring-like oscillating curve.  Visually like releasing a
// stretched rubber band - oscillates multiple times before
// settling, with the amplitude decaying exponentially.
// Penner's defaults:
//   amplitude = 1, period p = 0.3 (×1.5 for InOut to compensate
//   for the half-and-half stitch).
// The exponential decay term is `pow(2, ±10·t)` - the same
// "snap" as expo, modulated by a sine of period p.  Endpoint
// guards (t==0/t==1) keep the curve exact at the boundaries
// since the formula itself is only asymptotically correct there.

pub fn elasticIn(t: f32) f32 {
    if (t == 0.0) {
        return 0.0;
    }
    if (t == 1.0) {
        return 1.0;
    }
    const p: f32 = 0.3;
    const s: f32 = p / 4.0;
    const tm1: f32 = t - 1.0;
    const post_fix: f32 = pow(2.0, 10.0 * tm1);
    return -(post_fix * @sin((tm1 - s) * (2.0 * pi) / p));
}

pub fn elasticOut(t: f32) f32 {
    if (t == 0.0) {
        return 0.0;
    }
    if (t == 1.0) {
        return 1.0;
    }
    const p: f32 = 0.3;
    const s: f32 = p / 4.0;
    return pow(2.0, -10.0 * t) * @sin((t - s) * (2.0 * pi) / p) + 1.0;
}

pub fn elasticInOut(t: f32) f32 {
    if (t == 0.0) {
        return 0.0;
    }
    if (t == 1.0) {
        return 1.0;
    }
    const p: f32 = 0.3 * 1.5;
    const s: f32 = p / 4.0;
    const ts: f32 = t * 2.0; // [0, 2] range
    if (ts < 1.0) {
        const tm1: f32 = ts - 1.0;
        const post_fix: f32 = pow(2.0, 10.0 * tm1);
        return -0.5 * post_fix * @sin((tm1 - s) * (2.0 * pi) / p);
    }
    const tm1: f32 = ts - 1.0;
    const post_fix: f32 = pow(2.0, -10.0 * tm1);
    return post_fix * 0.5 * @sin((tm1 - s) * (2.0 * pi) / p) + 1.0;
}

// ============================================================================
// Tests - endpoint correctness + InOut midpoint sanity
// ============================================================================
// Every easing function should satisfy: ease(0) = 0, ease(1) = 1.
// (Within tolerance for the floating-point identities.)  For
// InOut variants, ease(0.5) should be exactly 0.5 (the curve is
// symmetric about its midpoint).  Back and elastic overshoots are
// allowed but bounded; we don't test them precisely here, just
// that they touch the endpoints and stay finite.
// These tests are the regression net: if anyone changes a
// formula and breaks an endpoint, the test fires immediately.

const eps_endpoint: f32 = 1e-5;
const eps_midpoint: f32 = 1e-5;
const eps_loose: f32 = 1e-3;

test "easings: endpoint identities for all functions" {
    // Every In/Out/InOut maps 0 -> 0 and 1 -> 1.  Linear is its
    // own test below.
    const Easing: type = *const fn (f32) f32;
    const families: [8][3]Easing = .{
        .{ sineIn, sineOut, sineInOut },
        .{ circIn, circOut, circInOut },
        .{ quadIn, quadOut, quadInOut },
        .{ cubicIn, cubicOut, cubicInOut },
        .{ expoIn, expoOut, expoInOut },
        .{ backIn, backOut, backInOut },
        .{ bounceIn, bounceOut, bounceInOut },
        .{ elasticIn, elasticOut, elasticInOut },
    };
    inline for (families) |fam| {
        inline for (fam) |f| {
            try expectApproxEqAbs(@as(f32, 0), f(0), eps_endpoint);
            try expectApproxEqAbs(@as(f32, 1), f(1), eps_endpoint);
        }
    }
}

test "easings: linear is identity" {
    try expectApproxEqAbs(@as(f32, 0), linear(0), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.25), linear(0.25), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.5), linear(0.5), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.75), linear(0.75), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 1), linear(1), eps_endpoint);
}

test "easings: InOut variants hit midpoint exactly" {
    // For non-overshooting In/Out pairs, the InOut midpoint at
    // t=0.5 lands at exactly 0.5 by symmetry.  Back's overshoot
    // makes its midpoint exact too (the overshoot cancels), but
    // bounce and elastic's InOut have phase-related midpoints
    // that don't necessarily hit 0.5.  Test the well-behaved ones.
    try expectApproxEqAbs(@as(f32, 0.5), sineInOut(0.5), eps_midpoint);
    try expectApproxEqAbs(@as(f32, 0.5), circInOut(0.5), eps_midpoint);
    try expectApproxEqAbs(@as(f32, 0.5), quadInOut(0.5), eps_midpoint);
    try expectApproxEqAbs(@as(f32, 0.5), cubicInOut(0.5), eps_midpoint);
    try expectApproxEqAbs(@as(f32, 0.5), expoInOut(0.5), eps_loose);
    try expectApproxEqAbs(@as(f32, 0.5), backInOut(0.5), eps_midpoint);
}

test "easings: known formula values match raylib's reasings.h at t=0.5" {
    // Sanity check: a few specific known values against the
    // expected reference output, catching formula transcription
    // errors.  These are computed from raylib's formulas with
    // (b=0, c=1, d=1, t=0.5).
    try expectApproxEqAbs(@as(f32, 0.25), quadIn(0.5), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.75), quadOut(0.5), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.125), cubicIn(0.5), eps_endpoint);
    try expectApproxEqAbs(@as(f32, 0.875), cubicOut(0.5), eps_endpoint);
    // sineIn(0.5) = 1 - cos(π/4) = 1 - √2/2 ≈ 0.2929
    try expectApproxEqAbs(@as(f32, 0.29289), sineIn(0.5), eps_loose);
    // sineOut(0.5) = sin(π/4) = √2/2 ≈ 0.7071
    try expectApproxEqAbs(@as(f32, 0.70711), sineOut(0.5), eps_loose);
    // circOut(0.5) = sqrt(1 - 0.25) = √0.75 ≈ 0.8660
    try expectApproxEqAbs(@as(f32, 0.86603), circOut(0.5), eps_loose);
}

test "easings: back functions overshoot but stay bounded" {
    // backOut at t≈0.85 overshoots above 1.0 - verify it does
    // overshoot but stays in [-0.2, 1.2] (well within sane
    // bounds; the actual maximum is ~1.1).
    const max_obs: f32 = backOut(0.85);
    try expect(max_obs > 1.0);
    try expect(max_obs < 1.2);

    // backIn at t≈0.15 goes briefly negative - verify.
    const min_obs: f32 = backIn(0.15);
    try expect(min_obs < 0.0);
    try expect(min_obs > -0.2);
}

test "easings: bounce stays non-negative" {
    // Sample 21 evenly-spaced points; none should be < 0.
    var i: u32 = 0;
    while (i <= 20) : (i += 1) {
        const t = float(i) / 20.0;
        try expect(bounceOut(t) >= 0.0);
        try expect(bounceIn(t) >= 0.0);
        try expect(bounceInOut(t) >= 0.0);
    }
}

test "easings: elastic stays finite across the range" {
    // Elastic can swing widely; just verify no NaNs/Infs and
    // bounded amplitude (|out| < 2 is generous; actual max is ~1.3).
    var i: u32 = 0;
    while (i <= 100) : (i += 1) {
        const t = float(i) / 100.0;
        const a = elasticIn(t);
        const b = elasticOut(t);
        const c = elasticInOut(t);
        try expect(isFinite(a));
        try expect(isFinite(b));
        try expect(isFinite(c));
        try expect(@abs(a) < 2.0);
        try expect(@abs(b) < 2.0);
        try expect(@abs(c) < 2.0);
    }
}
