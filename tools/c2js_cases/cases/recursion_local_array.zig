// PASSES (shadow stack). A local array in a recursive function is address-taken, so it
// lives in linear memory. Each call stores n, recurses, then reads buf[0] back AFTER the
// call and adds the sub-result; the reads must sum to the Gauss total N(N+1)/2. A single
// shared static slot (the pre-shadow-stack bug) would read the innermost call (0) at every
// level and sum to 0. Self-checking against the closed form (no hand-written magic number).
fn rec(n: u32) u32 {
    var buf: [2]u32 = .{ 0, 0 };
    buf[0] = n;
    if (n == 0) return buf[0];
    const sub: u32 = rec(n - 1);
    return buf[0] +% sub;
}
export fn run_test() i32 {
    const n: u32 = 200;
    const want: u32 = n *% (n +% 1) / 2;
    return if (rec(n) == want) 0 else 1;
}
