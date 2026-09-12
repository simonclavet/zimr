# Anti-sway crane — plan

## Why this one

**Every failure in the humanoid arc was in the layer between the solver and the robot** —
capsule axes, contact-row conventions, teleport notifications, warm starts, servo-and-command
overlap on the same joint. `boxQP`, the Riccati recursion and the LIPM Jacobians held up
whenever they were given clean inputs.

The crane has almost none of that layer. **No contact, no floating base, no kinematic chain, no
whole-body mapping.** Four states, one control, and a payoff that needs no readout to see.

## The physics

A trolley runs on a horizontal rail; a payload hangs below it on a cable of length `L`. Command
the trolley's ACCELERATION — which is what a real crane's drive takes, and what makes the model
honest rather than convenient.

    ẍ = a
    θ̈ = −(g/L)·sin θ − (a/L)·cos θ

Linearised about hanging (`θ ≈ 0`):

    ẍ = a                    θ̈ = −(g/L)·θ − a/L

★ **LINEAR, SO `A` AND `B` ARE CONSTANT** — the same happy structure as the balancing model, and
for the same reason: one backward pass is the exact answer, with no basin to fall into.

★★ AND THE SIGN ON `a/L` IS THE WHOLE PROBLEM. Accelerating the trolley forward swings the
payload BACKWARD. To stop a swinging load you must accelerate INTO it, which looks like the
wrong move and is exactly right. **That is the thing a reactive controller cannot do**, and the
thing the demo shows without a single number on screen.

State `[x, ẋ, θ, θ̇]`, control `[a]`.

## ★★★ THE ACCEPTANCE TEST, FIXED BEFORE ANY CODE

Move the payload 10 m and **arrive still**:

    |x − target|  < 0.05 m
    |θ|           < 0.02 rad   (about 1 degree)
    |θ̇|           < 0.02 rad/s

against a position PD on the trolley — same acceleration limit, same travel time — which reaches
the target and leaves the load swinging.

**The claim to beat: MPC residual swing under a tenth of the PD's.** Not "the cost goes down",
not "it looks smoother": a swing amplitude in radians, measured after arrival, for both.

## Gates, in order, each cheap and each able to fail

1. ✅ **The model against a closed form.** DONE, passes first try. Released from an angle with the trolley held still, the
   payload must oscillate at exactly `√(g/L)` — 1.81 rad/s for a 3 m cable, a **3.47 s period**.
   That number appears nowhere in the code, so it has to be reproduced rather than echoed. Same
   oracle shape as `cosh(ω·t)` for the balancing model.
2. ✅ **Jacobians against centred differences.** DONE., ε = 1e-2, tolerance relative to each entry. Every
   lesson from the trunk model applies unchanged.
3. ✅ **The planner, measured against the PD.** DONE — passes by 1100x.
4. ✅ **The demo** — `examples/crane`, two side by side.

## ★ TWO RISKS, NAMED NOW

**The planner's model is a small-angle approximation and the simulation should NOT be.** Sim the
full `sin θ` / `cos θ` dynamics and plan on the linear one — that is what real MPC does, and it
turns "does the approximation hold?" into something the demo answers rather than assumes. If the
planner commands swings past ~20 degrees the linearisation degrades, and the run will say so.

**The rail speed limit is a STATE constraint and `boxQP` bounds controls only.** Exactly the trap
the momentum excursion fell into: there is no constraint to write, so the cost weight is the
whole brake. **Measure the peak `|ẋ|` and check it against the limit — do not assume the weight
handled it.**

## What makes it worth watching

The trolley **decelerates early and briefly reverses** to catch the load. The payload traces a
path that arrives and stops dead, beside one that keeps swinging. Same horizon, same limit, one
knob different — the `balance_flywheel` format, which is the one that has actually communicated.

## ✅ GATES 1 AND 2 DONE — `craneStep`, `craneLinearize` in `robot_mpc.zig`

Three tests, all passing first try:

  * **the closed form** — released from rest with the trolley held, the payload passes through
    vertical at a quarter period and returns to its start at a full one, for `ω = √(g/L)` =
    1.808 rad/s. Neither that nor the 3.475 s period appears anywhere in `craneStep`. Checked for
    BOTH the linear and the nonlinear step, so the planner's approximation is pinned to the truth
    it approximates.
  * **the sign** — accelerate the trolley in +x and the payload must trail in −θ, and the mirror
    too so it cannot pass with a stuck sign. Checked as a DIRECTION; a norm would pass with it
    inverted, which is the failure that would make the whole demo do the opposite of the point.
  * **the trolley never moves** while the payload swings. If it drifts, the two halves are
    coupled in a way the equations do not say they are.
  * **Jacobians** against centred differences at three states and three controls, ε = 1e-2,
    tolerance relative to each entry.

Next: Gate 3, the planner against a position PD, measured on the acceptance test above.

## ✅✅ GATES 3 AND 4 DONE — THE ACCEPTANCE TEST PASSES BY A FACTOR OF 1100

    controller     final x   |angle|   |rate|   peak |vel|   residual swing
    position PD      9.994    0.1348   0.3129       2.077           0.2217
    MPC             10.000    0.0001   0.0001       3.258           0.0002

The bar was "residual swing under a tenth of the PD's". It came in at **a thousandth**. The PD
arrives at the target — 9.994 of 10.000, it is not a bad position controller — and leaves the
load swinging through **12.7 degrees**, because a gain on trolley POSITION has nothing to say
about a payload that is already where it should be and still moving.

★ AND THE RISK NAMED IN THIS PLAN CAME TRUE, WHICH IS WHY IT WAS NAMED: the planner spends
**3.26 m/s** of rail speed against the PD's 2.08. Speed is a STATE limit and `boxQP` bounds
controls only, so there is no constraint to write — the cost weight is the whole brake, exactly
as with momentum excursion. The demo shows peak speed for that reason. **It was measured, not
assumed.**

★ THE SIMULATION IS NONLINEAR AND THE PLAN IS NOT, throughout. The planner never sees `sin θ`
and the crane is never stepped without it.

Built, linted, smoked and shipped first try — which is what a problem with no contact layer,
no floating base and no kinematic chain looks like.
