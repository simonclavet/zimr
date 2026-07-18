// array-of-struct as a struct FIELD, plus mixed-type element fields (u8/f32/bool).
const Pt = struct { x: i32, y: i32 };
const Poly = struct { pts: [3]Pt, n: i32 };
const Item = struct { id: u8, val: f32, on: bool };
export fn run_test() i32 {
    var poly = Poly{ .pts = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } }, .n = 3 };
    poly.pts[1].x = 99;
    var s: i32 = poly.n;
    var i: u32 = 0;
    while (i < 3) : (i += 1) s += poly.pts[i].x + poly.pts[i].y;
    if (s != 120) return 1;
    var items = [_]Item{ .{ .id = 1, .val = 1.5, .on = true }, .{ .id = 2, .val = 2.5, .on = false } };
    items[1].on = true;
    var t: i32 = 0;
    for (items) |it| {
        t += @as(i32, it.id) * 100;
        t += @intFromFloat(it.val * 10);
        if (it.on) t += 1;
    }
    if (t != 342) return 2;
    return 0;
}
