// Arithmetic edges that the JS-number model must get exactly right (a regression
// guard, not a past bug): signed @divTrunc/@divFloor/@rem/@mod with NEGATIVE
// operands (JS `/` and `%` differ from all four), arithmetic vs logical right
// shift, and sub-32-bit wrapping (`+%`/`*%` on i8/u8/i16/u16). Self-checks (0=pass).
export fn run_test() i32 {
    // signed division/remainder family with negatives
    const a: i32 = -7;
    const b: i32 = 3;
    if (@divTrunc(a, b) != -2) return 1; // toward zero
    if (@divFloor(a, b) != -3) return 2; // toward -inf
    if (@rem(a, b) != -1) return 3; // sign of dividend
    if (@mod(a, b) != 2) return 4; // sign of divisor
    const c: i32 = 7;
    const d: i32 = -3;
    if (@divTrunc(c, d) != -2) return 5;
    if (@divFloor(c, d) != -3) return 6;
    if (@rem(c, d) != 1) return 7;
    if (@mod(c, d) != -2) return 8;

    // arithmetic (signed) vs logical (unsigned) right shift
    const e: i32 = -256;
    if (e >> 2 != -64) return 9;
    const f: u32 = 0x8000_0000;
    if (f >> 4 != 0x0800_0000) return 10;

    // sub-32-bit wrapping
    var u: u8 = 200;
    u +%= 100;
    if (u != 44) return 11;
    var s: i8 = 100;
    s +%= 50;
    if (s != -106) return 12;
    var w: u16 = 60000;
    w +%= 10000;
    if (w != 4464) return 13;
    var x: i16 = 30000;
    x *%= 2;
    if (x != -5536) return 14;

    return 0;
}
