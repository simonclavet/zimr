// Passing a slice by value (ptr+len) to a function and iterating it. (Once
// listed as a gap; verified working and locked in here.)
fn sum(s: []const i32) u32 {
    var r: u32 = 0;
    for (s) |v| r +%= @as(u32, @bitCast(v));
    return r;
}
export fn run_test() i32 {
    const a = [_]i32{ 3, 4, 5 };
    if (sum(a[0..]) != 12) return 1;
    if (sum(a[1..]) != 9) return 2;
    return 0;
}
