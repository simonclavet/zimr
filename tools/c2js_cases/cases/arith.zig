//! Arithmetic semantics: wrapping ops, shifts, floored div/mod, float math and
//! comparisons (the 3-way-compare bug that pinned the demo's ball to a corner).
//! run_test() returns 0 on success, or a nonzero code identifying the first
//! failed check.

fn eqf(a: f64, b: f64) bool {
    const d: f64 = a - b;
    return (if (d < 0) -d else d) < 1e-9;
}

export fn run_test() i32 {
    // wrapping add/mul on u32
    var x: u32 = 0xffff_ffff;
    x +%= 1;
    if (x != 0) {
        return 1;
    }
    var y: u32 = 0x1000_0000;
    y *%= 16; // 0x1_0000_0000 -> wraps to 0
    if (y != 0) {
        return 2;
    }

    // shifts
    var s: u32 = 1;
    s <<= 31;
    if (s != 0x8000_0000) {
        return 3;
    }
    var r: u32 = 0x8000_0000;
    r >>= 31;
    if (r != 1) {
        return 4;
    }

    // floored division/modulo (sign follows divisor) - distinct from C truncation
    if (@divFloor(@as(i32, -7), 3) != -3) {
        return 5;
    }
    if (@mod(@as(i32, -7), 3) != 2) {
        return 6;
    }
    if (@divTrunc(@as(i32, -7), 3) != -2) {
        return 7;
    }
    if (@rem(@as(i32, -7), 3) != -1) {
        return 8;
    }

    // float arithmetic
    if (!eqf(0.1 + 0.2, 0.30000000000000004)) {
        return 9;
    }
    if (!eqf(@as(f32, 3.0) * @as(f32, 0.5), 1.5)) {
        return 10;
    }

    // float comparisons (must be true 3-way ordering, not always-false)
    const a: f32 = 2.5;
    const b: f32 = 9.0;
    if (!(a < b)) {
        return 11;
    }
    if (a > b) {
        return 12;
    }
    if (!(b > a)) {
        return 13;
    }
    var neg: f32 = 5.0;
    neg = -neg;
    if (!eqf(neg, -5.0)) {
        return 14;
    }

    // int<->float conversions
    if (@as(i32, @intFromFloat(@as(f32, 3.9))) != 3) {
        return 15;
    }
    if (!eqf(@as(f64, @floatFromInt(@as(i32, 7))), 7.0)) {
        return 16;
    }

    return 0;
}
