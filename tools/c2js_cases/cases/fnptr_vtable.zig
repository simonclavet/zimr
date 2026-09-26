// Vtable-style struct with multiple function-pointer fields, one of which is
// reassigned. Mixes several indirect calls through distinct fields plus a
// mutable-field store - the general shape behind interface/dispatch objects.
const VT = struct { area: *const fn (i32) i32, perim: *const fn (i32) i32 };
fn sqArea(s: i32) i32 {
    return s * s;
}
fn sqPerim(s: i32) i32 {
    return s * 4;
}
export fn run_test() i32 {
    var v = VT{ .area = &sqArea, .perim = &sqPerim };
    var total: i32 = v.area(5) + v.perim(5); // 25 + 20 = 45
    v.area = &sqPerim; // repoint area at perim
    total += v.area(3); // 12
    if (total != 57) return 1;
    return 0;
}
