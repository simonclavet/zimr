// `@min`/`@max` — and anything the C backend lowers to an INLINE ternary
// `cond ? a : b` — must evaluate the SELECT, not just the condition. The
// transpiler had no ternary parser (it assumed the backend lowered every branch
// to gotos), so `@min`/`@max` silently kept the comparison and dropped both arms
// (an orphaned `a;`). Covers signed operands and unsigned operands ≥ 2^31 (where
// a sign-confused compare would also be wrong), a running reduction, and nested
// `@min`/`@max` (chained ternaries). Self-checks (returns 0 on success).
export fn run_test() i32 {
    // signed
    if (@min(@as(i32, -5), @as(i32, 3)) != -5) return 1;
    if (@max(@as(i32, -5), @as(i32, 3)) != 3) return 2;
    if (@min(@as(i32, 7), @as(i32, 7)) != 7) return 3;

    // unsigned, including a value above 2^31
    const big: u32 = 4_000_000_000;
    const small: u32 = 100;
    if (@min(big, small) != small) return 4;
    if (@max(big, small) != big) return 5;

    // running reduction over a slice
    var lo: i32 = 1000;
    var hi: i32 = -1000;
    const data = [_]i32{ 3, -7, 12, 0, -1, 9 };
    for (data) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    if (lo != -7 or hi != 12) return 6;

    // nested @min/@max -> chained ternaries
    const m = @max(@min(@as(i32, 5), @as(i32, 8)), @min(@as(i32, 2), @as(i32, 9)));
    if (m != 5) return 7; // max(min(5,8)=5, min(2,9)=2) = 5

    return 0;
}
