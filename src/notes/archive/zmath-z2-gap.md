# zmath adoption — Z2 gap analysis

Companion to `zmath-adoption-plan.md`. Produced turn 224. This is the
concrete work list for Z2: "make `math.zig` a strict superset of
zimr's math needs."

## Method

Diffed `zimrmath.zig`'s public API (181 `pub fn`, minus the 10 Z1
conversion-layer fns = 171 math fns) against `math.zig`'s (162
`pub fn`). The raw name-diff is 168 — but that number is almost
entirely **naming convention**, not capability: zmath has `dot3` /
`cross3` / `normalize3` / `mul` / `inverse` / `determinant` /
`transpose` / the full `rotation*` / `scaling` / `translation` /
`perspectiveFov*` / `ortho*` / `lookAt*` / `quatFrom*` / `slerp`
family. zimr just spells them `vector3DotProduct`, `matrixInvert`,
etc.

The list below is the **true gap**: capability zmath genuinely does
not have. Every entry was confirmed to have live call sites outside
`zimrmath.zig` + tests, so nothing here is skippable dead API.

## Category 1 — Vector2 (the big one): zmath has NO 2D at all

zmath is 3D/4D only. There is no `Vec2`, no 2D ops. All 32 of zimr's
`vector2*` functions are gap. Per the adoption plan's locked
decision, the compute type stays `@Vector(4,f32)` even for 2D — 2D
ops operate on lanes 0,1 and ignore/zero 2,3. (The plan's benchmark
settled that a dedicated `@Vector(2,f32)` is not worth it.)

Functions (32): `vector2Add` `vector2AddValue` `vector2Angle`
`vector2Clamp` `vector2ClampValue` `vector2CrossProduct`
`vector2Distance` `vector2DistanceSqr` `vector2Divide`
`vector2DotProduct` `vector2Equals` `vector2Invert` `vector2Length`
`vector2LengthSqr` `vector2Lerp` `vector2LineAngle` `vector2Max`
`vector2Min` `vector2MoveTowards` `vector2Multiply` `vector2Negate`
`vector2Normalize` `vector2One` `vector2RandomInUnitDisk`
`vector2Reflect` `vector2Refract` `vector2Rotate` `vector2Scale`
`vector2Subtract` `vector2SubtractValue` `vector2Transform`
`vector2Zero`.

Most are one-liners over lanes 0,1. `vector2Transform` (against a
`Mat`) and `vector2Rotate` need care. `vector2RandomInUnitDisk`
needs an RNG parameter — see Category 5.

## Category 2 — scalar utilities (10)

zmath operates on vectors; these are scalar-`f32` helpers zimr uses
widely. All tiny (3–10 lines each in zimrmath).

- `floatEquals` — epsilon compare
- `fract` — fractional part
- `wrap` — wrap value into [min,max)
- `remap` — re-range a scalar (zmath has `mapLinear` on vectors — a
  scalar `remap` can wrap it, or stand alone)
- `rcp` — reciprocal (zmath has no scalar rcp; it has vector recip
  approximations — keep a clean scalar one)
- `luminance` / `luminance8` — RGB→luma (used by 5 non-math files)
- `floatToHalf` / `halfToFloat` — f16 conversion (used by 4)
- `normalize` — NB this is the **scalar** `normalize` in the raw
  diff; zmath's vector `normalize3/4` already cover the vector case.
  Confirm what zimr's bare `normalize` actually does before porting
  (may be scalar-into-range, not vector-normalize).

## Category 3 — color / bit-packing (14)

Not really "math library" material, but they live in zimrmath today
and zmath has nothing like them. Port as-is into a clearly-marked
sub-section, or consider relocating to a `color.zig` in a later
turn — flag for Simon. List: `color8ToColor` `colorToColor8`
`compress8to1..6` `expand1to8..6to8`.

## Category 4 — vector3 / matrix / quaternion ops genuinely absent

zmath has the common ones; these specific ops it does not.

vector3 (18): `vector3Angle` `vector3Barycenter` `vector3CubicHermite`
`vector3Distance` `vector3DistanceSqr` `vector3Equals`
`vector3MoveTowards` `vector3OrthoNormalize` `vector3Perpendicular`
`vector3Project` `vector3Reject` `vector3RandomInUnitSphere`
`vector3RandomUnitVector` `vector3Refract` `vector3RotateByAxisAngle`
`vector3RotateByQuaternion` `vector3ToFloatV` `vector3Unproject`.
(`vector3Distance` etc. are trivial over `length3`; `Project`/
`Reject` are ~10 lines; `Barycenter` ~29; the `Random*` need an RNG.)

matrix (5): `matrixCompose` `matrixDecompose` (~100 lines — the big
one) `matrixTrace` `matrixFrustum` `matrixToFloatV`.

quaternion (6): `quaternionFromVector3ToVector3` (~24 lines)
`quaternionCubicHermiteSpline` `quaternionToEuler` `quaternionFromEuler`
`quaternionEquals` `quaternionTransform`.

## Category 5 — RNG-dependent ops — RESOLVED

`vector2RandomInUnitDisk`, `vector3RandomInUnitSphere`,
`vector3RandomUnitVector` need a random source. **Resolved:** the
`math.zig` versions take a `*std.Random` parameter. Keeps the fork
pure and global-state-free (matches zmath's whole design); it's the
only option that works without a hidden global. zmath has no RNG
convention to honor, so we pick the best one.

## Category 6 — euler-order question — RESOLVED (ship two, named)

raylib's `quaternionFromEuler` and zmath's `quatFromRollPitchYaw`
use *different* rotation orders — verified empirically: raylib is
**XYZ**, zmath is **ZXY**. The order *is* the operation (different
orders produce different rotations), so this is NOT a decision-7
"two spellings" case — it is two distinct operations, both with real
callers. **Resolved:** ship both, with explicit honest names that
fix both libraries' opaque naming:
  - `quatFromEulerXYZ` / `quatToEulerXYZ`  (raylib's order)
  - `quatFromEulerZXY` / `quatToEulerZXY`  (zmath's order)
zmath's `quatFromRollPitchYaw` / `quatToRollPitchYaw` stay as
documented aliases for the ZXY pair. Only these two orders ship —
the other four are not added speculatively.

## Category 3 — color / bit-packing — RESOLVED (relocate)

`color8ToColor` `colorToColor8` `compress8to1..6` `expand1to8..6to8`.
**Resolved:** these are not math — they move to a new `src/color.zig`
during Z2, not into `math.zig`. `math.zig` stays a math library.

## Suggested Z2 execution order

1. ✅ **DONE (turn 225)** — Scalar utils (Cat 2). Ported into
   `math.zig`'s "zimr additions" section: `floatEquals` /
   `floatEqualsEps`, `frac32`, `wrap32`, `rcp32`, `luminance` /
   `luminance8`, `floatToHalf` / `halfToFloat`. Scalar `remap` and
   scalar `normalize` deliberately skipped — they are `mapLinear` /
   `lerpInverse`, which already take scalars (decision 7).
2. ✅ **DONE (turn 226)** — Vector2 (Cat 1). Decision 7 shrank this
   from raylib's 32 `vector2*` fns to 13 genuine gaps: `cross2`,
   `distance2`, `distanceSq2`, `angle2`, `lineAngle2`, `reflect2`,
   `refract2`, `rotate2`, `transform2`, `clampLength2`,
   `moveTowards2`, `equals2`, `randomInUnitDisk2`. The other 19 are
   either already in zmath (`dot2`/`length2`/`lengthSq2`/
   `normalize2`) or are `@Vector` operators / generic `min`/`max`/
   `clamp`/`lerp` that zmath has no named wrapper for by design.
   Side finding: `reflect`/`refract` are absent from zmath at every
   width — `reflect3`/`refract3` are now a step-3 entry.
3. ✅ **DONE (turn 227)** — vector3/4 absent ops (Cat 4 vectors). 19
   ported: 3D — `distance3`, `distanceSq3`, `angle3`,
   `perpendicular3`, `project3`, `reject3`, `reflect3`, `refract3`,
   `moveTowards3`, `equals3`, `orthoNormalize3`, `barycenter3`,
   `cubicHermite3`, `rotateByAxisAngle3`, `unproject3`; 4D —
   `distance4`, `distanceSq4`, `moveTowards4`, `equals4`. Decision-7
   skips: `vector3RotateByQuaternion` (= zmath `rotate`),
   `vector3ToFloatV` (= `vecToArr3`), `vector4Min`/`Max` (= generic
   `min`/`max`).
4. ✅ **DONE (turn 228)** — matrix + quaternion absent ops (Cat 4).
   11 ported: matrix — `matrixTrace`, `matrixFrustum`,
   `matrixCompose`, `matrixDecompose` (the effort spike; returns a
   `TRS` struct, reads rows since `Mat` is row-major); quaternion —
   `quatFromTo`, `quatCubicHermite`, `quatEquals`; euler —
   `quatFromEulerXYZ`/`quatToEulerXYZ` (raylib order),
   `quatFromEulerZXY`/`quatToEulerZXY` (zmath order). Decision-7
   skips: `matrixToFloatV` (= `matToArr`), `quaternionTransform`
   (= `mul`).
5. ✅ **DONE (turn 229)** — Color/bit-packing (Cat 3). Plan said
   "relocate to `src/color.zig`" — investigation changed it to a
   **dedup**. `rlsw_pixel.zig` already owns the canonical color +
   bit-packing code (`expandToByte`/`compressByteTo`,
   `byteColorToFloats`/`floatColorToBytes`); `floatToHalf`/
   `halfToFloat` were already in `math.zig` from step 1. zimrmath's
   versions were dead/duplicate — deleted, no `color.zig` created
   (shipping a third copy would violate decision 7).
6. RNG ops (Cat 5) take a `*std.Random` param; euler quats (Cat 6)
   ship TWO orders (`quatFromEulerXYZ` / `quatFromEulerZXY`). Both
   resolved and DONE — RNG ops landed across steps 2-3, euler in
   step 4.

**Z2 IS COMPLETE (turn 229).** `math.zig` is a strict superset of
zimr's math needs. Next phase is Z3 (call-site migration).

All ports land in `math.zig` in zmath's section style (the file is a
hard fork — edit it directly), each with zmath-style tests, so the
`math-test` step's count grows as the gap closes.
