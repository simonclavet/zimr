// Non-power-of-2 integer widths in the 33-63 bit range (u40, u48, i40). These live
// in int64_t/uint64_t C storage and are BigInts in the JS model. Pre-fix the wrap
// helper masked them with a Number literal (`x & 1099511627775`), which threw
// "cannot mix BigInt and other types" against the BigInt value - triggered by a
// @truncate / @bitCast to such a width (the C backend lowers those via
// zig_wrap_u64(x, bits)). Fix masks via asUintN/asIntN at the real bit width.
var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // @truncate u64 -> u40 (BigInt value, 40-bit mask)
    const raw: u40 = @truncate(ru(0x12_FFFFFFFFFF)); // low 40 bits = 0xFFFFFFFFFF
    if (raw != 0xFFFFFFFFFF) return 1;

    // @bitCast u40 <-> i40 (all-ones -> -1)
    const sgn: i40 = @bitCast(raw);
    if (sgn != -1) return 2;
    const back: u40 = @bitCast(sgn);
    if (back != 0xFFFFFFFFFF) return 3;

    // u48 wrapping arithmetic at the 48-bit boundary
    const c: u48 = @intCast(ru(0xFFFFFFFFFFFF) & 0xFFFFFFFFFFFF); // max u48
    if (c +% 1 != 0) return 4; // wraps
    if (c +% 0x100 != 0xFF) return 5;

    // i40 negative arithmetic + cast to u64
    const n: i40 = @intCast(@as(i64, @bitCast(ru(@bitCast(@as(i64, -1000000))))));
    if (n != -1000000) return 6;
    const u: u64 = @bitCast(@as(i64, n));
    if (u != @as(u64, @bitCast(@as(i64, -1000000)))) return 7;

    // a u33 (just over the 32-bit boundary)
    const big33: u33 = @intCast(ru(0x1_80000000) & 0x1FFFFFFFF); // 2^32 + 2^31
    if (big33 != 0x180000000) return 8;
    if (big33 +% 0x80000000 != 0x200000000 & 0x1FFFFFFFF) return 9; // wraps to 0

    return 0;
}
