// @bitCast between a 64-bit scalar and an array of 32-bit words (and back). The
// Zig C backend lowers these to `memcpy(&dst, &src, 8)`; for the scalar-spill
// idiom a 64-bit value must be staged/read with __st64/__ld*64 (two words). Pre-fix
// it used a 32-bit typed-view (`__HEAPU32[..] = bigint` threw "Cannot convert a
// BigInt value to a number"; the read-back grabbed only the low word).
var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}
fn rw(x: [2]u32) [2]u32 {
    sink +%= x[0];
    return x;
}

export fn run_test() i32 {
    const v: u64 = ru(0xDEADBEEF_CAFEF00D);
    const words: [2]u32 = @bitCast(v);
    const back: u64 = @bitCast(words);
    if (back != v) return 1;
    // little-endian: words[0] = low 32 bits, words[1] = high 32 bits
    if (words[0] != 0xCAFEF00D) return 2;
    if (words[1] != 0xDEADBEEF) return 3;
    // array -> scalar with a runtime-touched array
    const w2 = rw(.{ 0x11112222, 0x33334444 });
    const joined: u64 = @bitCast(w2);
    if (joined != 0x33334444_11112222) return 4;
    return 0;
}
