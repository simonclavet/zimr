# Catching a thrown ball — plan

## ★★★ WHY THIS ONE, AND WHY IT IS THE AMBITIOUS ONE

Every showcase so far plans on a **small analytic model** — four states for the crane, six for the
rocket and the balancing body. `robot_mpc.zig` has a whole section that plans on the **real
articulated robot** — `Plan`, `optimize`, `shift`, `feedbackControl`, finite-differenced
`transition` — and it is **verified and never demonstrated.** No example in the tree exercises it.

This does. A **7-DOF Kuka**, 14 states, 7 torques, derivatives by finite difference through the
actual dynamics. That is the piece with the most code behind it and the least evidence in front
of it, and it is the honest answer to "does your MPC work on a robot" rather than on a toy.

## The task

A ball is thrown across the workspace on a ballistic arc. The arm must **catch** it: be at the
right place, at the right moment, **moving with it**.

★ **THE INTERCEPTION TIME IS PART OF THE ANSWER, NOT AN INPUT.** The arc crosses the reachable
volume over a window of maybe 300 ms. Early means less time to get there; late means the ball is
faster and nearer the workspace edge. Choosing is an optimisation, and there is no gain that
represents "arrive somewhere I am not yet, at a moment I have not yet picked".

★★ **AND MATCHING VELOCITY IS WHAT MAKES IT A CATCH RATHER THAN A SWAT.** A hand at exactly the
right place with the wrong velocity knocks the ball away. The terminal condition is on position
AND velocity, which is precisely what a terminal cost expresses and a servo does not.

## ★★★ ACCEPTANCE TEST, FIXED BEFORE THE CODE

Over a **spread of at least eight throws** varying in speed, height and lateral offset:

    at closest approach:   |hand − ball| < 5 cm
                           |relative speed| < 0.5 m/s

**Bar: MPC catches at least 6 of 8. The pursuit baseline catches at most 1.**

The baseline is **pure pursuit** — IK the hand to where the ball is *now*, track with a PD. It is
not a strawman; it is what most people write first, and it misses by roughly flight-time times
ball-speed, which for a 0.6 s flight at 6 m/s is most of a workspace.

## Gates, in order, each able to fail on its own

1. ✅ **The frame budget, measured FIRST.** DONE — and it found a blocker. See below. `transition()` costs **206 µs per knot** for an 18-DOF
   Go1 — a 7-DOF arm should be nearer 70 µs, but that is an estimate and estimates have been
   wrong all session. **Measure it before designing a horizon around it.** At 70 µs and 60 knots
   one linearisation pass is 4.2 ms; a 16 ms frame affords perhaps three. If it comes out at 200
   µs the horizon must shrink or the whole design changes, and it is much cheaper to learn that
   now.
2. **Ballistics and reachability.** Where is the ball at time `t`, and is that point inside the
   arm's workspace? A cheap pre-search over candidate `t` picks the interception instant. Gate:
   for a throw that visibly passes through the workspace, the search must return a time whose
   point `Ik` can actually reach — checked against `Ik.Result.reached`, not assumed.
3. **The planner reaches a moving target.** Reference: hand at `ball(t*)` with velocity
   `ball_vel(t*)` at knot `k*`. Gate: closest approach under 5 cm on a single easy throw, with
   the **relative speed** reported, because position alone is the swat.
4. **The spread**, against pursuit. The acceptance test above.
5. **The demo** — throw with a slider, catch counter, and the frame cost on screen.

## ★ RISKS, NAMED NOW, WITH WHAT SURVIVES IF EACH FAILS

**The frame budget may not close.** If a pass costs 15 ms the demo cannot plan every frame.
Fallback that is still honest: plan at 20 Hz and use `feedbackControl` between solves — which is
what the cartpole does and what real MPC does anyway. **The demo then SHOWS the split**, which is
arguably a better lesson than pretending it is free.

**Finite-difference derivatives at 14 states may be too noisy near joint limits.** The f32
cancellation wall is documented at §39 and has bitten twice. Gate 1 should report the derivative
error at a stretched pose, not only at a comfortable one.

**Contact at the catch.** The simplest possible version is no contact at all: score the catch
geometrically and let the ball pass through. **That is the version to build first.** Making the
ball a real `zimrphysics` body that lands in the hand is a stretch goal — every contact-layer
task this session has cost more than its estimate, and the catch is legible without it.

**A 300 ms interception window against a 20 Hz replan is six chances.** If the pre-search jitters
between candidate times the arm will dither. **Commit to `t*` once chosen** and re-pick only if
it becomes unreachable — and measure whether it jitters rather than assuming it will not.

## What makes it fun

The arm **reaches ahead to empty space** and waits there — visibly anticipating rather than
chasing. A pursuit baseline beside it, always a step behind, makes the difference obvious without
a single number. A catch counter, a throw slider, and the ball's predicted arc drawn as a ghost
with the chosen interception point marked on it, so you can see the decision the planner made
before you see whether it was right.

## ✅ GATE 1 — THE BUDGET IS FINE AND THE MODEL IS NOT

**The frame budget is comfortable, and my estimate was 3x pessimistic.** 20 000 transitions of
the 7-DOF Kuka in 0.469 s including startup:

    one knot of derivatives   ~23 us      (estimated 70; the Go1 at 18 dof measured 206)
    60 knots, one pass         1.4 ms
    inside a 16 ms frame       ~11 passes

★ SO THE DESIGN IS NOT BUDGET-BOUND. Eleven full linearisation passes per frame on a real
articulated robot is more headroom than any of the small-model examples needed, and it means the
horizon can be chosen for the physics rather than for the clock. **Worth having measured rather
than assumed** — a 70 µs estimate would have led to a 30-knot horizon for no reason.

## 🚧 ★★★ BUT THE KUKA HAS NO ACTUATORS

    kuka: 9 bodies, nq 7, nv 7, **nu 0**
    Transition: a is 196 entries, b is **0**

`transition` differentiates with respect to `d.ctrl`, and this model has none — so `B` is EMPTY
and there is literally nothing to plan with. Torques can still be applied through
`applied_force`, which is what `PoseHold` uses, but that is not what the derivative machinery
differentiates.

**URDF has no concept of an actuator.** MJCF does; URDF describes a kinematic tree and its
inertias and stops there. So `kuka_iiwa.urdf` was always going to import this way, and the
articulated planner has never been pointed at a model that could feed it.

★★ THE OPTIONS, IN ORDER OF HONESTY:
  1. **Add actuators to the imported spec** — one motor per joint, written into
     `kuka_iiwa.zig` or added by the importer. It is a generated file, so the importer is the
     right place, and "a URDF arm imports with no way to drive it" is a real gap rather than a
     demo inconvenience.
  2. **Use a model that has them.** `arm_gripper.xml` and the Go1 are MJCF and carry actuators.
     The Go1 is a poor catcher; the gripper arm may be a fine one and is worth checking first —
     it costs one probe.
  3. Teach `transition` to differentiate w.r.t. `applied_force`. Broadest fix, largest blast
     radius, and it changes a tested API for one example's convenience. **Not first.**

★ AND THE DERIVATIVES ARE SANE WHERE IT MATTERS: worst `|A|` entry 1.0011 at home, 1.0004
working, 0.9999 stretched, no NaN anywhere. The f32 cancellation wall that bit twice this
session does not bite here — which the plan asked to check at a stretched pose specifically,
rather than only at a comfortable one.

**Next: check `arm_gripper.xml` for `nu > 0` before deciding.** One probe, and it decides whether
this example needs an importer change or just a different file.

## ✅✅ DECISION: INVENT THE ROBOT. GATE 1b PASSES.

★★★ **THE TARGET IS A GAME, NOT SIM2REAL** — characters are physically simulated robots, and a
character does not have to correspond to hardware anyone has built. That reframing dissolves the
blocker rather than working around it: **the Kuka's fidelity was never the point**, and an arm
designed backwards from the task is strictly better than a real one that cannot be driven.

`examples/catch/keeper.xml` — five joints (yaw base, shoulder, elbow, wrist pitch, wrist yaw),
1.28 m reach from the shoulder, generous but FINITE torque limits so a throw can be out of reach
**dynamically** as well as kinematically. Written in MJCF because MJCF has actuators and URDF
does not, which was the entire obstruction.

    keeper: 6 bodies, nq 5, nv 5, **nu 5**
    Transition: a 100 entries, b **50 entries**, worst |B| 0.058355
    Ik reach: 1.0 m reached, 1.3 m not — a real boundary, not an infinite arm

**And the budget is generous:**

    one knot of derivatives   ~14.7 us  (upper bound; includes process startup)
    horizon  40    0.59 ms/pass    27 passes inside a 16 ms frame
    horizon  60    0.88 ms/pass    18 passes
    horizon 100    1.47 ms/pass    11 passes

★ **ELEVEN FULL iLQR PASSES PER FRAME AT A HUNDRED KNOTS**, on a physically simulated
articulated arm. The rocket needed a line search because four passes were not converging; this
has room for eleven and can afford one. **The design is not budget-bound**, which is worth
knowing before choosing a horizon rather than after.

★★ AND THE ARM IS A DESIGN ARTEFACT NOW, WHICH IS A DIFFERENT KIND OF FREEDOM. If the catch
proves too hard, the arm can get faster or longer — that is a legitimate move for a game and
would be cheating for sim2real. Worth stating so the next session does not treat the model as
fixed. **What must NOT move is the acceptance test**: 6 of 8 catches against pursuit's 1, with
5 cm and 0.5 m/s at closest approach.

## Remaining gates

  2. ✅ **Ballistics and reachability** — DONE — where is the ball at `t`, and can `Ik` actually reach it?
     Checked against `Ik.Result.reached`, which has already proved honest twice.
  3. **The planner reaches a moving target** — closest approach under 5 cm on one easy throw,
     with the RELATIVE SPEED reported, because position alone is the swat.
  4. **The spread against pursuit.**
  5. ✅ **The demo** — `examples/catch`.

## ✅ GATE 2 — THE INTERCEPTION SEARCH WORKS

    throw   t*      ball at interception       Ik reached
        0   0.73   (-0.12,  0.00,  0.58)      true
        1   0.75   (-0.00, -0.08,  0.62)      true
        2   0.73   (-0.17,  0.04,  0.56)      true
        3   0.85   ( 0.35, -0.02,  0.32)      true

A scan over candidate times taking the LATEST reachable instant — more time to prepare, and the
arm is not committed before it must be. Reachability judged by `Ik.Result.reached` rather than an
error threshold I invented, which has now been the honest answer three times.

## ★★★ GATE 3: THE HORIZON WAS 0.24 s AND THE BALL WAS 0.73 s AWAY

`Plan` steps the REAL dynamics, so a knot is the model's own timestep — 1/250 s. **Sixty knots is
0.24 seconds.** The planner was not failing to reach the interception; it had never been told
about it. At 220 knots (0.88 s) the closest approach improved from 0.86 m to 0.42 m and then to
0.07 m on the easiest throw.

★ **A HORIZON IN KNOTS IS NOT A HORIZON IN SECONDS**, and every small-model example so far hid
that because their steps were 0.02–0.05 s. The articulated planner steps at the simulation rate,
so a horizon that sounds generous can be a quarter of a second.

## ★★★ AND THE DECISIVE CHECK REFRAMED THE WHOLE EXAMPLE

Before touching a single weight: **can a plain servo make the move at all?**

    throw   time available   closest |hand-ball|   verdict
        0             0.73                0.0065   arm CAN
        1             0.75                0.0105   arm CAN
        2             0.73                0.0088   arm CAN
        3             0.85                0.0077   arm CAN

**The arm is capable and the planner is the problem** — which is the separation worth having
before tuning anything. But it also says something inconvenient and important: **IK plus a PD,
handed the interception point and time, puts the hand within 7 mm of the ball.** For a game, that
is already a catcher.

★★ SO MPC'S ADVANTAGE HAS TO BE SOMEWHERE ELSE, AND IT IS: **a servo driven to a FIXED pose
arrives and STOPS.** The ball is doing 4.7 m/s. Position alone says the PD caught it; relative
velocity says it swatted it across the room. That is exactly the distinction the acceptance test
already encodes — `|relative speed| < 0.5 m/s` — and it is why that criterion was written down
before any code.

**The comparison the demo must draw is therefore not "can it get there" but "is it moving with
the ball when it does".** The measurement fix for that was written and its edit failed its
assertion, so the relative-speed column above is still the BALL's speed, not the relative one.
Recorded as untested rather than reported.

## Remaining

  3. Weights: the planner reaches 0.07 m on the easiest throw and 0.72 on the hardest with
     state 0.05 / terminal 2.0 / control 1e-4. The servo proves the motion exists, so this is a
     cost problem. Raise the state and terminal weights and re-measure.
  4. The velocity-matched reference: the terminal knot should ask for the ball's VELOCITY, not a
     static pose. That is the change that makes the planner beat IK+PD rather than tie it.
  5. The spread, then the demo.

## ★★★ THE BASELINE SWATS. ALL FOUR. THAT IS THE HEADLINE.

    throw   time available   closest |hand-ball|   rel speed   verdict
        0             0.73                0.0065        5.81   swat
        1             0.75                0.0105        5.00   swat
        2             0.73                0.0088        6.45   swat
        3             0.85                0.0077        7.02   swat

**IK plus a PD puts the hand within 7 to 11 millimetres of the ball and catches nothing.** It
arrives and STOPS; the ball is doing 4.7 m/s. Position says it caught it; relative velocity says
it swatted it across the room.

★ THIS VINDICATES WRITING THE ACCEPTANCE TEST FIRST. `|relative speed| < 0.5 m/s` was set down
before any code existed, and it is the only reason a controller that looks perfect on the
obvious metric is correctly scored at zero. Had the bar been "get within 5 cm", the classical
baseline would have won and the example would have had nothing to show.

## 🚧 AND THE PLANNER IS NOT BEATING IT YET

    weights            velocity ref   closest approach
    0.05 / 2.0         no             0.07 - 0.72 m
    4.0  / 400         yes            0.38 - 0.75 m
    0.05 / 2.0         yes            0.24 - 0.71 m

★ TWO THINGS CHANGED AT ONCE AND THE NUMBER GOT WORSE, which says nothing about either. Reverting
the weights while keeping the velocity reference isolates it: **the velocity target costs about
0.17 m of position accuracy** (0.07 → 0.24 on the best throw). That is a real trade and an
expected one — asking the hand to be moving means it cannot also be perfectly placed — but 0.24 m
is still five times the bar.

★★ AND RAISING THE WEIGHTS MADE IT WORSE, which is the same signature the rocket had. There it
meant no line search; here `optimize` already HAS one, so the cause is different. The most likely
candidate: `term_w` is applied across all ten tangent dimensions including velocities, and the
joint velocities needed to match 4.7 m/s of hand speed are large — so a terminal weight of 400 on
them dwarfs everything else in the problem. **Weight the position and velocity blocks separately
before touching anything else.**

## What is solid, and what to do next

Solid: the arm, the budget (11 passes/frame at 100 knots), the interception search, the
horizon-in-knots lesson, and **a baseline that is now correctly scored as a swatter**.

Next, in order:
  1. Split `term_w` into position and velocity blocks rather than one number for all ten.
  2. Re-measure with the velocity reference on and off, one change at a time.
  3. If the planner still cannot close 0.24 m in 0.73 s while the servo closes it to 7 mm, the
     fault is the cost, not the solver — the servo is proof the trajectory exists.

## ★★★ THE DIAGNOSIS: I MADE THE ROCKET'S MISTAKE AGAIN

The reference is built once, from `Ik` at the interception, and then **copied into every knot**:

    for (0..horizon + 1) |k| {
        @memcpy(reference[k * nstate ..][0..m.nq], interception_pose);
    }

So the planner is asked to be **at the destination from knot zero**. That is "a destination is
not a reference" — the failure diagnosed on the rocket, written into tutorial §42 as one of five
wrong questions, and then repeated here three examples later.

★ THE ROCKET'S FIX APPLIES UNCHANGED: **a reference must be a TRAJECTORY the horizon can
follow.** For the crane and rocket that meant a descent profile; here it means the arm's pose
interpolated from where it is now to where it must be at `t*`, so every knot has somewhere
reachable to go. The servo does this implicitly — a PD from a distant target produces exactly
such a path — which is why the servo reaches 7 mm and the planner does not.

★★ AND THE WEIGHT SWEEPS WERE ALWAYS GOING TO BE NOISE against that. Position/velocity split,
2 to 800 on the terminal, velocity reference on and off — all of it re-arranging the cost of a
question that could not be answered. **Sweeping parameters when the formulation is wrong
produces motion, not progress**, and I have now spent several turns doing it.

## Honest state

**Solid:** the invented arm (nu 5, ~14.7 µs/knot, 11 passes per frame at 100 knots); the
interception search; the horizon-in-knots lesson; and **the baseline correctly scored as a
swatter** — 7 to 11 mm of position and 5 to 7 m/s of relative speed, catching nothing.

**Not solid:** the planner, at 0.24 to 0.52 m. The servo proves the trajectory exists, so this
is the reference, not the solver.

**Next, and it is one change:** interpolate the reference from the current pose to the
interception pose across the horizon, with the velocity target only at the final knots. Then
re-measure — and change ONE thing at a time, which the last three rounds did not.

## ⚠️ THE PROBE IS EDIT-DAMAGED. REWRITE IT, DO NOT PATCH IT.

`catch_probe.zig.txt` has been through a dozen indexed edits, several of which failed their
assertions and left the file half-changed. Two consequences, both discovered rather than
suspected:

★ **THE WEIGHT LINES WERE DELETED AND NEVER REPLACED.** For two full runs `state_w` and `term_w`
were UNINITIALISED, so the planner optimised against whatever the allocator handed it. **Every
number from those runs is void** — including the 0.24 to 0.52 m figures reported as if they meant
something.

★ **AND THE LAST RUN PRINTED A HEADER WITH NO ROWS**, because balancing the braces by counting
put them in the wrong scope and the throws loop ended up empty.

**Rewrite the probe from scratch.** The physics is settled and small: an invented arm, a
ballistic ball, an interception search, and a plan. Perhaps 150 lines, written once, rather than
a file that has been patched into a shape nobody can read.

## ★★ THE PATTERN, STATED PLAINLY

Three turns on this example. The genuine findings — the arm, the budget, the horizon-in-knots
lesson, the swatting baseline — all came from **clean probes run once**. Everything after that
came from patching one file repeatedly, and produced: two runs against uninitialised memory, one
run with an empty loop, several stale binaries reported as results, and no working demo.

**When a probe needs its fifth edit, the edit is not the problem — the file is.** Same shape as
the quadruped gait: the diagnosis was available early and got buried under attempts to reach it
by increments.

## What is actually established, and is not in doubt

  * the invented arm: nu 5, ~14.7 µs/knot, **11 iLQR passes inside a 16 ms frame at 100 knots**;
  * the interception search, agreeing with `Ik.Result.reached` on all four throws;
  * **a horizon is in knots of the model's timestep** — 60 knots is 0.24 s, not a horizon;
  * **the IK+PD baseline swats all four**: 7 to 11 mm of position, 5 to 7 m/s of relative speed,
    zero catches. Which is why `|relative speed| < 0.5` was worth fixing before any code;
  * the reference must be a TRAJECTORY, not a destination copied into every knot.

The rewrite starts from that list, and none of it needs re-deriving.

## ✅ THE PROBE WAS REWRITTEN CLEAN, AND THE NUMBERS ARE TRUSTWORTHY AGAIN

    controller   throw   closest gap   relative speed   verdict
    IK + PD          0        0.0052             5.82   swat
    IK + PD          1        0.0107             6.68   swat
    IK + PD          2        0.0074             5.97   swat
    IK + PD          3        0.0081             6.99   swat
    MPC              0        0.1740             6.40   miss
    MPC              1        0.4557             8.23   miss
    MPC              2        0.5267             5.51   miss
    MPC              3        0.1713             3.79   miss

**IK + PD caught 0 of 4. MPC caught 0 of 4.** One file, written once, no patched-over state —
these can be believed, unlike the last three rounds.

★ ONE MORE REAL FIX WENT IN AND HELPED A LITTLE: **`mpc.shift` slides the plan every tick and
the reference did not slide with it.** Built once, the reference's knot `k` stays at time `k·dt`
while the plan's knot `k` moves to `elapsed + k·dt` — they drift apart by a knot per tick. Same
shape as the cartpole's shift bug: everything the plan carries per knot must move together or
none of it should. Rebuilding the reference from the CURRENT pose and REMAINING time each replan
took the closest gap from 0.33 to 0.17 on the best throw.

## 🚧 THE NEXT SUSPECT, MEASURED-BUT-NOT-YET-REPORTED

`mpc.Options` has **no control-limit field**. `optimize` plans unconstrained, and the model then
clamps `d.ctrl` to its `ctrlrange` of ±260 N·m on the way in. If the plan is asking for far more
torque than the motors have, **the realised motion is nothing like the planned one and the plan
has no way to find out** — it is the "an unconstrained plan is optimistic in exactly the way an
unconstrained plan always is" problem the tutorial names at §40, arriving in person.

The instrumentation for this was written and its edit failed its assertion, so the peak-torque
column is **not** in the numbers above. **Measure it first next turn** — one column, and it
either exonerates the torque limits or explains everything.

★ AND IF IT IS THE LIMITS, THERE ARE TWO HONEST ANSWERS. Give the invented arm stronger motors —
legitimate, since it is a design artefact for a game. Or give `optimize` a control box, which
`boxQP` already implements for every other planner in this file and which the articulated one
simply never got. **The second is the better fix and the more useful one**, because every future
articulated plan wants it.

## ✅✅ THE MEASUREMENT FOUND A REAL LIBRARY BUG, AND IT IS FIXED

    controller   throw   closest gap   relative speed   peak Nm   verdict
    MPC              0        0.1740             6.40       357   miss
    MPC              1        0.4557             8.23       263   miss
    MPC              2        0.5267             5.51       267   miss
    MPC              3        0.1713             3.79       263   miss

**The plan was asking for 357 N·m against a ±260 limit.** Every throw at or over the bound: the
plan believed it would get a torque it never received, and flew a trajectory the arm could not.

★★★ AND THE CAPABILITY EXISTED ALL ALONG. `Plan.readLimits` reads the model's own actuator ranges
and `optimize` routes them to the same `boxQP` every other planner in this file already uses —
built, documented, and **opt-in**, so the first caller to plan on a real articulated robot simply
did not call it. With it on, peak torque is 258 to 260 and never over.

## ★ THE FIX IS THE DEFAULT, NOT THE CALL SITE

`Plan.init` now calls `readLimits` itself. **An unbounded plan is the surprising case, so it is
the one that should take an extra line** — a caller who genuinely wants one can clear
`has_limits`.

★★ BECAUSE THIS FAILURE IS INVISIBLE. The optimiser converges, reports success, and hands back a
plan the robot cannot execute; nothing in `Result` says otherwise. A default that silently
removes a constraint is the wrong default, and the only reason it was ever noticed is that the
plan's requested torque was printed in a column beside the outcome.

A test pins it: a fresh `Plan` on a model with actuators must have `has_limits` set, must carry
each actuator's own range at every knot, and the bounds must be REAL rather than the float
maxima that mean "unbounded" — a box of ±3.4e38 is unconstrained wearing a constraint's clothes.

## Still 0 of 4 on the catch

The box makes the plan HONEST, not yet successful — gaps moved to 0.10 to 0.40 m. That is the
right kind of progress: the planner is now solving the problem the robot actually has.

## ★★★ THE SOLVER IS STARVED, NOT STUCK — AND `Result` SAID SO DIRECTLY

    t   0  cost 4.739e3 -> 2.625e3  iters 6  conv false  reg 1.0e-6
    t  50  cost 1.839e3 -> 1.676e3  iters 6  conv false  reg 1.0e-6
    t 120  cost 1.525e3 -> 1.417e3  iters 6  conv false  reg 1.0e-4

Three things, and together they settle it:

  * **`iters 6` every time** — it uses the entire budget and is still improving when it stops;
  * **`conv false`** — it never runs out of improvement, only out of iterations;
  * **`reg 1.0e-6`**, i.e. the floor. The field's own doc says *"a large value means the problem
    was fighting back"*. It is not fighting back. The problem is well conditioned and the
    optimiser simply has not been given time to finish.

★ **THIS IS WHY `Result` HAS THOSE FIELDS.** Three turns were spent guessing between "the solver
is failing" and "the problem is wrong" — reference shapes, weight splits, velocity targets,
control limits — when one print of a struct the optimiser already returns distinguishes them.
**Ask the solver what it thinks it is doing before theorising about it.**

★★ AND THE CONTROL-BOX FIX STILL MATTERED, independently. The plan was asking for 357 N·m against
±260 and getting clamped; it is now feasible. A starved solver on an honest problem is a much
better place to be than a starved solver on a dishonest one.

## The next measurement, and the honest cost question

Sweep `iterations` at 6, 20 and 60 with everything else fixed. Two outcomes and both are useful:

  * **the gap closes** — then the answer is arithmetic. One pass at 220 knots costs ~3.2 ms, so
    20 iterations per replan is ~64 ms and a 0.02 s replan interval cannot afford it. The demo
    would then be honest about planning at a lower rate with `feedbackControl` between solves,
    which is what real MPC does anyway;
  * **the gap does not close** — then more compute is not the answer and the cost is wrong after
    all, but that would now be a MEASURED conclusion rather than a guess.

★ THE SWEEP'S EDIT FAILED ITS ASSERTION AND THE NUMBERS ABOVE ARE FROM THE UNSWEPT RUN. Recorded
as untested. The probe has now resisted three wrapper edits, which is the tell already written
into `claude.md`: **when a probe needs its fifth edit, the edit is not the problem — the file
is.** Write the sweep as its own small probe rather than wrapping this one again.

## ★★★ MORE ITERATIONS DOES NOTHING. THE STARVATION READING WAS WRONG.

    budget    throw 0   throw 1   throw 2   throw 3
         6     0.4981    0.5618    0.5486    0.1574
        20     0.4985    0.5687    0.5452    0.1561
        60     0.4964    0.5679    0.5453    0.1586

**Identical across a tenfold sweep.** A quantity unchanged across a swept parameter is not a
function of it — so the answer is not compute, and that is now measured rather than assumed.

★ AND `Result` MISLED ME, WHICH IS WORTH UNDERSTANDING RATHER THAN RESENTING. `iters 6, conv
false, reg 1e-6` is a true description: the optimiser really is still finding improvements when
it stops. It just means those improvements are worth almost nothing — it is descending a cost
whose minimum is in the wrong place. **"Still improving" and "improving usefully" are different
claims, and the struct can only report the first.**

## THE HYPOTHESIS THE NUMBERS NOW POINT AT: THE TERMINAL COST LANDS AT THE WRONG TIME

The horizon is fixed at 220 knots = **0.88 s**, and the interception is at 0.73 s and closing.
So the terminal knot — carrying by far the largest weight, 60 against 0.5 — is always
`elapsed + 0.88 s` into the future, which is **after the ball has gone past and hit the floor**.

The catch happens at knot `arrive`, and `Cost` has one `state` weight shared by every
non-terminal knot, so there is no way to say "this knot matters more than its neighbours". The
plan is being asked, with maximum emphasis, to be somewhere at a moment that no longer means
anything.

★ THE FIX IS TO MAKE THE TERMINAL KNOT *BE* THE INTERCEPTION — a horizon that shrinks as the
catch approaches, so the largest weight always lands exactly where the catch is. `Plan` allocates
a fixed horizon, so this needs either a `plan.horizon` that can be reduced after init, or a plan
rebuilt per throw at the right length.

★★ AND THAT IS A LIBRARY IMPROVEMENT, NOT A PROBE HACK. **Every interception problem has this
shape** — catching, striking, landing, arriving — and all of them need the terminal cost at a
chosen moment rather than at a fixed offset. A `Plan` whose horizon can be shortened in place is
the smallest change that buys it.

## ✅✅ THE TERMINAL KNOT WAS LANDING AFTER THE BALL HIT THE FLOOR

`Plan.setHorizon` added — shorten the horizon in place, so the terminal cost lands at a chosen
moment rather than at a fixed offset. Then set it to the time remaining, every replan:

    horizon        gap 0    gap 1    gap 2    gap 3     relative speed
    fixed 0.88 s   0.4981   0.5618   0.5486   0.1574    4.4 - 5.8
    = time left    0.0841   0.1451   0.1154   0.1779    1.40 - 2.23

★★★ **SIX TIMES CLOSER, AND THE RELATIVE SPEED FELL BY A FACTOR OF THREE.** That second number
is the one that matters: the hand is now genuinely MOVING WITH the ball, which is the thing the
IK+PD baseline structurally cannot do — it arrives and stops at 5 to 7 m/s of relative speed,
every time, however good its position.

★ AND THE DIAGNOSIS CAME FROM A NULL RESULT. The iteration sweep returning 0.4981 / 0.4985 /
0.4964 said "not compute" and pointed straight at the cost; the terminal weight is 60 against a
running 0.5, so wherever it lands is where the plan really tries — and it was landing 0.88 s out,
past the end of the ball's flight. **A parameter that changes nothing is as informative as one
that changes everything**, provided the null is believed rather than explained away.

★★ AND IT IS A LIBRARY IMPROVEMENT, NOT A PROBE HACK. Every interception has this shape —
catching, striking, landing, arriving — and `Cost` shares one weight across all non-terminal
knots, so "this knot matters more" cannot be said any other way. Making the terminal knot BE the
moment is how you say it.

## Remaining: 0.08 m against a 0.05 bar, 1.4 m/s against 0.5

Close, and the trend is unambiguous. The next thing to try is the reference near the interception
— it currently re-anchors to the CURRENT pose every replan, so the plan never inherits a sense
of being behind. Anchoring the interpolation to the PREVIOUS plan instead of to the live pose is
the obvious next experiment, and it is one change.

## ✅ THE DEMO IS BUILT — `examples/catch`

Two arms, same throw. Near one is IK + PD to the interception; far one plans. Sliders for throw
speed and lateral offset, a THROW button, and a running caught / swatted / missed tally per arm.

★ **THE PINK CUBE IS WHERE EACH ARM DECIDED TO MEET THE BALL** — drawn because the decision
happens before the motion does and is otherwise invisible. An arm reaching into empty space and
waiting there IS the plan, made visible.

★★ AND THE SCOREBOARD SEPARATES *SWATTED* FROM *MISSED*, which is the whole point. The servo
gets within millimetres and arrives STOPPED; scoring only distance would call that a catch and
the example would have nothing to show. `|relative speed| < 0.5 m/s` was written down before any
code and is the only reason the tally is honest.

Shipped with both arms still short of the full criterion — the planner at 0.08 m and 1.4 m/s
against bars of 0.05 and 0.5. **A demo that shows the current state honestly is worth more than
one tuned until it looks finished**, and the two library fixes it rests on — the control box on
by default, and `setHorizon` — are real regardless of the tally.

## ★ THREE BUGS THE BROWSER FOUND THAT THE PROBE COULD NOT

  1. **The reference was the wrong length.** `optimize` asserts `(horizon + 1) × nstate`, and
     `setHorizon` moves the horizon under a buffer allocated for the maximum — so it was handed
     2210 entries for a plan wanting 1880. The assert is right to refuse: a reference and a
     horizon that disagree is the silent-misalignment class that has cost this project several
     turns. **It only surfaced in the browser because the probe runs ReleaseFast, where `assertf`
     is compiled out.** The probe's numbers still stand — it filled and read the same prefix —
     but the demo had to be told.
  2. **The smoke run never planned.** Sixty frames with no ball in flight never enter
     `optimize`, so the gate was green because the interesting code did not run. The demo now
     throws on start, which is both a better opening and a real check.
  3. **And then it exhausted Node's 2 GB heap** — profiler timestamps, two JS boundary crossings
     apiece, from a frame that solves a trajectory optimisation. `profiler.freeze()` across the
     planner, exactly as the cartpole needed. 207 calls per frame after, of which 13 are clocks.

# ═══ CLOSING THE EXAMPLE — AN HONEST NEGATIVE RESULT ═══

## The question, put straight

> "Maybe there is no way to make a catch behavior with mpc that does not beat pd control?"

**On this problem, I did not find one.** Four formulations, four controllers, ball speeds from
1.2 to 5.8 m/s: nothing meets the bar written before any code — 5 cm AND 0.5 m/s relative.

    controller                   best gap    best relative   catches
    PD to a fixed pose             0.007          3.48          0
    PD tracking the ball ahead     0.000          3.71          0
    MPC, joint-space reference     0.287          4.09          0
    MPC, task-space cost           0.031          6.36          0

★ AND THE TASK IS NOT INFEASIBLE, WHICH IS THE MEASUREMENT THAT MAKES THIS CONCLUSIVE RATHER
THAN VAGUE: **the arm reaches 71 m/s of hand speed at full torque.** Matching a 4 m/s ball is
nowhere near its limits. Nothing here is a power problem.

## ★★★ WHAT THE NUMBERS ACTUALLY SAY, AND IT IS ONE THING

**Relative speed came back roughly EQUAL to the ball's speed, at every ball speed, for every
controller.** At a 1.19 m/s ball the hand was 4.76 m/s away from matching it; at 5.76 m/s it was
8.01. The hand is not slightly mistimed — **it is not co-moving with the ball at all.** It sweeps
through the ball's position at whatever speed it happens to have.

The tracking PD reaching a gap of **0.000** with 4.36 m/s of relative speed is the clearest
statement of it: perfect position, and completely wrong velocity, at the same instant.

★★ SO THE MISSING INGREDIENT IS NOT THE OPTIMISER. Every formulation asks the hand to BE
somewhere at a moment. **A catch is not an arrival, it is a RENDEZVOUS**: the hand has to join
the ball's trajectory and travel ALONG it for an interval, matching velocity before contact and
holding it through. Real catching robots solve that problem, not this one.

★ I TESTED BOTH ENDS OF THE INTERCEPTION WINDOW AND NEITHER HELPED. The latest reachable instant
minimises the time available to converge to the ball's velocity; the earliest gives the arm less
time to travel. **Both fail for the same underlying reason** — an instant is the wrong target
shape — which is why moving it does nothing.

## What this example IS worth, which is not nothing

  * `examples/catch` ships and honestly shows **swat versus miss**, which is a real distinction
    most demos of this kind hide by scoring distance alone;
  * **the acceptance test, written before any code, is what makes the negative result readable.**
    Had the bar been "get within 5 cm", the tracking PD would have "won" at 0.000 and the whole
    thing would have looked like a success. It measured the right quantity and then said no;
  * two library features came out of it and stand on their own — the control box on by default,
    and `Plan.setHorizon`;
  * and a third, `Cost.task`, is built and tested end to end even though it did not rescue this.

## If it is picked up again, the ONE change to make

**Reformulate the target as a rendezvous segment**: over the last ~150 ms, the hand's task is the
ball's trajectory itself — position AND velocity at every knot, not a point at one knot.
`Cost.task` already takes a per-knot position and velocity array, so the machinery exists. That
is a different problem statement, and it is the one that can actually be satisfied.

**Do not tune the current formulation further.** Four controllers agreeing to within a factor of
two, across a fivefold range of ball speeds, is not a tuning surface — it is a statement about
the problem being asked.

## ✅ THE NEGATIVE RESULT SURVIVES THE HARNESS FIX — RE-VERIFIED

An `applied_force` leak was later found that contaminated every planner number in the session
(see `reach_plan.md`). **The catch comparison was re-run with it closed**, because a conclusion
drawn from contaminated measurements has to be re-earned rather than assumed:

    ball speed    fixed PD        tracking PD      MPC
      1.19       0.242  4.23     0.237  6.45     1.066  1.06
      2.47       0.016  6.13     0.005  4.84     0.775  2.94
      3.52       0.206  7.91     0.283  4.22     0.465  4.12

**Still no catches, by anything.** The conclusion stands on clean numbers now: an ARRIVAL is the
wrong target shape for a catch, and the fix is a rendezvous segment rather than a better
optimiser or a cleaner harness.

★ WORTH THE RE-RUN EVEN THOUGH THE ANSWER DID NOT CHANGE. A result that happened to be right for
the wrong reasons is indistinguishable from one that is right, until you check.
