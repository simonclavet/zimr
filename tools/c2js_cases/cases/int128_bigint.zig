// PASSES (128-bit via BigInt). u128/i128 exceed JS's 2^53 Number range, so the C
// backend's zig_*_128 helpers are lowered to BigInt. This exercises construction, a
// shift past the 64-bit word boundary, add-with-carry across that boundary, multiply
// into the high word, and bitwise ops. Every extraction is small (<=16 bits / single
// bits), which stays exact through the u64->Number boundary (the lossy-beyond-2^53
// limit only bites a wide @truncate, tracked separately). Self-checking; was the
// `int128_unsupported` xfail. The C backend emits these as runtime helper calls
// (it does not constant-fold 128-bit ops), so this genuinely tests the BigInt path.
export fn run_test() i32 {
    // carry across the 2^64 boundary
    var a: u128 = 0xFFFF_FFFF_FFFF_FFFF; // 2^64 - 1
    a +%= 3; // 2^64 + 2
    if (@as(u32, @intCast(a & 0xFFFF)) != 2) return 1;
    if (@as(u32, @intCast((a >> 64) & 0xF)) != 1) return 2;
    // shift past 64, then mask
    var b: u128 = 1;
    b <<= 70; // 2^70
    b +%= 12345;
    if (@as(u32, @intCast(b & 0xFFFF)) != 12345) return 3; // 2^70 & 0xFFFF == 0
    if (@as(u32, @intCast((b >> 70) & 1)) != 1) return 4;
    // multiply into the high word
    var c: u128 = 0x1_0000_0000; // 2^32
    c *%= 0x1_0000_0000; // 2^64
    if (@as(u32, @intCast((c >> 64) & 0xF)) != 1) return 5;
    // bitwise or / xor / and
    var d: u128 = 0;
    d |= 0xAB;
    d ^= 0x0F; // 0xA4
    d &= 0xFC; // 0xA4
    if (@as(u32, @intCast(d & 0xFF)) != 0xA4) return 6;
    return 0;
}
