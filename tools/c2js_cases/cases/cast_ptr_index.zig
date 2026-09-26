// Indexing a scalar-pointer cast: `((ELEM*)base)[i]` (reads AND the address-of / store
// forms `&((ELEM*)base)[i]` / `((ELEM*)base)[i] = v`). The Zig C backend emits these
// (paren-wrapped) when it folds a slice or `[*:0]T`/`[*]T` pointer to a known GLOBAL
// base - e.g. a sentinel slice's `s.ptr[i]` -> `((u32*)&g)[i]`, and `p[i] = v` ->
// `*&((u32*)((arr_Ns_T*)&g))[i]`. Pre-fix:
//   * the value read lowered `[i]` as a literal JS subscript on a heap offset -> 0;
//   * the address form fell through to the value read (a load), so `p[i]=v` stored to
//     offset 0 (writes lost) and `p[i].field` read garbage;
//   * an OUTER scalar `(u32*)` cast leaked the INNER `(arr_Ns_T*)` cast's struct tag,
//     so the store strided by the wrapper struct size instead of the element size.
const P = struct { x: u32, y: u32 };
var g32: [6:0]u32 = .{ 11, 22, 33, 44, 55, 66 };
var wbuf: [4:0]u32 = .{ 0, 0, 0, 0 };
var ps: [3]P = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } };
var sink: usize = 0;
fn ri(x: usize) usize {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // scalar read via sentinel slice .ptr[i] (folded to ((u32*)&g32)[i])
    const s: [:0]u32 = g32[0..6 :0];
    var t: u32 = 0;
    var i: usize = ri(0);
    while (i < s.len) : (i += 1) t += s.ptr[i];
    if (t != 231) return 1;

    // STORE through a [*:0]u32 pointer into a GLOBAL (the scalar-outer-cast shape):
    // p[i] = v -> *&((u32*)((arr_4s_u32*)&wbuf))[i]. Pre-fix this either stored to
    // offset 0 (writes lost) or strided by the wrapper size (20) - both wrong.
    const p: [*:0]u32 = &wbuf;
    i = 0;
    while (i < 4) : (i += 1) p[i] = @intCast((i + 1) * 100);
    var w: u32 = 0;
    for (wbuf) |x| w += x;
    if (w != 100 + 200 + 300 + 400) return 2;
    if (wbuf[wbuf.len] != 0) return 3; // sentinel untouched

    // STORE + field read through a [*]struct pointer to a global (outer cast (P*)).
    const pp: [*]P = &ps;
    pp[ri(1)].x = 30;
    var f: u32 = 0;
    i = 0;
    while (i < 3) : (i += 1) {
        f += pp[i].x;
        f += pp[i].y;
    }
    if (f != 1 + 2 + 30 + 4 + 5 + 6) return 4;
    return 0;
}
