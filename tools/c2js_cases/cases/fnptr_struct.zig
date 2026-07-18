// function pointers stored in a struct, called indirectly and composed.
const Ops = struct {
    f: *const fn (i32) i32,
    g: *const fn (i32) i32,
};
fn fnDouble(x: i32) i32 {
    return x * 2;
}
fn fnInc(x: i32) i32 {
    return x + 1;
}
export fn run_test() i32 {
    const o = Ops{ .f = &fnDouble, .g = &fnInc };
    if (o.f(21) != 42) return 1;
    if (o.g(41) != 42) return 2;
    if (o.f(o.g(20)) != 42) return 3; // double(inc(20)) = double(21) = 42
    return 0;
}
