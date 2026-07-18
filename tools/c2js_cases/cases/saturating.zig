// saturating arithmetic (+| -| *|), unsigned and signed.
export fn run_test() i32 {
    const a: u8 = 200;
    const b: u8 = 100;
    if (a +| b != 255) return 1;
    if (a *| b != 255) return 2;
    if (b -| a != 0) return 3;
    const c: i8 = 100;
    if (c +| @as(i8, 100) != 127) return 4;
    return 0;
}
