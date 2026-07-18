// Slices (`[]T`) lower to a `{ ptr, len }` struct. This exercises the cases
// that matter for real code: scalar-element slices, struct-element slices,
// `.len` in arithmetic, mutation through a slice, a local array used as a
// slice, a string slice, and a slice-range expression (`arr[a..b]`, which is
// pointer arithmetic scaled by the element size). run_test returns 0 on
// success; any non-zero is the failing check number.

const Pt = struct { x: i32, y: i32 };

fn sumI(xs: []const i32) i32 {
    var t: i32 = 0;
    for (xs) |v| {
        t += v;
    }
    return t;
}

fn sumF(xs: []const f32) f32 {
    var t: f32 = 0;
    for (xs) |v| {
        t += v;
    }
    return t;
}

fn dotSum(pts: []const Pt) i32 {
    var s: i32 = 0;
    for (pts) |p| {
        s += p.x * p.y;
    }
    return s;
}

fn scale(xs: []i32, k: i32) void {
    for (xs) |*x| {
        x.* *= k;
    }
}

fn countChar(s: []const u8, c: u8) i32 {
    var n: i32 = 0;
    for (s) |ch| {
        if (ch == c) {
            n += 1;
        }
    }
    return n;
}

export fn run_test() i32 {
    // scalar-element slice + .len
    const data = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    if (sumI(&data) != 31) {
        return 1;
    }
    const sl: []const i32 = &data;
    if (sl.len != 8) {
        return 2;
    }

    // f32-element slice
    const fs = [_]f32{ 1.5, 2.5, 4.0 };
    if (@as(i32, @intFromFloat(sumF(&fs))) != 8) {
        return 3;
    }

    // struct-element slice
    const pts = [_]Pt{ .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 } };
    if (dotSum(&pts) != 26) {
        return 4;
    }

    // mutation through a mutable slice, then read back
    var nums = [_]i32{ 1, 2, 3, 4 };
    scale(&nums, 10);
    var ns: i32 = 0;
    for (nums) |n| {
        ns += n;
    }
    if (ns != 100) {
        return 5;
    }

    // string slice
    const msg = "hello world";
    if (countChar(msg, 'l') != 3) {
        return 6;
    }

    // slice-range expression: arr[1..4] = {20,30,40}
    const arr = [_]i32{ 10, 20, 30, 40, 50 };
    if (sumI(arr[1..4]) != 90) {
        return 7;
    }

    return 0;
}
