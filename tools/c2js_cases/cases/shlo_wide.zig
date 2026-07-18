// @shlWithOverflow on 64-bit and 32-bit. Pre-fix there was no handler for the
// zig_shlo_TN helper, so it hit the unhandled-C marker and the result was 0.
// References build the wrapped value and the overflow flag independently.
var su: u64 = 0;
fn ru(x: u64) u64 { su +%= x; return x; }
var sw: u32 = 0;
fn rw(x: u32) u32 { sw +%= x; return x; }

export fn run_test() i32 {
    var code: i32 = 1;
    // u64
    const c64 = [_]struct { a: u64, b: u6 }{
        .{ .a = 0xFF, .b = 60 }, .{ .a = 1, .b = 63 }, .{ .a = 0xFFFF, .b = 8 }, .{ .a = 0x1, .b = 0 },
    };
    for (c64) |c| {
        const a = ru(c.a);
        const r = @shlWithOverflow(a, c.b);
        const wrapped: u64 = a << c.b; // wrapping shl (truncates to 64)
        const did: u1 = blk: {
            if (c.b == 0) break :blk 0;
            const sh: u6 = @intCast(64 - @as(u32, c.b));
            break :blk if ((a >> sh) != 0) 1 else 0;
        };
        if (r[0] != wrapped) return code;
        if (r[1] != did) return code + 30;
        code += 1;
    }
    // u32
    const a32: u32 = rw(0xFF);
    const r32 = @shlWithOverflow(a32, @as(u5, 28));
    if (r32[0] != (a32 << 28)) return 60;
    if (r32[1] != 1) return 61; // 0xFF<<28 drops 1-bits past bit 31
    const r32b = @shlWithOverflow(rw(0x3), @as(u5, 4));
    if (r32b[0] != 0x30 or r32b[1] != 0) return 62;
    return 0;
}
