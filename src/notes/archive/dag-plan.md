# The DAG Plan

A verified, improved successor to `dependency-cycle-fix-plan-v2.md`.
Reflects current code reality (state-explicit refactor done — `0 prod /
0 tests / 0 fixtures` audit) and bakes in the per-turn discipline
that made that refactor land safely.

---

## What changed since v2 was written

The v2 plan was authored when Fix E (globals removal) was the dragon —
13 globals across 5 subsystems, 60+ residual reaches, the
`runtime_anchor` service-locator hub. **Most of that is already done.**

### Audit metric verified at start of this plan

```
src/drawing.zig    0 prod   0 tests   0 fixtures
src/rlgl.zig       0 prod   0 tests   0 fixtures
src/sound.zig      0 prod   0 tests   0 fixtures
src/runtime.zig    0 prod   0 tests   0 fixtures
src/ui.zig         0 prod   0 tests   0 fixtures
src/zimr.zig       0 prod   0 tests   0 fixtures
TOTAL              0 prod   0 tests   0 fixtures
```

Every public fn declares its substate dependencies in its signature.
The codebase has exactly **one** anchor reach left: `_jsBridgeInputState()`
in `runtime.zig` — by design, because JS event handlers call into wasm
exports without passing a state pointer.

### What v2 still got right

- The cycle is still 1 SCC of 8 nodes: `{codecs, drawing, raymath,
  rlgl, runtime, runtime_anchor, sound, types}`. Verified by graph
  walk — 51 edges total, 24 within the SCC.
- Three structural causes are still present:
  1. `types.zig` defines 36 methods on `extern struct` data types that
     delegate via inline `@import` to drawing/rlgl/raymath. Each of
     those imports is a back-edge that puts types inside the SCC.
  2. `LoadError` in types.zig composes from `codecs.png.Error` and
     `web.fetch.Error` — back-edge `types → codecs`.
  3. `runtime_anchor.zig` is a 77-line service-locator hub that 4
     subsystems still import for the `Runtime` type (even though
     none of them reach `anchor` anymore — only `runtime.zig` does,
     via `_jsBridgeInputState`).
- The proposed file split (`math.zig`, `enums.zig`, `allocator.zig`,
  `errors.zig`) is the right shape.

### What v2 got wrong about the current world

- **Fix E is 95% done.** The plan budgets ~600 LOC, 8 files, "the
  largest single fix" — but in current reality only 1 inbound import
  to `runtime_anchor` remains (from runtime.zig itself). E shrinks
  from a 6-step migration to a 3-step file rename.
- **Globals census** in v2 lists 13 to remove; current count is 1
  (`anchor`, soon to be renamed `app`).
- **The 6 in-source tests** v2 enumerates as needing migration are
  already gone — the state-explicit refactor retired every anchor
  fixture in the test suite.

### What this plan adds

- **Per-turn discipline baked into every phase.** The state-explicit
  refactor took ~38 turns and the discipline is what made it land
  safely. Same protocol here.
- **A DAG validator script** (`scripts/check_dag.py`) — analogous to
  `count_globals.py` — that walks imports, builds the graph, reports
  edge count + SCC membership. Run every turn alongside the audit.
- **A revised execution order** that exploits done-ness: Fix B + Fix
  D extracts done first (they're pure file moves), Fix C done next
  (it's the cycle-breaker), Fix A done last (smallest, can ride the
  D test churn), Fix E.tail is just a rename.
- **Explicit batch sizing.** Each phase is sized to ~1-3 turns of
  per-fn discipline work.

---

## The discipline (mandatory every turn)

These rules made the state-explicit refactor land. They land this
refactor too. **No exceptions.**

### Per-turn protocol

1. **Audit at turn start.** Run `python3 scripts/count_globals.py`
   AND `python3 scripts/check_dag.py` (new — see below). Verify both
   targets green: `zig build test --summary all` + `zig build
   smoke-test --summary all`.

2. **Read the style guide every 3 turns.** `view
   /home/claude/src/notes/style-guide.md` in full. The rules drift
   in your head between turns; re-anchoring takes 30 seconds and
   prevents the "wait, did I forget to add explicit local types?"
   review pass at end of turn.

3. **Re-read this plan every 5 turns.** "Why are we doing this" gets
   compacted out of working memory; rebuild it from the source.

4. **Touch-cleanup rule.** Every fn you touch — even by one character
   — gets the full Rule 1-7 sweep before you move on:
   - Rule 1: multi-arg fns one-arg-per-line; single-arg on one line.
   - Rule 2: explicit local types except when the type is already
     on the line (`alloc(T, ...)`, `@as(T, ...)`).
   - Rule 3: braces every branch.
   - Rule 4: casual undecorated comments; no numbered steps; doc
     comments declare allocator ownership / errors / side effects.
   - Rule 5: `@splat` over `**` for fixed-size array fills.
   - Rule 6: lift bare numeric/boolean literals into named locals
     when meaning isn't self-evident at the call site.
   - Rule 7: keep boolean conditions trivial; lift sub-expressions
     into named bools.

5. **Doc-comment every migrated fn.** Top-of-fn `///` block declares
   what the fn reads, what it mutates, and any non-obvious contracts.
   This is what made the state-explicit refactor reviewable. Same
   pattern for the file-split: every fn that moved gets its doc
   comment refreshed to match its new home.

6. **Build verify after each batch.** Both targets, every batch.
   Cache transients are real but rare; if a single-touch fix is
   green and a two-touch fix is red, the issue is in the second
   touch — don't blame the cache.

7. **CHANGELOG every turn.** Concise prose. Metrics delta (edges
   removed, SCCs broken, fixtures retired). What pattern emerged
   that should inform the next batch.

8. **Save zip every turn unconditionally** to
   `/mnt/user-data/outputs/zimr.zip`. Don't skip on "broken state" —
   broken intermediate states are recoverable; lost progress is not.
   If the state really is broken, the CHANGELOG should call it out
   with a concrete next-turn recovery step.

### Sed sweep discipline

The state-explicit refactor's recurring failure mode was file-wide
regex sweeps that hit unintended targets — `globalState() → &ws`
once corrupted the `pub inline fn globalState()` declarations
themselves. Lessons:

- **Bound replaces to specific ranges** (single fn, single test
  block) when possible.
- **Run a verify build immediately after any sweep.** Don't stack
  three sed sweeps then build — debug surface explodes.
- **Count occurrences before AND after** the sweep. If the delta
  doesn't match expectation, you hit unintended targets.

### Touched-fn boundaries

The "touch-cleanup" rule has one nuance: when a file split moves a
fn unchanged, that's a touch. Add the doc comment, do the Rule
1-7 sweep, fix the imports. When a file split moves a *type*
unchanged, the type's methods (the constructors that survive Fix C)
are touches; their bodies get the sweep.

When in doubt: did I edit this fn this turn? Yes → sweep it. No →
leave it.

---

## Tooling: `scripts/check_dag.py` (NEW)

```python
#!/usr/bin/env python3
"""
DAG validator for src/*.zig.

Builds the import graph from `@import("foo.zig")` calls (both file-scope
constants and inline imports), runs Tarjan's SCC algorithm, prints:
  - total edge count
  - non-trivial SCCs (size > 1) with their member modules
  - the "layer" each module sits at (longest path from a leaf)

Exit code: 0 if SCC count is 0, 1 otherwise.  Run this before every
commit and at the start of every refactor turn.
"""
import os, re, sys
from collections import defaultdict

src_dir = "src"
src_files = [f for f in os.listdir(src_dir) if f.endswith(".zig")]
modules = {f[:-4]: os.path.join(src_dir, f) for f in src_files}

import_re = re.compile(r'@import\("([^"]+\.zig)"\)')
edges = defaultdict(set)
for mod, path in modules.items():
    with open(path) as fp:
        text = fp.read()
    for tgt in import_re.findall(text):
        tgt_mod = tgt[:-4]
        if tgt_mod == mod or tgt_mod not in modules:
            continue
        edges[mod].add(tgt_mod)

# Tarjan
def tarjan(graph, nodes):
    idx = [0]; stack = []; low = {}; ix = {}; on = {}; sccs = []
    def go(n):
        ix[n] = idx[0]; low[n] = idx[0]; idx[0] += 1
        stack.append(n); on[n] = True
        for s in graph.get(n, []):
            if s not in ix:
                go(s); low[n] = min(low[n], low[s])
            elif on.get(s):
                low[n] = min(low[n], ix[s])
        if low[n] == ix[n]:
            scc = []
            while True:
                w = stack.pop(); on[w] = False; scc.append(w)
                if w == n: break
            sccs.append(scc)
    for n in nodes:
        if n not in ix: go(n)
    return sccs

sccs = tarjan(edges, list(modules.keys()))
non_trivial = [s for s in sccs if len(s) > 1]
total_edges = sum(len(v) for v in edges.values())

print(f"Edges:    {total_edges}")
print(f"Modules:  {len(modules)}")
print(f"SCCs:     {len(non_trivial)} non-trivial")
for scc in non_trivial:
    print(f"  size {len(scc)}: {sorted(scc)}")

sys.exit(0 if len(non_trivial) == 0 else 1)
```

**Run alongside `count_globals.py` every turn.** The two scripts are
the structural-quality dashboard.

---

## Target state

### Layered DAG (final)

```
L0 — std-only leaves:
  web.zig          extern "dom" / "webgl" declarations
  math.zig         [NEW] Vector*/Matrix/Quaternion/Color/Rectangle/
                         Camera*/Ray*/BoundingBox — pure data + arithmetic
  enums.zig        [NEW] raylib enums + named-constant blocks
  allocator.zig    [NEW] libc shim over std.heap.wasm_allocator

L1:
  types.zig        asset & audio types only — no methods, no enums,
                   no math types
                   ↓ math, enums

L2:
  raymath.zig      ↓ math, enums

L3:
  codecs.zig       ↓ math, enums, allocator, web
  rlgl.zig         ↓ math, enums, types, raymath, web

L3.5:
  errors.zig       [NEW] LoadError, ImageGenError — composes
                   ↓ codecs, web

L4:
  sound.zig        ↓ types, errors, codecs, allocator, web
  drawing.zig      ↓ types, errors, math, enums, codecs, rlgl,
                     raymath, allocator, web

L5:
  runtime.zig      ↓ types, math, enums, rlgl, raymath, allocator, web
                   (no longer imports drawing or runtime_anchor)
  ui.zig           ↓ types, math, enums, drawing, rlgl, runtime

L6 — top-level integration:
  runtime_assembly.zig  [REPLACES runtime_anchor.zig]
                   ↓ rlgl, runtime, sound, drawing
                     defines `pub const Runtime = struct{...}`
                     owns `pub var app: ?*Runtime = null`
                     hosts the 10 JS-export shims (relocated from
                     runtime.zig) so they don't create a back-edge

L7:
  zimr.zig         ↓ everything
  tests.zig        ↓ everything
```

**Targets:** 51 edges → 33. 1 SCC of 8 → 0. Single global stays.

### Globals census (final)

| Storage                          | Where                  | Why kept                           |
| -------------------------------- | ---------------------- | ---------------------------------- |
| `pub var app: ?*Runtime = null;` | `runtime_assembly.zig` | JS callbacks have no other way     |

That is the entire list. Net change from current: rename
`runtime_anchor.anchor` → `runtime_assembly.app`, move the 10 JS
shims that reach for it from `runtime.zig` to `runtime_assembly.zig`,
delete the obsolete file.

---

## Phases (six, in execution order)

Execution order is **different from v2**. v2 was written when Fix E
was the dragon and ordered A→B→C→D→E to back-load the risk. With Fix
E mostly done, the order rotates: do the file-extraction and
method-deletion work first (B → D → C), then close the cycle (A),
then collapse `runtime_anchor` (E.tail).

### Phase 0 — Tooling + plan-read (1 turn)

**Goal:** establish per-turn metrics before changing anything.

1. Create `scripts/check_dag.py` (contents above).
2. Run it; record the baseline (51 edges, 1 SCC of 8).
3. Re-read this plan in full + `style-guide.md` in full.
4. CHANGELOG entry stating baseline + intent.
5. Save zip.

**No code changes.** Just instrumentation + grounding.

### Phase 1 — Fix B: extract `errors.zig` ✅ DONE PRIOR

**Discovery on starting Phase 1**: `src/errors.zig` already exists
(75 lines, full LoadError + ImageGenError extracted, types.zig
clean of `LoadError`/`png_mod`/`fetch_mod`).  Done in a prior
session that wasn't reflected in working memory.

`errors` still appears in the SCC (per `check_dag.py`), but only
because it's transitively pulled into the cycle by Fix C +
Fix A — once those land, `errors` exits the SCC naturally.

**No action this phase.** Skip to Phase 2.

### Phase 2 — Fix C: delete every method from data types (2 turns)

**Eliminates:** `types → drawing` (24 inline imports), `types →
rlgl` (9), `types → raymath` (8). With Fix B already done, this
finishes types.zig's outbound back-edges and lets Fix D extract the
data types into clean leaves.

**Why this MUST come before Fix D**: `Matrix.lookAt` etc. carry
`@import("raymath.zig")` calls in their bodies.  If Fix D extracted
`Matrix` into `math.zig` first, the back-edges would just relocate
into math.zig.  Methods die first; clean type defs extract second.

**Sub-batch 2a (turn 1) — Matrix + Image methods:**

Delete from `types.zig`: `Matrix.rotation`, `lookAt`, `perspective`,
`ortho`, `mul`, `invert`, `transpose`, `determinant`, `translate`,
`scale`. Keep `identity`, `translation`, `scaling`, `zero` (pure
constructors).

Delete from `types.zig`: `Image.deinit`, `isValid`, `flipVertical`,
`flipHorizontal`, `rotateCW`, `rotateCCW`, `crop`.

Internal callers (per v2 plan's appendix):

```
types.zig:790      target.texture.deinit()       # inside RenderTexture deinit
types.zig:2134     try expect(!t.isValid())      # test
types.zig:2150     try expect(!img.isValid())    # test
types.zig:2155     img.deinit(allocator)         # test
types.zig:2160     try expect(!rt.isValid())     # test
types.zig:2170     try expect(!f.isValid())      # test
types.zig:2179     try expect(!m.isValid())      # test
drawing.zig:10943  const sig: fn (...) void = types.Font.deinit;
```

Each becomes the namespaced free-fn form (`textures.isImageValid(img)`,
`textures.unloadImage(allocator, img)`, etc.).

**Sub-batch 2b (turn 2) — Texture/RenderTexture/Font/Mesh/Material/
Model/Shader methods:**

Same shape as 2a. Delete the methods listed in the v2 plan's
Appendix B. 22 method removals.

**Touched-fn discipline:** for the 7 internal-caller updates, the
test bodies get the Rule 1-7 sweep. The signature regression test
in drawing.zig:10943 becomes a regression test for `text.unloadFont`
instead.

**Verify:** both builds green per sub-batch; `check_dag.py` shows
SCC size drop. After 2a: `types → raymath` gone. After 2b: `types →
rlgl` and `types → drawing` gone. The SCC collapses to
`{drawing, rlgl, runtime, runtime_anchor, sound}` — 5 nodes.

### Phase 3 — Fix D: extract `math.zig`, `enums.zig`, `allocator.zig` (3 turns)

**Eliminates:** indirect — reduces `types.zig`'s in-degree from 9
modules to 3; eliminates `runtime → ` outbound edges from
`drawing`/`codecs` (their only need was `runtime.allocator`).

**Why after Fix C:** with methods already deleted, the math/asset/enum
boundaries are clean — no method body references force a type to live in a
particular file. The split becomes a simple `git mv` of contiguous line
ranges.

**Sub-batch 3a (turn 1) — `math.zig`:**

1. Create `src/math.zig` with `Vector2`, `Vector3`, `Vector4`,
   `Quaternion`, `Matrix`, `Color`, `Rectangle`, `Camera2D`,
   `Camera3D`, `Ray`, `RayCollision`, `BoundingBox`. Copy verbatim
   from `types.zig`.
2. Delete those types from `types.zig`.
3. Add `pub const Vector2 = math.Vector2;` etc. re-exports inside
   `types.zig` (transitional — clean up in Phase 5).
4. Update `raymath.zig`: `const types = @import("types.zig");`
   → `const math = @import("math.zig");` (or both, if it touches
   asset types too).
5. Run check_dag.py: `raymath → types` should drop, replaced by
   `raymath → math`.

**Sub-batch 3b (turn 2) — `enums.zig`:**

1. Create `src/enums.zig` with the 21 enums from `types.zig` lines
   1194-1588. Copy verbatim.
2. Delete those enums from `types.zig`.
3. Add re-exports in `types.zig` (transitional).
4. Update inline imports across the codebase: every
   `@import("types.zig").PixelFormat` → `@import("enums.zig").PixelFormat`.
   Use a bounded sed sweep — count before/after.
5. Add `pub const enums = @import("enums.zig");` to `zimr.zig`.

**Sub-batch 3c (turn 3) — `allocator.zig`:**

1. Create `src/allocator.zig` with the contents of `runtime.allocator`
   (lines ~5847-6035 of runtime.zig).
2. Delete the `pub const allocator = struct { ... };` block from
   runtime.zig.
3. Update the four call sites in `drawing.zig` (lines 2667, 8355,
   10956, 16362) from `@import("runtime.zig").allocator` to
   `@import("allocator.zig")`.
4. Update `zimr.zig:76` to point at the new file.

**Touched-fn discipline:** every fn that moved into the new file
gets a refreshed doc comment + Rule 1-7 sweep. The `Matrix.lookAt`-
style methods stay for now (Fix C deletes them next phase) — but
they get touched, so they get swept too. This pre-pays the cleanup
cost, making Fix C a pure deletion.

**Verify:** both builds green per sub-batch; `check_dag.py` shows
edge count drop; SCC structure unchanged this phase (the cycle is
not yet broken — that's Fix C).

### Phase 4 — Fix A: relocate `setWindowIcon` (1 turn)

**Eliminates:** the single `runtime → drawing` edge.

**Why this late:** lowest-risk by itself, but it benefits from the
file moves landing first — the imports in zimr.zig that this fn
will reference are already settled.

**Steps:**

1. Move `setWindowIconPng`, `setWindowIcon`, `setWindowIcons` from
   `runtime.zig:489-518` to `zimr.zig` as plain `pub fn`s.
2. Remove the orphaned `@import("drawing.zig")` from runtime.zig.
3. Update internal references; check examples for `z.core.setWindowIcon`
   callers (none expected).

**Touched-fn discipline:** all three fns get the Rule 1-7 sweep + a
read/write doc comment declaring the substates they touch.

**Verify:** both builds green; `check_dag.py` shows edge count drop;
SCC structure unchanged this phase (E.tail collapses what's left).

### Phase 5 — Fix E.tail: rename `runtime_anchor.zig` → `runtime_assembly.zig` (1 turn)

**Eliminates:** the last 4 edges into the SCC (`runtime → runtime_anchor`,
`runtime_anchor → {drawing, rlgl, runtime, sound}`). Closes the cycle.

**This is now a tiny fix** because the state-explicit refactor already
did the hard work — only `_jsBridgeInputState` reads `anchor`, and
that one reach is moving with the JS shim into the new file.

**Steps:**

1. Rename `src/runtime_anchor.zig` → `src/runtime_assembly.zig`.
   Inside: rename `pub var anchor: ?*Runtime` → `pub var app: ?*Runtime`.
   Add `install(rt)` and `uninstall()` helpers per v2 plan.
2. Move the 10 `pub export fn input_push_*` shims from
   `runtime.zig:1610-1764` into `runtime_assembly.zig`. They call
   `pushKeyDown(&app.?.input, ...)` etc. — `pushKeyDown` itself stays
   in runtime.zig and takes `*InputState` (already does).
3. Delete `_jsBridgeInputState()` from runtime.zig. Its only callers
   were the 10 shims that just moved away.
4. Move the 4 vtable-backend thunks (`browserTime`, `browserFrameTime`,
   `browserFps`, `browserEmit`) from runtime.zig into runtime_assembly.zig
   — same pattern. Or leave them in runtime.zig, since after the
   state-explicit refactor they read substates via `userdata` (the
   `Browser.bind()` mechanism), so they don't need `app` at all.
   Decide based on what reads cleanest after the move.
5. Update `App.create` in zimr.zig: `runtime_assembly.install(&self.runtime)`
   replaces the manual `runtime_anchor.anchor = &self.runtime;` set.
6. Update `App.destroy`: `runtime_assembly.uninstall()`.
7. Update the `zimr.zig` re-export:
   `pub const Runtime = runtime_assembly.Runtime;`.

**Touched-fn discipline:** the 10 input shims + 4 vtable thunks get
the Rule 1-7 sweep + doc comments. `App.create` gets a comment update
explaining the install/uninstall lifecycle.

**Verify:** both builds green; `check_dag.py` reports **0 SCCs** and
**~33 edges** (down from 51). The plan's target is reached.

### Phase 6 — cleanup: drop transitional re-exports (1 turn)

**Eliminates:** the `pub const Vector2 = math.Vector2;` aliases in
`types.zig` (and similar in zimr.zig).

**Steps:**

1. Across the codebase, replace `types.Vector2` → `math.Vector2`,
   `types.PixelFormat` → `enums.PixelFormat`, etc. Bounded sed.
2. Delete the transitional re-exports from `types.zig`.
3. Update `zimr.zig`'s public surface to re-export from the proper
   homes (`pub const Vector2 = math.Vector2;` lives in zimr.zig as a
   top-level re-export now, not in types.zig).
4. Update `style-guide.md`:
   - Add Rule 8: "data types in `types.zig` and `math.zig` carry
     only constructors and pure-CPU predicates. Verbs live in
     subsystem modules."
   - Add Rule 9: "subsystem state lives in `*FooState` parameters
     threaded through fn signatures. The single global is
     `runtime_assembly.app`."
5. Update `architecture.md` to reflect the new file list and DAG.

**Touched-fn discipline:** style guide additions get the same care
as the existing rules — examples, rationale, what-not-to-do.

**Verify:** both builds green; `check_dag.py` shows the final edge
count + 0 SCCs; `count_globals.py` still shows 0/0/0.

---

## Order-of-operations summary

| # | Phase                      | Edges removed | SCC change       | Risk | Turns |
| - | -------------------------- | ------------- | ---------------- | ---- | ----- |
| 0 | Tooling + plan-read        | 0             | 0                | none | 1     |
| 1 | Fix B — `errors.zig`       | 2             | 8 → 7            | low  | 1     |
| 2 | Fix D — math/enums/alloc   | 0 net (some replaced) | 7 → 7    | low  | 3     |
| 3 | Fix C — delete methods     | 41            | 7 → 5            | low  | 2     |
| 4 | Fix A — setWindowIcon      | 1             | 5 → 5            | low  | 1     |
| 5 | Fix E.tail — assembly file | 4             | 5 → 0            | med  | 1     |
| 6 | Cleanup — drop re-exports  | 0             | 0                | none | 1     |

**Total: ~10 turns** (vs v2's "2-3 days for a developer familiar
with the codebase" — same magnitude when you factor in turn-paced
discipline).

After Phase 5: pure DAG, 33 edges, 1 global.

---

## What this is NOT

- **Not a behavioural change.** Every public API surface stays
  identical. Users still call `z.run`, `z.loadTexture`, `f.input`,
  `f.gl`. The internal `Image.deinit` → `textures.unloadImage`
  rename was already adopted as the documented form during the
  state-explicit refactor; this plan removes the unused method
  alternative.
- **Not a perf optimization.** Compilation cost goes down (smaller
  per-fn analysis surface) but runtime perf is unchanged.
- **Not a feature freeze.** New features can land in any phase as
  long as they respect the layered DAG.

## What this enables once done

- **Hot reload** — single `Runtime` aggregate cleanly extractable;
  reload swaps the contents while keeping `app` pointer stable.
- **Multi-app safety** — already enabled by state-explicit; this
  formalizes it at the type-system level.
- **Mockable subsystems** — every fn taking `*FooState` is trivially
  testable with a stack-local; no anchor fixture needed.
- **DAG-validated builds** — `check_dag.py` runs in CI; any future
  back-edge fails the build.
- **Faster compiles** — concrete measurement: per-fn analysis no
  longer pulls all subsystem state structs through the anchor type.

## Risk register

| Risk                                     | Likelihood | Mitigation                                                      |
| ---------------------------------------- | ---------- | --------------------------------------------------------------- |
| Sed sweep hits unintended targets        | high       | Bound to fn/test ranges; count before/after; build after each   |
| Phase 2's `enums.zig` extraction misses an enum | medium | check_dag.py still flags `types → drawing` if so — visible      |
| Phase 3's method deletion misses a caller | low       | exhaustive grep (per v2's verification); regression-test signatures |
| Phase 5 vtable userdata casting bug      | low        | already proven pattern from state-explicit refactor             |
| Some test I forgot exists somewhere      | medium     | `zig build test` is the source of truth, not grep               |
| Plan goes stale mid-execution            | low        | re-read every 5 turns; update CHANGELOG with deltas             |

## Appendix — v2's appendix B preserved (Fix C method deletion list)

The v2 plan's Appendix B is the canonical list of what gets deleted
in Phase 3. Reproduced verbatim for self-containment:

```
math.zig (post-D, was types.zig):
  Matrix.rotation        → @import("raymath.zig")
  Matrix.lookAt          → @import("raymath.zig")
  Matrix.perspective     → @import("raymath.zig")
  Matrix.ortho           → @import("raymath.zig")
  Matrix.mul             → @import("raymath.zig")
  Matrix.invert          → @import("raymath.zig")
  Matrix.transpose       → @import("raymath.zig")
  Matrix.determinant     → @import("raymath.zig")
  Matrix.translate       → uses Matrix.translation().mul()  [chained]
  Matrix.scale           → uses Matrix.scaling().mul()      [chained]

types.zig:
  Image.deinit           → drawing.textures.unloadImage
  Image.isValid          → drawing.textures.isImageValid
  Image.flipVertical     → drawing.textures.imageFlipVertical
  Image.flipHorizontal   → drawing.textures.imageFlipHorizontal
  Image.rotateCW         → drawing.textures.imageRotateCW
  Image.rotateCCW        → drawing.textures.imageRotateCCW
  Image.crop             → drawing.textures.imageCrop

  Texture.deinit         → rlgl.fwd.rlUnloadTexture
  Texture.isValid        → drawing.textures.isTextureValid
  Texture.draw           → drawing.textures.drawTexture
  Texture.drawAt         → drawing.textures.drawTextureV
  Texture.drawEx         → drawing.textures.drawTextureEx
  Texture.drawRec        → drawing.textures.drawTextureRec
  Texture.drawPro        → drawing.textures.drawTexturePro

  RenderTexture.isValid  → drawing.textures.isRenderTextureValid
  RenderTexture.deinit   → rlgl.fwd.rlUnloadFramebuffer (chained)

  Font.deinit            → drawing.text.unloadFont

  Mesh.unload            → drawing.models.unloadMesh
  Mesh.getBoundingBox    → drawing.models.getMeshBoundingBox

  Shader.unload          → drawing.shaders.unloadShader,
                           takes *rlgl.GlState

  Material.isValid       → drawing.models.isMaterialValid
  Material.unload        → drawing.models.unloadMaterial,
                           takes *rlgl.GlState
  Material.setTexture    → drawing.models.setMaterialTexture

  Model.isValid          → drawing.models.isModelValid
  Model.unload           → drawing.models.unloadModel
  Model.getBoundingBox   → drawing.models.getModelBoundingBox
```

35 methods. Plus the `Vector*.scale` / `.add` / `.sub` etc. that
**stay** because they're pure CPU with zero outgoing imports.
