// tagged union with a struct payload + switch capture.
const U = union(enum) { a: i32, b: struct { x: i32, y: i32 } };
export fn run_test() i32 {
    var u: U = .{ .b = .{ .x = 5, .y = 7 } };
    var s: i32 = 0;
    switch (u) {
        .a => |v| s = v,
        .b => |p| s = p.x * 10 + p.y,
    }
    if (s != 57) return 1;
    u = .{ .a = 42 };
    switch (u) {
        .a => |v| s += v,
        .b => |p| s += p.x,
    }
    if (s != 99) return 2;
    return 0;
}
