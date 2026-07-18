// global array-of-structs mutated through a runtime-indexed loop.
const G = struct { a: i32, b: i32 };
var gs = [_]G{ .{ .a = 0, .b = 0 }, .{ .a = 0, .b = 0 }, .{ .a = 0, .b = 0 }, .{ .a = 0, .b = 0 } };
export fn run_test() i32 {
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        gs[i].a = @intCast(i * 2);
        gs[i].b = @intCast(i * 3);
    }
    var s: i32 = 0;
    i = 0;
    while (i < 4) : (i += 1) s += gs[i].a * 10 + gs[i].b;
    if (s != 138) return 1;
    return 0;
}
