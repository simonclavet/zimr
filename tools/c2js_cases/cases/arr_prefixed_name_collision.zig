// Synthetic-array-wrapper NAME COLLISION. The C backend names its fixed-array
// wrapper structs `arr_<count>_<elem>` (e.g. `arr_3_i32`), and several detection
// sites distinguished a wrapper from a user struct by the bare `arr_` prefix.
// A user struct/module whose MANGLED name merely begins with `arr_<letter>` then
// collided: it was diverted away from struct-pointer/value tracking, and a
// `p->field` access fell through to a bogus JS property read (`p.field` on a
// numeric heap address -> undefined), silently corrupting every access.
//
// This file's module name is `arr_prefixed_name_collision`, so its structs mangle
// as `arr_prefixed_name_collision_*` - `arr_` followed by a LETTER, not a digit.
// A genuine wrapper is always `arr_` + a digit (the element count). Exercises a
// pointer deref, a by-value pass, and a 2-D array of such structs (the original
// trigger). Self-checks (returns 0 on success).
const P = struct { x: i32, y: i32 };

fn bump(p: *P) void {
    p.x += 1;
    p.y += 2;
}
fn dot(p: P) i32 {
    return p.x * p.y;
}

export fn run_test() i32 {
    // pointer deref -> &p->field must resolve to p + offset, not p.field
    var p = P{ .x = 10, .y = 20 };
    bump(&p);
    if (p.x != 11 or p.y != 22) return 1;

    // by-value pass (structTagOf path)
    if (dot(P{ .x = 6, .y = 7 }) != 42) return 2;

    // 2-D array of the struct (the original failing shape: nested wrappers
    // arr_2_arr_3_<module>_P over a user tag that itself starts with arr_)
    var g: [2][3]P = undefined;
    for (0..2) |i| for (0..3) |j| {
        g[i][j] = .{ .x = @intCast(i), .y = @intCast(j) };
    };
    var s: i32 = 0;
    for (0..2) |i| for (0..3) |j| {
        s += g[i][j].x * 10 + g[i][j].y;
    };
    // i in {0,1}: row0 -> 0+1+2=3 ; row1 -> 10+11+12=33 ; total 36
    if (s != 36) return 3;

    return 0;
}
