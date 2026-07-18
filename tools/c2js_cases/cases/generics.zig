// Comptime-generic instantiation: a generic function and a generic struct type,
// each monomorphized at u64 and u32, to confirm the transpiler handles the distinct
// concrete types the C backend emits (64-bit vs 32-bit storage/arithmetic). Self-checking.
fn addAll(comptime T: type, vals: []const T) T {
    var t: T = 0;
    for (vals) |v| t +%= v;
    return t;
}
fn Box(comptime T: type) type {
    return struct { val: T, count: u32 };
}

export fn run_test() i32 {
    const a64 = [_]u64{ 0x100000001, 0x200000002, 0x300000003 };
    const a32 = [_]u32{ 10, 20, 30, 40 };
    if (addAll(u64, &a64) != 0x600000006) return 1;
    if (addAll(u32, &a32) != 100) return 2;

    var b64: Box(u64) = .{ .val = 0x100000001, .count = 3 };
    b64.val +%= 0x200000002;
    b64.count += 1;
    if (b64.val != 0x300000003) return 3;
    if (b64.count != 4) return 4;

    var b32: Box(u32) = .{ .val = 50, .count = 1 };
    b32.val *= 2;
    if (b32.val != 100) return 5;
    if (b32.count != 1) return 6;
    return 0;
}
