// Function pointer passed as a CALLBACK argument and invoked inside the callee.
// The fn-ptr parameter holds a __FTABLE index, so `f(x)` inside `apply`
// dispatches through the table. `&sq` at the call site lowers to its index.
fn apply(f: *const fn (i32) i32, x: i32) i32 {
    return f(x) + f(x + 1);
}
fn sq(x: i32) i32 {
    return x * x;
}
export fn run_test() i32 {
    if (apply(&sq, 3) != 25) return 1; // sq(3)+sq(4) = 9+16 = 25
    return 0;
}
