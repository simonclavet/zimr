//! Packed structs (`packed struct {...}`) lower to a single integer that the C
//! backend read-modify-writes through a pointer to an ADDRESS-TAKEN scalar local,
//! plus a `memset(&t, 0, sizeof(...))` zero-init. That used to fail outright
//! ("sizeof is not defined"); now a <=32-bit packed struct is heap-backed (so
//! `&t` has a real address) and the bit packing (shr/and/<<) works. run_test()
//! returns 0 on success, else a nonzero code for the first failed check. (Packed
//! structs wider than 32 bits are out of scope and emit a loud marker instead —
//! they would need a true 64-bit heap load/store; see the file header.)

const Flags = packed struct { a: u1, b: u3, c: u4 }; // 8-bit
const RGBA = packed struct { r: u8, g: u8, b: u8, a: u8 }; // 32-bit
const Mix = packed struct { lo: u4, mid: u8, hi: u4 }; // 16-bit

export fn run_test() i32 {
    var f: Flags = .{ .a = 1, .b = 5, .c = 10 };
    f.b = 6;
    if (@as(i32, f.a) + f.b + f.c != 17) return 1; // 1 + 6 + 10

    var c: RGBA = .{ .r = 10, .g = 20, .b = 30, .a = 40 };
    c.g = 99;
    if (@as(i32, c.r) + c.g + c.b + c.a != 179) return 2; // 10 + 99 + 30 + 40

    var m: Mix = .{ .lo = 3, .mid = 200, .hi = 12 };
    var acc: i32 = 0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        m.mid +%= 1;
        acc += m.mid;
    } // 201 + 202 + 203 = 606
    if (acc + @as(i32, m.lo) + m.hi != 621) return 3; // 606 + 3 + 12

    return 0;
}
