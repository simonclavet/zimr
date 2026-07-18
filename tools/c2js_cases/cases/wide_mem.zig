//! 64-bit integers living IN MEMORY — struct fields, array elements, and values
//! reached through a pointer — round-trip correctly within 2^53. Previously a
//! 64-bit heap load/store touched only the low 32-bit word, so the high bits
//! were silently lost; the centralized __ld/st64 path (two little-endian words,
//! with sign handling) plus a true 8-byte element stride fixed it. run_test()
//! returns 0 on success, else a nonzero code for the first failed check.

const S = struct { id: u64, tag: i64, n: u32 };

fn storePtr(p: *u64, v: u64) void {
    p.* = v;
}

export fn run_test() i32 {
    // u64 struct field above 2^32
    var s: S = undefined;
    var v: u64 = 1;
    var i: u32 = 0;
    while (i < 42) : (i += 1) {
        v *%= 2;
    } // 2^42
    s.id = v +% 7; // 2^42 + 7
    s.tag = -(@as(i64, 1) << 41) - 3; // negative i64 below -2^32
    s.n = 9;
    if (s.id != 4398046511111) return 1; // 2^42 + 7
    if (s.tag != -2199023255555) return 2; // -(2^41) - 3
    if (s.n != 9) return 3;

    // negative i64 in an array (element stride must be 8 bytes)
    var arr: [3]i64 = undefined;
    arr[0] = 1;
    arr[1] = -(@as(i64, 1) << 40) - 5; // -(2^40) - 5
    arr[2] = 3;
    if (arr[1] != -1099511627781) return 4;
    if (arr[0] + arr[2] != 4) return 5;

    // u64 stored/loaded through a pointer to a heap-backed array element,
    // near the top of the safe range
    var buf: [2]u64 = undefined;
    buf[0] = 1;
    storePtr(&buf[1], 9007199254740990); // 2^53 - 2
    if (buf[1] != 9007199254740990) return 6;
    if (buf[0] != 1) return 7;

    return 0;
}
