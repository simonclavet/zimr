//! Signed sub-32-bit packed-struct bitfields (`i7`, `i3`, `i9`, `i13`) read back
//! WITHOUT sign extension - a negative field read as its raw unsigned bits
//! (e.g. i7 -3 -> 125): silent, 0 markers. The C backend extracts the field and
//! calls `zig_wrap_iN(x, UINT8_C(width))`; the transpiler parsed the leading
//! token (`UINT8_C`) of the width arg instead of the unwrapped number, so the
//! width silently defaulted to 32 and the `<<(32-w)>>(32-w)` sign-extension
//! collapsed to a no-op. Fixed by parsing the width from the unwrapped
//! expression. All fields here fit within 32 bits (the supported range; a wider
//! packed struct is the separate `packed_struct_wide` xfail). Read at RUNTIME so
//! the wrap path is exercised. run_test() returns 0 on success.

const P1 = packed struct { a: i7, b: u9, c: i16 }; // 32 bits
const P2 = packed struct { a: i3, b: i9, c: i13, d: u7 }; // 32 bits

export fn run_test() i32 {
    var p: P1 = .{ .a = -3, .b = 300, .c = -1000 };
    _ = &p;
    if (@as(i32, p.a) != -3) return 1; // signed 7-bit, negative
    if (@as(i32, p.b) != 300) return 2; // unsigned control
    if (@as(i32, p.c) != -1000) return 3; // signed 16-bit, negative

    p.a = 60; // positive into the signed field
    p.c = 2000;
    if (@as(i32, p.a) != 60) return 4;
    if (@as(i32, p.c) != 2000) return 5;
    p.a = -1; // all 7 bits set
    if (@as(i32, p.a) != -1) return 6;

    var q: P2 = .{ .a = -2, .b = -200, .c = -3000, .d = 100 };
    _ = &q;
    if (@as(i32, q.a) != -2) return 7; // i3
    if (@as(i32, q.b) != -200) return 8; // i9
    if (@as(i32, q.c) != -3000) return 9; // i13
    if (@as(i32, q.d) != 100) return 10; // u7 control
    q.b = 100;
    if (@as(i32, q.b) != 100) return 11; // positive into i9
    return 0;
}
