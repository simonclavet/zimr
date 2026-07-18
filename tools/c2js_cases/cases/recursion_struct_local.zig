// PASSES (shadow stack). An address-taken local STRUCT in a recursive function: each call
// reads both fields AFTER recursing. (a + b) = 3n per level, so the total is 3*N(N+1)/2;
// a shared static slot would read the innermost call's fields. Self-checking vs closed form.
const Box = struct { a: u32, b: u32 };
fn rec(n: u32) u32 {
    var box: Box = .{ .a = n, .b = n *% 2 };
    const p: *Box = &box;
    if (n == 0) return p.a +% p.b;
    const sub: u32 = rec(n - 1);
    return p.a +% p.b +% sub;
}
export fn run_test() i32 {
    const n: u32 = 100;
    const want: u32 = 3 *% (n *% (n +% 1) / 2);
    return if (rec(n) == want) 0 else 1;
}
