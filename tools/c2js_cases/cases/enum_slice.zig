// Slice of a sub-32-bit enum (`[]enum(u8)`). The slice lowers to `{ enumTag* ptr;
// usize len; }`; the slice POINTER is built with the correct 1-byte element stride,
// but the pointee element of the `ptr` field was sized at the default 4 bytes (the
// enum-tag typedef isn't resolved in struct layout), so `slice.ptr[i]` strided by 4
// over 1-byte-packed enum storage - reading the wrong elements. Fix resolves the
// pointer field's pointee to the enum's real width.
const Color = enum(u8) { red, green, blue, alpha };
var arr: [6]Color = .{ .red, .green, .blue, .alpha, .red, .blue };
var sink: usize = 0;
fn ri(x: usize) usize {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    const lo = ri(1);
    const hi = ri(5);
    const s = arr[lo..hi]; // {green, blue, alpha, red}
    var t: u32 = 0;
    for (s) |c| {
        const d: u32 = @backingInt(c);
        t = t * 10 + d;
    }
    if (t != 1230) return 1; // green=1, blue=2, alpha=3, red=0

    // index a slice element directly
    if (s[0] != .green) return 2;
    if (s[3] != .red) return 3;
    if (s.len != 4) return 4;
    return 0;
}
