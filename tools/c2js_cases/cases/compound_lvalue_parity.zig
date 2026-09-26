// READ/STORE PARITY canary. A compound assignment (`OP=`) reads and writes the
// SAME lvalue in one statement, so it catches any divergence between the read-
// address path and the store-address path - the asymmetry behind several past
// silent miscompiles (the nested-field read that returned 0, the dropped global
// array-of-structs store). Exercises nested fields and array-of-struct element
// fields, global and local, with +=, *=, -=, &=, <<=, ^=. Self-checks (0 = pass).
const In = struct { x: i32, y: i32 };
const Node = struct { inner: In, k: i32 };
var G = [_]Node{
    .{ .inner = .{ .x = 1, .y = 2 }, .k = 3 },
    .{ .inner = .{ .x = 4, .y = 5 }, .k = 6 },
};

export fn run_test() i32 {
    // global array-of-struct element, nested field, read-modify-write
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        G[i].inner.x +%= @intCast((i + 1) * 10); // 11, 24
        G[i].inner.y *%= 3; // 6, 15
        G[i].k -%= 1; // 2, 5
    }
    if (G[0].inner.x != 11 or G[0].inner.y != 6 or G[0].k != 2) return 1;
    if (G[1].inner.x != 24 or G[1].inner.y != 15 or G[1].k != 5) return 2;

    // local struct, nested field, bit-op compounds
    var n: Node = .{ .inner = .{ .x = 0xF0, .y = 8 }, .k = 100 };
    n.inner.x &= 0x3C; // 0x30 = 48
    n.inner.y <<= 2; // 32
    n.k ^= 0x0F; // 100 ^ 15 = 107
    if (n.inner.x != 48 or n.inner.y != 32 or n.k != 107) return 3;

    return 0;
}
