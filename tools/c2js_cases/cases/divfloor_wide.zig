// @divFloor on 64-bit operands. Pre-fix the transpiler lowered the
// `zig_div_floor_i64`/`_u64` helper to Math.floor(BigInt/BigInt) (signed) and
// Math.trunc(BigInt/BigInt) (unsigned) - both throw in the emitted JS, because
// Math.floor/Math.trunc reject BigInt (and BigInt `/` already truncates toward
// zero, so the signed case was also semantically wrong). The reference here is
// built from @divTrunc (plain BigInt `/`, which always worked) adjusted to
// floor, so a wrong value - not just a crash - is caught too.
fn refFloor(a: i64, b: i64) i64 {
    const q: i64 = @divTrunc(a, b);
    const r: i64 = @rem(a, b);
    return if (r != 0 and ((a < 0) != (b < 0))) q - 1 else q;
}

var sink: i64 = 0;
fn rt(x: i64) i64 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // Operands exceed 2^32 so the lowering must use the 64-bit (BigInt) path,
    // across every sign combination.
    const combos = [_][2]i64{
        .{ 0x100000001, 7 },        .{ -0x100000001, 7 },
        .{ 0x100000001, -7 },       .{ -0x100000001, -7 },
        .{ 0xDEADBEEFCAFE, 13 },    .{ -0xDEADBEEFCAFE, 1000003 },
        .{ 0x7FFFFFFFFFFFFFFF, 3 }, .{ -0x7FFFFFFFFFFFFFFF, 3 },
    };
    var code: i32 = 1;
    for (combos) |c| {
        const a: i64 = rt(c[0]);
        const b: i64 = rt(c[1]);
        if (@divFloor(a, b) != refFloor(a, b)) return code;
        code += 1;
    }
    // Unsigned 64-bit @divFloor == @divTrunc == `/` (operands non-negative).
    var u: u64 = 0;
    u +%= 0xCAFEBABEDEAD;
    if (@divFloor(u, @as(u64, 1009)) != u / 1009) return 100;
    if (@divFloor(@as(u64, 0xFFFFFFFFFFFFFFFF), @as(u64, 7)) != 0xFFFFFFFFFFFFFFFF / 7) return 101;
    return 0;
}
