// Function pointer stored in a MUTABLE struct field, called indirectly, then
// REASSIGNED through the field and called again. The C backend can't resolve
// this at comptime (unlike a const struct), so it stores `&fn` into the heap
// field and lowers `o.f = &g` as `t = &o.f; *t = &g`. Handled by the function-
// dispatch table: `&fn` lowers to a 1-based __FTABLE index, the field stores
// that index, and an indirect call dispatches `__FTABLE[idx](args)`. (The const
// case, fully resolved to direct calls, is covered in cases/fnptr_struct.zig.)
const Ops = struct { f: *const fn (i32) i32 };
fn fnDouble(x: i32) i32 {
    return x * 2;
}
fn fnTriple(x: i32) i32 {
    return x * 3;
}
export fn run_test() i32 {
    var o = Ops{ .f = &fnDouble };
    if (o.f(10) != 20) return 1;
    o.f = &fnTriple;
    if (o.f(10) != 30) return 2;
    return 0;
}
