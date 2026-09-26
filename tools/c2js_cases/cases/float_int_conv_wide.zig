// @floatFromInt / @intFromFloat across the 64-bit boundary. i64/u64 are BigInt
// in the JS model; pre-fix the int->float cast was identity (leaving a BigInt
// where a float was expected) and the float->int cast produced a Number into a
// BigInt context - both threw "Cannot mix/convert BigInt" in the emitted JS.
var su: u64 = 0;
fn ru(x: u64) u64 {
    su +%= x;
    return x;
}
var si: i64 = 0;
fn ri(x: i64) i64 {
    si +%= x;
    return x;
}
var sf: f64 = 0;
fn rf(x: f64) f64 {
    sf += x;
    return x;
}

export fn run_test() i32 {
    // int -> float
    if (@as(f64, @floatFromInt(ru(0x100000000))) != 4294967296.0) return 1;
    if (@as(f64, @floatFromInt(ri(-1000000000000))) != -1000000000000.0) return 2;
    if (@as(f64, @floatFromInt(ru(9007199254740992))) != 9007199254740992.0) return 3;
    // float -> int (i64/u64)
    if (@as(u64, @intFromFloat(rf(4294967296.0))) != 0x100000000) return 4;
    if (@as(i64, @intFromFloat(rf(-1000000000000.0))) != -1000000000000) return 5;
    if (@as(u64, @intFromFloat(rf(9007199254740992.0))) != 9007199254740992) return 6;
    // round-trip u64 -> f64 -> u64
    const x: u64 = ru(0xDEADBEEF);
    const f: f64 = @floatFromInt(x);
    if (@as(u64, @intFromFloat(f)) != 0xDEADBEEF) return 7;
    return 0;
}
