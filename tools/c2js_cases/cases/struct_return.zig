// struct returned by value from a function.
const P = struct { x: i32, y: i32 };
fn mk(a: i32) P {
    return .{ .x = a, .y = a * 3 };
}
export fn run_test() i32 {
    const p: P = mk(7);
    if (p.x != 7 or p.y != 21) return 1;
    return 0;
}
