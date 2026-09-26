// Address-of a local POINTER variable that ESCAPES. `&p` where `p` is a `*S` local
// produces a `**S` the callee dereferences with `*a0` (a real heap load of the
// stored pointer). The transpiler collapses `&local` to identity - correct for a
// struct VALUE (whose value is its heap offset) but wrong for a pointer VARIABLE,
// whose `&p` is the slot's own address. The collapse passed p's value, so the
// callee dereferenced garbage and mutations through the out-parameter were lost.
//
// Fix: a single-star struct-pointer local whose address is taken gets a 4-byte heap
// slot (still tracked in struct_ptrs so `p->field` resolves the tag; the member
// chain loads p's value from the slot). The C backend introduces this `&localPtr`
// idiom on its own (`t2 = &t1; *t2`), so this also hardens that whole shape.
//
// Covers: out-parameter set (`out.* = src`), reseating a pointer through a helper,
// field reads/writes before and after the reseat, and a two-pointer swap helper.
// Self-checks (returns 0 on success).
const S = struct { v: i32, w: i32 };

fn bumpHead(pp: *?*S) void {
    if (pp.*) |n| n.v += 100;
}
fn reseat(pp: **S, target: *S) void {
    pp.* = target;
}
fn swap(a: **S, b: **S) void {
    const t: *S = a.*;
    a.* = b.*;
    b.* = t;
}

export fn run_test() i32 {
    // --- out-parameter through a pointer-to-optional-pointer ---
    var a = S{ .v = 1, .w = 0 };
    var p: ?*S = &a;
    bumpHead(&p); // a.v -> 101
    if (a.v != 101) return 1;
    if (p) |n| {
        if (n.v != 101) return 2;
    } else return 3;

    // --- reseat a pointer via a helper, with field access on both sides ---
    var b = S{ .v = 10, .w = 20 };
    var c = S{ .v = 30, .w = 40 };
    var q: *S = &b;
    q.v += 5; // b.v -> 15 (field write through addr-taken ptr before escape)
    reseat(&q, &c); // q -> c
    q.w += 1; // c.w -> 41
    if (b.v != 15) return 4;
    if (c.w != 41) return 5;
    if (q.v != 30) return 6; // q now reads c

    // --- swap two pointers through a double-pointer helper ---
    var x = S{ .v = 100, .w = 0 };
    var y = S{ .v = 7, .w = 0 };
    var px: *S = &x;
    var py: *S = &y;
    swap(&px, &py);
    px.v += 1; // px -> y -> y.v = 8
    py.v += 2; // py -> x -> x.v = 102
    if (x.v != 102) return 7;
    if (y.v != 8) return 8;

    return 0;
}
