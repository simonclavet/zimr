// optional struct (?Struct) payload + null.
const P = struct { x: i32, y: i32 };
export fn run_test() i32 {
    var o: ?P = .{ .x = 5, .y = 9 };
    var s: i32 = 0;
    if (o) |v| s += v.x * 10 + v.y;
    if (s != 59) return 1;
    o = null;
    if (o != null) return 2;
    return 0;
}
