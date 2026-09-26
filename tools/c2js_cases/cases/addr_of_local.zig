//! Address-of a local SCALAR (`&w` for a plain `var w`) - the C out-parameter
//! idiom `f(&x)`. Such a local is heap-backed like an aggregate, so `&w` is a
//! real address: reads load from its slot and writes store to it (via the same
//! __ld/st-or-view path, so 64-bit works too). `&x` inside the bitcast/copy
//! idioms (`memcpy(&a,&b,n)`) is deliberately NOT treated this way - those temps
//! stay plain SSA values. run_test() returns 0 on success, else a code.

fn setU64(p: *u64, v: u64) void {
    p.* = v;
}
fn addU64(p: *u64, v: u64) void {
    p.* +%= v;
}
fn swap(a: *i32, b: *i32) void {
    const t: i32 = a.*;
    a.* = b.*;
    b.* = t;
}
fn divmod(a: u32, b: u32, q: *u32, r: *u32) void {
    q.* = a / b;
    r.* = a % b;
}
fn accumF32(p: *f32, v: f32) void {
    p.* += v;
}

export fn run_test() i32 {
    // u64 out-param above 2^32 (write then read-modify-write through the pointer)
    var w: u64 = 0;
    setU64(&w, 1099511627776); // 2^40
    addU64(&w, 7);
    if (w != 1099511627783) return 1;

    // two i32 pointers: swap reads and writes through both
    var x: i32 = 7;
    var y: i32 = -3;
    swap(&x, &y);
    if (x != -3 or y != 7) return 2;

    // multiple out-params + a direct write to a heap-backed scalar
    var q: u32 = 0;
    var r: u32 = 0;
    divmod(47, 5, &q, &r);
    q += 1; // direct (non-pointer) write to a heap-backed scalar
    if (q != 10 or r != 2) return 3;

    // f32 out-param accumulated in a loop
    var s: f32 = 1.0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) accumF32(&s, 0.5);
    if (s != 2.5) return 4;

    return 0;
}
