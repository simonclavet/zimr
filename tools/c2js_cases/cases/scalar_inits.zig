//! Scalar global initializers, including the type-limit macros the C backend
//! emits as bare names (UINT32_MAX, INT32_MIN, UINT64_MAX, …) that used to
//! silently become 0. 32-bit limits are checked exactly. 64-bit globals now
//! round-trip their FULL value when it fits in 2^53 (via the centralized
//! __ld/st64 heap path); a value above 2^53 (UINT64_MAX) cannot be exact in a
//! JS Number, so for that one we only assert the initializer stored a huge
//! nonzero value rather than 0. run_test() returns 0 on success.

var u32max: u32 = 4294967295; // UINT32_MAX
var i32min: i32 = -2147483648; // INT32_MIN
var i32max: i32 = 2147483647; // INT32_MAX
var u8max: u8 = 255; // UINT8_MAX
var big: u32 = 4000000000; // > i32 max
var u64max: u64 = 18446744073709551615; // UINT64_MAX (> 2^53: only "huge, not 0" is checkable)
var u64big: u64 = 1099511627776; // 2^40: within 2^53; low word is 0, so a correct read proves the HIGH word stored
var u64val: u64 = 0xdead_beef; // within 2^53
var i64neg: i64 = -1099511627781; // negative i64, within 2^53

export fn run_test() i32 {
    if (u32max != 0xffff_ffff) return 1;
    if (i32min != -2147483648) return 2;
    if (i32max != 2147483647) return 3;
    if (u8max != 255) return 4;
    if (big != 4000000000) return 5;
    // UINT64_MAX is above 2^53; just prove the limit macro didn't collapse to 0.
    if (u64max < 1_000_000_000_000_000) return 6;
    // 64-bit globals within 2^53 now read their FULL value, not just the low word.
    if (u64big != 1099511627776) return 7;
    if (u64val != 0xdead_beef) return 8;
    if (i64neg != -1099511627781) return 9;
    return 0;
}
