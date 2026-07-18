# spv2wgsl: the mandelbrot fix

## What was actually wrong

After two turns of suspecting transitive edge classification was the
root cause, the real bug turned out to be much simpler.

Zig's SPIR-V emit produces this pattern at the end of the mandelbrot
loop body (after the body's selection merge ladder converges):

```spv
Label 1207                    ; "loop continuation check" block
%_1210 = OpIEqual %phi_state 147        ; was the body's state set to EXIT?
OpBranchConditional %_1210 %1213 %1211  ; t=loop_merge, f=loop_continue
                                        ; (NO preceding OpSelectionMerge or OpLoopMerge!)

Label 1211                    ; loop continue block
... phi updates ...
OpBranch %1233                ; back to loop header
```

**The critical detail**: `OpBranchConditional` with NO preceding
`OpSelectionMerge` or `OpLoopMerge` instruction.  SPIR-V allows this
pattern when both targets are structurally-classified edges (here:
both are part of the enclosing loop's structure — one is the merge,
one is the continue).

Our `handleBranchConditional` had two branches: `pending_kind == .sel`
and `pending_kind == .loop`.  Neither matched when there was no
pending merge, so **the entire OpBranchConditional was silently dropped**.

Result: the loop body had zero exit edges → WGSL behavioral analysis
rejected with "loop does not exit".

## The fix

Added a third branch to `handleBranchConditional` for the no-pending-merge
case.  Classifies both targets against the open frame stack and emits:

| true → | false → | emit |
|---|---|---|
| `loop_break` | `loop_continue` | `if (cond) { break; }` |
| `loop_continue` | `loop_break` | `if (!cond) { break; }` |
| `loop_break` | `loop_break` | `break;` |
| `loop_break` | `forward` | `if (cond) { break; }` |
| `forward` | `loop_break` | `if (!cond) { break; }` |
| `loop_continue` | `forward` | `if (cond) { continue; }` |
| `forward` | `loop_continue` | `if (!cond) { continue; }` |

For mandelbrot:
- true=1211 → `loop_continue` (target IS the loop's cont label)
- false=1213 → `loop_break` (target IS the loop's merge label)
- Emits: `if (!(_1210)) { break; }`

## How we found it

Three rounds of progressively richer debug instrumentation:

1. **First round** — print branch target + classification at every
   `handleBranch` and `handleBranchConditional`.  Showed all branches
   classified as `forward`.  Misled me into believing we needed full
   Tint-style transitive edge classification.

2. **Second round** — print frame stack contents at every branch.
   Confirmed that loop merge/cont labels were correct in the frame
   but no branch targeted them directly.

3. **Third round** — emit `// DBG_OP <opcode>` for every dispatched
   instruction.  Found `OP 250` (OpBranchConditional) appearing
   between `Label 1207` and `Label 1211` with NO `DBG_BC` line
   alongside it — meaning the conditional branch was reaching our
   dispatch but our handler was producing no output.

The lesson: when an emitted WGSL output looks structurally wrong,
debug the dispatch BEFORE the analysis.  We assumed our handler was
running correctly and producing wrong output; the actual bug was
that the handler had a gap and was producing NO output.

## Forecast: how solid is this fix?

This handles the specific Zig SPIR-V pattern: divergent branches at
the END of a structured construct where both targets are
structurally-classified edges (loop merge / loop continue).  Should
also work for switch break patterns once we have switch frame support.

The "transitive edge classification" architecture from the Tint study
(see tint-vs-spv2wgsl.md) is still the right long-term direction.
But for Zig's specific output shape, this targeted fix is sufficient.

If we encounter pathological shaders where an intermediate block of
real computation sits between the structured construct and the loop's
merge/continue (i.e., the target is NOT directly merge/continue), we
will need the transitive classifier.  Empirically, this doesn't seem
to happen with current Zig SPIR-V emit for the fractal shaders.

## Status

- All three fractal WGSL outputs now have exactly 1 `break;` each
- Smoke goes 36 → 44 bridge calls (mandelbrot pipeline setup)
- No `UNHANDLED` opcode markers in any shader
- Real Chrome test pending (next turn)

## What this means for the larger plan

The "port Tint's ClassifyCFGEdges" item from `tint-vs-spv2wgsl.md`
is now LOWER priority.  If mandelbrot works in Chrome with this fix,
we have a working spv2wgsl for all real Zig-emitted shaders, with no
need for the multi-pass restructure.  The Tint port becomes a "nice
to have" for handling pathological SPIR-V from other producers.
