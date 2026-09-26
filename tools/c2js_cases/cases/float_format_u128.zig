//! Float formatting drives Zig's Ryu shortest-round-trip printer, which uses
//! 128-bit intermediate arithmetic: zig_mul_u128 / zig_add_u128 / zig_cmp_u128 /
//! zig_shr_u128 / zig_div_trunc_u128 / zig_rem_u128 (plus zig_make_u128). The
//! current C backend emits these WITHOUT the trailing `w` (and with no explicit
//! bits arg); the transpiler modelled only the `*w` names, so these calls fell to
//! the unhandled-helper marker (lowered to `0`) - the digits came out wrong, or a
//! Number/BigInt mix threw at runtime. Checksum the printed digits of a spread of
//! magnitudes; native ground truth vs transpiled must agree.

const std = @import("std");

export fn run_test() i32 {
    const xs = [_]f64{
        3.140625,  0.1, 1234567.89, 0.000123,
        9999999.0, 2.5, 6.022e23,   1.0 / 3.0,
    };
    var buf: [64]u8 = undefined;
    var acc: u32 = 5381;
    for (xs) |x| {
        const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return -1;
        for (s) |c| {
            acc = (acc *% 33) +% c;
        }
    }
    return @intCast(acc & 0x7fffffff);
}
