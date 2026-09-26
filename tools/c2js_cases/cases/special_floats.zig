//! Non-finite float constants. The Zig C backend emits inf/nan NOT through
//! zig_make_fNN(hexfloat, bits) but through zig_make_special_fNN(sign, name,
//! arg, repr) / zig_init_special_fNN(...) - a distinct form. Both the runtime
//! expression path and the static data-image path must map these to JS
//! Infinity / -Infinity / NaN (a bare bit-reconstruction would mis-decode, and
//! a zeroed data slot would read back as 0). run_test() returns 0 on success.

const std = @import("std");

fn isHuge(x: f32) bool {
    return x > 1.0e30;
}

// data-image path: a var global initialised to a non-finite constant
var inf_global: f32 = std.math.inf(f32);

export fn run_test() i32 {
    // runtime-expression path
    const pinf = std.math.inf(f32);
    const ninf = -std.math.inf(f32);
    const n = std.math.nan(f32);

    if (!isHuge(pinf)) {
        return 1;
    } // +inf is huge
    if (!(ninf < -1.0e30)) {
        return 2;
    } // -inf is hugely negative
    if (pinf == ninf) {
        return 3;
    } // +inf and -inf differ
    if (n == n) {
        return 4;
    } // NaN never equals itself
    if (pinf != pinf) {
        return 5;
    } // +inf is not NaN

    // data-image path: read the global back through a volatile load
    const p: *volatile f32 = &inf_global;
    if (!isHuge(p.*)) {
        return 6;
    } // the static slot must hold +inf, not 0

    return 0;
}
