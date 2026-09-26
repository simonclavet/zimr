// Arrays whose element is a struct: 2D `[N][M]`, `[N]Vec`, and `[N]NamedStruct`.
//
// Regression for a silent miscompile: the Zig C-backend lowers these as nested
// array wrappers (`struct arr_3_arr_4_i32 { struct arr_4_i32 array[3]; }`,
// `arr_4_vec_4_f32`, `arr_4_aos_Pt`). The transpiler used to claim only
// primitive arrays (`arr_4_i32`) via its dedicated path and reject every other
// `arr_*` tag as "handled elsewhere", so struct-element arrays fell through to
// neither path - `&g.array[i]` emitted `g.array[i]` against a numeric offset
// (markers=0, but wrong at runtime). The element stride was also taken as a
// scalar width instead of the element struct's size.

// Spelled out rather than imported: this corpus is standalone Zig fed straight
// to the C backend, with no zimr modules in scope. (A `prefer-vec` autofix pass
// once rewrote this line to `const Vec = Vec;` - the rule exempts zimrmath's
// canonical binding by PATH, and this file is not that path. tools/c2js_cases/
// is carved out of the lint scan now, so the definition is safe here.)
const Vec = @Vector(4, f32);
const Pt = struct { x: i32, y: i32 };

fn grid() i32 {
    var g: [3][4]i32 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            g[i][j] = @intCast(i * 10 + j);
        }
    }
    var total: i32 = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            total += g[i][j];
        }
    }
    return total; // 138
}

fn pts() i32 {
    var a: [4]Pt = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        a[i].x = @intCast(i);
        a[i].y = @intCast(i * i);
    }
    return a[3].x + a[3].y + a[2].y; // 3 + 9 + 4 = 16
}

fn mat() i32 {
    var m: [4]Vec = undefined; // zimrmath's Mat = [4]Vec
    m[0] = .{ 1, 0, 0, 0 };
    m[1] = .{ 0, 2, 0, 0 };
    m[2] = .{ 0, 0, 3, 0 };
    m[3] = .{ 0, 0, 0, 4 };
    return @intFromFloat(m[0][0] + m[1][1] + m[2][2] + m[3][3]); // 10
}

export fn run_test() i32 {
    if (grid() != 138) {
        return 1;
    }
    if (pts() != 16) {
        return 2;
    }
    if (mat() != 10) {
        return 3;
    }
    return 0;
}
