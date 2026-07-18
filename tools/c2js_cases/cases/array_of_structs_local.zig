// arrays of structs (local): compound-literal init, element-field store, index
// read, and `for`-by-value iteration. The init emitted markers; the struct-copy
// index / `for` path silently mis-strided by the int size instead of the struct.
const P = struct { x: i32, y: i32 };
export fn run_test() i32 {
    var arr = [_]P{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } };
    if (arr[0].x != 1 or arr[2].y != 6) return 1;
    arr[1].x = 99;
    const i: u32 = 2;
    arr[i].y = 88;
    if (arr[1].x != 99 or arr[2].y != 88) return 2;
    var sum_idx: i32 = 0;
    var k: u32 = 0;
    while (k < 3) : (k += 1) sum_idx += arr[k].x + arr[k].y;
    if (sum_idx != 199) return 3;
    var sum_for: i32 = 0;
    for (arr) |p| sum_for += p.x + p.y;
    if (sum_for != 199) return 4;
    return 0;
}
