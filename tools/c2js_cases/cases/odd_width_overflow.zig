// Overflow builtins (@addWithOverflow/@subWithOverflow/@mulWithOverflow/
// @shlWithOverflow) on 33-63 bit integers. The wrapped result is stored through a
// __st64 (64-bit) view that does NOT implicitly truncate to a 40-bit field, so
// pre-fix the stored result kept bits above the width (e.g. u40 max + 1 = 2^40
// instead of 0). The overflow BIT was already correct (a BigInt-vs-Number
// relational compare against 2^wn). Each check below WIDENS the result to u64/i64
// and uses it, so an unwrapped value leaks rather than being masked away.
var sink: u64 = 0;
fn ru(x: u64) u64 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    const max40: u40 = @intCast(ru(0xFFFFFFFFFF) & 0xFFFFFFFFFF);

    // add: (2^40 - 1) + 5 = 2^40 + 4 -> wraps to 4, overflow 1
    const a = @addWithOverflow(max40, @as(u40, 5));
    if (@as(u64, a[0]) != 4) return 1;
    if (a[1] != 1) return 2;

    // add no overflow: 0x100 + 0x200 = 0x300
    const a2 = @addWithOverflow(@as(u40, 0x100), @as(u40, 0x200));
    if (@as(u64, a2[0]) != 0x300) return 3;
    if (a2[1] != 0) return 4;

    // sub: 3 - 10 wraps to 2^40 - 7, overflow 1
    const s = @subWithOverflow(@as(u40, 3), @as(u40, 10));
    if (@as(u64, s[0]) != 0xFFFFFFFFFF - 6) return 5;
    if (s[1] != 1) return 6;

    // mul: 0x1000001 * 0x10000 = 2^40 + 0x10000 -> wraps to 0x10000, overflow 1
    const m = @mulWithOverflow(@as(u40, 0x1000001), @as(u40, 0x10000));
    if (@as(u64, m[0]) != 0x10000) return 7;
    if (m[1] != 1) return 8;

    // shl: 3 << 39 = 2^40 + 2^39 -> wraps to 2^39, overflow 1
    const sh = @shlWithOverflow(@as(u40, 3), @as(u6, 39));
    if (@as(u64, sh[0]) != 0x8000000000) return 9;
    if (sh[1] != 1) return 10;

    // signed i40: max_i40 (2^39 - 1) + 1 -> wraps to i40 min (-2^39), overflow 1
    const maxi: i40 = @intCast(@as(i64, @bitCast(ru(@bitCast(@as(i64, 0x7FFFFFFFFF))))));
    const si = @addWithOverflow(maxi, @as(i40, 1));
    if (@as(i64, si[0]) != -549755813888) return 11;
    if (si[1] != 1) return 12;

    // use a wrapped result in further arithmetic to be doubly sure it isn't 2^40
    var total: u64 = 0;
    total +%= @as(u64, a[0]) *% 1000; // 4000 if wrapped, huge if not
    if (total != 4000) return 13;
    return 0;
}
