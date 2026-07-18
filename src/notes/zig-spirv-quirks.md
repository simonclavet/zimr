# Zig SPIR-V output quirks — and our spv2wgsl workarounds

This document records the SPIR-V patterns Zig 0.16's self-hosted
SPIR-V backend emits that are non-ideal but valid, and the
workarounds we have in spv2wgsl.zig to translate them correctly.

**Why this exists:** when Zig 0.17+ improves its SPIR-V backend, we
want to be able to identify and remove these workarounds.  Every
workaround here is tagged with `// HACK(zig-0.16-spirv): ...` so
they're greppable.

Last updated against: Zig 0.16, `tools/zig-x86_64-linux-0.16.0/`,
SPIR-V backend at `src/codegen/spirv/CodeGen.zig`.

## Quirk 1: state-machine break paths in loops

### What Zig does

Zig's "structured" SPIR-V control flow mode (used for Vulkan targets)
treats selections (`if` blocks) as merge-ladder constructs, NOT as
early-exit blocks.  When a Zig `break` inside an `if` would exit a
loop, Zig:

1. Sets a phi state variable to a magic block-id value (e.g. `145u`,
   `197u`, depending on which break it was)
2. Branches to the selection's merge block (NOT the loop's merge)
3. The selection merge then chains through more selection merges
4. At the end of the loop body, a final `OpBranchConditional` checks
   `if (phi_state == EXIT_MAGIC)` and branches between
   `loop_merge` and `loop_continue`

See `src/codegen/spirv/CodeGen.zig` line 60-90 in the Zig source —
the comment explicitly says "For a `selection` type block, we cannot
use early exits, and we must generate a 'merge ladder' of OpSelection
instructions".

### Why it's a problem for naive translators

The naive approach to SPIR-V → WGSL would walk each block, look at
its terminator's targets, and classify them against the live
structured-CF frame stack: "is this target the merge of an enclosing
loop?  Emit `break;`.  Continue?  Emit `continue;`."

That doesn't work with Zig's state machine because NO branch inside
the loop body directly targets the loop's `merge` label.  Every
branch goes to an intermediate selection merge first.

Naive output: a `loop { ... }` with no `break` or `continue`
anywhere → WGSL's behavior analysis rejects it ("loop does not
exit").

### Our workaround

**HACK(zig-0.16-spirv):** In `handleBranchConditional`, when
`pending_kind` is null (no preceding `OpSelectionMerge` or
`OpLoopMerge`), classify BOTH targets against the open frame stack
and emit:

| true target | false target | emit |
|---|---|---|
| `loop_break` | `loop_continue` | `if (cond) { break; }` |
| `loop_continue` | `loop_break` | `if (!cond) { break; }` |
| `loop_break` | `loop_break` | `break;` |
| `loop_break` | `forward` | `if (cond) { break; }` |
| `forward` | `loop_break` | `if (!cond) { break; }` |
| `loop_continue` | `forward` | `if (cond) { continue; }` |
| `forward` | `loop_continue` | `if (!cond) { continue; }` |

This catches the loop's final state-check `OpBranchConditional`
which has no preceding merge instruction but whose targets are
structurally classified.

### What "ideal" SPIR-V would look like

Tint/Khronos-reference SPIR-V from glslc or similar typically emits:

```spv
loop_header:
  OpLoopMerge merge_block continue_block
  OpBranchConditional iter_cond body_start merge_block

body_start:
  ...
  ; for early break inside an if:
  if (escaped) {
    OpBranch merge_block   ; direct branch to loop merge
  }
  ...
  OpBranch continue_block

continue_block:
  ...
  OpBranch loop_header
```

This emits direct `OpBranch loop_merge` from inside the if — easy to
translate as `if (cond) { break; }` with no state machine.

### When to remove this workaround

When Zig's SPIR-V backend gains an `early_exit` mode for selections,
or restructures break-out-of-loop to use direct merge branches, this
workaround becomes dead code.

Watch for: changes to `ControlFlow.Structured.Block.selection` in
`src/codegen/spirv/CodeGen.zig` that allow early exits.

The Codeberg `quint/zig-spirv` repo is the active improvement effort
for Zig's SPIR-V backend.

## Quirk 2: OpPhi instructions without explicit assignments

### What Zig does

Zig emits OpPhi instructions with the standard SPIR-V form: at the
top of a block, OpPhi declares a value with `(incoming_value,
predecessor_block)` pairs.  The semantics: when entering this block
from `predecessor_block_i`, the phi has value `incoming_value_i`.

### Why it's a problem

WGSL has no native phi.  We hoist phi variables to function scope
(`var phiN: T;`) and then must emit `phiN = source_value;` at the
END of every predecessor block, before its terminator.

This is the standard "SSA → lexical" lowering.  It's not really a
Zig quirk — every SPIR-V producer does this — but it's a complex
piece of translation that's easy to get wrong.

### Our workaround

Pre-pass that walks all OpPhi instructions and builds a map
`predecessor_block_id → [(phi_id, source_value)]`.  During emission,
before any block's terminator (`OpBranch`, `OpBranchConditional`,
`OpReturn`, etc.), emit all registered phi assignments.

See `phi_assigns: PhiAssignMap` in `emitOneFunction` and the
pre-terminator emission in `emitFunctionBody`.

This is the Tint pattern from item 5 of `tint-vs-spv2wgsl.md`.
**Not a hack — this is the correct general approach.  Will remain
even when Zig 0.17+ improves.**

## Quirk 3: OpCopyObject is used liberally

### What Zig does

Zig's SPIR-V emit uses `OpCopyObject` (opcode 83) frequently for SSA
rebinding — anywhere a value needs a fresh result-id, Zig wraps it
in an OpCopyObject rather than reusing the existing id.

### Our workaround

`OpCopyObject` is treated identically to `OpLoad` — emit a `let`
binding that aliases the operand:
```wgsl
let _newid: T = source_value;
```

See `handleOpCopyObject` in spv2wgsl.zig.  **Not a hack — this is
the correct translation.  Will remain even when Zig 0.17+ improves.**

## Quirk 4: OpFUnord* comparison opcodes

### What Zig does

Zig sometimes emits unordered float comparisons (`OpFUnordLessThan`,
etc., opcodes 181, 183, 185, 187, 189, 191) instead of their ordered
counterparts (`OpFOrd*`).

The semantic difference: ordered comparisons return false if either
operand is NaN; unordered return true.  In normal (non-NaN) data,
they're identical.

### Our workaround

Treat `OpFUnord*` as their `OpFOrd*` equivalents (`<`, `==`, etc.).
WGSL has no NaN-vs-ordered distinction in its operators, so this is
correct for all non-NaN inputs.

For NaN-sensitive code this would be wrong, but no shader in our
corpus relies on it.

**HACK(zig-0.16-spirv):** Could potentially be Zig-specific behavior
or could be an LLVM lowering artifact that propagates through.  When
Zig 0.17+ ships with cleaner SPIR-V, check whether `OpFUnord*` still
appears.  If so, this is fine to keep; if not, remove the enum
entries.

## What's NOT a quirk: Zig's SPIR-V is actually good

After studying the output extensively, these are the things Zig gets
RIGHT:

1. **Struct member offsets** are correct.  `OpMemberDecorate Offset`
   produces well-laid-out structs that match the Zig `extern struct`
   `@sizeOf`.

2. **Type emission** is clean.  `vec2<f32>` becomes `OpTypeVector
   %float 2`, `vec4` is `OpTypeVector %float 4`, etc.  No spurious
   wrappers or padding types.

3. **Entry point signatures** are clean.  Input varyings have
   `OpDecorate Location` properly assigned.  Built-in inputs
   (`OpBuiltIn`) work the way they should.

4. **OpAccessChain** for struct field access is exactly what you'd
   expect.

5. **OpExtInst (GLSL.std.450 builtin calls)** are emitted for
   `sqrt`, `log2`, `pow`, etc.  These translate cleanly to WGSL
   builtins.

In short: Zig's structured-CF lowering for loops with nested-break
is the one rough spot.  Everything else is solid.

## Non-spv2wgsl issues we hit on the way

These showed up in the same investigation but are not spv2wgsl
issues — recording them for context:

### Issue A: Pipeline layout mismatch when combining engine VS with custom FS

The mandelbrot demo pairs:
- `default_shapes_vs.wgsl` — engine VS that expects a view-projection
  uniform at `@group(0) @binding(0)`.  Layout: `array<vec4<f32>, 4>`
  = 64 bytes in WGSL uniform address space.
- `mandelbrot_fs.wgsl` — custom FS that expects the mandelbrot Ubo
  at `@group(0) @binding(0)`.  Layout: 32-byte struct.

Both shaders bind to the SAME slot `@group(0) @binding(0)`, but with
different sizes.  Our `loadShader` builds the bind group layout from
the FS schema (`mandelbrot_fs_io.Ubo` → 32 bytes), then real Chrome
rejects the pipeline because the VS reads up to byte 64 of that
buffer.

**Not an spv2wgsl problem.**  The fix is on the pipeline-composition
side: either use a different VS (custom mandelbrot VS with no
uniform), assign the mandelbrot Ubo to a different binding slot
(`@binding(1)`), or build a layout that accommodates both bindings.

### Issue B: Array stride in WGSL uniform address space

WGSL `array<vec4<f32>, 4>` in uniform address space takes 64 bytes
(each element 16 bytes due to uniform-AS stride rule, even though
vec4 is naturally 16 bytes already).  This isn't a quirk — it's the
WGSL spec rule.  Just noting it for understanding the 64-byte size
that confused me initially.

## Summary table — workarounds to remove on Zig 0.17+

| Workaround | File:line | Description | Test |
|---|---|---|---|
| No-pending-merge OpBranchConditional | spv2wgsl.zig handleBranchConditional, else branch | Catches loop state-machine exit | Mandelbrot loadShader works |
| OpFUnord* aliasing to OpFOrd* | spv2wgsl.zig Op enum + dispatch | Compares NaN-permissive | Check Zig 0.17 output |

The other "workarounds" (phi assign-at-predecessor, OpCopyObject,
edge classification) are correct general translation patterns, not
Zig-specific hacks.  They stay.
