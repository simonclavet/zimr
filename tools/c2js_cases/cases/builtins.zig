//! Bit / abs / saturating / overflow builtins that lower to zig.h runtime
//! helpers (zig_abs, zig_clz, zig_ctz, zig_popcount, zig_byte_swap,
//! zig_bit_reverse, zig_adds/subs, zig_addo, ...). These used to be emitted as
//! verbatim calls to undefined JS functions — a SILENT runtime ReferenceError.
//! This case pins their correct lowering. run_test() returns 0 on success, or a
//! nonzero code identifying the first failed check. Inputs come from loop
//! counters so the builtins survive into the C output (aren't constant-folded).

export fn run_test() i32 {
    // @abs over a signed range
    var abs_sum: i32 = 0;
    var a: i32 = -4;
    while (a <= 4) : (a += 1) {
        abs_sum += @as(i32, @intCast(@abs(a)));
    }
    if (abs_sum != 20) return 1; // 4+3+2+1+0+1+2+3+4

    // @popCount / @clz / @ctz on u32
    var pc: i32 = 0;
    var cl: i32 = 0;
    var ct: i32 = 0;
    var i: u32 = 1;
    while (i <= 8) : (i += 1) {
        pc += @popCount(i);
        cl += @clz(i);
        ct += @ctz(i);
    }
    if (pc != 13) return 2;
    if (cl != 235) return 3;
    if (ct != 7) return 4;

    // @byteSwap u32
    var bs: u32 = 0;
    var j: u32 = 1;
    while (j <= 3) : (j += 1) {
        bs +%= @byteSwap(j *% 0x01020304);
    }
    if (bs != 0x04030201 +% 0x08060402 +% 0x0c090603) return 5;

    // @bitReverse u8
    var br: u32 = 0;
    var k: u8 = 0;
    while (k < 4) : (k += 1) {
        br +%= @as(u32, @bitReverse(@as(u8, 1) << @as(u3, @intCast(k))));
    }
    if (br != 0x80 + 0x40 + 0x20 + 0x10) return 6;

    // saturating add/sub on u8
    var sa: u32 = 0;
    var m: u8 = 0;
    while (m < 5) : (m += 1) {
        sa += @as(u32, @as(u8, 250) +| (m *% 3)); // 250,253,255,255,255
    }
    if (sa != 250 + 253 + 255 + 255 + 255) return 7;
    var ss: u8 = 10;
    ss -|= 25; // saturates at 0
    if (ss != 0) return 8;

    // @addWithOverflow on u8
    var res_sum: u32 = 0;
    var ov_sum: u32 = 0;
    var n: u8 = 0;
    while (n < 6) : (n += 1) {
        const r = @addWithOverflow(@as(u8, 200), n *% 20);
        res_sum +%= r[0];
        ov_sum +%= r[1];
    }
    // 200 + {0,20,40,60,80,100} -> u8 {200,220,240,4,24,44}; overflow {0,0,0,1,1,1}
    if (res_sum != 200 + 220 + 240 + 4 + 24 + 44) return 9;
    if (ov_sum != 3) return 10;

    return 0;
}
