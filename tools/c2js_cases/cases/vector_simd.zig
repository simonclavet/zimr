// @Vector SIMD: elementwise + and *, @splat, @reduce.
export fn run_test() i32 {
    const a: @Vector(4, f32) = .{ 1, 2, 3, 4 };
    const b = a + a * @as(@Vector(4, f32), @splat(2.0));
    if (@as(i32, @intFromFloat(@reduce(.Add, b))) != 30) return 1;
    const iv: @Vector(4, i32) = .{ 10, 20, 30, 40 };
    if (@reduce(.Add, iv) != 100) return 2;
    return 0;
}
