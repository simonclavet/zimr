// 64-bit integers are exact past 2^53 (lowered to BigInt). Self-checking: every
// branch returns nonzero on a precision/wrap error, 0 when all hold. Pre-BigInt
// (Number ABI) these silently lost the low bits beyond 2^53 and returned nonzero.
export fn run_test() i32 {
    // add past 2^53 keeps the low bits
    var x: u64 = 9007199254740993; // 2^53 + 1
    x +%= 2; // 2^53 + 3
    if ((x & 0xFFFF) != 3) return 1;
    if (x != 9007199254740995) return 2;

    // wraparound at the full 64-bit boundary
    var y: u64 = 0xFFFFFFFFFFFFFFFF;
    y +%= 1;
    if (y != 0) return 3;

    // multiply landing above 2^53
    var z: u64 = 0x0020000000000000; // 2^53
    z *%= 3;
    if (z != 0x0060000000000000) return 4;

    // signed 64-bit arithmetic shift keeps the sign
    var s: i64 = -1;
    s >>= 1; // still -1
    if (s != -1) return 5;

    // a high u64 narrowed to u32 keeps the low 32 bits
    const w: u64 = 0xDEADBEEF_CAFEF00D;
    if (@as(u32, @truncate(w)) != 0xCAFEF00D) return 6;
    // and the high half via a shift
    if (@as(u32, @truncate(w >> 32)) != 0xDEADBEEF) return 7;

    // @bitCast between 64-bit scalars (i64<->u64, f64<->u64) reinterprets the bits
    if (@as(u64, @bitCast(s)) != 0xFFFFFFFFFFFFFFFF) return 8;
    var u: u64 = 0x123456789ABCDEF0;
    if (@as(i64, @bitCast(u)) != 0x123456789ABCDEF0) return 9;
    const f: f64 = 1.0; // IEEE-754 bits 0x3FF0000000000000
    if (@as(u64, @bitCast(f)) != 0x3FF0000000000000) return 10;
    const g: f64 = @bitCast(@as(u64, 0x3FF0000000000000));
    if (g != 1.0) return 11;

    _ = &u;
    return 0;
}
