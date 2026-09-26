// @memset of a non-byte array lowers to a compact C for-loop with a `++` step -
// both the loop form and `++` were unhandled (marker / mis-parse). Also @memcpy
// and a struct-element fill. Self-checks (returns 0 on success).
export fn run_test() i32 {
    var a: [5]i32 = undefined;
    @memset(&a, 7);
    var s: i32 = 0;
    for (a) |x| s +%= x;
    if (s != 35) return 1;

    var b: [6]i32 = undefined;
    @memset(&b, 0); // byte-fill path
    for (b) |x| {
        if (x != 0) return 2;
    }

    const src = [_]i32{ 10, 20, 30, 40 };
    var dst: [4]i32 = undefined;
    @memcpy(&dst, &src);
    var p: i32 = 0;
    for (dst) |x| p = p *% 100 +% x;
    if (p != 10203040) return 3;

    const P = struct { x: i32, y: i32 };
    var pts: [3]P = undefined;
    @memset(&pts, .{ .x = 1, .y = 2 });
    var q: i32 = 0;
    for (pts) |pt| q +%= pt.x *% 10 +% pt.y;
    if (q != 36) return 4; // 3 * (10+2)

    return 0;
}
