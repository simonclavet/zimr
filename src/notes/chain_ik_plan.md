# Redundant chain IK — plan

## The problem

A **ten-link planar chain**, base pinned, tip tracking a target the user drags. Links of 0.3 m,
so a 3.0 m reach.

★ **TEN DEGREES OF FREEDOM FOR A TWO-DOF TASK.** The null space is eight-dimensional, which is
where a solver's conditioning stops being a footnote. Instability in an IK solver is **instantly
visible** in a redundant chain in a way it never is in a six-DOF arm — the whole thing whips.

**Zero dynamics, zero contact.** The layer that has never broken in this project, and nothing
else. `ctl.Ik` is exercised as the real subject rather than as scaffolding.

## ★ THE A/B IS A SLIDER, NOT A REWRITE

`ctl.Ik` already exposes `damping` (default 0.05). Damped least squares solves

    Δq = Jᵀ(J·Jᵀ + λ²I)⁻¹ · e

and at `λ = 0` that is the bare pseudo-inverse. **So zero at one end of the slider IS the naive
solver**, and no second code path is needed to make the comparison honest.

Near a singularity — the chain at full stretch, or folded — `J·Jᵀ` becomes ill-conditioned and
the bare inverse asks for enormous joint velocities to buy a tiny tip motion. Damping trades a
little tracking accuracy for a bounded answer, and the trade is exactly what you watch.

## ★★★ ACCEPTANCE TEST, FIXED BEFORE THE CODE

Sweep the target along a path that **crosses the reachable boundary and comes back**, since the
boundary is where the conditioning shows:

    inside the workspace:   tip error < 1 mm
    everywhere, including at full stretch:  peak |Δq| per solve < 0.5 rad

**Bar: damped stays under the joint-velocity ceiling across the whole sweep; undamped exceeds it
near the boundary.** Report peak |Δq| for both, as numbers. Not "it looks smoother".

## Gates, in order

1. ✅ **The chain itself.** DONE. Ten links, 3.0 m reach; the tip reaches a point at 2.9 m and cannot
   reach one at 3.5 m — and `Ik.Result.reached` must say so rather than silently returning a
   best effort. **An unreachable target is a normal outcome, not an error.**
2. ✅ **The sweep.** DONE.
3. ✅ **The demo** — `examples/chain_ik`.

## ★ RISKS, NAMED NOW

**A planar chain in a 3D engine still has 3D joints.** The hinge axis must be consistent or the
chain leaves its plane; that is a `vec(0,1,0)` question and this project has already lost three
turns to one of those. **Verify the tip stays in the plane before believing any tracking number.**

**`max_step` clamps the per-iteration joint change and will mask the very divergence this
example exists to show.** It must be loose enough that the undamped solver can misbehave
visibly, or the comparison proves nothing. **Report the raw requested step, not the clamped one.**

## ✅ ALL THREE GATES DONE

**Gate 1.** 12 bodies, nv 10, reach exactly 3.000 m. A target at 2.9 m is reached in **4
iterations** to 0.00001 m; one at 3.5 m returns `reached = false` after exhausting its budget
rather than silently handing back a best effort. And **the tip's y stayed identically zero** —
the chain is genuinely planar, which the plan said to verify before believing any tracking
number, after `vec(0,0,1)` cost three turns elsewhere.

**Gate 2**, sweeping across the reach boundary and back:

    damping   worst tip err   peak |Δq| in one solve
      0.001        0.000982              100.067
      0.010        0.000891               38.834
      0.050        0.000927               11.567
      0.300        0.000997                0.752

★★★ **THE ACCURACY IS THE SAME AND THE MOTION SPANS 133x.** A hundred radians in one solve is
sixteen full revolutions of a joint to move a tip by a millimetre. Damped least squares costs
nothing inside the workspace and buys a bounded answer at the boundary — the entire argument, in
one table.

## ★ TWO THINGS THE PLAN GOT WRONG, BOTH FOUND BY MEASURING

**Zero damping is not the naive solver — it is no solver.** At `λ = 0` the chain does not move at
all: peak `|Δq|` measured **0.000**. `ctl.Ik` declines a singular solve rather than diverging,
which is the right call and means the textbook "undamped versus damped" A/B does not exist here.
The honest comparison is a damping too small to condition the problem against one that does.

**And the first sweep reported 2.000000 m of error for EVERY setting** — identical, which by now
is a recognised tell. The chain starts stretched straight out and the sweep opens near the base,
so the opening transient dominated a max that was supposed to describe steady tracking. Skipping
the first ten solves made the real differences visible. **A summary statistic taken over the
wrong window hides exactly the thing it was meant to show.**
