# Zig 0.14 → 0.16 Migration Guide

Saved turn 280 from Simon's upload.  The verbatim guide is below;
my zimr-specific verification notes + cleanup-pattern recipes
follow after.

---

## 0.15.1

**usingnamespace Removed**
```zig
// 0.14
pub usingnamespace @import("f.zig");
// 0.16
const f = @import("f.zig");
pub const a = f.a;
```

**async/await Removed**
```zig
// 0.14
var f = async run(); await f;
// 0.16
const t = try std.Thread.spawn(.{}, run, .{}); t.join();
```

**Non-exhaustive Enum Switch**
```zig
// 0.14
switch(v) { .a => {} }
// 0.16
switch(v) { .a => {}, _ => {} }
```

**Lossy Int->Float Coercion Forbidden**
```zig
// 0.14
const f: f32 = 16777217;
// 0.16
const f: f32 = @floatFromInt(16777217);
```

**Inline Asm Typed Clobbers**
```zig
// 0.14
asm("..." : [ret] "=r" (-> usize));
// 0.16
asm("..." : [ret] "=r" (-> usize)); // Explicit type strictly enforced
```

**I/O (StdOut & Buffers)**
```zig
// 0.14
try std.io.getStdOut().writer().print("hi\n", .{});
// 0.16
var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
try bw.writer().print("hi\n", .{});
try bw.flush();
```

**@ptrCast Single-Item to Slice**
```zig
// 0.16: Now allowed to cast a single item pointer to a slice of length 1.
const slice: *[1]u8 = @ptrCast(ptr);
```

**Arithmetic on undefined**
Strict rules now apply; operations on undefined are explicitly tracked and error if improperly utilized.

## 0.16.0

**@cImport Removed**
```zig
// 0.14
const c = @cImport(@cInclude("stdio.h"));
// 0.16
// In build.zig: b.addTranslateC(...)
const c = @import("c");
```

**@Type Replaced**
```zig
// 0.14
const T = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = 32 } });
// 0.16
const T = @Int(.unsigned, 32);
```

**@floor, @ceil, @round, @trunc Return Integers (Coercion)**
Because these now return integer types, they can implicitly coerce to other types (like floats or wider ints) under the new small-integer coercion rules.
```zig
// 0.14
const a: f32 = @floor(3.14); // returns f32
// 0.16
const a: i32 = @floor(3.14); // returns int, coerces freely if safe
```

**Small Integer Coercion to Floats**
```zig
// 0.16: Small integer types can now implicitly coerce to floating point types.
const f: f32 = @as(u8, 5);
```

**Runtime Vector Index Forbidden**
```zig
// 0.14
const v = vec[idx];
// 0.16
const arr: [4]f32 = vec;
const v = arr[idx];
```

**Array/Vector In-Memory Coercion Forbidden**
```zig
// 0.14
var arr: [4]u32 = vec;
// 0.16
var arr: [4]u32 = undefined;
@memcpy(&arr, &vec);
```

**Unary Float Builtins Forward Result Type**
```zig
// Builtins like @sqrt now forward the result type directly based on the operand.
```

**Packed Types Rules**
```zig
// 0.14
const S = packed struct { a: u7, p: *u32 };
// 0.16
// Forbid unused bits: must explicitly pad
// Forbid pointers: must use integers
const S = packed struct { a: u7, _pad: u1, p: usize };
```
*Note: Explicit backing integers are now allowed on packed unions, but implicit backing is forbidden in `extern` contexts.*

**Equality Comparisons on Packed Unions**
```zig
// 0.16: Equality checks on packed unions directly compare the underlying backing integer.
```

**Pointer Alignment Cast**
```zig
// 0.14
const ptr: *align(4) u32 = &v;
// 0.16
// Explicitly-aligned pointers are distinct from naturally-aligned ones.
const ptr: *align(4) u32 = @alignCast(&v);
```

**Comptime-Only Pointers**
Pointers to comptime-only types are no longer strictly comptime-only themselves.

**Lazy Field Analysis**
Struct fields are now analyzed lazily, meaning errors in unused fields might not trigger a compile failure until instantiated.

**Zero-bit Tuple Fields**
Zero-bit fields in tuples are no longer implicitly `comptime`.

**Trivial Local Address Return Forbidden**
```zig
// 0.14
fn f() *u32 { var x: u32 = 0; return &x; }
// 0.16
fn f() u32 { var x: u32 = 0; return x; } // Return by value required
```

**Global Env/Args Removed**
```zig
// 0.14
var args = std.process.args();
// 0.16
var args = try std.process.argsWithAllocator(allocator);
```

**Dependency Loop Rules Simplified**
Dependency resolution handles cyclic graphs differently, resolving simplified rules in `build.zig` files.

---

# zimr-specific notes (turn 280 verification)

The above is the verbatim guide.  Notes below add empirical
testing against actual `0.16.0` toolchain + zimr-codebase-specific
cleanup patterns.

## The `@floor`/`@ceil`/`@round`/`@trunc` int-coercion result rule

**The single highest-leverage change for zimr.**  These builtins
now return an integer type directly when the result-location is
typed as integer.  That eliminates the whole
`@intFromFloat(@floatFromInt(x) * scale)` ceremony in one go.

### Verified turn 280 against `0.16.0`:

```zig
// All three of these compile and produce the same result for positive vals:
const px1: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent_i16)) * scale);  // before
const px2: i32 = @intFromFloat(ascent_i16 * scale);                            // turn 279 cleanup
const px3: i32 = @floor(ascent_i16 * scale);                                   // turn 280 — best

// Bare @floor (no result location) still returns the legacy float type:
const px4 = @floor(@as(f32, 3.7));  // → f32 = 3.0
```

### Choosing between `@floor`, `@ceil`, `@round`, `@trunc`, `@intFromFloat`

For **positive** values, all five give the same result.  For
**negative** values they differ:

| Builtin            | -3.9 → | Use case                            |
|--------------------|--------|-------------------------------------|
| `@floor`           | -4     | Toward -∞.  Right answer for most pixel math (line wrap, scroll clamps). |
| `@trunc`           | -3     | Toward 0.  Matches C-style `(int)x`. |
| `@intFromFloat`    | -3     | Same as `@trunc`.                   |
| `@ceil`            | -3     | Toward +∞.                          |
| `@round`           | -4     | Nearest, ties away from zero.       |

**For zimr's widget/pixel/font math**: prefer `@floor` in 0.16 —
both shorter than `@intFromFloat` AND semantically correct for
negative coordinates (e.g. a left-edge widget at x=-0.5 should
land at pixel -1, not pixel 0).

### When the result type is float (not int), no change needed

`@floor` without an integer result-location still returns the
input's float type.  So `const x: f32 = @floor(f)` keeps working
exactly as in 0.14.

## Other 0.16 patterns relevant to zimr's codebase

### `@as(T, @intCast(x))` / `@as(T, @floatFromInt(x))` — outer @as redundant

Already covered in plan steps 4.4 and 4.5 (filed turn 278/279).

### Small-int → f32 implicit coerce (lossless only)

```zig
const a: f32 = some_i16_var;      // ✓ — i16 fits in f32 mantissa
const a: f32 = some_u8_var;       // ✓
const a: f32 = some_i32_var;      // ✗ — error: expected f32, found i32
const a: f32 = some_usize_var;    // ✗ — usize is i64-wide on 64-bit
```

Implicit coerce works for `i8`/`u8`/`i16`/`u16` only (anything
whose integer values all fit in f32's 23-bit mantissa exactly).
Most zimr code uses `i32`/`usize` so the bare-coerce form is
rarely applicable here.

### Binary ops `* + - /` do NOT propagate result-location to operands

```zig
const t: f32 = i32_var * f32_var;  // ✗ — error
```

This is why the `@floor`/`@intFromFloat` wrapping trick (rule
above) is so useful: the BUILTIN propagates result-location even
though the binary `*` inside doesn't.

### Non-exhaustive enum switch needs `_ => {}` arm

If zimr ever adds `extern enum` or `enum (u8)` with named values
plus catch-all unknowns, every `switch` over it needs an
explicit `_ => {}` branch.  Watch for this when porting raylib
enums.

### `@ptrCast` single → slice-of-1 allowed

Was previously an error.  Useful when bridging single-item to
slice APIs (e.g. `@memcpy(&dest_byte, slice)` patterns).

### Pointer-alignment cast `@alignCast` required

When converting `*T` to `*align(N) T`, must wrap in `@alignCast`.
Affects any zimr code that takes alignment-sensitive pointers
(rare, but font atlas pixel pointers + GPU buffer pointers
qualify).

### Trivial local-address return forbidden

```zig
fn make_color() *Color {
    var c: Color = .{ ... };
    return &c;   // ✗ — escapes stack
}
```

Caught by zig in 0.16 instead of being silent UB.  Probably no
hits in zimr's current code (we don't do this), but worth
knowing.

### Packed struct restrictions

Pointers forbidden inside `packed struct`; all bits must be
explicit (use `_pad` fields for unused).  Affects any zimr
binary-format parsers (codecs.zig glyph/font header structs are
the obvious candidates) — should audit if anything regresses.

## Cleanup decision tree (for incremental sweeps per plan steps 4.4/4.5)

When you encounter `@as(...)`-heavy float-math, ask:

1. **Is the result going to an int slot?** → `@floor` /
   `@ceil` / `@round` is the shortest path.  Prefer `@floor`
   unless you specifically want one of the others.
2. **Is the result going to a float slot?** → Drop the outer
   `@as(f32, ...)` wrap; result-location does it.  Keep
   `@floatFromInt(...)` only if the operand is `i32`/`usize`
   (lossless rule).
3. **Is the multiplication INSIDE another builtin
   (`@intFromFloat`, `@floor`, `@sqrt`, ...)?** → Drop the
   inner `@floatFromInt` entirely — the outer builtin
   propagates f32 to its operand subexpressions.
4. **Is the binary expression bare (no wrapping builtin)?** →
   You're stuck with explicit `@floatFromInt` on at least the
   int operand.  Binary ops don't propagate.

## Where this guide lives

- This file: `src/notes/zig-0.16-migration-guide.md`.  Reference
  for ALL Zig version-drift questions.
- Cleanup plan: `src/notes/imgui-plan.md` steps 4.4, 4.5, 4.6.
- Per-turn pointer in `claude.md` (Zig 0.16 result-location
  rules section).

Update this file when you learn new patterns.  The
self-improvement rule from `claude.md` applies here too.
