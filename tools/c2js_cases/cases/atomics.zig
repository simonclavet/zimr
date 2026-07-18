// Atomic operations. In single-threaded wasm these are plain load/store/RMW (memory
// ordering is a no-op). The C backend emits them as function-like macros the
// preprocessor ignores; pre-fix, isTypeQualifierOrSpecifier treated the helper names
// (zig_atomic_store/_load, zig_atomicrmw_*) as TYPE specifiers, so each statement was
// mis-parsed as a declaration and SILENTLY DROPPED — the store/RMW never happened and
// an atomic load left a stale temp. Fix: exclude the atomic helper functions from the
// type-specifier set (so they parse as calls) and lower them to load/store/RMW, with
// the RMW result written to the first arg (the old value).
var g: u32 = 0;
var sink: u32 = 0;
fn ru(x: u32) u32 {
    sink +%= x;
    return x;
}

export fn run_test() i32 {
    // store must actually land (read g directly, non-atomically)
    @atomicStore(u32, &g, ru(100), .seq_cst);
    if (g != 100) return 1;

    // load reads the live value
    if (@atomicLoad(u32, &g, .seq_cst) != 100) return 2;

    // Add returns the OLD value and updates
    const a_old = @atomicRmw(u32, &g, .Add, 50, .seq_cst);
    if (a_old != 100) return 3;
    if (g != 150) return 4;

    // Sub
    const s_old = @atomicRmw(u32, &g, .Sub, 30, .seq_cst);
    if (s_old != 150) return 5;
    if (g != 120) return 6;

    // Xchg returns old, sets new
    const x_old = @atomicRmw(u32, &g, .Xchg, 7, .seq_cst);
    if (x_old != 120) return 7;
    if (g != 7) return 8;

    // bitwise And/Or/Xor
    g = 0xFF00;
    const an = @atomicRmw(u32, &g, .And, 0x0FF0, .seq_cst);
    if (an != 0xFF00 or g != 0x0F00) return 9;
    const orr = @atomicRmw(u32, &g, .Or, 0x00FF, .seq_cst);
    if (orr != 0x0F00 or g != 0x0FFF) return 10;
    const xr = @atomicRmw(u32, &g, .Xor, 0x0F0F, .seq_cst);
    if (xr != 0x0FFF or g != 0x00F0) return 11;

    // atomic on a stack local
    var local: u32 = ru(10);
    @atomicStore(u32, &local, 200, .seq_cst);
    const l_old = @atomicRmw(u32, &local, .Add, 55, .seq_cst);
    if (l_old != 200 or @atomicLoad(u32, &local, .seq_cst) != 255) return 12;

    return 0;
}
