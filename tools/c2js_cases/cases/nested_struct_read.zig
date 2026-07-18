// 2- and 3-level nested struct field reads must return VALUES, not addresses
// (the old Q1 "returns the field address" gap — now fixed; locked in here).
const Inner = struct { b: i32, c: i32 };
const Mid = struct { inner: Inner, d: i32 };
const Outer = struct { mid: Mid, e: i32 };
export fn run_test() i32 {
    var g: Outer = undefined;
    g.mid.inner.b = 5;
    g.mid.inner.c = 7;
    g.mid.d = 9;
    g.e = 3;
    if (g.mid.inner.b != 5 or g.mid.inner.c != 7 or g.mid.d != 9 or g.e != 3) return 1;
    const s: i32 = g.mid.inner.b * 1000 + g.mid.inner.c * 100 + g.mid.d * 10 + g.e;
    if (s != 5793) return 2;
    return 0;
}
