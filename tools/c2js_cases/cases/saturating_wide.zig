// Saturating +| -| *| <<| on 64-bit operands. Pre-fix the __clampu/__clampi
// helpers used Number bounds (clamping u64 to 2^53-1, computing i64 bounds via
// Math.pow) and returned a Number for an out-of-range value while passing a
// BigInt through otherwise — so the emitted JS threw "Cannot convert ... to a
// BigInt" / "Cannot mix BigInt and other types". The saturating <<| additionally
// did `BigInt * Math.pow(2, b)`. References use the *WithOverflow builtins (a
// different lowering) and pick the saturation bound on overflow.
const MAXU: u64 = 0xFFFFFFFFFFFFFFFF;
const MAXI: i64 = 0x7FFFFFFFFFFFFFFF;
const MINI: i64 = -0x8000000000000000;

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

fn refAddU(a: u64, b: u64) u64 {
    const r = @addWithOverflow(a, b);
    return if (r[1] == 1) MAXU else r[0];
}
fn refSubU(a: u64, b: u64) u64 {
    const r = @subWithOverflow(a, b);
    return if (r[1] == 1) 0 else r[0];
}
fn refMulU(a: u64, b: u64) u64 {
    const r = @mulWithOverflow(a, b);
    return if (r[1] == 1) MAXU else r[0];
}
fn refShlU(a: u64, b: u6) u64 {
    const r = @shlWithOverflow(a, b);
    return if (r[1] == 1) MAXU else r[0];
}

fn refAddI(a: i64, b: i64) i64 {
    const r = @addWithOverflow(a, b);
    if (r[1] == 0) return r[0];
    return if (a > 0) MAXI else MINI;
}
fn refSubI(a: i64, b: i64) i64 {
    const r = @subWithOverflow(a, b);
    if (r[1] == 0) return r[0];
    return if (a >= 0) MAXI else MINI;
}

export fn run_test() i32 {
    var code: i32 = 1;
    const ua = [_]u64{ 0xFFFFFFFFFFFFFF00, 5, 0x100000000, 0xDEADBEEF, MAXU };
    const ub = [_]u64{ 0x1000, 99, 0x100000000, 0x10, 1 };
    for (ua, ub) |a0, b0| {
        const a = ru(a0);
        const b = ru(b0);
        if ((a +| b) != refAddU(a, b)) return code;
        if ((a -| b) != refSubU(a, b)) return code + 20;
        if ((a *| b) != refMulU(a, b)) return code + 40;
        code += 1;
    }
    // saturating shift-left
    if ((ru(0xFF) <<| 60) != refShlU(0xFF, 60)) return 70;
    if ((ru(1) <<| 63) != refShlU(1, 63)) return 71;
    if ((ru(0xFFFF) <<| 8) != refShlU(0xFFFF, 8)) return 72;
    // signed saturating add/sub/mul
    if ((ri(0x7FFFFFFFFFFFFF00) +| ri(0x1000)) != refAddI(0x7FFFFFFFFFFFFF00, 0x1000)) return 80;
    if ((ri(-0x7FFFFFFFFFFFFF00) -| ri(0x1000)) != refSubI(-0x7FFFFFFFFFFFFF00, 0x1000)) return 81;
    if ((ri(-5) *| ri(3)) != -15) return 82;
    if ((ri(1000000) *| ri(1000000000000000)) != MAXI) return 83;
    return 0;
}
