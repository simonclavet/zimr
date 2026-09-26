// struct-by-value out of an array: `var s = pts[i]` (copy out) and `pts[i] = s`
// (store back) must stride by the element struct's WHOLE size. The whole-struct
// deref/copy path computed its pointer stride from the scalar elemSize (4)
// instead of sizeof(elem), so a copy of pts[1] read pts[0].y into s.x and
// pts[1].x into s.y - a silent miscompile. Self-checks (returns 0 on success).
const Pt = struct { x: i32, y: i32 };

export fn run_test() i32 {
    var pts = [_]Pt{ .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 40 }, .{ .x = 50, .y = 60 } };

    // copy element 1 out by value
    var s = pts[1];
    if (s.x != 30 or s.y != 40) return 1;

    // mutating the copy must not disturb the source
    s.x = 999;
    if (pts[1].x != 30 or pts[1].y != 40) return 2;

    // whole-struct store of the (mutated) copy into element 2
    pts[2] = s;
    if (pts[2].x != 999 or pts[2].y != 40) return 3;

    // element 0 untouched throughout
    if (pts[0].x != 10 or pts[0].y != 20) return 4;

    // runtime-indexed copy-out in a loop
    var i: usize = 0;
    var sum: i32 = 0;
    while (i < 3) : (i += 1) {
        const e: Pt = pts[i];
        sum +%= e.x +% e.y;
    }
    if (sum != 10 + 20 + 30 + 40 + 999 + 40) return 5;
    return 0;
}
