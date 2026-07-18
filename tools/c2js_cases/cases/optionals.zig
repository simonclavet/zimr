const Box = struct { v: i32, tag: ?u32 };
fn firstEven(a: u32, b: u32) ?u32 {
    if (a % 2 == 0) {
        return a;
    }
    if (b % 2 == 0) {
        return b;
    }
    return null;
}
export fn run_test() i32 {
    if ((firstEven(3, 8) orelse 0) != 8) {
        return 1;
    } // orelse (some)
    if ((firstEven(5, 7) orelse 100) != 100) {
        return 2;
    } // orelse (null)
    var s: i32 = 0;
    if (firstEven(4, 9)) |v| {
        s = @intCast(v);
    } // if |capture| (some)
    if (s != 4) {
        return 3;
    }
    s = 0;
    if (firstEven(1, 3)) |v| {
        s = @intCast(v);
    } else {
        s = -1;
    } // if/else (null)
    if (s != -1) {
        return 4;
    }
    const x: ?u32 = 42;
    if (x.? != 42) {
        return 5;
    } // force-unwrap .?
    const z: ?u32 = null;
    if (z != null) {
        return 6;
    } // value-optional null compare
    var box: Box = .{ .v = 5, .tag = null };
    if (box.tag != null) {
        return 7;
    } // optional struct field == null
    box.tag = 9;
    if ((box.tag orelse 0) != 9) {
        return 8;
    } // optional field set then read
    const np: ?*u32 = null;
    if (np != null) {
        return 9;
    } // pointer-optional null
    return 0;
}
