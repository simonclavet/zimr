//! Indexing a POINTER-typed struct field - `self.buf[i]` where the field is
//! `*[N]T` (pointer to a fixed array) or `[*]T` (many-pointer). In the Zig
//! C-backend this lowers via a pointer-to-pointer temp:
//!     t3 = &self->buf;    // address of the field    (arr_N_T **)
//!     t4 = *t3;           // LOAD the stored pointer  (the field's value)
//!     t5 = &t4->array[i]; // stride into the pointee
//! The transpiler used to collapse `*t3` to identity - because a `struct X **`
//! was classified as a struct pointer, whose deref is the offset itself - and
//! so strode from the field's ADDRESS instead of the loaded pointer: a silent
//! wrong result with no marker. The fix loads the pointer for a double-star
//! struct pointer that holds a heap address, while the `&local` round-trip
//! (the `self` access, slice element addresses) stays identity.
//!
//! The pointers are taken through a `noinline` boundary so the structs are
//! built at RUNTIME (not folded into a static initializer), which isolates the
//! field-load lowering from static-data relocation. run_test() returns 0 on
//! success, else a nonzero code.

const N = 16;

const Box = struct {
    buf: *[N]u8, // pointer-to-array field, stride 1
    fn at(self: *const Box, i: usize) u8 {
        return self.buf[i];
    }
    fn set(self: *const Box, i: usize, v: u8) void {
        self.buf[i] = v;
    }
};

const WBox = struct {
    w: *[8]u32, // pointer-to-array field, stride 4
    fn at(self: *const WBox, i: usize) u32 {
        return self.w[i];
    }
};

const MBox = struct {
    p: [*]u8, // many-pointer field, stride 1 (the already-correct control)
    fn at(self: *const MBox, i: usize) u8 {
        return self.p[i];
    }
};

var backing: [N]u8 = undefined;
var wbacking: [8]u32 = undefined;
var mbacking: [4]u8 = undefined;

// Opaque to const-folding: returns a runtime pointer, so a struct built from
// it is constructed at run time rather than baked into the data image.
noinline fn rtBacking() *[N]u8 {
    return &backing;
}
noinline fn rtWBacking() *[8]u32 {
    return &wbacking;
}
noinline fn rtMBacking() [*]u8 {
    return &mbacking;
}

export fn run_test() i32 {
    var i: usize = 0;
    while (i < N) : (i += 1) backing[i] = @intCast(i * 2); // 0,2,4,...,30
    i = 0;
    while (i < 8) : (i += 1) wbacking[i] = @intCast(i * 100 + 7); // 7,107,...,707
    i = 0;
    while (i < 4) : (i += 1) mbacking[i] = @intCast(i + 40); // 40,41,42,43

    // *[N]u8 - read through the pointer-to-array field.
    const b = Box{ .buf = rtBacking() };
    if (b.at(0) != 0) return 1;
    if (b.at(3) != 6) return 2;
    if (b.at(15) != 30) return 3;

    // *[8]u32 - stride 4 through the field.
    const wb = WBox{ .w = rtWBacking() };
    if (wb.at(0) != 7) return 4;
    if (wb.at(5) != 507) return 5;
    if (wb.at(7) != 707) return 6;

    // [*]u8 - many-pointer field (already worked; kept as a control).
    const mb = MBox{ .p = rtMBacking() };
    if (mb.at(0) != 40) return 7;
    if (mb.at(3) != 43) return 8;

    // Write through the field pointer, then read it back.
    b.set(4, 99);
    if (b.at(4) != 99) return 9;
    if (backing[4] != 99) return 10; // the write reached the real backing array

    return 0;
}
