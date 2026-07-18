# CHANGELOG — turns 220-229

Per-turn journal for turns 220-229.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 230
opens, this file is frozen and a fresh `changelog230-239.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog210-219.md`, `changelog200-209.md`, `changelog093-199.md`,
`changelog001-092.md`).

---

## [Frozen — decade complete]

### Turn 229 — zmath-adoption Z2 step 5 (dedup, not relocate) — Z2 COMPLETE

Z2's final step. The gap doc planned to *relocate* the color /
bit-packing helpers from `zimrmath.zig` into a new `src/color.zig` —
but investigation showed that would have *violated* decision 7, so
the step became a **dedup** instead.

**What was found.** `zimrmath.zig`'s `color8ToColor` / `colorToColor8`,
the twelve `compress8to{1..6}` / `expand{1..6}to8` functions, and
`floatToHalf` / `halfToFloat` were either dead or duplicated:
- `rlsw_pixel.zig` already owns the *canonical* form of all the
  color/packing code — `expandToByte(n, v)` / `compressByteTo(n, v)`
  (one parameterized fn, not twelve) and `byteColorToFloats` /
  `floatColorToBytes`. zimrmath's twelve-function spelling had zero
  external callers. Creating a `color.zig` with another copy would
  ship a third spelling of the same concept.
- `floatToHalf` / `halfToFloat` were *already ported to `math.zig`*
  in Z2 step 1 — zimrmath's were a straight duplicate.

**What was done.** Deleted all of it from `zimrmath.zig` (the
bit-replication block, the RGBA8↔RGBA32F block, the f16 block, the
`inv_255` helper, and their 7 now-orphaned tests) — replaced with an
18-line note explaining where each capability lives now and why it
isn't here. No `color.zig` created: `rlsw_pixel.zig` is the rightful
home for the color/packing code, `math.zig` for f16. Shipping one,
the best one.

**Flat-export wiring.** Added `math.zig` to `gen_flat_exports.py`'s
source list, *before* `zimrmath` so its names win on collision (plan
decision 5; the generator is first-writer-wins). Added the `zmath`
private binding to `zimr.zig` and regenerated. Result: `z.*` now
surfaces 119 names from `math.zig` (`z.dot3`, `z.mul`,
`z.floatToHalf`, …) alongside zimrmath's remaining 151. `floatToHalf`
/ `halfToFloat` / `luminance` now flat-export from `zmath`;
zimrmath's `wrap` / `fract` keep their own flat names (math.zig's are
`wrap32` / `frac32` — deliberately suffixed, no collision), both
surfaces coexisting until Z3 migrates callers.

**Z2 IS COMPLETE.** `math.zig` is now a strict superset of zimr's
math needs: Z2 step 1 (scalar utils) + step 2 (Vector2, 13 fns) +
step 3 (vector3/4, 19 fns) + step 4 (matrix/quat/euler, 11 fns) +
step 5 (dedup). The gap is closed; both math libraries coexist with
the conversion layer between them. Next is Z3 — migrating call
sites onto `math.zig` leaf-first, shrinking `zimrmath.zig` toward
deletion.

**Audit:** host tests 1457 → 1449 (−8: the 7 deleted orphan tests
for deleted dead code, as intended), math-test 127/127, smoke
100/100, install clean, fmt clean, globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (color/packing/f16 blocks +
7 tests deleted, replaced with a relocation note),
`scripts/gen_flat_exports.py` (math.zig added as a source),
`src/zimr.zig` (`zmath` binding + regenerated AUTOGEN block),
`src/notes/zmath-z2-gap.md` (step 5 + Z2 marked complete),
`src/notes/zmath-adoption-plan.md` (Z2 marked done), `docs.html`.

**Next:** Z3 — call-site migration. Move `zimrmath.zig`'s internal
helpers and the renderer compute sites onto `math.zig`'s API,
leaf-first, file by file. `zimrmath.zig` shrinks as callers leave;
storage structs never migrate.

### Turn 228 — zmath-adoption Z2 step 4: matrix + quaternion ops (+ Euler decision)

Ported the genuinely-absent matrix and quaternion operations, and
settled the Euler-angle question with a refinement to decision 7.

**Decision 7 carve-out — distinct operations all ship; only
redundant *spellings* are eliminated.** Euler angle order is not a
"two names for one thing" case: `XYZ` and `ZXY` produce *different*
rotations, the way `dot` and `cross` do. Verified empirically that
raylib's `quaternionFromEuler` is **XYZ** order and zmath's
`quatFromRollPitchYaw` is **ZXY**. Both have real callers, so both
ship — but with explicit names that fix the actual sin of both
upstreams (an opaque name you must read source to decode). The plan
and gap doc now record this carve-out. We ship exactly the two
orders with real demand, not all six.

**The 11 ported:**
- Matrix (4): `matrixTrace`, `matrixFrustum` (OpenGL `[-1,1]` depth,
  like raylib — pairs with `perspectiveFovRhGl`), `matrixCompose`
  (TRS in one call), `matrixDecompose` (returns a `TRS` struct,
  value-out — not raylib's `*ptr` mutation; reads basis vectors from
  *rows* because zmath's `Mat` is row-major, which is the correct
  thing for that layout).
- Quaternion (3): `quatFromTo` (shortest-arc), `quatCubicHermite`,
  `quatEquals` (documented as a *component* compare — does not treat
  `q`/`-q` as equal).
- Euler (4): `quatFromEulerXYZ` / `quatToEulerXYZ` (raylib order),
  `quatFromEulerZXY` / `quatToEulerZXY` (zmath order). zmath's
  `quatFromRollPitchYaw` / `quatToRollPitchYaw` stay as aliases for
  the ZXY pair. A test explicitly pins that XYZ and ZXY genuinely
  differ.

Decision-7 skips this step: `matrixToFloatV` (= zmath `matToArr`),
`quaternionTransform` (= `mul` of a vec by a matrix).

Test note: the `matrixFrustum` test initially compared against
`perspectiveFovRh` and failed on the depth term — `perspectiveFovRh`
uses `[0,1]` (D3D) depth, `matrixFrustum`/raylib use `[-1,1]` (GL).
The function was right; the test's assumption was wrong. Fixed to
compare against `perspectiveFovRhGl`. Flagged for Z3: zimr ships
WebGL2, so the renderer must consistently use the `*Gl` projection
builders.

**Audit:** host tests 1447 → 1457 (+10), math-test 117 → 127 (+10),
smoke 100/100, install clean, fmt clean, globals 0/0/0.

**Files touched:** `src/math.zig` (matrix+quat+euler section in
zimr-additions), `src/notes/zmath-adoption-plan.md` (decision 7
carve-out), `src/notes/zmath-z2-gap.md` (Cat 6 + step 4 updated),
`docs.html`.

**Next:** Z2 step 5 — relocate the color / bit-packing helpers
(`color8ToColor`, `compress8toN`, `expandNto8`, `colorToColor8`,
`luminance*` already done in step 1) out of `zimrmath.zig` into a
new `src/color.zig`. Then Z2 is done and Z3 (call-site migration)
begins.

### Turn 227 — zmath-adoption Z2 step 3: vector3 / vector4 ops

Ported the genuinely-absent 3D/4D vector operations into `math.zig`'s
zimr-additions section. Decision-7 filter again trimmed the list:
raylib's `vector3RotateByQuaternion` is zmath's existing `rotate`,
`vector3ToFloatV` is `vecToArr3`, `vector4Min`/`Max` are the generic
`min`/`max` — none re-ported.

**The 19 ported:**
- 3D (15): `distance3`, `distanceSq3`, `angle3`, `perpendicular3`,
  `project3`, `reject3`, `reflect3`, `refract3`, `moveTowards3`,
  `equals3`, `orthoNormalize3`, `barycenter3`, `cubicHermite3`,
  `rotateByAxisAngle3`, `unproject3`.
- 4D (4): `distance4`, `distanceSq4`, `moveTowards4`, `equals4`.

Each with a `test "zmath.<name>"` block. Notable design calls:
- `reflect3`/`refract3` complete the reflect/refract family started
  with `reflect2`/`refract2` last turn (zmath ships neither at any
  width).
- `angle3` uses `atan2(|cross|, dot)`, not `acos(dot)` — robust for
  near-parallel and near-antiparallel inputs (the `acos` form loses
  precision exactly there); a test pins the `pi` case.
- `orthoNormalize3` returns a value (`OrthoBasis3{ tangent,
  bitangent }`) instead of mutating through `*Vector3` pointers like
  raylib's version — value-in/value-out is the zmath style and
  composes better.
- `rotateByAxisAngle3` (Euler-Rodrigues) is kept as a distinct op,
  not a naming dup — it is the matrix-free direct rotation; the doc
  points callers rotating *many* vectors at `matFromAxisAngle`
  instead.
- `unproject3`'s round-trip test exercises `lookAtRh` +
  `perspectiveFovRh` + `mul` + `inverse` together — a real
  integration check, not just a unit test.

**Audit:** host tests 1428 → 1447 (+19), math-test 98 → 117 (+19),
smoke 100/100, install clean, fmt clean, globals 0/0/0.

**Files touched:** `src/math.zig` (vector3/4 section in
zimr-additions), `src/notes/zmath-z2-gap.md` (step 3 marked done),
`docs.html`.

**Next:** Z2 step 4 — the genuinely-absent matrix + quaternion ops
(`matrixCompose`, `matrixDecompose` — the ~100-line effort spike —
`matrixTrace`, `matrixFrustum`, `quaternionFromVector3ToVector3`,
`quaternionCubicHermiteSpline`, `quaternionEquals`, etc.).

### Turn 226 — zmath-adoption Z2 step 2: Vector2

Ported the 2D vector surface into `math.zig`'s zimr-additions
section. The headline result: decision 7 ("ship one name per
concept") shrank this from raylib's 32 `vector2*` functions to **13**
genuine gap functions.

**Why only 13.** Re-analysed raylib's 32 against what zmath already
provides:
- 4 already exist — `dot2`, `length2`, `lengthSq2`, `normalize2` are
  in stock zmath.
- ~15 are `@Vector` operators — zmath deliberately has no
  `add`/`sub`/`scale`/`negate`/`min`/`max`/`clamp`/`lerp` *functions*;
  `@Vector(4,f32)` does `+ - * /` natively and zmath's generic
  `min`/`max`/`clamp`/`lerp` already accept `Vec`. Porting raylib's
  named wrappers would be shipping a second spelling of `a + b`.
- 13 are the real gap — 2D-specific ops zmath has at no width.

**The 13 ported** (all on `Vec`, value in lanes 0,1 per the locked
compute-type decision): `cross2`, `distance2`, `distanceSq2`,
`angle2`, `lineAngle2`, `reflect2`, `refract2`, `rotate2`,
`transform2`, `clampLength2`, `moveTowards2`, `equals2`,
`randomInUnitDisk2`. Each with a `test "zmath.<name>"` block.
Naming follows zmath's width-suffix convention (`dot2`, `length2`).

Notable details:
- `reflect`/`refract` turn out to be absent from zmath at *every*
  width, not just 2D — `reflect2`/`refract2` ship now; `reflect3`/
  `refract3` are flagged as a Z2-step-3 gap entry.
- Scalar-reduction ops (`cross2`, `distance2`, `distanceSq2`) return
  `F32x4` splatted across lanes, matching zmath's existing `dot2`/
  `length2` so they compose with vector expressions. `angle2`/
  `lineAngle2` are inherently angles, so they return plain `f32`.
- `lineAngle2` does NOT keep raylib's clockwise-positive sign —
  raylib's own source TODOs that choice, and one function rotating
  opposite to `angle2`/`rotate2`/the matrix rotations is a footgun.
  zimr's `lineAngle2` is counter-clockwise positive like everything
  else; the porting guide notes raylib code must negate.
- `randomInUnitDisk2` takes `*std.Random` — the resolved RNG
  decision; `math.zig` stays global-state-free.

**Audit:** host tests 1415 → 1428 (+13), math-test 85 → 98 (+13),
smoke 100/100, install clean, fmt clean, globals 0/0/0.

**Files touched:** `src/math.zig` (Vector2 section in zimr-additions;
`lineAngle2` sign corrected to CCW-positive on review),
`src/notes/zmath-z2-gap.md` (step 2 marked done),
`src/notes/migrating-from-raylib.md` (zmath-rename section stub +
the `lineAngle2` sign-change note), `docs.html`.

**Next:** Z2 step 3 — the genuinely-absent vector3/vector4 ops
(`vector3Project`/`Reject`/`Barycenter`/`Perpendicular`,
`reflect3`/`refract3`, the `*MoveTowards`/`*Equals` family, etc.).

### Turn 225 — zmath-adoption: plan sharpened + Z2 step 1 (scalar utils)

Two parts: a philosophy tightening of the adoption plan, then the
first concrete Z2 port.

**Plan: decision 7 — "one name per concept, ship the best one."**
The plan now states unambiguously that the end state has a *single*
canonical spelling for every operation. zmath and raylib-flavoured
zimrmath both have e.g. dot-product; the zmath name (`dot3`) is
canonical and the raylib name (`vector3DotProduct`) simply goes
away — no aliases. The two audiences are kept happy *differently*:
zmath users get the zmath compute surface unchanged; raylib users
get (a) zimr's storage types staying raylib-shaped `extern struct`s,
(b) the gap-fill functions ported in zmath's *style* so the library
is one consistent dialect, (c) the porting guide's name-mapping
table. Consequence: Z2 shrinks — only the ~88 true-capability-gap
functions get ported, not the ~80 raylib-named duplicates of things
zmath already does. Z3/Z4 reworded to match (migrate call sites
directly onto zmath's API; no wrapper layer).

**Three open questions from the gap doc — resolved:**
- RNG ops take a `*std.Random` parameter (pure, no global state).
- Color / bit-packing helpers are not math — they relocate to a new
  `src/color.zig` during Z2, not into `math.zig`.
- Euler: ship one — zmath's `quatFromRollPitchYaw`. raylib's order
  does not get its own function; the guide documents any difference.

**Z2 step 1 — Category 2 scalar utilities ported into `math.zig`.**
New "zimr additions" section at the end of `math.zig` (clearly
fenced off from upstream zmath), holding the scalar-`f32` helpers
zmath lacks: `floatEquals` / `floatEqualsEps` (now return `bool`,
not raylib's `i32`), `frac32`, `wrap32`, `rcp32`, `luminance` /
`luminance8`, `floatToHalf` / `halfToFloat`. Each in zmath's style
with a `test "zmath.<name>"` block. Naming follows zmath's `32`
suffix convention for scalar functions that could later gain vector
counterparts (`modAngle32` is the precedent).

Two of zimr's old scalar utils were deliberately NOT ported —
decision 7 in action: scalar `remap` is exactly zmath's `mapLinear`
and scalar `normalize` (into-range) is exactly `lerpInverse`, both
of which already accept scalar `f32`. Those concepts already exist;
call sites move to the zmath name in Z3.

One in-source `// [zimr]` edit to upstream zmath: `adjustSaturation`
had a local const named `luminance` that shadowed the new top-level
`luminance`; renamed the local to `luma` (behaviour unchanged — it
was a latent shadow anyway).

**Audit:** host tests 1408 → 1415 (+7), math-test 78 → 85 (+7),
smoke 100/100, install clean, fmt clean, globals 0/0/0.

**Files touched:** `src/math.zig` (zimr-additions section + the
`adjustSaturation` local rename), `src/notes/zmath-adoption-plan.md`
(decision 7, Z2/Z3/Z4 rewrite), `src/notes/zmath-z2-gap.md` (Cat
3/5/6 marked resolved), `docs.html`.

**Next:** Z2 step 2 — Vector2. All 32 `vector2*` ops, ported in
zmath style operating on `@Vector(4,f32)` lanes 0,1.

### Turn 224 — zmath-adoption Z2 prep: gap analysis

Planning turn — no source change. Characterized the exact gap Z2
must close, written up as the committed doc `src/notes/zmath-z2-gap.md`.

**Method + headline finding.** Diffed `zimrmath.zig`'s 171 math
functions against `math.zig`'s 162. The raw name-diff is 168, but
that number is overwhelmingly *naming convention*, not missing
capability — zmath has the full `dot3`/`cross3`/`normalize3`/`mul`/
`inverse`/`determinant`/`transpose` + all the `rotation*`/`scaling`/
`perspectiveFov*`/`ortho*`/`lookAt*`/`quatFrom*`/`slerp` builders,
just spelled differently from zimr's `vector3DotProduct` etc. The
*true* gap — capability genuinely absent — is much smaller and falls
into six categories.

**The true gap:**
- Cat 1 — **Vector2**: zmath has zero 2D. All 32 `vector2*` fns are
  gap. Compute type stays `@Vector(4,f32)` on lanes 0,1 per the
  plan's locked decision.
- Cat 2 — 10 scalar utilities (`fract`, `wrap`, `remap`, `rcp`,
  `luminance`/`luminance8`, `floatToHalf`/`halfToFloat`,
  `floatEquals`, scalar `normalize`).
- Cat 3 — 14 color / bit-packing helpers (`color8ToColor`,
  `compress8toN`, `expandNto8`) — flagged for a possible relocation
  to a `color.zig` instead.
- Cat 4 — 29 genuinely-absent vector3/matrix/quat ops
  (`vector3Project`/`Reject`/`Barycenter`, `matrixDecompose` — the
  ~100-line effort spike — `quaternionFromVector3ToVector3`, etc.).
- Cat 5 — 3 RNG-dependent ops (`vector*Random*`): open question
  whether `math.zig` takes an RNG parameter (lean: yes, keeps it
  pure) or these stay elsewhere.
- Cat 6 — euler-order question carried from the plan: raylib's
  `quaternionFromEuler`/`ToEuler` order vs zmath's YXZ
  `quatFromRollPitchYaw` — must confirm, not assume.

Every gap entry was confirmed to have live call sites outside
`zimrmath.zig` + tests — nothing skippable. The doc includes a
suggested 6-step execution order (scalars → Vector2 → small
vector3/4 ops → matrix/quat ops → color → RNG/euler).

**Audit:** no source touched; fmt clean, globals 0/0/0, docs
rebuilt (picks up the new note). install/test/smoke unchanged from
turn 223.

**Files touched:** new `src/notes/zmath-z2-gap.md`, `docs.html`
(regenerated).

**Next:** Z2 step 1 — port the Category 2 scalar utilities into
`math.zig` in zmath's section style with zmath-style tests.

### Turn 223 — zmath-adoption Z1: conversion layer

Z1 of the zmath-adoption arc (`notes/zmath-adoption-plan.md`): the
`toZm` / `fromZm` boundary so zimr's storage types and zmath's
compute types can coexist and values cross freely.

**Added to `zimrmath.zig`** (new "zmath conversion layer" section at
end of file; `zimrmath.zig` now `@import`s `math.zig`):
`vector2ToZm`/`FromZm`, `vector3ToZm`/`FromZm`, `vector4ToZm`/`FromZm`,
`quaternionToZm`/`FromZm`, `matrixToZm`/`FromZm`. Vectors are
component copies with documented lane-fill contracts (V2 → lanes 0,1
+ zero; V3 → lanes 0,1,2 + zero; V4/Quat → all four). Quaternion
conversions are mechanically the V4 ones but named for intent +
single-point-of-change if `Quaternion` ever stops aliasing `Vector4`.

**The matrix conversion — and a bug found and fixed mid-turn.** The
first implementation TRANSPOSED the field-name mapping, reasoning
that bridging zimr's column-vector convention to zmath's row-vector
convention required it. Wrong. zimr `Matrix` (column-major memory)
and zmath `Mat` (row-major memory) ARE memory transposes — but both
use the same row-major field/row NAMING (`m{r*4+c}` ≡ `Mat[r][c]`).
Copying by field *name* therefore needs NO transpose: the
memory-layout flip happens for free, and transposing the names
double-applies it. Caught by the cross-convention transform tests
(the round-trip test still passed — a wrong-but-consistent transpose
pair is still self-inverse, which is exactly why round-trips alone
are insufficient). Empirically re-derived the mapping with throwaway
probes (`matrixTranslate(10,20,30)` → memory slots 3,7,11 in zimr,
12,13,14 in zmath) and confirmed the direct field-name copy. The
operator-level convention difference (`M*v` vs `v*M`) is NOT handled
by the conversions — it's left to call sites to pick multiply order.
All three explanatory comment blocks rewritten to document this
correctly, including why round-trip tests can't catch a bad
transpose.

**New `src/tests/zm_conversion_test.zig`** (9 tests, wired into the
`tests.zig` aggregator): round-trips for every type, plus the
load-bearing semantic tests — transform a point through zimr's
column-vector path and through zmath's row-vector path after
conversion, assert they match. These are what caught the transpose
bug.

**Note on test count:** importing `math.zig` into `zimrmath.zig`
pulls zmath's own ~77 embedded tests into the native `tests.zig`
aggregator too — host test count 1322 → 1408 (+9 conversion tests,
+77 from zmath). They're now covered both here and in the standalone
`math-test` step. The Z0 asm-gating holds — the native aggregator
compiles `math.zig` fine on the stock self-hosted backend.

**Audit:** host tests 1408/1408, math-test 78/78, smoke 100/100, fmt
clean, globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (conversion layer appended,
imports `math.zig`), new `src/tests/zm_conversion_test.zig`,
`src/tests.zig` (wire-in), `src/notes/zmath-adoption-plan.md` (Z1
marked done).

**Next:** Z2 — make `math.zig` a strict superset of zimr's math
needs. zmath has no `Vector2` type and lacks ~12 of zimr's scalar
utils + a chunk of vector ops; port the gap list into the fork in
zmath style, with zmath-style tests.

### Turn 222 — zmath-adoption Z0: zmath vendored as src/math.zig

First step of the zmath-adoption arc (`notes/zmath-adoption-plan.md`).
Z0 = vendor zmath verbatim, wire its own test target, fix only
Zig-version drift — no gap-filling, no integration.

**Vendored.** zig-gamedev zmath `0.11.0-dev` (`src/root.zig`, 4720
lines, MIT) copied verbatim into `src/math.zig` with a provenance
header documenting upstream, version, and fork status. zmath's
LICENSE saved alongside at `src/notes/zmath-LICENSE.txt`. This is a
HARD FORK — no upstream-merge story; `math.zig` is edited freely from
here. Convention stays zmath-native (row-major / row-vector) per the
plan's locked decision 1; it coexists with `zimrmath.zig`'s
column-vector convention during the migration.

**In-source `// [zimr Z0]` edits — 4 sites, 2 categories, each
marked so the diff from upstream stays auditable:**

*Zig-version drift (3):*
1. `@import("zmath_options").enable_cross_platform_determinism` →
   local `const … = true`. zmath expects a build-injected options
   module from its own `build.zig`; zimr vendors the file directly
   and doesn't use that build system.
2. + 3. Two FFT `fftUnswizzle` shift-amount casts. `log2_length` is
   `Log2Int(usize)` = u5 on wasm32; upstream's bare `32` literal gets
   inferred as u5 and Zig 0.16 rejects it. Compute the difference in
   u32, `@intCast` down to the shift type (value provably in range
   via the existing `assert(log2_length >= 2)`).

*Self-hosted-backend workaround (1):* the `round`/`ceil`/`floor`/
`trunc` x86-asm gating described under Build wiring below.

**Build wiring.** New `math-test` step builds `src/math.zig` as a
standalone test executable and runs zmath's ~70 embedded tests.

One Z0-specific snag handled here: zmath's `round`/`ceil`/`floor`/
`trunc` contain x86 inline assembly (`vroundps`/`vrndscaleps`) that
trips a register-allocator assertion in Zig 0.16's self-hosted
x86_64 backend (`genSetReg called with a value larger than
dst_reg`). zimr ships wasm32, where `cpu_arch == .x86_64` is
comptime-false and that asm is already dead-stripped — the portable
bit-twiddling `else` branch is what actually runs. So those four asm
branches are gated behind `false` (kept, not deleted — the diff from
upstream stays auditable; commented `// [zimr Z0]`). This changes
nothing about zimr's behaviour or perf (it's wasm) and means the
native test target compiles on the stock self-hosted backend — no
`use_llvm` override, no toolchain split.

`math.zig` is deliberately NOT folded into the `tests.zig`
aggregator: it isn't part of zimr's module graph yet (Z3 moves the
boundary).

**Z0 gate met: zmath's own 78 tests pass** (`zig build math-test` →
78/78). That's the verbatim-vendor confirmation — the fork is
genuinely upstream zmath, correctly compiled under our toolchain.

**Audit:** zimr host tests 1322/1322 (unchanged — math.zig not yet
in the graph, as intended), math-test 78/78 (new), smoke 100/100,
fmt clean, globals 0/0/0.

**Files touched:** new `src/math.zig` (vendored + 4 `// [zimr Z0]`
edits: 3 drift, 1 asm-gating),
new `src/notes/zmath-LICENSE.txt`, `build.zig` (math-test step),
`src/notes/zmath-adoption-plan.md` (Z0 marked done).

**Next:** Z1 — conversion layer in `zimrmath.zig`: `toZm`/`fromZm`
for `Vector2/3/4 ↔ zm.Vec`, `Matrix ↔ zm.Mat` (matrix conversions
TRANSPOSE — the convention flip lives here), `Quaternion ↔ zm.Quat`.

### Turn 221 — pbr_demo fixed: shader-enum ABI drift + a 5th transform-order bug

Started as "visual-verify the turn-220 fixes", became a deep debug of
why `pbr_demo` rendered black. Multi-stage instrumentation
(RenderList dump → shader compile/link logging → per-call
`rlSetUniform` logging) localised it.

**Root-cause bug — shader-enum ABI drift.** `drawing.zig` hand-coded
`SHADER_UNIFORM_VEC4 = 4` and `SHADER_UNIFORM_INT = 6`, but in the
canonical `ShaderUniformDataType` enum `4` is `int` and `6` is
`ivec3`. So every textured/lit draw uploaded `colDiffuse` (a vec4)
via `glUniform1iv` and the diffuse sampler via `glUniform3iv` →
`GL_INVALID_OPERATION` on desktop, and a no-log link rejection on
stricter mobile drivers (→ the renderer fell back to the default
flat shader, hence "black"). Investigation found this was one of
**three** independently hand-copied copies of the shader-location /
uniform-type enums, and all three had drifted from the canonical
`types.zig` enums in different ways (`vertex_normal` at 2 vs 3, the
VEC4/INT swap).

**Systemic fix — single source of truth + guards.**
- Deleted all three hand-copied constant tables (`drawing.zig` ×2,
  `rlgl.zig` ×1). Every `SHADER_LOC_*` / `SHADER_UNIFORM_*` /
  `SLOC_*` constant is now `@intFromEnum(types.<Enum>.<variant>)` —
  derived, not copied. The enums in `types.zig` are the sole source
  of truth.
- Added a `comptime` ABI guard in `types.zig` next to the enums:
  reordering/inserting a variant now fails the build with a named
  `@compileError` instead of silently corrupting uploads.
- Added `src/tests/shader_enum_test.zig` (3 tests, wired into
  `tests.zig`) — runtime pin of the enum wire values + the
  `rlSetUniform` dispatch contract.
- Aggressively commented all former copy-sites + both enums with the
  full failure story.

**Also fixed — 5th instance of the disc-1 order bug.** `resolveCamera`
in `scene.zig` composed `view * proj` instead of `proj * view` for
`ResolvedCamera.view_proj`, which feeds `Frustum.fromViewProj`
(Gribb-Hartmann extraction needs the proper world→clip matrix).
Turn 220 found 4; this is the 5th, same class.

**Also — turn 221's earlier sub-fixes** (carried in this entry since
they shipped together): PBR vertex shader given explicit
`layout(location)` attributes matching the default/skinned shaders;
PBR VS+FS precision changed `highp` → `mediump` to match the working
default shaders.

**Cleanup:** stripped all temporary instrumentation (compile/link
log dumps in `rlgl.zig`, per-call `rlSetUniform` logging, the
PBR-loc dump in `render.zig`, the RenderList dump in `pbr_demo.zig`).
Fixed `pbr_demo`'s stale HUD text (it claimed "no lighting" — the
lighting path is fully wired).

**Audit:** host tests 1319 → 1322 (+3 shader-enum tests), smoke
100/100, fmt clean, globals 0/0/0.

**Files touched:** `src/drawing.zig` (2 tables → enum-derived),
`src/rlgl.zig` (1 table → enum-derived, debug stripped),
`src/types.zig` (comptime ABI guard), `src/render.zig` (PBR shader
layout/precision, debug stripped), `src/scene.zig` (resolveCamera
order), new `src/tests/shader_enum_test.zig`, `src/tests.zig`
(wire-in), `examples/pbr_demo.zig` (debug stripped, HUD text).

**Next:** zmath-adoption Z0 — vendor zmath verbatim as `src/math.zig`.
The B4-discrepancies prerequisite is fully cleared (turn 220 + the
5th instance here).

### Turn 220 — B4-discrepancies investigation: 4 transform-order bugs fixed

The prerequisite before the zmath-adoption arc (`zmath-adoption-plan.md`).
Phase B's mechanical `matrixMultiply`→`matrixMul` migration was
byte-identical, but rendering reversed-convention code in standard
notation made several pre-existing transform-composition-order
mistakes legible.  The plan logged 3; the investigation confirmed all
3 as real bugs and surfaced a 4th of the same class.

New test file `src/tests/transform_order_test.zig` (5 tests) pins the
correct order against the column-vector convention anchor (`drawMesh`:
`mvp = matrixMul(proj, model_view)`).  Uses a deliberately asymmetric
TRS fixture — non-uniform scale + a real rotation + non-zero
translation — because with uniform scale or zero translation the
buggy and correct orders coincide, which is exactly why smoke never
caught any of this.  Each test was confirmed to FAIL against the
buggy code before the fix landed.

**Bugs fixed:**
1. `scene.zig` `SceneTransform.matrix()` — built math `S * R * T`,
   corrected to `T * R * S`.  Hard confirmation: the consumer reads
   `world.m12/m13/m14` as world translation, valid only for `T*R*S`.
2. `scene.zig` `worldMatrixOf` hierarchy fold — folded leaf-outermost,
   corrected to root-outermost (`root * ... * leaf`) by swapping the
   `matrixMul` args in the fold loop.
3. `render.zig` skybox `view_proj` — composed `view * proj` then
   inverted; corrected to `proj * view` (world→clip order).
4. `render.zig` shadow `light_space` — composed
   `light_view * light_proj`; corrected to `light_proj * light_view`.
   Same error class as #3; not in the original logged list.

#1 and #2 are fully pinned by host tests.  #3 and #4 feed shaders, so
the gate is also visual — `skybox` and `pbr_demo` standalones rebuilt
off post-fix code (skybox view_proj; pbr_demo shadows + skybox).

**Audit:** host tests 1314 → 1319 (+5), smoke 100/100, fmt clean,
globals 0/0/0.

**Files touched:** new `src/tests/transform_order_test.zig`,
`src/tests.zig` (wire-in), `src/scene.zig` (2 fixes),
`src/render.zig` (2 fixes), `src/notes/matrix-fix-plan.md` +
`src/notes/zmath-adoption-plan.md` (status), `bench/` (vec-layout
microbench harness added this turn).

**Next:** zmath-adoption Z0 — vendor zmath verbatim as `src/math.zig`,
wire its own test target, fix only Zig-version drift.  Prerequisite
is now cleared.
