# Showcase examples for the MPC / IK solvers

## Why these, and why in this order

**Every failure in the humanoid and quadruped arcs was in the layer BETWEEN the solver and the
robot** — capsule axes, contact-row conventions, teleport notifications, warm starts, a servo
and a command fighting over one joint. `boxQP`, the Riccati recursion, the LIPM and crane
Jacobians and the IK all held up whenever they were handed clean inputs.

So the showcases are ordered by **how little of that layer they contain**. Contact and floating
bases are where the time goes; kinematics and small analytic models are where the solver gets to
speak for itself.

★ AND EACH ONE SHIPS WITH ITS NAIVE BASELINE SIDE BY SIDE, the way `balance_flywheel` and
`crane` do. "Our MPC works" is a far weaker claim than "here is the same problem, the same
horizon, one knob different."

★★ AND THE ACCEPTANCE TEST IS WRITTEN BEFORE THE CODE, as a NUMBER. Not "it looks smoother" —
a quantity, measured on both, with the bar stated up front. That discipline is the only thing
that has reliably distinguished progress from motion in this project.

---

## 1. ✅ Anti-sway crane — DONE

`examples/crane`, plan in `crane_plan.md`. Trolley on a rail, payload swinging below; carry it
10 m and arrive still.

    controller     final x   |angle|   |rate|   peak |vel|   residual swing
    position PD      9.994    0.1348   0.3129       2.077           0.2217
    MPC             10.000    0.0001   0.0001       3.258           0.0002

Bar was "under a tenth of the PD's"; it came in at **a thousandth**. Built, linted, smoked and
shipped first try — which is what no-contact, no-floating-base, no-chain looks like.

---

## 2. ✅ Rocket landing — DONE. 4 of 4 against the PD's 0 of 4. `rocket_plan.md`

A body under gimballed thrust must land softly on a pad.

**State** `[x, y, ẋ, ẏ, θ, θ̇]`. **Control** `[thrust, gimbal angle]`.

★ **THE CONSTRAINTS ARE THE PROBLEM, WHICH IS THE POINT.** Thrust is bounded above AND BELOW —
a real engine cannot throttle to zero — so "cut the engine and coast" is not available. The
gimbal is bounded. And the pad is a floor the trajectory must not pass through, which is a
STATE constraint the planner has to respect from far away.

**This is where `boxQP` earns its keep**: the four hand-computed clamp cases are load-bearing
rather than incidental, and a lower thrust bound is exactly the kind of asymmetric box that
catches a solver taking shortcuts.

**Acceptance test:** touch down with |vertical speed| < 0.5 m/s, |horizontal speed| < 0.3 m/s
and |tilt| < 5 degrees, from a spread of initial offsets. Baseline: a PD on position and
attitude with the same bounds — it will either crash or hover.

**Known risk:** the floor is a state constraint and `boxQP` bounds controls only. Same trap as
momentum excursion and rail speed. **Measure the lowest point of the planned path; do not assume
the cost weight held it.**

---

## 3. ✅ Redundant chain IK — DONE. Accuracy flat, joint motion spans 133x. `chain_ik_plan.md`

A ten-link planar chain, base pinned, tip tracking a target the user drags.

★ **TEN DEGREES OF FREEDOM FOR A TWO-DOF TASK**, so the null space is eight-dimensional and the
solver's conditioning is on display. A naive pseudo-inverse jitters and flips near singularities;
damped least squares glides. **Instability in an IK solver is instantly visible in a redundant
chain** in a way it never is in a six-DOF arm.

**Zero dynamics, zero contact** — the layer that has never broken, and nothing else.

**Acceptance test:** drag the target through and past the reachable boundary. Tip error under
1 mm inside the workspace; **joint velocity bounded everywhere**, including at full stretch,
where the naive version diverges. Report peak |q̇| for both.

**A/B:** damping factor as a slider, zero at one end. Zero is the naive solver, and the failure
is dramatic and instant.

---

## 4. ⚠️ Catching a thrown ball — CLOSED as an honest negative. `catch_plan.md`

A fixed-base arm intercepts a ball in flight.

★ **THE INTERCEPTION TIME IS PART OF THE ANSWER, NOT AN INPUT.** And the terminal condition is
on VELOCITY as well as position — the hand has to match the ball, not swat it. That combination
is what a planner is for.

**Why this one is safe:** fixed base. No floating root, no contact scheduling, no whole-body
mapping — every category that consumed the humanoid turns is simply absent. The arm already
exists (`examples/robot_3d`, the Kuka).

**Acceptance test:** catch rate over a spread of throws, with |hand − ball| < 3 cm and relative
speed < 0.5 m/s at contact. Baseline: aim at where the ball is NOW (pure pursuit), which misses
by roughly the flight time times the ball speed.

---

## 5. Ball and plate

A plate tilts in two axes; a ball rolls on it; drive it to a target and stop it there.

★ **NON-MINIMUM PHASE, AND IT LOOKS LIKE A MISTAKE.** To stop the ball you must first tilt the
WRONG WAY. Same shape as the crane's reverse, and the same reason a reactive controller cannot
do it — by the time the ball is on target, tilting toward the target only speeds it up.

**Risk, named:** the only one on this list with contact. But it is the simplest kind — a sphere
on a plane, one point, no capsules and **no axis convention to get wrong**. That last part is
worth saying out loud after `vec(0,0,1)` cost three turns.

**Acceptance test:** ball within 2 cm of target with speed under 2 cm/s, from four starting
corners. Baseline: PD on ball position, which orbits or oscillates.

---

## Ideas considered and set aside

  * **Walking quadruped** — the contact-schedule layer is exactly what has repeatedly failed,
    and the gait is mostly kinematics rather than a planner showcase.
  * **Humanoid one-leg balance** — still open (`humanoid_balance_plan.md`), and the honest number
    is modest: the arms are worth about 0.23 m/s of push, 0.43 with them extended.
  * **Cartpole swing-up** — already shipped (`examples/mpc_cartpole`), and rigorous, but the
    payoff reads as a physics toy rather than a task anyone recognises.

## ★★★ A DECISION THAT CHANGES THE WHOLE PROJECT'S FRAME

**The target is a game in which characters are physically simulated robots — not sim2real.**

So a model is a DESIGN ARTEFACT, not a fixture to be honoured. When the Kuka imported with `nu 0`
and nothing to plan with, the answer was not to fix the URDF importer: it was to invent an arm
with actuators, designed backwards from the task. Five minutes, and the blocker evaporated.

★ WHAT THIS DOES AND DOES NOT LICENSE. It licenses inventing robots, tuning their reach, mass and
torque limits until a demo is impressive, and preferring MJCF over URDF because MJCF has
actuators. **It does not license moving the acceptance test.** A robot built to make its own test
easy proves nothing; a robot built so the test is FAIR, and then measured against it, proves the
planner. Keep those two apart.

## ★★★ THE LIBRARY'S REAL LIMIT, FOUND BY BUILDING ON IT

Four showcases in, the gap is not the solver — it is what the COST can express. `Cost` holds
diagonal weights on joint positions and velocities and nothing else, so a task like "the hand
should be there, moving like that" has to be translated into joint angles by `Ik` before the
planner ever sees it.

**That translation is where the planner's advantage goes.** It arrives having already been told
the answer, and on a redundant arm it is also told to discard every alternative.

`task_space_cost_plan.md` has the design. It is the single change that would make the articulated
planner more capable than IK plus a servo rather than an expensive way to match one.

## ⚠️ ON THE ONE THAT DID NOT WORK

The catch is closed without a win, and deliberately so. Four controllers — two servos, two
planners — over a fivefold range of ball speeds, none meeting a bar set before any code existed.
The arm reaches **71 m/s** of hand speed, so it is not a power problem.

★ **THE ACCEPTANCE TEST IS WHAT MAKES A NEGATIVE RESULT READABLE.** Written first, it measured
relative speed as well as distance — and the best servo reached a gap of 0.000 m with 4.36 m/s of
relative speed. On distance alone that is a triumph; on the real criterion it is a swat. **A bar
chosen after the fact would have been chosen to be cleared.**

★★ AND THE DIAGNOSIS IS REUSABLE: every formulation asked the hand to BE somewhere at a moment,
and a catch is a RENDEZVOUS — joining a trajectory and travelling along it. That distinction
applies to striking, docking, hand-offs and landings, and it is worth more than a demo that
worked for reasons nobody wrote down.

## 6. Reaching a target in 0.3 s — THE ONE THAT FITS THE ARCHITECTURE (`reach_plan.md`)

The intended system is **RL picks a kinematic target 0.3 s ahead, MPC reaches it**. So the claim
worth proving is not "MPC beats PD at a task" but "given a target 0.3 s away, MPC reaches it
better" — and torque limits make that provable rather than arguable.

★ MEASURED ALREADY: no PD gain does both jobs. Slow enough not to overshoot means not arriving
(0.1745 m short); fast enough to arrive means saturating and sailing past (0.0995 short then
0.1166 over, at 318 N·m against a 260 limit). **A planner told WHEN has no such tradeoff.**

**This supersedes the remaining showcase ideas in priority.** Ball-and-plate is a nice
non-minimum-phase illustration; this is the bottom half of the system actually being built.

## 7. ✅✅ Tracking a moving target — **THE ONE WHERE THE PLANNER WINS**

`examples/tracking`, plan and measurements in `reach_plan.md`.

    PD kp  2500    0.685 rad
    PD kp  9000    0.437 rad
    PD kp 20000    0.287 rad     ← the best the family does
    MPC preview    0.096 rad     ← three times better

★★★ **AND IT IS A DIFFERENCE IN INFORMATION, NOT IN TUNING.** A servo tracking a target moving
at `v` holds a lag of about `2v/√kp` — always behind, and no gain removes it, only trades it
against saturation and ringing. A planner shown the path 0.3 s ahead leads instead. The demo puts
the gain on a live slider so the claim can be attacked rather than asserted.

★ THE ARM IS BUILT TO BE HARD FOR A SERVO: five segments, 1.9 m, **6 kg at the tip**, so the
inertia is strongly configuration-dependent and no single `kp` is right everywhere. The planner
re-linearises the real mass matrix at every knot.

★★ AND IT IS THE BOTTOM HALF OF THE INTENDED SYSTEM — a policy choosing a kinematic target a
fraction of a second ahead, a planner reaching it. Here the target comes from a closed form
instead of a policy; **nothing below the interface would change.**

## 8. ⚠️ Quadruped torso attitude — CLOSED as "no". Fixed WITHOUT a planner (`torso_mpc_plan.md`)

`examples/quadruped` commands torso roll/pitch open-loop: IK the legs for the wanted attitude,
hand the joint angles to a PD, and never look at the torso again. Measured, **every command
undershoots by a nearly constant 0.030–0.043 rad** — about 2.3 degrees, always the same
direction, invisible to the controller.

★ AND THE FIX IS NOT AUTOMATICALLY MPC. A few lines of attitude feedback would remove most of it,
and **the comparison has to be against that corrected servo**, not the shipped open-loop one.
Where a planner should still win is the transient, a MOVING command (preview — the advantage that
survived every ablation), and staying inside 35 N·m actuators while doing it.

## ★★ TWO EXAMPLES NOW CLOSED AS "NO", AND THAT IS A RESULT

The catch and the quadruped torso both ended without an MPC win. Neither was a wasted turn:

  * the catch produced the control box on by default, `Plan.setHorizon`, and `Cost.task`;
  * the torso produced a **bug fix in a shipped demo** — sliders that undershot by up to 32% —
    and it cost six lines rather than a planner.

★ THE PATTERN WORTH KEEPING: **measure the gap, then fix it the cheapest way that works, then
ask whether anything remains.** Reaching for the planner first would have produced a worse
answer to both, and the honest "no" is what makes the one real win — `examples/tracking`, where
preview beats a tuned servo by 1.63x — mean anything.

## 9. Foot slip under a moving torso — **THE STRONGEST REMAINING MPC CASE** (`foot_slip_plan.md`)

Measured on the shipped quadruped running the attitude routine: **every foot slides 4.3 m in
12 seconds**, with the friction demand peaking at **1.83x the cone** and over the limit ~85% of
the time.

★★★ THIS IS THE FIRST PROBLEM IN THE WHOLE SHOWCASE WHERE A PLANNER HAS SOMETHING A SERVO
STRUCTURALLY CANNOT HAVE: **it can refuse to ask for a force the ground cannot supply, and shift
the load to a leg that can.** A position controller has no representation of a friction cone —
not a weak one, none.

★ THE CHEAP FIXES STILL COME FIRST (re-plant the stale targets, soften the legs), because the
attitude case just showed how a missing loop masquerades as a planner's advantage. But unlike
that case, there is a reason to expect something left over.
