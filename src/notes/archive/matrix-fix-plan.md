# Matrix-convention fix plan

zimr inherits raylib's matrix convention verbatim, which has a
long-documented quirk: `matrixMultiply(L, R)` computes math `R*L`
because the implementation reads matrices in "row times row" order
instead of "row times column".  The pipeline still renders correctly
end-to-end because matrices are also stored transposed in memory, and
the two wrongs cancel — but user-facing code reads upside-down.  See
raylib issues #3039 and #4858 for the long-form discussion.

This document is the per-phase plan.  Turn-by-turn execution status
goes in CHANGELOG.

## Phase B — fix multiplication direction (7 turns)

**Status: PHASE B COMPLETE (Turns 206-219).**

B0-B6 all done.  The codebase uses standard-math matrix
multiplication (`matrixMul`) throughout; the reversed-convention
`matrixMultiply` is removed (`@compileError` stub).  Porting guide
shipped at `src/notes/migrating-from-raylib.md`.  Smoke held
100/100 at every step.

B3 finding: no matrix-building helper internally composes via
`matrixMultiply` — only `vector3Unproject` (a vector helper) did.

B6 deviation: the `zimr.zig` flat export of `matrixMultiply` was
KEPT (not deleted as originally planned) — keeping it means
`z.matrixMultiply` resolves and a call hits the helpful
`@compileError` porting message rather than a generic "no member"
error.

**Remaining work, in priority order:**
1. **B4 discrepancies investigation** (see section below) — the
   `scene.zig` `S*R*T` vs `T*R*S` question + two order mismatches.
   Should come before Phase C.
2. **zmath-adoption discussion** (see `zmath-adoption-idea.md`) —
   would likely absorb Phase C entirely.
3. **Phase C** (struct field reorder) — only if zmath adoption
   does NOT happen; otherwise superseded.

* **B0** — Test scaffolding.  `src/tests/matrix_test.zig` pins
  current behavior with 12 tests across three categories: per-helper
  analytical, multiplication semantics, end-to-end chain.  Result:
  every helper EXCEPT `matrixMultiply` produces a standard matrix.
  This means B3 (helper audit) collapses to verification only.
* **B1** — Document the inherited convention at the top of
  `src/zimrmath.zig`.  Temporary doc; replaced when B6 ships.
* **B2** — Add `pub fn matrixMul(A: Matrix, B: Matrix) Matrix`
  that implements standard math `A * B`.  Body derived from
  `result.m{i+4j} = Σ_k left.m{i+4k} * right.m{k+4j}`.  Equivalent to
  `matrixMultiply(B, A)` — the migration mapping at every call site
  is "swap args + rename".  Old `matrixMultiply` retained.
* **B3** — Verify the per-helper tests still pass (audit step only,
  since B0 showed they all already match standard).
* **B4** — Migrate 45 call sites file-by-file.  Order:
  `zimrmath.zig` → `render.zig` → `drawing.zig` → `scene.zig` +
  `rlgl.zig` + `gpu.zig` → `examples/`.  Focused smoke per file;
  3D demos are the visual regression gate.  Probably 3–4 turns
  rather than 1.
* **B5** — *(merged into B4 per-file smoke; no separate step.)*
* **B6** — Replace `matrixMultiply` body with `@compileError`
  pointing at `matrixMul` and the porting guide.  Ship
  `src/notes/migrating-from-raylib.md`.

## Phase C — reorder struct fields (3 turns)

After B is shipped clean.  The struct memory layout becomes genuinely
column-major (matching OpenGL); field names `m0..m15` unchanged, but
their declaration order swaps from the jumbled raylib order
(`m0, m4, m8, m12, m1, m5, ...`) to sequential (`m0, m1, m2, m3,
m4, m5, ...`).

* **C0** — Reorder declaration in `src/types.zig`.  Audit for
  byte-level Matrix dependencies (pre-flight grep at planning time
  found zero — all paths go through `matrixToFloatV`).
* **C1** — Collapse `matrixToFloatV` to `@bitCast([16]f32, mat)`
  or equivalent.  Short-circuit hot-path callers where useful.
* **C2** — Extend the porting guide with the field-layout note.
  CHANGELOG entry.

## Decisions locked in

1. **Field names stay `m0..m15`** through both phases.  Renaming
   adds 281 unrelated migrations with zero math benefit.
2. **B6 uses `@compileError`** for the removed `matrixMultiply`,
   not silent removal — directs users to the porting guide.
3. **Phase B's call-site migration uses "swap args"**, not "leave
   code alone and reinterpret".  The compile error from the rename
   forces every site to be touched and reviewed.

## Math verification

The new `matrixMul` body, verified against a hand-trace of
`T = translate(1, 0, 0)`, `R = rotateZ(90°)` applied to `(1, 0, 0)`:

* Current `matrixMultiply(T, R) * (1, 0, 0) = (0, 2, 0)`.  Matches
  math `R*T` (translate first, then rotate).  Reversed convention.
* Future `matrixMul(T, R) * (1, 0, 0) = (1, 1, 0)`.  Matches math
  `T*R` (rotate first, then translate).  Standard convention.

End-to-end pipeline (struct → `matrixToFloatV` → OpenGL bytes →
shader → pixel) is unchanged by Phase B alone.  Same matrix bytes,
same uniform, same draw.

## B4 discrepancies — RESOLVED (investigation turn)

B4 was a *mechanical* migration: every `matrixMultiply(L, R)` became
`matrixMul(R, L)`, byte-identical output, behavior preserved (smoke
proves it).  But translating reversed-convention code into standard
notation made several pre-existing comment/code-order mismatches
**legible** for the first time.  The investigation turn confirmed all
of them as real bugs against the column-vector convention anchor
(`drawMesh`: `mvp = matrixMul(proj, model_view)`), fixed them, and
pinned the correct order in `src/tests/transform_order_test.zig` (5
new tests, asymmetric TRS fixture — uniform scale / zero translation
made the buggy and correct orders coincide, which is why smoke never
caught any of this).

**4 bugs found** (the plan originally logged 3; the 4th — `light_space`
— surfaced during the fix as the same error class):

1. **`scene.zig` `SceneTransform.matrix()`** — built math `S * R * T`;
   corrected to `T * R * S`.  Hard confirmation: its consumer reads
   `world.m12/m13/m14` as the world translation, valid only for
   `T * R * S`.  FIXED.

2. **`scene.zig` `worldMatrixOf` chain fold** — folded leaf-outermost
   (`leaf * ... * root`); corrected to root-outermost
   (`root * ... * leaf`) by swapping the `matrixMul` args in the fold.
   FIXED.

3. **`render.zig` skybox `view_proj`** — composed math `view * proj`
   then inverted it; corrected to `proj * view` (the world→clip
   order).  FIXED.  Visual gate: `skybox` + `pbr_demo` standalones.

4. **`render.zig` shadow `light_space`** — composed math
   `light_view * light_proj`; corrected to `light_proj * light_view`.
   Same error class as #3.  FIXED.  Visual gate: `pbr_demo` shadows.

Gates after the fixes: host tests 1314 → 1319, smoke 100/100, fmt
clean, globals 0/0/0.  **Prerequisite cleared — Z0 can begin.**
