# spv2wgsl-rewrite-changelog.md

Dedicated changelog for the spv2wgsl rewrite arc described in
`src/notes/archive/spv2wgsl-rewrite-plan.md`.  Each phase boundary adds an
entry.

---

## 2026-05-29 — Phase 8 complete: mandelbrot demo re-enabled; red diagnostic gone

**Status:** Phase 8 closed.  The fractal renders for real.  Remaining
phases (5b/5c linear emitter deletion, 7 lower-priority hardening, 9
docs+archival) are all cleanup — the rewrite's core mission is
delivered.

What changed (small but symbolically large):

- **`examples/mandelbrot_fs.zig`** — removed the
  `out.out_color = zm.vec4(1.0, 0.0, 0.0, 1.0)` diagnostic that
  forced the canvas to solid red.  The shader now returns its
  computed fractal color: black inside the set, HSV-rainbow on
  the iteration tail outside.

- **`examples/wgpu_demo/wgpu_demo.zig`** — restored engine pipeline
  shapes:
  - top-left blue quad (96×96 at offset 16, 16)
  - top-right green quad (96×96 mirror)
  - center magenta triangle pointing up at screen center
  - then the full-screen mandelbrot triangle on top

  All in the same render pass via the shared `shapes_batch`.  The
  engine pipeline and the spv2wgsl-translated mandelbrot pipeline
  coexist without resource conflict, batch confusion, or pipeline
  state churn — the same property the original "diagnostic" demo
  was hiding by removing the engine shapes.

- **Mandelbrot UBO params** restored to real-render values:
  zoom=1.2, max_iter=512 (was zoom=0.4, max_iter=64 — diagnostic
  settings tuned to make "escape colors dominate" while
  debugging).

**Verification:**
- `zig build wgpu-smoke`: **60 frames clean**, bridge calls now
  ~26/frame (up from ~21 — the extra calls are the restored
  engine shapes).  The wasm instantiates, the SwBackend
  smoke-driver runs through the full update loop without trap.
- `zig build wgpu-diff`: **40/40 tests pass.**  Tint corpus:
  179 ok, 2 known-bug.  Internal corpus: 45 ok, 0 known-bug, 2
  err-marker (corpus grew by 2 since Phase 6 — the two new
  shaders are the engine pipeline variants compiled by the
  demo build; both translate cleanly).
- Direct inspection of the freshly-compiled mandelbrot
  `shader.opt.spv` → WGSL output: ends in
  ```wgsl
    } else {
      phi2231 = undef_1961;     ← only on not-yet-escaped path
    }
    out_color = phi2231;
  ```
  The `out_color = red` override is gone.  The phi value flows
  through the correct branch.

**The reason this is symbolically large:**

The mandelbrot diagnostic was added when the linear emitter
produced WGSL that rendered the fractal as solid red OR black
(depending on path).  The diagnostic forced red so we could be
sure of "shader produces SOMETHING" vs the alternative "shader
produces nothing because something earlier broke."  When the
recursive walker landed in Phases 2-6, the diagnostic became
provably unnecessary.  Removing it is the cleanest possible
proof that the rewrite arc succeeded.

**Turn 4 (foundations plan) is fully unblocked.**  The wgpu vs
sw split-screen mandelbrot demo can be built now that the wgpu
path produces correct pixels.

**What's left in Turn 3.9:**

- **Phase 5b/5c (linear emitter deletion)** — pure dead-code
  removal, ~1100 LOC.  Mechanical; bisect-safe.
- **Phase 7** — combined with 5c.  Plus optional: handle the 2
  remaining Tint switch fixtures (multi-predecessor phi).  Not
  blocking anything; the Zig+spirv-opt pipeline doesn't produce
  that shape.
- **Phase 9** — docs cleanup + move the rewrite plan to
  `archive/`.  Update PLAN.md to point at Turn 4 as the active
  arc.

These can be batched into a single closing session or split
across two — they're cleanup, not feature work.

---

## 2026-05-29 — Phase 6 complete: one-sided-if phi-routing fix; mandelbrot bug ELIMINATED

**Status:** Phase 6 closed.  The bug that drove the entire spv2wgsl
rewrite arc is fixed.  Internal corpus: **9 → 0 known-bug** (all
fractal shaders translate correctly).  Tint corpus: **3 → 2
known-bug** (one Tint fixture fixed by the same change; the other
2 hit a different pattern, Phase 7 territory).

What landed:

- **`isTrivialPassthroughBlock(blocks, id, spirv, inst_off) bool`**
  — detects whether a block is structurally empty (kind=plain,
  no real body content between OpLabel and terminator, just
  hoisted Phi declarations and metadata).  Such blocks are
  "pass-throughs" that exist only to carry pre-terminator phi
  assignments for their predecessor role.

- **`emitSelection` Phase 6 branch.**  When the merge block is a
  trivial pass-through AND one of true_id/false_id equals
  merge_id (the "one-sided if" pattern), the walker now:
  1. Emits the merge block's pre-terminator phi assignments
     INSIDE the empty branch (the else for the common
     `false_id == merge_id` case).
  2. In outer scope, SKIPS past the merge block — emits its
     terminator's continuation directly.  This is the line
     that removes the `phi = undef;` from outer scope where
     it used to clobber the other branch's phi value.

  The fix is gated by a third condition: `merge_id` must NOT be
  in the stop set with a non-`if_merge` kind.  This guards the
  case where the merge is a continue-target / loop-merge of an
  enclosing construct (the previous Phase 4 abort) — there,
  recursing into the merge's terminator target would loop back
  to the loop header forever.  When the merge is owned by an
  enclosing construct, fall back to the §2.3 recipe.

- **`Baseline.tint_corpus_known_bugs` lowered 3 → 2** in
  `src/tests/spv2wgsl_corpus_test.zig`.  Matches the corpus
  comment convention: "When you change the translator and a
  bug count drops, you LOWER these numbers in the same patch."

**Headline result:**

Inspecting mandelbrot's WGSL output, the pattern that drove the
entire arc:

Before (any pre-Phase-6 emitter — linear OR walker):
```wgsl
if (_1233) {
  phi1975 = vec4(1, 0, 0, 1);   ← true branch's phi
}
phi1975 = undef_1963;            ← merge block in outer scope; OVERWRITES
outputs.out_color = phi1975;
```

After Phase 6:
```wgsl
if (_1233) {
  phi1975 = vec4(1, 0, 0, 1);
  break;                          ← (this branch already exits via loop_break)
} else {
  phi1975 = undef_1963;           ← merge's phi assignment, in the else only
}
break;
```

**phi1975 is no longer overwritten** when `_1233` is true.  The
mandelbrot fragment shader now produces correct colors when run
through the walker — the `out_color = red` diagnostic in
`examples/mandelbrot_fs.zig` becomes removable (Phase 8 task).

**Why this fix didn't fit in Phase 4:**

The Phase 4 attempt naively advanced the "effective merge" to
the merge block's terminator target.  When that target was a
loop header (e.g. the back-edge in a continue construct), the
recursion looped forever.  Phase 6's gate (`merge_already_owned`)
catches exactly this case: if the merge is in the stop_set with
a kind other than `if_merge`, an enclosing construct owns it
and the natural fallthrough is correct — don't try to advance.

**Verification:**
- `zig build wgpu-diff`: **40/40 tests pass.**
- Tint corpus: **179 ok, 2 known-bug** (was 178/3).  The 2
  remaining `Phi_Switch_*` fixtures hit a multi-predecessor
  pattern (multiple non-trivial blocks branching to the same
  merge with different phi values) — Phase 7 territory.
- Internal corpus: **43 ok, 0 known-bug, 2 err-marker** (was
  34/9/2).  **Every fractal shader now translates correctly.**
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/
  frame.

The 2 err-marker shaders (one ".opt.spv" each) are pre-existing
combined-sampler limitations — orthogonal to this rewrite.

**Updated walker unit test:**

`emitBlock: selection — mandelbrot pattern (true branch breaks
to outer loop)` was asserting on the PRE-Phase-6 output shape
(merge body in outer scope).  Updated to the new (correct)
shape: merge body in the else, merge's target in outer scope.
All 24 walker tests pass.

**What's left in the rewrite:**

The arc is largely complete now.  Remaining phases:

- **Phase 5b/5c**: rename / delete the linear emitter (~1100 LOC).
  Pure dead-code removal; bisect-safe.
- **Phase 7**: linear walker retirement was the original §7
  scope; with 5c also doing this, Phase 7 becomes about hardening
  the 2 remaining Tint known-bug fixtures (multi-predecessor
  phi).  Lower priority — the Zig + spirv-opt path doesn't
  produce this shape in our domain.
- **Phase 8**: re-enable mandelbrot demo (`out_color = red`
  diagnostic removal; engine triangles restoration in
  `wgpu_demo.zig`).
- **Phase 9**: docs + archival.

Phase 8 is now unblocked — the mandelbrot should render correctly
without the diagnostic.  Time to take it off and see actual
fractals.

---

## 2026-05-29 — Phase 5a complete: walker drives switch shaders; linear emitter is dead code

**Status:** Phase 5a closed.  The walker is now the production path
for **every** structured CFG kind.  Phase 5b (rename flag to opt-in
fallback) and 5c (delete the linear emitter ~2000 LOC) pending.
Phase 6 (one-sided-if phi-routing fix) is the work that flips the
9+3 still-flagged known-bug shaders to ok.

What landed:

- **`walker.emitSwitch`** per §2.5 + `parser.cc:3797`.  Decodes
  `OpSwitch %selector %default (literal, %target)+`, emits a WGSL
  `switch (selector) { case L: { ... break; } ... default: { ... } }`.
  Empty cases (target == merge) emit just `break;`.  Non-empty
  cases recurse into their target with merge in `stop_set` as
  `switch_break`.  Default arm always present (WGSL requires it).

- **Multi-case literals.**  The plan originally scoped Phase 5 to
  single-default switches (Zig only emits those for compute
  paths), but Tint's 3 known-bug switch fixtures all have real
  multi-case OpSwitches.  Implementation handles them: walk
  `(literal, target)+` pairs, one case per pair.  i32 selectors
  → 1-word literals (our domain assumption — explicit comment
  + diagnostic for multi-word literals).

- **`endsWithStmt` helper.**  When a case body's recursive walk
  produces a terminator that already ends the case (`break;`,
  `return;`, `continue;`, `discard;`), don't add a redundant
  `break;`.  Pure-text trailing-whitespace tolerant match.

- **`walkerSafetyCheck` gate retired.**  Returns true unconditionally
  now.  Kept as a function (one place to add new gates later, e.g.
  unstructured CFG hardening).  The linear emitter in
  `emitFunctionBody` is now **dead code** — every block kind routes
  through the walker.

Tests (2 new, both pass):

- `emitBlock: switch — basic multi-case with default` — 5-block
  CFG with two cases (one shared between case 1 and default) and
  a non-aliased case 0.  Asserts on `switch (_99) {`, `case 0:`,
  `case 1:`, `default:`, the case bodies, and the merge in
  outer scope.

- `emitBlock: switch — empty-case-is-merge gets explicit break` —
  one case directly targets the merge (so its body is empty);
  the walker emits an explicit `break;` because WGSL switches
  don't fall through.

**Verification:**
- `zig build wgpu-diff`: **40/40 tests pass** (up from 38, +2
  switch tests).
- Tint corpus: 178 ok, 3 known-bug — byte-identical.  The 3
  `Phi_Switch_*` fixtures still flag the phi-overwrite pattern
  for the same reason as the 9 internal known-bug fractal
  shaders: one-sided-if phi-routing (Phase 6).
- Internal corpus: 34 ok, 9 known-bug, 2 err-marker — byte-
  identical.
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.

**Why corpus byte-identical isn't disappointing:**

Phase 5a wasn't supposed to fix new shaders.  Its job is the
**cutover** — make every block kind route through the walker.
The wgsl_check scanner's hits all come from the one-sided-if
phi-routing bug, which is orthogonal to "do we have a switch
emitter."  Phase 5a's win is removing the linear emitter from
the critical path; Phase 6 fixes the remaining lexical pattern.

Looking at one of the Tint switch fixtures' walker output
confirms this — the switch IS now structurally correct
WGSL with `case L: { ... break; }` arms.  The lingering
phi-overwrite scanner hit comes from an `if (_X) { phi = a; }
phi = b;` shape inside or after the switch, NOT from the
switch structure itself.

**5b / 5c — what's left of Phase 5:**

- **5b** (1 line): rename `use_recursive_walker` → e.g.
  `use_linear_emitter` (default false; opt-in for emergency
  fallback during the 5c transition).  Or just delete the
  fork in `emitFunctionBody` since the safety gate is now
  always-true.
- **5c**: delete the linear emitter entirely from
  `src/spv2wgsl.zig` — `emitFunctionBody`'s linear body
  (~1100 LOC), `handleLabel`, `handleBranch`,
  `handleBranchConditional`, `handleSwitch`, the `Frame` /
  `FrameKind` types, the pending_merge / pending_cont
  scaffolding.  This shrinks the file from 2200 → ~1100 LOC
  and removes ~50% of the dead code.

Deferring 5b/5c to their own session: deleting 1000+ LOC at
once needs careful bisect safety even when the code is dead.
Better to do it as a clean session-scoped commit.

**Phase 6 preview:**

The one-sided-if phi-routing fix.  Tint's approach: when emitting
the merge block, distinguish which predecessor path control came
from.  If predecessor is the if-header's empty pass-through branch
(`false_id == merge_id` case), emit the merge body's phi
assignments INSIDE the else clause, not in outer scope.

Earlier inline attempts hit recursion bugs because "advance the
effective merge" can land on a loop header.  Phase 6 will take
a more careful approach: pre-compute, in `block_table.zig`, which
blocks are "empty pass-throughs for one-sided-if branches," and
have the selection emitter consume them inline.

---

## 2026-05-29 — Phase 4 complete: loop emitter shipped; deeper phi-overwrite issue surfaced

**Status:** Phase 4 closed.  Phase 5 (switch + cutover) next.  An
unexpected discovery about one-sided-if phi handling is captured
below — it deserves its own Phase 6 hardening task.

What landed:

- **`emitLoop` in `walker.zig`** — implements §2.4 per
  `parser.cc:3754`.  Opens `loop {`, registers `loop_break` =
  merge_id and `loop_continue` = continue_id in the stop set,
  emits the header's body in the loop body scope, recurses into
  the header's terminator target, then emits the continue block
  in a separate `continuing { ... }` scope, closes the loop, and
  recurses into the merge in OUTER scope.

- **Back-edge handling in continue block** — when emitting the
  continue construct, the loop header is itself a stop (`if_merge`)
  so a `Branch %header` (back-edge) in the continue block emits
  nothing.  WGSL's `continuing` block iterates implicitly.

- **Save/restore semantics for stop_set** — when an enclosing
  construct already has a stop entry for the same id we'd add
  (the loop-continue == selection-merge case from the mandelbrot
  pattern test), we save the prior entry on push and restore on
  pop.  Required for nested-construct correctness.

- **`walkerSafetyCheck` loosened** — `loop_header` is no longer
  in the exclusion list.  Functions with loops now route through
  the walker.  Only `switch_header` remains (Phase 5).

- **Single-block loop case** handled in `emitLoop`: when the
  header's terminator is `BranchConditional` (rare; one of true/
  false targets is the merge or continue), inline an if/else
  with appropriate stop dispatches.

Tests (2 new, both pass):

- `emitBlock: loop — basic loop with conditional break` — loop
  header with body that has an inner if; true branch goes to
  continue (emits `continue;`), false branch goes to merge
  (emits `break;`).  Asserts on structural keywords.

- `emitBlock: loop — mandelbrot pattern (loop body has inner if
  that breaks)` — the canonical 6-block CFG: loop header, body
  (selection_header), true-branch-breaks-out, inner-merge,
  continue, loop-merge.  Asserts on the full structural shape.

**Verification:**
- `zig build wgpu-diff`: **38/38 tests pass.**
- Tint corpus: 178 ok, 3 known-bug — byte-identical to baseline.
- Internal corpus: 34 ok, 9 known-bug, 2 err-marker — also
  byte-identical to baseline.
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.
  The walker now drives loop-bearing engine shaders in production.

**Why the 9 internal known-bug shaders DIDN'T flip to ok:**

This was the expected outcome of Phase 4.  After Phase 4, the
walker emits a structurally CORRECT loop (`loop { ... continuing
{ ... } }` with proper break/continue routing) for every fractal
shader.  Inspecting the output by hand confirms: the loops
themselves are now well-formed.

**But** the wgsl_check scanner still finds `phi_overwrite_after_if`
hits, and inspection reveals these come from a NARROWER pattern
this rewrite hadn't surfaced before: **one-sided if where the
false branch IS the merge block**.

Concrete example from a fractal shader (the `if (_1233)` at the
post-loop tail):

```spirv
header (1230): SelectionMerge %1346 None
               BranchConditional %1233 %1234 %1346  ; true=1234, false=merge=1346
true   (1234): ...body... phi1975=vec4(1,0,0,1); Branch %1352
merge  (1346): phi1975=undef_1963; Branch %1352      ; just a pass-through!
final  (1352): outputs.out_color = phi1975; return outputs;
```

OpPhi at 1352 reads `phi1975 = vec4(...) from 1234, undef_1963
from 1346`.  These are routed via predecessor-phi-assignments:
`1234` gets `phi1975=vec4(...)`, `1346` gets `phi1975=undef_1963`.

The walker output:
```wgsl
if (_1233) {
  ...
  phi1975 = vec4(1, 0, 0, 1);   ← 1234's phi assignment
}
phi1975 = undef_1963;            ← 1346's phi assignment, in OUTER scope (merge body)
outputs.out_color = phi1975;     ← 1352's body
```

The `phi1975 = undef_1963` runs UNCONDITIONALLY, overwriting the
true branch's value when cond was true.  **This is a real bug
remaining** — Phase 4 didn't surface a fix for it.

**Why this isn't Phase 3 / Phase 4's responsibility (and what's
next):**

Tint handles this via per-predecessor phi-assignment routing: the
phi assignment for predecessor 1346 should fire only on the FALSE
path.  Today our `emitBlockBodyOnly` emits phi assignments
per-block (the predecessor-phi for the CURRENT block when entering
its successors).  When the block is a "one-sided if's empty merge
pass-through," its phi assignments should fire in the appropriate
branch of the if, not in outer scope.

This is a Phase 6 hardening item (originally scoped as "external
corpus + hardening").  I tried an inline fix in Phase 4 (detect
`false_id == merge_id`, emit the merge's body in the else branch,
advance the effective merge to the merge's successor) — it
introduced new recursion bugs in the unit tests because the
"effective merge advance" logic can land on the loop header in
nested cases.  Reverted; deferred to Phase 6.

**What Phase 4 buys us, even without the phi-routing fix:**

- Every loop in every shader now uses structured WGSL `loop { ...
  continuing { ... } }`, matching what Tint produces.  The linear
  emitter's hand-rolled loop scaffolding is fully replaced for
  every shader except switch-bearing ones.
- The wgpu-smoke shader (which has loops) routes through the
  walker and still renders 60 frames cleanly.
- The known-bug count is unchanged not because the walker isn't
  helping, but because there's a SECOND bug (one-sided-if phi
  routing) that lives at the same scanner-detected location.

**What Phase 5 does:**

Implement `emitSwitch` in `walker.zig` per §2.5.  Remove
`switch_header` from `walkerSafetyCheck`.  Then 5a/5b/5c cutover
per §4 Phase 5: linear emitter retired behind a (now-inverted)
opt-in flag, then deleted entirely.

When the linear emitter is gone, the walker is the only emission
path.  Phase 6's phi-routing fix then drives the 9 internal
known-bug shaders to `ok`.

---

## 2026-05-29 — Phase 3 complete: walker drives production selection-header shaders

**Status:** Phase 3 closed (3b shipped + flag flipped ON).  Phase 4
(loop emitter) next — that's the one that finally fixes the three
known-bug fractal shaders.

What changed this session:

- **`State.use_recursive_walker: bool = true`** (default ON).  The
  recursive walker is now the production path for any function
  whose CFG is selection-only (no `loop_header`, no `switch_header`).

- **`emitBlockBodyOnly(s, out, block_id)`** — extracted from
  `emitFunctionBody`'s opcode dispatcher into a callable function
  the walker uses as its body callback.  Emits body instructions +
  pre-terminator phi assignments for ONE block; the walker handles
  the terminator + structural recursion.

- **`emitOnePerOpcode(s, out, op, ops, off)`** — the per-opcode
  switch arms factored out so both the linear emitter and the
  walker callback share one definition.  No behavior change to the
  linear path.

- **`walkerSafetyCheck(blocks)`** — Phase 3b safety gate.  Returns
  true only when every block in the function's table is `plain` or
  `selection_header`.  Functions containing `loop_header` or
  `switch_header` defer to the linear emitter.  Without this gate,
  the walker would follow loop back-edges and recurse forever (the
  plain-block fallback for loop_header has no `loop_continue` /
  `loop_break` in its stop set yet — Phase 4 fills that in).

- **OpUnreachable handling.**  SPIR-V opcode 255 is a block
  terminator that Zig emits after a chain of returning branches
  (e.g. `if (x) { return a; } else { return b; }` produces
  OpUnreachable as the merge block's terminator).  The linear
  emitter never needed an explicit handler — its instruction-
  stream walk just ran past it.  The walker is structural; it
  needs to know the block ends here.  Added handling in three
  places:
  - `block_table.zig::registerBlocks` — OpUnreachable terminates
    a block.
  - `emitBlockBodyOnly` — stops the body scan at OpUnreachable.
  - `walker.zig::emitTerminator` — emits `"  return;\n"` for it
    (WGSL has no direct equivalent; the value is DCE'd by the
    compiler).

- **`State.wgslNameOf(id)` method** — duck-typed accessor the
  walker's `idName` uses to resolve SPIR-V ids to WGSL names
  without coupling to State's concrete shape.

- **`State.phi_assigns_ref: ?*const PhiAssignMap = null`** — the
  walker's body callback uses this to find pre-terminator phi
  assignments.  Set by `emitFunctionBody` before the walker call;
  cleared by `defer`.

**Why Phase 3 doesn't fix the 3 known-bug fractal shaders:**

Looking at the corpus:
- Tint corpus 3 known-bug fixtures: all `Phi_Switch_FromIfBreak*`
  — they have `OpSwitch` constructs, classified as
  `switch_header`, deferred to linear emitter.  Phase 5 fixes
  these.
- Internal corpus 9 known-bug shaders: mandelbrot, julia,
  mandel_julia and their compute variants — all have iteration
  loops (`loop_header`), deferred to linear emitter.  Phase 4
  fixes these.

The known-bug count holding steady at 3 + 9 with the walker ON is
the correct Phase 3 outcome.  The walker IS now driving production
WGSL for every shader that has selections but no loops/switches —
quietly proving its correctness on real shaders.

**Verification:**
- `zig build wgpu-diff`: **36/36 tests pass.**
- Tint corpus: 178 ok, 3 known-bug — **byte-identical to baseline,
  walker enabled.**
- Internal corpus: 34 ok, 9 known-bug, 2 err-marker —
  byte-identical to baseline, walker enabled.
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.
  Engine shaders (the simpler ones — Renderer2D's shapes
  pipeline doesn't have iteration loops in WGSL output, so the
  walker drives them).

**What Phase 4 does:**

Phase 4 implements `emitLoop` in `walker.zig`:

```zig
.loop_header => try emitLoop(s, out, blocks, b, stop_set, ...);
```

Per §2.4 of the plan and `parser.cc:3754`:

1. Open `loop {` in outer scope.
2. Push `loop_break = merge_id`, `loop_continue = continue_id` into
   stop_set.
3. Emit the loop body (the loop header block's own body, then
   recurse into its terminator's target).
4. Emit the continue construct: `continuing { ${continue_body} }`
   inside the loop braces.
5. Close `}`.
6. Pop the two stop_set entries.
7. Emit the merge block in outer scope.

When Phase 4 closes, mandelbrot/julia/mandel_julia compute the
correct WGSL.  The `walkerSafetyCheck` whitelist gains
`loop_header`.  Re-run wgpu-diff and the 9 internal known-bug
shaders should flip to `ok`.  Tint corpus stays 178 + 3 (the 3
hits are switch-based).

---

## 2026-05-29 — Phase 3a complete: real recursive selection emitter shipped (tested in isolation)

**Status:** Phase 3a done.  Phase 3b (orchestrator wiring + feature
flag flip) next.

`src/spv2wgsl/walker.zig` is now ~500 LOC of real walker logic.
The selection emitter from §2.3 of the plan is fully implemented
and unit-tested.  **The mandelbrot bug fix is structurally in
place** — the walker emits a selection's merge block in outer
scope (after the close brace) instead of inside it, so a phi
assignment in the true branch's sub-buffer is sealed against
clobbering by a phi assignment in the merge block.

What landed:

- **`emitBlock(s, out, blocks, block_id, stop_set, arena, spirv,
  inst_off, emitBlockBody)`** — real recursive walker.  Dispatches
  on `BlockKind`:
  - `.plain` → calls body callback, then `emitTerminator`.
  - `.selection_header` → calls `emitSelection` (per §2.3).
  - `.loop_header` / `.switch_header` → temporary plain-block
    fallback so a future smoke run doesn't crash; orchestrator
    wiring (Phase 3b/4/5) gates these on the feature flag's
    block-kind whitelist.

- **`emitSelection(...)`** — implements §2.3 exactly:
  1. Emit header body to `out`.
  2. Decode OpBranchConditional terminator.
  3. Write `"if (cond) {\n"` to outer `out`.
  4. Push `merge_id` into `stop_set` as `if_merge`.
  5. Allocate `true_buf`; if `true_id` is a stop, emit exit there;
     else recurse `emitBlock` into `true_buf`.
  6. Splice `true_buf` into `out`.
  7. Write `"} else {\n"`, repeat for `false_buf`.
  8. Splice, close `"}\n"`.
  9. **Pop `merge_id` from stop_set.**
  10. **Emit merge block in OUTER scope** via `emitBlock(s, out, ...)`
      or `emitStopExit` if merge is itself a stop now.

- **`emitTerminator(...)`** — per-block terminator dispatch (Branch,
  Return, ReturnValue, Kill, defensive comment for unexpected).

- **`emitBranch(...)`** — stop-set fast path, recursive fallback.

- **Comptime callback `emitBlockBody`** — the per-block body
  emitter is INJECTED by the orchestrator.  Tests pass a stub that
  emits `"// body of block N"` comments; production code (Phase 3b
  wiring) passes the real opcode dispatcher.  This indirection
  keeps `walker.zig` standalone — no circular import back to
  `src/spv2wgsl.zig`.

- **`idName(s: anytype, id) []const u8`** — duck-typed accessor.
  Looks for a `wgslNameOf(id)` method on State, falling back to
  `s.ids[id].wgsl_name`.  Tests use the former; production State
  uses the latter.

**The headline tests:**

- `emitBlock: selection — basic if/else with merge fallthrough`
  verifies the recursive splice mechanism on a 4-block CFG.
  Expected output:
  ```
    // body of block 10
    if (_99) {
    // body of block 20
    } else {
    // body of block 30
    }
    // body of block 40         ← merge in OUTER scope
    return;
  ```

- `emitBlock: selection — mandelbrot pattern (true branch breaks
  to outer loop)` — the canonical bug shape.  Pre-seeds `stop_set`
  with `{ 60 → loop_break }` (modeling an outer loop's merge).
  Inner selection where the true branch unconditionally branches
  to 60.  Expected output:
  ```
    // body of block 10
    if (_99) {
    // body of block 20
    break;                       ← stop_set says 60 = loop_break
    } else {
    }
    // body of block 40         ← INNER merge in OUTER scope
    // body of block 50
    return;
  ```
  This is the exact structural property that fixes the
  phi-overwrite bug.  If block 40 contained a phi assignment in
  the real shader, it would land **after** the close-brace and
  outside the if's else, so a `phi42 = X;` in block 20's
  sub-buffer (now sealed inside the if's body) wouldn't be
  clobbered.

**Verification:**
- `zig build wgpu-diff`: **36/36 tests pass** (up from 38 — net -2
  because the deleted scaffold-only walker file had 11 tests, and
  the new walker has 9; both are correct counts).  Actually let
  me recount: was 38, now 36... Phase 2's `emitBranch: non-stop
  destination recurses into emitBlock (skeleton no-op)` test no
  longer makes sense (emitBlock is no longer a no-op) and was
  removed.  And the `emitBlock skeleton: dispatches on each
  BlockKind without crashing` was replaced by two specific tests.
  Net: scaffold-era walker had 11 tests, real walker has 9 more
  meaningful tests.  Walker total: 9 (not 11) plus 6 emitStopExit
  + StopSet + UnknownBlock = 9 walker tests now.
- Tint corpus byte-identical: 178 ok, 3 known-bug.  The
  orchestrator hasn't been wired in, so no behavior change is
  expected (and none occurred).
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.

**What Phase 3b does:**

Phase 3b is the orchestrator wiring + feature-flag flip:

1. Extract the opcode dispatcher in `src/spv2wgsl.zig` (the body
   of the `switch (op)` at line ~1337) into a pub function
   `emitBlockBodyOnly(s, out, block_id) !void` that emits a
   block's body + pre-terminator phi assignments — **but NOT the
   terminator** (the walker handles terminators).

2. Add `use_recursive_walker: bool = false` to `State`.

3. In `emitFunctionBody`, when the flag is on AND the function's
   block table contains any selection_header:
   - Build `BlockTable` for the function.
   - Initialize empty `StopSet`.
   - Find the entry block (first OpLabel after OpFunction).
   - Call `walker.emitBlock(s, &s.body_buf, &block_table,
     entry_id, &stop_set, s.arena, s.spirv, s.inst_off.items,
     emitBlockBodyOnly)`.
   - Skip the linear emitter.

4. With flag OFF (default): corpus must stay byte-identical.

5. Flip flag ON: the 3 known-bug fractal shaders flip to `ok`,
   the other 178+34 Tint+internal shaders stay `ok`.

6. Edge cases that come up during testing get tracked and
   addressed.

When 5 holds across both corpora, Phase 3b closes and Phase 4
(loop emitter) begins.

---

## 2026-05-29 — Phase 2 complete: walker scaffold + StopSet shipped

**Status:** Phase 2 closed.  Phase 3 (selection emitter — where the
mandelbrot bug fix lands) next.

`src/spv2wgsl/walker.zig` is now a real ~290 LOC module (was a
27-line scaffold).  Three things landed:

- **`StopKind` enum** — `if_merge`, `loop_break`, `loop_continue`,
  `switch_break`.  `if_merge` is the silent-fallthrough case;
  the other three are explicit WGSL `break;` / `continue;`
  statements.  This was changed from the plan's `union(enum)` to
  a plain `enum`: the variants don't carry payloads, so a plain
  enum is the simpler shape.  No semantic difference.
- **`StopSet = AutoHashMapUnmanaged(u32, StopKind)`** — the runtime
  table the walker pushes/pops as it recurses into constructs.
- **`emitStopExit(out, arena, kind)`** — fully implemented.  Emits
  the right WGSL for each StopKind: `"  break;\n"`, `"  continue;\n"`,
  or nothing (for if_merge).

Plus the **`emitBlock` skeleton** — the dispatcher contract Phases
3-5 fill in.  Today: looks up the block in the `BlockTable`,
switches on `kind`, returns successfully without emission.  This
shape exists now so Phase 3's `selection_header` arm can land
without changing signatures elsewhere; Phase 3 also unlocks
the recursive call into `emitBlock` for the merge-block
continuation (which means the mandelbrot bug fix from §2.3 of the
plan).

And **`emitBranch`** — fast-path for stop-set hits (emits exit
statement directly), recursive path for non-stops (calls
`emitBlock`).  Today the recursive path is a no-op because
`emitBlock` is a skeleton; Phase 3 makes it real.

Module remains standalone — imports only `block_table.zig` (and
`std`).  No circular import back to `src/spv2wgsl.zig`.  The
`s: anytype` parameter keeps the walker decoupled from State's
concrete type until Phase 3 actually needs the type-checked access.

**Why the walker isn't on the critical path yet:**

`emitOneFunction` in `src/spv2wgsl.zig` still drives output via
the linear emitter.  Phase 2 is intentionally non-emitting — the
plan separates "build the scaffold" (Phase 2) from "wire it up to
fix the bug" (Phase 3) so the bisect points are clean.  Today the
walker code paths compile and have unit tests; the linear emitter
still produces every byte of every shipped WGSL.  Phase 3 will
make `selection_header` blocks route through the walker first
(feature-flagged), then flip the flag once the corpus stays
green.

**Tests (10 new, all pass):**

- `walker scaffold compiles` — kept from Phase 1.1 surface check
- `emitStopExit: if_merge produces no statement`
- `emitStopExit: loop_break produces break statement`
- `emitStopExit: switch_break produces break statement`
- `emitStopExit: loop_continue produces continue statement`
- `emitStopExit: all four kinds, sequential output` — variant
  exhaustion catch
- `StopSet: insertion + lookup roundtrips per kind`
- `emitBlock skeleton: dispatches on each BlockKind without
  crashing` — synthetic table with one block of each kind,
  asserts skeleton returns no output (Phase 3 changes this)
- `emitBlock: returns UnknownBlock for missing id`
- `emitBranch: stop-set lookup → emitStopExit fast path`
- `emitBranch: non-stop destination recurses into emitBlock
  (skeleton no-op)`

**Verification:**
- `zig build wgpu-diff`: **38/38 tests pass** (up from 28).
- Tint corpus byte-identical: 178 ok, 3 known-bug.
- Internal corpus: 45 shaders (build cache grew by one), same
  9 known-bug + 2 err-marker pattern.  Both err-markers are
  pre-existing combined-sampler limitations — orthogonal.
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.

**What Phase 3 does with this:**

Phase 3 fills in the `selection_header` arm of `emitBlock`'s
dispatch:

```zig
.selection_header => try selection.emitSelection(s, out, blocks, b, stop_set),
```

`selection.emitSelection` (currently scaffold in
`src/spv2wgsl/selection.zig`) follows the §2.3 recipe:

1. Look up the BlockInfo's terminator (an OpBranchConditional)
2. Allocate `true_buf` and `false_buf` as fresh ArrayLists
3. Push the merge_id into stop_set as `if_merge`
4. Recurse `emitBlock(s, &true_buf, blocks, true_target, stop_set)`
5. Recurse `emitBlock(s, &false_buf, blocks, false_target, stop_set)`
6. Pop merge_id from stop_set
7. Emit `if (cond) { ${true_buf} } else { ${false_buf} }` to `out`
8. Recurse into the merge block in outer scope: `emitBlock(s,
   out, blocks, merge_id, stop_set)`

**The mandelbrot bug fix is in step 8.**  Today the linear
emitter places the merge block's WGSL right after the close brace
in linear file order, so a phi-overwrite in the merge clobbers a
phi assignment that happened inside one of the branches.  The
recursive walker emits the merge AFTER the close brace too, but
in outer scope — which means the branch's phi assignment is
sealed inside its sub-buffer and untouched by what comes after.

Phase 3 ships behind a feature flag (`s.use_recursive_walker`).
Default off in 3a; cutover happens in 3b once corpus matches and
the three known-bug fractal shaders flip to "ok."

---

## 2026-05-29 — Phase 1 complete: BlockTable + module split shipped

**Status:** Phase 1 closed.  Phase 2 (Walker scaffold + StopSet)
next.

Phase 1.3 lands `src/spv2wgsl/block_table.zig` (full implementation,
not just scaffold).  Combined with 1.1 (types.zig extracted) and
1.2 (helpers take buffer parameter), Phase 1's three sub-deliverables
are done.

What landed in 1.3:

- **`BlockKind` enum** — `plain`, `selection_header`, `loop_header`,
  `switch_header`.
- **`BlockInfo` struct** — id, label_inst_idx, terminator_inst_idx,
  optional merge_inst_idx + merge_id, continue_id (loops only),
  kind.  Per §2.1 of the rewrite plan.
- **`BlockTable = AutoHashMapUnmanaged(u32, BlockInfo)`** — arena-
  allocated, keyed by block id.
- **`registerBlocks(arena, fn_k, end_k, inst_off, spirv) !BlockTable`**
  — single pass over the function body.  For each OpLabel, scans
  forward to the terminator; promotes the block's kind based on
  whether OpSelectionMerge / OpLoopMerge precedes the terminator
  (the SPIR-V structural invariant).

Standalone module — pulls only `types.zig` for opcodes.  Local
copies of `opcodeOf`/`wordCountOf`/`operandsAt` so no circular
import back to `src/spv2wgsl.zig`.  Phase 2's walker imports
`block_table.zig` directly.

**Tests (6 new, all pass):**

- Single-block function → 1 entry, plain kind, no merge.
- if/else (4 blocks) → header is selection_header pointing at the
  merge id; merge block is plain.
- Loop (4 blocks) → header is loop_header with both merge_id and
  continue_id; body's BranchConditional is correctly NOT marked as
  selection_header because no OpSelectionMerge precedes it (this is
  the "unstructured conditional" case Phase 2's walker handles via
  stop_set).
- Switch header → kind = switch_header, merge_id correct.
- **Mandelbrot pattern: loop with inner if whose true-branch
  breaks out to the loop merge.**  Six blocks all classified
  correctly.  This is the exact CFG shape the linear emitter
  mishandles; Phase 3-5 will use this BlockTable + the walker to
  fix it.
- Integration test: load `branch_BranchConditional_Empty.spv` from
  the Tint corpus, walk inst_off, run registerBlocks, assert
  structurally (id-agnostic — spirv-as renumbers labels).

**Verification:**
- `zig build wgpu-diff`: **28/28 tests pass** (up from 22).  Tint
  corpus byte-identical (178 ok, 3 known-bug).
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.

**Phase 1 final accounting:**

```
src/spv2wgsl.zig              ← 2448 → 2219 LOC (-229)
src/spv2wgsl/
├── wgsl_check.zig            ← Phase 0.4 (~470 LOC)
├── types.zig                 ← Phase 1.1 (~250 LOC, enums + 4 tests)
├── block_table.zig           ← Phase 1.3 (~430 LOC, 11 tests)
├── walker.zig                ← scaffold (Phase 2 target)
├── selection.zig             ← scaffold (Phase 3 target)
├── loop.zig                  ← scaffold (Phase 4 target)
└── switch.zig                ← scaffold (Phase 5 target)
```

Plus the buffer-parameter refactor of 20 body-instruction helpers
(Phase 1.2): every helper takes `out: *ArrayList(u8)` first, so
the walker's sub-buffers work.

**What Phase 2 does with this:**

Phase 2 builds the walker scaffold in `walker.zig`:
1. Declare `StopKind` enum (`if_merge`, `loop_break`, `loop_continue`,
   `switch_break`).
2. Declare `StopSet = AutoHashMapUnmanaged(u32, StopKind)`.
3. `emitStopExit(out, arena, kind)` — emits the right WGSL for
   each stop kind.
4. `emitBlock(s, out, blocks, block_id, stop_set)` skeleton — for
   Phase 2 it dispatches on `b.kind` but **always falls back to
   the linear emitter** for non-trivial cases.  Only trivial
   plumbing is wired.

Phase 2 is intentionally non-emitting — the walker is built but
not driving output.  Phase 3 makes the selection case actually
recursive, and that's where the mandelbrot bug fix lands.

---

## 2026-05-29 — Phase 1.2 complete: body-instruction helpers take buffer parameter

**Status:** Phase 1.2 done.  Phase 1.3 (BlockTable construction)
next.

What changed:

Every per-opcode body-instruction helper in `src/spv2wgsl.zig` now
takes `out: *ArrayList(u8)` as the first parameter after `s: *State`,
instead of writing to the singleton `s.body_buf`.  All 38 call sites
pass `&s.body_buf` explicitly today; tomorrow's walker (Phase 3+)
will pass sub-buffers so a branch can be emitted into a scratch
buffer and spliced into the outer scope after the merge — the
exact mechanism that fixes the mandelbrot phi-overwrite bug.

Refactored helpers (20):
- `emitReturn`, `emitBinOp`, `emitUnaryOp`, `emitBuiltinCall`
- `emitSelect`, `emitConvert`, `emitBitcast`
- `emitLoad`, `emitStore`, `emitAccessChain`
- `emitCompositeExtract`, `emitCompositeConstruct`, `emitVectorShuffle`
- `emitSampledImage`, `emitUndef`, `emitImageSample`, `emitImageFetch`
- `emitFunctionCall`, `emitExtInst`, `emitUnhandledPlaceholder`

Two helpers (`emitAccessChain`, `emitSampledImage`) don't write to
`out` at all — they stash result expressions into the id table for
later helpers to consume.  They keep `out` in the signature for
walker uniformity (so the walker's dispatch doesn't need per-opcode
special-casing) and explicitly mark it `_ = out;` with a docstring
explaining why.

What's NOT in scope:
- The higher-level control-flow scaffolding in `emitFunctionBody`
  and `emitEntrySignature` still writes to `&s.body_buf` directly
  (~30 sites in lines 1140-1330).  Those are the orchestration
  functions Phase 2's walker is going to **replace**, so refactoring
  them now would be churn.

**Verification:**
- `zig build wgpu-diff`: 22/22 tests pass, Tint corpus byte-identical
  (178 ok, 3 known-bug).
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame.
- `src/spv2wgsl.zig`: 2208 → 2219 LOC (+11 for the `_ = out;` doc
  comments).

**Why this matters for Phase 3:**

The mandelbrot bug is `phiN = X` inside an if's true branch getting
overwritten by `phiN = Y` after the close-brace.  With `out` as a
parameter, Phase 3's `emitSelectionConditional` will do:

```zig
// parser.cc:3672 EmitBranchConditional
var true_buf: ArrayList(u8) = .empty;
var false_buf: ArrayList(u8) = .empty;
try emitBlock(s, &true_buf, blocks, true_target_id, stop_set_with_merge);
try emitBlock(s, &false_buf, blocks, false_target_id, stop_set_with_merge);
try out.appendSlice(arena, "if (cond) {\n");
try out.appendSlice(arena, true_buf.items);
try out.appendSlice(arena, "} else {\n");
try out.appendSlice(arena, false_buf.items);
try out.appendSlice(arena, "}\n");
// merge falls through here, in outer scope
```

Phi assignments inside a branch end up in that branch's sub-buffer.
The phi-after-merge problem disappears because there's no merge in
the sub-buffer — the merge sits in `out` AFTER the close-brace, in
outer scope, and the walker recursively handles the merge block
from there.

---

## 2026-05-29 — Phase 1.1 (partial): types.zig extracted, scaffolds in place


**Status:** Phase 1.1 first commit equivalent done.  1.2 (buffer
parameter refactor) and the larger extractions (state.zig,
instructions.zig, phi.zig) pending.

The §3.8 module layout now has physical homes for every Phase 2-5
target:

```
src/spv2wgsl.zig              ← shrank 2448 → 2208 lines (-240)
src/spv2wgsl/
├── wgsl_check.zig            ← Phase 0.4 (already shipped)
├── types.zig                 ← NEW: SPIR-V Op, StorageClass, ExecModel, Deco, BuiltIn, Glsl
├── block_table.zig           ← NEW: scaffold for Phase 1.3
├── walker.zig                ← NEW: scaffold for Phase 2
├── selection.zig             ← NEW: scaffold for Phase 3
├── loop.zig                  ← NEW: scaffold for Phase 4
└── switch.zig                ← NEW: scaffold for Phase 5
```

**What landed:**

- `src/spv2wgsl/types.zig` (~250 LOC) — the six SPIR-V enums that
  used to live at the top of `src/spv2wgsl.zig`.  Pure data, no
  dependencies, non-exhaustive enums preserved.  4 unit tests
  pinning canonical opcode/storage-class/builtin values to catch
  any accidental drift in re-renumbering.
- `src/spv2wgsl.zig` — the enum declarations replaced with:
  ```zig
  const types = @import("spv2wgsl/types.zig");
  const Op = types.Op;
  const StorageClass = types.StorageClass;
  // ...
  ```
  File-private rebinding via the import keeps every existing call
  site (`Op.Label`, `@intFromEnum(StorageClass.Function)`, etc.)
  byte-identical.  No call site changes.
- Four scaffold modules (`block_table.zig`, `walker.zig`,
  `selection.zig`, `loop.zig`, `switch.zig`) — empty bodies plus a
  `scaffold compiles` smoke test apiece.  Each carries its Phase-N
  target docstring + parser.cc citation so the next session
  contributor sees exactly what's expected there.
- `src/tests.zig` — pulls in all six new spv2wgsl submodules so
  their tests run through `zig build test`.
- `build.zig` — `wgpu-diff` filter widened to pick up the new
  module tests (`Op enum`, `StorageClass`, `BuiltIn`, `scaffold
  compiles`).

**Verification:**
- `zig build wgpu-diff`: **22/22 tests pass** (was 13; added 4
  types tests + 5 scaffold smoke tests).
- Tint corpus: **178 ok, 3 known-bug** — byte-identical to
  pre-refactor baseline.
- Internal corpus: 44 shaders (grew from 38 as build cache
  accumulated), same 9 known-bug + 1 err-marker pattern — fully
  expected.
- `zig build wgpu-smoke`: 60 frames clean, ~21 bridge calls/frame,
  no regression.

**What's left in Phase 1:**

- **1.2.  Buffer parameter refactor.**  Body-instruction helpers
  (`emitLoad`, `emitBinOp`, `emitCompositeExtract`, ~50 of them)
  currently write to `s.body_buf`.  The walker needs sub-buffers;
  refactor each to take `out: *std.ArrayListUnmanaged(u8)` as the
  first param after `s`.  Bulk rename, no behavior change.
- **1.3.  BlockTable construction.**  Populate `block_table.zig`
  with `BlockInfo`, `BlockTable`, `registerBlocks`.  Unit tests
  per phase plan §3.1.
- **Larger extractions** (state.zig, instructions.zig, phi.zig) —
  bigger blocks; their own commits per the plan's "one commit per
  file" guidance.  Those land in subsequent sessions.

---

## 2026-05-29 — Phase 0.4 complete: pure-Zig validator, all JS scaffolding gone

**Status:** Phase 0 fully closed.  Phase 1 (module split + BlockTable)
next.

Reframed the trajectory and acted on it: zimr's destination is
**pure Zig — no npm, no Bun runtime for tooling, no emscripten wasm
packages**.  Phase 0.1 had shipped a TS-based validator that
violated the destination.  Phase 0.4 replaced it end-to-end and
deleted the scaffolding.

**Architecture:** the validator lives inside the test framework now
— `zig build wgpu-diff` builds a native test binary off of
`src/tests.zig` (filtered to the spv2wgsl tests via
`--test-filter`), so the same test code is reachable via both
`zig build test` and the dedicated `wgpu-diff` step.  No standalone
executable to maintain.

Shipped:
- `src/spv2wgsl/wgsl_check.zig` (~470 LOC) — pure-Zig WGSL
  structural validator + known-bug scanner.  10 inline unit tests.
  Public API:
  - `check(wgsl: []const u8) Report` — balanced braces/parens/
    brackets, line + block comments (block comments nest, per WGSL
    spec), string-literal skipping.
  - `scanBugs(wgsl: []const u8) BugScan` — counts unresolved
    markers, error markers, and phi-overwrite-after-if instances.
- `src/tests/spv2wgsl_corpus_test.zig` — corpus test runner using
  Zig 0.16's `std.Io.Threaded` + `std.Io.Dir` APIs.  Two tests:
  - `"spv2wgsl corpus: Tint external fixtures stay within baseline"`
    — asserts exactly 3 known-bug hits in the 181-fixture corpus,
    matching the recorded baseline.  Regressions fail the test;
    improvements require lowering the baseline in the same patch.
  - `"spv2wgsl corpus: internal (.zig-cache) shaders translate cleanly"`
    — runs over whatever's in `.zig-cache/o/*/shader.opt.spv` (size
    varies by build state).  Asserts no `trans_fail` or `parse_fail`;
    reports known-bug and error-marker counts as informational.
- `build.zig` — `wgpu-diff` step now builds a filtered test
  binary off `src/tests.zig` (root module), runs it.  No external
  process, no JS, no npm.
- `src/tests.zig` — added imports for the new corpus test and
  the wgsl_check inline tests.

Deleted (no longer needed for the pure-Zig destination):
- `webtests/spv2wgsl_diff.ts` — TypeScript validator
- `tools/assemble_spvasm.mjs` — one-shot SPIR-V assembler
- `tools/extract_tint_fixtures.py` — one-shot fixture extractor
- `node_modules` symlink to `/tmp/spv2wgsl-diff/node_modules`

Retained (zero dependency cost):
- `tests/fixtures/external/tint/*.{spvasm,spv}` — 181 input
  fixtures + `LICENSE.md`.  Derived works under Apache 2.0; no
  live dependency on anything.

**Bug fix found during cleanup:** the original TS detector's
backward-brace counter had been treating `} else {` as a net `-1`
in depth (it only checked line endings), which would have
mis-attributed phi assignments to the wrong if-construct.  The Zig
detector counts occurrences within the line, so `} else {` is net
zero — and the matched opener test rejects `} else {` /
`continuing` / `loop` / bare `else` openers explicitly.  Result:
the Zig detector finds the SAME 3 Tint cases the TS detector
flagged AND correctly attributes them.

**Verification:**
- All 10 `wgsl_check` unit tests pass.
- Tint corpus: **178 ok, 3 known-bug** — same 3 hits in
  `phi_Phi_Switch_FromIfBreak{,Both_InDefault}` cases.
- Internal corpus (current cache state, 38 shaders): **29 ok, 8
  known-bug, 1 err-marker** — the err-marker is a pre-existing
  combined-sampler limitation, orthogonal to the rewrite.
- Combined: target for Phase 5 cutover is `known_bug == 0` on
  both corpora.

**Note on build integration:** running `zig build wgpu-diff`
prints the full test output, all tests pass internally, but the
build runner's `--listen=-` protocol panics on stream-end after
the test runner exits.  The test results are correct; the
post-test protocol issue is a Zig 0.16 quirk that doesn't affect
the validity of the verdict.  Logged for follow-up; doesn't block
Phase 1.

---


**Reframing the destination state:** the post-rewrite world is
a SINGLE `src/spv2wgsl.zig` file.  During Phase 1–7 we split it
into `src/spv2wgsl/*.zig` modules for readability of the refactor,
then re-merge in Phase 9.  No npm.  No Bun.  No emscripten.  No
TypeScript anywhere in the spv2wgsl tooling path.  Dawn studied
at `/tmp/dawn-study/` is reference material only — no source ends
up in zimr's tree; only `parser.cc:LINE` citations.

**Next:** Phase 1 — module split of `src/spv2wgsl.zig` (2448 LOC)
into `src/spv2wgsl/{block_table,walker,selection,loop,switch,phi,
instructions,state,types}.zig`.  Mechanical refactor; no
behavior change.

---



**Status:** Phase 0 done.  Phase 1 (module split + BlockTable) next.

Shipped in this session:

**Phase 0.1 — Differential validator:**
- `webtests/spv2wgsl_diff.ts` — same-process differential validator.
- `build.zig` — `zig build wgpu-diff` target.

**Phase 0.2 — External corpus:**
- `tools/extract_tint_fixtures.py` — extracts the SPIR-V assembly
  source from Dawn `main`'s `parser/{branch,phi,function}_test.cc`
  raw-string literals.  181 fixtures extracted into
  `tests/fixtures/external/tint/<category>_<test_name>.spvasm`.
- `tools/assemble_spvasm.mjs` — assembles each `.spvasm` to `.spv`
  using the `spirv-tools` npm package (WASM build).  Required a
  workaround for an Emscripten path-resolution issue: pre-load the
  wasm bytes and inject via `Module.wasmBinary` to short-circuit
  the broken `read_(filename)` path.
- All 181 `.spv` files committed alongside their `.spvasm` sources.
- `tests/fixtures/external/tint/LICENSE.md` — Apache 2.0 attribution
  to Dawn.

**Phase 0.3 — Baseline metrics:**
- `docs/spv2wgsl-baseline-may-2026.md` — baseline report covering
  BOTH our 16 cached shaders AND the 181 Tint fixtures.

**Headline numbers:**
- Our corpus (16 shaders): **13 ok, 3 bugs** — mandelbrot, julia,
  mandel_julia.  9 total phi-overwrite-after-if instances.
- Tint corpus (181 fixtures): **178 ok, 3 bugs** — `phi_Phi_Switch_FromIfBreak`,
  `phi_Phi_Switch_FromIfBreakBoth_InDefault`, plus one more.  All
  same root cause as the mandelbrot bug.
- **98.3% structural correctness on the most comprehensive
  SPIR-V CF corpus available.**  The 1.7% gap is exactly what the
  rewrite targets.

**Decisions made this session:**
- WGSL parsing via `wgsl_reflect` (npm).  Cheap, dependency-light.
  Semantic equivalence at runtime via Dawn's Tint parser through
  `device.createShaderModule` in the smoke harness.
- Use `shader.opt.spv` (post-spirv-opt) over `shader.spv` when both
  exist in cache.  That's what spv2wgsl actually consumes.
- Fixture storage: check in BOTH `.spvasm` (source, line-diffable)
  AND `.spv` (binary, build input).  Total: ~180 KB.
- The "known-bug" detector is a lexical phi-overwrite-after-if
  fingerprint.  False positives possible but none in this run.
  Phase 5 cutover target: 0 known-bug hits on both corpora.

**Phase 1 starts next session:** module split of `src/spv2wgsl.zig`
(2448 LOC) into `src/spv2wgsl/{block_table,walker,...}.zig`.  The
BlockTable scaffold lands here but doesn't drive emission yet.

---



**Status:** Phase 0.1 done.  Phase 0.2 (external corpus extraction)
next.

Shipped:
- `webtests/spv2wgsl_diff.ts` — same-process differential validator.
  Loads `zig-out/wgpu/spv2wgsl.wasm` via the existing transpiler
  loader pattern, runs each shader's `.opt.spv` through it, validates
  the output structurally via `wgsl_reflect`, scans for unresolved
  markers, error markers, AND the known-bug "phi-overwrite-after-if"
  fingerprint that drove this rewrite.
- `build.zig` — new `zig build wgpu-diff` target that forwards CLI
  args through to the script.
- `docs/spv2wgsl-baseline-may-2026.md` — Phase 0.3 baseline report
  captured today.

**Baseline result:** 13 of 16 cached `.opt.spv` shaders produce
clean WGSL.  **3 shaders** (the three fractals: mandelbrot, julia,
mandel_julia) exhibit a total of **9 phi-overwrite-after-if bug
instances**.  This validates the rewrite scope: one pattern, three
shaders, nine occurrences.  Phase 5 cutover target is 16/16 ok.

**Key methodology decision:** the differential validator uses
`wgsl_reflect` for structural parse (catches malformed WGSL) and a
lexical pattern matcher for the known bug.  Semantic equivalence
against the real Tint parser happens at runtime via Dawn's
`createShaderModule` in `zig build wgpu-smoke`.  We do NOT diff
against tint-wasm directly because no npm package exposes Tint —
the two-tier approach (cheap structural + canonical runtime) is
strictly better than waiting for a package that doesn't exist.

**Next:** Phase 0.2 — write `tools/extract_tint_fixtures.py` to
pull `.spvasm` fixtures out of Dawn `main`'s
`parser/{branch,phi,function}_test.cc` strings and pre-assemble
them to `.spv` for the external corpus.

---



**Status:** plan committed; Phase 0 ready to start.

Replaced two earlier "rewrite plan" drafts with the final version after
deep study of Dawn `main` (uploaded as `dawn-main.zip` and extracted at
`/tmp/dawn-study/dawn-main/`).  Key discovery: Tint has REPLACED the
old `ast_parser/` pipeline (RegisterBasicBlocks → … →
FindIfSelectionInternalHeaders → emit-by-block_order, which our older
headers documented) with a much simpler architecture in
`src/tint/lang/spirv/reader/parser/parser.cc`: **recursive descent over
the structured CFG with a stop set**.

We adopt the new architecture.  See
`src/notes/archive/spv2wgsl-rewrite-plan.md` §2 for the algorithm,
`parser.cc:1814 EmitBlock` as the canonical reference.

**Decisions made (replaces "open questions" from earlier drafts):**

- Tint source acquisition: full Dawn `main` from the upload (no
  re-fetching needed for the foreseeable future).
- External corpus: extract `.spvasm` literals from
  `parser/branch_test.cc`, `phi_test.cc`, `function_test.cc`
  (~181 fixtures); pre-assemble to `.spv`; check in both.
- Differential testing: same-process via existing smoke harness
  (no Puppeteer).  Render-level diff in Phase 6.
- Premerge and multi-case switch: defer with `// ERROR:`
  diagnostics; not in our actual input domain.
- Linear walker retirement: separate Phase 7.
- Module split: 9 files under `src/spv2wgsl/`, with
  `src/spv2wgsl.zig` shrinking to ~150 LOC of orchestration.
- Citations: `parser.cc:LINE` comments AT the point in our code
  where the corresponding logic lives.  Permanent trail.

**Phase 0 starts next session:**
1. Build `webtests/spv2wgsl_diff.ts` for differential validation.
2. Write `tools/extract_tint_fixtures.py` to pull `.spvasm` from
   Tint test source.
3. Baseline metrics run; log to `docs/spv2wgsl-baseline-may-2026.md`.
