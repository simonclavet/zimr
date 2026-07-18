# spv2wgsl drops OpPhi assignments — the root cause of the dead fluids

**Status: FOUND, NOT FIXED. This is the next job.**

`spv2wgsl` emits phi variables that are DECLARED, READ, and NEVER ASSIGNED. WGSL
zero-initialises them, so every control-flow decision that depends on one is made on a
zero — and loops exit on their first iteration.

## The evidence

Count, per kernel, the `var phiN: u32;` declarations against the `phiN = ...`
assignments in the emitted WGSL:

    applyAndFinalize   13 phi vars,  5 NEVER ASSIGNED
    buildGrid           6 phi vars,  2 NEVER ASSIGNED
    density            29 phi vars,  6 NEVER ASSIGNED
    densityTiled      150 phi vars, 69 NEVER ASSIGNED
    force              35 phi vars,  9 NEVER ASSIGNED
    forcePig           18 phi vars,  3 NEVER ASSIGNED
    viscosity          32 phi vars,  7 NEVER ASSIGNED
    gravityMouse        7 phi vars,  2 NEVER ASSIGNED
    prefixSum           6 phi vars,  2 NEVER ASSIGNED
    ---- clean ----
    clearGrid           1 phi vars,  0
    predict             1 phi vars,  0
    fallBounceLean      5 phi vars,  0

The clean ones are exactly the kernels with NO RUNTIME LOOP. `compute_smoke`'s `double_it`
has none either, which is why it stayed green and hid this for so long.

The shape, from `prefixSum`:

    var phi26853: u32;                    // declared...
    ...
    let _26845: bool = 72u == 72u;        // condition computed, then DISCARDED
          phi26855 = phi26853;            // ...read here, never written anywhere
        } else {
          phi26855 = 45u;
        }
    let _26859: bool = phi26855 == 41u;   // -> false -> `break` on iteration 1

The `if (_26845) { phi26853 = 41u } else { phi26853 = 72u }` that should feed it is simply
absent from the output. Compare an earlier build of the same kernel, which DID emit it —
so the assignment is being dropped somewhere in the structurizer, not never generated.

## What it costs

Everything that looked like several unrelated bugs is this one bug:

  * `fluid_sort`: `prefixSum`'s scan breaks immediately -> `cell_start` all zeroes ->
    `scatter` piles every particle into slot 0 -> `copyback` writes those zeros back into
    `pos` -> the wall clamp parks all 50k particles in one corner.
  * `fluid_gpu`: `density`'s neighbour loops break immediately -> no particle ever finds a
    neighbour -> `rho` is exactly 0.0 -> no pressure force -> the particles behave like
    sand: they fall, stack, and never repel.

## Not the cause

Ruled out on device, each with a measurement:

  * The uniform buffer. It is CORRECT — reading `g.P.n_cols` straight from the binding
    gives 92. (A SEPARATE bug did corrupt it: kompute's whole-struct uniform->Ctx copy
    dropped a field. That is FIXED — see `installKernel`. It is what unstuck `fluid_gpu`
    from `frozen 100%`.)
  * Bounds checks. `@setRuntimeSafety(false)` on the kernel changes nothing: still 2
    unassigned phis.
  * The loop form. `while (i < n) : (i += 1)` and a manual `i += 1` in the body both
    produce the same 2 unassigned phis.
  * Buffer aliasing, binding numbers, uniform std140 layout, host-side param values — all
    verified correct on device.

## Where to look

`src/spv2wgsl.zig`, the phi/exit-arg machinery:

  * `applyDefaultToShortestExit` (~3583) — "Push a default value onto whichever of an
    If/Loop/Switch's materialized exit edges has the FEWEST args so far (i.e. the one that
    did not receive this phi's value via a real predecessor). Mirrors Tint's default-block
    fixup."
  * The `PhiAssignMap` / `phi_assigns_ref` path (~635, ~793).
  * Loop-carried phis: "the header OpPhis: declared before the loop" (~2428).

Suspicion: an exit edge that never gets materialised, so its phi assignment is never
appended — leaving the `var` at its zero-init. The `72u == 72u` and `45u == 45u`
comparisons in the output are structurizer state checks that got constant-folded, which
suggests the state machine has predecessors the emitter is not visiting.

This is likely a REGRESSION: the fluid demos are reported to have worked (20k particles at
60fps), and the recent spv2wgsl arc touched exactly this area ("unstructured
BranchConditional", "OpUndef in OpPhi predecessors").

## The test to write first

`webtests/transpiler_corpus.zig` should gain a check that FAILS on this today: transpile a
kernel with a runtime loop and assert that **every `var phiN` declared in the output is
assigned at least once**. That is a purely syntactic check on the emitted WGSL, it needs no
GPU, and it would have caught this the day it was introduced.
