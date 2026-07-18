// Array of function pointers, dispatched by index in a loop. Each `&fn` lowers
// to its __FTABLE index; `tbl[i](acc)` loads the index from the array and calls
// __FTABLE[idx]. Exercises fn-ptr values stored in an aggregate (not a struct
// field) and an indirect call whose callee is an array element.
fn add1(x: i32) i32 {
    return x + 1;
}
fn mul2(x: i32) i32 {
    return x * 2;
}
fn negate(x: i32) i32 {
    return -x;
}
export fn run_test() i32 {
    const tbl = [_]*const fn (i32) i32{ &add1, &mul2, &negate };
    var acc: i32 = 10;
    var i: usize = 0;
    while (i < tbl.len) : (i += 1) acc = tbl[i](acc);
    if (acc != -22) return 1; // negate(mul2(add1(10))) = negate(22) = -22
    return 0;
}
