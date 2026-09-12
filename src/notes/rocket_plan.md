# Rocket landing — plan

## The problem, precisely

Planar rigid body under gimballed thrust. **State** `[x, y, vx, vy, θ, ω]` — `y` is altitude,
`θ` is tilt from vertical, positive toward `+x`. **Control** `[thrust, gimbal]`.

Body up-axis is `(sin θ, cos θ)`; the gimbal deflects thrust by `δ` within the body, so:

    ax = T·sin(θ+δ) / m
    ay = T·cos(θ+δ) / m − g
    α  = −L·T·sin δ / I          (engine sits L below the centre of mass)

★ **NONLINEAR, UNLIKE THE CRANE AND THE BALANCING MODEL.** `sin(θ+δ)` couples attitude and
gimbal, so `A` and `B` depend on the state and the control, and every knot must be
re-linearised. **This is the first showcase that exercises the full iLQR loop rather than a
one-shot LQR** — which is the point: the recursion has been tested against hand-derived gains,
and this is it doing the job it was built for.

## ★★★ WHY THIS PROBLEM AND NOT ANOTHER

**The constraints are the problem.** Not decoration on it — the problem.

  * **Thrust is bounded BELOW as well as above.** A real engine cannot throttle to zero, so
    "cut the engine and coast" is unavailable, and a plan that wants less deceleration than
    `T_min` gives must instead **tilt the rocket to waste some thrust sideways**. That is a
    manoeuvre no gain produces and the box solve makes available.
  * **The gimbal is bounded**, so attitude authority runs out exactly when a late correction
    needs it most.
  * **The pad is a floor the path must not cross**, from far away.

This is where `boxQP`'s four hand-computed clamp cases stop being incidental. An asymmetric box
(`[0.4·W, 2.0·W]`) is precisely the shape that catches a solver quietly treating a bound as
symmetric or as a simple clamp after the fact.

## Numbers

    mass            500 kg          weight 4905 N
    inertia         3000 kg·m²
    engine arm      L = 5 m below the centre of mass
    thrust          [0.4·W, 2.0·W] = [1962, 9810] N     ← cannot throttle to zero
    gimbal          ±15° = ±0.262 rad
    start           x 30 m, y 100 m, vx −10, vy −30 m/s, θ 0.10 rad

Full gimbal at full thrust gives `L·T·sin δ / I` ≈ 4.2 rad/s² — real authority, not a token.

## ★★★ ACCEPTANCE TEST, FIXED BEFORE THE CODE

Touch down (`y ≤ 0`) with **all four** of:

    |vy| < 0.5 m/s        |vx| < 0.3 m/s
    |θ|  < 0.087 rad (5°) |x|  < 1.0 m   (on the pad)

from a **spread of starting offsets**, not one lucky trajectory. Baseline: a PD on position and
attitude given the same bounds — it will either crash or hover, because it cannot represent
"tilt to waste thrust I am not allowed to switch off".

**Bar: MPC lands the spread; the PD lands none of it.** And report both, as numbers.

## Gates, in order

1. ✅ **The model against physics, not against itself.** DONE, first try. No thrust → free fall at exactly `−g`.
   `T = mg`, `δ = 0`, `θ = 0` → nothing moves, for thousands of steps. Gimbal produces torque
   of the right SIGN, checked both ways, since a norm would pass with it inverted.
2. ✅ **Jacobians against centred differences.** DONE, first try., ε = 1e-2, tolerance relative to each entry, swept
   at several attitudes AND gimbal angles — the coupling only shows up off-centre.
3. ✅ **The planner against the PD.** DONE — **4 of 4 against 0 of 4.**
4. ✅ **The demo** — `examples/rocket`, two side by side.

## ★ RISKS, NAMED NOW

**The pad is a STATE constraint and `boxQP` bounds controls only.** Same trap as rail speed and
momentum excursion, for the third time. There is no constraint to write; the cost weight is the
whole brake. **Measure the minimum altitude along the planned path and report it** — if the plan
dips below zero mid-horizon it is flying through the ground and the landing is luck.

**Re-linearisation is now load-bearing.** The crane got away with constant `A`, `B`; this cannot.
If the plan diverges, suspect too few iLQR passes before suspecting the cost weights.

**`T_min` may make hover impossible below a certain mass.** With `T_min` = 0.4·W the rocket
cannot hover at less than 40% throttle — it must descend or tilt. That is intended, and it is
what makes the problem interesting, but it means **a plan that wants to hang still is
infeasible** and the cost should not ask for it.

## ✅ GATES 1 AND 2 — `rocketStep`, `rocketLinearize`, both passing first try

  * **free fall at exactly −g**, position lagging by the half-step semi-implicit Euler owes;
  * **thrust equal to weight, upright, holds still** for five thousand steps — the two terms are
    the same number and must cancel;
  * **the gimbal's sign, both ways.** A magnitude check would pass with it inverted, which would
    make a landing demo steer itself into the ground;
  * **leaning trades lift for travel** — tilted at hover thrust it must both drift AND sink,
    which is the manoeuvre the lower thrust bound forces;
  * **Jacobians vs centred differences**, swept off-centre in tilt AND gimbal, because at
    `θ = δ = 0` half the entries vanish and a wrong derivative hides completely. The thrust
    column gets a nudge on its own scale: 1e-2 N against 4905 N is below what f32 can difference.

## 🚧 GATE 3: MPC LANDS 1 OF 4, PD LANDS 0 OF 4

The baseline behaves exactly as predicted — **0 of 4**, descending at 1.10 m/s against a 0.5
bar, because it has no way to express "tilt to waste thrust I am not allowed to switch off".

The planner is not there yet, and the failures moved in an informative order:

    attempt                          result
    reference = the pad              HOVERS at 1.15-2.23 m, leaning 0.474 rad
    linear glide slope               reaches the pad, arrives at -2.2 m/s
    √(2ah) profile + rebalanced cost reaches the pad, arrives at -1.1 to -2.9 m/s

★★★ **THE FIRST FAILURE IS THE INTERESTING ONE, AND IT VALIDATES THE MODEL.** Told to be at the
pad — 100 m away, with a 3 s horizon — the planner found that unreachable, settled for zero
VELOCITY instead, and **leaned 0.474 rad to waste thrust it could not switch off so it could
hover below minimum throttle.** That is precisely the manoeuvre this problem was chosen to
showcase. It is a clever answer to the wrong question, and the question was mine.

★ A REFERENCE MUST BE REACHABLE WITHIN THE HORIZON. "Be at the destination" is not a reference
when the destination is twenty horizons away; a descent PROFILE is. And the profile shape is not
a tuning choice — `v = −√(2·a·h)` is the fastest descent from which a given deceleration still
stops you at the ground. The linear `−0.4·h` I tried first commands −2.2 m/s with 5 m to go, and
the rocket faithfully delivered −2.2.

★★ WHAT REMAINS IS THE FLARE: it arrives ON the pad, upright enough, and too fast. The vertical
authority is there (`T_max/m − g` = 9.81 m/s², and stopping 2.2 m/s in 5 m needs 0.5), so this is
the cost or the profile near the ground, **not** the vehicle. **The next thing to measure is the
commanded thrust over the last two seconds** — if it is not saturating high, the planner does not
believe it needs to flare, and that is a reference problem rather than a weights problem.

★ AND I STOPPED HERE DELIBERATELY. Three attempts in, the changes had become weight-tuning, which
is the pattern that consumed the quadruped gait. The model and its derivatives are verified; the
policy is not; the difference is worth keeping visible.

## ✅ THE DEMO IS BUILT — `examples/rocket`

Two vehicles, same descent, same bounds; PD near, planner far. Sliders for the starting offset,
altitude and descent rate, so the spread is explorable rather than fixed.

★ **THE FLAME LENGTH IS THE THROTTLE, AND IT NEVER GOES OUT.** That is the constraint drawn
rather than described: the floor is 40% of weight, so there is always a flame, and a vehicle
needing less deceleration has to lean instead. The panel prints throttle with a MIN/MAX marker —
**that is the measurement the plan says to take next**: if the planner is not saturating high in
the last seconds it does not believe it needs to flare, which is a reference problem rather than
a weights problem, and now it can be answered by looking.

★ ONE BUG WORTH KEEPING: `for (1..trail_count)` with an empty trail is `1..0`, an integer
UNDERFLOW rather than an empty range. It ran fine in release on the host and trapped instantly
in the debug wasm smoke run — which is exactly what that gate is for.

## ★★★ THE MEASUREMENT THE PLAN CALLED FOR, TAKEN

Printed the commanded throttle on the way down. It is not a flare — it is **chatter**:

    163%  109%  88%  61%  132%  192%  200%  77%  173%  200%  40%  40%

★ **AND THE CAUSE WAS IN THE TUTORIAL ALL ALONG.** §40 says to shift the control sequence one
knot forward between solves. This planner did not — every tick warm-started from a seed stale by
one knot, so the solver re-derived from scratch under an iteration budget that assumes it does
not have to. `shiftRocketPlan` added, and wired into the example.

The crane got away without it because its problem barely changes between ticks. A descent does
not have that luxury.

## 🚧 AND LENGTHENING THE HORIZON MAKES IT WORSE — WHICH IS THE REMAINING CLUE

    horizon    result
     3 s       lands 1 of 4, arrives at -1.4 to -2.9 m/s
     6 s       lands 1 of 4, arrives at -7 to -12 m/s, tilt to -1.0 rad
    10 s       lands 1 of 4, arrives at -17 to -22 m/s

**More horizon over a nonlinear model with a fixed iteration budget means more distance over
which the linearisation is wrong, and more confidence in a plan built on it.** The centred start
lands at every horizon; the offset ones never do, so it is the LATERAL coupling — the term that
is nonlinear — that is not converging.

★ THE NEXT THING TO MEASURE IS THE ITERATION BUDGET, NOT THE WEIGHTS: sweep `passes` at 4, 12
and 30 with the horizon fixed at 3 s. If more passes fix the offset starts, the problem is
convergence and the fix is either more passes or a line search. If they do not, the cost is
asking for something the vehicle cannot do and that is a different conversation.

★★ I ATTEMPTED THAT SWEEP AND THE EDIT FAILED ITS ASSERTION, so the numbers above the sweep are
the old binary's. **Recorded rather than reported as a result** — a stale binary that prints
plausible numbers is the specific trap that has cost this project several turns.

## ✅✅ ACCEPTANCE TEST PASSED — 4 OF 4 AGAINST 0 OF 4

    controller   touchdown vy    tilt      landed
    position PD        -1.10     0.002     0 of 4
    MPC                -0.11     0.005     4 of 4

An order of magnitude inside every criterion, from every offset, and **identical whether the
solver gets 4 passes or 60** — which is what convergence looks like when the step size is chosen
rather than assumed.

Two fixes got it there, and neither was the optimiser:

★ **THE LATERAL AXIS HAD NO PROFILE.** The descent profile replaced the altitude reference and
`x` stayed a step target of zero at every knot — a vehicle 30 m out was told to be over the pad
IMMEDIATELY. The same unreachable reference that made the first version hover, left in place on
the other axis. That is why the centred start always landed and the offset ones never did.

★★ **NO LINE SEARCH.** §37 of the tutorial is titled *the forward pass, and why the step size is
not optional*, and `solveRocket` rolled out at full feedforward and kept whatever came back. On
a LINEAR model that is correct — which is why the crane and the balancing planner never needed
one and never missed it. Here the symptom was unmistakable: **more iterations made it worse**,
4 passes landing at −1.1 m/s and 60 tumbling through 6.4 rad. An optimiser that diverges as it
works harder is overshooting, not converging slowly.

★ AND THE PASS SWEEP WAS MISREAD FIRST TIME. Grepping only the "landed N of 4" line showed 1 at
every budget and looked like "not a function of it" — but the per-case MARGINS improved sharply
(vx −5.64 → −0.15). **A summary statistic hid a trend the detail lines had.**
