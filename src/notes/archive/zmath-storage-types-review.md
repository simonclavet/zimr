# zmath-adoption — storage-types review (turn 232)

Investigation log behind the turn-232 amendment to **decision 2** of
`zmath-adoption-plan.md` (the storage-vs-compute split).

## Why this review happened

Mid-Z3, after migrating `renderer_trait.zig` (leaf 1) and `rlsw.zig`
(leaf 2), Simon asked the right question at the right time: *are we
losing performance to all these conversions?  We agreed no SIMD
storage of matrices — but are we 100% sure?  We will spend a long
time converting.*

The honest answer was no, we were not 100% sure — the original
decision 2 applied one uniform storage/compute split to all of
`Vector2/3/4`, `Quaternion`, `Matrix` without distinguishing
"interop layout is genuinely load-bearing" from "two names for one
thing."  This review gathered the evidence.

## What was measured

### 1. Exact sizes and alignments

| type | `@sizeOf` storage | `@sizeOf` zmath | `@alignOf` storage / zmath | layout-forced & different from `@Vector`? |
|---|---|---|---|---|
| `Vector2`    | 8  | (no zmath 2D) | 4 / —  | yes |
| `Vector3`    | 12 | 16 (`Vec`)    | 4 / 16 | **yes — 12≠16** |
| `Vector4`    | 16 | 16 (`Vec`)    | 4 / 16 | no — size-identical |
| `Quaternion` | 16 | 16 (`Quat`)   | 4 / 16 | no — size-identical |
| `Matrix`     | 64 | 64 (`Mat`)    | 4 / 16 | no — size-identical |

`Vector3` is the one type with a real, irreducible layout
difference: 12 bytes vs 16.  A vertex buffer packed
`[pos:Vec3][nrm:Vec3][uv:Vec2]` has a stride the GPU and the
`.blend` parser depend on.  `Vector2` has no zmath equivalent at
all.  `Vector4`/`Quaternion`/`Matrix` are all *size-identical* to
their zmath counterparts — the only delta is alignment (4 vs 16).

### 2. Every `Matrix` site, classified

- **Struct fields holding a `Matrix`:** `rlgl.GlState` (modelview/
  projection/transform), `rlsw.Context.mat_mvp`, `scene` node
  (world/view/proj/view_proj), `drawing` model transforms,
  `gpu.zig` draw params, `types.zig` `Transform`-adjacent.  All are
  *compute state* — none are GPU-buffer-layout structs.
- **`@ptrCast` / `@bitCast` / `@alignCast` on `Matrix`:** only the
  `boneMatrices` sites in `drawing.zig` — and those cast
  `[*c]Matrix` ↔ `[]Matrix`, i.e. **same type on both sides**, just
  pointer-shape juggling between an allocator return and a slice.
  If `Matrix` becomes `Mat`, both sides are `Mat`; the cast stays
  valid.
- **`Matrix` crossing FFI / GPU upload:** every matrix→GPU path goes
  through `matrixToFloatV` / `matToArr` producing a fresh `[16]f32`
  first — `rlgl.rlSetUniformMatrix` (`matrixToFloatV` then
  `uniformMatrix4fv`), `rlgl.rlSetUniformMatrices` (loops
  `matrixToFloatV` into a float buffer), `gl_iface.multMatrix`
  (now `matToArr`).  `rlgl.zig` even carries an explicit comment
  *warning against* `@ptrCast(&matrix)` to `[*c]const f32` because
  the byte order would be wrong.  **No site hands a `*Matrix`
  struct across FFI.**
- **`@sizeOf`/`@offsetOf`/`@alignOf` on `Matrix`:** grep came back
  **empty**.  Nothing depends on `Matrix`'s exact layout
  numerically.

### 3. The Z1 finding, recalled

Z1 (turn 223) already established that zimr's `Matrix` (column-major
*storage*) and zmath's `Mat` (row-major) use the *same row-major
field naming*, so `matrixToZm` is a direct field-name copy, not a
transpose — the memory-layout flip happens for free.  Two types
that are that close are two names for one thing.

## The conclusions

1. **`Matrix`, `Vector4`, `Quaternion` should not be distinct storage
   types.**  They are size-identical to `zmath.Mat`/`Vec`/`Quat`,
   nothing depends on their layout numerically, and nothing crosses
   FFI with them as structs.  Keeping them separate is a decision-7
   violation (two names, one concept) that was baked into Phase 0's
   assumptions instead of surfacing as a "port this duplicate?"
   question.  They *become* the zmath types.

2. **`Vector2` and `Vector3` stay storage structs.**  Their byte
   layout is genuinely interop-forced (vertex formats, the C ABI,
   the `.blend` parser) and — for `Vector3` — *differs* from
   `@Vector(4,f32)` (12 vs 16 bytes).  Here the split earns its
   cost.

3. **The "conversion cost" worry is half-misplaced.**  For
   `Vector3`, `toZm(v)` = `f32x4(v.x, v.y, v.z, 0)` is *a load*, not
   a memory reformat — a hand-written `vector3Add` does the same
   load.  The split does not add work; it relabels where the load is
   written.  The conversions that *genuinely* cost something are the
   64-byte `Matrix` round-trips around a `mul` — and those are
   exactly what conclusion 1 *deletes* by collapsing the type.

4. **Alignment rising 4→16 is safe.**  `gpa.alloc(Mat, n)` aligns
   correctly for any type; nothing reads a `Mat` through a
   tighter-aligned pointer (the `@sizeOf`/`@offsetOf` grep proved
   no layout dependency).  Alignment *rising* only breaks code that
   assumed *tighter* packing — and there is none.

## The rule, going forward

> A type gets a separate storage representation **if and only if**
> its in-memory byte layout is constrained by something outside
> zimr's control (the C ABI, a vertex format, a file format) **AND**
> that layout differs from the compute representation
> `@Vector(4,f32)`.  Otherwise there is one type, and it is the
> zmath one.

Under this rule: `Vector2`/`Vector3` split; `Vector4`/`Quaternion`/
`Matrix` do not.  The rule is no longer "split everything" — it is
"split exactly what reality forces you to split."  This is the same
principle as decision 7 (one name per concept), finally applied to
the type layer instead of just the function layer.

---

## CORRECTION (turn 233) — the rule above was incomplete

Starting the collapse, the first thing checked was `Vector4` /
`Quaternion` (smallest blast radius — collapse the easy one first to
prove the pattern).  That check found the turn-232 rule was **wrong
about them**.

The turn-232 rule keyed on *layout*: "size-identical to a zmath type
AND nothing depends on the layout numerically → collapse."  But it
never checked **semantic** usage.  The evidence the collapse-attempt
surfaced:

- `codecs.zig` stores glTF `rotation` and `base_color_factor` as
  `Vector4` struct fields and parses them **field-by-field from
  JSON**: `mat.base_color_factor.x = jsonToFloat(items[0])`, etc.
- `physics.zig` stores `orientation: Quaternion = .{ .x=0, .y=0,
  .z=0, .w=1 }` as `RigidBody` state — a named-field record.
- A quaternion's `.w` is the **scalar part** — a meaningful name,
  not a bare index.  `q[3]` is strictly worse.
- `Vector4` **never crosses a hard ABI boundary as a struct** — the
  extern/GPU/FFI grep came back empty.  So the *interop* argument
  that was supposed to justify collapsing it does not even apply.

So `Vector4`/`Quaternion` are **storage/semantic structs that happen
to be size-16** — the *opposite* of `Matrix`.  Size-compatibility
makes a collapse *possible*; it does not make it *good*.

**The corrected rule has three clauses — all must hold to collapse:**

1. layout-compatible with `@Vector(4,f32)` (alignment may only
   rise), **and**
2. **no semantically-named fields** — components are bare indices,
   not meaningful names, **and**
3. **never crosses a hard ABI boundary as a struct** — only ever
   flattened to a float array, if at all.

| type | (1) layout-compat | (2) no semantic fields | (3) never ABI struct | collapse? |
|---|---|---|---|---|
| `Vector2`    | no  | no (`.x .y`)        | no  | **stays** |
| `Vector3`    | no  | no (`.x .y .z`)     | no  | **stays** |
| `Vector4`    | yes | **no** (`.x .y .z .w`) | partial (glTF value) | **stays** |
| `Quaternion` | yes | **no** (`.w` scalar) | no  | **stays** |
| `Matrix`     | yes | **yes** (`.m5`=idx) | **yes** (always flattened) | **collapses** |

**`Matrix` is the only type passing all three.**  Z3 step 0 collapses
`Matrix` → `zmath.Mat` and *only* `Matrix`.  The decision-2 amendment
in the plan is updated to this three-clause form.

Lesson: the turn-232 investigation measured the right things for
`Matrix` (its case is genuinely about layout + flattening) but
generalised from them too eagerly.  A type's *interface* —
whether its fields carry meaning — matters as much as its *layout*.
The collapse-attempt itself was the check that caught it; better to
have found this in the first five minutes of Z3 step 0 than after
rewriting `codecs.zig` to positional `Vec` literals.

## Consequence for the migration

Z3 gains a **step 0**: the type collapse, done first as one coherent
change.  It makes every remaining leaf cheaper — matrix-stack and
quaternion code stops needing conversions at all; only `Vector2`/
`Vector3` compute sites still convert.  The `rlsw.zig` conversions
added in turn 231 mostly *delete* in Z3 step 0 (the operand-order
reversal stays — that is a real convention fact, not a conversion
artifact).  Z4 shrinks correspondingly: half the "relocate the
storage struct" work becomes "the struct is already gone."

## The `.mN` blast radius — measured, and smaller than it looks

`zmath.Mat` is `[4]@Vector(4,f32)`, indexed `m[row][col]` — it has
no `.m0`..`.m15` named fields and (being built on `@Vector`) cannot
be **runtime**-indexed.  So the collapse must rewrite every `.mN`
access.  Raw count across `src/`: **1329**.  That sounds
prohibitive.  It is not, once broken down:

| file | `.mN` count | migration cost? |
|---|---|---|
| `zimrmath.zig` | 894 | **no** — these vanish when the file is deleted |
| `rlgl.zig`     | 162 | yes |
| `types.zig`    | 85  | yes (the `Matrix` struct def + methods themselves) |
| `scene.zig`    | 58  | yes |
| `rlsw.zig`     | 55  | yes |
| `drawing.zig`  | 43  | yes |
| `runtime.zig`  | 32  | yes |

**67% of the apparent cost (894 sites) is inside the file being
deleted** — not migration work at all.  The genuine external cost is
**~435 sites**, and the rewrite is purely mechanical: `mN` maps to
`m[N/4][N%4]` (verified empirically — `m0`→`m[0][0]`, `m5`→`m[1][1]`,
`m12`→`m[3][0]`).  A scripted regex sweep with careful
gate-verification handles it.

**The `@Vector` runtime-index limitation does not bite zimr.** A grep
for runtime-indexed matrix loops (`m[var][var]`, `@field` with a
computed name) came back **empty** — zimr only ever accesses matrix
elements by compile-time-known field.  So no `inline for`
restructuring is needed; the limitation is real in principle but
inert in this codebase.

Conclusion: the collapse is *large but genuinely mechanical*, and
the "1329" headline number is two-thirds illusory.  The earlier
worry that it was deceptively expensive is itself dispelled by the
measurement.
