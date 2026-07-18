// Sentinel-terminated arrays. A `[N:0]T` lowers to a wrapper whose name encodes
// the count with the sentinel-type id, e.g. `arr_4s177_u32` (count "4s177"). pre-fix
// parseArrTag failed to parse that count, so structTagOf DIVERTED a non-string
// sentinel array (treating it like a u8 string wrapper); a `t.array[i]` element
// access then fell through to a literal JS property access on a heap offset
// (`(number).array[i]` -> "Cannot read properties of undefined") — a runtime crash.
// Fix parses the count digits before the `s` marker so the wrapper is recognized.
// u8 sentinel arrays (strings) keep their existing path (regression-guarded here).
// ALSO guards the global under-allocation that recognizing the wrapper exposed: a
// sentinel array's global must get its FULL byte size (incl. the sentinel slot)
// from the wrapper's struct layout — not count*elem_size, which omits the sentinel
// slot and lets the next global overlap arr[N] (read back as that global's value).
var g32: [4:0]u32 = .{ 1, 2, 3, 4 };
var g64: [3:0]u64 = .{ 0x100000001, 0x200000002, 0x300000003 };
var acc: u64 = 0;
fn bump(x: u64) u64 {
    acc +%= x;
    return x;
}

export fn run_test() i32 {
    // non-string sentinel array (the crash case)
    var a: [4:0]u32 = .{ 10, 20, 30, 40 };
    a[1] = 25;
    var t: u32 = 0;
    for (a) |x| t += x;
    if (t != 10 + 25 + 30 + 40) return 1;
    if (a[a.len] != 0) return 2; // sentinel

    // a global sentinel array
    g32[0] = 100;
    var s: u32 = 0;
    for (g32) |x| s += x;
    if (s != 100 + 2 + 3 + 4) return 3;

    // u8 sentinel array (string-ish) still works
    var b: [3:0]u8 = .{ 65, 66, 67 };
    b[2] = 90;
    var u: u32 = 0;
    for (b) |c| u += c;
    if (u != 65 + 66 + 90) return 4;
    if (b[b.len] != 0) return 5;

    // 64-bit sentinel array: writing through `bump` mutates the `acc` global; if the
    // sentinel array under-allocated, `acc` would overlap g64[3] and the sentinel
    // read below would return acc's value instead of 0.
    g64[1] = bump(0xAAAABBBBCCCC);
    if (g64[g64.len] != 0) return 6; // sentinel must still be 0, not `acc`
    var w: u64 = 0;
    for (g64) |x| w +%= x;
    if (w != 0x100000001 + 0xAAAABBBBCCCC + 0x300000003) return 7;
    if (acc != 0xAAAABBBBCCCC) return 8;
    return 0;
}
