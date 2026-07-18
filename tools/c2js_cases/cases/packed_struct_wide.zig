// Packed struct wider than 32 bits (60-bit backing -> u64). Field packing now rides
// the 64-bit BigInt path (__ldu64/__st64 + BigInt bit-ops), so reads/writes are exact
// even for the field above bit 40. Self-checking: returns 0 only if every field
// round-trips and writes stay independent. Pre-64-bit-BigInt this emitted a marker.
const P = packed struct { a: u20, b: u20, c: u20 };
export fn run_test() i32 {
    var p: P = .{ .a = 1, .b = 2, .c = 3 };
    if (p.a != 1) return 1;
    if (p.b != 2) return 2;
    if (p.c != 3) return 3;

    // a write to one field leaves the neighbors intact (the RMW mask must be 64-bit)
    p.b = 5;
    if (p.a != 1) return 4;
    if (p.b != 5) return 5;
    if (p.c != 3) return 6;

    // full-width field values (20 bits each), incl. the top field above bit 40
    p.a = 0xFFFFF;
    p.c = 0xABCDE;
    if (p.a != 0xFFFFF) return 7;
    if (p.b != 5) return 8;
    if (p.c != 0xABCDE) return 9;

    // whole-value @bitCast round-trip through the 60-bit backing integer
    const raw: u60 = @bitCast(p);
    const q: P = @bitCast(raw);
    if (q.a != 0xFFFFF or q.b != 5 or q.c != 0xABCDE) return 10;

    return 0;
}
