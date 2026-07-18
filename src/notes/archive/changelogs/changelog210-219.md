# CHANGELOG — turns 210-219

Per-turn journal for turns 210-219.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 220
opens, this file is frozen and a fresh `changelog220-229.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog200-209.md`, `changelog093-199.md`, `changelog001-092.md`).

---

### Turn 219 — matrix-fix B6: `matrixMultiply` removed — PHASE B COMPLETE

**B6 — the Phase B finish line.**  Four pieces:

1. **`matrixMultiply` removed.**  Its body in `src/zimrmath.zig` is
   now a `@compileError` directing callers to `matrixMul` and the
   porting guide.  Zig's lazy analysis means the stub only fires
   when the function is actually *called* — verified with a
   throwaway test (`_ = zmath.matrixMultiply(a, a)` errors with the
   full message; a plain alias does not).

2. **Flat export kept (deviation from plan, with reason).**  The
   original B6 plan said delete the `zimr.zig` flat export.  But
   keeping `pub const matrixMultiply = ...` means `z.matrixMultiply`
   still *resolves* — and calling it produces the helpful
   `@compileError` porting message instead of a generic "no member
   named matrixMultiply" error.  Better deprecation UX, so the
   export stays (regenerated via `gen_flat_exports.py`, which picks
   it up automatically since it's still a `pub fn`).

3. **Category-2/3 pinning tests removed.**  `matrix_test.zig` shed
   the four tests that called `matrixMultiply` (two reversed-
   convention pins, one inside-out chain, the migration-identity
   test).  Added one replacement — `matrixMul: order matters` —
   pinning that `matrixMul(T,R)` differs from `matrixMul(R,T)` for
   a non-commutative pair.  The file header + section headers
   rewritten for the post-B6 two-category structure.

4. **Porting guide shipped.**  New `src/notes/migrating-from-raylib.md`:
   the `MatrixMultiply(L,R)` → `matrixMul(R,L)` rule with a
   before/after table, why chains now read outside-in, what did NOT
   change (builders, `vector3Transform`, struct field names, GPU
   upload), and a common-idioms quick reference.  Picked up by
   `build_docs.py` into `docs.html`.

Also rewrote the "MATRIX CONVENTION" doc block at the top of
`zimrmath.zig` — it was written as "in progress" with Phase B/C as
future work; now describes the post-B6 state as the current
convention.

**PHASE B IS COMPLETE.**  Recap of the arc (turns 206-219): B0 test
scaffolding → B1 in-source convention doc → B2 add `matrixMul` →
B3 helper audit (no-op, confirmed) → B4 migrate ~36 call sites
across 7 files → B6 remove `matrixMultiply` + porting guide.  The
codebase now uses standard-math matrix multiplication throughout;
the reversed raylib convention is gone.  Smoke held 100/100 at
every single step.

**Tests:** −4 +1, net −3, total 1317 → 1314.

**Audit numbers:** smoke 100/100, host tests 1314/1314, fmt clean,
globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (matrixMultiply →
`@compileError`, convention doc block rewritten), `src/zimr.zig`
(autogen), `src/tests/matrix_test.zig` (4 tests removed, 1 added,
headers rewritten), new `src/notes/migrating-from-raylib.md`,
`docs.html` (regenerated).

**Next turn:** Phase B is done and shippable.  Phase C (struct
field reorder) is optional and can follow, but two things are
queued ahead of it: (a) the "B4 discrepancies" investigation —
the `scene.zig` `S*R*T` vs `T*R*S` question and the two order
mismatches logged in `matrix-fix-plan.md`; (b) the zmath-adoption
discussion Simon flagged, which would likely absorb Phase C.
Next turn should check in with Simon on sequencing.

### Turn 218 — matrix-fix B4 file 7 (runtime.zig + example) — B4 call-site migration COMPLETE

**B4 file 7 — `src/runtime.zig` + `examples/rlsw_side_by_side.zig`.**
- `runtime.zig` `getCameraMatrix2D` — 3 sequential `matrixMultiply`
  calls swapped to `matrixMul`.  Traced: the chain builds math
  `T(offset) * S(zoom) * R(rot) * T(-target)`, which is the correct
  2D-camera transform; the old comment's `*`-notation was loosely
  describing the operation *sequence*, not the matrix product.
  Comment rewritten to state the product unambiguously.
- `rlsw_side_by_side.zig` — 1 site in the MVP-debug-logging path,
  swapped + comment updated.
- `examples/instancing.zig` — a prose comment mentioning
  "matrixMultiply chains" updated to `matrixMul` so it won't dangle
  after B6 removes the old name.

**B4 call-site migration is COMPLETE.**  A repo-wide grep confirms
every `matrixMultiply` *call* is now `matrixMul`.  What remains:
- `pub fn matrixMultiply` in `zimrmath.zig` (the definition) and
  `pub const matrixMultiply` in `zimr.zig` (the flat export) —
  both removed together in B6.
- The Category-2 tests in `matrix_test.zig` that deliberately pin
  `matrixMultiply`'s reversed behavior, plus the migration-identity
  test — all cleaned up in B6 when the function goes away.

**Tally of the full B4 migration** (turns 212-218): 7 files, ~36
call sites — `zimrmath.zig` 6, `render.zig` 2, `drawing.zig` 11,
`scene.zig` 6, `rlsw.zig` 8, `rlgl.zig` 8, `runtime.zig` 3,
`rlsw_side_by_side.zig` 1.  Every non-test swap was byte-identical
(verified via the `matrixMul(A,B) == matrixMultiply(B,A)`
identity); every test rewritten in clean standard-math form.  Smoke
stayed 100/100 across all seven files.  Three latent
comment/code-order discrepancies were surfaced and logged in
`matrix-fix-plan.md` (not fixed — out of B4 scope).

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/runtime.zig` (3 sites + comment),
`examples/rlsw_side_by_side.zig` (1 site + comment),
`examples/instancing.zig` (1 comment).

**Next turn:** B6 — remove `matrixMultiply` (replace body with
`@compileError` pointing at `matrixMul` + the porting guide),
delete its `zimr.zig` flat export, clean up the Category-2 tests
in `matrix_test.zig`, and write `src/notes/migrating-from-raylib.md`.

### Turn 217 — matrix-fix B4 file 6 (rlgl.zig)

**B4 file 6 — `src/rlgl.zig` migrated.**  8 `matrixMultiply` calls,
all non-test, all swapped to `matrixMul`.  This is the WebGL
pipeline counterpart of turn 216's rlsw work and mirrors it
structurally:

- `rlTranslatef` / `rlRotatef` / `rlScalef` / `rlMultMatrix` /
  `rlMultMatrixf` — were `matrixMultiply(m, current)`, math
  `current * m`; now `matrixMul(current, m)`, same product.
- `rlFrustum` / `rlOrtho` — were `matrixMultiply(current, m)`,
  math `m * current`; now `matrixMul(m, current)`, same.
- The MVP build in `rlDrawRenderBatch` — was
  `matrixMultiply(modelview, projection)`, math
  `projection * modelview`; now
  `matrixMul(projection, modelview)`, same and now reads correctly.

All swaps verified byte-identical.  Smoke 100/100 — rlgl is the
WebGL pipeline that *every* example runs through, so a green smoke
sweep is the strongest regression signal available.

**Docstring fixes (reversed-convention artifacts).**  Same class of
fix as rlsw last turn.  The per-function docstrings described
direction in muddled reversed-convention terms:
- `rlTranslatef` / `rlRotatef` / `rlScalef` said "Pre-multiply" —
  the code computes `current * M` (post-multiply in standard
  terms).  Rewritten to state `current = current * M` plainly.
- `rlMultMatrix`'s docstring referenced `matrixMultiply` by name —
  updated to `matrixMul`.
- `rlFrustum` / `rlOrtho` said "Operand order is `current × frustum`
  (post-multiply)" — the code computes `frustum * current`.
  Rewritten to `math frustum * current` with the "wraps the camera
  setup outermost" intuition kept.

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/rlgl.zig` (8 call sites + 5 docstrings).

**Next turn:** B4 file 7 — `src/runtime.zig` (3 sites: the
TRS-chain composition in the runtime's transform helper) plus
`examples/rlsw_side_by_side.zig` (1 site).  After that only the
`src/zimr.zig` flat export remains, then B6 (remove
`matrixMultiply` with `@compileError` + porting guide).

### Turn 216 — matrix-fix B4 file 5 (rlsw.zig)

**B4 file 5 — `src/rlsw.zig` migrated.**  8 `matrixMultiply` calls
(7 non-test + 1 test), all swapped to `matrixMul`:

- Matrix-stack ops `translate` / `rotate` / `scale` / `multMatrix`
  — each was `matrixMultiply(m, cur.*)` (or `(mat.*, cur.*)`),
  computing math `current * M`; now `matrixMul(cur.*, m)`, same
  product.
- `frustum` / `ortho` — were `matrixMultiply(cur.*, m)`, math
  `M * current`; now `matrixMul(m, cur.*)`, same.
- The MVP build in the draw-setup path — was
  `matrixMultiply(modelview, projection)`, math
  `projection * modelview`; now `matrixMul(projection, modelview)`,
  same and now reads correctly.
- The `multMatrix` direction-pinning test — rewritten in clean
  standard-math form: name, comment, and the `expected` expression
  all now say `matrixMul(before, m)` / `current * mat`.

All non-test swaps verified byte-identical.  rlsw has a large
inline-test suite plus the `rlsw_side_by_side` smoke example
(software vs WebGL pixel comparison) — both pass, which is a
strong regression signal for this file.

**Comment fix (reversed-convention artifact).**  The "Multiplication
direction" comment block above the matrix-stack methods stated both
direction formulas *backwards* relative to what the code actually
computes — it was written in the reversed-convention reading
(`matrixMultiply(m, cur)` mentally read as "M * current" when it
actually computes `current * M`).  The prose intuitions
("innermost", "wraps the camera setup") were correct; only the
`A * B` formulas were flipped.  Corrected both, and noted the block
is now in standard math notation.  Also updated the stale
"see the matrixMultiply call patterns in rlgl.zig" cross-reference
to `matrixMul`.

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/rlsw.zig` (8 call sites + 1 comment block).

**Next turn:** B4 file 6 — `src/rlgl.zig` (8 sites: the rlgl
matrix-stack ops `rlMultMatrixf` / `rlRotatef` / `rlTranslatef` /
`rlScalef` + the MVP build in `rlDrawRenderBatch`).

### Turn 215 — matrix-fix B4 file 4 (scene.zig) + discrepancies logged

**B4 file 4 — `src/scene.zig` migrated.**  6 `matrixMultiply` calls
across 5 lines, all strict mechanical swaps:
- `SceneTransform.matrix()` (2 calls) — the T/R/S compose.
- `computeViewState` `view_proj` (1, non-test).
- `computeWorldMatrix` chain fold (1, non-test).
- two `Frustum.intersectsSphere` tests (2) — rewritten in clean
  `matrixMul(view, proj)` form.

Every swap verified byte-identical via the `matrixMul(A,B) ==
matrixMultiply(B,A)` identity.  Smoke 100/100.

**Two latent discrepancies surfaced (NOT fixed — out of B4 scope).**
Translating the reversed-convention code into standard `matrixMul`
notation made two pre-existing comment/code mismatches legible:

1. `SceneTransform.matrix()` computes math `S * R * T`, but the
   comment claimed `T * R * S` and `drawing.zig`'s
   `matrixFromTransform` builds `T * R * S`.  Two transform-compose
   functions producing different products — one is very likely
   wrong.
2. `computeWorldMatrix`'s chain fold computes leaf-outermost
   (`leaf * ... * root`); the original comment claimed
   root-outermost.

Both render correctly in smoke today, which means the scene
examples don't exercise an asymmetric-enough case (non-uniform
scale + rotation) to expose the difference.  Logged in
`matrix-fix-plan.md` under a new "B4 discrepancies" section, with a
note that the investigation turn should build a deliberately
asymmetric test case and fix + regression-test any real bug.  B4
itself stays purely mechanical: source comments updated to state
the *actual* computed product, behavior untouched.

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/scene.zig` (5 lines, 6 call sites),
`src/notes/matrix-fix-plan.md` (+ "B4 discrepancies" section).

**Next turn:** B4 file 5 — `src/rlsw.zig` (8 sites + 1 test: the
software renderer's matrix-stack ops `multMatrix` / `rotate` /
`translate` / `scale` and the MVP build).

### Turn 214 — matrix-fix B4 file 3 (drawing.zig)

**B4 file 3 — `src/drawing.zig` migrated.**  11 `matrixMultiply`
calls across 8 lines, all non-test, all strict mechanical swaps:

- `drawMesh` MVP path (3 calls): `mat_model`, `mat_model_view`,
  `mvp` — the model→world→view→clip composition.
- `drawModelEx` (3 calls): the TRS chain
  `matrixMultiply(matrixMultiply(S, R), T)` plus the
  `model.transform` compose.
- `drawModelWiresEx` (3 calls): same TRS-chain + compose shape.
- `matrixFromTransform` (2 calls): the per-bone TRS chain used by
  skeletal animation.

The TRS chains are worth a note: the old
`matrixMultiply(matrixMultiply(S, R), T)` computed math `T*R*S`
(the correct TRS matrix — scale applied to the vertex first), just
written inside-out.  The mechanical swap yields
`matrixMul(T, matrixMul(R, S))` — still `T*R*S`, now reading
outside-in to match standard math.  Comments updated to state the
`T*R*S` product explicitly.

Every swap verified byte-identical via the `matrixMul(A,B) ==
matrixMultiply(B,A)` identity.  Smoke 100/100 — every 3D model
example (models3d, skinned_mesh, instancing, pbr_demo, billboards,
cube3d, gltf_*) renders unchanged, which is the real regression
gate for this file.

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/drawing.zig` (8 lines, 11 call sites).

**Next turn:** B4 file 4 — `src/scene.zig` (5 sites: the
scene-graph world-transform composition + the view-projection
builders in the camera path).

### Turn 213 — matrix-fix B4 file 2 (render.zig) + zmath-adoption idea captured

**B4 file 2 — `src/render.zig` migrated.**  Two non-test call sites,
both strict mechanical swaps:
- `light_space` (shadow pass): `matrixMultiply(light_proj,
  light_view)` → `matrixMul(light_view, light_proj)`.
- `view_proj` (skybox pass): `matrixMultiply(proj, view)` →
  `matrixMul(view, proj)`.

Both verified byte-identical via the `matrixMul(A,B) ==
matrixMultiply(B,A)` identity.  Comments updated to record the
provenance and state the computed product in standard notation.

Note for a later turn (NOT a B4 concern): the skybox comment used
to read "Inverse(proj * view)" but the code — under the old
reversed convention — computed `view * proj`.  The mechanical swap
preserves that exactly, and the now-standard-notation code makes
the question legible.  Whether `view * proj` is the intended order
or a latent bug masked by the `matrixToFloatV` reshuffle is a
separate investigation; B4's job is only to change the spelling,
and smoke (100/100, including all skybox + shadow examples)
confirms behavior is unchanged.

**zmath-adoption idea captured.**  Simon raised the possibility of
replacing the hand-ported `zimrmath.zig` with a house-style fork of
**zmath** (SIMD `@Vector`-based math, enables `v1 + v2`, Zig
ecosystem compat).  Wrote `src/notes/zmath-adoption-idea.md`
capturing the idea, the rough blast radius (62 files, ~1940
`Vector[234]` mentions, ~11.7k `.x/.y/.z` accesses), the central
design question (named-field structs with SIMD underneath vs.
exposing `@Vector` directly), and what the real investigation must
cover (C-ABI / `extern struct` layout — `@Vector(4,f32)` is 16
bytes vs `extern struct {x,y,z}` 12 bytes, which touches every
vertex-buffer and uniform path).  **Status: idea only**, to be
revisited with Simon after Phase B closes.  The matrix-fix arc
continues unaffected — finishing Phase B first makes any eventual
zmath diff smaller (call sites already say `matrixMul`).

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/render.zig` (2 call sites), new
`src/notes/zmath-adoption-idea.md`.

**Next turn:** B4 file 3 — `src/drawing.zig` (8 sites: the
model-view-projection composition in the 3D draw path, plus the
TRS-chain builders).

### Turn 212 — matrix-convention fix, Phase B3 + B4 (file 1: zimrmath.zig)

**B3 — helper audit (no-op confirmed).**  The per-helper analytical
tests from Turn 206 already pass.  B3's distinct job was checking
whether any matrix-*building* helper internally composes via
`matrixMultiply` — if one did, it'd be entangled with the reversed
convention and belong in B4's surface.  Audit result: the only
`matrixMultiply` caller inside `src/zimrmath.zig` is
`vector3Unproject`, which is a *vector* helper, not a matrix
builder.  All eight matrix-building helpers (translate, scale,
rotateX/Y/Z, perspective, ortho, lookAt, invert, transpose) are
self-contained.  The plan's independence assumption holds; B3
needs zero fixes.

**B4 file 1 — `src/zimrmath.zig` migrated.**  Six `matrixMultiply`
call sites moved to `matrixMul`:

- `vector3Unproject` (1 site, non-test) — strict mechanical swap:
  `matrixMultiply(view, projection)` → `matrixMul(projection, view)`.
  Both evaluate to math `projection * view`; byte-identical output.
- Three inline `test` blocks (5 sites) — rewritten in clean
  standard-math form rather than mechanical swap, since test
  assertions are self-contained and reading like math is clearer:
  the identity test now names its temporaries `a_times_i` /
  `i_times_a`; the invert test composes `M = matrixMul(T, R)`;
  the rotateXYZ-inverse test composes `matrixMul(A, B)` matching
  its "R_xyz * R_zyx should be identity" comment (the old code
  computed the reverse, which was also identity — comment and
  code now agree).

**B4 policy locked in (recorded here for the remaining files):**
- **Non-test call sites: strict mechanical swap.**
  `matrixMultiply(L, R)` → `matrixMul(R, L)`.  Output is
  byte-identical, so behavior cannot change; any test/smoke
  regression would mean a transcription error, immediately
  suspicious.
- **Test call sites: rewrite in standard-math form.**  The
  assertions are self-contained; clarity wins.  Each migrated
  test is re-run to confirm it still passes.

**Remaining B4 surface:** ~38 call sites across `render.zig` (2),
`drawing.zig` (8), `scene.zig` (5), `rlsw.zig` (8 + 1 test),
`rlgl.zig` (8), `runtime.zig` (3), `examples/rlsw_side_by_side.zig`
(1), plus the `src/zimr.zig` flat export.  Order per plan:
render → drawing → scene/rlgl/gpu → rlsw → examples.

**Tests:** no count change, 1317/1317 (migrated tests rewritten
in place, not added).

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (6 call sites, +8/-7 lines
incl. comments).

**Next turn:** B4 file 2 — `src/render.zig` (2 sites, both
projection/view composition in the shadow + main render paths).

### Turn 211 — changelogs split into per-decade files

Process change.  The monolithic `src/notes/CHANGELOG.md` had grown
to 14,421 lines / 115 turn entries (turns 93-210) — too big for the
"read the last 2-3 entries on a fresh session" workflow to stay
cheap.  Restructured into `src/notes/changelogs/`, one file per ten
turns:

- `changelog001-092.md` — was `archive/changelog_may_08.md`, moved
  and renamed.  Turns 1-92.  Frozen.
- `changelog093-199.md` — turns 93-199, carved out of the old
  monolith.  Frozen.  (Wider-than-decade range because it predates
  the scheme.)
- `changelog200-209.md` — turns 201-209 (200 and 204 never had
  entries).  Frozen.
- `changelog210-219.md` — **the new active file.**  Turn 210
  carried over, turn 211 (this entry) appended.  Has the
  `## [Unreleased]` header.

Entry-count check: 1 + 8 + 106 = 115, matches the original.

Rollover rule going forward: when the first turn of a new decade
opens (220, 230, ...), freeze the current file (drop its
`## [Unreleased]`, adjust the preamble) and start a fresh
`changelogNNN-MMM.md`.  The old size-threshold rotation is retired
— turn number alone decides when a file closes.

**Also folded in two smaller claude.md changes Simon asked for:**
- Removed the "ask the user to confirm they downloaded the zip"
  line added in turn 209 — snapshot cleanup is now fully
  autonomous, no confirmation needed.
- Updated the reading-order section (item 1) and per-turn rule 2
  to describe the new changelog layout.

**Files touched:** `src/notes/claude.md` (reading-order item 1,
rule 1 zip-confirm removal, rule 2 full rewrite), new
`src/notes/changelogs/` (4 files), deleted `src/notes/CHANGELOG.md`,
moved `src/notes/archive/changelog_may_08.md`.

No code change, no gate impact.

### Turn 210 — matrix-convention fix, Phase B2: add `matrixMul`

Added `pub fn matrixMul(left, right) Matrix` to `src/zimrmath.zig`,
implementing standard math `A*B` (`result[r,c] = Σ_k A[r,k]*B[k,c]`).
The old reversed-convention `matrixMultiply` is untouched and still
exported — nothing calls `matrixMul` yet, so smoke is unaffected.

**Code shipped:**
- `src/zimrmath.zig` — new `matrixMul` (16-line body + doc comment).
  Body derived by taking `matrixMultiply`'s body and swapping
  `left`↔`right` throughout, then reordering each term left-first.
- `src/zimr.zig` — regenerated flat exports via
  `scripts/gen_flat_exports.py`; `z.matrixMul` picked up
  automatically (it's a new `pub fn`, no SKIP-list change needed).
- `src/tests/matrix_test.zig` — four new tests in a new
  "Category 2b" section.

**Implementation choices:**
- Body derivation: rather than re-deriving from the Σ formula and
  risking a transcription error, took the known-correct
  `matrixMultiply` body and applied the `matrixMul(A,B) ==
  matrixMultiply(B,A)` identity — swap the operands, reorder for
  readability.  Then cross-checked three elements (m5, m10, m12)
  against the Σ formula independently.
- Kept `matrixMultiply` fully intact this turn.  B2 is purely
  additive; the call-site migration is B4's job.  This keeps the
  turn's blast radius at zero — if smoke had regressed, it would
  have been a real surprise pointing at a gen-script bug.

**Tests added:** +4, total 1313 → 1317.
- `matrixMul` computes standard A*B (the `(1,1,0)` result vs
  `matrixMultiply`'s `(0,2,0)` for the same T, R).
- The migration identity `matrixMul(A,B) == matrixMultiply(B,A)`,
  tested on a non-commutative rotation/translation pair both ways.
- Identity is the two-sided multiplicative identity.
- Outside-in transform chain reads like math, and equals the
  inside-out `matrixMultiply` chain for the same end transform.

**Audit numbers:** smoke 100/100, host tests 1317/1317, fmt clean,
globals 0/0/0.

**Files touched:** `src/zimrmath.zig` (+28), `src/zimr.zig`
(+1 export, autogen), `src/tests/matrix_test.zig` (+82).

**Next turn:** B3 — re-run the per-helper analytical tests as a
formal audit step (Turn 206 already showed all helpers produce
standard matrices, so this is expected to be a no-op confirmation),
then start B4's call-site migration with `src/zimrmath.zig`'s own
internal uses.

