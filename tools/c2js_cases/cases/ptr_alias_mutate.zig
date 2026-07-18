// Pointer aliasing and mutation through pointers, with 64-bit elements (a prime
// place for silent store/load-width or addressing miscompiles). Covers: two
// pointers to the same element, a pointer to a struct field, an array of pointers
// mutated through, a swap, and pointer-arithmetic walking. All must observe each
// other's writes through the single shared __MEM heap. Self-checking.
const S = struct { a: u64, b: u32, c: u64 };
var arr: [4]u64 = .{ 0x100000001, 0x200000002, 0x300000003, 0x400000004 };
var s: S = .{ .a = 0, .b = 0, .c = 0 };
var ga: u64 = 0x100000001;
var gb: u64 = 0x200000002;

export fn run_test() i32 {
    // aliasing the same element
    const p1: *u64 = &arr[1];
    const p2: *u64 = &arr[1];
    p1.* +%= 0x500000005;
    if (p2.* != 0x700000007) return 1;
    if (arr[1] != 0x700000007) return 2;

    // pointer to struct fields (u64 around a u32)
    const pa: *u64 = &s.a;
    const pc: *u64 = &s.c;
    pa.* = 0x100000001;
    pc.* = 0x300000003;
    s.b = 42;
    pa.* +%= pc.*;
    if (s.a != 0x400000004) return 3;
    if (s.c != 0x300000003) return 4;
    if (s.b != 42) return 5;

    // array of pointers, mutate through
    const ptrs = [_]*u64{ &ga, &gb };
    for (ptrs) |p| p.* +%= 0x1000000010;
    ptrs[1].* +%= 0xF;
    if (ga != 0x1100000011) return 6;
    if (gb != 0x1200000021) return 7;

    // swap via pointers
    swap(&ga, &gb);
    if (ga != 0x1200000021) return 8;
    if (gb != 0x1100000011) return 9;

    // pointer-arithmetic walk + mutate
    var p: [*]u64 = &arr;
    p += 2; // -> arr[2]
    var i: usize = 0;
    while (i < 2) : (i += 1) p[i] +%= 0x100000000;
    if (arr[2] != 0x400000003) return 10;
    if (arr[3] != 0x500000004) return 11;
    return 0;
}
fn swap(p: *u64, q: *u64) void {
    const tmp = p.*;
    p.* = q.*;
    q.* = tmp;
}
