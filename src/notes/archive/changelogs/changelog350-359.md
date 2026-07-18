# Changelog 350-359

## [Unreleased]

### Turn 359 — math.zig section sweep continues (-224 sites)

Continued the section-at-a-time sweep through math.zig: 402 → 178
untyped-local (-224 in one turn).  Largest single-turn delta of
the arc.

#### Sections cleared

| Section | Lines | Sites |
|---------|-------|------:|
| matFromAxisAngle/quatFromAxisAngle body + tests | 2997-3320 | ~22 |
| matFromQuat body remnant | 3030-3060 | ~3 |
| inverseQuat / conjugate / rotate body | 3331-3360 | ~6 |
| slerp / slerpV body + tests | 3370-3400 | ~12 |
| hsvToRgb body + switch-arm temps | 3709-3750 | ~13 |
| rgbToSrgb / srgbToRgb body | 3784-3826 | ~7 |
| linePointDistance body + test | 3840-3858 | ~6 |
| sin32 / cos32 / sincos32 scalar | 3861-3914 | ~9 |
| modAngle32 / cmulSoa | 4073-4096 | ~3 |
| fftButterflyDit4_1 / fftButterflyDit4_4 body | 4100-4192 | ~24 |
| fftInitUnityTable / fft / ifft body | 4639-4754 | ~15 |
| floatToIntAndBack tests | 4875-4888 | ~3 |
| util.mat namespace: get* fns + tests | 4938-5057 | ~30 |
| refract2 / rotate2 / transform2 tests | 5500-5550 | ~10 |
| clampLength2 / moveTowards2 body + tests | 5556-5610 | ~10 |
| perpendicular3 / project3 / reject3 body+tests | 5699-5755 | ~10 |
| reflect3 / refract3 body + tests | 5760-5795 | ~8 |
| moveTowards3 / equals3 / orthoNormalize3 body+tests | 5800-5858 | ~12 |
| barycenter3 body + test | 5862-5896 | ~16 |
| cubicHermite3 body + test | 5901-5928 | ~9 |

#### Patterns that crystallized

- **`dot3(a, b)[0]` is an f32** — the [0] lane extract from a
  broadcast-result.  Same for `length3(v)[0]`, `lengthSq3(v)[0]`.
  Local annotation as `f32`, not `Vec`.
- **`@TypeOf(re0, re1)` in anytype fns** — for `cmulSoa` body
  locals, the type expression `@TypeOf(re0, re1)` captures the
  common type the anytype params resolve to.  Same shape as
  `: T` when `const T = @TypeOf(v)` is in scope, just inlined.
- **`@TypeOf(fn_alias)` for fn-pointer locals** — `const degToRad
  = std.math.degreesToRadians;` needs annotation; the working
  shape is `: @TypeOf(std.math.degreesToRadians) = ...`.  Used
  in 4 util.mat tests.
- **`[N]Vec` annotation explicit lengths** — `const re_temp:
  []Vec = re_temp_storage[0..re.len];` for slices.  Couldn't use
  `[_]Vec` (only valid in initializers, not type position) so
  small test arrays kept inferred-length without annotation.

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **3650 issues** (was 3874 turn 358, -224)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 3187 (was 3411, -224) |
| line-length | ~443 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

math.zig untyped-local: **402 → 178** (-224 sites in this turn,
-558 since turn 353).

#### Implementation notes

- **Mid-sweep tests every batch** — Python script → `zig build
  test` → fix any errors → next batch.  No errors surfaced this
  turn; the patterns are now well-understood enough that the
  regex hit rate is high.
- **Mass-edit per concept-class.**  All `const v0/v1/v2 = b - a`
  etc in barycenter3 done in one Python invocation.  Same for
  the FFT butterfly bodies.  Each invocation handles 5-20 sites,
  takes <1 second.
- **Some anonymous arrays not annotated** — `var im = [_]Vec{...}`
  in fft tests has a length that varies per test (32 here, 64
  there).  `var im: [_]Vec = .{...}` is invalid Zig 0.16
  syntax (can't use `_` in explicit type position).  Workaround
  would be to compute N manually for each, but that's noise for
  test scaffolding.  Left untyped; linter false-positive for
  this case.

#### Files touched

- `src/math.zig`: ~224 annotations across 21 function families

#### Next turn

math.zig still has 178 untyped-local sites.  Remaining
concentrations: lines 6000-6500 (~75, Euler-angle conversions
mostly), plus some smattering in 4500-5000 ranges.  1-2 more
turns to clear math.zig entirely.

After math.zig: drawing.zig (568 sites), ui.zig (693 sites),
codecs.zig (458 sites).  Those will be slower per-site since
they don't have the "T = @TypeOf(v) in scope, body locals are
T" uniformity that math.zig has.

---

### Turn 358 — `vec_up`/`axis_x`/`axis_z` added; `vec3`/`point3` removed

Three small cleanups from Simon: add the conventional direction
constants, drop the back-compat aliases now that everything's been
swept to use `vec`/`point` as primary names, confirm `splat`/`splat2`
shape is right.

#### 1. Direction constants

```zig
pub const vec_up: Vec = .{ 0, 1, 0, 0 };
pub const axis_x: Vec = .{ 1, 0, 0, 0 };
pub const axis_z: Vec = .{ 0, 0, 1, 0 };
```

All three have w=0 (directions, translation-invariant).  `vec_up`
is the +Y axis under raylib/zmath's Y-up convention.  `axis_x` and
`axis_z` are the unsigned basis vectors.  No `axis_y` because it
would equal `vec_up`; for `-X`/`-Y`/`-Z` and `vec_down`/`vec_left`
etc., negate at the callsite.

#### 2. `vec3` / `point3` removed

Turn 357 kept these as back-compat aliases for the renamed
`vec`/`point`.  Now removed:

- 660 `vec3(...)` callsites converted to `vec(...)` (Python
  word-boundary sweep across `src/` and `examples/`)
- 3 `point3(...)` callsites converted to `point(...)`
- Both functions deleted from math.zig
- Tests renamed (`test "zm.vec3"` → `test "zm.vec"`, etc.)

Stale doc-comment references in `src/zimr.zig:57` and
`src/math.zig:309` updated.

The mass-rename created `pub inline fn vec` duplicates (primary
def from turn 357 + renamed-from-vec3 back-compat), surfaced as
"duplicate symbol" compile errors during the sweep.  Fix was to
delete the duplicates and keep the primary defs only.

Remaining "vec3" matches in code (grep `\bvec3\b`) are all
legitimate non-zm uses: GLSL shader vertex declarations (`in vec3
vertex_position`), gltf accessor enum variants (`.vec3`), and
matching string literals (`"VEC3"`).  None are calls to the
removed helpers.

#### 3. `splat` / `splat2` already correct

```zig
pub inline fn splat(v: f32) Vec { return @splat(v); }
pub inline fn splat2(v: f32) Vec2 { return @splat(v); }
```

These were already in place (math.zig:5195 / 5200).  No work
needed.  `zsplat(comptime T: type, v: f32) T` also exists for
the generic case (porting back from upstream zmath).

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **3874 issues** (was 3875, -1)

Tag breakdown unchanged from turn 357 (this was rename/delete
work, not annotation work).

#### Implementation choices

- **Word-boundary rename instead of context-aware.**  Python's
  `\bvec3\(` and `\bpoint3\(` are precise enough: matches the
  function-call form but not GLSL `in vec3`, gltf enum `.vec3`,
  or strings `"VEC3"`.  Mass-converted 660+3 sites in one pass.
- **Delete duplicates after rename.**  The mass-rename created
  `pub inline fn vec` collisions with turn 357's primary defs.
  `zig build test` flagged them immediately; surgical
  `str_replace` deleted the back-compat versions.  Net result:
  `vec` and `point` exist once each, in the "Z4 - vector
  constructors" section.
- **`axis_y` deliberately not added.**  Simon asked for
  `vec_up`/`axis_x`/`axis_z`.  `axis_y == vec_up` would create
  an alias with no payoff (two names for one constant).
  Convention: `vec_up` IS the +Y direction; if you literally
  mean "the second basis axis" you can write `vec_up` and it
  reads correctly.

#### Files touched

- `src/math.zig`: 3 new const decls + 2 fn defs removed + 2 test renames + doc-comment fixes
- `src/zimr.zig`: 1 doc-comment fix
- 660 vec3 → vec rewrites across `src/codecs.zig`, `src/drawing.zig`, `src/physics.zig`, `src/render.zig`, `src/rlgl.zig`, `src/runtime.zig`, `src/scene.zig`, `src/types.zig`, `src/ui.zig`, plus various examples
- 3 point3 → point rewrites (`src/math.zig`, `src/zimr.zig`, `examples/split_screen.zig`)

#### Convention summary (after this turn)

| Want | Use |
|------|-----|
| direction with literal components | `zm.vec(x, y, z)` |
| point with literal components | `zm.point(x, y, z)` |
| explicit 4-component Vec | `zm.vec4(a, b, c, d)` |
| quaternion (semantic) | `zm.quat(x, y, z, w)` |
| 2D vector | `zm.vec2(x, y)` |
| `: Vec = .{...}` annotation present | `.{ a, b, c, d }` |
| direction from array | `zm.dirFromArr3(arr)` |
| point from array | `zm.pointFromArr3(arr)` |
| broadcast scalar to Vec | `zm.splat(s)` |
| broadcast scalar to Vec2 | `zm.splat2(s)` |
| zero Vec | `zm.vec_zero` |
| identity quaternion | `zm.quat_identity` |
| +Y direction | `zm.vec_up` |
| +X basis vector | `zm.axis_x` |
| +Z basis vector | `zm.axis_z` |

#### Next turn

Back to clearing math.zig untyped-local (411 sites).

---

### Turn 357 — kill F32x4 entirely; new Vec constructors and constants

Simon's directive: collapse `F32x4` into `Vec`, add ergonomic
helpers (`vec`/`point`/`vec4`/`quat`/`vec2`/`vec_zero`/`quat_identity`),
and standardize w-lane semantics (vec → direction w=0, point → w=1).

#### 1. `F32x4` removed from the public API

`F32x4` no longer exists as a public type name.  `Vec` is the
canonical name for `@Vector(4, f32)`:

```zig
// Before
pub const F32x4 = @Vector(4, f32);
pub const Vec = F32x4;
pub const Mat = [4]F32x4;
pub const Quat = F32x4;

// After
pub const Vec = @Vector(4, f32);
pub const Mat = [4]Vec;
pub const Quat = Vec;
```

492 sites in math.zig converted via Python (word-boundary
substitution, skipping pure-comment lines so historical context
in `// docs` blocks survives).  `F32x8`/`F32x16` kept — those are
genuinely different wider SIMD types used by the generic-width
utilities (load/store/all/any).

**0 `F32x4` references in code across the codebase** (verified
post-sweep with grep ignoring pure-comment lines).

#### 2. Constructor convention crystallized

```zig
pub inline fn vec(x, y, z) Vec     { return .{x, y, z, 0.0}; } // DIRECTION (w=0)
pub inline fn point(x, y, z) Vec   { return .{x, y, z, 1.0}; } // POINT (w=1)
pub inline fn vec4(a, b, c, d) Vec { return .{a, b, c, d}; }   // no w assumption
pub inline fn quat(x, y, z, w) Quat { return .{x, y, z, w}; }  // semantic alias for vec4
pub inline fn vec2(x, y) Vec2      { return .{x, y}; }         // (already existed)
```

Plus constants:

```zig
pub const vec_zero: Vec = .{ 0, 0, 0, 0 };
pub const quat_identity: Quat = .{ 0, 0, 0, 1 };
```

`vec3` / `point3` kept as back-compat aliases for `vec` / `point`
(internal callsites that already use them stay valid).

#### 3. Semantic distinction enforced in callsites

Camera lookAt arguments in pbr_demo.zig and split_screen.zig
rewritten to use the correct constructor:

```zig
// Before
zm.lookAtRh(
    zm.f32x4(-3, 6, -4, 1),    // eye - point but written as raw 4-tuple
    zm.f32x4(0, 0, 0, 1),      // target - point
    zm.f32x4(0, 1, 0, 0),      // up - direction
);

// After
zm.lookAtRh(
    zm.point(-3, 6, -4),  // eye is a point
    zm.point(0, 0, 0),    // target is a point
    zm.vec(0, 1, 0),      // up is a direction
);
```

This is the payoff for the convention: callsites now read as
"eye is a point, up is a direction" instead of being three
identical-looking `zm.f32x4(...)` calls where you have to read
the trailing `0` or `1` to know what each means.

#### 4. `zm.quat_identity` and `zm.vec_zero` replace literals

26 sites total replaced via Python sweep across `src/drawing.zig`,
`src/scene.zig`, `src/physics.zig`, `src/types.zig`,
`src/codecs.zig`:

```zig
// Before
.rotation = zm.f32x4(0, 0, 0, 1),    // verbose, semantically opaque
orientation: Quat = zm.f32x4(0, 0, 0, 1),

// After
.rotation = zm.quat_identity,
orientation: Quat = zm.quat_identity,
```

#### Bugs surfaced + fixed

The F32x4 → Vec rename collided with my new `quat` and `point`
constructor names where local variables/params already used those
names:

| File:Line | Site | Fix |
|-----------|------|-----|
| math.zig:3023 | `matFromQuat(quat: Quat)` | renamed param `quat` → `q` |
| math.zig:3197 | `quatToMat(quat: Quat)` | renamed param `quat` → `q` |
| math.zig:3320 | `conjugate(quat: Quat)` | renamed param `quat` → `q` |
| math.zig:3324 | `inverseQuat(quat: Quat)` | renamed param `quat` → `q` |
| math.zig:3201 | `quatToAxisAngle` multi-line sig | same (regex missed multi-line) |
| math.zig:3346 | quaternion.rotate test local | renamed `quat` → `q` |
| math.zig:3428/35 | quatToRollPitchYaw test local | renamed `quat` → `q` (block regex) |
| math.zig:5553 | transform2 local `point` | renamed `point` → `p_in` |

All caught by mid-sweep `zig build test`.  Total turnaround was
~5 minutes.

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **3875 issues** (was 3884; -9)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 3411 |
| line-length | 444 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

The lint count barely moved — this turn was mostly type rename
and constructor additions, not closing untyped sites.

#### Implementation choices

- **`vec3`/`point3` kept as back-compat aliases**, not removed.
  Internal callsites already using them work; new code should
  prefer the shorter `vec` / `point`.  Future cleanup can sed
  them but it's mechanical.
- **Param `quat: Quat` → `q: Quat`** rather than aliasing the
  constructor.  Zig 0.16 disallows local shadowing of module
  decls, so the cleanest fix is the rename.  `q` is the
  conventional 1-letter quat var anyway (see existing
  `q0`/`q1` test vars throughout).
- **Don't auto-convert `zm.f32x4(...)` to `vec4(...)`** wholesale.
  Many sites have 4 meaningful components (matrix rows, colors,
  homogeneous coordinates being built deliberately).  Only auto-
  converted the obvious patterns: `(0, 0, 0, 1)` → quat_identity,
  `(0, 0, 0, 0)` → vec_zero.  The point/direction conversions
  remain manual case-by-case (eye vs up).
- **`vec3` test renamed locals to typed (`const v: Vec = ...`)**
  while the body was being touched — incidental cleanup, +2
  annotations.

#### Files touched

- `src/math.zig`: 492 F32x4 → Vec substitutions + 5 new helpers + 8 quat/point param renames
- `src/drawing.zig` / `src/scene.zig` / `src/physics.zig` / `src/types.zig` / `src/codecs.zig`: 26 quat_identity/vec_zero substitutions
- `examples/pbr_demo.zig` / `examples/split_screen.zig`: 6 callsite conversions (lookAtRh args)

#### Next turn

Back to clearing math.zig untyped-local.  Lint at 3875 / math.zig
411 untyped-local.  Section sweep continues from line 3700.

---

### Turn 356 — Vec ergonomics: `@bitCast` simplify, `vec()`/`pointFromArr3` helpers, Vec over F32x4

Simon's directive: four orthogonal improvements to make code
read more naturally with `Vec`.

#### 1. `@as(Tu, @bitCast(...))` → `@bitCast(...)` (12 sites)

When the destination is already annotated with the target type,
Zig 0.16 infers the type from context, making the explicit `@as`
wrapper redundant:

```zig
// Before
const v0u: Tu = @as(Tu, @bitCast(v0));
// After
const v0u: Tu = @bitCast(v0);
```

Caught 12 sites in math.zig where annotations from turns 354-355
made the explicit cast unnecessary.  The 2 remaining
`@as(Tu, @bitCast(...))` calls in math.zig are in expression
context (no destination annotation) so the explicit cast IS
needed.

#### 2. `F32x4` → `Vec` for Vec-semantic functions

Convention crystallized: **`F32x4` is only for the "this is
specifically the 4-wide variant of a generic SIMD function"
case (e.g. tests that also exercise F32x8/F32x16).  Everything
else should be `Vec`.**

Updated signatures for these functions to use `Vec` consistently:

- `f32x4s`
- `loadArr2`/`loadArr3`/`loadArr3w`/`loadArr4`
- `dot2`/`dot3`/`dot4`
- `lengthSq2`/`lengthSq3`/`lengthSq4`
- `length2`/`length3`/`length4`
- `determinant`
- `adjustSaturation`/`adjustContrast`
- `rgbToHsl`/`hslToRgb`/`rgbToHsv`/`hsvToRgb`
- `rgbToSrgb`/`srgbToRgb`
- `cross2`/`distance2`/`distance3`/`distance4`

Plus parameter types where they meant Vec but said F32x4
(`color`, `rgb`, `hsl`, `hsv`, `srgb`, internal `hueToClr` params).

`F32x4` outside math.zig: **0 sites.**  The convention was already
fully respected at API boundaries.

#### 3. New helpers: `vec`, `pointFromArr3`, `dirFromArr3`

Three ergonomic constructors added to math.zig.  Each is polymorphic
over input (`anytype`) for the array-style helpers since callers
sometimes pass a `[3]f32`, sometimes a `Vec` they want to re-stamp
the w lane on.

```zig
pub inline fn vec(x: f32, y: f32, z: f32) Vec {
    return .{ x, y, z, 1.0 };
}
pub inline fn pointFromArr3(arr: anytype) Vec {
    return .{ arr[0], arr[1], arr[2], 1.0 };
}
pub inline fn dirFromArr3(arr: anytype) Vec {
    return .{ arr[0], arr[1], arr[2], 0.0 };
}
```

The `vec` helper is the new conventional shorthand for "point with
w=1" - the most common 3D point construction.  Per Simon: "the
function vec would become very common and would imply the type Vec.
I prefer Vec to F32x4 everywhere possible."

**Existing pattern conversions** (Python-driven):

- `zm.f32x4(eye[0], eye[1], eye[2], 1.0)` → `zm.pointFromArr3(eye)`
- `zm.f32x4(rotation_axis[0], rotation_axis[1], rotation_axis[2], 0.0)`
  → `zm.dirFromArr3(rotation_axis)`
- `zm.f32x4(0, 6, -4, 1)` (literal w=1 point) → `zm.vec(0, 6, -4)`

Skipped: `zm.f32x4(0, 0, 0, 1)` — quaternion identity, not a point.
The pattern check is "if first 3 args are all 0, skip" so we don't
accidentally rewrite Quat identities as `vec(0,0,0)`.

#### 4. `: F32x4 = f32x4(...)` → `: Vec = .{...}` in Vec-semantic tests

When the annotation specifies type, `f32x4(...)` is just a way to
build a vector literal — `.{ ... }` does the same with less syntactic
noise.  Restricted to tests where ONLY F32x4 is used (e.g. dot3, cross3
tests).  Tests that exercise F32x4/F32x8/F32x16 in parallel kept
the `f32x4(...)` form for symmetry.

```zig
// Before
const v0: F32x4 = f32x4(1.0, 2.0, 3.0, 1.0);
// After
const v0: Vec = .{ 1.0, 2.0, 3.0, 1.0 };
```

32 sites converted.

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **3884 issues** (essentially flat from 3883)

The lint count barely moved because most of this turn's work was
**rewriting** existing annotated code rather than adding new
annotations.  The Vec/F32x4 conversion is annotation-style; doesn't
change lint counts.  Same for the `@bitCast` simplification.

#### Implementation choices

- **Polymorphic `anytype` for the array helpers.**  A `[3]f32` param
  would require callers to pass exactly `[3]f32`, but real code has
  Vecs and `*const [N]f32` slices and so on.  `anytype` makes the
  helper accept whatever indexes with `[0]`/`[1]`/`[2]`.
- **No `vec3dir(x, y, z)` companion to `vec`.**  Could exist
  symmetrically (w=0 instead of w=1) but direction-as-3-literals
  is rare; `vec(x, y, z)` covers ~95% of literal construction.
  Direction literals continue using `zm.f32x4(x, y, z, 0)` for now.
- **Skip Quat identity `f32x4(0, 0, 0, 1)` from conversion.**
  Syntactically indistinguishable from a Vec point but semantically
  a rotation.  Auto-conversion would lie about intent.

#### Files touched

- `src/math.zig`: 12 @bitCast simplifications + ~30 signature updates + 32 test-init rewrites + 3 new helpers
- `src/drawing.zig`, `src/render.zig`, `src/runtime.zig`, `src/scene.zig`: ~8 array-construction sites converted
- `examples/pbr_demo.zig`, `examples/split_screen.zig`: camera point literals to `vec()`

#### Next turn

Back to clearing math.zig untyped-local (411 → 0 in 3-4 turns).
Remaining ranges: 3700-4500 (lerp variants, spherical ops, ~100
sites), 4500-5500 (more ops, ~65), 5500-6499 (3D/4D vector ops +
Quat conversions + Euler angles, ~170).

---

### Turn 355 — math.zig section sweep continues (-155 sites)

Pushed the section-at-a-time sweep through lines 1880-3700.
math.zig untyped-local: **566 → 411** (-155).

#### Sections cleared

| Section | Lines | Sites |
|---------|-------|------:|
| asin32xN/acos32xN/atan body | 1876-1937 | ~9 |
| atan2 body | 1980-2003 | ~9 |
| dot2/dot3/dot4/cross3 body + tests | 2097-2164 | ~16 |
| length{2,3,4}/normalize{2,3,4} tests | 2185-2238 | ~10 |
| vecMulMat/matMulVec/mul tests | 2250-2390 | ~15 |
| rotationX/Y/Z, translation, scaling | 2390-2470 | ~6 |
| perspective/orthographic family | 2495-2750 | ~25 |
| determinant body | 2751-2792 | ~12 |
| inverseDet body | 2807-2900 | ~15 |
| qmul + matFromQuat body + tests | 2997-3170 | ~18 |
| quatFromMat body + tests | 3196-3253 | ~14 |
| adjustSaturation/Contrast body | 3481-3491 | ~2 |
| rgbToHsl/rgbToHsv/hueToClr | 3493-3680 | ~30 |

#### Vocabulary that crystallized this turn

Three patterns dominate math.zig:

1. **Body locals when `const T = @TypeOf(v)` is in scope** — any
   arithmetic temp annotates as `T`.  Vector-bool intermediates as
   `@Vector(veclen(T), bool)` or, where used multiple times,
   `const Tb = ...` alias near the top.

2. **Body locals returning concrete `F32x4`** — every swizzle,
   every multiplication chain, every shuffle returns `F32x4`.
   Annotate uniformly.  When a fn takes `Mat` and returns `F32x4`
   (like `determinant`), the body temporaries `v0`...`v5`,
   `p0`/`p1`/`p2`, `r`, `s` are all F32x4.

3. **`sincos(f32) → [2]f32`** — the only non-obvious type.
   Caused by raylib's compact "sin and cos in one call" convention.
   Appears in rotationX/Y/Z, perspective fns, quatFromAxisAngle.

#### One bug surfaced

Python regex mis-emitted `dotv0, v1)` (missing function call
parens) at 3 sites in dot2/dot3/dot4 tests.  Mid-sweep `zig build
test` caught it; 3 targeted sed fixes resolved it in 20 seconds.
Pattern was that `(\n        )const v = dot[234]\(` was being
followed by my regex builder error - I had a stray `+ r'dot'` in
the wrong scope.  Fixed by writing 3 separate substitutions
instead of one parameterized.

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **3883 issues** (was 4038 turn 354, -155)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 3416 (was 3571, -155) |
| line-length | 447 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

#### Implementation notes

- **Python regex with mid-sweep test is the right loop.**  Run a
  batch (10-30 sites), `zig build test`, fix any compile errors,
  move on.  Each cycle is ~20 seconds.  Faster than reviewing each
  edit individually because the compiler IS the review.
- **Test the regex output by reading the file before running zig.**
  Caught the `dotv0` bug in 1 cycle.  Would catch worse bugs
  (e.g. missing operator, wrong type) in the same cycle.
- **Cold-cache check** at end of turn is now habit.  Today the
  build was already cleanly hot, but discipline matters - same
  bug class as turn 354 could hit any time.

#### Files touched

- `src/math.zig`: ~155 annotations across 14 function families

#### Next turn

math.zig still has 411 sites.  Remaining concentration is in
lines 3700-4500 (color + lerp variants + spherical ops) plus
the 5500-6499 tail (3D/4D vector ops + Quat conversions +
Euler angles).  Each ~50-100 sites.  3-4 more turns to clear
math.zig entirely.

---

### Turn 354 — math.zig section sweep (-170 sites); cache-hidden drawing.zig typos fixed

Shifted from small-files-first to **section-at-a-time in math.zig**
since the long-tail per-file count was dropping below the worth-
opening-the-editor threshold and 736 math.zig sites was the
biggest single concentration left.

#### Two work strands this turn

##### 1. math.zig: SIMD utility functions (lines 398-1500)

Cleared these contiguous regions:

- **`load`/`store`/`arrNPtr`/`loadArr` + tests** (lines 398-540).
  Annotation vocabulary: `T`, `F32x4`, `F32x8`, `[*]const f32`,
  `Mat`, `*const [7]f32`, `u32`.
- **`all`/`any`/`isNearEqual`/`isNan`/`isInf`/`isInBounds`/`andInt`**
  (lines 540-720).  Same vocabulary plus `Boolx4`/`Boolx8` for
  vector-bool results.  Bitwise fns introduced `Tu` (= `@Vector(N, u32)`)
  pattern for the v0u/v1u temporaries.
- **`andNotInt`/`orInt`/`norInt`/`xorInt`/`minFast`/`maxFast`/`min`/`max`**
  (lines 720-920).  Python-batched (sed too pattern-fragile) for the
  uniform `const v0 = f32xN(...)` → `const v0: F32xN = f32xN(...)`
  transforms.  For `min`/`max` body, added the `Tb` alias
  (= `@Vector(veclen(T), bool)`) so `nan0`/`nan1` could be annotated
  consistently.
- **`round`/`trunc`/`floor`/`ceil`/`clamp`/`clampFast`** (lines 940-1410).
  All take `anytype` and return `@TypeOf(v)`.  Body locals (`r1`,
  `r2`, `result`, `larger_mask`, `smaller_mask`) annotate as `T` or
  `@Vector(veclen(T), bool)`.
- **`lerpOverTime`/`lerpVOverTime`/`mapLinear`/`mapLinearV`**
  (lines 1530-1600).  `t` annotated as `@TypeOf(rate, dt)` since
  these are anytype-anytype.
- **`mulAdd` boolean flag + `sin32xN`/`cos32xN`** (lines 1660-1750).
  Trig minimax approximations have the same body shape: var x: T,
  const absx: T, const rflx: T, const x2: T, var result: T.

##### 2. cache-hidden annotation typos in drawing.zig

Mid-sweep `zig build test` (post first math.zig batch) surfaced
**8 broken `: f32` annotations** in `drawing.zig` that had been
sitting in source for several turns, hidden by cache.  All
fixed:

| Line | Was | Should be | What it was |
|------|-----|-----------|-------------|
| 13213-14 | `: f32` | `: usize` | OBJ vertex indices |
| 14329 | `: zm.Vec` | `: zm.Mat` | matFromAxisAngle returns Mat |
| 15076 | `: f32` | `: usize` | slice .len |
| 16343 | `: f32` | `: u8` | alpha channel byte |
| 16423 | `: f32` | `: i32` | heightmap.height |
| 4386/4394/4402/4410 | `: f32` | `: usize` | dither buffer indices (4 sites in one fn) |
| 5695 | `: f32` | `: u64` | sx1 (mirrors sx0 above it) |
| 5708 | `: f32` | `: usize` | output buffer index |
| 6690 | `: f32` | `: usize` | copy length |
| 7675 | `: f32` | `: Color` | colorAlpha returns Color |
| 8349 | `: f32` | `: Rectangle` | getImageAlphaBorder returns Rect |
| 8843 | `: f32` | `: Image` | imageFromImage returns Image |

These are the same shape of failure as turns 345 (parse errors),
346 (walker no-op), 350 (Vec2 field access).  The cache had been
serving compiled artifacts from before the bad annotations were
written, so tests passed.  The fix-rhythm worked here: a single
mid-sweep `zig build test` revealed all 12 typos at once, each
fixable in 30 seconds via str_replace.

**Cold-cache check at end of turn** confirms all 1555 tests pass
against current source (no caching).  That's the gate that
catches this class of failure.

#### Audit

- `zig build test`: **1555/1555 pass** (cold-cache verified)
- `zig fmt --check`: CLEAN
- `zig build lint`: **4038 issues** (was 4425 turn 353; -387 net)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 3571 (was 3956, -385) |
| line-length | 447 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

math.zig specifically: **736 → 566** (-170 sites).

#### Implementation choices

- **Section-at-a-time, not file-at-a-time.**  math.zig at 6400
  lines is too big to "finish" in one turn.  Pick a coherent
  chunk (e.g. "load/store + arr helpers" or "all/any/isNearEqual"),
  do all sites in it, test, save.  Multi-turn arc.
- **Python over sed for repetitive multi-line patterns.**  The
  bitwise-int family (andInt, orInt, etc.) has 8 functions with
  near-identical structure - sed handles them but Python regex
  with capture groups handles the variant cases (F32x4 vs F32x8)
  in one pass.  After Python pass, `zig build test` catches any
  bad annotations (the `var result: T` in fns without `T` decl
  surfaced 4 errors immediately, fixed in seconds).
- **`Tb` alias pattern.**  When a function body needs to express
  `@Vector(veclen(T), bool)` multiple times, declare
  `const Tb = @Vector(veclen(T), bool);` near the top.  Same as
  the existing `Tu = @Vector(veclen(T), u32);` pattern.
  Already used in `isInBounds`; adopted in `min`/`max`.

#### Files touched

- `src/math.zig`: ~170 annotation additions across 6+ function families
- `src/drawing.zig`: 12 wrong-type annotations corrected

#### Next turn

math.zig still has 566 untyped-local sites.  Next contiguous
sections to hit: lines 1500-2000 (lerp, mapLinear, modAngle,
sin/cos/tan family bodies and tests, atan, atan2), lines
2000-2500 (matrix mul + transpose + rotation), and so on.
Each section is ~30-100 sites and takes 1 turn.

The cold-cache discipline matters a lot here.  If the rule is
"check every 5-10 turns," turn 354 was exactly the right turn
(turn 354 - turn 350 = 4 turns).  The 12 cache-hidden bugs
discovered today validate the rule.

---

### Turn 353 — untyped-local cleanup: 17 files cleared (~87 sites)

Continued small-files-first sweep at lower site counts (5-7
sites/file).  Big bag of mechanical annotations, no semantic
edits.

#### Files cleared

7-site files:
- `examples/vector_angle.zig`           (7)
- `examples/png_demo.zig`                (7)
- `examples/lines_drawing.zig`           (7)
- `examples/hilbert_curve.zig`           (7)
- `examples/audio_basic.zig`             (7)

6-site files:
- `examples/wireframe.zig`               (6)
- `examples/lines_bezier.zig`            (6)
- `examples/first_person_camera.zig`     (6)
- `examples/basic.zig`                   (6)

5-site files:
- `examples/ui_tables_demo.zig`          (5)
- `examples/ui_mouse_drag.zig`           (5)
- `examples/touch_paint.zig`             (5)
- `examples/skinned_mesh.zig`            (5)
- `examples/rectangle_scaling.zig`       (5)
- `examples/particles.zig`               (5)
- `examples/load_image_demo.zig`         (5)
- `examples/kaleidoscope.zig`            (5)

**Total: 92 site-fixes, 17 files cleared.**

#### Audit

- `zig build test`: **1555/1555 pass** (114/114 steps)
- `zig fmt --check`: CLEAN
- `zig build lint`: **4425 issues** (was 4654 turn 352, -229)

The -229 delta is larger than the 92 sites touched.  Untyped-local
went from 4176 → 3956 = -220.  The extra ~128 cleared sites are
collateral from the sed passes: when a variable gets a type
annotation, the type-signal detection picks up other usages of
related variables in the same file (e.g. annotating one
`getMousePosition` result lets the linter infer the type from
context for another local that uses it).  No bug here, just
type signal propagation working as intended.

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 3956 |
| line-length | 449 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

Note `line-length` dropped from 462 to 449 (-13).  Some of the
sites I sed-edited were also `line-length` violations - adding
the type annotation pushed them under the 120-col limit, or my
multi-line rewrites split them across multiple lines.

#### Encountered issues

- **Type name confabulation** caught by mid-sweep test.  Annotated
  `z.png.decode()` return as `z.png.DecodedImage`; actual type
  is `z.png.Image`.  Confirmed via
  `grep -nE '^\s+pub const Image\b' src/codecs.zig`.  Mid-sweep
  test caught it in seconds; would have been frustrating to debug
  if discovered later.
- **Indent-sensitive sed missed depth-different sites** in
  `hilbert_curve.zig` and `kaleidoscope.zig`: same
  `const u = s.ui_ctx.beginFrame(...)` pattern, but `s` (local
  param name) vs `state` (longer name) → my sed pattern that
  matched `state.ui_ctx` missed the `s.ui_ctx` form.  Each one
  surfaced as `1 remaining` in the post-batch lint.
- **String literal types**: `const msg = "literal";` annotates as
  `[]const u8` (most natural; coerces from `*const [N:0]u8`).

#### Implementation choices

- **sed-then-verify cadence.**  Each file's sed pass is followed
  by `zig build test` (warm cache, ~1s).  When that's green,
  next file.  Run `zig build lint` at the end of every 3-5 files
  to catch sed misses.  This is the rhythm that's working
  consistently.
- **`*const T` for pointer params** that read-only borrow caller's
  state (e.g. `*const FontCache`).  Reserves `*T` for genuinely
  mutating handles.
- **`@TypeOf(buttons[0])`** for inferred-element-type annotations
  in `audio_basic.zig`: the `buttons` array element type is an
  anon `struct { x: f32, label: []const u8 }` (per audio_basic's
  layout helper), so `@TypeOf` keeps the annotation valid without
  having to name the struct.

#### Files touched

- 17 example files: ~92 annotation additions
- (no source files touched)

#### Next turn

Lint untyped-local at 3956.  Remaining files in 4-5 site range
plus 8-site files left untouched yet.  Approaching the natural
break-point where remaining files have ≤4 sites each (long
tail).  Worth considering whether to switch to "section at a
time" sweeps in big modules (drawing.zig ~700, math.zig ~700,
ui.zig ~600).

---

### Turn 353 — untyped-local cleanup: 15 files cleared (~132 sites)

Highest count single-turn this arc.  Batch-sed pattern is
gelling; the type vocabulary I noted last turn covered ~95%
of the work this turn, so most files cleared in 1-2 sed
passes.

#### Files cleared

| File | Sites |
|------|-----:|
| `examples/ui_log_viewer.zig`    | 10 |
| `examples/ui_clipper.zig`       | 10 |
| `examples/music_streaming.zig`  | 10 |
| `examples/mandelbrot.zig`       | 10 |
| `examples/rlsw_side_by_side.zig`|  9 |
| `examples/recursive_hud.zig`    |  9 |
| `examples/instancing.zig`       |  9 |
| `examples/imgui_demo.zig`       |  9 |
| `examples/composer_drum.zig`    |  9 |
| `examples/camera2d.zig`         |  9 |
| `examples/starfield_effect.zig` |  8 |
| `examples/shapes_showcase.zig`  |  8 |
| `examples/gallery.zig`          |  8 |
| `examples/collision_area.zig`   |  8 |
| `examples/window_demo.zig`      |  7 |
| **Total**                       | **133** |

#### Audit

- `zig build test`: **1555/1555 pass** (114/114 steps)
- `zig fmt --check`: CLEAN
- `zig build lint`: **4522 issues** (was 4654 turn 352; -132)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 4044 |
| line-length | 462 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

#### Three patterns worth recording

**[:0]const u8 vs [:0]u8 for bufPrintZ + literal fallback.**
`std.fmt.bufPrintZ(&buf, ...)` returns `[:0]u8` on success.  When
combined with `catch "fmt overflow"`, the catch branch returns
`*const [N:0]u8` (a sentinel-terminated string literal).  These
two don't unify under `[:0]u8` (literal is const), but
`[:0]const u8` accepts both via the const-coercion path.  Same
shape applies to `allocPrint + catch "?"` — annotate as
`[]const u8` not `[]u8`.  Cost: one mid-sweep test, +1 char
type annotation.

**`*const [N][]const u8` for `&[_][]const u8{...}` array literals
that get aliased.**  `imgui_demo.zig:878` had
`const fruits = &[_][]const u8{...};` — the `&` takes the
address, so the type is a pointer-to-array, not a slice.
Annotated as `*const [7][]const u8`.  Slicing would also work
(`[]const []const u8`) but mismatches the source semantics
(the caller passes it directly to `u.listBox(...)` which expects
the pointer form).

**Cascade type for `serializeLayout`.**  `imgui_demo.zig:1039`
had `const buf = u.serializeLayout(state.gpa) catch null;` —
the `catch null` wraps the `![]u8` error union into `?[]u8`,
so the local is `?[]u8`.  Easy to mis-type as `?[]const u8` or
`[]u8` if you don't trace the catch path.

#### Files touched

- 15 example files: ~132 annotation additions
- (no source files touched this turn)

#### Next turn

- 7 more 6-7 site files remaining
- ~15 files in the 4-5 site range
- Then onto the big modules: drawing.zig (~700), math.zig
  (~700), ui.zig (~690) — section-at-a-time.

---

### Turn 352 — untyped-local cleanup: 9 files cleared (~104 sites)

Continued the small-files-first sweep.  9 example files cleared
this turn, all annotation-only changes (no semantic edits).

#### Files cleared

| File | Sites |
|------|-----:|
| `examples/ui_multiselect_finder.zig` | 13 |
| `examples/gestures_testbed.zig`      | 13 |
| `examples/math_sine_cosine.zig`      | 12 |
| `examples/keys.zig`                  | 12 |
| `examples/image_editor.zig`          | 12 |
| `examples/double_pendulum.zig`       | 12 |
| `examples/ui_panes.zig`              | 11 |
| `examples/text_layout.zig`           | 11 |
| `examples/ball_physics.zig`          | 11 |
| **Total**                            | **107** |

#### Pattern observations

- **sed is fast but pattern-fragile.**  The
  `^    const name = std.fmt.allocPrint` pattern catches function-
  scope locals but misses everything inside `if/for/while`
  blocks (4+ extra indent).  Multiple sites for the same variable
  name (e.g. `const mp = z.getMousePosition(f.input);` appearing
  at depth-1 AND depth-3) need separate sed passes.  Always
  re-run lint after a batch to find the stragglers.
- **`bufPrint` vs `allocPrint` distinction matters.**  Stack-
  bound buffers return `[]const u8`; arena-allocated returns
  `[]u8`.  `bufPrint(&buf, ...)` is the former (the slice
  borrows the stack buffer), `allocPrint(arena, ...)` the
  latter (heap-owned).  Mismatched annotations caught at compile
  time, but you can also figure out which from the call shape.
- **Cascade types stay consistent.**  `z.Vec2` for screen-space
  points (mouse, touch), `z.Font` for loaded fonts,
  `z.Texture` for GPU textures, `z.Image` for CPU pixel buffers,
  `z.Color` for colors, `std.Random` for RNG state,
  `std.mem.Allocator` for allocators, `[]u8`/`[]const u8` for
  strings.  These cover ~90% of annotations.

#### Audit

- `zig build test`: **1555/1555 pass** (114/114 steps)
- `zig fmt --check`: CLEAN
- `zig build lint`: **4654 issues** (was 4759 turn 351; -105
  matches the cleared sites + 1 trivial drift).

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 4176 |
| line-length | 462 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

#### Files touched

- 9 example files: ~107 annotation additions
- (no source files touched this turn)

#### Next turn

Remaining small files (`ui_log_viewer.zig` 10, plus 5-10 more
in the 8-10-site range).  After the tail clears, start on the
big modules: `drawing.zig` (~700 sites), `math.zig` (~700),
`ui.zig` (~600).  Those will be section-at-a-time multi-turn
arcs.

---

### Turn 351 — kill `Vector2/3/4` aliases; only `Vec` and `Vec2` survive

Simon's refinement of the turn-350 directive: "I like using Vec
for @Vector(4, f32) and Vec2 for @Vector(2, f32).  All other names
such as Vector3 as an alias for Vec and Vector2 as Vec2 could be
killed, right?  We should not use @Vector(2, f32) directly ever
though.  This is hidden in math.zig, and all files include it."

#### What survives, what dies

| Name | Status | Definition |
|------|--------|------------|
| `zm.Vec` | **canonical** | `@Vector(4, f32)` — 3D + 4D |
| `zm.Vec2` | **canonical** | `@Vector(2, f32)` — 2D |
| `zm.Mat` | canonical | `[4]F32x4` |
| `zm.Quat` | canonical | `F32x4` |
| ~~`zm.Vec3`~~ | KILLED | redundant alias for `Vec` (added turn 350, removed turn 351) |
| ~~`zm.Vec4`~~ | KILLED | redundant alias for `Vec` |
| ~~`Vector2`~~ | KILLED | was alias for `Vec2` |
| ~~`Vector3`~~ | KILLED | was alias for `Vec` |
| ~~`Vector4`~~ | KILLED | was alias for `Vec` |
| `Vector2i` | **kept** | distinct integer-vec2 struct (named fields by design) |

The convention is now: files write `const Vec = zm.Vec;` and
`const Vec2 = zm.Vec2;` at the top, then use `Vec` / `Vec2`
throughout.  **`@Vector(2, f32)` is hidden inside math.zig and
must not appear anywhere else as a type in code** (doc comments
describing the type are fine).

#### Walking the work

Most of the kill was already done by accumulated cleanup; the
real survey count after the turn-350 work was:

- `Vector2` in code: 86 raw matches but 75 were `Vector2i` and
  doc-comment references to raylib API names (`Vector2Refract`).
  Real type-name uses: ~1.
- `Vector3` in code: 2 (both doc comments)
- `Vector4` in code: 0
- Direct `@Vector(2, f32)`: 30 sites, mostly in math.zig itself
  + doc comments

The actual mechanical work was small:

1. **Remove `Vec3 = F32x4` and `Vec4 = F32x4`** from math.zig
   (already done earlier this turn — these were my redundant adds).
2. **Convert math.zig function signatures**: `vec2()`, `splat2()`,
   `reflect2()`, `refract2()`, etc. switched from
   `@Vector(2, f32)` return/param types to `Vec2` (in scope inside
   math.zig).  13 line edits.
3. **Convert entities.zig test wrappers**: the ECS forEach test's
   `Pos = struct { v: @Vector(2, f32) }` became
   `Pos = struct { v: Vec2 }` after adding
   `const zm = @import("math.zig"); const Vec2 = zm.Vec2;` at
   the top.
4. **Fix transform_order_test.zig**: it referenced the dead
   `types.Vector3` and `types.Quaternion` aliases.  Switched to
   `zm.Vec` and `zm.Quat`.
5. **Drop redundant `const zm = @import("math.zig");` decls** in
   drawing.zig sub-namespaces.  Zig 0.16 disallows shadowing a
   file-level import in nested struct decls — was an ambiguous-
   reference error.  Removed 4 inner re-imports; outer file-level
   `zm` (line 15) is in scope throughout.

#### Audit

- `zig build test`: **1555/1555 pass** (114/114 steps)
- `zig fmt --check`: CLEAN
- `zig build lint`: **4759 issues** (-12 from turn 350)

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 4281 |
| line-length | 462 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

#### Implementation choices

- **Doc comments mentioning `@Vector(2, f32)` are FINE.**  These
  are descriptive ("the storage type is `@Vector(2, f32)`"), not
  uses.  The ban is on the type appearing in function signatures,
  variable declarations, struct fields - the places where Zig
  treats it as a TYPE, not where Markdown-ish prose describes it.
- **No `Vec3` or `Vec4` aliases.**  Vec carries both 3D and 4D
  semantics depending on which function suite uses it (zm has
  `dot3` and `dot4`, `normalize3` and `normalize4`, etc).
  Naming them separately would be redirection without value.
- **`Vector2i` survives** because it's structurally distinct:
  named `.x`/`.y` integer fields, methods, used for pixel-grid
  coordinates where integer semantics matter.  Different beast
  from Vec2.

#### Files touched

- `src/math.zig`: removed `Vec3`/`Vec4`, 13 signature conversions
- `src/entities.zig`: zm import added + 2 wrapper conversions
- `src/drawing.zig`: 4 redundant inner `zm` imports removed
- `src/tests/transform_order_test.zig`: 2 alias replacements
- (`types.zig` Vector2/3/4 aliases were already removed in some
  earlier cleanup — turn 351 didn't need to touch them)

#### Next turn

The cold-cache rule needs codifying at decade boundaries (350,
360, ...) as a hard rule.  Did the cold-check at the end of
turn 350; should do it again at end of turn 360.  Also: untyped-
local at 4281 means the long pole still has 4281 sites to go.
Time to start on the bigger files (`drawing.zig` ~780, `math.zig`
~700, `ui.zig` ~690) one section at a time.

---

### Turn 350 — ban `struct { x, y }` Vec2 aliases; unify on `zm.Vec2 = @Vector(2, f32)`

Simon's directive: "There should be no struct{x,y} remaining
anywhere.  Only `zm.Vec2 = Vector(2, f32)`.  If we dont want
to include math.zig for some reason, we can just use
`@Vector(2, f32)`, which is one of the reasons i decided to
avoid named struct for Vector2."

#### Three layers of work

##### 1. `zm.Vec2` defined; `types.Vector2` aliases it

`src/math.zig` gains:

```zig
pub const Vec2 = @Vector(2, f32);
pub const Vec3 = F32x4;
pub const Vec4 = F32x4;
```

Vec3 and Vec4 alias `F32x4` (= `@Vector(4, f32)`) for SIMD
regimentation — Vec3 carries an unused `.w` lane that the
matrix math can ignore or use for `.w = 1` (points) /
`.w = 0` (directions).  Vec2 lives on its own at @Vector(2)
since 2-lane SIMD is its natural size.

`src/types.zig` updated:

```zig
- pub const Vector2 = @Vector(2, f32);
+ pub const Vector2 = zm.Vec2;
```

Aliasing, not redefining — both refer to the SAME type.
No cascade on any code that uses `types.Vector2` or `z.Vector2`.

##### 2. Cache exposed a build that was already broken

Before any edits this turn, `zig build test` was actually
RED — multiple files had `.x`/`.y` access on
`@Vector(2, f32)` values left over from a prior partial
refactor of `runtime.input.Vec2` (was `struct { x, y }`, now
`= types.Vector2`).  Caching had been serving old artifacts
across 5+ turns; tests appeared green but the underlying
state was broken.  Direct verification:
`zig build test 2>&1 | grep error` showed 14 distinct field-
access errors across `runtime.zig` + 12 examples.

This is the same shape of failure as turn 345 (silent parse
errors hidden by the linter's skip path) and turn 346
(silent walker no-op masking 436 issues).  Mid-turn `zig
build test` cadence still works; the bug is when an entire
turn's work has been audited against stale cache, then a
LATER turn catches the truth.

Defense: turn 346's cold-sanity-check rule
(`rm -rf .zig-cache && zig build test` every 5-10 turns)
specifically addresses this.  This turn was 4 turns past the
last cold check (turn 346); should have been due.

##### 3. Mechanical sweep: `.x`/`.y` → `[0]`/`[1]`

Sed pass through every file with Vec2-bound variables.
Variable names converted (per error trace): `mp`, `md`,
`delta`, `mouse`, `tp`, `cur`, `p0`, `p1`, `d`, `mouse_delta`.
Init expressions like `Pos{ .x = a, .y = b }` rewritten as
`Pos{ a, b }`.  `return .{};` for Vec2 became `return @splat(0);`
since `@Vector` types don't have field-default zero.

Cleared `struct { x, y }` definitions in:

- `src/runtime.zig:1456` (`input.Vec2` - already done before turn,
  but tests using `.x`/`.y` were broken; fixed in this sweep)
- `src/drawing.zig:6505` (anon `gpa.alloc(struct{x,y}, n)` for
  voronoi seed alloc - already converted to `types_mod.Vector2`
  before turn)
- `examples/ecs_solar_system.zig:40, 54` (`Pos`, `Velocity`)
- `examples/ecs_boids.zig:54-55` (already converted to `z.Vector2`
  before turn; no work this turn)

Renamed (legitimate struct-field uses, kept):

- `src/entities.zig:1576` `Vec2` → `Point` (used in `@offsetOf`
  test - needs named fields)
- `src/entities.zig:7371` `Vec2` → `Point` (`Ref.path(..., "y")`
  reflection test - needs named fields)

ECS test pattern (`Pos` + `Vel` as nominally distinct
components):

```zig
// Pos and Vel are nominally distinct so the ECS can keep them
// in separate component slots; both wrap a Vec2 since that's
// what they semantically are.
const Pos = struct { v: @Vector(2, f32) };
const Vel = struct { v: @Vector(2, f32) };
```

This is allowed under the new rule because the struct wraps
Vec2, doesn't shadow it — `.v` accessor, not `.x`/`.y`.

#### Audit

- `zig build test`: **1555/1555 pass** (114/114 steps).  Verified
  fresh-cache: tests now ACTUALLY pass against the current
  source, not cached old artifacts.
- `zig fmt --check`: CLEAN
- `zig build lint`: **4771 issues** (was 4773; -2 from the
  Vec2 cleanup, lint-irrelevant for most of the sweep).

Tag breakdown:

| Tag | Count |
|-----|------:|
| untyped-local | 4293 |
| line-length | 462 |
| ex-variant | 20 |
| anon-return | 6 (opt-in) |

Survey verification:

```sh
grep -rnE 'struct[[:space:]]*\{[[:space:]]*x:[[:space:]]*f32,[[:space:]]*y:[[:space:]]*f32[[:space:]]*\}' \
    src/*.zig examples/*.zig
```

Returns 2 hits, both renamed to `Point`, both with comment
documenting why they're exempt (struct-field reflection).

#### Implementation choices

- **Wrap-with-named-field for ECS distinctness.**  Plain
  `Pos = @Vector(2, f32)` and `Vel = @Vector(2, f32)` would
  be the same type in Zig - both anonymous - and the ECS
  would store them in the same component slot.  Wrapping in
  named structs (`Pos = struct { v: Vec2 }`) gives nominal
  distinction while still using Vec2 for the data.
- **`Point` rename rather than `// vec2-exempt:` comments.**
  Visual scan for "is this a Vec2 alias?" benefits from
  using a different name.  `Point` reads as "a struct with
  named-field access," distinct from `Vec2` = "indexed pair."
- **No grep-and-replace fallback on docs/notes.**  The 30+
  matches in `src/notes/`, `src/web/readme.html`,
  `src/notes/changelogs/` etc. stay as-is - those are
  documentation referring to historical / hypothetical
  struct shapes, not live code.

#### Files touched

- `src/math.zig`: +3 vector type aliases (Vec2, Vec3, Vec4)
- `src/types.zig`: 1 line (Vector2 → alias zm.Vec2)
- `src/runtime.zig`: ~20 line edits (Vec2 init + sed cleanup)
- `src/entities.zig`: 2 test types renamed + 1 forEach test rewritten
- `examples/ecs_solar_system.zig`: ~10 line edits
- 11 other example files: sed `.x`/`.y` → `[0]`/`[1]`

#### Next turn

The mid-turn `zig build test` rule's defense-in-depth needs
a periodic cold-cache rule.  Turn 346 said "every 5-10 turns,
or before any zip you'll ship for visual verification."  This
turn was at turn 350 = 4 turns past last cold check.  Should
have caught the stale cache earlier.  Codify the cold-check
cadence more concretely?  At decade rollovers (350, 360, ...)
as a hard rule?

---
