// Element store through a wrapper POINTER: `t->array[i] = v` where t : arr_M_u64*
// (the inner-row pointer of a [N][M]u64). The Zig C backend emits this for a 2D
// `@memset(row, v)` over `for (&grid) |*row|`, and for a `[*]`-style row write.
// Pre-fix only single-field `ptr->field =` was handled (not the `[idx]` element
// form), so each 64-bit element store was dropped (orphaned load) and the grid
// read back as its uninitialized fill.
var grid: [2][3]u64 = undefined;
var line: [4]u64 = undefined;

export fn run_test() i32 {
    // 2D row @memset (row is *[3]u64)
    for (&grid) |*row| @memset(row, 0xFEDCBA9876543210);
    for (grid) |row| {
        for (row) |x| {
            if (x != 0xFEDCBA9876543210) return 1;
        }
    }
    // distinct per-row values via a row pointer + element index
    var r: usize = 0;
    while (r < 2) : (r += 1) {
        const row: *[3]u64 = &grid[r];
        var c: usize = 0;
        while (c < 3) : (c += 1) row[c] = 0x1000000000 *% @as(u64, @intCast(r * 3 + c + 1));
    }
    r = 0;
    while (r < 2) : (r += 1) {
        var c: usize = 0;
        while (c < 3) : (c += 1) {
            if (grid[r][c] != 0x1000000000 *% @as(u64, @intCast(r * 3 + c + 1))) return 2;
        }
    }
    // 1D row pointer element store
    const lp: *[4]u64 = &line;
    var i: usize = 0;
    while (i < 4) : (i += 1) lp[i] = 0x2222222200000000 *% @as(u64, @intCast(i + 1));
    i = 0;
    while (i < 4) : (i += 1) {
        if (line[i] != 0x2222222200000000 *% @as(u64, @intCast(i + 1))) return 3;
    }
    return 0;
}
