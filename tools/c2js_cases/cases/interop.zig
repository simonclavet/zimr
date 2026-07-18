//! JS interop through the raw kernel (the helper layer is covered by the demo
//! scenario). Exercises property reads, numeric/float args, and a string
//! argument — the string travels through js_str + js_call, the path where the
//! pointer-field load once returned an address instead of the string pointer.
//! Runs against a `fixture` object the test runner installs on globalThis.
//! run_test() returns 0 on success.

const Handle = u32;
extern fn js_global() Handle;
extern fn js_get(
    o: Handle,
    p: [*]const u8,
    l: u32,
) Handle;
extern fn js_call1(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
) Handle;
extern fn js_call2(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) Handle;
extern fn js_str(p: [*]const u8, l: u32) Handle;
extern fn js_num(x: f64) Handle;
extern fn js_to_num(v: Handle) f64;
extern fn js_truthy(v: Handle) u32;

fn prop(o: Handle, comptime name: []const u8) Handle {
    return js_get(o, name.ptr, name.len);
}

export fn run_test() i32 {
    const fx: Handle = prop(js_global(), "fixture");

    // property read
    if (@as(i32, @intFromFloat(js_to_num(prop(fx, "x")))) != 42) {
        return 1;
    }

    // numeric-args method call: fixture.add(3, 4) == 7
    const sum: Handle = js_call2(fx, "add", 3, js_num(3), js_num(4));
    if (@as(i32, @intFromFloat(js_to_num(sum))) != 7) {
        return 2;
    }

    // string argument round-trips: fixture.strlen("hello") == 5
    const hello = "hello";
    const len: Handle = js_call1(fx, "strlen", 6, js_str(hello, hello.len));
    if (@as(i32, @intFromFloat(js_to_num(len))) != 5) {
        return 3;
    }

    // float args: fixture.scale(2.5, 4.0) == 10.0
    const scaled: f64 = js_to_num(js_call2(fx, "scale", 5, js_num(2.5), js_num(4.0)));
    if (scaled < 9.999 or scaled > 10.001) {
        return 4;
    }

    // truthiness
    if (js_truthy(prop(fx, "flag")) == 0) {
        return 5;
    }

    return 0;
}
