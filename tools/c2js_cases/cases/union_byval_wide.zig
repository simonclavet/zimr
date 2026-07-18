// A tagged union with a 64-bit (u64/i64/f64) payload, constructed then passed
// BY VALUE to a function. The Zig C backend builds such a union with a direct
// two-level field store `t.payload.big = v`; pre-fix only single-level
// `t.field = v` was modelled, so the 64-bit payload store was miscompiled into
// a LOAD and the value never reached memory (the callee then read stale bytes).
const U = union(enum) { big: u64, sig: i64, real: f64, small: u32, none: void };

var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}

fn asBits(u: U) u64 {
    return switch (u) {
        .big => |b| b,
        .sig => |s| @bitCast(s),
        .real => |r| @bitCast(r),
        .small => |s| s,
        .none => 0,
    };
}

export fn run_test() i32 {
    if (asBits(.{ .big = ru(0x123456789ABC) }) != 0x123456789ABC) return 1;
    if (asBits(.{ .sig = @bitCast(ru(0xFFFFFFFF00000001)) }) != 0xFFFFFFFF00000001) return 2;
    if (asBits(.{ .real = 3.5 }) != @as(u64, @bitCast(@as(f64, 3.5)))) return 3;
    if (asBits(.{ .small = 0x1234 }) != 0x1234) return 4;
    if (asBits(.none) != 0) return 5;
    return 0;
}
