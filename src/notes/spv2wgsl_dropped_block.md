# spv2wgsl silently DROPS a guarded block

**Status: FOUND AND FIXED.** The cause was a widening of SCCP's selection-fold that I
introduced as part of the phi fix. See "The cause" below.

`spv2wgsl` can emit an `if`'s CONDITION and then not emit the BLOCK it guards. The block's
entire contents — loads, stores, a whole nested loop — vanish. There is no error, no `//
ERROR:` marker, no diagnostic. The kernel compiles, runs, and computes a plausible-looking
wrong answer.

## The reproduction

`examples/sort_smoke/sort_min.zig`, kernel `computeForce`. Run `sort_smoke.html`:

    CPU FORCE:  0/64 wrong (worst |corr| err 0.0000)
    GPU FORCE: 59/64 wrong (worst |corr| err 0.2921)

Same source. kompute compiles it for both targets; only the GPU is wrong.

## What was dropped

    sort_min.computeForce: 86 memory ops in the SPIR-V     <- Zig's output is COMPLETE
    emitted WGSL:           3 buffer accesses              <- the transpiler's is not

    reads inside the emitted computeForce:
      kbuf_pos:    1   (only `my_pos`; the neighbour read `b_pos[kk]` is GONE)
      kbuf_dens:   1   (only `my_d`;   the neighbour read `b_dens[kk]` is GONE)
      kbuf_starts: 0   (`b_starts[cell]` is GONE ENTIRELY)
      kbuf_corr:   1   (the write survives)

The ENTIRE innermost neighbour loop — the cell-range lookup and everything inside it — is
absent. `corr` therefore comes out ~0, which is why the error magnitude equals the size of
the correction itself.

## The tell

    let _4940: bool = phi4936 == 138u;      // COMPUTED...
    let _5545: u32 = phi4936;               // ...and DISCARDED. Never used.
              phi5547 = _5545;

State 138 is "enter the cell's particle loop". The condition to enter it is emitted; the
`if (_4940) { ... }` that consumes it never is. The state machine falls straight through to
`break`.

**A `bool` that is computed and never used is the syntactic signature of this bug.** Note
that dead bools ALSO occur benignly (SCCP folds leave `72u == 72u` behind), so a naive
"no dead bools" rule would fire on healthy kernels — `fluid_gpu`, which works, has 9 in its
`force`. The invariant has to be structural, not textual.

## Not the cause

Each ruled out by re-emitting and re-counting the buffer reads:

  * The co-location fallback (`@cos`/`@sin` of a hashed seed). Removed it; loop still gone.
  * The second `continue` in the innermost loop (`if (d2 >= h*h) continue`). Rewrote it as
    an if-block, matching `computeDensity`'s shape exactly; loop still gone.
  * Zig's SPIR-V backend. The SPIR-V has all 86 memory ops. The loss is downstream.

It IS sensitive to module composition: `computeForce` compiled CORRECTLY (`0/64 wrong`) in
the previous build, with the identical source. The only change was which OTHER buffers the
module declares. That points at something order- or id-dependent in the structurizer, since
SPIR-V result ids shift when the module changes.

## The cause — and it was self-inflicted

`sccp` folds a selection whose condition is a known constant: the `OpBranchConditional`
becomes an unconditional branch and the `OpSelectionMerge` is dropped. `mergeBlockPhiWouldOrphan`
decides when that is unsafe.

It used to refuse the fold only when the merge block was **itself a construct header** AND
carried a phi — on the reasoning, written into the comment, that a non-header merge "folds
fine: its phi is collapsed by edge-pruning."

That reasoning is wrong. Edge-pruning does collapse the phi. What it does not do is keep the
BLOCK the folded branch used to guard. When the merge carries a phi, the arm that is no
longer branched to stops being reachable, and everything it dominated goes with it — here,
the entire innermost neighbour loop.

The one-armed-phi collapse then made the result WELL-FORMED, which is exactly why nothing
caught it: `checkPhiClosure` stayed green, no `// ERROR:` marker was emitted, the shader
compiled and ran. **A visible bug had been traded for an invisible one.**

**The fix:** refuse to fold ANY selection whose merge carries a phi. Drop the "must be a
construct header" condition entirely. The collapse stays — it is still correct, and still
needed for the folds we do perform — but it is not a licence to fold a phi-carrying merge.

Cost: a few folds we no longer do. The pass exists to hoist `textureSample` into uniform
control flow, and those guards sit at phi-free merges, so nothing regresses. 55/55 spv2wgsl
tests pass; every shader in the engine still transpiles with no unassigned phis.

## The lesson

Well-formed output is not the same thing as correct output. The collapse was a real fix for
a real bug, and it made the IR valid — so every check we had went green while the compiler
quietly deleted a loop. When a guard says "this shape is dangerous," widening it because a
new mechanism *seems* to make the danger moot needs the same evidence as any other claim.

## THE GUARD (built — `checkBufferAccessSurvival`)

A structural invariant, checked on every shader:

> Every storage buffer that a function ACCESSES in the (folded) SPIR-V must be accessed in
> the WGSL emitted for that function.

`computeForce` accesses `kbuf_starts` in SPIR-V and never mentions it in the WGSL body.
That check is cheap, needs no GPU, and would have caught this immediately — the same way
`checkPhiClosure` now catches the phi bug it was written for.

## Why this matters beyond the fluid

A silently dropped block is the worst failure mode a compiler has. Every kompute kernel with
nested control flow is exposed to it, and nothing in the pipeline currently notices.


## The second bug, uncovered by the first

Refusing to fold phi-carrying merges means the `OpUnreachable` tail blocks those folds used
to delete now SURVIVE — and `emitUnreachReturn` had a latent bug waiting for them:

    if (self.is_current_entry) {
        try self.emitEntryReturn(out, arena);   // emits `return outputs;`
    }

A COMPUTE entry has no `Outputs` struct. Every kernel in the engine came out with

    return outputs;
           ^^^^^^^  unresolved value 'outputs'

and the browser rejected the module. The distinction already existed —
`currentFunctionIsEntry()` is defined as *entry AND has outputs*, precisely for choosing
between `return outputs;` and `return;` — and this one call site simply didn't use it.

Fixed: a value-returning entry stages its outputs; a void (compute) entry emits `return;`.

Two bugs, and the first was hiding the second. That is what a compiler pass that silently
deletes code buys you.


## The guard, as built

`checkBufferAccessSurvival`, run on every shader in every mode, alongside `checkPhiClosure`:

> Every storage buffer that THIS ENTRY's call graph accesses in the SPIR-V must be accessed
> in the WGSL emitted for it.

A dropped block takes its loads and stores with it, so a buffer the kernel provably touches
simply stops appearing. That is the one signal a silently deleted block cannot hide — the
guarding condition may still be emitted (dead), the phis may all be assigned, the module may
be perfectly well-formed. **But the loads are gone.**

Two details, both learned the hard way by re-introducing the bug to test the guard:

  1. **It runs on the ORIGINAL SPIR-V, not the folded one.** The first version checked the
     FOLDED module — and stayed completely silent on the re-introduced bug. Of course it did:
     the fold is what deletes the block, so the access is missing from both sides and the
     guard compares the crime scene with itself. A guard that cannot see the thing it was
     written for.

  2. **It is scoped to the entry's call graph, not the module.** Kernels in one kompute module
     declare the same buffers but touch different subsets. A module-wide union flags
     `computeDensity` for not using `kbuf_pos2` — which `scatter` uses and it does not.

  3. **Membership, not count.** Emission legitimately merges accesses (CSE, hoisting), so
     demanding the same NUMBER would fire on healthy shaders.

Verified both ways: with the bug re-introduced it names the exact kernel and buffer —

    error: spv2wgsl [computeForce]: `kbuf_starts` is ACCESSED in the SPIR-V but never in the
    emitted WGSL.

— and it caught `computeVisc`, which was silently broken too. With the fix in place, all
eight compute examples and the full launcher build clean, zero false positives.

## The old phi bug: still fixed

Re-verified after all of the above:

  * 0 unassigned phis across the entire launcher (every shader in the engine)
  * `prefixSum` — the serial `while` the phi bug reduced to a single iteration — emits a real
    `loop {}`, 2 `cell_start` writes, 2 `grid_counts` reads, 0 unassigned phis
  * 55/55 spv2wgsl tests
  * on device: `GPU prefixSum: 0/33 starts wrong` in `sort_smoke`

The two guards now cover both halves of the same failure mode: `checkPhiClosure` catches a
value that is never written; `checkBufferAccessSurvival` catches CODE that is never emitted.
