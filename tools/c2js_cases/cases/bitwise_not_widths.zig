// `~x` across every value domain c2js models. Compiler 1857 stopped emitting the
// C `~` operator and now routes every integer NOT through zig.h's
// `zig_not_uN(x, bits)` / `zig_not_iN(x, bits)`; until that helper was modelled
// the whole class lowered to the constant 0 — MD5 went silently wrong, and
// math.rotl with it.
//
// Each reference recomputes the value WITHOUT `~`, so it lowers through a
// different path than the thing under test: `x ^ maxInt` for the unsigned forms
// (a plain C XOR) and `-x - 1` for the signed ones (plain arithmetic). A
// reference spelled `~x` would be a tautology.
//
// The sub-byte widths are what catches a suffix-vs-bits mistake: a u5 lives in a
// uint8_t, so the call is `zig_not_u8(x, 5)` and must mask with 31 — reading the
// width off the `u8` name suffix would mask with 255 and hand every downstream
// shift a value eight times too large.
var seed: u32 = 0x9E3779B9;

/// An LCG through a mutable global, so the operands are genuinely runtime
/// values. A comptime-foldable input would let the compiler evaluate `~x` and
/// the reference together and agree without ever emitting zig_not_.
fn next() u32 {
    seed = seed *% 1664525 +% 1013904223;
    return seed;
}

export fn run_test() i32 {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        const r: u32 = next();

        // u32 — the MD5 I-round path (`y ^ (x | ~z)`).
        if (~r != (r ^ 0xFFFFFFFF)) {
            return 1;
        }

        // u5 in u8 storage — the math.rotl shift-amount path.
        const u5v: u5 = @truncate(r);
        if (~u5v != (u5v ^ 31)) {
            return 2;
        }

        // i32 — signed at exactly 32 bits (the `| 0` canonical form).
        const i32v: i32 = @bitCast(r);
        if (~i32v != (-%i32v -% 1)) {
            return 3;
        }

        // i7 — signed sub-byte, so the result must be SIGN-extended, not masked.
        const i7v: i7 = @truncate(i32v);
        if (~i7v != (-%i7v -% 1)) {
            return 4;
        }

        // u64 / i64 — the BigInt domain, where `~` is a BigInt op and the
        // narrowing is asUintN/asIntN rather than a Number mask.
        const u64v: u64 = (@as(u64, r) << 32) | @as(u64, next());
        if (~u64v != (u64v ^ 0xFFFFFFFFFFFFFFFF)) {
            return 5;
        }
        const i64v: i64 = @bitCast(u64v);
        if (~i64v != (-%i64v -% 1)) {
            return 6;
        }

        // u48 — a 33-63 bit width, where the uint64_t storage type and the real
        // width disagree inside the BigInt domain.
        const u48v: u48 = @truncate(u64v);
        if (~u48v != (u48v ^ 0xFFFFFFFFFFFF)) {
            return 7;
        }

        // The composite the bug was found in: rotate-left, whose right-hand
        // shift amount is `~b + 1` on a 5-bit value.
        const s: u5 = @truncate(r);
        const rotated: u32 = (r << s) | (r >> (~s +% 1));
        const ref_shift: u5 = @truncate(32 - @as(u32, s));
        if (rotated != ((r << s) | (r >> ref_shift))) {
            return 8;
        }
    }

    // Pin the LCG so a compiler that folded the whole loop away would disagree
    // with the native oracle rather than pass vacuously.
    if (seed == 0x9E3779B9) {
        return 9;
    }
    return 0;
}
