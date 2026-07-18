// `[*]Struct` (many-item pointer) indexing must stride by the WHOLE struct size.
// A struct-pointer local records its pointee on ty.struct_tag (NOT ty.elem), and
// the `&p[i]` address path — which underlies both `p[i].field` reads and stores —
// consulted only ty.elem, so it struck a stride of 1 and silently miscompiled
// every many-pointer struct access (field read, field store, and whole-struct
// store), including such a pointer passed as a function parameter. The cross-check
// against the array view pins the addressing. Self-checks (returns 0 on success).
const P = struct { x: i32, y: i32, z: i32 };

fn sumX(p: [*]P, n: usize) i32 {
    var s: i32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) s +%= p[i].x;
    return s;
}

export fn run_test() i32 {
    var arr = [_]P{
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
    };
    const p: [*]P = &arr;

    // field stores through the many-pointer
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        p[i].x = @intCast(i + 1);
        p[i].y = @intCast((i + 1) * 10);
        p[i].z = @intCast((i + 1) * 100);
    }
    // whole-struct store into one element
    p[2] = .{ .x = 3, .y = 30, .z = 300 };

    // read back through the many-pointer; cross-check the same bytes via the array
    i = 0;
    while (i < 4) : (i += 1) {
        const e: i32 = @intCast(i + 1);
        if (p[i].x != e) return 1;
        if (p[i].y != e * 10) return 2;
        if (p[i].z != e * 100) return 3;
        if (arr[i].x != e or arr[i].y != e * 10 or arr[i].z != e * 100) return 4;
    }

    // many-pointer passed as a function parameter, indexed inside
    if (sumX(p, 4) != 1 + 2 + 3 + 4) return 5;
    return 0;
}
