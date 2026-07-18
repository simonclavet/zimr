// @addWithOverflow / @mulWithOverflow tuple results.
export fn run_test() i32 {
    const r = @addWithOverflow(@as(u8, 200), @as(u8, 100));
    if (r[0] != 44 or r[1] != 1) return 1;
    const m = @mulWithOverflow(@as(u8, 20), @as(u8, 20));
    if (m[0] != 144 or m[1] != 1) return 2; // 400 & 0xFF
    return 0;
}
