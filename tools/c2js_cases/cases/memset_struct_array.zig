// @memset of a STRUCT-element array: `((arr_N_T*)&g)->array[i] = (struct T){...}`
// where T is a struct (here carrying a u64 field). structTagOf does NOT divert
// struct-element wrappers, but the per-element struct-copy store still fell
// through and was dropped (the address was computed, the copy of the struct
// literal was missing) - so every element kept its uninitialized fill.
const P = struct { a: u64, b: u32, c: i64 };
var arr: [3]P = undefined;
var arr2: [3]P = undefined;

export fn run_test() i32 {
    @memset(&arr, P{ .a = 0xCAFEBABE_1234, .b = 0x55, .c = -0x100000001 });
    for (arr) |p| {
        if (p.a != 0xCAFEBABE_1234) return 1;
        if (p.b != 0x55) return 2;
        if (p.c != -0x100000001) return 3;
    }
    // @memcpy of a struct array
    @memset(&arr2, P{ .a = 0x9988776655, .b = 0xAB, .c = 7 });
    @memcpy(&arr, &arr2);
    for (arr) |p| {
        if (p.a != 0x9988776655 or p.b != 0xAB or p.c != 7) return 4;
    }
    return 0;
}
