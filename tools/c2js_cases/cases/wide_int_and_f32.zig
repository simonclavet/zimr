//! 64-bit integer arithmetic within 2^53 (mul/shl/shr/div/mod — these used to be
//! computed in 32 bits via Math.imul / JS `<<` / `>>`, wrong above 2^32) and f32
//! single-precision rounding (f32 math used to run at f64 precision, off by an
//! ULP). run_test() returns 0 on success, or a nonzero code for the first failed
//! check. Loop-driven so the ops survive into the C (aren't constant-folded).

export fn run_test() i32 {
    // 64-bit multiply: 3^20 = 3_486_784_401 (> 2^32, < 2^53)
    var p: u64 = 1;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        p *%= 3;
    }
    if (p != 3_486_784_401) return 1;

    // 64-bit shift-left: 1 << 40 = 2^40
    var s: u64 = 1;
    var j: u32 = 0;
    while (j < 40) : (j += 1) {
        s <<= 1;
    }
    if (s != 1_099_511_627_776) return 2;

    // 64-bit shift-right: 2^45 >> 40 = 2^5 = 32
    var t: u64 = 1;
    var a: u32 = 0;
    while (a < 45) : (a += 1) {
        t *%= 2;
    }
    var b: u32 = 0;
    while (b < 40) : (b += 1) {
        t >>= 1;
    }
    if (t != 32) return 3;

    // 64-bit add + div + mod within 2^53
    var v: u64 = 1;
    var c: u32 = 0;
    while (c < 42) : (c += 1) {
        v *%= 2;
    }
    v +%= 7; // 2^42 + 7 = 4_398_046_511_111
    if (v / 1_000_000 != 4_398_046) return 4;
    if (v % 1_000_000 != 511_111) return 5;

    // f32: 0.1 added ten times is NOT 1.0 in single precision — its rounded bit
    // pattern is 0x3F800001 (slightly above 1.0); f64 precision gives < 1.0.
    var f: f32 = 0.0;
    var d: u32 = 0;
    while (d < 10) : (d += 1) {
        f += 0.1;
    }
    if (@as(u32, @bitCast(f)) != 0x3F800001) return 6;

    // f32 sqrt is rounded to single precision (sqrt(2) in f32 = 0x3FB504F3).
    const q: f32 = @sqrt(@as(f32, 2.0));
    if (@as(u32, @bitCast(q)) != 0x3FB504F3) return 7;

    return 0;
}
