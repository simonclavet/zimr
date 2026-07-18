# Tint vs spv2wgsl: architectural comparison

Source studied: `lang/spirv/reader/ast_parser/` from the `tint-wasm` build —
`function.h` (1362 lines), `construct.h` (285 lines), `ast_parser.h` (964 lines).
No `.cc` files shipped, but the headers document the algorithm in extensive
detail (Tint is C++ where most algorithms are visible through the class shape
and method names).

## Side-by-side

| Concept | Tint | spv2wgsl (ours) |
|--|--|--|
| **Passes** | 12 separate analysis passes before emission | 1 linear pass during emission |
| **Block traversal order** | Reverse structured post-order, **pre-computed** | SPIR-V binary order |
| **Construct kinds** | Function, IfSelection, SwitchSelection, Loop, **Continue** (separate!) | sel, loop |
| **Construct shape** | `[begin_pos, end_pos)` range in block order + `scope_end_pos` (loop's WGSL scope extends past `end_pos` to include its Continue construct) | merge label (a single u32) |
| **Construct linkage** | `parent`, `enclosing_loop`, `enclosing_continue`, `enclosing_loop_or_continue_or_switch` | none — only a stack |
| **Per-block metadata** | Full `BlockInfo` struct: `pos`, `merge_for_header`, `continue_for_header`, `header_for_merge`, `header_for_continue`, `is_continue_entire_loop`, `construct` (back-pointer), `succ_edge` (per-edge kind map), `case_head_for`, `default_head_for`, `true_head`, `false_head`, `premerge_head`, `flow_guard_name`, `hoisted_ids`, `phi_assignments`, `phis_needing_state_vars` | none |
| **Edge classification** | Every CFG edge labeled: `kBack`, `kSwitchBreak`, `kLoopBreak`, `kLoopContinue`, `kIfBreak`, `kCaseFallThrough`, `kForward` | none — we treat every branch the same |
| **SSA values** | `DefInfo` per ID with `requires_named_let_def`, `requires_hoisted_var_def`, first/last use positions, defining block pos | every result becomes a `let` at definition site |
| **Phi handling** | `phi_assignments` list on the source block: every branch into a phi-block carries explicit assignments to the phi's state variable, emitted **before the branch terminator at the predecessor** | phi vars declared at function top; phi instruction emits `bool()` placeholder ⚠ |
| **OpUndef** | Zero-init of the declared type | `bool()` placeholder ⚠ |
| **Value inlining** | Heuristic: combinatorial + single use + same construct → inline at use; otherwise `let` | always `let`, every result |
| **Premerge** | Tracks `premerge_head` — the block where then/else reconverge before the real merge | unsupported |
| **Flow guards** | Emits a boolean guard variable when a construct has both if-break and forward edges that need to skip subsequent code | unsupported |

## The Tint pass pipeline (FunctionEmitter::EmitBody)

```
1.  RegisterBasicBlocks()              — populate BlockInfo map keyed by label id
2.  TerminatorsAreValid()              — every branch targets a block in this fn
3.  RegisterMerges()                   — cross-link header ↔ merge ↔ continue;
                                         detect "continue == loop header" (single-block loop)
4.  ComputeBlockOrderAndPositions()    — reverse structured post-order;
                                         every block gets a unique position
5.  VerifyHeaderContinueMergeOrder()   — structural invariant check
6.  LabelControlFlowConstructs()       — every block tagged with its nearest
                                         enclosing Construct; ConstructList built
7.  FindSwitchCaseHeaders()            — match case literals to target blocks
8.  ClassifyCFGEdges()                 — every successor edge gets an EdgeKind
9.  FindIfSelectionInternalHeaders()   — locate true_head, false_head, premerge_head
10. RegisterLocallyDefinedValues()     — DefInfo for every locally-defined ID
11. FindValuesNeedingNamedOrHoistedDefinition()
                                       — decide for each value: inline / let / hoisted var
12. EmitFunctionVariables()            — emit hoisted vars + locals at function top
13. EmitFunctionBodyStatements()       — walk blocks in structured order; at terminators
                                         use the classified edge to emit
                                         break / continue / fall-through / structured branch
```

## Where this matters for us right now

Our broken outputs (before the recent fix) had this pattern:

```wgsl
loop {
  if (iter_cond) {
  } else {                    // ← false branch goes to LOOP MERGE
    let early = ...;
    if (early_break_cond) {
      ...
    }
  }
} continuing { ... }          // ← invalid syntax (we patched this)
```

What Tint would do with the same SPIR-V:

1. `ClassifyCFGEdges` marks the iter-false edge as `kLoopBreak`
2. At the iter-check block, instead of opening a scoped `if/else`,
   `EmitNormalTerminator` emits `if (!iter_cond) { break; }`
3. The continue construct is emitted as a separately-positioned block
   in structured order, inside the loop's WGSL scope, producing
   `loop { ... continuing { ... } }` (always correct)

Our recent fix made the second emission correct. But the first one — the
break-instead-of-scoped-if — is still missing. The remaining "broken"
shaders (the three fractals, blocked by OpPhi + OpUndef placeholders) need
the **edge classification** + **phi-at-predecessor** patterns from Tint.

## What I'd port piecewise (no full rewrite needed)

These are incremental — each is a small change that moves us closer to Tint's
correctness without requiring the full multi-pass restructure:

1. **Pre-pass: label → binary-offset map.** One sweep over `s.inst_off`,
   record where each `OpLabel` lives. Costs O(n) memory; lets us answer
   "is label X in scope of frame Y?" in the emission phase.

2. **Pre-pass: header → merge / continue map.** When we see `OpSelectionMerge`
   or `OpLoopMerge`, record `merge_for_header` and (for loops)
   `continue_for_header`. Replaces our current pending-state hack.

3. **Edge classification at BranchConditional.** For each branch, look up
   whether the target is the merge / continue of an enclosing frame. Then:
   - `true → enclosing_merge, false → forward` → `if (cond) { break; }`
   - `false → enclosing_merge, true → forward` → `if (!cond) { break; }`
   - `true → enclosing_continue, false → forward` → `if (cond) { continue; }`
   - both forward → current scoped-if behavior
   - both → enclosing_merge → just `break;` (no if)

4. **Same for plain OpBranch.** If the target is an enclosing merge:
   `break;`. Enclosing continue: `continue;`. Otherwise fall-through.

5. **OpPhi assign-at-predecessor.** When emitting any block, before its
   terminator branch, look up `phi_assignments` for that successor and emit
   `phi_N = source_value;`. Requires either (a) a small second-pass that
   collects phi assignments per source block, or (b) processing phis at
   the destination label, walking back to find which previous block
   provided the value.

6. **OpUndef → typed zero-init.** Trivial — same pattern as our existing
   module-scope undef handling.

(1)+(2)+(3)+(4) gives us proper structured-CF emission for break/continue.
(5)+(6) re-enables fractals. Combined, we'd cover 100% of what Zig's
SPIR-V emit produces.

## What I would NOT port

- **Multi-pass AST.** Tint builds a full AST then post-processes. Ours
  emits text directly. The AST approach is more correct (you can rewrite
  invalid output) but is several thousand lines of plumbing we don't need
  if we get the linear emission right.

- **Premerge / flow-guards.** These handle pathological SPIR-V patterns
  (reconvergence before merge; mixed if-break and forward edges). Zig
  doesn't emit these patterns. Skip until proven necessary.

- **Combinatorial inlining heuristic.** Tint's "inline single-use,
  same-construct combinatorials" is purely a readability optimization.
  Our `let _NNN: T = ...` chain is verbose but correct. Skip.

## On porting miniray to Zig

My honest take: **don't.** Reasoning:

1. Miniray has its own bugs (panic on `select(...)`, doesn't recognize
   WGSL `continuing` syntax). Porting buggy code to Zig produces buggy
   Zig code. Not progress.

2. Miniray only does syntax validation. Real WebGPU validates a lot more:
   type compatibility, binding layout, vertex attribute formats,
   bind-group access mode matching. Miniray says "OK" to plenty of WGSL
   that real Chrome rejects.

3. The current setup — shell out to the miniray WASM at build time — is
   one shell command in `build.zig`. Cost: ~0. Value: catches the
   structural bug class.

4. If we want a real validator at build time, Tint compiles to WASM too
   (see `tint-wasm-main`!) and is the reference implementation. That would
   be the move: shell out to `tint-wasm` to convert our WGSL through
   Tint's parser and check for errors. Same shape as miniray, way more
   coverage. Zero porting required.

5. The energy to port miniray (2-3k LOC of Go runtime + parser) is
   better spent on the spv2wgsl improvements above. Those produce
   correct WGSL; the validator's job is then trivial.

So: yes to point 1 (study Tint, look for more bugs) — done above. Yes
to point 2 (more bugs in our version) — found and listed above. Friendly
no to point 3 (port miniray to Zig). Counter-proposal: wire `tint-wasm`
into the build as our validator. Same workflow, real coverage.
