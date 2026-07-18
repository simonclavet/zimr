// Aliasing through an ARRAY OF POINTERS. Two silent miscompiles lived here:
//
//   (1) Double-star store. `(*pp) = ptr` where `pp` is `struct X **` was lowered
//       as a struct byte-COPY (`__copy(pp, rhs, size)`) instead of a 4-byte
//       pointer-value store, because the store path consulted only struct_ptrs and
//       ignored pp_struct_ptrs. For a 4-byte struct the copy even dereferenced the
//       rhs offset, so the array ended up holding the POINTEES instead of the
//       swapped pointers. The read side already checked pp_load first; the store
//       side now mirrors that.
//
//   (2) Inline array-of-pointers element address. A wrapper field `struct X *a[N]`
//       carries ptr_elem (set for any pointer element), so `arr[i]` took the slice
//       `.ptr` LOAD path and dereferenced once too many. An inline array (f.size>4)
//       is laid out in place: element i is at base + i*4 and the stored pointer is
//       read by the later deref — no extra load.
//
// The swap below stores pointers through `*(&arr[i])` (exercises 1) and reads them
// back through `arr[i]` (exercises 2); the final field writes must land in the
// swapped targets. Self-checks (returns 0 on success).
const S = struct { v: i32 };

export fn run_test() i32 {
    var x = S{ .v = 7 };
    var y = S{ .v = 11 };
    var arr = [_]*S{ &x, &y };

    // read back before any swap: arr[0] -> x, arr[1] -> y
    if (arr[0].v != 7) return 1;
    if (arr[1].v != 11) return 2;

    // swap the two pointers via a temp (a `*(&arr[i]) = ptr` store each)
    const t = arr[0];
    arr[0] = arr[1];
    arr[1] = t;

    // arr[0] now -> y, arr[1] now -> x
    arr[0].v += 1; // y.v -> 12
    arr[1].v += 100; // x.v -> 107

    if (x.v != 107) return 3;
    if (y.v != 12) return 4;
    // the stored pointers must be the swapped ones (read through arr again)
    if (arr[0].v != 12) return 5;
    if (arr[1].v != 107) return 6;
    return 0;
}
