// @bitCast of/to a <=32-bit packed struct, plus whole-value copy. A packed struct
// lowers to a single integer typedef (`typedef uintN_t bitpack__...;`) kept in a
// heap slot. Whole-value ops (`n = @bitCast(p)`, `p = @bitCast(n)`, `p2 = p`) were
// silently broken: a whole-value READ gave the slot offset while a STORE wrote a
// stray JS scalar — the two never met. Field-level access always worked; this
// guards both. Self-checks (returns 0 on success).
const Pair = packed struct { lo: u16, hi: u16 }; // 32 bits: lo@0..15, hi@16..31
const Bytes = packed struct { a: u8, b: u8, c: u8, d: u8 };

export fn run_test() i32 {
    // struct -> int
    var p = Pair{ .lo = 0x1234, .hi = 0x5678 };
    p.lo +%= 0;
    const n: u32 = @bitCast(p);
    if (n != 0x5678_1234) return 1;

    // int -> struct, read fields
    var raw: u32 = 0x1234_5678;
    raw +%= 0;
    const bs: Bytes = @bitCast(raw);
    if (bs.a != 0x78) return 2;
    if (bs.b != 0x56) return 3;
    if (bs.c != 0x34) return 4;
    if (bs.d != 0x12) return 5;

    // whole-struct copy of a packed struct, then field read
    const p2: Pair = p;
    if (p2.lo != 0x1234 or p2.hi != 0x5678) return 6;

    // field RMW still correct (no regression)
    var p3 = Pair{ .lo = 1, .hi = 2 };
    p3.lo = 9;
    p3.hi +%= 10;
    if (@as(u32, p3.lo) +% @as(u32, p3.hi) *% 100 != 1209) return 7;

    // round-trip: struct -> int -> struct
    const back: Pair = @bitCast(n);
    if (back.lo != 0x1234 or back.hi != 0x5678) return 8;

    return 0;
}
