// Width-dependent bit builtins on 33-63 bit integers: @clz, @ctz (zero case),
// @byteSwap, @bitReverse. The C backend passes the REAL type width as the second
// arg (e.g. zig_clz_u64(x, 48)) while the name suffix is the u64 STORAGE type.
// Pre-fix the lowering used the suffix (64), so @clz(u48) counted leading zeros in
// 64 bits and @byteSwap(u40) swapped 8 bytes instead of 5; __clz also didn't adjust
// for the width. Fix uses the second-arg width and adjusts __clz by (64 - n).
var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // @clz on a u48 with bit 39 set -> 48 - 1 - 39 = 8
    const a: u48 = @intCast(ru(0x008000000000) & 0xFFFFFFFFFFFF);
    if (@clz(a) != 8) return 1;
    if (@ctz(a) != 39) return 2;

    // @clz / @ctz zero cases must equal the width
    const z: u48 = @intCast(ru(0) & 0xFFFFFFFFFFFF);
    if (@clz(z) != 48) return 3;
    if (@ctz(z) != 48) return 4;

    // @popCount over all 48 bits
    const f: u48 = @intCast(ru(0xFFFFFFFFFFFF) & 0xFFFFFFFFFFFF);
    if (@popCount(f) != 48) return 5;

    // @byteSwap on a u40 (5 bytes): 0x1122334455 -> 0x5544332211
    const b: u40 = @intCast(ru(0x1122334455) & 0xFFFFFFFFFF);
    if (@byteSwap(b) != 0x5544332211) return 6;

    // @bitReverse on a u8 inside the odd-width family, plus a u40 round-trip
    if (@bitReverse(@as(u8, 0b00000001)) != 0b10000000) return 7;
    if (@bitReverse(@bitReverse(b)) != b) return 8;

    // @clz on a u33 with only bit 32 set -> 0
    const c: u33 = @intCast(ru(0x100000000) & 0x1FFFFFFFF);
    if (@clz(c) != 0) return 9;
    if (@ctz(c) != 32) return 10;
    return 0;
}
