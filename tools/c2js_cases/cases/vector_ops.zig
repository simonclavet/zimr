// @Vector coverage: f64 elementwise arithmetic + reductions, @splat, integer
// reductions (Min/Max/And/Or/Xor), and a bool-vector compare result. Self-checking.
export fn run_test() i32 {
    // f64 vector
    const a: @Vector(4, f64) = .{ 1.5, 2.5, 3.5, 4.5 };
    const b: @Vector(4, f64) = .{ 2.0, 2.0, 2.0, 2.0 };
    const prod = a * b; // {3,5,7,9}
    if (@reduce(.Add, prod) != 24.0) return 1;
    if (@reduce(.Max, a) != 4.5) return 2;

    // @splat
    const base: @Vector(4, i32) = @splat(10);
    const idx: @Vector(4, i32) = .{ 0, 1, 2, 3 };
    if (@reduce(.Add, base + idx) != 46) return 3;

    // integer reductions
    const v: @Vector(4, u32) = .{ 12, 5, 30, 8 };
    if (@reduce(.Max, v) != 30) return 4;
    if (@reduce(.Min, v) != 5) return 5;
    if (@reduce(.And, v) != 0) return 6;
    if (@reduce(.Or, v) != 31) return 7;
    if (@reduce(.Xor, v) != 31) return 8;

    // bool-vector compare result
    const mask: @Vector(4, bool) = v > @as(@Vector(4, u32), @splat(10));
    var arr: [4]u8 = undefined;
    inline for (0..4) |i| arr[i] = if (mask[i]) 1 else 0;
    if (arr[0] != 1 or arr[1] != 0 or arr[2] != 1 or arr[3] != 0) return 9;
    return 0;
}
