// @min / @max with a NaN operand. Zig's @min/@max ignore NaN — they return the
// non-NaN operand (LLVM minnum/maxnum / C fmin/fmax semantics). The C backend
// lowers these to zig_min_f64 / zig_max_f64, which were mapped to JS Math.min /
// Math.max — and those return NaN if EITHER argument is NaN, so `@min(x, nan)`
// came back NaN instead of x. Fixed with NaN-ignoring __fmin/__fmax helpers.
var sink: f64 = 0;
fn rf(x: f64) f64 {
    sink += x;
    return x;
}

export fn run_test() i32 {
    const z = rf(0.0);
    const nan = z / z;
    const x = rf(5.0);

    const mn1 = @min(x, nan);
    const mx1 = @max(x, nan);
    const mn2 = @min(nan, x); // order shouldn't matter
    const mx2 = @max(nan, x);
    if (mn1 != 5.0) return 1;
    if (mx1 != 5.0) return 2;
    if (mn2 != 5.0) return 3;
    if (mx2 != 5.0) return 4;
    // results must not be NaN
    if (mn1 != mn1 or mx1 != mx1 or mn2 != mn2 or mx2 != mx2) return 5;

    // both NaN -> NaN
    const bb = @min(nan, nan);
    if (bb == bb) return 6;

    // normal (non-NaN) min/max unaffected
    if (@min(rf(3.0), rf(7.0)) != 3.0) return 7;
    if (@max(rf(3.0), rf(7.0)) != 7.0) return 8;
    if (@min(rf(-2.0), rf(-9.0)) != -9.0) return 9;
    return 0;
}
