// packed structs with bool fields (bool is one bit in the bitpack). Was a SILENT
// miscompile: bools read as false and corrupted the offsets of following fields.
const F = packed struct { a: bool, b: u7, c: bool, d: u7 };
export fn run_test() i32 {
    var f: F = .{ .a = true, .b = 100, .c = false, .d = 50 };
    f.c = true;
    if (f.a != true or f.b != 100 or f.c != true or f.d != 50) return 1;
    f.a = false;
    f.b = 7;
    if (f.a != false or f.b != 7 or f.d != 50) return 2;
    const G = packed struct { x: bool, y: bool };
    var g: G = .{ .x = true, .y = false };
    g.y = true;
    if (g.x != true or g.y != true) return 3;
    return 0;
}
