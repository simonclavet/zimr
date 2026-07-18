// Address of a local scalar; write through it and read back. (Once listed as a
// gap; verified working and locked in.)
export fn run_test() i32 {
    var x: i32 = 5;
    const p: *i32 = &x;
    p.* = 7;
    p.* +%= 3;
    if (x != 10) return 1;
    return 0;
}
