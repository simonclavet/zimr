// @fieldParentPtr recovers a struct pointer from a pointer to one of its fields.
// The C backend lowers it as `parent = (Parent*)((u8*)field_ptr - offsetof(
// Parent, field))`, using the C stddef `offsetof` macro. The transpiler resolves
// offsetof to the field's byte offset in its own layout, so the subtraction lands
// on the parent base; before, offsetof was unhandled (loud marker, threw).
const Big = struct { a: u32, b: u32, c: i32, d: u32 };
export fn run_test() i32 {
    var x = Big{ .a = 1, .b = 2, .c = 99, .d = 4 };
    const pc: *i32 = &x.c; // points at field c (offset 8)
    const parent: *Big = @fieldParentPtr("c", pc);
    parent.a = 100; // mutate through the recovered parent pointer
    if (parent.a != 100) return 1;
    if (parent.c != 99) return 2;
    if (parent.d != 4) return 3;
    return 0;
}
