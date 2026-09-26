// Error unions (`E!T`): the Zig C-backend lowers them to a struct
// `{ T payload; uint16_t error; }` built with designated initializers, and the
// error codes to a C `enum { zig_error_Bad = 1u, ... }`. Regression for two
// gaps: designated-initializer compound literals, and unresolved enum constants
// (the error names) - both fixed (parseCompoundLiteral by-name routing +
// prescanEnums recording the constants).
const E = error{ TooBig, Negative };
fn checked(x: i32) E!i32 {
    if (x < 0) {
        return E.Negative;
    }
    if (x > 100) {
        return E.TooBig;
    }
    return x * 2;
}
fn sumChecked(a: i32, b: i32) E!i32 {
    const x: i32 = try checked(a);
    const y: i32 = try checked(b);
    return x + y;
}
export fn run_test() i32 {
    if ((checked(5) catch -1) != 10) {
        return 1;
    } // catch default (ok)
    if ((checked(-3) catch -1) != -1) {
        return 2;
    } // catch default (err)
    if ((checked(200) catch -7) != -7) {
        return 3;
    }
    const r: i32 = checked(-1) catch |err| switch (err) { // catch |err| + switch
        error.Negative => @as(i32, 1000),
        error.TooBig => 2000,
    };
    if (r != 1000) {
        return 4;
    }
    if ((sumChecked(10, 20) catch -1) != 60) {
        return 5;
    } // try propagation (ok)
    if ((sumChecked(10, 200) catch -1) != -1) {
        return 6;
    } // try propagation (err)
    var got: i32 = 0;
    if (checked(50)) |v| {
        got = v;
    } else |_| {
        got = -1;
    }
    if (got != 100) {
        return 7;
    } // if |val| else |err|
    return 0;
}
