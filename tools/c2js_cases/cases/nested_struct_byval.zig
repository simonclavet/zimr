// Nested struct passed BY VALUE where the inner struct is over-aligned by its
// parent: the C backend emits `typedef struct X aligned__N_X;` and casts
// `&parent.field` through that alias. The transpiler resolves the struct-typedef
// alias to the real struct so the pointer cast is recognized and the nested
// field access lands at the right heap offset (rather than being misparsed as a
// multiply, which silently dropped the access before).
const Inner = extern struct { x: i16, y: i16 };
const Box = extern struct { id: u32, p: Inner, q: Inner };
fn add(a: Inner, b: Inner) i32 {
    return a.x + a.y + b.x + b.y;
}
export fn run_test() i32 {
    var z = Box{ .id = 9, .p = .{ .x = 1, .y = 2 }, .q = .{ .x = 3, .y = 4 } };
    z.p.x += 100;
    if (add(z.p, z.q) != 110) return 1; // 101 + 2 + 3 + 4
    return 0;
}
