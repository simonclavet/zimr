// multi-dimensional [N][M] arrays with runtime indices.
export fn run_test() i32 {
    var m: [3][3]i32 = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 8, 9 } };
    var i: u32 = 1;
    const j: u32 = 2;
    m[i][j] = 99;
    if (m[1][2] != 99 or m[0][0] != 1 or m[2][2] != 9) return 1;
    var s: i32 = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        var k: u32 = 0;
        while (k < 3) : (k += 1) s += m[i][k];
    }
    if (s != 138) return 2;
    return 0;
}
