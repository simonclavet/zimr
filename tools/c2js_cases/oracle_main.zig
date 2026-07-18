// Native-oracle main: runs run_test() and writes its i32 result as decimal to
// stdout via the raw linux write syscall (no std.Io / std.fmt). Appended to a
// copy of the test program so we can diff native ground truth vs transpiled JS.
fn writeDec(v: i32) void {
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
    _ = @import("std").os.linux.write(1, &buf, n);
}
pub fn main() void {
    writeDec(run_test());
}
