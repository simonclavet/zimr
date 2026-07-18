// Recursive function with a struct passed/returned BY VALUE (shadow-stack frame).
// An address-taken struct local in a recursive function lives on the per-call
// shadow-stack frame (__fp + N), NOT its static scratch slot. Two assignment
// shapes wrote to the STATIC slot while `&local`/reads used the FRAME, so the
// stored value was silently lost (reads hit uninitialized frame memory):
//   * whole-struct copy   `s = other;`     (parseAssign struct-value path)
//   * struct field store  `s.field = rhs;` (parseAssign name.field path)
// Both now resolve the destination through scratchBase (frame-aware).
// Self-checks (returns 0 on success).

const Acc = struct { sum: i64, count: i32 };

// whole-struct copy of a by-value param into a recursive local (`var a = acc;`)
fn collatz(n: u64, acc: Acc) Acc {
    if (n == 1) return .{ .sum = acc.sum + 1, .count = acc.count + 1 };
    var a: Acc = acc; // struct-value copy into an address-taken recursive local
    a.sum += @intCast(n);
    a.count += 1;
    return collatz(if (n % 2 == 0) n / 2 else 3 * n + 1, a);
}

const St = struct { a: i32, b: i32 };

// struct FIELD stores into a fresh recursive local each frame
fn go(n: i32) i32 {
    if (n <= 0) return 0;
    var s: St = undefined;
    s.a = n;
    s.b = n * 2;
    return s.a + s.b + go(n - 1);
}

export fn run_test() i32 {
    const r: Acc = collatz(6, .{ .sum = 0, .count = 0 });
    // 6,3,10,5,16,8,4,2,1 : sum=55 count=9
    if (r.sum != 55) return 1;
    if (r.count != 9) return 2;

    if (go(5) != 45) return 3; // 3*(1+2+3+4+5)

    return 0;
}
