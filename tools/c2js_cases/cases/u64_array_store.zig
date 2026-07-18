// Element stores into a 64-bit-element array. The Zig C backend lowers these to
// `((arr_N_T*)&g)->array[i] = v` (a primitive-element array wrapper). structTagOf
// deliberately diverts such wrappers, so pre-fix BOTH the element store AND the
// whole-array value load were miscompiled: the store became an orphaned __ldu64
// (the value never reached memory) and `*(arr_N_T*)&g` dereferenced arr[0]'s low
// word as a copy SOURCE address — so @memset, @memcpy, and a direct `arr[i]=v`
// loop all read back as zero. Reference values are computed independently.
var dst: [4]u64 = undefined;
var src: [4]u64 = undefined;
var direct: [4]u64 = undefined;

export fn run_test() i32 {
    // @memset with a 64-bit (BigInt) fill
    @memset(&dst, 0xCAFEBABE_DEADBEEF);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (dst[i] != 0xCAFEBABE_DEADBEEF) return 1;
    }

    // direct element store loop
    i = 0;
    while (i < 4) : (i += 1) direct[i] = 0x1000000000 *% @as(u64, @intCast(i + 1));
    i = 0;
    while (i < 4) : (i += 1) {
        if (direct[i] != 0x1000000000 *% @as(u64, @intCast(i + 1))) return 2;
    }

    // @memcpy of a 64-bit-element array
    i = 0;
    while (i < 4) : (i += 1) src[i] = 0x1111111100000000 *% @as(u64, @intCast(i + 1));
    @memcpy(&dst, &src);
    i = 0;
    while (i < 4) : (i += 1) {
        if (dst[i] != src[i]) return 3;
    }
    return 0;
}
