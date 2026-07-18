// Storing into a GLOBAL array-of-structs element field — `G[i].field = v` — must
// emit the assignment. The C backend inlines the element address as a cast-pointer
// with `+` arithmetic (`*(&((P*)((arr*)&G) + i)->x) = v`); the lvalue address walker
// had no `+` (pointer-arithmetic) case, so the LHS failed to resolve, the store path
// bailed, and the whole assignment was silently dropped — the LHS lowered to an
// orphaned heap read and the RHS to a bare value. Local arrays were unaffected
// (the backend used a temp there). Self-checks (returns 0 on success).
const P = struct { x: i32, y: i32 };
var G = [_]P{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } };

export fn run_test() i32 {
    // direct field stores into global elements (constant and runtime index)
    G[0].x = 100;
    G[0].y = 200;
    var i: usize = 1;
    while (i < 3) : (i += 1) {
        G[i].x = @intCast(i * 10);
        G[i].y = @intCast(i * 10 + 1);
    }
    if (G[0].x != 100 or G[0].y != 200) return 1;
    if (G[1].x != 10 or G[1].y != 11) return 2;
    if (G[2].x != 20 or G[2].y != 21) return 3;

    // store through a pointer into the global array
    const q = &G[2];
    q.x = 999;
    if (G[2].x != 999 or G[2].y != 21) return 4;

    // whole-struct store into a global element
    G[1] = .{ .x = 7, .y = 8 };
    if (G[1].x != 7 or G[1].y != 8) return 5;

    // element 0 still intact
    if (G[0].x != 100 or G[0].y != 200) return 6;
    return 0;
}
