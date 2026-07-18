// runtime-indexed array field of a struct (`g.vals[i]`). The header doc once
// flagged this as unverified; it works.
const S = struct { vals: [4]i32, tag: i32 };
var g: S = .{ .vals = .{ 10, 20, 30, 40 }, .tag = 7 };
export fn run_test() i32 {
    var i: u32 = 2;
    g.vals[i] = 99;
    if (g.vals[2] != 99 or g.vals[0] != 10 or g.tag != 7) return 1;
    var s: i32 = g.tag;
    i = 0;
    while (i < 4) : (i += 1) s += g.vals[i];
    if (s != 176) return 2;
    return 0;
}
