// Array of an enum whose tag type is < 32 bits (here enum(u8)). The synthetic
// array wrapper `arr_N_<enumTag>` previously sized the enum element at the default
// 4 bytes (enum-tag aliases are intentionally NOT width-resolved for user structs,
// where a scalar enum field uses a self-consistent 4-byte slot). For an ARRAY that
// breaks: the element STORE strides by the real width (1), but the whole-array
// struct copy + read used a 4-byte stride - the values read back garbage and the
// `switch` on them hit `unreachable`. Fix resolves enum-tag elements to their real
// width for array wrappers only (scalar enum fields keep the 4-byte slot).
const Color = enum(u8) { red, green, blue, alpha };
var arr: [4]Color = undefined;

// a struct with a SCALAR enum field must still work (4-byte slot, unchanged)
const S = struct { c: Color, n: u32 };
var s: S = undefined;

export fn run_test() i32 {
    arr[0] = .blue; // 2
    arr[1] = .red; // 0
    arr[2] = .alpha; // 3
    arr[3] = .green; // 1
    var t: u32 = 0;
    for (arr) |c| {
        const d: u32 = switch (c) {
            .red => 0,
            .green => 1,
            .blue => 2,
            .alpha => 3,
        };
        t = t * 10 + d;
    }
    if (t != 2031) return 1; // blue,red,alpha,green -> 2,0,3,1

    // a single mutated element read back correctly
    arr[1] = .alpha;
    if (arr[1] != .alpha) return 2;
    if (arr[0] != .blue or arr[2] != .alpha or arr[3] != .green) return 3;

    // scalar enum field (regression guard)
    s.c = .blue;
    s.n = 0x1234;
    if (s.c != .blue or s.n != 0x1234) return 4;
    return 0;
}
