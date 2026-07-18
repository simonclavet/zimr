// integer-field packed structs (always worked; locked in as the control for the
// packed-bool fix).
const P = packed struct { a: u4, b: u4, c: u8 };
export fn run_test() i32 {
    var p: P = .{ .a = 3, .b = 5, .c = 200 };
    p.b = 9;
    if (p.a != 3 or p.b != 9 or p.c != 200) return 1;
    return 0;
}
