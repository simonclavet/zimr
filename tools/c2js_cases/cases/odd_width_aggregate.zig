// 33-63 bit integers as ARRAY / aggregate elements (u40, u48). The C backend stores
// such an element in an 8-byte cell, but the transpiler's element-name parser did not
// recognize odd widths (returned null), so an arr_N_u40 wrapper was misclassified as
// an array-of-struct and its element store silently lowered to a LOAD (dropping the
// write); @memcpy/@memset of such arrays also threw "cannot mix BigInt and other
// types". Fix: parse arbitrary integer widths, and route 33-63 bit elements through
// the 8-byte __ld64/__st64 cell (masked to the type width) like 64-bit ints.
var a40: [4]u40 = undefined;
var b40: [4]u40 = undefined;
var c48: [3]u48 = .{ 0, 0, 0 };
var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // @memset across a u40 array (the loop-store that pre-fix dropped)
    @memset(&a40, @intCast(ru(0x1122334455) & 0xFFFFFFFFFF));
    for (a40) |x| if (x != 0x1122334455) return 1;

    // @memcpy u40 -> u40
    @memcpy(&b40, &a40);
    for (b40) |x| if (x != 0x1122334455) return 2;

    // direct indexed store/load; neighbors must be untouched
    a40[2] = @intCast(ru(0xAABBCCDDEE) & 0xFFFFFFFFFF);
    if (a40[2] != 0xAABBCCDDEE) return 3;
    if (a40[0] != 0x1122334455) return 4;

    // read-modify-write of an odd-width element
    a40[1] +%= 0x10;
    if (a40[1] != 0x1122334465) return 5;

    // u48 array fill + readback
    var i: usize = 0;
    while (i < 3) : (i += 1) c48[i] = @intCast(ru(0x100000000000 *% @as(u64, @intCast(i + 1))) & 0xFFFFFFFFFFFF);
    if (c48[0] != 0x100000000000) return 6;
    if (c48[2] != 0x300000000000) return 7;

    // pointer to an odd-width element
    const p: *u40 = &a40[3];
    p.* = 0x99;
    if (a40[3] != 0x99) return 8;

    // sum through the __ld64 path
    var sum: u64 = 0;
    for (b40) |x| sum +%= x;
    if (sum != 0x1122334455 *% 4) return 9;
    return 0;
}
