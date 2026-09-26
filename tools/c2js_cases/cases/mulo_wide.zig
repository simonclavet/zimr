//! @mulWithOverflow on integers wide enough that the TRUE product exceeds 2^53.
//! The wrapped (stored) result was computed with a plain JS `*`, which loses low
//! bits once the product passes 2^53, so the truncated value was silently wrong
//! for large 32-bit operands - even though the regular `*%` multiply (Math.imul)
//! was correct. The overflow BIT was fine (a float multiply preserves the
//! product's magnitude). The fix computes the stored value with Math.imul for a
//! <=32-bit multiply, keeping the magnitude compare for the overflow bit.
//!
//! Self-checking: the @mulWithOverflow VALUE is cross-checked against `*%` (the
//! independently-correct wrapping multiply), and the overflow BIT against cases
//! whose overflow is known by construction. run_test() returns 0 on success.

export fn run_test() i32 {
    // --- u32: products well beyond 2^53 ---
    {
        var a: u32 = 0xFFFFFFFF;
        var k: u32 = 0;
        while (k < 12) : (k += 1) {
            const r = @mulWithOverflow(a, a);
            const w: u32 = a *% a; // known-correct wrapping product
            if (r[0] != w) return 1; // wrapped value must match
            // a*a for a>=0x10000 always exceeds 2^32 -> overflow expected here
            if (a >= 0x10000 and r[1] != 1) return 2;
            a = r[0] +% 0x9E3779B1;
        }
    }
    // --- i32 (signed) large operands ---
    {
        var a: i32 = 0x4DEECE66;
        var k: u32 = 0;
        while (k < 10) : (k += 1) {
            const r = @mulWithOverflow(a, a);
            const w: i32 = a *% a;
            if (r[0] != w) return 3;
            a = r[0] +% 0x13571357;
        }
    }
    // --- exactness controls: no-overflow and small operands ---
    {
        const r0 = @mulWithOverflow(@as(u32, 3), @as(u32, 4));
        if (r0[0] != 12 or r0[1] != 0) return 4;
        const r1 = @mulWithOverflow(@as(u32, 0x10000), @as(u32, 0x10000)); // 2^32
        if (r1[1] != 1 or r1[0] != 0) return 5; // wraps to 0, overflow set
    }
    // --- u16 / u8 (float-exact, must still be right) ---
    {
        var a: u16 = 60000;
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            const r = @mulWithOverflow(a, a);
            if (r[0] != a *% a) return 6;
            a = r[0] +% 13;
        }
        const r8 = @mulWithOverflow(@as(u8, 200), @as(u8, 200));
        if (r8[0] != (@as(u8, 200) *% @as(u8, 200)) or r8[1] != 1) return 7;
    }
    return 0;
}
