// @byteSwap / @bitReverse on a 64-bit value. Pre-fix the __byteswap/__bitreverse
// JS runtime helpers used Number arithmetic (Math.floor(x / Math.pow(256, k)),
// r * 256, ...), so calling them with a BigInt (any u64) threw "Cannot mix BigInt
// and other types" - they never branched on width the way __clz/__ctz/__popcount
// do. References are built from BigInt-safe shifts/masks (explicit byte moves for
// the swap, a bit loop for the reverse) so a wrong value is caught, not just the
// crash.
var sink: u64 = 0;
fn rt(x: u64) u64 {
    sink +%= x;
    return x;
}

fn refSwap(x: u64) u64 {
    return ((x & 0xFF) << 56) | ((x & 0xFF00) << 40) |
        ((x & 0xFF0000) << 24) | ((x & 0xFF000000) << 8) |
        ((x >> 8) & 0xFF000000) | ((x >> 24) & 0xFF0000) |
        ((x >> 40) & 0xFF00) | ((x >> 56) & 0xFF);
}

fn refRev(x: u64) u64 {
    var v: u64 = x;
    var r: u64 = 0;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

export fn run_test() i32 {
    const xs = [_]u64{
        0x0102030405060708, 0xF0F0DEAD0000CAFE, 0x1,
        0xFF,               0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
    };
    var code: i32 = 1;
    for (xs) |x| {
        const v: u64 = rt(x);
        if (@byteSwap(v) != refSwap(v)) return code;
        if (@bitReverse(v) != refRev(v)) return code + 50;
        code += 1;
    }
    return 0;
}
