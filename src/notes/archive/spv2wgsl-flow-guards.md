# spv2wgsl: Tint-style flow guards for early-exit if-else

## The bug

Zig 0.16's structured SPIR-V backend emits this pattern for any one-sided
`if` whose body contains a `break`/`continue` out of an outer loop or
selection:

```spirv
block X:  OpSelectionMerge %M
          OpBranchConditional %cond, %T, %M    ; FALSE goes directly to M
block T:  ...
          OpBranch %OUTER                       ; skips M entirely
block M:  ... phi predecessor assignments ...
          OpBranch %OUTER

block M2 (= %OUTER's body somewhere later):
          ; reads phi
```

The `OpPhi` at the convergence point has incoming pairs `(T_value, T)` and
`(M_value, M)`. M is BOTH the sel_merge AND the false-branch target — but T
branches OUT (to OUTER) without passing through M. So M's body only
executes when `cond` was false.

Naive linear emission produces:

```wgsl
if (cond) {
  T_body
  phi = T_value
}
phi = M_value          ; ← unconditional, OVERWRITES the true-branch phi!
read phi
```

Concretely, in our diagnostic mandelbrot with `out_color = red` forced at
the end of `shaderMain`, the loop's iteration state machine produces an
`if (phi1225 == 145u) { phi1975 = red }` and then `phi1975 = undef`
unconditionally after the if.  Result: canvas renders zero, not red.

## What I tried and why it broke

The first attempt: detect the pattern and re-point the if-else's merge at
T's actual branch target (the convergence point). In linear emission:

```
if (cond) {
  T_body
  phi = T_value
} else {
  M_body
  phi = M_value
}
read phi
```

This works for the simplest case (T → OUTER, M → OUTER, both converge at
OUTER) but produces unbalanced braces when:

- T's target isn't reached as a structured-merge label in linear order
  (e.g. T branches to a sibling construct's merge which is several
  outer-frame pops away)
- The if-else lives inside a loop and T's target is "wherever the loop
  body falls into next"
- Multiple early-exit if-elses nest

The mandelbrot WGSL with the hack hit `error: expected '}' for if
statement` at line 122:1 because four `{` braces (for an inner if, an
outer if, a loop, and the function) never closed before `return outputs;`.

## Tint's approach: flow guards

Tint's SPIR-V reader (`lang/spirv/reader/ast_parser/function.{h,cc}`) does
a full CFG analysis pre-pass with these stages:

```
RegisterBasicBlocks
 → TerminatorsAreValid
 → RegisterMerges                       ; header ↔ merge cross-links
 → ComputeBlockOrderAndPositions        ; reverse structured post-order
 → VerifyHeaderContinueMergeOrder
 → LabelControlFlowConstructs           ; assign each block to its construct
 → FindSwitchCaseHeaders
 → ClassifyCFGEdges                     ; succ_edge[B] = EdgeKind for each successor
 → FindIfSelectionInternalHeaders       ; true_head/false_head/premerge_head/flow_guard
```

The `EdgeKind` enum (function.h:60-85) classifies CFG edges:

- `kBack` — back-edge (loop continue target → header)
- `kSwitchBreak` / `kLoopBreak` — break to merge of enclosing switch/loop
- `kLoopContinue` — to continue target of nearest enclosing loop
- `kIfBreak` — branch to merge of enclosing if-selection (NOT a break or
  continue)
- `kCaseFallThrough` — switch case fall-through (invalid in WGSL)
- `kForward` — forward edge inside a construct

The relevant case for us: **a block has both a `kIfBreak` edge AND a
`kForward` edge, but no merge instruction on the source block**.  That's
the early-exit pattern.  Tint sets `BlockInfo::flow_guard_name` on the
enclosing if-selection's header.

Emission then uses three helpers:

- `PushGuard(flow_guard_name, end_id)` — emits `if (flow_guard) {` and
  pushes a statement block that closes at `end_id`
- The flow_guard variable is hoisted to function scope, initialized
  `true`
- `MakeBranchDetailed(src, dest, &flow_guard_name_ptr)` — when the branch
  is the if-break edge that needs a guard, the caller emits
  `flow_guard = false;` before the branch

Conceptually our mandelbrot output becomes:

```wgsl
var flow_guard_M: bool = true;
if (cond) {
  T_body
  phi = T_value
  flow_guard_M = false;
  // (implicit fall through to OUTER)
}
if (flow_guard_M) {
  M_body
  phi = M_value
}
// OUTER reads phi
```

When `cond` was true: T runs, sets `flow_guard_M = false`, phi = T_value;
the `if (flow_guard_M)` block is skipped; phi stays T_value. ✓
When `cond` was false: T skipped; `flow_guard_M` still true; M runs,
phi = M_value. ✓

## Implementation plan for spv2wgsl

To match Tint's algorithm we need a real CFG pre-pass.  Rough stages,
matching Tint's structure:

### Stage A: basic block registration (~50 LOC)

Walk function body once.  Build:

```zig
const BlockInfo = struct {
    id: u32,
    pos: u32 = invalid_pos,                // position in linear order
    merge_for_header: u32 = 0,
    continue_for_header: u32 = 0,
    header_for_merge: u32 = 0,
    header_for_continue: u32 = 0,
    construct: ?*Construct = null,
    terminator_idx: usize = 0,             // index into inst_off of terminator
    successors: std.BoundedArray(u32, 2),  // 0, 1, or 2 successors
    succ_edge: [2]EdgeKind = .{.forward, .forward},

    // if-selection bookkeeping
    true_kind: EdgeKind = .forward,
    false_kind: EdgeKind = .forward,
    true_head: u32 = 0,
    false_head: u32 = 0,
    premerge_head: u32 = 0,
    flow_guard_name: []const u8 = "",
};
const block_info: std.AutoHashMapUnmanaged(u32, BlockInfo) = ...;
```

### Stage B: merge registration (~30 LOC)

Walk again, find OpSelectionMerge / OpLoopMerge, cross-link
header↔merge in block_info.

### Stage C: structured post-order (~80 LOC)

DFS from the entry block, visiting:
1. true successor first (or false for a loop header) — Tint's
   `ComputeBlockOrderAndPositions` documents the exact order
2. continue target (for loop headers)
3. merge target last
Push to `block_order` on POST-order; reverse at the end.

This is the order Tint emits blocks in.  It is NOT the SPIR-V file order
— it's an explicit CFG traversal that respects structured CF.

### Stage D: construct labeling (~60 LOC)

A `Construct` is one of:
- function body
- if-selection (header → merge)
- switch-selection (header → merge)
- loop (header → merge, plus continue target)
- continue (continue target → merge)

Walk block_order; for each block, find its innermost enclosing
construct based on position relative to construct headers / merges.
Cross-check: each block must be inside exactly one construct chain.

### Stage E: edge classification (~100 LOC)

For each block B in block_order, for each successor S of B:
- If S is a continue target whose loop encloses B → `kLoopContinue`
- If S is a loop merge whose loop encloses B → `kLoopBreak`
- If S is a switch merge whose switch encloses B → `kSwitchBreak`
- If S is an if-merge whose if encloses B → `kIfBreak`
- Else if S is a back-edge → `kBack`
- Else → `kForward`

### Stage F: find if-selection internal headers (~80 LOC)

For each if-selection header H with merge M:
- `true_head` = H's true target if it's inside the construct, else 0
- `false_head` = H's false target if it's inside the construct, else 0
- `premerge_head` = first block in the construct that's a join point of
  multiple internal branches but is NOT the merge
- `flow_guard_name` = "guard_<H.id>" if any block in the construct has
  BOTH a `kIfBreak` edge AND a `kForward` edge in its successors

### Stage G: emit, in block_order (~200 LOC of refactor)

Replace the current linear "walk SPIR-V file order" emission with a
walk over `block_order`.  For each block B:

1. If B is a header, emit construct opening (`if (cond) {`, `loop {`, etc.).
   If the construct needs a flow guard, emit
   `var <flow_guard>: bool = true;` BEFORE the construct opening.
2. Emit B's non-terminator instructions, plus pre-terminator phi
   assignments.
3. Emit B's terminator, classified by edge kind:
   - `kLoopBreak` / `kLoopContinue` / `kSwitchBreak` → `break;` / `continue;`
     (or nothing, if implicit at end of construct)
   - `kIfBreak` → set `flow_guard = false;` if this if-selection has one,
     then implicit fall-through (no statement)
   - `kBack` → nothing (implicit loop iteration)
   - `kForward` → either fall-through (no statement) or some explicit
     statement depending on whether we're branching to a non-adjacent block
4. If the next block in block_order isn't B's natural successor, we may
   need to close constructs and re-open guards.  See Tint's
   `EmitStatementsInBasicBlock` for the details.

## Estimate

Total work: **~600 lines of new Zig code**, plus refactor of the existing
linear emission (~200 LOC affected).  Time estimate: **2–3 focused days**.

The current spv2wgsl is a single-pass linear translator (~2400 LOC).
This redesign moves it to a two-phase
(CFG-analyze → emit-by-block-order) translator while keeping the body
of each block's emission largely the same.

## What we can ship sooner

A **subset** of the algorithm — just Stage F's `flow_guard_name`
detection plus the three emission points — could handle the specific
mandelbrot pattern without a full block-order refactor.  Rough plan:

1. Pre-pass identifies "header H whose construct contains a block with
   both a kIfBreak edge and a kForward edge" — for the mandelbrot case
   that's just the OpBranchConditional whose false_label == sel_merge
   AND whose true_label's successor != sel_merge.
2. At that OpBranchConditional:
   - Emit `var flow_guard_<H>: bool = true;` BEFORE the existing `if (cond) {`
   - (still open the if-else with the original merge as merge — no
     re-pointing)
3. At the true branch's OpBranch (the early exit):
   - Emit `flow_guard_<H> = false;` just before the existing pre-terminator
     phi-assignment block
4. At the sel_merge label (M):
   - Close the `}` for the if-true branch as currently
   - Emit `if (flow_guard_<H>) {`
   - Push a new frame that will close at M's natural continuation
     (the original outer construct)

Open question: where does the `if (flow_guard) { ... }` close?  Tint's
answer is: at the same end_id as the original if-selection's merge.
For us, that's the next time we'd naturally close out of the construct
— typically at the next loop iteration boundary or function return.

This subset is **~150 LOC** and might be doable in one afternoon, but
it has the same fragility concerns as my first attempt: it depends on
the linear emission reaching the right close labels.  The full
block-order refactor is the robust solution.

## References

- `/tmp/tint-wasm-main/lang/spirv/reader/ast_parser/function.h` —
  reading SPIR-V into Tint AST, includes EdgeKind, BlockInfo, all the
  pre-pass method declarations and field documentation
- `/tmp/tint-wasm-main/lang/spirv/reader/ast_parser/construct.h` —
  Construct type hierarchy
- `/tmp/tint-wasm-main/lang/spirv/reader/ast_parser/ast_parser.h` —
  module-level orchestration
- SPIR-V structured CF rules: SPIRV-spec §2.11 "Structured Control Flow"
- The actual `.cc` implementation is at
  https://dawn.googlesource.com/dawn/+/refs/heads/main/src/tint/lang/spirv/reader/ast_parser/function.cc
  (not in our local upload — it's the wasm package which is headers-only)
