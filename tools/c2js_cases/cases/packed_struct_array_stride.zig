// Packed-struct ARRAY stride. A packed struct lowers to one `bitpack__...` word
// (here u64) and its fields are read/written by masked __ld*64/__st64 (8-byte ops).
// An array of it must therefore stride by 8. Two bugs made it stride by 4 (elements
// overlapping, silent garbage):
//   1. struct layouts were computed (inside prescanData) BEFORE prescanTypedefs ran,
//      so the bitpack typedef's width wasn't known yet - now enums/typedefs prescan
//      first.
//   2. the free fn tyFromSpecifiers can't see the alias tables, so a `bitpack__...`
//      element defaulted to a 32-bit int - parseStructDef now resolves it via
//      bitpack_sizes to the real byte width.
// Self-checks (returns 0 on success).
const F = packed struct { x: u24, y: u24, z: u16 }; // 64 bits -> bitpack u64
var arr: [3]F = undefined;

export fn run_test() i32 {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        arr[i] = .{
            .x = @intCast(i + 1),
            .y = @intCast((i + 1) * 100),
            .z = @intCast((i + 1) * 7),
        };
    }
    var s: u32 = 0;
    for (&arr) |*f| {
        f.x +%= 1; // each element's x bumped - must not bleed into a neighbour
        s += f.x + f.y + f.z;
    }
    // i=0: x=2  y=100 z=7  -> 109
    // i=1: x=3  y=200 z=14 -> 217
    // i=2: x=4  y=300 z=21 -> 325
    if (s != 651) return 1;

    // also confirm no neighbour corruption: recompute y/z which were never written
    // after init
    var checkz: u32 = 0;
    for (&arr) |*f| checkz += f.z;
    if (checkz != 7 + 14 + 21) return 2;

    return 0;
}
