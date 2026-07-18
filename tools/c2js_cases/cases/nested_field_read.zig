// Reading a NESTED struct field — `s.inner.field` (two-plus levels) — must
// heap-LOAD at the folded byte address. The C backend emits the read as
// `*(&(&S->inner)->a)`; the `*(&X)` read shortcut parsed the inner lvalue with the
// tag-losing postfix parser, computed the address of `inner`, then emitted `->a`
// as a JS PROPERTY access (`(addr).a` -> undefined -> 0) — a silent read
// miscompile. Stores were already correct (they used the tag-tracking lvalue
// walker), so the field looked written but read back as 0. Self-checks (0 = pass).
const A = struct { p: i32, q: i32 };
const B = struct { a: A, r: i32 };
const C = struct { b: B, s: i32 };
var GC: C = .{ .b = .{ .a = .{ .p = 0, .q = 0 }, .r = 0 }, .s = 0 };

export fn run_test() i32 {
    // global, three levels deep
    GC.b.a.p = 1;
    GC.b.a.q = 2;
    GC.b.r = 3;
    GC.s = 4;
    if (GC.b.a.p != 1 or GC.b.a.q != 2) return 1; // the nested read that returned 0
    if (GC.b.r != 3 or GC.s != 4) return 2;

    // local, two levels deep
    var lb: B = .{ .a = .{ .p = 0, .q = 0 }, .r = 0 };
    lb.a.p = 10;
    lb.a.q = 20;
    lb.r = 30;
    if (lb.a.p != 10 or lb.a.q != 20 or lb.r != 30) return 3;

    // force the reads into an arithmetic expression
    const sum = GC.b.a.p * 1000 + GC.b.a.q * 100 + GC.b.r * 10 + GC.s +
        lb.a.p + lb.a.q + lb.r;
    if (sum != 1294) return 4;
    return 0;
}
