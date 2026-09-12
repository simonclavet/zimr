// @abs on a 64-bit signed integer. Pre-fix the transpiler emitted Math.abs(x),
// which throws on a BigInt. Reference: negate-and-select in BigInt-safe i64
// (avoiding the i64-min edge, which @abs would promote past i64 range).
var sink: i64 = 0;
fn rt(x: i64) i64 {
    sink +%= x;
    return x;
}
fn refAbs(x: i64) u64 {
    return if (x < 0) @as(u64, @intCast(-x)) else @as(u64, @intCast(x));
}
export fn run_test() i32 {
    const xs = [_]i64{ -0x123456789A, 0x123456789A, -1, 0, 0x7FFFFFFFFFFFFFFF, -0x7FFFFFFFFFFFFFFF };
    var code: i32 = 1;
    for (xs) |x0| {
        const x = rt(x0);
        if (@abs(x) != refAbs(x)) return code;
        code += 1;
    }
    return 0;
}
