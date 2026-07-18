# Ziggification candidates

> **Status as of May 2026 — fully closed, plus an aggressive
> follow-on sweep that found two real raylib-parity bugs.**
> The original 7-category audit below is preserved as the
> historical record.  Categories 1-7 closed in earlier work; an
> aggressive 10-turn sweep on top added typed enum dispatch,
> folded module globals, finished `[*]` → slice migrations, and
> caught bugs that were latent because the affected code paths
> had no test coverage.
>
> See `notes/CHANGELOG.md` for per-turn implementation details.
>
> ## Aggressive sweep (May 2026, 10 turns)
>
> Built on the closed Cat 1-7 inventory.  Each turn was scoped to
> ~one structural concern, with a verified `zig build test` +
> `zig build smoke-test` checkpoint between turns.
>
> 1. **Audit + plan** — counted 448 `c_int`/269 in rlgl.zig, 132
>    while-loops over arrays, 13 module globals.  Drew the line
>    on what was raylib-ABI-required and what was just legacy.
> 2. **Sentinels final cleanup** — `exportMeshAsObj` migrated to
>    `Allocator.Error![]u8`; glyph getters c_int → u21 (3 fns
>    deleted, Z-suffix internals promoted); rlgl matrix host-stubs
>    `zeroes(Matrix)` → `matrixIdentity()` (zero matrix collapses
>    under multiplication, identity composes sensibly).
> 3. **Pixel-format dispatch** — added `Image.pixelFormat()`
>    typed accessor; mass refactor of ~150 dispatch sites in
>    drawing.zig from magic-number switches to enum-tag switches.
>    Surfaced and fixed a latent `loadImageColors` bug.
> 4. **rlgl globals folded** — 4 file-scope `var`s folded into
>    `RLGL: State` struct, names taken from raylib master where
>    they exist.  `_testGetDepth()` test helper added.  +4
>    behavioural tests for cull-plane state.
> 5. **UPPER_CASE → snake_case + LOG_* enum** — 92 example
>    consts renamed; 8 `LOG_*: c_int` aliases retyped to
>    `TraceLogLevel`; `setTraceLogLevel`/`traceLog` accept
>    `TraceLogLevel`.  +4 typed-API tests.
> 6. **c_int → idiomatic Zig + raylib-verified bug fixes** —
>    converted ~17 internal c_int while-loops to for-loops.
>    Caught **Bug 1** (`getPixelDataSize` had wrong bpp for
>    5 HDR formats — `R32`=8 should be 32, etc.) and **Bug 2**
>    (off-by-one in compressed-format boundary check rejected
>    `R16G16B16A16` as compressed).  +14 tests pin every
>    pixel-format byte size against raylib's reference values.
>    Added `PixelFormat.isCompressed()` typed method.
> 7. **runtime.zig globals folded** — 4 module-scope vars
>    (`TIME`/`FPS`/`WINDOW`/`TRACELOG`) folded into one
>    `STATE: CoreState` struct.  `_testReset` collapsed from 6
>    lines to 3.
> 8. **Text helpers go full Zig idiom** — deleted 12 C-shape
>    `[*:0]const u8` text functions (`textCopy`/`textIsEqual`/
>    `textFindIndex`/`textAppend`/`textToInteger`/`textToFloat`/
>    `textLength`/`drawText`/`drawTextEx`/`drawTextPro`/
>    `measureText`/`measureTextEx`).  Replacements documented per-
>    deletion: `std.mem.eql`, `std.fmt.parseInt`, slice-shape
>    `draw`/`drawEx`/`measure`/`measureEx`.  9 example files
>    cleaned up (22 mass renames, 5 `.ptr` strips, 4 `@ptrCast`
>    eliminations).  Manifest updated.
> 9. **`[*]` → slices + Bug 3** — `imageKernelConvolution`,
>    `drawTriangleStrip3D`, `unloadModelAnimations`,
>    `unloadFontData`, mesh-gen helpers (`writeFlat` etc.) all
>    migrated to slice signatures.  Caught **Bug 3**:
>    `Font.deinit` had wrong arity (no allocator), would have
>    failed to compile if anyone called it.  +6 behavioural tests.
> 10. **Status finalised** — this file updated; final snapshot
>     saved.
>
> ### Three bugs found by raylib-master comparison
>
> The recurring lesson: when zimr's behaviour for a function
> isn't covered by tests, comparing against
> `/home/claude/raylib-ref/raylib-master/src/*.c` is the most
> reliable way to find drift.  Three real bugs surfaced this way:
>
> 1. **`getPixelDataSize`**: HDR-format bpp values were wrong for
>    5 formats (`R32`/`R16`/`R32G32B32`/`R16G16B16`/`R16G16B16A16`),
>    returning 1.5x-4x undersized buffers.  Found by reading
>    `rtextures.c:GetPixelDataSize`.
> 2. **`PIXELFORMAT_COMPRESSED_DXT1_RGB` boundary marker**: zimr
>    used `c_int = 13` (off by one — the actual enum value is 14).
>    Made `imageCrop` and `imageResizeCanvas` silently reject
>    `R16G16B16A16` images as if they were compressed.  Found by
>    reading `raylib.h`'s PixelFormat enum.
> 3. **`Font.deinit`**: wrong arity, never compiled.  Found by
>    grep during `unloadFontData` migration.
>
> ### What's still left
>
> - **Bool returns** (`checkCollision*` family): could become
>   `?Vector2`/`?Color`/etc.  Original audit's "callers used to
>   it" still holds; not aggressive-sweep material.
> - **~199 `c_int` in drawing-coord parameters**: every example
>   uses these; v1.0 territory per original deferral.
> - **~269 `c_int` in rlgl.zig**: GL spec values (`0x0200` etc.)
>   required by WebGL ABI.  Hard requirement.
> - **`extern struct` field types** (`Image.width: c_int`,
>   `Mesh.vertices: [*c]f32`): raylib ABI parity.  Hard requirement.
> - **Single-global-state pattern in rlgl**: still one global
>   blob (`RLGL: State`).  Dismantling completely would mean
>   threading `App` through every drawing call — multi-week
>   refactor not justified by the win.
>
> ## Process & tooling
>
> - **`/home/claude/raylib-ref/raylib-master/`** — extracted
>   raylib master.  Used for behaviour verification.  Workflow:
>   `grep -n "FunctionName" raylib-master/src/*.c`, read the C,
>   port the *behaviour* using Zig idioms.
> - **`/home/claude/snapshots/save.sh <label>`** — saves
>   `zimr-<label>.tar.gz`.  Saved 6 snapshots over the sweep.
> - **Style guide rule**: every touched function gets brought
>   up to current spec (Rules 1+3+5: one-arg-per-line,
>   mandatory braces, prefer `@splat` over `**`).
> - **Test discipline**: 530 → **592 host tests**, 60/60 wasm
>   steps green at every snapshot.


> - **Cat 6 (codepoint-slice half)**: pulled in opportunistically
>   while touching the codepoint functions.  Owned-int slices in
>   `loadRandomSequence` / `loadCodepoints` / `loadUTF8` /
>   `drawTextCodepoints` / `measureTextCodepoints` use `[]i32`
>   rather than `[]c_int`.
> - **Cat 7** (`unloadX(allocator)` wrappers): the two unused
>   wrappers in `textures` (`unloadImageColors`,
>   `unloadImagePalette`) deleted entirely.  `unloadRandomSequence`
>   kept (actively used, gives a discoverable counterpart name).
>
> ## Still open / deliberately deferred
>
> - **Cat 3 (text-helper half)**: `textCopy`, `textIsEqual`,
>   `textFindIndex`, `textToInteger`, `textToFloat` remain.
>   Original audit recommended deletion in favour of
>   `std.mem` / `std.fmt` rather than reshaping; that's still the
>   right call.  Worth a separate session.
> - **Cat 6 (drawing coords)**: still ~199 `c_int` parameters in
>   drawing/runtime/rlgl that could be `i32` / `u32`.  Original
>   audit deferred to v1.0; the codepoint-slice half got pulled
>   in opportunistically but the bulk of drawing-coord work is
>   genuinely v1.0 territory — every coord is exercised by every
>   example.
> - **Bool returns** (~10 `checkCollision*` + a few input):
>   could be `?Vector2` / `?Color` / etc.  Original audit's
>   "callers used to it" still holds.  Low priority.
>
> ## Process notes for future ziggification work
>
> - **Tools first.** Get Zig 0.16 (`pip install ziglang`) and Bun
>   (`npm install -g bun`) wired up before starting any migration.
>   `zig build test` (~70ms, 562 tests) and `zig build smoke-test`
>   (60 wasm steps) are the two verification paths; both should
>   stay green between every batch of edits.
> - **Tests first when possible.** For Cat 2a I wrote the
>   error-path tests before flipping the function signatures;
>   that turned the migration into a watch-the-tests-go-from-fail-
>   to-pass exercise rather than "did I remember every call site".
> - **Aggressive deletions are usually right.** Cat 4's
>   `getCodepoint*` family had the typed shape staring at us in
>   `nextCodepoint` already; Cat 7's wrappers had no callers and
>   no matching loaders.  When the audit says "vestigial," check
>   whether the right move is delete rather than reshape.
> - **Style guide compliance is automatic when you touch a
>   function.**  Rule 3 (mandatory braces) and Rule 1 (one arg per
>   line) caught dozens of latent style drift sites during these
>   migrations because the rule says "the moment you edit a
>   function, bring the whole function up to spec."  Rule 5
>   (`@splat` over `**`) was added during this work.

---

# Original audit (May 2026, pre-implementation)

A catalog of zimr's public API surface that's still C-flavored and
would benefit from a more Zig-idiomatic shape — by allocator
discipline, slice-vs-pointer-pair, errors-as-errors, and enum-typed
parameters.

This is an inventory, not a plan.  Every change here is a breaking
API change for callers.  zimr's value proposition is "raylib for
Zig+wasm" so a wholesale rewrite would defeat the porting goal — but
new functions, internal helpers, and thoughtfully-introduced overloads
should follow the Zig-native shape.

---

## Summary by axis

| Axis | Count | Priority |
|---|---|---|
| `c_int`/`c_uint` parameters that should be `i32`/`u32`/enum | ~199 across drawing.zig (92), runtime.zig (46), rlgl.zig (61) | LOW (raylib-faithful, high churn) |
| `[*]const T` + `count: c_int` that should be `[]const T` | 11 in drawing.zig | HIGH (one-line internal change, removes a footgun) |
| `[*:0]const u8` C-strings that should be `[]const u8` | ~15 text/string functions in drawing.zig | MEDIUM (Zig-native overloads exist for some) |
| Sentinel-of-failure returns (`zeroes(T)`, `0`, `&.{}`) instead of `error.X` | ~14 image generators + ~2 input/random + ~5 loaders | HIGH (silently swallows failure) |
| Out-pointers (`*c_int`) for multi-value returns | 4 in drawing.zig | MEDIUM (pure Zig pattern: return struct) |
| Allocator passed to functions that don't allocate | a few "unload" wrappers | LOW (drop the wrapper, document `gpa.free` directly) |
| Bool returns where `?T` or error union fits | ~10 `checkCollision*` + a few input | LOW (raylib idiom, callers used to it) |

Counts are approximate from line-grep — exact list is below.

---

## Category 1: `[*]const T + count: c_int` → `[]const T`

These are the **most worthwhile fixes** because the C-style signature
makes it impossible for the Zig compiler to bounds-check the input.
Every call site has to pass `points.ptr` and `@intCast(points.len)`
manually — pure ceremony with an off-by-one trap.

All of these are in `src/drawing.zig`:

| Line | Function | Current shape |
|---|---|---|
| 209 | `checkCollisionPointPoly` | `points: [*]const Vector2, pointCount: c_int` |
| 541 | `drawTriangleStrip` | `points: [*]const Vector2, pointCount: c_int` |
| 575 | `drawTriangleFan` | `points: [*]const Vector2, pointCount: c_int` |
| 976 | `drawLineStrip` | `points: [*]const Vector2, pointCount: c_int` |
| 1470 | `drawSplineLinear` | `points: [*]const Vector2, pointCount: c_int` |
| 1483 | `drawSplineBasis` | `points: [*]const Vector2, pointCount: c_int` |
| 1545 | `drawSplineCatmullRom` | `points: [*]const Vector2, pointCount: c_int` |
| 1597 | `drawSplineBezierQuadratic` | `points: [*]const Vector2, pointCount: c_int` |
| 1610 | `drawSplineBezierCubic` | `points: [*]const Vector2, pointCount: c_int` |
| 3839 | `imageDrawTriangleFan` | `points: [*]const Vector2, pointCount: c_int` |
| 3849 | `imageDrawTriangleStrip` | `points: [*]const Vector2, pointCount: c_int` |
| 6378 | `drawTextCodepoints` | `codepoints: [*]const c_int, codepointCount: c_int` |

**Recommended**: switch all to `points: []const Vector2`.  The tiny
shim functions doing `points.ptr / points.len` for raylib API parity
(if anyone needs it) can stay as a separate file.

---

## Category 2: Sentinel-of-failure returns

Every one of these silently swallows allocation failure or
invalid-input and returns a zeroed struct.  The caller has no way to
distinguish "you passed bad input" from "the GPU is on fire."

### 2a. Image generators (drawing.zig)

| Line | Function | Failure mode |
|---|---|---|
| 3955 | `genImageColor` | Returns `zeroes(Image)` on `width<=0 or height<=0` |
| 3982 | `imageCopy` | Returns `zeroes(Image)` on `image.data == null` |
| 4015 | `imageFromImage` | Returns `zeroes(Image)` on bad rect |
| 4156 | `genImageGradientLinear` | Returns `zeroes(Image)` on bad dims |
| 4203 | `genImageGradientRadial` | Returns `zeroes(Image)` on bad dims |
| 4244 | `genImageGradientSquare` | Returns `zeroes(Image)` on bad dims |
| 4282 | `genImageChecked` | Returns `zeroes(Image)` on bad dims |
| 4313 | `genImageWhiteNoise` | Returns `zeroes(Image)` on bad dims |
| 4353 | `genImagePerlinNoise` | Returns `zeroes(Image)` on bad dims |
| 4401 | `genImageCellular` | Returns `zeroes(Image)` on bad dims |
| 4590 | `genImageText` | Returns `zeroes(Image)` on bad dims |

**Recommended**: add `error.InvalidDimensions` (and any specifics) to
the existing `Allocator.Error` set the function already returns.  All
of these already take an allocator, so they have an error union — just
expand it.

### 2b. Loaders (drawing.zig)

| Line | Function | Failure mode |
|---|---|---|
| 5023 | `loadTextureFromImage` | Returns texture with `.id = 0` if upload fails — caller has to check `tex.id != 0` |
| 5070 | `loadTextureCubemap` | Returns `empty` cubemap on size/format mismatch (line 5074-5080) |
| 5197 | `loadRenderTexture` | (probably similar — should audit) |

**Recommended**: convert to `LoadError!Texture2D` etc.  The existing
`types.LoadError` set fits naturally.

### 2c. Other sentinels (runtime.zig)

| Line | Function | Failure mode |
|---|---|---|
| 423 | `loadRandomSequence` | `gpa.alloc(...) catch return &.{};` swallows OOM |
| 691 | `getKeyPressed` | Returns `0` when queue is empty — sentinel collides with real KEY_NULL |
| 706 | `getCharPressed` | Same: `0` for "empty" |

**Recommended**: `loadRandomSequence` should return
`Allocator.Error![]i32` (also see Cat. 6 about returning `[]i32` not
`[]c_int`).  The two `getKeyPressed`/`getCharPressed` should return
`?KeyboardKey` / `?u21` so empty is `null`.

---

## Category 3: C-string `[*:0]const u8` → `[]const u8`

The text functions are the worst offenders because they LITERALLY
already have Zig-slice internals (e.g. `drawText` at line 6370 calls
`draw(s[0..cstrLen(s)], ...)` — it length-scans a C string just to
turn it back into a slice).  Just expose the slice form.

All in `src/drawing.zig` text section:

| Line | Function |
|---|---|
| 5901 | `getCodepointNext(s: [*:0]const u8, codepointSize: *c_int)` |
| 5920 | `getCodepoint(s: [*:0]const u8, codepointSize: *c_int)` |
| 5924 | `getCodepointCount(s: [*:0]const u8)` |
| 5937 | `textLength(s: [*:0]const u8)` |
| 5941 | `textCopy(dst: [*]u8, src: [*:0]const u8)` |
| 5952 | `textIsEqual(text1, text2: [*:0]const u8)` |
| 5970 | `textFindIndex(s, search: [*:0]const u8)` |
| 5982 | `textAppend(s: [*]u8, append: [*:0]const u8, position: *c_int)` |
| 5992 | `textToInteger(text_in: [*:0]const u8)` |
| 6007 | `textToFloat(text_in: [*:0]const u8)` |
| 6247 | `imageDrawText(s: [*:0]const u8, ...)` |
| 6272 | `imageDrawTextEx(s: [*:0]const u8, ...)` |
| 6366 | `drawTextEx(s: [*:0]const u8, ...)` |
| 6370 | `drawText(s: [*:0]const u8, ...)` |
| 6374 | `drawTextPro(s: [*:0]const u8, ...)` |

**Recommended**: drop the C-shim signatures from the public API.
`drawText`/`drawTextEx`/`drawTextPro` already have Zig-slice
counterparts (`text.draw`, `text.drawEx`, `text.drawPro`) — those
should become the recommended path.  `textCopy`/`textAppend`/
`textIsEqual`/`textFindIndex`/`textToInteger`/`textToFloat` are all
`std.mem`/`std.fmt` material — delete and let users call `std`.
`getCodepoint*` is `std.unicode.Utf8Iterator` material — delete in
favor of stdlib.

---

## Category 4: Out-pointers for multi-value returns

| Line | Function | Out-pointer |
|---|---|---|
| 5901 | `getCodepointNext` | `*c_int` for size |
| 5908 | `getCodepointPrevious` | `*c_int` for size |
| 5920 | `getCodepoint` | `*c_int` for size |
| 5982 | `textAppend` | `*c_int` for position |
| 291 | `checkCollisionLines` | `?*Vector2` for collision point |

**Recommended**: return a struct.

```zig
pub const CodePointAndSize = struct { codepoint: u21, size: u8 };
pub fn getCodepointNext(s: []const u8) ?CodePointAndSize { ... }
```

---

## Category 5: `c_int` keys/buttons → typed enums

Input functions all take `c_int` even though `KeyboardKey` /
`MouseButton` / `GamepadButton` / `GamepadAxis` enums exist
(`src/types.zig` lines 1219, 1405, 1457, 1497).

| Line | Function | Should take |
|---|---|---|
| 662 | `isKeyPressed(key: c_int)` | `KeyboardKey` |
| 668 | `isKeyPressedRepeat(key: c_int)` | `KeyboardKey` |
| 673 | `isKeyDown(key: c_int)` | `KeyboardKey` |
| 678 | `isKeyReleased(key: c_int)` | `KeyboardKey` |
| 684 | `isKeyUp(key: c_int)` | `KeyboardKey` |
| 718 | `setExitKey(key: c_int)` | `KeyboardKey` |
| 731 | `getKeyName(key: c_int)` | `KeyboardKey` |
| 818 | `isMouseButtonPressed(button: c_int)` | `MouseButton` |
| 824 | `isMouseButtonDown(button: c_int)` | `MouseButton` |
| 829 | `isMouseButtonReleased(button: c_int)` | `MouseButton` |
| 835 | `isMouseButtonUp(button: c_int)` | `MouseButton` |

(Plus the gamepad equivalents — same pattern.)

**Recommended**: switch to enum, keep the constants
(`types.KEY_SPACE` etc. — already 1288-style "raylib-style constants
generated by hand from KeyboardKey") for backward-compat.  Each
function body's `if (key <= 0 or key >= MAX_KEYBOARD_KEYS)` bounds
check disappears because the enum is already valid-by-construction.

---

## Category 6: Coordinate `c_int` → `i32`

This is the highest-count, lowest-priority category.  Every
`drawPixel(posX: c_int, posY: c_int, ...)` etc. uses `c_int` only
because raylib's C API uses `int`.  In Zig there's no portability
reason to stick with `c_int` — `i32` is fine, more familiar, and
removes the `@intCast` ceremony at every call site.

Affected: 92 functions in drawing.zig, 46 in runtime.zig, 61 in
rlgl.zig.

**Recommended**: defer until v1.0 when a major-version break is
acceptable.  In the meantime, prefer `i32`/`u32` for *new* functions.

---

## Category 7: `unloadX(allocator, x)` wrappers

These exist for raylib API symmetry but are pointless in Zig — the
caller already has the allocator, so `gpa.free(slice)` is one
character shorter.

| Line | Function |
|---|---|
| runtime.zig:446 | `unloadRandomSequence(gpa, seq)` → just `gpa.free(seq)` |
| drawing.zig:3923 | `unloadImageColors` |
| drawing.zig:3936 | `unloadImagePalette` |

**Recommended**: keep them but mark `@deprecated` with a one-liner
pointing at `gpa.free`.  Removes the `Allocator` parameter from the
caller's mental load.

---

## Category 8: Inconsistent allocator placement

Some functions take `gpa` first (Zig idiom), some take `gpa` last
(C-tail idiom from raylib porting), and `loadFontFromTtf` even has
the allocator in the middle:

```
loadFontFromTtfData(gpa: Allocator, ttf_bytes: []const u8, ...)  ✓
loadTextureCubemap(gpa: Allocator, faces: [6]Image)              ✓
loadFontFromTtf(gpa: Allocator, ttf_bytes, font_size, ...)       ✓
genImageColor(gpa: Allocator, width, height, color)              ✓
drawMeshInstanced(gpa: Allocator, mesh, material, transforms)    ✓
```

Actually... checking, **all the allocator-taking functions take it
first**.  The codebase is consistent here.  Move this category to
"audited, clean."

---

## Where to start

If we tackle these in priority order:

1. **Category 2 (sentinel returns)** — highest user-impact.  Silent
   failure is the worst kind.  Maybe 20 functions, each is 5–10 lines
   of edits, and the existing error sets are already in place
   (`Allocator.Error`, `LoadError`).
2. **Category 1 (slice-vs-pointer-pair)** — 12 functions, mechanical
   conversion, removes the `@intCast(...len)` ceremony at all call
   sites.  Internal `[*]const + count` shim can stay private if any
   examples need raylib-API parity (none currently do).
3. **Category 3 (C-strings)** — 15 functions.  Most have Zig-slice
   counterparts already; just remove the `[*:0]` versions and update
   the few examples that use them.
4. **Category 5 (enum keys)** — 11+ functions.  Mechanical.  Keep
   constant aliases for backward compat.
5. **Category 4 (out-pointers)** — 5 functions.  Return a struct.
6. **Category 7 (allocator wrappers)** — deprecate with comment.
7. **Category 6 (`c_int` coords)** — defer to v1.0.

Steps 1+2 alone would meaningfully improve the API without breaking
much existing user code (sentinel returns become errors, but nobody
was checking the sentinel anyway).

---

## What's NOT a candidate

`src/codecs.zig` is already idiomatic Zig throughout — allocator
first, slices everywhere, errors-as-errors, no sentinels.  It's the
template for what the rest of the library could look like.

`src/raymath.zig` is a numerical library — `Matrix`/`Vector*` types
and pure functions on them.  No allocators, no errors, no slices.
Already correct shape.

`src/ui.zig` is internal Zig from the start; its API surface is
already idiomatic.

`src/web.zig` is the wasm/JS extern boundary — `[*]u8 + len` is
necessary because that's how the JS shim sees memory.  Internal-only,
not a public API.
