# Mandelbrot blocker: state-machine SPIR-V & single-pass spv2wgsl

## What happened this turn

Re-enabled mandelbrot in wgpu_demo.zig.  Real Chrome rejected the
generated WGSL with:

```
Error while parsing WGSL: :71:3 error: loop does not exit
loop {
  ^
- While calling [Device].CreateShaderModule([ShaderModuleDescriptor "mandelbrot"])
```

The error is real: the emitted loop has **no `break` or `continue`
anywhere inside the body**.  WGSL's behavioural analysis correctly
rejects it.

## Why our spv2wgsl can't catch it

Added debug prints to `handleBranch` / `handleBranchConditional`
showing the classified `EdgeKind` and stack state at every branch
inside the mandelbrot fragment shader.  Summary:

```
// DBG loop opens merge=1343 cont=1341
// DBG branch_cond cond=_1236 t=forward(1239) f=forward(1237)  ← iter check
// DBG branch_cond cond=_1253 t=forward(1254) f=forward(1335)  ← nested if
// DBG branch_cond cond=_1281 t=forward(1282) f=forward(1333)  ← nested if
// DBG branch target=1337 kind=forward stack.len=2
// DBG branch target=1233 kind=forward stack.len=1
// ... (many more, all 'forward') ...
```

**Not a single branch inside the loop body targets the loop's merge
(1343) or continue (1341).**  Zero `break` or `continue` can be
emitted, because no branch matches our `classifyEdge`'s rules.

## Why Zig's SPIR-V looks like this

Zig's SPIR-V backend appears to lower nested control flow with
multiple `break` paths into a **state-machine pattern**:

```zig
// Source
while (i < 1024) : (i +%= 1) {
    if (@as(f32, @floatFromInt(i)) >= io_in.u.max_iter) break;
    if (zm.cnorm2(z) > 256.0) { escaped = 1; break; }
    z = zm.cmandelbrot_step(z, c_complex);
    n += 1.0;
}
```

```spv
; conceptual SPIR-V (not exact)
loop_header (1233):
  i_cond = phi_iter < 1024
  OpSelectionMerge sel_merge
  OpBranchConditional i_cond, body_block, exit_label
                                          ; exit_label is an INTERMEDIATE block,
                                          ; not loop_merge directly

body_block (1237):
  ; body computation, each break sets phi_state to magic value
  phi_state = 195u (when escaped=1, break)
  phi_state = 197u (when i>=max_iter, break)
  OpBranch sel_merge

sel_merge (1337):
  ; after body, check phi_state — but this check doesn't
  ; OpBranchConditional to loop_merge; it sets MORE state
  ; and eventually falls through to cont via OpBranch
  OpBranch cont (1341)

cont (1341):
  phi_iter = phi_iter_next   ; the actual i +%= 1
  OpBranch loop_header
```

The CFG only `OpBranch`es to the loop's `merge` label **from outside
the loop body itself** — most likely from a final dispatch block
after the loop, or via an `OpUnreachable` / fall-through path that
WGSL's behavioural analysis can't prove terminates.

Our single-pass linear emitter sees ALL these branches as `forward`
because their immediate targets are intermediate blocks, not the
loop's `cont` / `merge` directly.

## What this means for fixing it

The only correct fix is Tint's full multi-pass approach
(tint-vs-spv2wgsl.md):

1. `RegisterMerges` — record header ↔ merge ↔ continue links
2. `ComputeBlockOrderAndPositions` — reverse structured post-order
3. `LabelControlFlowConstructs` — every block tagged with its
   nearest enclosing Construct (BlockInfo struct, not just frame
   stack)
4. **`ClassifyCFGEdges`** — every edge labeled
   `kBack`/`kSwitchBreak`/`kLoopBreak`/`kLoopContinue`/`kIfBreak`/
   `kForward`.  Critically, classification is **transitive** — an
   edge to intermediate-block-X that only `OpBranch`es to
   loop_merge is itself a `kLoopBreak` edge.
5. Then at emission, terminators use the classified edges to emit
   the right `break;` / `continue;` / structured branches.

This is multiple days of work to implement correctly, and is the
right move long-term.  Short-term workarounds (try to detect "block
X is a thin wrapper around an OpBranch to loop_merge" inline) are
fragile and easy to get wrong.

## What landed correctly this turn

Even though mandelbrot is back in the disabled state:

1. **OpPhi assign-at-predecessor** is implemented (Tint pattern
   item 5).  Pre-pass collects `(phi_id, value_id)` per predecessor
   block; emission emits the assigns before each block's
   terminator.  Visible in the mandelbrot WGSL as 47 phi-var
   assignments throughout the function.  This is the correct SSA →
   lexical lowering for phi nodes and would be required eventually
   regardless of the CFG fix.

2. **`classifyEdge` walks ALL frames** including the top.  The prior
   "skip top" logic was wrong — for plain OpBranch with no enclosing
   sel, the top frame IS the loop frame, and skipping it meant the
   classifier never returned `loop_break`/`loop_continue`.

3. **Edge classification for OpBranch** — plain unconditional
   branches now emit `break;` / `continue;` when targeting an
   enclosing loop's merge/continue.  This already works for simple
   while-loop patterns; mandelbrot just doesn't generate that
   pattern.

4. **OpCopyObject (83), OpFUnord* compares (181/183/185/187/189/191)**
   — handlers added.  Corpus now has zero `UNHANDLED` markers.

## Next steps when this becomes priority again

Either:

**(a) Full Tint port of the CFG analysis** — implement the 12-pass
pipeline.  Highest correctness, most work.  Estimate: 1-2 weeks.

**(b) Investigate Zig SPIR-V emit flags** — Zig may have a switch
that emits "simple" structured CF instead of state-machine.  If yes,
the simple form would be much easier to translate.  Worth a brief
look first.

**(c) Use Tint as the translator** — `tint-wasm` ships ready-made.
Compile it into the build, feed our SPIR-V to Tint, get WGSL back.
Removes spv2wgsl entirely from the critical path; spv2wgsl becomes a
"backup" / "no-extra-dependencies" path that handles simple shaders.
This is the lowest-effort path to working fractals.
