# spv2wgsl: a Tint-style structured-IR rewrite for control flow + phi

Status: PROPOSED (Simon greenlit "bite the bullet, follow Tint" —
2026-05-30).  This is the spec; execution is phased (below) so the
corpus stays green throughout.

---

## 1.  Why — the current model is wrong, not just buggy

We lower OpPhi by **single-predecessor text assignment**: hoist
`var phiN`, register `phiN = value` at the one SPIR-V predecessor
block, flush at that block's terminator (`spv2wgsl.zig` ~1038–1092 +
`emitBlockBodyOnly` ~1315).  Every new control-flow shape has
revealed a new way this is wrong, each "fixed" by a new special case:

- **Phase 6** — one-sided-if: merge phis clobbered the live branch →
  `route_phi_inline` + `isTrivialPassthroughBlock` hack in
  `emitSelection`.
- **This session** — nested-merge-in-loop: the inner `if(i<max_iter)`
  TRUE branch ends in a nested `if` whose merge block is the true-side
  predecessor of the outer merge.  Our flush emits the outer merge's
  phi copy (`phi1209 = …`) only on the FALSE branch (walker.zig
  emits it once, at the literal predecessor).  On the iterating path
  `phi1209` keeps its zero-init value → `phi1209 == 147u` is false →
  **the loop breaks on iteration 1** → every pixel takes the
  `escaped==0` → black path → the fractal never renders.  The swirl
  works only because it has no loop and never hits this path.

Two bugs, one root cause.  `walker.zig` is now a pile of `StopSet`
kinds, `if_merge` stops, trivial-passthrough detection and
`route_phi_inline` branches — symptoms of a model that doesn't match
the problem.  Patching the next shape is a losing game.

## 2.  What Tint does (grounded in their source)

Reference: `/tmp/dawn-main/dawn-main/src/tint/lang/spirv/reader/parser/parser.cc`.

1. **OpPhi → block parameter.**  A merge is a `MultiInBlock` with
   params; the phi result IS a param.  (`EmitPhi`, `AddValue`.)
2. **Structured control instructions produce values.**  `If`/`Loop`/
   `Switch` have `Exits()`; each exit (`ExitIf`/`ExitLoop`/
   `ExitSwitch`/`Continue`/`NextIteration`/`BreakIf`) carries the phi
   values as **operands**.
3. **`Propagate` walks UP and pushes onto EVERY exit.**  When a value
   defined deep in nested constructs feeds an outer merge, Tint walks
   up the control tree; at each construct it does
   `for (auto exit : ctrl->Exits()) exit->PushOperand(src)`, and the
   value re-emerges as a block param in the parent scope.  (`Propagate`
   ~1229, `AddOperandToTerminator` / `PropagateTerm` ~2701.)
4. **Position-specialized handlers**: `EmitPhiInIfMerge`,
   `EmitPhiInSwitchMerge`, `EmitPhiInLoopHeader`, `EmitPhiInLoopBody`,
   `EmitPhiInLoopContinue`, `EmitPhiInLoopMerge`.  The loop header phi
   gets its initial value through the loop initializer and its
   iterated value through the continue/`NextIteration` — which is
   exactly the `continuing`-block phi dance we hand-rolled and got
   subtly wrong.
5. **Forward refs deferred**: a phi can name a value defined later;
   Tint fills those at end-of-block (`values_to_replace_`, comment
   ~79/1856).
6. **The IR validator** enforces that every inbound branch of a
   MultiInBlock supplies args matching the params.  Dropping a copy is
   not representable.

Key realization: even Tint's **WGSL writer lowers block params back to
hoisted `var` + per-branch assignments** — i.e. the *output shape* is
the same thing we already emit.  The robustness isn't in the output;
it's in the **IR invariant** (every exit edge carries the args),
enforced *before* the writer runs.  We don't need a fancier output —
we need that invariant.

## 3.  What we adopt — and what we deliberately DON'T

zimr's thesis (Simon's diagram): spv2wgsl *does not validate, does not
optimize* — the browser's Tint/naga does both on our output.  That
stays true and bounds the rewrite.

ADOPT (the part the browser can't fix for us):
- A small **structured IR** for the CFG skeleton: blocks with params,
  structured `If`/`Loop`/`Switch`, terminators that carry args.
- **Block-param phi lowering** with **`Propagate`-to-every-exit**.
- The **position-specialized loop phi handling** (header/body/
  continue/merge).

DO NOT build (the browser already does it on our WGSL):
- An optimizer / any optimization passes.
- A validator (we keep `wgsl_check` + the corpus gate; the browser is
  the real validator).
- The full Tint core IR with every instruction type and every lowering
  pass (atomics, strided arrays, texture rewrites, shader-IO, …).

So the leaf/straight-line instructions keep lowering to WGSL text via
the **existing id-table emitters** (they're correct — the swirl, a
real shader through the whole pipeline, renders perfectly at 119fps).
The IR's only job is the structured CFG + phi.

## 4.  The minimal IR (Zig sketch)

```zig
const Allocator = std.mem.Allocator;

const ValueRef = union(enum) {
    constant: u32,        // spirv id of an OpConstant (text-emitted)
    instr: u32,           // spirv id of a normal result (text-emitted)
    block_param: *Param,  // a lowered phi
    fn_param: u32,
};

const Param = struct {           // a lowered OpPhi
    phi_id: u32,                 // original spirv id → WGSL `var phiN`
    type_id: u32,
    block: *Block,
};

const Block = struct {
    params: []Param = &.{},      // phis at this merge
    body_block_id: u32,          // reuse existing text emitter for the body
    term: Terminator,
};

const Terminator = union(enum) {
    branch:        struct { target: *Block, args: []ValueRef },
    exit_if:       struct { parent: *If,     args: []ValueRef },
    exit_loop:     struct { parent: *Loop,   args: []ValueRef },
    exit_switch:   struct { parent: *Switch, args: []ValueRef },
    cont:          struct { parent: *Loop,   args: []ValueRef }, // -> continuing
    next_iter:     struct { parent: *Loop,   args: []ValueRef }, // -> header
    break_if:      struct { parent: *Loop, cond: u32, args: []ValueRef },
    ret, ret_value: u32, kill, unreachable,
};

const If     = struct { cond: u32, t: *Block, f: *Block, results: []Param, exits: []*Terminator };
const Loop   = struct { body: *Block, continuing: *Block, results: []Param, exits: []*Terminator };
const Switch = struct { selector: u32, cases: []Case, default: *Block, results: []Param, exits: []*Terminator };
```

`propagate(value, from_block)`: mirror Tint — walk up `from_block`'s
parent chain; at each `If`/`Loop`/`Switch`, push `value` onto every
entry in `.exits` and replace `value` with the new result param in the
parent scope; stop when `value` is in scope at the merge.

WGSL emission from the IR:
- declare `var phiN: T;` for every `Param`;
- emit each block body via the **existing** `emitBlockBodyOnly`
  (id-table text), then for the terminator emit one `phiN = arg;` per
  `(param, arg)` pair — for **every** exit, so both branches always
  assign;
- `If` → `if (cond) { t; <exit assigns> } else { f; <exit assigns> }`;
- `Loop` → `loop { body; <continue/break> continuing { <param assigns> } }`
  with the header params initialized before the loop and updated in
  `continuing` (the EmitPhiInLoopHeader/Continue rule).

## 5.  Phased migration (corpus stays green the whole way)

- **P0 — IR + builder, no output.**  Add `src/spv2wgsl/ir.zig`
  (types) + `src/spv2wgsl/ir_build.zig` (SPIR-V → IR using the
  existing `BlockTable` + `GetStructuredCFGAnalysis`-equivalent we
  already compute).  Cross-check the IR's structure against the
  current block table on the whole corpus.  Emits nothing yet.
- **P1 — IR emitter behind a flag.**  `-Dwalker=ir` routes pass4
  through the IR emitter; default stays the old walker.  Gate:
  `wgpu-check` clean on EVERY corpus shader under both walkers, and
  the mandelbrot itercount standalone renders a cardioid in-browser.
- **P2 — flip default to `ir`.**  Old walker kept behind
  `-Dwalker=legacy` for one cycle as a fallback.
- **P3 — delete the legacy walker.**  Remove `StopSet`, `if_merge`,
  `route_phi_inline`, `isTrivialPassthroughBlock`, and the per-pred
  phi flush.  `walker.zig` shrinks to the IR build + emit.

Rollback at any phase = flip the flag.  Never a red corpus.

## 6.  Effort / risk — honest

- This is a **multi-session** change: CFG reconstruction + phi is the
  hard core of any SPIR-V reader.  But it's **bounded** — we're
  copying a proven design, scoped to CFG/phi, reusing the working
  straight-line emitters, and we don't touch the type/decoration
  passes (passes 1–3) at all.
- Biggest risk is the **loop header/continue phi** routing (Tint
  splits it across header-init + continue-update).  Mitigation: P1's
  dual-walker corpus diff catches any divergence shader-by-shader, and
  the itercount standalone is the in-browser truth check.
- Optional de-risking first step (recommended, ~5 lines, 1 build):
  before committing to the rewrite, patch `emitSelection` to also
  emit the outer-merge phi copy at the end of the TRUE branch and
  confirm the mandelbrot renders in-browser.  Proving the root cause
  end-to-end makes the rewrite a confident refactor rather than a
  hopeful one.  (Then throw the patch away and do P0–P3 properly.)

## 7.  Reference index (Tint files worth re-reading per phase)

- CFG + phi core: `lang/spirv/reader/parser/parser.cc`
  - `Propagate` ~1229, `AddOperandToTerminator`/`PropagateTerm` ~2701
  - `EmitPhi` ~2625, `EmitPhiInIfMerge`, `EmitPhiInLoop*` ~2663+
  - loop header/continue phi handling ~1856–1990
- IR shapes we're mirroring: `lang/core/ir/{block,multi_in_block,if,
  loop,switch,exit_if,exit_loop,exit_switch,continue,next_iteration,
  break_if}.h`
- WGSL writer (how block params become hoisted vars again):
  `lang/wgsl/writer/`

---

## 8.  Progress

### P0, step 1 — `src/spv2wgsl/ir.zig` landed (2026-05-30)

The structured-IR **type model + validator** is in, lint-clean, wired
into the spv2wgsl test root (`pub const ir = @import(...)` +
`test { _ = ir; }`), and green:

- Types: `Param`, `Block`/`Item`, `Terminator` (`exit_if`/
  `exit_switch`/`exit_loop`/`cont`/`break_if`/`branch`/`ret`/…),
  `If`/`Loop`/`Switch`/`Case`, `FnBody`.
- `validate(body)` — walks the tree tracking the enclosing-construct
  scope and asserts **every exit edge supplies exactly as many phi
  args as its target construct declares params**.  This is the
  invariant that makes the legacy dropped-copy bug *unrepresentable*.
- Tests (4/4 pass standalone + in-suite): build the mandelbrot's exact
  failing shape AS IR (loop ⊃ if(i<limit) ⊃ if(i<max) ⊃ if(!escaped),
  so the outer merge's true-side predecessor is an inner merge).  One
  test asserts `validate` ACCEPTS the well-formed shape; another
  asserts it REJECTS the shape where the inner if's TRUE branch drops
  its phi args (`error.PhiArityMismatch`) — i.e. the validator catches
  the precise defect that broke the fractal.

**Design refinement discovered while writing it:** because we emit
phis as **hoisted `var phi{id}` at function scope**, every value is
always in scope — so we do NOT need Tint's multi-level `Propagate`
(which exists to bring a block-scoped SSA value into an outer scope).
What we need, and what the legacy model lacked, is **explicit
per-construct exits** so the emitter assigns each construct's result
phis on *every* exit edge, plus the `validate` guard above.  A chain
of merges (inner-phi → outer-phi, each a hoisted var assigned at its
own construct's exits) handles arbitrarily deep nesting with no
propagation pass.  This shrinks the rewrite meaningfully.

Next: **P0 step 2** — `src/spv2wgsl/ir_build.zig` (SPIR-V → IR using
the existing `BlockTable`), cross-checked structurally against the
block table on the whole corpus, still emitting nothing.

### Note: pre-existing lint debt in the received tree

`zig build lint-check` reports ~554 issues across 216 files (467 in
`src/`, 188 in `examples/`, 33 in `build.zig`) — all pre-existing in
the uploaded snapshot, none introduced here (`ir.zig` = 0 hits).  The
operative audit gate `./scripts/timed-build.sh wgpu-check` is green
(26 shaders transpile cleanly, no regressions, smoke passes).  Flagged
for Simon; not touched (out of scope for the rewrite, and risky to
mass-edit code we're not changing).

### P0, step 2 — `src/spv2wgsl/ir_build.zig` started (2026-05-30)

Entry point landed: `build(arena, fn_k, end_k, inst_off, spirv)
!ir.FnBody`, consuming the same flat instruction index as the legacy
walker plus `block_table.registerBlocks` metadata.  The reconstruction
algorithm (mirror the legacy traversal, retargeted to build IR; attach
phi args at every construct exit) is documented at the top of the
file.

Implemented + tested this increment:
- the straight-line **base case** (a single plain block → `FnBody{
  entry: Block{ body, terminator } }`), with `mapTerminator` covering
  `ret`/`ret_value`/`kill`;
- control-flow shapes return `error.IrBuildUnsupported` — explicit, so
  the P1 `-Dwalker=ir` flag can fall back to the legacy walker rather
  than emit something wrong;
- 2 tests (self-contained synthesized SPIR-V): the base case lowers
  and passes `ir.validate`; an if/else function surfaces
  `IrBuildUnsupported`.
Lint-clean (0 hits); `wgpu-check` green; both new modules wired into
the test root.

Next increment: **selection (`If`) reconstruction with phi attachment**
— recurse the true/false branch blocks stopping at the merge, read the
merge's OpPhis into `If.results`, and append each (value, pred) to the
matching exit's args so the phi lands on both branches (the fix for
the mandelbrot bug).  Then loops (header/continue/merge phis), then
switches.

### Lint-debt cleanup — `spv2wgsl.zig` in progress (2026-05-30)

**UPDATE:** `src/spv2wgsl.zig` is now **fully lint-clean (272 → 0)**.
Every emitter (types, constants, module vars, all pass-4 function/
opcode helpers, access-chain, composite/shuffle/image/ext-inst,
convertSpirvToWgsl, checkOutputClosure, and the test block) now has
explicit local type annotations, block-braced branches, multiline
3+-param signatures, and wrapped match-arms / long lines.  All 37
spv2wgsl tests pass; wgpu-check green.  Project-wide lint: **496 →
224**.  Remaining debt (224) is in other files — next targets by
count: `build.zig` (33), `src/wgpu.zig` (24),
`src/shader_runtime_wgpu.zig` (21), `src/render_pass.zig` (10),
`src/wgpu_smoke_test.zig` (9), `src/shader_compile.zig` (9),
`examples/sw_fractal_gallery.zig` (9), then a long tail.  Method
unchanged: read each file, reverbosify in the explicit style, loop
fmt+lint+gate until stable.

Per Simon's directive (lint is now an in-scope hard gate; the rules
are a forcing function to read + reverbosify the code, not mechanical
noise to suppress).  Working the file top-down in coherent function
groups; each group: read it, add explicit local type annotations,
brace all branch bodies, break 3+-param signatures and any >120-col
lines (restructuring with locals / wrapped match-arms — NOT by
deleting annotations), then re-run `zig fmt` + lint + the wgpu-check
gate in a loop until that section is stable.

Baseline was **496 issues / 216 files** (290 untyped-local, 80
branch-braces, 30 fn-args-multiline, 8 line-length, 6 module-var);
**251 of them in `src/spv2wgsl.zig`** (the rewrite's home file, so
highest value).  Progress on `spv2wgsl.zig`: **272 → 164** local
issues cleared so far (passes 3 + 4: all type/constant/module-var
emitters, `pass4_functions`, `emitOneFunction`, `hasEntryOutputs`,
`emitEntrySignature`, `emitIoField`, `emitBlockBodyOnly`,
`emitOnePerOpcode`, `emitFunctionBody`).  Remaining ~164 are in the
per-opcode emit helpers (lines ~1700–2100) and the test block.
wgpu-check stays green and all 37 spv2wgsl tests pass at every
checkpoint.

Note: `zig test src/spv2wgsl.zig` exits non-zero because test 6
(`checkOutputClosure catches undeclared reference`) deliberately
exercises the error path and logs one `std.log.err` diagnostic; the
test itself passes (37/37 OK).  This is by-design and predates the
cleanup — the suite is green.

### Lint scan was non-recursive — STRUCTURAL FIX (2026-05-30)

Investigated why ~hundreds of lint issues accumulated despite the
default `zig build` being lint-gated (turn 382).  Root cause: the
`lint_run` file-collection in `build.zig` used a NON-recursive
`dir.iterate()` over `src/` and `examples/`, so it only linted the 49
top-level `src/*.zig` files and SILENTLY skipped every subdirectory —
`src/spv2wgsl/*.zig` (the whole transpiler engine!), `src/shaders/*`,
`examples/wgpu_demo/*`.  `zig build` stayed green while debt piled up
in the unscanned dirs.

Fix: switched the scan to a recursive `dir.walk()` (excluding only
`tests/` and `notes/staging/` by path prefix).  The scan now covers
all 263 source files at any depth.  TRUE baseline revealed: **470
issues / 263 files** (vs the old scan's falsely-low ~224).  This is a
permanent structural fix — subdir debt can never silently accumulate
again, and the gate now genuinely guards the whole tree (build.zig +
shaders + every src subdir).

Also fixed a self-inflicted error: I'd earlier reported `ir.zig` /
`ir_build.zig` as "0 lint issues", but that was a STALE mtime-cache
stamp (the linter caches clean results under
`tools/.zig-cache/lint-stamps/` and skips re-linting on an mtime
match).  Re-checked cold: they had 32 + 15 real issues.  Both now
genuinely clean (annotated, braced, multiline sigs; 4 + 17 tests
still pass).  Both gotchas (recursive-scan requirement, stale-stamp
trap) are now documented in `src/notes/claude.md`.

Cleared so far: `spv2wgsl.zig` (272→0), `ir.zig`, `ir_build.zig`.
Remaining ~423, biggest: `walker.zig` (~92), `block_table.zig` (~56),
`wgsl_check.zig` (~31), `build.zig` (~31), `src/wgpu.zig` (~24),
`shader_runtime_wgpu.zig` (~21).

### Lint cleanup progress — whole spv2wgsl engine clean (2026-05-30)

The entire `src/spv2wgsl/` directory (10 files) + `src/spv2wgsl.zig`
are now lint-clean.  Cleared this pass: `walker.zig` (92→0),
`block_table.zig` (56→0), `wgsl_check.zig` (31→0), on top of the
earlier `spv2wgsl.zig` (272→0), `ir.zig`, `ir_build.zig`.  Project
total: **470 → 244**.

Refactors made along the way (the verbosity rules as a forcing
function to actually improve the code, per Simon):
- `walker.zig`: inlined `isEntry` (single use) into `emitReturnLine`;
  inlined `wordCountOf` (single use) into `operandsAt`; replaced
  `endsWithStmt` with `endsWithTerminator` that encapsulates the
  repeated 4-way break/return/continue/discard check (two 4-line
  boolean blobs → single calls); named `BuiltSpirv`/`SynthInstruction`
  types for the test helper's anon-struct return.
- `block_table.zig`: inlined `wordCountOf` into `operandsAt` (same as
  walker, for consistency); named `BuiltSpirv`/`SynthInstruction`.
- `wgsl_check.zig`: **perf fix** — `trimLine` took its line-offset
  table by value as `[4096]usize` (a 32 KB copy on every call, in an
  O(lines²) backward scan); changed to a `[]const usize` slice.

All tests green at each step (walker 24, block_table 11, wgsl_check
10), wgpu-check green throughout.  Remaining ~244 is outside the
engine: `src/shader_runtime_wgpu.zig` (32), `build.zig` (32),
`src/wgpu.zig` (24), `shader_introspect.zig` (16), `pipeline_cache.zig`
(15), `gpu_iface.zig` (14), then a tail.

### GLSL-path `zig build test` breakage — root-caused + un-blocked (2026-05-30)

`zig build test` was RED on arrival (verified in the untouched upload
baseline at /tmp/zimr_baseline — NOT a regression).  Root cause: four
consumers `@embedFile` engine GLSL outputs that the build deliberately
never generates because their `.zig` sources are in the
`old_3d_shaders` skip-list (the dying WebGL2/GLSL 3D path):
- src/rlgl.zig:1981  → default_vs.glsl  (+ default_fs.glsl)
- src/render.zig     → lambert/pbr/shadow/skybox/unlit _vs/_fs .glsl
- examples/typed_unlit_demo.zig:87 → unlit_vs.glsl
The unresolved anonymous import surfaced as a cryptic per-file
`FileNotFound` that ABORTED the whole build before any test ran,
masking the entire example suite's typecheck.

Structural fix (build.zig): in the `is_old` skip branch, instead of a
bare `continue`, wire the shader's `<name>.glsl` import to a marked
placeholder `src/shaders/_deleted_glsl_placeholder.glsl` (on zimr_mod,
zimr_mod_smoke, AND the engine_shaders list so examples get it too).
This is a gravestone, not a revival — the shaders are still dead; the
placeholder just lets the rest of the suite build so real failures
aren't masked.  Result: `zig build test` went from "aborts, 0 tests
run" to **253/255 steps, 1800/1801 tests pass**.

Remaining: ONE latent runtime failure now exposed —
`rlsw_shader.test.rasterizeTriangles draws a clip-space full-screen
triangle` (rlsw_shader.zig:605, green-channel probe).  rlsw is the
LIVE software renderer (not doomed), so this deserves a real fix, but
it is PRE-EXISTING (identical in baseline, just never reached before)
and orthogonal to the lint/migration work — tracked for a dedicated
look.  The `spv2wgsl: id %N redefined` lines in that test's output are
warnings, not the failure.

Proper long-term direction unchanged: migrate rlgl/render 3D + the
GLSL examples to wgpu/WGSL, then delete the GLSL generation, the
skip-list, and this placeholder wholesale.

### Lint cleanup arc COMPLETE — 0 issues / 263 files (2026-05-30)

`zig build lint-check` is clean across the ENTIRE tree (cold):
470 → 0.  `wgpu-check` green, `zig build test` unchanged at 1800/1801
(the one failure is the pre-existing rlsw rasterization bug, not a
lint regression).  The recursive-scan fix + this cleanup mean the
whole project now actually passes its own style gate, and `zig build`
(lint-gated) is green on the style axis.

Files cleared this session (each: lint 0 + gate green, tests where
testable): spv2wgsl.zig (272), walker.zig (92), block_table.zig (56),
shader_runtime_wgpu.zig (32), build.zig (32), wgsl_check.zig (31),
wgpu.zig (24), shader_introspect.zig (16), pipeline_cache.zig (15),
gpu_iface.zig (14), wgpu_demo.zig (11), render_pass.zig (10),
wgpu_smoke_test.zig (9), shader_compile.zig (9), renderer_2d.zig (9),
sw_fractal_gallery.zig (9), wgpu_texture.zig (8), pbr_fs.zig (7),
spv2wgsl_wasm.zig (6), bind_group_cache.zig (6), compute_pass.zig (5),
ir.zig, ir_build.zig, descriptor_encoder.zig, and a tail of 1-3-issue
files.

Notable improvements beyond annotation: Carmack inlines (isEntry,
wordCountOf ×2, hotCombos2D table collapse), trimLine 32 KB-by-value →
slice perf fix, clamp-pattern → std.math.clamp.  The gate caught two
of my own slips mid-sweep (a u4 narrowing cast in pipeline_cache, an
array-vs-slice annotation in shader_runtime_wgpu) — exactly why it
runs per file.

### P0 step 2 — `If` reconstruction algorithm, grounded in Tint (2026-05-30, resumed)

Re-read the plan + `ir.zig`/`ir_build.zig` + the Tint phi handlers
(`parser.cc` EmitPhiInIfMerge ~3004, EmitPhiInLoopMerge ~2746,
EmitPhiInLoopHeader ~2920, AddOperandToTerminator ~2701).  The exact
algorithm for the next increment (selection / `If`):

GIVEN a `selection_header` block H with OpBranchConditional(cond,
true_id, false_id) and merge M = H.merge_id:

1. Emit H's own body as a `body` item (everything between OpLabel and
   the SelectionMerge/BranchConditional).
2. Build the TRUE branch: starting at true_id, recurse the sub-CFG,
   STOPPING at M (M is a walk-stop for this construct).  The branch's
   final block gets terminator `exit_if{ args: [] }` (args filled in
   step 4).  Same for FALSE branch from false_id.
   - If true_id == M (or false_id == M): that branch is empty — its
     `Block` is just `{ items: [], term: exit_if{} }`.
3. Read M's OpPhis → `If.results` (one `Param{ phi_id, type_id }`
   each, in OpPhi source order).  This fixes the param COUNT that
   `validate` checks every exit against.
4. For each OpPhi, for each (value_id, pred_blk_id) operand pair
   (operands are [type, result, (val,pred)+], pred at odd indices):
   - pred_blk_id names the SPIR-V block that branches to M on that
     path.  Find the IR block/terminator for that pred and APPEND
     value_id to its `exit_if.args`.  After recursion the relevant
     terminator is the `exit_if` of THIS `If` (Tint asserts exactly
     this — the ExitIf's ControlInstruction == ctrl).
   - SPECIAL CASE (Tint's `blk_id == header_id`): the pred IS H
     itself → the branch went H→M directly (the empty-branch side).
     Attach value_id to whichever branch terminator currently has
     FEWER args (Tint's heuristic: the empty/default branch).
   - The hard nested case (the mandelbrot bug): pred_blk_id is an
     INNER merge block, not true_id/false_id directly.  Because we
     recurse the whole branch sub-CFG and every leaf that targets M
     ends in `exit_if` of THIS If, appending to "the terminator for
     pred_blk_id" lands the arg on the correct exit regardless of
     nesting depth.  This is the whole point: the arg is attached per
     EXIT EDGE, so both branches always assign → no dropped copy.
5. After the If, CONTINUE from M in the parent scope (M becomes the
   next item / terminator chain in H's enclosing block) — M is
   emitted ONCE, in the parent, exactly as the §2.3 recipe wants.

IMPLEMENTATION SHAPE (mirrors legacy walker dispatch but builds IR):
need a recursive `buildBlock(start_id, stop_id) !*ir.Block` that
walks plain blocks accumulating `body` items + nested constructs,
stopping when it reaches stop_id (returns up so the parent emits the
stop block).  A `pred_blk_id → *ir.Block` (the leaf block whose
terminator should carry that pred's phi arg) lookup is needed for
step 4 — simplest: as we build, record every block we create keyed by
its SPIR-V id, then in step 4 map pred_blk_id → that block's
`*Terminator` and append.  The terminator must already be the
`exit_if` for M (guaranteed if we set exit_if on every leaf that
branches to M during recursion).

Forward-ref nuance (Tint values_to_replace_): a phi value_id can name
an instruction defined later; in OUR model values are raw ids resolved
at emit time by the id table, so there is NO forward-ref problem at
build time — we just store the id.  (Another simplification from the
hoisted-var approach.)

NEXT ACTION: implement `buildBlock` + `If` reconstruction in
ir_build.zig (remove the `IrBuildUnsupported` for the single-selection
case), add tests: (a) a simple diamond if/else with a merge phi →
validate accepts + both exit_if args populated; (b) the one-sided if
(true_id==merge) → empty branch gets the phi via the default-block
path; (c) the nested-merge shape (mandelbrot's) → the outer merge phi
arg lands on BOTH the inner-merge exit and the other branch.  Keep
loops/switches on IrBuildUnsupported for the increment after.

### P0 step 2 — `If` reconstruction LANDED (2026-05-30)

`ir_build.zig` now reconstructs structured `If` from
`selection_header` blocks, with the dropped-copy fix built in.
Implemented:
- A `Builder` context (arena, table, inst_off, spirv, + `by_id`:
  SPIR-V-block-id → built `*ir.Block`, mirroring Tint's
  `spirv_id_to_block_`).
- Recursive `buildBlock(start_id, stop_id)`: walks plain blocks
  accumulating `body` items, dispatches `selection_header` →
  `buildIf`, stops at the enclosing merge.  Continues from a
  construct's merge in the PARENT (the §2.3 "merge emitted once in
  parent" recipe — verified: a one-sided if lowers to
  `[body H, If, body merge]` + the merge's own terminator).
- `buildIf`: builds both branches (`buildBranch`, which yields an
  empty block ending in `exit_if{}` when the branch IS the merge),
  reads the merge's OpPhis into `If.results`, and `attachIfMergePhis`
  pushes each phi value onto the exit terminator of its predecessor's
  IR block via `by_id` — so the phi lands on EVERY exit edge.  The
  header-direct (`pred == header_id`) one-sided case attaches to the
  branch with fewer args (Tint's default-block rule).
- Loops + switches + unstructured conditionals still return
  `IrBuildUnsupported` (next increments).

Tests (19/19 pass, lint 0, wgpu-check green, project still 0):
- one-sided if (no phi) → `[body, If, body merge]`, both exits 0-arg;
- diamond if/else with a merge phi → `If.results=[phi20]`, true exit
  args=[21], false exit args=[22] (the phi on BOTH branches — the
  exact dropped-copy fix), `ir.validate` accepts;
- loop → still `IrBuildUnsupported`.

NEXT: loop reconstruction (header_params from loop-header OpPhis,
body recursion stopping at continue+merge, `cont`/`break_if` exits,
continuing-block param updates — EmitPhiInLoopHeader/Body/Continue/
Merge in parser.cc ~2746-2990).  Then switches.  Then P1 (the
`-Dwalker=ir` emitter behind a flag).

### P0 step 2 — Loop reconstruction (no-phi) LANDED (2026-05-30)

`ir_build.zig` now reconstructs `Loop` from `loop_header` blocks.  The
single-`stop_id` param of `buildBlock` was generalized to a **stop
stack** (`StopStack`: a fixed array of `(target_id, ExitKind)`, innermost
-first lookup) — mirroring the legacy walker's `StopSet`/`StopKind` but
as IR terminator tags.  This is what lets a branch resolve to the right
exit (`exit_if` / `exit_loop` / `cont`) by the NEAREST enclosing
construct, including a break that sits inside a nested `if`.

Implemented:
- `buildLoop`: pushes `(merge, exit_loop)` + `(continue, cont)` while
  building the body; builds the continuing block via `buildContinuing`
  (its back-edge `Branch %header` becomes a plain `branch` terminator —
  the implicit WGSL loop iteration).
- `buildUnstructuredCond` + `buildCondTarget`: the in-loop iteration
  check shape (`OpBranchConditional` on a PLAIN block, no
  SelectionMerge) → an `If` whose targets resolve against the stop
  stack; the block is `unreach` after (both branches transfer control).
- `If` branch recursion now also goes through the stop stack (push
  `(merge, exit_if)`), so a break/continue inside an if-branch resolves
  correctly.

DEFERRED to the next sub-increment (return `IrBuildUnsupported`, caller
falls back to legacy walker): loops whose HEADER or MERGE declares
OpPhis (the loop-carried-value dance — `header_params`, `cont` args,
loop-merge `results`), and single-block loops (continue == header).

Tests (21/21 pass, lint 0, wgpu-check green, project still 0):
- simple no-phi loop → `Loop{ body ends in cont, continuing ends in
  branch %header }`;
- **the mandelbrot break-out-of-loop pattern** (loop ⊃ inner if whose
  TRUE branch branches to the LOOP MERGE) → the nested break correctly
  becomes `exit_loop` (not `exit_if`), proving the stop-stack resolves
  the break by the right enclosing construct.  This is the exact CFG
  shape whose phi handling broke the fractal;
- a loop with a header OpPhi → still `IrBuildUnsupported` (deferred).

NEXT: loop-carried phis — read loop-header OpPhis into `header_params`
(init before loop + update from each `cont` edge's args), loop-merge
OpPhis into `results` (attach on `exit_loop`/`break_if` edges).  Then
switches.  Then P1 (`-Dwalker=ir` emitter behind a flag) — at which
point the mandelbrot can render end-to-end through the IR path.

### Labeled break/continue — NON-ISSUE (verified empirically 2026-05-30)

Concern: WGSL has only UNLABELED `break`/`continue` (innermost loop/
switch).  If our input SPIR-V ever contained a branch to a NON-innermost
construct's merge (a labeled break to an outer loop), the IR would build
correctly but be unemittable as WGSL → silent miscompile.

Tested the worst case through zimr's EXACT toolchain (`zig build-obj
-target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld` — the
NATIVE SPIR-V backend, not LLVM): three nested loops with `break :outer`
to the outermost, `continue :mid` to the middle, and `break :mid` from
INSIDE a switch.  Dumped with `tools/zspv --dump` and traced every
terminator.

RESULT: **Zig's native SPIR-V backend fully desugars labeled control
flow.**  Every single branch target is the merge/continue of the
INNERMOST enclosing construct — zero cross-level jumps.  A labeled break
becomes: inner construct breaks to its OWN merge normally, then a
flag-check AFTER that construct (when it is no longer open) propagates
the exit one level up, where the next loop is now innermost.  The
switch break lands on the switch's own merge; nothing exits the switch
directly.  `spirv-opt` accepts the module (well-formed structured CFG).

IMPLICATION: our stop-stack innermost-first lookup is EXACTLY matched to
the input.  We need NO guard-variable lowering pass and NO labeled-exit
handling — Zig did that lowering upstream.  The `break_if` terminator is
still used (loop-iteration-check shape), but not for labeled exits.

CAVEAT (one assumption to preserve): this holds for Zig-sourced shaders
through Zig's native SPIR-V backend — zimr's ENTIRE shader pipeline, so
we are fully covered.  It would NOT necessarily hold for arbitrary
hand-written / third-party SPIR-V (some producers emit less-structured
CFGs).  zimr only ever feeds its own Zig shaders through spv2wgsl, so
this is safe; do not point ir_build at foreign SPIR-V without revisiting.

### Loop-carried phis — confirmed shape from real mandelbrot + Tint fixtures (2026-05-30)

KEY FINDING: Zig's native SPIR-V backend keeps mutable locals in MEMORY
(OpVariable/OpLoad/OpStore, Function storage) — so raw Zig shader output
has FEW phis (the loop-iteration var is load/store, not a header phi).
BUT the pipeline runs `spirv-opt -O` (mem2reg etc.) BEFORE the
transpiler, which promotes those memory locals to SSA — so the SPIR-V
spv2wgsl ACTUALLY consumes is phi-heavy.  Verified on the real
mandelbrot post-opt: 22 phis / 3 vars, loop header `%1122` carries 4
header phis (the loop-carried z/n/escaped/i).

CANONICAL loop-header-phi shape (Tint fixture
`phi_Phi_FromContinuing.spvasm`, matches the real mandelbrot):
```
%32 = OpLabel                      ; loop header
%33 = OpPhi %int  %int_0 %17  %34 %35   ; (init from parent %17, iter from continue %35)
      OpLoopMerge %37 %35 None
      OpBranchConditional %true %38 %37
...
%35 = OpLabel                      ; continue block
%34 = OpCopyObject %int %int_1
      OpBranch %32                 ; back-edge
```
A loop-header OpPhi has EXACTLY 2 incoming pairs: `(init_value,
parent_block)` and `(iter_value, continue_block)`.  Maps to our model:
- header phi → a `Loop.header_params` entry (`var phiN`),
- init_value assigned BEFORE the loop (the pre-loop block's edge),
- iter_value assigned in the CONTINUING block (carried as the `cont`
  edge / continuing terminator).
Loop-MERGE phis (a value escaping the loop) → `Loop.results`, attached
on every `exit_loop`/`break_if` edge — identical mechanism to the
If-merge phi attachment already implemented (`attachIfMergePhis`).

IMPLEMENTATION (next): in buildLoop, stop returning IrBuildUnsupported
for header/merge phis.  (1) read header OpPhis → header_params; for each,
record init_value (parent edge) for pre-loop assignment + iter_value
(continue edge) for the continuing update; (2) read loop-merge OpPhis →
results via the same per-exit attachment as If.  The `cont` terminator's
args carry the header phis' iter values (positional, header_params
order).  Useful Tint refs: EmitPhiInLoopHeader ~2920, EmitPhiInLoopMerge
~2746, EmitPhiInLoopBody ~2895, EmitPhiInLoopContinue.

### F-arc step tags (renumbering the IR rewrite phases)

Adopting short step tags (per the claude.md turn/tag rule).  The IR
rewrite is the **F arc**:
- **F1** — ir.zig type model + validator.  DONE.
- **F2** — ir_build.zig structural reconstruction (no output):
  - F2a — straight-line base case.  DONE.
  - F2b — `If` reconstruction + merge-phi attachment.  DONE (turn 796).
  - F2c — `Loop` reconstruction (no-phi) + stop-stack generalization.
    DONE (turn 798).
  - F2d — loop-carried phis (header_params / cont args / loop-merge
    results).  NEXT.
  - F2e — `Switch` reconstruction.
- **F3** — ir_emit.zig WGSL emitter behind `-Dwalker=ir` (the old P1).
- **F4** — flip default to ir; legacy behind `-Dwalker=legacy` (old P2).
- **F5** — delete legacy walker StopSet/route_phi_inline/etc (old P3).

### Labeled break/continue is a NON-ISSUE — verified empirically (turn 799)

Open design worry (turn 799): WGSL has only UNLABELED break/continue,
so a SPIR-V branch to a NON-innermost merge would build correct IR but
be unemittable → silent miscompile.  RESOLVED by testing the worst
case through zimr's exact toolchain.

Compiled a 3-deep nested-loop Zig fn with `break :outer`, `continue
:mid`, and a `break :mid` from inside a `switch`, via
`zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm
-fno-lld -O ReleaseFast -ofmt=spirv` (the NATIVE backend zimr uses,
NOT LLVM which segfaults on spirv).  Dumped with our own `tools/zspv
--dump` (build: `zig build-exe tools/zspv.zig -femit-bin=/tmp/zspv`;
opcodes are numeric — 248=Label, 249=Branch, 250=BranchConditional,
251=Switch, 246=LoopMerge, 247=SelectionMerge, 253=Return).

RESULT: **Zig's native SPIR-V backend FULLY desugars labeled control
flow.**  Every branch/branch-conditional/switch target in the module
is the merge or continue of the INNERMOST enclosing construct — zero
cross-level jumps.  A labeled break becomes a flag-cascade: the inner
construct breaks to its OWN merge, then a flag-check AFTER it (when it
is no longer the innermost) propagates the exit up one level.  The
switch break lands on the switch's own merge; nothing jumps out of the
switch directly.  spirv-opt accepts the module (structurally valid).

IMPLICATION for the F arc:
- The stop-stack innermost-first lookup is not just sufficient but
  EXACTLY matched to the input — the only branch targets that exist
  are innermost ones.
- NO guard-variable lowering pass is needed for labeled exits; Zig
  already did that lowering upstream.
- `break_if` (in ir.zig) is still used for the loop-iteration-check
  shape, but not for labeled exits.

CAVEAT (recorded so nobody trips on it later): this holds for
Zig-sourced shaders through Zig's native backend — i.e. zimr's ENTIRE
shader pipeline.  It would NOT necessarily hold for arbitrary foreign
SPIR-V (some producers emit less-structured CFGs).  zimr only ever
feeds its own Zig shaders through spv2wgsl, so this fully covers us;
do not point ir_build at third-party SPIR-V without revisiting this.

The innermost-by-TARGET resolution this relies on is already covered
by the `continue-nested-in-if` test (turn 798): a `continue` inside an
if inside a loop resolves to `cont` by skipping PAST the if's
`exit_if` stop to the loop's `cont` stop — matching on target id, not
stack position.

### F2d — loop-carried phis: ALREADY DONE (discovered turn 801)

Correction to the record: F2d was completed in an earlier turn but the
"NEXT" pointer above wasn't updated, so turn 801 nearly re-did it.  The
implementation is fully present in `ir_build.zig` and tested:
- `readLoopHeaderPhis` + `backEdgePred` + `branchesToTarget`: read
  loop-header OpPhis into `Loop.header_params` with `init` = the
  pre-loop edge value, and collect the continue-edge values into
  `Loop.iter_args` (positional).  Mirrors Tint's EmitPhiInLoopHeader
  (the init-via-initializer / iter-via-NextIteration split), adapted to
  our hoisted-var model (init assigned before the loop, iter assigned
  at the end of `continuing`).
- `attachLoopMergePhis`: loop-merge OpPhis → `Loop.results`, each value
  attached to the `exit_loop`/`break_if` edge of its predecessor (same
  per-exit mechanism as `attachIfMergePhis`).
- The phi-deferral guards (`blockHasPhi`) are gone; `buildLoop` now
  handles header + merge phis.  Still deferred: single-block loops
  (continue == header) and non-canonical header phis (not exactly one
  pre-loop + one continue edge).

Tests (in `ir_build.zig`, all green): "loop-header phi (init + iter
split)" → header_params=[phi30 init=31], iter_args=[32]; "loop-merge
phi (value escaping the loop)" → results=[phi70], break edge carries
arg [71].  Plus the F2c structural loop tests and the
continue-nested-in-if stop-stack test.

Cold verification turn 801: ir_build 23/23, ir 4/4, lint 0 (file +
whole project 263), wgpu-check green.

So the builder (F2) now covers: straight-line, If+merge-phi,
Loop+header/merge-phi, and the nested break/continue cases.  The only
remaining F2 piece is **F2e — Switch reconstruction** (`switch_header`
still returns `IrBuildUnsupported`).

---

### F2e — Switch reconstruction LANDED (turn 802)

`ir_build.zig` now reconstructs `Switch` from `switch_header` blocks,
completing the F2 builder.  `buildSwitch` decodes `OpSwitch`
(`[selector, default, (literal, target)+]`, merge from the preceding
SelectionMerge), builds each case + default via `buildCaseTarget`
(stopping at the merge -> `exit_switch`; empty case when target ==
merge), dedups selectors sharing a target into one `Case` with
multiple `values` (WGSL `case a, b:`), and attaches merge OpPhis to
each case's `exit_switch` edge via `attachSwitchMergePhis`.  No
fallthrough (WGSL semantics).  Grounded in Tint EmitSwitch (~3805) +
the per-exit phi pattern shared with If/Loop merges.

Tests (ir_build now 25/25, lint 0, wgpu-check green, project 0/263):
"switch with cases, default, and a merge phi" -> 2 cases + default,
results=[phi70], each case/default exit_switch carries its phi value
(71/72/73); "dedups switch selectors that share a case body" ->
case 1 and case 2 both -> %20 collapse to ONE case with values [1,2].

Builder (F2) is now COMPLETE.  Deferred structured shapes (rare,
fall back to legacy via IrBuildUnsupported): single-block loops
(continue==header), non-canonical loop-header phis, unstructured
OpSwitch on a plain block (no SelectionMerge).

### F3 (part 1) — `ir_emit.zig` WGSL emitter LANDED (turn 803)

The structured-IR → WGSL emitter is in, standalone + unit-tested.  It's
duck-typed over `s: anytype` (needs `wgslNameOf(id)` +
`currentFunctionIsEntry()`) and an `emitBlockBody` callback matching
`emitBlockBodyOnly` — the same interface the legacy `walker.emitBlock`
already uses, so the real `State` + the existing block-body text
emitter satisfy it directly.

Emits: If/Loop/Switch shells; the per-exit `phi{id} = <value>;`
assignments (pairing each exit edge's args with the enclosing
construct's result params, threaded down via an `Enclosing` struct —
so a merge phi lands on EVERY branch, the dropped-copy fix); loop
header-phi init before the loop + iter update at the end of the
`continuing` block; and function terminators (return / return outputs /
discard / break / continue / break-if).  It does NOT declare the
hoisted `var phi{id}: T;` — the pass4_functions prepass already does
that for both walkers.

Tests (8, all green; also run inside the spv2wgsl test root → 49/49):
diamond if/else with the phi assigned on BOTH branches; loop with
header-phi init-before-loop + iter-in-continuing (order asserted);
switch with a dedup'd `case 2, 3:` + default + per-case break; entry
fn `return outputs;`.  ir_emit lint 0; project lint 0/264; wgpu-check
green.

NOT yet wired to real output: `emitFunctionBody` still always calls
the legacy walker.  F3 part 2 wires the `-Dwalker=ir` build option to
route through `ir_build.build` → `ir_emit.emit` with legacy fallback.

### F3 (part 2) — `--walker=ir` wired + a real legacy bug found (turn 805)

The IR path now drives real output behind a flag, with safe fallback:
- `convertSpirvToWgslWithWalker(arena, spirv, .ir|.legacy)` +
  `WalkerChoice` enum; `convertSpirvToWgsl` delegates `.legacy`.
- `emitFunctionBody` branches: `.ir` tries `ir_build.build` →
  `ir_emit.emit` into a scratch buffer, committing only on success;
  on `IrBuildUnsupported`/`MalformedFunction` it falls back to the
  legacy walker for THAT function (corpus stays green during rollout).
- `tools/spv2wgsl.zig` gained a leading `--walker=ir|legacy` flag
  (threaded through cmdTranslate/cmdCheck).

DUAL-WALKER CORPUS COMPARISON (181 Tint fixtures):
- 181/181 legacy ok; 175/181 ir ok (6 clean fallbacks = the deferred
  shapes: single-block loops, non-canonical header phis, unstructured
  switch-on-plain-block).
- Of the 175 both-ok: 101 identical, 39 whitespace-only, 35
  "substantive".

KEY FINDING — the substantive diffs are NOT IR bugs:
1. Acceptable structural variation: legacy hoists a forward block out
   of an `if` and uses a negated one-sided `if (!c) continue;`; IR
   keeps the block inside the branch (`if (c) {..; continue} else
   {continue}`).  Same semantics, both valid WGSL.
2. IR is MORE CORRECT than legacy on some shapes.  Confirmed:
   `branch_BranchConditional_Nested_TrueExit` — CFG is `%14 brc
   T=%13(merge) F=%15`, `%15→%13`, and `_16` lives in %15, so `_16`
   is CONDITIONAL (runs only on %14's false edge).  Legacy emits
   `_16` UNCONDITIONALLY after the inner if (latent bug); IR correctly
   emits it in the else branch.  This is precisely the dropped/
   mis-scoped-statement bug class the rewrite exists to eliminate.

CONCLUSION: do NOT chase byte-parity with legacy — legacy is the buggy
baseline.  The rollout gate is "IR output is valid WGSL + renders
correctly in-browser", not "IR == legacy".

BUG FIXED this turn: the loop HEADER block's own body was emitted
BEFORE the loop in the parent scope; it must be INSIDE the loop body
(the header is the back-edge target → runs every iteration).
`buildLoop` now prepends `{ .body = header.id }` to the loop body
block (via `prependBodyItem`, mutating in place to keep `by_id` phi-
attachment pointers valid).  Loop tests updated for the new item
indices; ir_build 25/25.

State: ir_build 25/25, ir_emit 8/8, project lint 0/264, wgpu-check
green (default legacy).  IR path NOT yet exercised by the shader build
(F3 part 3).

### F3 (part 3) — `-Dwalker=ir` through the shader build + corpus-green (turn 807)

The IR walker is now wired through the REAL shader pipeline and passes
the whole corpus end-to-end.

Build wiring:
- `ShaderPipeline.wgsl_walker: []const u8 = "legacy"` field
  (shader_codegen.zig); the spv2wgsl invocation emits a leading
  `--walker={s}` arg BEFORE `--strict`/positional (matches the CLI's
  leading-flag parser).
- `-Dwalker=` build option in build.zig ("legacy" default | "ir"),
  set onto `shader_pipeline.wgsl_walker`.  So `zig build wgpu-check
  -Dwalker=ir` runs every engine shader through the IR path.

RESULT: `wgpu-check -Dwalker=ir` is GREEN — 0 transpile failures,
wgpu_smoke PASSED, NO REGRESSIONS.  Default (legacy) wgpu-check also
still green.  ir_emit 8/8, spv2wgsl 49/49, project lint 0/271.

BUG FOUND + FIXED (only the full-pipeline run surfaced it): the IR
path was DOUBLE-emitting every phi assignment.  `emitFunctionBody`
sets `s.phi_assigns_ref` (the legacy phi-routing map) and the IR
branch ran with it still set, so `emitBlockBodyOnly` injected
`phi = val` at each block terminator AND the IR emitter emitted its
own merge/header phi assignments on top.  Visible on the fractal
shader as duplicated `phi2048 = ...` lines in both the pre-loop init
and the continuing block.  FIX: `tryEmitViaIr` now saves + NULLs
`phi_assigns_ref` for the duration of the IR emit (restoring it for
the legacy fallback) — the IR path owns phi lowering entirely.  This
also confirmed the design: in our hoisted-var model the IR emitter's
init-before-loop + iter-at-end-of-continuing is the SINGLE source of
loop-phi assignments; the legacy terminator-injection must be off.

Unit tests couldn't catch this (they use a no-op fakeBlockBody with no
phi_assigns_ref, so no collision) — it took the real emitBlockBodyOnly
+ a phi-heavy loop shape.  Lesson logged: the full-pipeline corpus run
is a distinct gate from the module unit tests.

## >>> STATUS (read this FIRST at start of turn) <<<

- ✅✅ CARDIOID RENDERED IN-BROWSER (turn 808).  Simon's phone (real
  WebGPU) shows a correct Mandelbrot — cardioid + period bulbs +
  seahorse-valley filaments, smooth iteration coloring, ~95fps — built
  via `wgpu-demo -Dwalker=ir`.  This is the visible end-to-end proof
  the whole F-arc existed for: mandelbrot_fs.zig → SPIR-V → zspv →
  spirv-opt → OUR spv2wgsl STRUCTURED-IR walker → WGSL → browser GPU,
  zero Tint/Naga in the wasm.  The iteration-count phi (phi2048) that
  the legacy walker dropped now escapes the loop correctly.
- TWO BUGS the screenshot loop caught that the JS-shim wgpu-check could
  NOT (only a real WGSL frontend validates types/arity): (1) phi
  DOUBLE-EMIT (fixed turn 807 — nulled phi_assigns_ref in tryEmitViaIr);
  (2) phi EXIT-ARG MISROUTING on one-sided ifs (fixed turn 808).  Bug
  2 detail: `attachExitArg`'s old "attach to whichever branch has fewer
  args" heuristic scrambled phi values across branches when a merge had
  MULTIPLE phis with a header-direct (one-sided-if) edge — true branch
  got 3 args, else got 2, leftover paired against the wrong phi var
  (phi2099:f32 ← u32 → `cannot assign 'u32' to 'f32'` at wgsl
  mandelbrot:106:23, blank canvas).  FIX: route header-direct values
  (pred==header_id) DETERMINISTICALLY to the EMPTY branch (the one
  whose target IS merge_id), in phi order, so every branch's exit args
  stay positionally aligned with results.  ALSO added a safety net:
  tryEmitViaIr now `ir.validate(&body) catch return
  error.IrBuildUnsupported` BEFORE emitting — malformed IR (arity
  mismatch) falls back to legacy instead of shipping broken WGSL.
- ALL GATES GREEN turn 808: ir_build 25/25, ir_emit 8/8, spv2wgsl
  49/49, wgpu-check green under BOTH -Dwalker=ir AND default(legacy),
  cold project lint 0/271.
- NEXT: F4 — flip the DEFAULT walker to "ir" (legacy stays behind
  `-Dwalker=legacy` for one cycle as the escape hatch).  THEN F5 —
  delete the legacy walker + now-dead phi_assigns_ref / StopSet /
  route_phi_inline / isTrivialPassthroughBlock machinery + the GLSL
  emitter (tools/zglsl.zig already on deletion_skip).  Optional polish
  after F4/F5: brighten the mandelbrot palette; wire the dormant
  julia / mandel_julia shaders into wgpu_demo (the title already says
  "3 fractals").
- DON'T REDO: F1, F2(a-e), F3 (emitter + CLI + build wiring) DONE.
  Loop header-body-inside-loop bug FIXED turn 805.  Phi double-emit
  FIXED 807.  Phi exit-arg misrouting FIXED 808.  Labeled
  break/continue non-issue (799).  Do NOT chase byte-parity with
  legacy — legacy is the buggy baseline (and it's getting deleted).
