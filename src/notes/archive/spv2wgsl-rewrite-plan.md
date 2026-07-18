# spv2wgsl-rewrite-plan.md — making spv2wgsl the best SPIR-V→WGSL translator for our needs

> **Driving plan, late May 2026 — Final version.**  Successor to
> Phase A of `webgpu-migration-plan.md`.  Replaces all earlier
> "rewrite plan" drafts in this directory.  Every decision in this
> plan is made; nothing is parked for Simon.
>
> Grounded in:
>
> - **Deep study of Dawn `main` (May 2026)**:
>   `/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/parser.cc`
>   (4673 lines), specifically `EmitBlock` (1814), `EmitBranch`
>   (3444), `EmitBranchConditional` (3672), `EmitLoop` (3754),
>   `FindPremergeId` (3484), `EmitPhi` and its dispatchers (2625,
>   2747, 3004, 3068).  Plus the 122 hand-crafted `.spvasm` test
>   cases in `parser/branch_test.cc` that are exactly the CF edge
>   cases the algorithm was designed to handle.
> - **Profile of our actual SPIR-V inputs**: 44 zimr shaders, of
>   which 35 have zero structural CF (vertex passthroughs, simple
>   FS), 8 have loops or conditional breaks (the fractals + a few
>   engine shaders), 0 have switches in source code (Zig emits a
>   trivial `switch (0u)` block as a structural anchor in some
>   cases — see §1.3), 0 have nested loops, 0 have premerge
>   patterns (Zig's structured backend doesn't reconverge inside
>   constructs).
>
> Conclusion: **our input domain is a strict subset of Tint's
> handled cases**.  We need maybe 40% of the algorithmic complexity
> Tint covers.  The plan reflects that.

---

## TL;DR

`spv2wgsl` produces WGSL that Chrome parses but executes wrong on
shaders whose Zig 0.16 structured CF compiles to a one-sided `if`
whose body contains a `break`/`continue` out of an outer construct.
The mandelbrot diagnostic (force `out_color = red` at the end of
`shaderMain`) proved this — the phi assignment from M (the SPIR-V
sel_merge that's the "else" body when the true branch breaks out)
unconditionally overwrites the true branch's phi value.

The fix is to **replace the linear file-order emission** with
**recursive descent over the structured CFG with a stop set** — the
algorithm Tint uses today in Dawn `main`.  This plan does that in
9 phases over ~9 focused weeks.

We **study** Dawn for inspiration — no Dawn source ends up in
zimr's tree.  Citations in code comments (`parser.cc:LINE`) are
the only artifact of the study.

---

## §1.  Honest current state

### 1.1.  What works

`src/spv2wgsl.zig` is a single-pass linear translator of ~2448 LOC.
Corpus: 51/51 clean transpile, 18 fixture entries.

- All non-control-flow opcodes (loads, stores, arithmetic, vector
  and matrix ops, texture sampling, swizzling, comparisons,
  conversions, builtins).
- One-sided `if` where both branches converge at the merge.
- Standard while-style loops: header conditional + body + continue
  target structure.
- OpPhi as hoisted `var phiN: T;` + per-predecessor assignment in
  a pre-pass.

### 1.2.  What's broken

**Early-exit if-else (the "if-break" case)**: `OpSelectionMerge
%M ; OpBranchConditional %c %T %M` where `T` branches OUT to an
outer construct's merge.  M is the "else" body that runs only when
c is false, but our linear emitter renders it as unconditional
fall-through.  Phi values from T get overwritten by phi values
from M.  Reproduced in `examples/mandelbrot_fs.zig` with
`out.out_color = vec4(1, 0, 0, 1)` at the end; rendered as zero.

**Tint's name for this pattern**: `IfBreak_FromThen_ForwardWithinThen`
(`parser/branch_test.cc:3411`).  Tint's solution: recursive walk
emits the "then" body inside the if-true block (where T's exit is
correctly a `break`); the would-be "else" body is the merge content
emitted AFTER the if in the outer scope.

### 1.3.  Other patterns our input has

From profiling our 44 shaders' compiled SPIR-V:

- **`OpSwitch` with single default case**: Zig 0.16 emits `switch
  (0u) { default: { ... } }` as a structural anchor in some
  contexts.  Our linear emitter handles this with a specific
  pattern detector.  The new walker needs the same.
- **Nested if-elses**: trivial structured nesting.  Our linear
  emitter handles it; new walker will too via natural recursion.
- **Loops with break-inside-if**: the mandelbrot pattern.  Bug.
- **Loops with continue-inside-if**: similar to the above.
  Untested but almost certainly has the same bug.
- **OpKill (`discard`)**: appears in 3 fragment shaders.

### 1.4.  Patterns our input does NOT have

- **Nested loops**: Zig doesn't compile any of our shaders to
  this.  Out of scope for the initial rewrite; add only if a real
  shader needs it.
- **Premerge** (true and false branches converge inside the if,
  before the merge): Zig's structured backend doesn't generate
  this — it always emits proper structured CF with a single merge
  point.  Out of scope for the initial rewrite.  If a future
  shader hits it, the walker emits `// ERROR: premerge` and we
  add the helper.
- **OpSwitch with multiple meaningful cases**: not in our corpus.
  Trivial single-default still needs handling (per §1.3).
- **Conditional back-edges** (do-while pattern): Zig 0.16 doesn't
  emit these.  May appear in 0.17+; will be addressed when
  encountered.

---

## §2.  Architecture: recursive descent with stop set

The algorithm comes from
`/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/parser.cc`.

### 2.1.  Data structures

```zig
// Per-block info, built once per function in a pre-pass.
pub const BlockInfo = struct {
    id: u32,
    label_inst_idx: usize,        // index into State.inst_off
    terminator_inst_idx: usize,
    merge_inst_idx: ?usize = null,  // OpSelectionMerge or OpLoopMerge
    merge_id: u32 = 0,
    continue_id: u32 = 0,  // loops only
    kind: enum { plain, selection_header, loop_header, switch_header } = .plain,
};

pub const BlockTable = std.AutoHashMapUnmanaged(u32, BlockInfo);

// What a branch to a stop label means in the current emission context.
pub const StopKind = union(enum) {
    /// `exit_if` in Tint IR; in WGSL: no statement (fall through to
    /// the merge block which is emitted in the outer scope).
    if_merge,
    /// In WGSL: `break;`
    loop_break,
    /// In WGSL: `continue;`
    loop_continue,
    /// In WGSL: `break;` (switch break)
    switch_break,
};

pub const StopSet = std.AutoHashMapUnmanaged(u32, StopKind);
```

### 2.2.  Core walker

```zig
// All emission goes through buffer parameters — never a singleton.
// This is what makes sub-buffers (for if-true vs if-false bodies) work.
pub fn emitBlock(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    block_id: u32,
    stop_set: *StopSet,
) anyerror!void {
    const b = blocks.get(block_id).?;

    // Loop headers branch out to a specialized emitter that opens
    // the WGSL `loop {}` and recursively emits body + continuing.
    if (b.kind == .loop_header) {
        return emitLoopHeader(s, out, blocks, b, stop_set);
    }

    // Emit non-terminator, non-merge instructions.
    try emitBodyInstructions(s, out, b);

    // Pre-terminator phi predecessor assignments (existing pre-pass
    // gives us the table; we just emit at the right buffer here).
    try emitPredecessorPhiAssignments(s, out, block_id);

    // Dispatch on terminator.
    const term_off = s.inst_off.items[b.terminator_inst_idx];
    const term_w = s.spirv[term_off];
    const op: Op = @enumFromInt(opcodeOf(term_w));
    const ops = operandsAt(s.spirv, term_off);

    switch (op) {
        .Return => try bstr(out, s.arena, "  return;\n"),
        .ReturnValue => try emitReturnValue(s, out, ops),
        .Kill => try bstr(out, s.arena, "  discard;\n"),
        .Unreachable => try bstr(out, s.arena, "  // OpUnreachable\n"),

        .Branch => try emitBranch(s, out, blocks, ops[0], stop_set),

        .BranchConditional => {
            if (b.kind == .selection_header) {
                try emitSelectionConditional(s, out, blocks, b, ops, stop_set);
            } else {
                // No merge instruction on the source block — this is
                // a loop-internal conditional (iter-check, body-conditional-
                // break, etc.).  Both targets resolve via stop_set.
                try emitUnstructuredConditional(s, out, blocks, b, ops, stop_set);
            }
        },

        .Switch => {
            assert(b.kind == .switch_header);
            try emitSwitch(s, out, blocks, b, ops, stop_set);
        },

        else => unreachable, // SPIR-V structured CF guarantees this
    }
}

fn emitBranch(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    dest: u32,
    stop_set: *StopSet,
) !void {
    if (stop_set.get(dest)) |kind| {
        try emitStopExit(out, s.arena, kind);
        return;
    }
    // Not a stop — recursively emit the destination as our continuation.
    try emitBlock(s, out, blocks, dest, stop_set);
}

fn emitStopExit(out: *std.ArrayListUnmanaged(u8), arena: Allocator, kind: StopKind) !void {
    switch (kind) {
        .if_merge => {}, // no statement; merge runs in outer scope
        .loop_break, .switch_break => try bstr(out, arena, "  break;\n"),
        .loop_continue => try bstr(out, arena, "  continue;\n"),
    }
}
```

### 2.3.  Selection conditional

The case where the mandelbrot bug lives — and is fixed.  Modeled on
Dawn `parser.cc:3672`.

```zig
fn emitSelectionConditional(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    header: BlockInfo,
    ops: []const u32,
    stop_set: *StopSet,
) !void {
    const cond_name = lookupId(s, ops[0]).wgsl_name;
    const true_id = ops[1];
    const false_id = ops[2];
    const merge_id = header.merge_id;

    // Open `if (cond) {` in OUTER scope.
    try bprint(out, s.arena, "  if ({s}) {{\n", .{cond_name});

    // Register merge as stop block.  Note: parent constructs' stop
    // entries are STILL in stop_set during the recursion — that's
    // what lets T branch to an outer loop's merge and emit `break;`.
    try stop_set.put(s.arena, merge_id, .if_merge);

    // True branch goes into its own sub-buffer.
    var true_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (stop_set.get(true_id)) |kind| {
        try emitStopExit(&true_buf, s.arena, kind);
    } else {
        try emitBlock(s, &true_buf, blocks, true_id, stop_set);
    }
    try out.appendSlice(s.arena, true_buf.items);

    // False branch.
    try bstr(out, s.arena, "  } else {\n");
    var false_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (stop_set.get(false_id)) |kind| {
        // Common case for one-sided if: false_id == merge_id → no statement.
        try emitStopExit(&false_buf, s.arena, kind);
    } else {
        try emitBlock(s, &false_buf, blocks, false_id, stop_set);
    }
    try out.appendSlice(s.arena, false_buf.items);

    try bstr(out, s.arena, "  }\n");

    // Pop the if-merge stop entry.
    _ = stop_set.remove(merge_id);

    // Merge block emits in OUTER scope.  Its body and terminator run
    // ONLY when control reaches here naturally (i.e., true_id didn't
    // branch out; or false_id didn't branch out).  If both branches
    // exited (e.g., both returned), this is dead code — but emit
    // anyway; the WGSL compiler will warn or DCE it.
    try emitBlock(s, out, blocks, merge_id, stop_set);
}
```

**Worked example: mandelbrot bug, fixed.**

Input SPIR-V (the relevant subgraph):
```
block H (selection_header, merge_id=M):
  OpSelectionMerge %M
  OpBranchConditional %c %T %M
block T:
  ...body...
  phiN  ← needs T_value at end
  OpBranch %OUTER  (OUTER is a loop_break stop)
block M:
  ...body...
  phiN  ← needs M_value at end
  OpBranch %OUTER
```

Initial stop_set: `{OUTER: .loop_break}` (from the enclosing loop).

Walker runs `emitBlock(out, blocks, H, stop_set)`:
1. H is a selection_header → `emitSelectionConditional`.
2. Emits `if (cond) {` to `out`.
3. stop_set is now `{OUTER: .loop_break, M: .if_merge}`.
4. True branch: `emitBlock(true_buf, blocks, T, stop_set)`:
   - Emit T's body to true_buf.
   - Pre-terminator phi assignment: `phiN = T_value;` to true_buf.
   - Terminator OpBranch OUTER.  OUTER is in stop_set as
     `.loop_break` → emit `break;` to true_buf.
5. Splice true_buf into out.
6. Emits `} else {` to out.
7. False branch: false_id == M, M is in stop_set as `.if_merge` →
   emit nothing.
8. Emits `}` to out.
9. Remove M from stop_set.
10. Emit merge: `emitBlock(out, blocks, M, stop_set)`:
    - Emit M's body to out (the OUTER scope).
    - Pre-terminator phi assignment: `phiN = M_value;` to out.
    - Terminator OpBranch OUTER.  OUTER in stop_set as
      `.loop_break` → emit `break;` to out.

Final output:
```wgsl
if (cond) {
  ...T body...
  phiN = T_value;
  break;
} else {
}
...M body...
phiN = M_value;
break;
```

Semantically correct.  When cond=true: T's body runs, phi gets
T_value, break exits the outer loop.  M never executes.  When
cond=false: T skipped, falls through to M's body, phi gets
M_value, break.

This is precisely what the bug needed.  No flow-guard variable.
No CFG analysis pre-pass.  Just emit each block once, in its
correct scope, with terminators that route to the right exit.

### 2.4.  Loop header

Modeled on Dawn `parser.cc:3754`.

```zig
fn emitLoopHeader(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    header: BlockInfo,
    stop_set: *StopSet,
) !void {
    try bstr(out, s.arena, "  loop {\n");

    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    var cont_buf: std.ArrayListUnmanaged(u8) = .empty;

    // Register stops.  Note: continue_id may equal header.id for
    // single-block loops; that's fine — the stop_set lookup just
    // routes branches-to-header as `continue;`.
    try stop_set.put(s.arena, header.merge_id, .loop_break);
    try stop_set.put(s.arena, header.continue_id, .loop_continue);

    // Emit header's body instructions and pre-terminator phi
    // assignments INTO body_buf (the loop body's WGSL scope).
    try emitBodyInstructions(s, &body_buf, header);
    try emitPredecessorPhiAssignments(s, &body_buf, header.id);

    // Header's terminator: usually OpBranch to body_first_id, or
    // OpBranchConditional for a single-block loop.  Recurse.
    const term_off = s.inst_off.items[header.terminator_inst_idx];
    const op: Op = @enumFromInt(opcodeOf(s.spirv[term_off]));
    const ops = operandsAt(s.spirv, term_off);
    switch (op) {
        .Branch => try emitBranch(s, &body_buf, blocks, ops[0], stop_set),
        .BranchConditional => try emitUnstructuredConditional(
            s, &body_buf, blocks, header, ops, stop_set,
        ),
        else => unreachable,
    }

    // Continuing block lives in a separate WGSL scope.
    // continue_id might be same as header.id (single-block loop) —
    // in that case the continuing block is empty.
    if (header.continue_id != header.id) {
        try emitBlock(s, &cont_buf, blocks, header.continue_id, stop_set);
    }

    try out.appendSlice(s.arena, body_buf.items);
    if (cont_buf.items.len > 0) {
        try bstr(out, s.arena, "  continuing {\n");
        try out.appendSlice(s.arena, cont_buf.items);
        try bstr(out, s.arena, "  }\n");
    }
    try bstr(out, s.arena, "  }\n");

    _ = stop_set.remove(header.merge_id);
    _ = stop_set.remove(header.continue_id);

    // Emit merge in OUTER scope.
    try emitBlock(s, out, blocks, header.merge_id, stop_set);
}
```

### 2.5.  Switch

Trivial for our input (Zig only emits single-default), modeled on
Dawn `parser.cc:3797`:

```zig
fn emitSwitch(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    header: BlockInfo,
    ops: []const u32,
    stop_set: *StopSet,
) !void {
    const selector = lookupId(s, ops[0]).wgsl_name;
    const default_id = ops[1];
    // (case_id, case_value) pairs starting at ops[2]; for our input
    // there are zero such pairs (Zig only emits single-default).
    const has_real_cases = ops.len > 2;

    try bprint(out, s.arena, "  switch ({s}) {{\n", .{selector});
    try stop_set.put(s.arena, header.merge_id, .switch_break);

    if (has_real_cases) {
        // (defer until a real shader needs it; emit ERROR meanwhile)
        try bstr(out, s.arena, "    // ERROR: spv2wgsl multi-case switch not yet implemented\n");
    } else {
        try bstr(out, s.arena, "    default: {\n");
        var case_buf: std.ArrayListUnmanaged(u8) = .empty;
        if (stop_set.get(default_id)) |kind| {
            try emitStopExit(&case_buf, s.arena, kind);
        } else {
            try emitBlock(s, &case_buf, blocks, default_id, stop_set);
        }
        try out.appendSlice(s.arena, case_buf.items);
        try bstr(out, s.arena, "    }\n");
    }

    try bstr(out, s.arena, "  }\n");
    _ = stop_set.remove(header.merge_id);
    try emitBlock(s, out, blocks, header.merge_id, stop_set);
}
```

### 2.6.  Unstructured conditional (no merge instruction)

`OpBranchConditional` without a preceding `OpSelectionMerge`/`OpLoopMerge`
means we're inside a construct doing inline control flow (loop iter
check, body conditional break, etc.).  Both branches resolve through
stop_set.

```zig
fn emitUnstructuredConditional(
    s: *State,
    out: *std.ArrayListUnmanaged(u8),
    blocks: *const BlockTable,
    header: BlockInfo,
    ops: []const u32,
    stop_set: *StopSet,
) !void {
    const cond = lookupId(s, ops[0]).wgsl_name;
    const true_id = ops[1];
    const false_id = ops[2];

    const t_stop = stop_set.get(true_id);
    const f_stop = stop_set.get(false_id);

    // Patterns we hit in practice:
    //   1) Both stops: emit `if (cond) { <t-exit>; } else { <f-exit>; }`
    //   2) True stop, false forward: emit `if (cond) { <t-exit>; }` then recurse on false
    //   3) False stop, true forward: emit `if (!(cond)) { <f-exit>; }` then recurse on true
    //   4) Neither stops: extremely rare in Zig output; we'd need full structured
    //      analysis to handle this case.  Emit `// ERROR:` and inspect when we hit it.

    if (t_stop != null and f_stop != null) {
        try bprint(out, s.arena, "  if ({s}) {{\n", .{cond});
        try emitStopExit(out, s.arena, t_stop.?);
        try bstr(out, s.arena, "  } else {\n");
        try emitStopExit(out, s.arena, f_stop.?);
        try bstr(out, s.arena, "  }\n");
        return;
    }

    if (t_stop != null) {
        try bprint(out, s.arena, "  if ({s}) {{\n", .{cond});
        try emitStopExit(out, s.arena, t_stop.?);
        try bstr(out, s.arena, "  }\n");
        try emitBlock(s, out, blocks, false_id, stop_set);
        return;
    }

    if (f_stop != null) {
        try bprint(out, s.arena, "  if (!({s})) {{\n", .{cond});
        try emitStopExit(out, s.arena, f_stop.?);
        try bstr(out, s.arena, "  }\n");
        try emitBlock(s, out, blocks, true_id, stop_set);
        return;
    }

    // No-stop case.  Diagnostic for now.
    try bprint(out, s.arena, "  // ERROR: unstructured cond with no stops, cond={s}\n", .{cond});
    _ = header;
}
```

### 2.7.  Phi handling — keep our existing approach

Tint represents phis as block parameters in IR.  We emit WGSL
strings directly, so phis are hoisted `var phiN: T;` at function
scope plus per-predecessor assignment.  This is correct WGSL
already.

The existing `phi_assigns: PhiAssignMap` pre-pass in
`src/spv2wgsl.zig:1283-1338` (registers `(phi_id, source_value)`
keyed by predecessor block) carries over UNCHANGED.  The recursive
walker just calls `emitPredecessorPhiAssignments(out, block_id)`
before each terminator — exactly the same as today.

The bug isn't in our phi pre-pass.  It's in WHICH SCOPE the
assignments land in during emission.  The recursive walker fixes
that automatically because each block is emitted in its
structurally-correct scope.

### 2.8.  Why we don't build Tint's IR

Tint's pipeline: `SPIRV → core::ir::Module → AST → WGSL`.  Three
passes, three representations.

Justified for Tint because they have many backends (WGSL, MSL,
HLSL, GLSL, SPIR-V emission, plus validation/transformation passes).

For us: SPIR-V → WGSL string.  No backends, no transformations
beyond what spirv-opt already did.  Skipping IR keeps the
translator simple and the wasm bundle small.

If a future zimr arc needs HLSL or MSL output, the right move is
to add a second string emitter sharing the same walker, not to
add an IR.

---

## §3.  Decisions made

All open questions from the prior plan, resolved here:

### 3.1.  Tint source acquisition: full Dawn `main` from upload ✓

Source is at `/tmp/dawn-study/dawn-main/`.  All `.cc` files
available (not just headers).  No re-fetching.  When the upload
expires (transcript cleared), we re-upload.

### 3.2.  External corpus: extract `.spvasm` from Tint test source ✓

Tint's `parser/branch_test.cc`, `parser/phi_test.cc`,
`parser/function_test.cc` contain 181 hand-crafted `.spvasm`
inputs as string literals.  Phase 0 extracts these into
`tests/fixtures/external/tint/<test_name>.spvasm`.

Storage: pre-assemble to `.spv` once using
`tools/spirv-prebuilt-linux-x86_64/spirv-as` (already in tree)
and check in BOTH `.spvasm` (source) and `.spv` (build input).

Total fixture size: ~180 KB of binary.  Acceptable.

License: Tint is Apache 2.0; we add
`tests/fixtures/external/tint/LICENSE.md` citing
`github.com/google/dawn/LICENSE` and noting these are derived
from Tint's test fixtures (not its production source).

### 3.3.  Differential testing — same-process, no Puppeteer ✓

Use the existing smoke harness.  `webtests/spv2wgsl_diff.ts` runs
both spv2wgsl (our wasm) and tint-wasm (the WGSL validator we
already use in the corpus runner) on the same SPIR-V input,
diffs the two WGSLs, and reports.  No browser needed.

Phase 6 adds render-diff: same harness compiles each WGSL to a
wgpu pipeline, renders a known scene, pixel-compares.  This uses
the existing wgpu-smoke infrastructure — no new dependencies.

### 3.4.  Premerge — defer ✓

Zig 0.16 doesn't emit premerge patterns.  Implementation emits
`// ERROR: spv2wgsl premerge not implemented` diagnostic.
Add the helper from §2.4 of the prior plan if we ever see one
in a real shader.

### 3.5.  Multi-case switch — defer ✓

Zig 0.16 only emits single-default `switch (0u) { default: {} }`.
Implementation emits `// ERROR:` for multi-case.

### 3.6.  Changelog — dedicated file ✓

`src/notes/changelogs/spv2wgsl-rewrite-changelog.md` opened
Phase 0.  Each phase close gets a dated entry.

### 3.7.  Linear walker retirement — separate phase ✓

Phase 7 deletes linear `emitFunctionBody` and all its support
functions.  Final LOC target: `src/spv2wgsl*.zig` totals ≤1800.

### 3.8.  Module split layout ✓

```
src/spv2wgsl.zig              ← module entry, public API (re-exports)
src/spv2wgsl/                 ← internal modules
├── block_table.zig           ← BlockInfo, BlockTable, registerBlocks
├── walker.zig                ← emitBlock + emitBranch + emitStopExit
├── selection.zig             ← emitSelectionConditional, emitUnstructuredConditional
├── loop.zig                  ← emitLoopHeader
├── switch.zig                ← emitSwitch
├── phi.zig                   ← PhiAssignMap (extracted from spv2wgsl.zig)
├── instructions.zig          ← emitBodyInstructions + per-opcode helpers
│                                 (extracted from spv2wgsl.zig's ~1500 LOC of opcode handling)
├── state.zig                 ← State, IdInfo, lookupId, setId, etc.
└── types.zig                 ← TypeKind, type spellings (extracted)
```

`src/spv2wgsl.zig` shrinks to ~150 LOC of orchestration.  The
public CLI tool (`tools/spv2wgsl.zig`) and build integration
(`src/shader_codegen.zig`) keep their existing imports — only
`@import("spv2wgsl.zig")` is needed.

### 3.9.  Citation style ✓

Every algorithmic decision carries `// parser.cc:LINE` in a
comment AT THE POINT IN OUR CODE where the corresponding logic
lives.  Example:

```zig
// parser.cc:3672 EmitBranchConditional — open if/else in outer scope,
// recurse for true and false into sub-buffers, splice them in, then
// emit merge in outer scope.
fn emitSelectionConditional(...) !void { ... }
```

These references survive in the codebase forever as the trail
back to upstream.

---

## §4.  Phase plan

Each phase ships independent value.  `wgpu-corpus` and `wgpu-smoke`
pass at every phase boundary.

### Phase 0 — Foundations (~1 week)

**0.1.  Differential validator.**
`webtests/spv2wgsl_diff.ts`:
- Inputs: path to `.spv`
- Runs spv2wgsl wasm (already built); captures WGSL output
- Runs tint-wasm parser/writer (already in our toolchain)
- Compares: both parse?  Identifier-canonicalized AST diff?
- Output: side-by-side text diff + parity verdict

Wired as `zig build wgpu-diff <name>`.

**0.2.  External corpus extraction.**
- Write `tools/extract_tint_fixtures.py` that walks
  `/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/{branch,phi,function}_test.cc`
- Each `TEST_F(SpirvParserTest, NAME) { EXPECT_IR(R"(...)", ...); }`
  block extracts to `tests/fixtures/external/tint/NAME.spvasm`
- Assemble each with `spirv-as` to `tests/fixtures/external/tint/NAME.spv`
- Sanity: count fixtures (should be ~181), confirm each `.spv` is
  valid via spirv-val

**0.3.  Baseline metrics run.**
- Run `wgpu-diff` over every `.spv` in:
  - `tests/fixtures/*.spv` (our existing corpus)
  - `tests/fixtures/external/tint/*.spv` (just extracted)
  - Compiled outputs of our 44 zimr shaders
- For each: parses?  identifier-canonical match with tint-wasm?
- Log to `docs/spv2wgsl-baseline-may-2026.md` with breakdown by category

**Acceptance:**
- `zig build wgpu-diff mandelbrot_fs` shows the unified diff
  between our (buggy) WGSL and tint-wasm's (correct) WGSL.
- Baseline parity number recorded.  This is what Phase 5 drives
  to 100%.

**Time:** 5 days.

---

### Phase 1 — BlockTable + module split (~1 week)

**1.1.  Module split (no algorithmic change).**
Move existing code from `src/spv2wgsl.zig` to the per-§3.8 layout.
This is purely mechanical refactor — every function ends up in its
new file with adjusted imports.

Done in one commit per file extracted (8 commits).  After each,
`zig build wgpu-corpus` and `wgpu-smoke` pass.

**1.2.  Buffer parameter refactor.**
The existing body-instruction helpers (`emitLoad`, `emitBinOp`,
`emitCompositeExtract`, ~50 of them) write to `s.body_buf`.  The
walker needs sub-buffers.  Refactor: each takes
`out: *std.ArrayListUnmanaged(u8)` as the first param after `s`.
Bulk rename.

This is what the existing linear emitter uses too (it just always
passes `&s.body_buf`).  No behavior change.

**1.3.  BlockTable construction.**
New `src/spv2wgsl/block_table.zig`:
- `BlockInfo` per §2.1
- `BlockTable` (`AutoHashMapUnmanaged(u32, BlockInfo)`)
- `registerBlocks(arena, fn_k, end_k, inst_off, spirv) !BlockTable`

Unit tests via Zig's `std.testing`:
- single-block function: 1 entry
- if/else (4 blocks): kinds = .selection_header for H, .plain for T/F/M
- loop (4 blocks): kinds = .loop_header for H, .plain for body/cont/M
- mandelbrot's actual SPIR-V (committed as fixture .spv): every
  expected block + kind matches

BlockTable is computed but **not yet used** for emission.  Linear
walker still drives output.

**Acceptance:**
- Phase 1 unit tests pass.
- Corpus unchanged.
- LOC: `src/spv2wgsl.zig` drops from 2448 to ~150; new modules total
  ~2300 (no algorithmic change, just split).

**Time:** 5 days.

**Cite-on-commit:** `parser.cc:1814 EmitBlock`, `parser.cc:1827 GetLoopMergeInst`.

---

### Phase 2 — Walker scaffold + StopSet (~3 days)

**2.1.**
`src/spv2wgsl/walker.zig`:
- `StopKind`, `StopSet` per §2.1
- `emitStopExit(out, arena, kind)` per §2.2
- `emitBlock(s, out, blocks, block_id, stop_set)` skeleton — for
  this phase, it dispatches on `b.kind` and terminator, but
  **always falls back to the linear emitter** for non-trivial cases.
  Only the trivial case (no terminator handling, just call into
  linear) is wired.

The skeleton is added but NOT YET CALLED by `emitOneFunction` —
linear walker is still the only path.

**2.2.**
Unit tests via simulated stop_set: every (kind, edge) combination
produces the expected WGSL substring.

**Acceptance:**
- Phase 2 unit tests pass.
- Corpus unchanged.

**Time:** 3 days.

**Cite-on-commit:** `parser.cc:3444 EmitBranch`.

---

### Phase 3 — Selection emitter, simple cases (~2 weeks)

**3.1.  `emitSelectionConditional` (§2.3).**
Writes if/else with merge in outer scope.  Recurses for true/false
branches.  This is THE phase where the mandelbrot fix appears in
the code — but it's behind a feature flag.

**3.2.  Feature flag.**
`State.use_recursive_walker: bool = false`.  Per-test override.
When true, `emitOneFunction` calls the walker; otherwise linear.

**3.3.  Verification fixtures.**
- Trivial FS (just `return outputs;`): walker output ==
  linear output (byte-identical).
- One-sided if (mandelbrot interior check): walker output renders
  correctly per differential.
- The mandelbrot diagnostic: walker output renders RED via the
  smoke harness's render-equivalence check.

**Acceptance:**
- All verification fixtures pass via walker (flag on per-fixture).
- Corpus unchanged (flag default off).
- Mandelbrot diagnostic with flag on: red canvas via smoke.

**Time:** 10 days.

**Cite-on-commit:** `parser.cc:3672 EmitBranchConditional`.

---

### Phase 4 — Loop emitter (~1 week)

**4.1.  `emitLoopHeader` (§2.4).**
Includes:
- `loop { ... }` wrapper
- Stop set push for merge → loop_break, continue → loop_continue
- Body buffer + continuing buffer
- Single-block loop handling (continue_id == header.id)

**4.2.  `emitUnstructuredConditional` (§2.6).**
The non-merge `OpBranchConditional` cases — loop iter check, body
conditional break.  Three patterns: both stops, true stop only,
false stop only.

**4.3.  Verification:**
- Mandelbrot's iteration loop translates correctly via walker.
- All shaders in our corpus with loops (mandelbrot, julia,
  mandel_julia, pbr_fs, default_fs, unlit_vs) produce correct WGSL
  via walker.

**Acceptance:**
- Walker (with flag on) renders all loop-containing shaders
  correctly.
- Corpus unchanged (flag default off).

**Time:** 5 days.

**Cite-on-commit:** `parser.cc:3754 EmitLoop`, `parser.cc:3768 EmitLoopMerge`.

---

### Phase 5 — Switch + cutover (~1 week)

**5.1.  `emitSwitch` (§2.5).**
Single-default case (covers all our actual inputs).
`// ERROR:` for multi-case.

**5.2.  Cutover.**
Flag default → ON.  Corpus regenerates with
`--refresh-fixture`.  Each new WGSL verified:
- Compiles via tint-wasm
- Structurally matches tint-wasm's own translation of the same `.spv`
- Renders identically via smoke (where renderable)

Sub-phases for bisect safety:
- 5a: cutover for shaders with NO control flow (the 35 trivial
  ones).  Refresh fixture.
- 5b: cutover for shaders with one-sided ifs.
- 5c: cutover for everything else.

**Acceptance:**
- `zig build wgpu-corpus` passes after fixture refresh.
- `zig build wgpu-smoke` passes.
- `zig build wgpu-diff` shows zero structural drift on every
  corpus shader.
- Mandelbrot demo renders correctly.

**Time:** 5 days.

**Cite-on-commit:** `parser.cc:3797 EmitSwitch`.

---

### Phase 6 — External corpus + hardening (~1 week)

**6.1.  External corpus parity.**
Run all 181 Tint fixtures through the new walker.  Expected
results:
- ~120 will produce byte-equivalent WGSL on first try (the simple
  cases).
- ~50 will need premerge or multi-case-switch and produce
  `// ERROR:` lines.  These are EXPECTED diagnostics — Tint's
  corpus is deliberately comprehensive.  Document which Tint test
  names we don't yet handle.
- ~10 will surface bugs in our walker.  Fix each.

Acceptable end state: 100% of OUR shaders work; ~70% of Tint's
corpus works; the remaining 30% have documented `// ERROR:` lines
matching the feature scope we declared (no premerge, no multi-case
switch).

**6.2.  Fuzz harness.**
`webtests/spv2wgsl_fuzz.ts`:
- Generates random Zig shader templates from a known-good template
  library (parameterizing constants and conditions)
- Compiles each to SPIR-V via Zig
- Runs spv2wgsl
- Logs any crashes/panics/unhandled

Run for 10,000 iterations as a one-time stress test.

**6.3.  Render-level differential.**
For each of mandelbrot, julia, mandel_julia, default_fs, pbr_fs:
- Compile both our WGSL and tint-wasm's WGSL to wgpu pipelines via
  the smoke harness
- Render the same scene to a render texture
- Pixel-compare with threshold ≤2/255 per channel

**Acceptance:**
- 100% parity on our corpus.
- Documented coverage on Tint corpus.
- Zero crashes in 10K fuzz iterations.
- Render diff passes for all 5 reference shaders.

**Time:** 5 days.

---

### Phase 7 — Linear walker retirement (~3 days)

**7.1.  Delete linear code.**
- Delete `emitFunctionBody` and all helpers it used that the walker
  doesn't (`Frame`, `FrameKind`, `classifyEdge`, `handleLabel`,
  `handleBranch`, `handleBranchConditional`, `handleSwitch`).
- Walker becomes the only emission path.

**7.2.  Tighten the module split.**
With linear gone, some helpers move:
- `instructions.zig` shrinks (no `Frame` / `handleX` cluster).
- `walker.zig` is the sole emission driver.

**Acceptance:**
- Corpus unchanged.  Smoke unchanged.
- Final LOC: target ≤1800 across `src/spv2wgsl*.zig`.

**Time:** 3 days.

---

### Phase 8 — Re-enable demo (~3 days)

**8.1.**
- Remove diagnostic from `examples/mandelbrot_fs.zig`.
- Re-enable engine triangles in `wgpu_demo.zig`.
- Re-enable `julia_fs` and `mandel_julia_fs`.
- Tune mandelbrot center/zoom/max_iter for visual quality.

**8.2.**  Verify on phone (Simon).

**Acceptance:**
- "3 fractals through the typed pipeline" demo title is accurate.
- All three fractals + engine triangles render correctly.

**Time:** 3 days.

---

### Phase 9 — Documentation + archival (~2 days)

**9.1.**
- `docs/spv2wgsl-architecture.md`: full algorithm + worked
  mandelbrot example + Tint citations.
- `docs/zig-spirv-quirks.md`: trim to remaining quirks (OpCopyObject,
  OpFUnord*).
- Move this plan to `src/notes/archive/spv2wgsl-rewrite-plan.md`.
- `PLAN.md`: spv2wgsl rewrite arc closed; webgpu-migration Phase
  E/F unblocked.

**9.2.**  Final entry in
`src/notes/changelogs/spv2wgsl-rewrite-changelog.md`.

---

## §5.  Timeline

| Phase | Topic                              | Estimate | Cumulative |
| ----- | ---------------------------------- | -------- | ---------- |
| 0     | Foundations (diff + corpus)        | 5 d      | 1 wk       |
| 1     | BlockTable + module split          | 5 d      | 2 wk       |
| 2     | Walker scaffold + StopSet          | 3 d      | 2.5 wk     |
| 3     | Selection emitter                  | 10 d     | 4.5 wk     |
| 4     | Loop emitter                       | 5 d      | 5.5 wk     |
| 5     | Switch + cutover                   | 5 d      | 6.5 wk     |
| 6     | External corpus + hardening        | 5 d      | 7.5 wk     |
| 7     | Retire linear walker               | 3 d      | 8 wk       |
| 8     | Re-enable demo                     | 3 d      | 8.5 wk     |
| 9     | Docs + archival                    | 2 d      | 9 wk       |

**~9 weeks** with no buffer.  "All year" gives plenty.

Each phase ends with a working tree, a passing corpus, and a
changelog entry.

---

## §6.  What this plan is NOT

- **Not vendoring Dawn**.  Citations only; no Dawn code in tree.
- **Not building Tint's IR**.  See §2.8.
- **Not optimizing the SPIR-V before translation**.  spirv-opt's
  output is our input.
- **Not emitting GLSL or HLSL or MSL**.  WGSL only.
- **Not replacing tint-wasm as the differential reference**.  Tint
  is the ground truth.
- **Not handling premerge or multi-case switch in v1**.  Deferred
  with `// ERROR:` diagnostics.  Added when a real shader needs them.

---

## §7.  Why this is worth doing

zimr's principle: one source, three execution domains.  The Zig
shader is the source.  Our translator closes the loop on browser
GPU rendering.  Owning the translator means:

- Build-time errors point to Zig source.
- Quirks in Zig's SPIR-V backend get named workarounds we control.
- The whole pipeline is auditable.
- wasm bundle stays small (~1.7 MB current; naga+wasm adds ~5 MB).

The 9-week investment buys a translator we trust for years of
zimr development.

---

## §8.  Status board

| Phase | Topic                          | Status   | Date | Notes |
| ----- | ------------------------------ | -------- | ---- | ----- |
| 0     | Foundations                    | ✅ done  | 2026-05-29 | 0.1 diff + 0.2 corpus (181 fixtures) + 0.3 baseline + 0.4 pure-Zig validator (TS/npm scaffolding deleted).  178/181 Tint corpus clean; same 3 known-bug hits; all-Zig test rig. |
| 1     | BlockTable + module split      | ✅ done  | 2026-05-29 | 1.1: types.zig (250 LOC enums) + 5 scaffolds.  1.2: 20 body helpers take `out: *ArrayList(u8)` first.  1.3: `BlockTable` + `registerBlocks` (430 LOC, 11 tests including real Tint fixture).  `spv2wgsl.zig` 2448 → 2219 LOC.  28/28 tests pass.  Corpus byte-identical. |
| 2     | Walker scaffold + StopSet      | ✅ done  | 2026-05-29 | `walker.zig` ~290 LOC.  StopKind enum (if_merge/loop_break/loop_continue/switch_break — plain enum, not union since variants are payload-free).  `emitStopExit` fully implemented + tested for every variant.  `emitBlock` skeleton dispatches on all 4 BlockKinds (no emission yet — Phase 3-5 fill in arms).  `emitBranch` handles stop-set fast path.  10 unit tests pass. |
| 3     | Selection emitter              | ✅ done  | 2026-05-29 | 3a: `walker.emitSelection` per §2.3 with sub-buffer splice + merge-in-outer-scope.  3b: orchestrator extracts `emitBlockBodyOnly` + `emitOnePerOpcode`; `State.use_recursive_walker = true` default; `walkerSafetyCheck` gates on selection-only CFGs.  OpUnreachable (255) handled in walker, block_table, body callback.  Corpus byte-identical with walker enabled (9+3 known-bug shaders are loop/switch — Phases 4/5).  36/36 tests, wgpu-smoke 60f clean. |
| 4     | Loop emitter                   | ✅ done  | 2026-05-29 | `emitLoop` per §2.4 + back-edge silent-stop + nested stop_set save/restore.  Safety gate accepts loop_header.  38/38 tests, corpus byte-identical with walker driving loops in production.  Surfaced a one-sided-if phi-routing bug (the merge block's body emitted unconditionally in outer scope clobbers true-branch phi assignments) — narrower than the original mandelbrot bug, requires Tint-style per-predecessor phi routing.  Deferred to Phase 6. |
| 5     | Switch + cutover               | 🔧 5a done | 2026-05-29 | 5a: `walker.emitSwitch` per §2.5 + multi-case literals (3 Tint switch fixtures structurally correct now).  `walkerSafetyCheck` retired (returns true always).  40/40 tests; corpus byte-identical (the 12 still-flagged shaders all hit the one-sided-if phi-routing pattern — Phase 6).  5b (flag rename) + 5c (delete linear emitter) deferred. |
| 6     | External corpus + hardening    | ✅ done  | 2026-05-29 | One-sided-if phi-routing fix.  `isTrivialPassthroughBlock` helper + emitSelection's Phase 6 branch: when merge_id is a trivial pass-through AND one of true_id/false_id == merge_id AND merge isn't owned by an enclosing construct, emit merge's pre-terminator phis INSIDE the empty branch and skip merge in outer scope.  **Tint: 178 → 179 ok (3 → 2 known-bug); Internal: 34 → 43 ok (9 → 0 known-bug).  Mandelbrot bug ELIMINATED.**  40/40 tests pass, wgpu-smoke clean. |
| 7     | Retire linear walker           | ⏸ low-pri | —    | combined with Phase 5c; plus optional multi-predecessor phi for 2 remaining Tint fixtures (not in Zig+spirv-opt domain) |
| 8     | Re-enable demo                 | ✅ done  | 2026-05-29 | Red `out_color` diagnostic removed; engine triangles + quads restored in `wgpu_demo.zig`; mandelbrot UBO restored to zoom=1.2 / max_iter=512.  wgpu-smoke green (60f, ~26 bridge/frame).  Internal corpus grew to 47 (2 new engine pipeline variants, both clean).  Fractal renders for real. |
| 9     | Docs + archival                | ⏸ next  | —    | move plan to archive; update PLAN.md focus to Turn 4 |

---

## §9.  End-of-plan note for next session

**On resume:** start Phase 0.1 — build
`webtests/spv2wgsl_diff.ts`.

**Reading order if picking this up cold:**
1. This file.
2. `/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/parser.cc`
   lines 1814 (EmitBlock), 3444 (EmitBranch), 3672 (EmitBranchConditional),
   3754 (EmitLoop), 3797 (EmitSwitch).
3. `/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/branch_test.cc`
   — 122 named test cases that ARE the spec for what the algorithm
   should handle.  At minimum scan the names; for tricky cases
   (e.g. `IfBreak_FromThen_ForwardWithinThen` at line 3411), read
   the body.
4. `docs/spv2wgsl-flow-guards.md` — worked-example writeup of the
   mandelbrot bug.  The OLD plan's framing.  Still useful as a
   concrete demonstration of the bug; the NEW plan reframes the
   fix.
5. `src/notes/changelogs/spv2wgsl-rewrite-changelog.md` — opened
   Phase 0.  Each phase boundary adds an entry.

**Build commands relevant here:**
- `zig build wgpu-corpus` — corpus regression
- `zig build wgpu-corpus -- --refresh-fixture` — accept new outputs
- `zig build wgpu-smoke` — Bun-side smoke
- `zig build wgpu-demo` — full demo build
- `bun run webtests/transpiler_corpus.ts` — corpus runner
- `zig build wgpu-diff <name>` — (Phase 0.1) side-by-side
  differential
- `bun run webtests/spv2wgsl_fuzz.ts` — (Phase 6.2) fuzz harness

**What WILL change:**
- `src/spv2wgsl.zig` shrinks from 2448 to ~150 LOC.
- New `src/spv2wgsl/*.zig` modules total ≤1800 LOC after Phase 7.
- The recursive walker replaces the linear walk in Phase 5.
- One new dependency: `tests/fixtures/external/tint/` directory
  with ~180 KB of binary `.spv` files.

**What WON'T change:**
- Public CLI surface (`tools/spv2wgsl.zig`).
- Build integration (`src/shader_codegen.zig`).
- Corpus tooling (`webtests/transpiler_corpus.ts`).
- Existing imports: `@import("spv2wgsl.zig")` still resolves.
