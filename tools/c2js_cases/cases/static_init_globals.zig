// Regression: static initialization of globals and the `*(&X)` field-store
// shape the Zig C-backend emits for optional/nested-struct payloads.
//
// Exercises: optional scalars and structs with the lazy `if (x == null) x = ...`
// pattern (so the `?T = null` static `is_null` flag must be honoured), writing a
// nested payload field through `*(&(&opt->payload)->field)`, zero-init `bool`
// globals used as one-shot flags, and writing the MIDDLE bool of a packed-bool
// struct (byte-addressed - must not clobber its neighbours). run_test() returns
// 0 on success; the harness also asserts the generated JS has zero markers.
const S = struct { x: u32, y: u32 };
const Flags = struct { a: bool, b: bool, c: bool };

var opt_scalar: ?u32 = null;
fn getScalar() u32 {
    if (opt_scalar == null) {
        opt_scalar = 99;
    }
    return opt_scalar.?;
}

var opt_struct: ?S = null;
fn getStruct() S {
    if (opt_struct == null) {
        opt_struct = .{ .x = 3, .y = 4 };
    }
    return opt_struct.?;
}

var flags: Flags = .{ .a = false, .b = false, .c = false };
var counter: u32 = 0;
var done: bool = false;

export fn run_test() i32 {
    // optional scalar: lazy init on first use, and it sticks
    if (getScalar() != 99) {
        return 1;
    }
    if (getScalar() != 99) {
        return 2;
    }

    // optional struct: lazy init writes payload fields via the *(&X) store
    const s: S = getStruct();
    if (s.x != 3 or s.y != 4) {
        return 3;
    }

    // write the middle bool of a packed-bool struct; byte addressing must leave
    // the neighbouring bools untouched
    flags.b = true;
    if (flags.a) {
        return 4;
    }
    if (!flags.b) {
        return 5;
    }
    if (flags.c) {
        return 6;
    }

    // zero-init bool global as a one-shot flag
    if (!done) {
        counter += 1;
        done = true;
    }
    if (!done) {
        counter += 1;
        done = true;
    }
    if (counter != 1) {
        return 7;
    }
    if (!done) {
        return 8;
    }

    // reassign an optional back to null, then re-init
    opt_scalar = null;
    if (opt_scalar != null) {
        return 9;
    }
    if (getScalar() != 99) {
        return 10;
    }

    return 0;
}
