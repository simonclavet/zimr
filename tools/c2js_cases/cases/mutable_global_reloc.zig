//! Relocation of `&otherGlobal` inside a MUTABLE global's static initializer.
//! A `var` global aggregate (struct with pointer fields, a slice, or a bare
//! pointer) initialized with the address of another global must have the
//! pointee's heap offset written into its data image; the transpiler used to
//! leave it null, so the field read back as 0 - a silent wrong result. (Const
//! globals escape this: the C backend value-propagates their pointer derefs, so
//! they never read the data image; a `var` one genuinely does.) These are read
//! at RUNTIME so the data image is exercised. run_test() returns 0 on success.

var a: u32 = 100;
var b: u32 = 200;
var gbuf = [_]u8{ 1, 2, 3, 4, 5 };

const Holder = struct { p: *u32, q: *u32, tag: u32 };
var h: Holder = .{ .p = &a, .q = &b, .tag = 7 };

var sl: []u8 = &gbuf;
var bare: *u32 = &b;

export fn run_test() i32 {
    // mutable global struct with pointer fields -> &a, &b relocated into data
    if (h.p.* != 100) return 1;
    if (h.q.* != 200) return 2;
    if (h.tag != 7) return 3;
    // write through a relocated pointer reaches the real global
    h.p.* = 111;
    if (a != 111) return 4;
    // mutable global slice -> {ptr,len} relocated
    if (sl.len != 5) return 5;
    var sum: u32 = 0;
    for (sl) |v| sum +%= v;
    if (sum != 15) return 6;
    sl[2] = 99;
    if (gbuf[2] != 99) return 7;
    // bare mutable global pointer
    if (bare.* != 200) return 8;
    return 0;
}
