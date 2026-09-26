// slice of structs: arr[0..] then for(s)|p| reads and s[i].field writes -
// the slice element pointer points at a struct, indexed by struct size.
const P = struct { x: i32, y: i32 };
export fn run_test() i32 {
    var arr = [_]P{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } };
    const s: []P = arr[0..];
    var sum: i32 = 0;
    for (s) |p| sum += p.x * 10 + p.y;
    var i: usize = 0;
    while (i < s.len) : (i += 1) s[i].x += 100;
    var sum2: i32 = 0;
    for (s) |p| sum2 += p.x;
    if (sum + sum2 != 411) return 1;
    return 0;
}
