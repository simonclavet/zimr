// 2D array of structs ([N][M]Struct): the inner row is a struct-element
// array-wrapper pointer; storing/reading grid[i][j].field must stride by the
// element struct size, not do an object property access. Regression for the
// structPtrTagOf struct-elem-array-wrapper fix.
const Cell = struct { x: i32, y: i32 };
export fn run_test() i32 {
    var grid: [2][2]Cell = undefined;
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        var j: u32 = 0;
        while (j < 2) : (j += 1) {
            grid[i][j] = .{ .x = @as(i32, @intCast(i)) + 1, .y = @as(i32, @intCast(j)) + 1 };
        }
    }
    var s: i32 = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        var j: u32 = 0;
        while (j < 2) : (j += 1) s += grid[i][j].x * 10 + grid[i][j].y;
    }
    if (s != 66) return 1;
    return 0;
}
