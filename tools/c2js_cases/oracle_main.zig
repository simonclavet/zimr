// Native-oracle main: runs run_test() and writes its i32 result as decimal to stdout, with no std.fmt. Appended to a
// copy of the test program so we can diff native ground truth vs transpiled JS. It reaches std only through
// `@import("std")` and declares nothing but `writeDec` and `main`, so the case's own names cannot collide with it;
// it writes through std.Io's stdout rather than a system call so it builds for every host (c2js_diff.zig).
fn writeDec(io: @import("std").Io, v: i32) void {
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var x: i64 = v;
    var neg: bool = false;
    if (x < 0) {
        neg = true;
        x = -x;
    }
    var tmp: [24]u8 = undefined;
    var t: usize = 0;
    if (x == 0) {
        tmp[t] = '0';
        t += 1;
    }
    while (x > 0) {
        tmp[t] = @intCast('0' + @as(u8, @intCast(@mod(x, 10))));
        t += 1;
        x = @divTrunc(x, 10);
    }
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    while (t > 0) {
        t -= 1;
        buf[n] = tmp[t];
        n += 1;
    }
    buf[n] = 10;
    n += 1;
    // A failed write leaves the answer empty, which no case's JavaScript answers: the case fails, it is not lost.
    @import("std").Io.File.stdout().writeStreamingAll(io, buf[0..n]) catch {};
}
pub fn main(init: @import("std").process.Init) void {
    writeDec(init.io, run_test());
}
