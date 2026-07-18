//! Runtime-indexed array-typed struct *fields* (`s.vals[i]` where `vals: [N]T`).
//! In the Zig C-backend such a field is a nested array-wrapper struct
//! (`struct { T array[N]; }`), so the access lowers to `&s.vals.array[i]`. The
//! transpiler must (a) size/align the field as that nested struct — so a field
//! AFTER it lands at the right offset — and (b) resolve the `.array[i]` chain to
//! a strided element address instead of indexing a number. Covers global and
//! local structs, constant and runtime indices, scalar/f32/byte elements,
//! several array fields, an array-of-structs field, field writes, and a
//! by-value struct param. run_test() returns 0 on success, else a code.

const G64 = struct { vals: [3]u64, n: u32 };
var g64: G64 = .{ .vals = .{ 10, 20, 30 }, .n = 3 };

const Local4 = struct { vals: [4]i32, n: u32 };

const Padded = struct { head: u32, vals: [3]i64, tail: u32 };
var padded: Padded = .{ .head = 1, .vals = .{ 100, 200, 300 }, .tail = 7 };

const TwoArr = struct { a: [2]u32, b: [2]u32 };
var two: TwoArr = .{ .a = .{ 1, 2 }, .b = .{ 10, 20 } };

const Vecish = struct { v: [4]f32, n: u32 };
var vecish: Vecish = .{ .v = .{ 1.5, 2.5, 3.0, 4.0 }, .n = 4 };

const P = struct { x: i32, y: i32 };
const Aos = struct { items: [3]P, n: u32 };
var aos: Aos = .{ .items = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } }, .n = 3 };
var aosw: Aos = .{ .items = .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } }, .n = 3 };

const Bytes = struct { buf: [8]u8, n: u32 };

const ByVal = struct { vals: [3]u32, n: u32 };
fn sumByVal(s: ByVal) u32 {
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < s.n) : (i += 1) acc += s.vals[i];
    return acc;
}

export fn run_test() i32 {
    // 1. global struct, runtime-indexed u64 field
    {
        var sum: u64 = 0;
        var i: u32 = 0;
        while (i < g64.n) : (i += 1) sum += g64.vals[i];
        if (sum != 60) return 1;
    }
    // 2. local struct, runtime-indexed i32 field
    {
        const l: Local4 = .{ .vals = .{ 5, 7, 9, 11 }, .n = 4 };
        var s: i32 = 0;
        var i: u32 = 0;
        while (i < l.n) : (i += 1) s += l.vals[i];
        if (s != 32) return 2;
    }
    // 3. field offsets: a scalar before AND after the array must stay intact
    {
        var s: i64 = 0;
        var i: u32 = 0;
        while (i < 3) : (i += 1) s += padded.vals[i];
        if (s != 600) return 3;
        if (padded.head != 1 or padded.tail != 7) return 4;
    }
    // 4. constant index
    {
        if (g64.vals[0] != 10 or g64.vals[2] != 30) return 5;
    }
    // 5. two array fields: the second sits after the first; a write to one
    //    must not bleed into the other.
    {
        if (two.a[0] + two.a[1] + two.b[0] + two.b[1] != 33) return 6;
        two.b[1] = 99;
        if (two.b[1] != 99 or two.a[1] != 2) return 7;
    }
    // 6. f32 array field
    {
        var s: f32 = 0;
        var i: u32 = 0;
        while (i < vecish.n) : (i += 1) s += vecish.v[i];
        if (s != 11.0) return 8;
    }
    // 7. array-of-structs field: element is a struct, indexed then field-read
    {
        var s: i32 = 0;
        var i: u32 = 0;
        while (i < aos.n) : (i += 1) s += aos.items[i].x * 10 + aos.items[i].y;
        if (s != 102) return 9;
    }
    // 8. byte array field: write each element, then read back
    {
        var b: Bytes = .{ .buf = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .n = 0 };
        var i: u32 = 0;
        while (i < 8) : (i += 1) b.buf[i] = @intCast(i * 3);
        var sum: u32 = 0;
        i = 0;
        while (i < 8) : (i += 1) sum += b.buf[i];
        if (sum != 84) return 10;
    }
    // 9. struct passed by value, then index its array field
    {
        const s: ByVal = .{ .vals = .{ 11, 22, 33 }, .n = 3 };
        if (sumByVal(s) != 66) return 11;
    }
    // 10. array-of-structs WRITES at a runtime index, then read back via both a
    //     constant index (the `*(&...)` deref form) and a runtime index.
    {
        var i: u32 = 0;
        while (i < aosw.n) : (i += 1) {
            aosw.items[i].x = @intCast(i + 1);
            aosw.items[i].y = @intCast((i + 1) * 10);
        }
        if (aosw.items[0].x != 1 or aosw.items[1].y != 20 or aosw.items[2].x != 3) return 12;
        var s: i32 = 0;
        i = 0;
        while (i < aosw.n) : (i += 1) s += aosw.items[i].x + aosw.items[i].y;
        if (s != 66) return 13;
    }
    return 0;
}
