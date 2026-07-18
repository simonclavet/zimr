# zmath adoption plan — `src/math.zig`

Replaces `src/notes/zmath-adoption-idea.md` (the earlier rough capture).
This is the committed plan, post the decision pass with Simon.

## Goal

Replace the hand-ported `src/zimrmath.zig` (a raymath.h port) with a
hard fork of zig-gamedev's **zmath** as `src/math.zig`.  The guiding
principle: **Zig people who know zmath should feel at home.**  raylib
people will need to adapt — that tradeoff is accepted and deliberate.


## Locked decisions

1. **Convention: keep zmath's row-major / row-vector convention
   unchanged.**  `mul(v, m)` treats `v` as a row; `mul(A, B)` composes
   "apply A then B" (reads left-to-right).  The fork is *unmodified
   zmath at the convention level*.  Cost lands on zimr's ~36 internal
   matrix call sites (just migrated in Phase B, so fresh) — they get
   re-adapted to row order.  Note this is the *opposite* of the
   column-vector convention Phase B settled `zimrmath` on; that's
   fine, `zimrmath` is being retired.

2. **Storage vs compute split — NARROWED then CORRECTED (turns 232-233),
   then SUPERSEDED by the "zmath all the way down" direction (turn 243).**

   **★ CURRENT RULE (turn 243, made concrete turn 247).** The owner's
   stated end-state: the system uses **zmath everywhere** —
   `@Vector(4,f32)` wherever a vector/quaternion is a *value to
   compute on* — and **raw fixed-size arrays (`[N]f32`) only where
   saving space measurably matters** (packed vertex/transfer
   buffers).  No bespoke `extern struct` math types survive; named-
   member access (`.x/.y/.z`) is gone, it is `v[0]/v[1]/v[2]`.

   | type        | end-state type      | rationale |
   |-------------|---------------------|-----------|
   | `Matrix`    | `zmath.Mat`         | DONE (Z3 step 0). |
   | `Vector3`   | **`zmath.Vec` (`@Vector(4,f32)`)** | not a struct, not a struct alias — `pub const Vector3 = Vec`.  Same type as `Vector4`/`Quaternion`/`Vec`; the "3-ness" is which function you call (`dot3` vs `dot4`), zmath's model.  Lane 3 = 0 for a direction, 1 for a point.  Verified: nothing depends on it being 12 bytes. |
   | `Vector2`   | **`@Vector(2, f32)`** | UI / 2D — 8 bytes, not 16; matters across the many widget rects, text-layout positions, gesture state, etc.  `@Vector(2)` has the same operators (`+`/`-`/`*`/`@splat`) and indexing (`[0]/[1]`) as the 4-wide.  The prior "no `@Vector(2)`" rule (turns 232-243) was about *3D math*, where one compute width avoids per-op width questions; UI math does not chain into 3D math, so the rule does not apply. |
   | `Vector4`   | **`zmath.Vec`**     | size-identical, same type. |
   | `Quaternion`| **`zmath.Quat`** (= `Vec`) | a quaternion *is* 4 floats; storage = compute, zero conversion. |
   | `[3]f32` / `[2]f32` | packed storage only | appears **only where space measurably matters** — vertex/transfer buffers — and those are already raw flat `[N*3]f32`, not `[]Vector3`. |

   **Consequences:**
   - **The conversion layer mostly disappears.**  Once `Vector3`/
     `Vector2`/`Vector4`/`Quaternion` *are* `Vec`, `toZm`/`fromZm`
     are identities and delete.  What remains is the genuine
     packed-buffer boundary: small `loadArr3`/`storeArr3` (and
     `*Arr2`) helpers in `math.zig` — load/stores, naturally
     math-library territory.
   - **The bespoke struct method suites die.**  `Vector3.add`/`.dot`/
     `.cross`/`.normalize`/… cannot exist on a `@Vector` and are not
     re-created.  Compute is native operators (`a + b`, `a * @as(Vec,
     @splat(s))`) and `zmath.*` functions (`dot3`, `cross3`,
     `normalize3`, `rotate`, `qmul`, …).
   - **No operator-wrapper functions.**  `v3Add`/`v3Sub`/`v3Scale`
     and the like are NOT introduced — a wrapper around `+` earns
     nothing.  If a storage-to-storage op on a *packed* `[3]f32`
     buffer ever proves a *measured* perf problem, the fix is a
     dedicated `arrayAdd`/`arrayDot`/… in `math.zig`, added **then**,
     **proven by a benchmark** — not speculatively.
   - `math.zig` carries small *ergonomic constructors* — `vec3(x,y,z)`
     (lane 3 = 0), `point3(x,y,z)` (lane 3 = 1), `vec2(x,y)` — so the
     ~560 call sites that build vectors read cleanly instead of
     drowning in `@Vector` syntax.  These are constructors, not
     operation-wrappers; they earn their place.
   - Named-field access (`v.x`) is gone — the owner has explicitly
     accepted this ("named-field access is overrated", turns 239 +
     243 + 247) and asked to "get rid of named members `Vector3` as
     soon as possible".  The decision-2 clause-2 ("no semantically-
     named fields") is therefore moot.
   - The clause-1 16-vs-12-byte hazard is moot too: `Vector3` is no
     longer a *storage array type* you'd build a `[]Vector3` from —
     packed buffers are raw `[N*3]f32`, and a `[]Vec` slice has
     uniform 16-byte stride (correct, just larger).
   - 2D-specific operations (`vector2Rotate`, `vector2LineAngle`, …)
     port into a small `math.zig` 2D section operating on the 4-wide
     type (lanes 0,1); there is still **no `@Vector(2)`**.

   **Migration order — REVISED (turn 247): type-by-type vertical, NOT
   compute-first/storage-second.**  The turn-243 "compute surface
   first, against the current storage types" ordering was wrong: it
   forces conversion scaffolding (`v3ToZm`/`v3FromZm`/`v3Add` bridge
   helpers) that exists *only because the type is temporarily the
   wrong shape* — an incoherent intermediate state.  The camera made
   it obvious: `Camera3D.position` is internal compute state, there
   is no reason it is a named-field struct, and "convert at every
   call site" is pure waste.  Instead: go **one type at a time** —
   flip the type definition AND fix every call site (compute and
   storage both) in one coherent wave, gates green at the end.  No
   scaffolding, because once the type *is* `Vec`, compute sites use
   native operators directly and storage sites just hold the value.
   See the Z4 section for the wave order (smallest blast radius
   first: `Camera3D`, then scene/physics, then drawing, then the
   remaining storage sites).

   *— historical: the three-clause rule (turns 232-233) and the
   turn-243 Z4a/Z4b compute-first split both follow as marked
   history.  The three-clause rule correctly drove the `Matrix`
   collapse; the turn-243 split correctly identified the end-state
   types but got the *ordering* wrong (turn 247 corrects it).  The
   turns 243-246 work done under "Z4a" is not wasted — the bridge
   helpers it built are exactly the conversion the type-flip waves
   delete, and those call sites are already off `zimrmath`'s
   raylib-named API. —*

   The original rule applied one uniform split to all of
   `Vector2/3/4`, `Quaternion`, `Matrix`.  Turn 232 narrowed it using
   size/alignment/FFI evidence; turn 233, *starting* the collapse,
   found that the turn-232 criterion ("size-identical to a zmath
   type → collapse it") was **incomplete** — size-compatibility means
   a collapse is *possible*, not that it is *good*.  The corrected
   rule has three clauses, ALL of which must hold to collapse a type
   into its zmath counterpart:

   **A type collapses into the zmath type only if:**
   1. it is layout-compatible with `@Vector(4,f32)` / `[4]@Vector]`
      (size and the alignment can only rise, never a tighter
      requirement), **and**
   2. it has **no semantically-named fields** — its components are
      bare indices, not meaningful names, **and**
   3. it **never crosses a hard ABI boundary as a struct** (FFI,
      vertex buffer, serialization record) — only ever flattened to
      a float array at the boundary, if at all.

   **Applying all three:**

   | type | layout-compat? | semantic fields? | crosses ABI as struct? | verdict |
   |---|---|---|---|---|
   | `Vector2`    | no (8≠16)  | yes (`.x .y`)      | yes (vertex/FFI) | **stays a storage struct** |
   | `Vector3`    | no (12≠16) | yes (`.x .y .z`)   | yes (vertex/FFI) | **stays a storage struct** |
   | `Vector4`    | yes        | **yes (`.x .y .z .w`)** | as a *value* in serialization structs (glTF) | **stays a storage struct** |
   | `Quaternion` | yes (= `Vector4`) | **yes (`.w` is the scalar part)** | yes (physics `RigidBody.orientation`, glTF `rotation`) | **stays (it is the `Vector4` alias)** |
   | `Matrix`     | yes        | **no** (`.m5` is bare index `[1][1]`) | **no** (always flattened via `matToArr`/`matrixToFloatV`) | **becomes `zmath.Mat`** |

   **Why the turn-232 reasoning was wrong about `Vector4`/`Quaternion`.**
   The turn-232 investigation measured sizes and FFI *struct*
   crossings and concluded "size-16 → collapse."  But it never
   checked *semantic* usage.  `Vector4` turns out to be used
   pervasively as a named-field record: `codecs.zig` parses glTF
   `rotation` / `base_color_factor` field-by-field from JSON
   (`.x = jsonToFloat(items[0])`); `physics.zig` stores
   `orientation: Quaternion = .{ .x=0, .y=0, .z=0, .w=1 }` as
   `RigidBody` state.  A quaternion's `.w` is the scalar part — `[3]`
   is strictly worse.  And `Vector4` never crosses a hard ABI
   boundary at all (the extern/GPU/FFI grep came back empty) — so the
   *interop* argument that was supposed to justify collapsing it does
   not even apply.  `Vector4`/`Quaternion` are **storage/semantic
   structs that happen to be size-16**, the opposite of `Matrix`.

   **`Matrix` is still the one true collapse.** It is the only type
   that passes all three clauses: layout-compatible, no semantic
   field names (`.m5` is a pure index), and never an FFI struct
   (every matrix→GPU path already flattens through `matrixToFloatV` /
   `matToArr`).  Z3 step 0 collapses `Matrix` → `zmath.Mat` and
   *only* `Matrix`.

   **The conversion-cost reframe (turn 232) still holds** and is the
   reason the *remaining* split is acceptable: for storage vectors,
   `toZm(v)` = `f32x4(v.x, v.y, v.z, 0)` is a *load*, not a memory
   reformat — the split relabels where the load happens, it does not
   add work.  The genuinely-costly conversions were the 64-byte
   `Matrix` round-trips, and collapsing `Matrix` deletes exactly
   those.

   **The compute type is still always `@Vector(4,f32)`** — 2D values
   load into lanes 0,1.  Do NOT introduce a `@Vector(2,f32)`.

   See `src/notes/zmath-storage-types-review.md` for the full
   investigation log (turn 232) and the turn-233 correction.

   **Recorded consideration (turn 239) — "named-field access is
   overrated."**  A reasonable counter-position: clause 2 ("no
   semantically-named fields") weights ergonomics that are partly
   just familiarity — `v[0]` is only worse than `v.x` if you have
   decided indexing is unclear, which for vector math is arguable.
   This is noted as a real input, but it does **not** overturn the
   decision 2 verdicts, for one structural reason: **clause 1
   (layout) is independent of the names question.**  Even granting
   that names are overrated, `@Vector(4,f32)` storage is still
   16 bytes and still corrupts the stride of any `[]Vector3` /
   packed vertex struct — that hazard does not care whether the
   components are named.  What the "names overrated" view *does*
   legitimately shift: it strengthens the case for `[3]f32` (or
   `[2]`/`[4]`) as the storage representation — layout-safe, just
   indexed — over the current `extern struct`.  That is a viable
   future change (an `extern struct {x,y,z}` and `[3]f32` are
   bit-identical, so it is a mechanical swap of access syntax, not
   an ABI change).  It is *not* a license to make `@Vector(4)` a
   storage type.  If this is picked up, it is its own change with
   its own gate run; decision 2's "storage struct vs `@Vector(4)`
   compute" split stands until then.

   *Original decision 2 text (now historical):*  `extern struct {
   x, y, z }` stays as the storage / interop / vertex-buffer /
   uniform type for all vector and matrix types; zmath's `Vec` is
   the compute type; convert at the boundary.

3. **Location & structure: `src/math.zig`, single file, hard fork.**
   No upstream-merge story — zmath is the *starting point*, not a
   tracked dependency.  `math.zig` is edited freely like any other
   zimr source file.  Gap-fills go straight in, in zmath's own section
   style.  Dead weight (FFT, color, F32x8/F32x16 paths) can be trimmed
   later since there's no upstream fidelity to preserve.

4. **Call surface: dual.**  `math.zig` is usable directly as `zm`
   (`const zm = @import("math.zig")` — zmath-native, `zm.mul`,
   `zm.cross3`, etc.), AND the autogen `z.*` flat exports
   (`gen_flat_exports.py`) pick it up so zimr/raylib-flavored users
   get `z.mul`, `z.cross3`, `z.matFromQuat` on the existing flat
   namespace.  No nested `z.math.mul` — functions flatten directly
   into `z.*`.

5. **`z.*` collision rule: `math.zig` names win.**  Where `math.zig`
   and (during the parallel phase) `zimrmath.zig` would both export a
   flat name, `math.zig` wins.  zimrmath's colliding flat exports get
   renamed or dropped as each function is brought over.  zimrmath
   keeps its *own distinct* names (`matrixMul`, `vector3Normalize`,
   `vector3Transform`, …) during the parallel phase; those retire when
   the file is deleted.  Genuine name overlaps (`identity`, `lerp`,
   `inverse`, `normalize3`) differ enough in signature (`@Vector` vs
   `Vector3`, row vs column) that mis-wired call sites *type-error*
   rather than silently miscompiling — the good failure mode.

   **Resolved (turn 240) — the `matrixMul` vs `mul` question.**  The
   public surface re-exported *both* `z.matrixMul` (from
   `zimrmath.zig`'s shim, raylib operand order) *and* `z.mul` (from
   `math.zig`, zmath row-vector order) — not a collision, since the
   names differ, so the autogen emitted both.  The question was which
   to keep.  Resolution: **do what zmath is doing.**  The public
   surface exposes the zmath names and conventions — `z.mul`,
   `z.identity`, `z.inverse`, `z.translation`, `z.rotationX/Y/Z`,
   `z.lookAtRh`, `z.perspectiveFovRhGl`, `z.matFromAxisAngle`,
   `z.matFromQuat`, … — not raylib-flavoured aliases.  The
   `zimrmath.zig` matrix shims were scaffolding; they come down rather
   than getting a permanent facade.  The examples migrated to the
   zmath names (turn 240), applying the operand reversal where
   `matrixMul(A,B)` → `mul(B,A)`.  The one *exception* is genuine
   storage↔compute **bridges**: `quaternionFromMatrix` takes a
   `Matrix` and returns a `Quaternion` *storage struct* (not zmath's
   compute `Quat`), so it is not a raylib-flavoured duplicate of
   anything in `math.zig` — it stays until the `Quaternion` storage
   type itself is reconsidered.  "Do what zmath is doing" means drop
   the *duplicates*, not the *bridges*.

6. **End-state: `zimrmath.zig` is deleted.**  Parallel coexistence is
   *temporary scaffolding with a teardown date*, not a permanent
   state.  "Is zimrmath gone yet" is a concrete progress metric.

   **Storage-type end-state — REVISED (turns 232-233, see decision 2).**
   Of the five `extern struct` types, **only `Matrix` collapses**:
   - `Vector2`, `Vector3`, `Vector4`, `Quaternion` — all survive as
     `extern struct`s and relocate to `types.zig`.  `Vector2`/
     `Vector3` because their layout is interop-forced and differs
     from `@Vector`; `Vector4`/`Quaternion` because they are
     semantically named-field records (glTF `rotation`, physics
     `RigidBody.orientation`, a quaternion's scalar `.w`) that never
     cross a hard ABI boundary as structs — size-16 makes a collapse
     *possible* but the three-clause rule in decision 2 says don't.
     (`Quaternion` stays the `Vector4` alias.)
   - `Matrix` — does **not** survive as a distinct type.  It *becomes*
     `zmath.Mat`.  It is the only type passing all three collapse
     clauses (layout-compatible, no semantic field names, never an
     FFI struct).  The genuine boundary (`Mat` → `[16]f32` for a
     shader / `rlMultMatrixf`) is the `matToArr` call that always
     existed.  A `types.zig` alias `pub const Matrix = zmath.Mat;`
     is kept for call-site readability.
   - The Z1 conversion layer shrinks: the `matrix*Zm` pair is deleted
     (a `Mat`↔`Mat` identity once `Matrix` *is* `Mat`); the
     `vector2/3/4` and quaternion conversions survive and relocate to
     `types.zig` — they are genuinely permanent (storage vectors must
     convert to the `@Vector` compute type).

7. **One name per concept — ship the best one, not both.**  The end
   state has a *single* canonical spelling for every operation.  When
   zmath and raylib-flavored zimrmath both have a concept, the
   **zmath name is canonical** — it's terser, SIMD-native, and
   handedness-explicit (`perspectiveFovRh` vs `perspectiveFovLh`),
   and the file *is* zmath.  We do **not** ship `vector3DotProduct`
   as an alias for `dot3`; the raylib name simply goes away.  This is
   not hostile to raylib users — they are made happy a *different*
   way (see below), and a consistent single API is friendlier than a
   two-headed one where every call site picks a dialect.

   How each audience is kept happy:
   - **zmath users**: the compute surface IS zmath — `mul`, `dot3`,
     `cross3`, `normalize3`, `matFromQuat`, the `*Rh`/`*Lh` builders.
     Nothing to relearn.
   - **raylib users**: (a) zimr's storage types stay raylib-shaped —
     `Vector3{ .x, .y, .z }`, `Matrix`, `Quaternion` extern structs
     remain the interop/vertex/uniform surface; (b) the
     gap-fill functions (Vector2, the ops zmath lacks) are ported in
     *zmath's* style so the whole library is one consistent dialect,
     not a patchwork; (c) `migrating-from-raylib.md` carries the
     name-mapping table.  A raylib user porting code already expects
     to change function calls — what they want is that the concepts
     map cleanly and the target API is coherent.  They get that.

   Consequence for Z2: the gap list shrinks.  We port only the ~88
   *true-gap* functions (capability zmath genuinely lacks).  We do
   **not** port the ~80 raylib-named duplicates of things zmath
   already does — those concepts already exist under the zmath name.

   **Carve-out — distinct operations all ship; only redundant
   *spellings* are eliminated.**  Decision 7 kills two *names for the
   same operation*, not two *operations*.  Where two functions
   genuinely compute different things, both ship — the test is "does
   it produce a different result", not "does it look similar".  The
   canonical example is **Euler angle order**: the rotation order
   *is* the operation (`XYZ` and `ZXY` produce different rotations,
   the way `dot` and `cross` do).  raylib's `quaternionFromEuler` is
   empirically **XYZ** order; zmath's `quatFromRollPitchYaw` is
   **ZXY**.  Both have real callers who expect that behaviour, so
   both ship — but with *honest, explicit* names that fix the real
   sin of both libraries (opaque order):
     - `quatFromEulerXYZ` / `quatToEulerXYZ`  (the raylib order)
     - `quatFromEulerZXY` / `quatToEulerZXY`  (the zmath order)
   zmath's `quatFromRollPitchYaw` / `quatToRollPitchYaw` stay as
   thin, clearly-documented aliases for the ZXY pair (zmath muscle
   memory preserved).  Still one name per *(operation, order)* — no
   `quaternionFromEuler`-vs-`quatFromEulerXYZ` both meaning XYZ.  We
   ship exactly the two orders with real demand; we do NOT
   speculatively add the other four.


## Phase C is absorbed

If `math.zig`'s `Mat = [4]@Vector(4,f32)` becomes zimr's internal
matrix compute type, the Phase C question (reorder `Matrix`'s
`m0..m15` fields to sequential memory) is **moot** — `Mat` is already
SIMD-laid-out.  `zimr.Matrix` (the `extern struct`) survives only as
the storage/interop type.  Phase C comes off the queue.


## The gap: what zimrmath has that zmath lacks

zmath must be *extended* to be a strict superset before zimr code can
move.  Inventory from `zimrmath.zig` (156 pub fns):

### Big structural gap
- **No `Vector2` / 2D vector functions at all.**  zimrmath has ~30
  `vector2*` functions (`vector2Rotate`, `vector2LineAngle`,
  `vector2MoveTowards`, `vector2Refract`, `vector2RandomInUnitDisk`,
  …).  zmath is 3D/4D-only.  2D support is a from-scratch addition.

### Vector functions (zmath ~25, zimr ~95)
zmath covers dot/cross/length/normalize/swizzle.  zimr adds, per
vector width: `*Distance`, `*DistanceSqr`, `*MoveTowards`, `*Lerp`,
`*Clamp`, `*ClampValue`, `*Min`/`*Max`, `*Reflect`, `*Refract`,
`*Invert`, `*Negate`, `*Angle`, `*Project`, `*Reject`,
`*Perpendicular`, `*OrthoNormalize`, `*Barycenter`, `*CubicHermite`,
`*RotateByAxisAngle`, `*RotateByQuaternion`, `*RandomInUnitSphere`,
`*RandomUnitVector`, `*Unproject`, `*Transform`, `*ToFloatV`, plus
`*One`/`*Zero` constructors and the `*AddValue`/`*SubtractValue`
scalar-broadcast forms.

### Quaternion functions (zmath ~14, zimr ~24)
zmath has the core.  zimr adds `quaternionFromVector3ToVector3`,
`quaternionCubicHermiteSpline`, `quaternionNlerp`, `quaternionLerp`
(non-slerp), `quaternionTransform`, `quaternionFromEuler` /
`quaternionToEuler` (raylib's specific euler order — verify vs
zmath's `quatFromRollPitchYaw`), and the
`*Add`/`*Subtract`/`*Scale`/`*Divide`/`*AddValue` arithmetic forms.

### Matrix functions (mostly covered)
zmath has identity/mul/transpose/inverse/determinant/rotation/
translation/scaling/perspective/ortho/lookAt.  zimr adds
`matrixAdd`/`matrixSubtract`, `matrixCompose`/`matrixDecompose`,
`matrixTrace`, `matrixFrustum`.  Several are near-aliases of zmath
names with raylib conventions — reconcile case-by-case.

### Scalar utilities (zmath has few, zimr has a pile)
`clamp`, `lerp`, `normalize` (scalar remap-to-01), `remap`, `wrap`,
`fract`, `saturate`, `floatEquals`, `floatToHalf` / `halfToFloat`,
`rcp`, `luminance` / `luminance8`.

### Color / bit-packing helpers
`expand1to8`..`expand6to8`, `compress8to1`..`compress8to6`,
`color8ToColor` / `colorToColor8`, the `float3` / `float16` structs.
zmath has its own color block (`rgbToHsl` etc.) — decide whether
zimr's packing helpers belong in `math.zig` or move to a `color.zig`.


## Phased rollout

Each phase keeps the Phase-B discipline: green gates every turn
(`install --release=small`, `test`, `smoke-test`, `fmt`,
`count_globals`), per-turn snapshot zip, changelog entry.

**Z0 — fork in place.  ✅ DONE (turn 222).**  Vendored zig-gamedev
zmath `0.11.0-dev` (`src/root.zig`, 4720 lines) verbatim as
`src/math.zig` with a provenance header; MIT LICENSE saved at
`src/notes/zmath-LICENSE.txt`.  Wired a standalone `math-test` build
step.  Four in-source `// [zimr Z0]` edits, two categories:
*drift (3)* — (1) `@import("zmath_options")` → local `const` (we
don't use zmath's build.zig); (2)+(3) two FFT shift-amount casts
where Zig 0.16 infers the `32` literal as `u5` and rejects it.
*self-hosted-backend workaround (1)* — zmath's `round`/`ceil`/
`floor`/`trunc` carry x86 inline asm that trips a register-allocator
assertion in Zig 0.16's self-hosted x86_64 backend; since zimr ships
wasm (where that asm is already comptime-dead), the four asm
branches are gated behind `false` (kept for auditability).  No
`use_llvm` override, no toolchain split.  Gate met: **zmath's own 78
tests pass** on the stock backend.  `math.zig` is NOT yet in zimr's
module graph — it's a parallel library until Z3.

**Z1 — conversion layer.  ✅ DONE (turn 223).**  Added `toZm` /
`fromZm` to `zimrmath.zig` for `Vector2/3/4 ↔ zm.Vec`, `Quaternion ↔
zm.Quat`, `Matrix ↔ zm.Mat`.  IMPORTANT CORRECTION to this plan's
earlier assumption: the matrix conversions do **NOT** transpose.
zimr `Matrix` (column-major memory) and zmath `Mat` (row-major
memory) are memory transposes, but both use the same row-major
field/row *naming* (`m{r*4+c}` ≡ `Mat[r][c]`), so a direct
field-NAME copy is correct — the memory flip happens for free, and
transposing the names double-applies it.  (The first implementation
DID transpose; `zm_conversion_test.zig`'s cross-convention transform
tests caught it.)  The operator-level difference (`M*v` vs `v*M`) is
handled by call sites, not the conversion layer.  New
`src/tests/zm_conversion_test.zig` (9 tests) — round-trips +
semantic cross-convention transform checks.  Both libraries now
coexist and values cross freely.

**Z2 — close the *true* gap in `math.zig`.  ✅ DONE (turns 225-229).**
Ported the genuine capability gaps in zmath-style, with zmath-style
tests, across five steps: scalar utils (225), Vector2 — 13 fns
(226), vector3/4 — 19 fns (227), matrix/quat/euler — 11 fns (228),
and a dedup pass (229) that deleted `zimrmath.zig`'s dead/duplicate
color + bit-packing + f16 code rather than relocating it (the
canonical versions already lived in `rlsw_pixel.zig` and, for f16,
`math.zig`).  `math.zig` is now a strict superset of zimr's math
needs; `gen_flat_exports.py` sources it (119 flat `z.*` names).
Decision 7 shrank the work throughout — only true-capability gaps
were ported, never raylib-named duplicates of existing zmath ops.
Original Z2 text (now historical) follows:

**Z2 — close the *true* gap in `math.zig`.**  Port only the ~88
functions that are genuine capability holes (see `zmath-z2-gap.md`
for the categorized list).  Do NOT port raylib-named duplicates of
things zmath already does — per decision 7, those concepts ship
under their zmath name only.  Everything lands in `math.zig` in
zmath's section style, each with zmath-style tests, so `math-test`'s
count grows as the gap closes.  Execution order: scalar utils →
Vector2 → small absent vector3/4 ops → matrix/quat absent ops → RNG
ops.  Three open questions from the gap doc are now **resolved**:

  - *RNG ops* (`vector*Random*`): `math.zig` functions take a
    `*std.Random` parameter.  This keeps the fork pure and
    global-state-free (matches zmath's whole design), and it's the
    one option that actually works without a hidden global.  zmath
    has no RNG convention to honor, so we pick the best one.

  - *Color / bit-packing* (`color8ToColor`, `compress8toN`,
    `expandNto8`, `colorToColor8`): these are **not math** — they
    move to a new `src/color.zig`, not into `math.zig`.  `math.zig`
    stays a math library.  This relocation happens in Z2 (they have
    live call sites; moving them is part of clearing zimrmath).

  - *Euler order* (`quaternionFromEuler` / `quaternionToEuler`):
    ship **one** — zmath's `quatFromRollPitchYaw` (and a new
    `quatToRollPitchYaw` if zmath lacks the inverse).  Verify
    raylib's order against zmath's at port time; if they differ, the
    raylib order does NOT get its own function — the porting guide
    documents the difference and call sites adapt.  One euler
    convention in the codebase, full stop.

**Z3 — move call sites onto `math.zig`, leaf-first.**  Migrate
*directly to zmath's API* — `dot3`, `mul`, `matFromQuat`, etc. — not
to renamed wrappers.  `zimrmath.zig`'s functions are not turned into
"thin wrappers"; they are deleted as the last caller leaves.  Order
by how cheap the type mismatch is:
  1. `zimrmath.zig`'s own internal helpers — wherever zimrmath still
     has callers, its internals migrate first so the file shrinks
     from the inside.
  2. Internal renderer compute (`render.zig`, `drawing.zig`,
     `scene.zig`, `rlsw.zig` / `rlgl.zig` MVP builds) — file by file,
     same cadence as Phase B's B4.
  3. **`Vector2`/`Vector3`** stay storage structs — convert at the
     compute boundary (that conversion is a load, not overhead — see
     decision 2).  They never migrate, only relocate to `types.zig`.

  **Z3 step 0 — the `Matrix` collapse (turns 232-233 amendment, do FIRST).  ✅ DONE (turns 233-235).**
  `Matrix` is now `zmath.Mat` everywhere; all gates green at turn 235.
  Original step-0 description follows:

  **Z3 step 0 — the `Matrix` collapse (turns 232-233 amendment, do FIRST).**
  Before continuing the leaf-by-leaf call-site migration, collapse
  `Matrix` → `zmath.Mat` (decision 2 — and *only* `Matrix`;
  `Vector4`/`Quaternion` were considered and rejected, they stay
  storage structs).  This is a wide but mechanical change (every
  `Matrix` field/param/local changes type, every `.mN` access becomes
  `m[N/4][N%4]` — ~435 genuine external sites, the other ~894 are
  inside `zimrmath.zig` and vanish with it) and it must land as one
  coherent step, not dribbled across leaves — a half-collapsed type
  is worse than either end state.  Done first, it makes every
  *remaining* leaf dramatically cheaper: matrix-stack code stops
  needing conversions entirely.  Approach: introduce the `types.zig`
  alias (`pub const Matrix = zmath.Mat;`), then fix the fallout the
  compiler points at — storage-struct *methods* (`Matrix.identity` /
  `translation` / `scaling`, 3 methods, 14 call sites all in
  `rlsw.zig`) become the zmath builders, `extern struct` literals
  (`.{ .m0 = …}`) become `Mat` literals, the `boneMatrices`
  alloc/ptrcast stays valid (same type both sides).  zimr has zero
  runtime-indexed matrix loops (verified turn 232) so no `inline for`
  restructuring is needed.  The `rlsw.zig` conversions added in
  turn 231 mostly *delete* here — the operand-order reversal stays
  (a real convention fact), the `matrixToZm`/`matrixFromZm` wrapping
  goes.  Re-verify with the same empirical-equivalence discipline.

**Z4 — retire `zimrmath.zig`.**  REVISED AGAIN (turn 247).  The
turn-243 split (Z4a "compute surface", Z4b "storage flip") was
itself wrong: migrating call sites against the *old* storage type
means building conversion scaffolding (`v3ToZm`/`v3FromZm`/`v3Add`
bridge helpers) whose only reason to exist is that the type is
*temporarily* the wrong shape.  That intermediate state is
incoherent — the camera (`Camera3D.position` et al.) made it
obvious: the camera is internal compute state, there is no reason
its fields are a named-field struct, and "convert at every call
site" is pure waste.  The fix is to stop deferring the type change.

  **Z4 — type-by-type vertical migration.**  Go *one storage type at
  a time*; for each, flip the type definition AND fix every call
  site — compute and storage both — in a single coherent wave, gates
  green at the end of it.  No conversion scaffolding is built,
  because once the type *is* the right shape, compute sites use
  native `@Vector` operators / `zmath.*` directly and storage sites
  just hold the value.  Order by blast radius, smallest first.

  **End-state types (decision 2 ★, made concrete turn 247):**
  - `Vector3` **becomes `@Vector(4,f32)`** — i.e. `pub const Vector3
    = zmath.Vec;`.  Not a struct, not a struct alias.  It is the
    same type as `Vector4`/`Quaternion`/`Vec` (zmath's model — the
    "3-ness" is which *function* you call, `dot3` vs `dot4`, not the
    type).  Named-member access (`.x/.y/.z`) is gone; it is
    `v[0]/v[1]/v[2]`.  Lane 3 is 0 for a direction, 1 for a point,
    by convention.  Verified safe: nothing depends on `Vector3`
    being 12 bytes (no `@sizeOf`/`@ptrCast`/packed-struct embedding;
    `Mesh` vertex data is already raw `[*c]f32`, not `[]Vector3`).
  - `Vector2` → `@Vector(2, f32)` — UI / 2D, 8-byte; the prior
    "no `@Vector(2)`" rule (which applied to 3D math) is lifted for
    Vector2 specifically.  `[2]f32` only where 2D values are
    genuinely *stored packed* (texcoord buffers).
  - `Quaternion` → `zmath.Quat` (= `Vec`) outright.
  - `Vector4` → `Vec`.
  - `[3]f32` / `[2]f32` appear **only where saving space measurably
    matters** — packed vertex/transfer buffers — and those are
    mostly already raw flat `[N*3]f32` arrays, not `[]Vector3`.

  **`math.zig` carries small ergonomic helpers** so the ~560 call
  sites that build vectors don't drown in `@Vector` syntax.  The set
  (added as the first step of Z4, before any call-site churn):
  - `vec3(x, y, z) Vec` — direction constructor, lane 3 = 0.
  - `point3(x, y, z) Vec` — point constructor, lane 3 = 1.
  - `vec2(x, y) @Vector(2, f32)` — UI/2D constructor.
  - `loadArr3([3]f32) Vec` / `storeArr3(Vec) [3]f32` — the
    packed-storage boundary.  `vecToArr3` already exists for the
    store direction; add the load.
  - `loadArr2` / `storeArr2` likewise.
  zmath's `f32x4` stays the explicit 4-lane constructor.  These live
  in `math.zig`'s zimr-additions section.

  **The bespoke struct method suites die** — `Vector3.add`/`.dot`/
  `.cross`/`.normalize`/… in `types.zig` cannot exist on a
  `@Vector` and are not re-created.  Compute is native operators
  (`a + b`, `a * @as(Vec, @splat(s))`) and `zmath.*` functions
  (`dot3`, `cross3`, `normalize3`, `rotate`, `qmul`, …).  The
  `zimrmath.zig` `vector*`/`quaternion*` compute surface is deleted
  as each type's wave removes its last caller.

  **Migration waves, smallest blast radius first:**
  1. `Camera3D` — internal compute state, the clearest case.  Flip
     `position`/`target`/`up` to `Vec`; fix `runtime.zig`'s camera
     code + the ~19 examples that build a camera.
  2. `scene.zig` / `physics.zig` — already migrated their *compute*
     onto bridge helpers (turns 243-244); those bridges collapse to
     nothing once `Vector3`/`Quaternion` are `Vec` (the bridge body
     *was* the conversion).
  3. `drawing.zig` — the `models` builders + the `v3*` consolidation.
  4. The remaining `Vector3`/`Vector2`/`Vector4`/`Quaternion` storage
     sites across `types.zig`, codecs, glTF, examples.
  5. The genuinely-2D ops zmath lacks (`vector2Rotate`,
     `vector2LineAngle`, …) port into a small `math.zig` 2D section
     operating on `@Vector(2, f32)`.
  6. Collapse the Z1 conversion layer (`toZm`/`fromZm` — once the
     types ARE `Vec`, these are identities and delete).  Point
     `gen_flat_exports.py` purely at `math.zig`.  Delete
     `zimrmath.zig`.

  **Wave 2 (Vector3 → Vec) status: ✅ DONE turns 247-248.**
  `pub const Vector3 = zmath.Vec;` lives in `types.zig`.  `zimrmath.zig`
  is down from ~2200 to ~995 lines (Vector3 + Quaternion families
  deleted).  ~507 struct-literal sites and ~195 method-call sites
  migrated to `zmath.vec3(...)` / native operators / `zmath.*`
  functions.  Discovered + documented three structural hazards along
  the way:
  - **Rule 13** (`extern struct` + `@Vector` = layout UB).  Flipped
    `Camera3D` / `Camera2D` / `Transform` / `Ray` / `RayCollision` /
    `BoundingBox` / `Model` / `VrStereoConfig` to plain `struct`.
    Documented in `claude.md`.
  - **Out-param init contract**.  `pub fn run`'s `init_fn` signature
    changed from `fn (...) !State` to `fn (..., *State) !void` to
    kill latent dangling-pointer bugs (logger captures `&state.field`,
    which used to point into the about-to-die stack frame of
    `initState`).  99 examples mechanically migrated.
  - **Two EPA degeneracies fixed**: empty-simplex on coincident
    centers (seed with 4 spread-direction support probes) and
    polytope-full on deep-overlap (graceful bail with best-found
    face instead of asserting).
  - **Bun-style assert module** (`src/assert.zig`) added because
    `wasm32-wasi-none` Debug panics report "Cannot print stack
    trace: debug info unavailable for target" — the new `assertf`
    logs `file:line:col + message` via `std.log.err` (routes through
    `js_log` to the smoke harness) BEFORE the unreachable trap, so
    the diagnostic survives.  Build option `-Dassert-log=true`
    forces it on in any optimize mode.  5 sites in `physics.zig`
    migrated; other 194 sites stay on `std.debug.assert`.
  - **Production install build default** fixed (turn 249): Zig 0.16's
    `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall })`
    actually means "Debug by default, ReleaseSmall when `--release`
    is passed" — the wrong default for a ship-path step.  Replaced
    with explicit `b.option(... orelse .ReleaseSmall)`.  Produces
    202 KB physics_pyramid.wasm vs the prior accidental-Debug 2.7 MB.

  Gates at end of wave 2: `zig build test` 1400/1400, `zig build
  smoke-test` 100/100, `zig build install` produces real
  ReleaseSmall artifacts.

  **Wave 3 (Vector4 → Vec; Quaternion bundled) status: ✅ DONE turns 249-250.**
  `pub const Vector4 = zmath.Vec;` lives in `types.zig`, and since
  `pub const Quaternion = Vector4` per raylib's alias, the flip
  ports Quaternion too — Quaternion *is* Vec now.  `zimrmath.zig`
  shrunk 992 → ~830 lines (the `vector4*` family of 22 functions
  plus the matching test block deleted via Python script with a
  banner comment matching wave 2's deletion).

  The change collapsed several layers of bridge code that had
  accumulated over earlier waves:
  - **Conversion helpers** `vector4ToZm` / `vector4FromZm` /
    `quaternionToZm` / `quaternionFromZm` in `zimrmath.zig`
    became `return v` (identity).  Kept for porting symmetry
    and as a single change-site if Quaternion ever stops
    aliasing Vector4 in the future.
  - **5 example bridges** (`quatStructToVec` / `quatVecToStruct`
    in pbr_demo, physics_demo, physics_pyramid, split_screen,
    plus `quatStructToVec` in `transform_order_test.zig`)
    collapsed to identity — same story.
  - **`physics.zig` quat helpers**: `quatFromAxisAngle` /
    `quatMul` / `quatNormalize` / `quatConjugate` /
    `rotateByQuat` all simplified.  No more struct↔Vec
    wrapping.  `quatConjugate` is now `q * zmath.f32x4(-1,
    -1, -1, 1)` (lane-mask negate).  `rotateByQuat`'s
    runtime-safety check uses `lengthSq4` instead of the
    hand-unrolled `q.x*q.x + ...`.
  - **`drawing.zig`**: `colorNormalize` /
    `colorFromNormalized` lane-indexed (`[0]/[1]/[2]/[3]`),
    `quatSlerp` collapsed to direct `zmath.slerp`, animation
    keyframe lerp rewritten as native ops + `normalize4`
    (with zero-guard fallback to identity quat),
    `matrixFromTransform`'s quat-wrapping deleted (just pass
    `t.rotation` directly to `matFromQuat`), 5 quat-identity
    literals `.{ .x = 0, .y = 0, .z = 0, .w = 1 }` migrated to
    `zmath.f32x4(0, 0, 0, 1)`.  Added `zmath` import to the
    `textures` namespace (it didn't have one before — Vector4
    only entered that namespace via Color↔Vector4 conversion).
  - **`scene.zig`**: `SceneTransform` default rotation
    literal, `matrix()` quat-wrapping deleted, `rotateVector`
    is now a one-liner `return zmath.rotate(q, v)`.
  - **`codecs.zig`**: glTF Node / Material default rotations
    and `base_color_factor`, JSON parse of `baseColorFactor`
    (4 individual field assigns collapsed to one `f32x4(...)`),
    test reads (`.x` → `[0]`).
  - **`gpu.zig`**: `base_color_factor` lane-indexed in
    material-conversion code.
  - **Test files**: Vector4 round-trip test in
    `zm_conversion_test.zig` (round-trip is now an identity
    check, kept for the porting-symmetry rationale),
    `fixture_rot` in `transform_order_test.zig`, Vector4 test
    block in `types.zig` (rewritten with Vec idioms: native
    `+` / `-`, `zmath.dot4(a, b)[0]`, `@as(Vector4, @splat(0))`).
  - **Flat exports**: `gen_flat_exports.py` regenerated; the
    `vector4*` re-exports in `zimr.zig` vanish automatically.

  Gates at end of wave 3: `zig build test` 1398/1398 ✅ (drop
  of 2 from wave 2 = the two deleted Vector4 zimrmath tests,
  expected).  `zig build smoke-test` 100/100 ✅.  Globals
  0/0/0.  DAG clean.

  Empirical-equivalence discipline still applies per wave: before
  trusting that `zmath.X` matches the old `zimrmath.vectorX`, verify
  it (the turn-243 `qmul` operand-reversal trap and the turn-244
  `rotate` unit-quaternion precondition were both caught this way).

  **Wave 4 (Vector2 → @Vector(2, f32)) status: ✅ DONE turn 250.**
  Wider blast radius than waves 2-3 — ~300+ call sites across UI,
  drawing, examples, tests.  Camera2D was already pre-flipped to
  plain `struct` in turn 248 (Rule 13), so the major extern-struct
  hazard was already handled.

  **Method: Python compile-error sweep.**  The volume made
  hand-editing impractical.  A script (`/tmp/migrate_v2_b.py`)
  runs `zig build test`, captures error lines, and for each one
  applies a regex replacing `expr.x → expr[0]` / `expr.y → expr[1]`
  on the dotted identifier path — skipping the conversion if the
  last segment of `expr` looks like a Rectangle variable.  The
  rect-var set is auto-discovered by scanning the file for
  `const X: Rectangle` / `var X: Rectangle` / `const X = Rectangle{`
  declarations and extended with generic names (`r`, `rec`, `rect`,
  `rectangle`).  Run repeatedly until the fix count converges to
  zero — the compiler reveals new errors as parent expressions get
  fixed.  Converged on ~270 sites in `src/ui.zig` (104), `src/
  drawing.zig` (63), `src/types.zig` (27), `src/runtime.zig` (15),
  and a long tail in examples.

  **Hand-fix tail** (~50 sites):
  - **Function-call-result accesses** (`getWindowSize().x` →
    `getWindowSize()[0]`).  The script's regex needs an identifier
    prefix before the dot; `)\.x` doesn't match.  Second regex pass
    handled `)\.x` / `)\.y` directly.
  - **Rectangle/Vector2 collision lines** where the script's auto-
    discovery missed a Rectangle name (`cell`, `w.last_item_rect`,
    `source`, `dest`, `r`, `drag_area`, `handle_rect`).  Manual
    revert from `cell[0]` to `cell.x`.
  - **`runtime.input.Vec2`** — a *separate* struct type from
    `types.Vector2`, used in mouse / touch state.  Has `.x`/`.y`
    fields, not lane indices.  Hand-fixed in `runtime.zig`
    getMouseDelta / getMouseDragDelta / touch.points return shapes
    and a few example callers (camera2d, ui_phone_gestures).
  - **Anonymous internal structs**: `drawing.textures.
    genImageCellular` has per-cell seed array as anonymous
    `struct { x: f32, y: f32 }`; `codecs.truetype.Point`; entities
    test fixtures `Vec2`/`Line`/`TestPrimary`.  These use struct-
    literal init form (`.{ .x = a, .y = b }`), not array form.
  - **Vector2 method calls** (`Vector2.init`, `.dot`, `.length`,
    `.normalize`, `.zero`) — Vector2 has no methods now.  Replaced
    with `Vector2{ x, y }` short literal and `@reduce(.Add, a*b)`
    for 2-lane dot (since `zmath.dot2` takes 4-lane `Vec`).  Deleted
    the "method-style call also works" regression test in `types.zig`.
  - **One regex misfire restored**: the paren-suffix sweep
    accidentally converted 4 method references in `codecs.zig`'s
    `Allocator.vtable` shims (`(struct { fn x() ... }).x` —
    getting a function pointer).  Restored via Python walk that
    checks for `fn x(` declarations within 8 lines before the
    `}).x` site.

  **`zimrmath.zig` shrunk 825 → ~530 lines.**  Full `vector2*`
  family (25 functions + Vector2 test block ~290 lines) deleted
  via Python script.  Dead `closeV2` / `closeV3` helpers deleted
  too.  `vector2ToZm` / `vector2FromZm` updated to take the new
  `@Vector(2, f32)` type (widen to 4-lane `Vec` with lanes 2,3
  zero-filled — unchanged contract).

  **One external `z.vector2*` caller migrated**: `examples/
  kaleidoscope.zig` used `z.vector2Subtract/Rotate/Multiply` —
  converted to native operators + `z.rotate2`.  Initial typo
  `z.math.rotate2` caught by compile error (math isn't a
  namespace on the flat surface; rotate2 is at the top level).

  **Other touches**:
  - **`Vector2i` fix-up**: a pre-conversation wave-4 attempt had
    broken Vector2i by converting its struct-literal method bodies
    to array-literal form.  Vector2i stays a struct (keeps i32 ABI),
    so all `.{ .x = ..., .y = ... }` restored.
  - **types.zig Vector2 test block** rewritten 109 → 64 lines.
    Native operators, `@reduce(.Add, a*b)` for dot,
    `@sqrt(@reduce(.Add, v*v))` for length, `zmath.rotate2` for
    rotation, `@min`/`@max` for min/max/clamp.
  - **ZON layout test in `ui.zig`**: `pos = .{ .x = 100, .y = 200 }`
    → `pos = .{ 100, 200 }` (array form for `@Vector(2, f32)`).
    Caught only after compile passed and tests ran — first wave
    where the compile/test boundary surfaced a separate issue.

  Gates at end of wave 4: `zig build test` 1385/1385 ✅ (drop
  of 13 from wave 3 end = deleted Vector2 zimrmath tests +
  Vector2 test-block reduction + deleted method-style regression
  test; expected).  `zig build smoke-test` 100/100 ✅.  `zig
  build install` 201 KB ReleaseSmall ✅ (verified distinct MD5
  from 2.7 MB Debug smoke).  Globals 0/0/0.  DAG clean.

  **Reflection — was the order right?** Mid-wave the question came
  up: should Rectangle decomposition have happened before Vector2
  to make the migration script trivial (no Rectangle/Vector2
  collision)?  Tallied: of 50 hand-fix sites, only ~6 were
  Rectangle/Vector2 collisions.  The script's rect-var auto-
  discovery handled the rest for free.  Wave 5 (Rectangle
  decomposition) is now actually *better positioned* than the
  alternative ordering — once Vector2 IS `@Vector(2, f32)`, the
  decomposed Rectangle's `pos`/`size` fields are natively Vec2
  with no nested-struct dance.

  **Wave 5 (Rectangle lighter-touch) status: ✅ DONE turn 251.**
  The original "decompose Rectangle into `pos: Vec2, size: Vec2`"
  plan was **abandoned** at the start of the turn after a
  cost-benefit survey: ~2000 `r.x` / `r.y` / `r.width` / `r.height`
  field-access sites across the codebase, virtually all in drawing /
  UI / collision code; only ~5-10 sites do Vec2-shaped Rectangle
  math (translation/scale) that the decomposed form would
  genuinely help.  2-3× verbosity at 2000 sites for a marginal
  win at 10 sites is a bad trade.

  **Option 2 executed instead** (the lighter touch):
  - `Rectangle` flipped from `extern struct` → plain `struct` (Rule
    13 hygiene; the rest of the storage family is already plain
    struct, and `extern` was vestigial since no GPU/raylib path
    passes Rectangle by value through a C-ABI seam).
  - Five Vec2-shaped accessor methods added (`pos()`, `translated()`,
    `scaled()`, `inset()`, plus a `fromPosSize()` pair constructor)
    — opt-in for code that genuinely wants Vec2 ops; the existing
    `r.x/.y/.width/.height` field access keeps working untouched.
  - One test added.

  **Zero existing call sites changed.**  Total diff: ~50 lines
  added to `src/types.zig`.  Gates: 1386/1386 host tests, 100/100
  smoke, 201 KB ReleaseSmall.

  **Reflection.**  The wave-4 banking entry (above) speculated that
  doing Rectangle decomposition after Vector2 would be "better
  positioned" because the decomposed `pos`/`size` fields would be
  natively Vec2.  That speculation was correct on its own terms,
  but it elided the more important question: was the decomposition
  worth doing at all?  The survey said no.  Better-positioned
  doesn't mean worth the position.

  **Wave 6 (`zimrmath.zig` deletion) status: ✅ DONE turn 252.**
  Decision 6 finally realised.  Survey at the start of the turn
  found *zero* live external callers of any zimrmath function —
  the `gen_flat_exports.py`-generated `z.X` re-exports existed but
  were never imported anywhere in `src/` or `examples/`.  Only
  `scene.zig:561` actually called something: `zmath_conv.vector3FromZm(
  zmath.mul(...))` — an identity wrapper around a `zmath.mul`
  result.  Inlined the wrapper (`Vector3 = zmath.Vec` post-wave-2,
  so the conversion is `return v;`), removed the import, deleted
  the file (530 lines, last surviving holdout from raylib's
  raymath.h port).  Also deleted `tests/zm_conversion_test.zig`
  whose premise (round-tripping non-trivial conversions) no
  longer held.  Gates: 1373/1373 host tests, 100/100 smoke,
  201 KB ReleaseSmall.

  **Z4 arc CLOSED.**  All six waves shipped (1: Camera3D, 2:
  Vector3, 3: Vector4 + Quaternion, 4: Vector2, 5: Rectangle
  lighter-touch, 6: zimrmath deletion).  End-state:
  - All math goes through `src/math.zig` (zmath + zimr-additions).
  - Storage types: `Vector2 = @Vector(2, f32)`; `Vector3 =
    Vector4 = Quaternion = zmath.Vec = @Vector(4, f32)`;
    `Matrix = zmath.Mat`; `Rectangle = struct { x, y, width,
    height: f32 }` (plain struct with Vec2-shaped accessors).
  - Rule 13 honoured throughout — no `extern struct` outside
    genuine FFI seams.
  - Empirical-equivalence discipline applied at each wave —
    operand-reversal traps and unit-quaternion preconditions
    caught early.

  Decision 6 (`zimrmath.zig` is deleted) was the original target
  of this whole arc, and it's now done.  *Historical: the
  turn-243 Z4a/Z4b split was superseded by the wave 1-6 plan; the
  turns 243-246 work done under "Z4a" (scene, physics, runtime,
  drawing compute migrated onto bridge helpers) was not wasted —
  those bridges were exactly the conversion that waves 1-3
  collapsed.*


## Prerequisite — do this BEFORE Z0

The **B4-discrepancies investigation** (logged in
`matrix-fix-plan.md`): the `scene.zig` `S*R*T` vs `T*R*S` question and
the two order-mismatches.  Resolve these against `zimrmath` first —
porting latent matrix-order bugs into a freshly-forked library and
then trying to tell "bug" from "convention flip" apart is a debugging
nightmare.  Clean house, then fork.


## Open question to settle during Z2

raylib's `quaternionFromEuler` / `quaternionToEuler` use a specific
euler order.  zmath has `quatFromRollPitchYaw` / `quatToRollPitchYaw`
(documented YXZ).  Before porting, confirm whether they agree — if
not, zimr keeps both, clearly named, and the porting guide documents
the difference.


## Benchmark — `@Vector` vs `struct` under wasm ReleaseSmall

Run before starting, to validate decision 2.  Harness kept in
`work/bench/` (`bench_vec.zig` + `run.js`, bun): a tight ALU-bound
2D-vector workload (lerp + mul + normalize + dot, N=1024 in L1),
median of 9 trials, built `wasm32 ReleaseSmall`.

zimr ships **`wasm32` with `simd128` enabled** (build.zig — the
rasterizer kernels need it), so the simd128 column is the one that
matters.

| compute type     | no-simd | simd128 (zimr's target) |
|------------------|---------|-------------------------|
| `struct{x,y}`    | 1.00x   | 1.00x                   |
| `@Vector(2,f32)` | ~1.00x  | ~1.00x  (tied)          |
| `@Vector(4,f32)` | ~0.97x  | **~0.91x (~9% faster)** |

Findings:
- **`@Vector(2,f32)` is NOT slower than `struct{x,y}` — but also not
  faster.**  wasm SIMD is 128-bit = 4×f32; a 2-wide vector can't fill
  a register and scalarizes just like the struct.  Net: a 2-wide type
  buys nothing and adds a second vector width to track.
- **`@Vector(4,f32)` is ~9% faster** on zimr's actual target — it maps
  to one `v128`, each componentwise op is one instruction.  This is
  exactly zmath's `Vec = @Vector(4,f32)` design and is a point *for*
  adopting it.
- Caveats: tight L1 ALU microbench — the 9% is a compute-kernel
  ceiling, not a whole-frame number.  `@Vector(4)` for 2D doubles
  register footprint (16 vs 8 bytes), which is why the *storage* type
  stays the 12-byte struct; the 4-wide is for transient compute only.

Consequence baked into decisions 2 and Z2: compute on `@Vector(4,f32)`
always (2D in lanes 0,1, zmath-style); never introduce `@Vector(2)`.

