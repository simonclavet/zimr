// @memcpy of fixed arrays must actually copy. Regression for the silent
// miscompile where the wrapper's `.array` field decayed wrong (scalar-loaded
// instead of yielding its base address), making the copy a no-op.
export fn run_test() i32 {
    const a = [_]i32{ 11, 22, 33 };
    var b = [_]i32{ 0, 0, 0 };
    @memcpy(&b, &a);
    if (b[0] != 11 or b[1] != 22 or b[2] != 33) return 1;
    // copy into a non-zero destination too
    const z = [_]i32{ 100, 200, 300 };
    @memcpy(&b, &z);
    if (b[0] != 100 or b[2] != 300) return 2;
    return 0;
}
