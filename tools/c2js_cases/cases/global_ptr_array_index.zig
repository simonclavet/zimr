//! Indexing a MUTABLE global array-of-pointers at a runtime index - `tbl[i].*`
//! where `var tbl = [_]*u32{ &a, &b, &c }`. The element-address lowering used to
//! emit a spurious load (`__HEAPU32[tbl_base] + i*4` instead of `tbl_base + i*4`),
//! reading garbage: silent, 0 markers. parseArrTag didn't recognize a pointer
//! element (`arr_N_ptr_*`), so the fixed-array element-address handler bailed and
//! the `&` fallback produced the load. Now a pointer element is a 4-byte slot, so
//! `&tbl->array[i]` strides correctly. (The const form is value-propagated to a
//! compound literal and was never affected.) run_test() returns 0 on success.

var ga: u32 = 10;
var gb: u32 = 20;
var gc: u32 = 30;
var tbl = [_]*u32{ &ga, &gb, &gc };

export fn run_test() i32 {
    // runtime-indexed read through each pointer element
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < tbl.len) : (i += 1) sum +%= tbl[i].*;
    if (sum != 60) return 1; // 10 + 20 + 30

    // constant index
    if (tbl[1].* != 20) return 2;

    // write through a pointer-array element reaches the real global
    tbl[2].* = 99;
    if (gc != 99) return 3;
    if (tbl[2].* != 99) return 4;

    return 0;
}
