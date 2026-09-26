//! c2js CANARY - proves the transpiler still lowers Zig's C backend correctly
//! after a compiler bump.
//!
//! The `/*?...*/` marker gate in `tools/c2js.zig` catches constructs c2js KNOWS
//! it cannot model. It cannot catch the other half: a construct c2js models
//! WRONGLY. That is what bit us on 0.17.0-dev.1676, where zig.h renamed the
//! integer casts and 99 call sites per bundle silently became the literal `0`.
//!
//! THE ORACLE IS ZIG'S COMPTIME EVALUATOR. `battery()` is a pure function over a
//! seed. `canaryExpected()` evaluates it at COMPTIME, so the answer is a constant
//! folded by the compiler itself and never passes through c2js. `canary(seed)`
//! runs the same code at RUNTIME, so every operation lowers to a zig.h helper,
//! through the C backend, through c2js, into JavaScript. The seed arrives as a
//! parameter precisely so the optimizer CANNOT fold the runtime path back into
//! the constant and make the comparison tautological.
//!
//! Any disagreement means c2js is emitting wrong VALUES - the failure mode that
//! ships green through build, lint, fmt and verify_imports.
//!
//! Run: `zig build c2js-canary` (see webtests/c2js_canary.mjs).
//!
//! NOT covered here: atomics and >64-bit heap traffic, which comptime cannot
//! evaluate. Those are marker-emitting paths, so the gate owns them.

/// The fixed seed the expected value is computed from. The runtime entry takes
/// its seed as an argument, so this constant never reaches that path.
const seed: u32 = 0x9E3779B9;

/// A packed struct exercises sub-width field loads/stores, which lower to
/// masking helpers with a `bits` argument narrower than the storage width -
/// exactly the case where treating a same-width cast as identity goes wrong.
const Packed = packed struct {
    a: u9,
    b: u3,
    c: i7,
    d: u13,
};

/// Every operation here lowers to a zig.h runtime helper. Keep it pure and
/// comptime-evaluable: no atomics, no pointers, no floats (the float path needs
/// `zm`, which this standalone root cannot import).
fn battery(s: u32) u32 {
    var acc: u32 = s;

    // sub-width truncation: masks to `bits`, NOT to the storage width
    const t9: u9 = @truncate(acc);
    const t3: u3 = @truncate(acc >> 7);
    acc +%= t9;
    acc ^= t3;

    // signed truncation sign-extends from `bits`, a different helper body
    const si: i32 = @bitCast(acc);
    const t7: i7 = @truncate(si);
    acc +%= @as(u32, @bitCast(@as(i32, t7)));

    // same-width bitCast round trip (the shape that silently became 0)
    const back: u32 = @bitCast(si);
    acc ^= back;

    // widening and narrowing intCast
    const wide: u64 = @as(u64, acc) *% 0x0100_0001_9F;
    const narrow: u32 = @truncate(wide >> 11);
    acc +%= narrow;

    // wrapping arithmetic at several widths
    var b8: u8 = @truncate(acc);
    b8 = b8 *% 251 +% 7;
    var b16: u16 = @truncate(acc >> 5);
    b16 = b16 *% 40503 -% 12345;
    acc ^= @as(u32, b8) | (@as(u32, b16) << 8);

    // shifts, including a shift amount that varies with the seed
    const sh: u5 = @truncate(acc);
    acc = (acc << sh) | (acc >> (31 - sh));

    // signed division and remainder round toward zero, unlike JS `>>`
    const sv: i32 = @bitCast(acc);
    const q: i32 = @divTrunc(sv, -1234567);
    const r: i32 = @rem(sv, 7919);
    acc +%= @bitCast(q ^ r);

    // 64-bit division/remainder go through the BigInt path
    const w64: u64 = (@as(u64, acc) << 32) | 0xDEAD_BEEF;
    acc ^= @truncate(w64 / 1_000_003);
    acc +%= @truncate(w64 % 4_294_967_291);

    // 128-bit arithmetic
    const w128: u128 = @as(u128, w64) *% 0xFFFF_FFFF_FFFF_FFC5;
    acc ^= @truncate(w128 >> 64);

    // packed struct: sub-width fields stored and read back
    const p: Packed = .{
        .a = @truncate(acc),
        .b = @truncate(acc >> 9),
        .c = @truncate(@as(i32, @bitCast(acc))),
        .d = @truncate(acc >> 12),
    };
    acc +%= @as(u32, p.a) ^ (@as(u32, p.b) << 9);
    acc ^= @as(u32, @bitCast(@as(i32, p.c))) +% (@as(u32, p.d) << 12);

    return acc;
}

/// The runtime path: every op lowers through the C backend and c2js.
pub export fn canary(s: u32) u32 {
    return battery(s);
}

/// The oracle: the same computation folded by Zig's comptime evaluator, so it
/// never passes through c2js. Node compares this against `canary(canarySeed())`.
pub export fn canaryExpected() u32 {
    return comptime battery(seed);
}

/// The seed the oracle used, handed to the runner so the two sides agree.
pub export fn canarySeed() u32 {
    return seed;
}
