// Sentinel-terminated array whose element is an enum-tag typedef: `[N:sentinel]Enum`.
// Its wrapper is `arr_Ns<id>_<enumTag>` with a non-primitive element. Pre-fix
// isStructElemArrayTag rejected the `Ns<id>` sentinel count, so structTagOf DIVERTED
// the wrapper to the scalar/string path - `t = arr` (a whole-array value) read the
// first 4 bytes as a single number and used it as a base address, so element reads
// were garbage (0). Fix parses the count before the `s` marker there too; a
// non-primitive element is then recognized as an array-of-aggregates (carrying the
// enum-width handling). A sentinel u8/u32 array keeps a primitive element and stays
// on its own path. (Sentinels must be scalar, so there is no sentinel-struct array.)
const Tok = enum(u8) { a, b, c, end };
var es: [3:.a]Tok = .{ .a, .b, .c };

export fn run_test() i32 {
    // global sentinel enum array
    es[1] = .c;
    var t: u32 = 0;
    for (es) |x| t = t * 10 + @backingInt(x);
    if (t != 22) return 1; // a=0, c=2, c=2 -> 022
    if (es[es.len] != .a) return 2; // sentinel is .a (value 0)

    // local sentinel enum array, different sentinel
    var ls: [4:.end]Tok = .{ .a, .b, .c, .a };
    ls[3] = .b;
    var u: u32 = 0;
    for (ls) |x| u = u * 10 + @backingInt(x);
    if (u != 121) return 3; // 0,1,2,1
    if (ls[ls.len] != .end) return 4; // sentinel is .end (value 3)

    // index the local array directly
    if (ls[0] != .a) return 5;
    if (ls[2] != .c) return 6;
    return 0;
}
