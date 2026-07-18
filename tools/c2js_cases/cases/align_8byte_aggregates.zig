// 8-byte alignment bug CLASS. Any aggregate holding an f64/i64/u64 is read/written
// via a shift-by-3 typed view (__HEAPF64 / __ld*64 / __st64) that REQUIRES 8-byte
// alignment; a slot that is only 4-aligned silently reads/writes the wrong 8 bytes.
// Three places got this wrong and are exercised here:
//   1. struct size + field offsets rounded to 4, not the struct's true alignment
//      (Zig reorders `{u8, f64}` to put the f64 at offset 0, size 16 / align 8);
//      arrays of such a struct then strided by the unpadded span and mis-read.
//   2. the global data image only 4-aligned each global's start, so an f64/i64
//      global (or struct global) at a 4-but-not-8 offset mis-read.
//   3. allocScratch only 4-aligned, so a union-with-struct-payload passed BY VALUE
//      (its payload lowered into a scratch slot) mis-read its f64 fields.
// Self-checks (returns 0 on success).
const Mixed = struct { a: u8, d: f64, b: i64 }; // align 8, size 24 (d@0, b@8, a@16)
var g_arr = [_]Mixed{
    .{ .a = 1, .d = 1.5, .b = 100 },
    .{ .a = 2, .d = 2.5, .b = 200 },
    .{ .a = 3, .d = 4.0, .b = 300 },
};

// u8 interleaved with f64 globals: forces some f64 to a 4-aligned start pre-fix.
var b0: u8 = 9;
var f0: f64 = 1.0;
var b1: u8 = 8;
var f1: f64 = 2.0;
var f2: f64 = 4.0;

const Shape = union(enum) { circle: f64, rect: struct { w: f64, h: f64 } };
fn area(s: Shape) f64 {
    return switch (s) {
        .circle => |r| 3.0 * r * r,
        .rect => |q| q.w * q.h,
    };
}

export fn run_test() i32 {
    // (1) array-of-struct stride + field offsets, mutate then re-read.
    var sumd: f64 = 0;
    var sumb: i64 = 0;
    var suma: u32 = 0;
    for (&g_arr) |*m| {
        m.d += 0.5;
        m.b +%= 1;
        sumd += m.d; // (2.0+3.0+4.5) = 9.5
        sumb += m.b; // (101+201+301) = 603
        suma += m.a; // 6
    }
    if (@as(i32, @intFromFloat(sumd * 2.0)) != 19) return 1;
    if (sumb != 603) return 2;
    if (suma != 6) return 3;

    // (2) interleaved scalar globals.
    f0 += 0.0;
    f1 += 0.0;
    f2 += 0.0;
    if (@as(i32, @intFromFloat((f0 + f1 + f2) * 10.0)) != 70) return 4;
    if (@as(u32, b0) + b1 != 17) return 5;

    // (3) union-with-struct-payload by value (scratch alignment).
    const c = area(Shape{ .circle = 2.0 }); // 12
    const r = area(Shape{ .rect = .{ .w = 3.0, .h = 4.0 } }); // 12
    if (@as(i32, @intFromFloat(c + r)) != 24) return 6;

    return 0;
}
