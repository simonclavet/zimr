# Why the quadruped's feet slide, and what to do about it

## ★★★ MEASURED, NOT GUESSED

Running the cone-plus-roll routine for 12 seconds with the shipped controller:

    foot   slid (m)   worst |ft|/(mu*fn)   ticks over the cone
       0     4.3466                1.826                 2127
       1     4.3160                1.826                 2152
       2     4.3543                1.826                 2124
       3     4.3386                1.826                 1835

**Every foot slid 4.3 metres.** The friction demand peaks at **1.83x the cone** and sits over the
limit for roughly **85% of all sampled ticks**. This is not a tuning wobble; the feet are being
asked, almost continuously, for more tangential force than the ground can supply.

★ AND THE FRICTION COEFFICIENT CAME FROM THE CONTACT ITSELF (`Contact.friction`), not from a
number typed into the probe — the ratio means what it says.

## ★★ THE MECHANISM, AND IT IS NOT REALLY ABOUT FRICTION

The controller commands POSITIONS and knows nothing about forces. Two things compound:

  1. **The planted spots are captured once, at stance, and never updated.** The moment the robot
     drifts, every leg is hauling toward a world point that no longer corresponds to anything —
     forever, and harder every second as the error grows.
  2. **The four legs are solved independently.** Each is told to hold its own foot still while
     the torso moves between them; any inconsistency between the four solutions comes out as
     tangential force at the contacts, and nothing arbitrates.

**Raising friction would hide this rather than fix it** — which is why Simon ruled it out, and
he is right to.

## The fixes, cheapest first — and the cheap ones must be tried first

  1. **RE-PLANT.** Refresh each foot's target to where the foot actually is, on the same cadence
     as the trim. A stale target is a force demand that only grows. **Few lines.**
  2. **COMPLIANCE.** A softer leg demands less force for the same position error, which attacks
     the tangential demand directly. Simon's instinct, and it costs one constant — though it
     will trade against the attitude accuracy the trim just bought, so both must be measured
     together.
  3. **A PLANNER THAT KNOWS THE CONE.** `solveTrunk` in `robot_mpc.zig` already allocates contact
     forces against a friction PYRAMID — that is what its `rows_per_contact = 4` basis is for,
     and it was verified finding 29.4 N per foot against a quarter-weight nobody told it.
     **This is the case where a planner has something no servo can have**: it can refuse to ask
     for a force the ground cannot supply, and shift the load to a leg that can.

★★★ THE ACCEPTANCE TEST, FIXED NOW: run the routine 12 s and report **total foot slip** and
**ticks over the friction cone**. Bar: slip under 0.1 m and zero ticks over the cone, against a
baseline of re-plant plus compliance at its best setting. **The planner must beat the fixed
servo, not the shipped one** — the attitude case already showed how easily a missing loop
masquerades as a planner's advantage.

## ★ AND SIMON'S SECOND IDEA IS THE RIGHT WAY TO MAKE IT MATTER

**A heavy arm and gripper on the torso.** It moves the centre of mass around as the arm swings,
which makes the load transfer between legs large and fast — precisely the regime where
distributing contact forces well is worth more than holding joint angles well. The same move as
the 6 kg gripper on the tracking arm, which is what made that comparison bite.

★ AND IT IS HONEST FOR A GAME: the robot is a design artefact, so hanging a heavy arm on it to
make the control problem interesting is a legitimate choice rather than a cheat.

# ═══ THE CHEAP FIXES ARE EXHAUSTED — WHICH MAKES THIS THE REAL MPC CASE ═══

## ★★ TWO WRONG BASELINES BEFORE THE RIGHT ONE, AND BOTH ARE WORTH RECORDING

  1. **I substituted `kv = 2√kp` for the shipped damping.** That is three times as much damping
     as the real controller, a different system entirely, and it scored the baseline at 0.477 rad
     of lag where the truth is 0.0098. **Two things changed while I believed one had.**
  2. **Then the whole sweep used kp 400 / kv 12 — settings copied from another example.** The
     quadruped has its own inline PD and ships at **kp 100, kv 2**. A full sweep measured a
     controller nobody runs.

★ THE TELL FOR BOTH WAS THE SAME: a number that disagreed with an earlier measurement of
supposedly the same thing. **Check the baseline against a known value before trusting a sweep
built on it** — the sweep is only as good as its zero.

## ★★★ THE HONEST NUMBERS, AT THE DEMO'S ACTUAL SETTINGS

       kp    kv   attitude lag   total slip   worst cone   ticks over
      100     2         0.0117        1.079         1.83         2452   ← as shipped
      100     6         0.0131        0.945         1.72         2217   ← 12% better
      100    12         0.0268       21.751         1.83         7206   ← overdamped, far worse
      200     8         0.0087        2.813         1.83         7838
       60     5         0.1944        5.648         1.83         3215

**The demo is already near the best a position PD can do.** About 1 m of slip in 12 s — roughly
9 cm/s of drift, which is exactly what is visible on screen — and the friction cone violated
**2452 times, peaking at 1.83x**.

★ COMPLIANCE IS ALREADY APPLIED (kp 100 is soft), correcting the damping ratio buys 12%, and
going softer or stiffer both make it worse. **There is no cheap fix left**, which is precisely
what was missing from the attitude case.

## ★★★ SO THIS IS THE CASE WHERE A PLANNER HAS SOMETHING NOBODY ELSE DOES

A position controller has **no representation of a friction cone** — not a weak one, none. It
cannot know that the foot it is hauling on is the one currently carrying least load. A planner
that allocates contact forces against the pyramid basis can, and `solveTrunk` already does
exactly that.

**Bar: slip under 0.1 m and zero ticks over the cone, against kp 100 / kv 6** — the corrected
servo, not the shipped one, and not the two wrong ones I measured first.

★ AND SIMON'S HEAVY-ARM IDEA IS THE MULTIPLIER. Swinging mass on top makes the load transfer
between legs large and fast, which is the regime where allocating forces well beats holding
angles well. The 6 kg gripper is what made the tracking comparison bite; the same trick applies
here, and on a design-artefact robot it is a legitimate choice rather than a cheat.

## ✅ SHIPPED INTO `examples/quadruped`

  * **`kv` 2 → 6.** The damping RATIO was wrong, not the stiffness: `kv = 2` against `kp = 100`
    is badly underdamped, and an underdamped leg oscillates about its target — a foot that
    alternately grips and breaks away. Slip 1.079 → 0.945 m, cone violations 2452 → 2217.
    **Both directions are worse** (kv 12 slides 21.75 m), which is what makes it a minimum rather
    than a guess.
  * **`kv` is now on a slider.** It was the parameter that mattered most for slip and there was
    no way to touch it. A control whose best value is three times its default deserves to be
    reachable.
  * **Slip and friction demand are on screen**, always, with a "clear slip" button that re-plants
    the reference. Above 1.0 the ground is being asked for force it does not have.

★ THE READOUT IS THE POINT. The whole question — "why do the feet slide" — was unanswerable from
the demo because nothing reported either the slip or the demand causing it. **A behaviour nobody
can measure is a behaviour nobody can improve**, and that is now fixed regardless of whether the
planner is ever built.

## What remains for the planner, unchanged

**0.945 m of slip and 2217 cone violations, at the best position-PD settings available.** No
cheap fix is left. That is the gap, and it is the one a force-allocating planner is uniquely able
to close.

# ═══ ✅ THE ARM IS ON, SPLICED PROCEDURALLY ═══

A three-bone arm with a heavy gripper, **injected into the Go1's MJCF at load time** rather than
checked in as a second robot: the bodies go into the trunk, the motors into the actuator block,
and the whole thing goes through the normal importer. Reach, mass and mount are parameters of
the demo, and nobody maintains a fork of the fixture.

    go1 + arm: 19 bodies, nq 23, nv 22, nu 16
      total mass 16.26 kg, gripper 1.94 kg
      gripper sweeps  x 0.966  y 0.718  z 0.575
      ★ CENTRE OF MASS MOVES  x 0.1441  y 0.1075  z 0.0810

★★★ **THE CoM SWINGS 0.144 m FORE-AFT AGAINST A 0.36 m FOOT BASE** — forty percent of the
support polygon, moving fast. That is exactly the load transfer that turns "hold the feet still"
from a kinematics problem into a force problem.

## ★ THE SPLICE IS ANCHORED ON TEXT, NOT ON LINE NUMBERS

It finds `<body name="FR_hip"` and `  <actuator>` and cuts there, so it survives the fixture
being reformatted. A line offset would break silently the first time anyone touched the file, and
the failure would look like a broken robot rather than a broken splice.

## ★★ THE TWO CONTROLLERS ARE DELIBERATELY IGNORANT OF EACH OTHER

The arm reaches for a circle **in the trunk's own frame**, so as the torso rolls the world-space
target moves with it and the arm chases a point that is itself being thrown around. The torso
pipeline is untouched. **Neither controller knows the other exists**, so the arm's mass arrives
at the legs as a disturbance nobody planned for — which is precisely the situation a
force-allocating planner could handle and two independent servos cannot.

★ AND THE ARM'S IK WRITES ONLY THE ARM'S JOINTS into `home`, masked by `limbActuation` from the
gripper. The legs stay under the torso controller. Mixing them would have made the experiment
meaningless in a way that is easy to do by accident and hard to notice.

## Next: the number

Turn the routine and the arm on together and read the slip and cone figures already on the panel.
The baseline to beat, without the arm, is **0.945 m of slip and 2217 cone violations**.

## 🐛 "I CAN'T SEE THE ARM" — AND IT WAS THE HUMANOID'S BUG, AGAIN

The arm WAS in the model — verified: `arm_base`, `arm_upper`, `gripper` all present with their
geoms, at sensible world positions. The problem was downstream.

★★★ **THE `home` KEYFRAME CARRIES 19 NUMBERS AND THE MODEL NOW HAS nq 23.** `applyKeyframe`
refuses a keyframe of the wrong length — correctly, because a keyframe of the wrong length is not
a pose. **Both call sites discarded the result with `_ =`**, so the refusal was silent and the
robot never got its standing pose.

★★ THIS IS WORD FOR WORD THE BUG `examples/humanoid` DOCUMENTS:

> *"the keyframe was 28 numbers, the model 70 once the projectiles joined the tree, and
> `applyKeyframe` refused. The label still said holding: squat, which is worse than no feedback
> at all."*

Written down there, and repeated here — because the splice changed `nq` and **nothing connected
those two facts**. A note in one example does not protect another.

★ FIXED BOTH WAYS: the splice now pads the keyframe with four zeros for the arm joints, and both
call sites CHECK the result and log the lengths if it ever refuses again. **A silent refusal is
worse than a crash** — a crash names its cause.

## ★ THE GENERAL RULE THIS EARNS

**Anything that changes `nq` or `nv` invalidates every fixed-length array keyed to them** —
keyframes, saved poses, references, cost weights. The splice is a model transform, so it owns
every consequence of the transform, not just the bodies it inserted.

## 🐛🐛 "FALLS IMMEDIATELY" — AND IT WAS NEVER THE MASS

★★★ **THE SPLICE POSITION REORDERED EVERY JOINT INDEX.** Inserted before `<body name="FR_hip">`,
the arm's four joints come FIRST in qpos order, so every leg index shifts by four. Leg angles
then land in arm joints, the legs stay at `qpos0` — straight — and the robot topples the instant
it is reset.

★★ AND IT LOOKED EXACTLY LIKE A MASS PROBLEM. Simon's diagnosis was the obvious one, I agreed
with it, and I ran two sweeps chasing it:

    rest pose sweep    six folded configurations   ALL FELL
    mass sweep         2.06 kg down to 0.25 kg     ALL FELL

**A quarter-kilogram arm falling is not a mass problem**, and that is the observation that broke
it open — a 0.25 kg addition to a 12 kg robot cannot topple anything. **The sweep that refuses to
move is the one that tells you what you are testing is not the cause.**

Moved to the end of the trunk body: **every mass from 0.25 kg to 2.06 kg now stands**, trunk
height 0.331 in all five cases.

## ★ WHY AFTER THE LEGS IS THE RIGHT PLACE, NOT JUST A WORKING ONE

As the last child of the trunk, the arm's joints come after every leg's, so **all pre-existing
indices are preserved** — the keyframe, the actuator ordering, and every piece of code that
assumes where a leg lives. The keyframe padding appended four zeros at the END, which was wrong
before and is now correct for the same reason.

★★ THE GENERAL RULE: **a model transform that inserts joints must insert them where they change
no existing index**, or it must fix up everything keyed to those indices. Appending is nearly
always available and nearly always right; inserting in the middle is a rename of every number
downstream.

# ═══ ✅ THE GIMBAL: A ROUTINE THAT LOOKS GOOD, STANDS, AND HAS A GAP WORTH CLOSING ═══

Simon's design: **the gripper holds a fixed point in the world while the torso weaves, rocks and
bobs beneath it.** Three incommensurate rates — cone 0.55, roll 0.31, bob 0.19 — so the pose
never repeats and the arm cannot be tracking a memorised cycle. Arm half bent, because an arm at
a joint limit cannot counter-animate in both directions.

    cone  roll   bob   trunk z   gripper drift mean / worst   verdict
    0.22  0.20  0.035   0.3519          0.0290 / 0.0498      STANDS
    0.16  0.14  0.025   0.3493          0.0202 / 0.0329      STANDS   ← the demo's default
    0.10  0.09  0.015   0.3450          0.0125 / 0.0203      STANDS

★★ **IT STANDS AT EVERY AMPLITUDE TESTED**, and the gripper holds its point to 20 mm at the
shipped setting. The robot visibly weaves and the gripper visibly does not — which is the effect
Simon asked for, and it is legible without reading a number.

## ★★★ AND THIS IS THE BEST-SHAPED MPC CASE THE PROJECT HAS PRODUCED

The 20–29 mm of drift is not noise; it is **lag**. The arm is IK'd to the fixed point from
wherever the base has already moved to, then a PD chases those angles — so every correction
starts after the disturbance has happened.

★ **AND THE DISTURBANCE IS KNOWN IN ADVANCE.** The torso routine is a closed-form function of
time, so where the base will be 0.2 s from now is exactly computable. That makes the arm's
required joint trajectory computable too — which is **preview**, the one advantage that survived
every ablation in this project and the one that beat a tuned servo by 1.63x on the arm.

**Bar: gripper drift under 5 mm at the 0.16/0.14/0.025 setting**, against the IK+PD baseline's
20 mm. Same robot, same routine, same torque limits, and the servo tuned at its best.

★★ THE PIECES ALREADY EXIST: the pose-table trick from `examples/tracking` (the routine is
periodic in each of three frequencies, so the counter-pose is a function of phase), `Cost.task`
for the gripper residual, and the measured knowledge that a 0.3 s horizon at a coarse timestep
is affordable. **This is the demo to build next.**

# ═══ THE GIMBAL WITH A PLANNER: IT FALLS OVER ═══

    controller     mean drift   worst    trunk z   verdict
    PD kp    60         0.3029   0.4747     0.3499   stands
    PD kp   100         0.1529   0.2516     0.3437   stands
    PD kp   200         0.1173   0.1969     0.3248   stands   ← the servo's optimum
    PD kp   400         2.6130   4.9282     0.3186   stands   (trend reversed)
    MPC preview         1.7722   2.3801     0.1425   **FELL**

**The planner does not merely lose — it puts the robot on the floor**, where every servo setting
including the badly-tuned ones stays up.

## ★★★ WHY THIS IS DIFFERENT FROM THE ARM, AND IT IS NOT A TUNING GAP

`examples/tracking` works because a fixed-base arm has **no contacts**. Here the planner drives
all sixteen actuators, four legs included, and `transition` finite-differences the dynamics
through a contact solver.

★ **CONTACT IS NOT DIFFERENTIABLE IN THE WAY A FINITE DIFFERENCE ASSUMES.** Nudge a joint and a
foot may gain or lose a constraint row; the quotient across that boundary is not a derivative of
anything. The quadruped's own MPC example already says this — `examples/mpc_quadruped` ships
with "NOTHING HOLDS YET, INCLUDING THE STAND" in its header — and this is the same wall from a
different direction.

★★ SO THE HONEST CONCLUSION: **the gimbal is a beautiful demo and a bad MPC case.** The drift is
real lag and preview would in principle fix it, but the vehicle for preview here would have to
plan through contact, and that does not work today.

## ★ AND A TIMESTEP LESSON WORTH KEEPING

At 1/125 — borrowed from the tracking demo, where a coarser step was measured to be both cheaper
AND more accurate — **every controller fell**, including servo settings that stand comfortably at
1/250. That result was measured on a FIXED-BASE ARM WITH NO CONTACTS.

**A timestep that is fine for one robot is not a general setting.** Contact stiffness sets the
rate the legs need, and nothing about the arm's result transfers to a robot that touches things.

## What to do instead

  1. **Ship the gimbal as it is.** It stands, it looks like a gimbal, and the drift readout is
     honest about what a servo achieves.
  2. **If the planner is wanted here, plan the TRUNK only** — `solveTrunk` works on the SRBD with
     an explicit friction pyramid rather than finite-differencing through contact, which is
     precisely the tool for this and the one `mpc_quadruped` was built around.
  3. **Do not point `optimize` at a legged robot again** without first fixing what
     `mpc_quadruped`'s header already documents.

# ═══ ★★★ WHERE THE DRIFT ACTUALLY COMES FROM — AND SIMON'S PROPOSAL IS THE FIX ═══

    controller     mean drift   worst    trunk z   verdict
    PD kp   200        0.1173   0.1969     0.3248   stands   ← servo optimum
    MPC preview        1.7722   2.3801     0.1425   FELL
    PD + feedforward   0.1253   0.2055     0.3248   stands   ← no better

**Feedforward gives nothing**, and that null is the finding. Inverse dynamics along the known
trajectory is exactly the information a planner would use, obtained without differentiating
contact — and it does not help.

## ★★★ SO THE DRIFT IS NOT THE ARM'S TRACKING LAG

The table's arm reference is computed against the **COMMANDED** torso pose. The torso never
reaches that pose — it droops and lags, which is the 0.0117 rad of attitude error already
measured. So the arm tracks its reference perfectly and still misses, because **the reference was
computed for a robot in a place this robot never was.**

★ AND THAT EXPLAINS THE EARLIER NUMBER. The live demo, which re-solves the arm's IK against the
torso's ACTUAL pose every tick, holds the gripper to **20 mm**. The table version, computing
against the commanded pose, drifts **117 mm** — nearly six times worse with a better controller.
**The reference's anchor mattered more than everything downstream of it.**

## ★★ WHICH IS PRECISELY WHAT SIMON PROPOSED

> "make a desired pose using ik, with feet where they are in the world NOW, with the torso where
> we want it relative to the AVERAGE OF CURRENT FEET... and the gripper arm counter-animated to
> be where we want"

**Anchoring the reference to the robot's actual state is the whole fix**, and it is the half of
the proposal that the measurements support. Every element earns its place:

  * **feet where they are now** — kills the accumulating fight against stale planted spots
    (measured: 17.4 m of slip when the targets are stale);
  * **torso relative to the average of current feet** — makes the commanded pose reachable from
    where the robot is, rather than from where it started;
  * **gripper counter-animated against the ACTUAL torso** — which is the 20 mm versus 117 mm
    above.

## 🚧 AND THE OTHER HALF — "then run MPC to follow it" — IS THE PART THAT DOES NOT WORK

Not because the idea is wrong, but because `optimize` finite-differences through the contact
solver and puts this robot on the floor. **A better reference does not make contact
differentiable.** Measured twice now, and `examples/mpc_quadruped` says the same in its header.

★ THE HONEST ARCHITECTURE FOR THIS ROBOT, THEN:

  1. build the reference exactly as Simon describes — anchored to current feet, current torso,
     with the arm countering the REAL base;
  2. track it with the servo, which is already at its best and already stands;
  3. and if a planner is wanted, use `solveTrunk` on the SRBD with its explicit friction pyramid
     — the tool built for legged contact — not the whole-body finite-difference one.

**The reference is where the wins are on this robot. The planner is where they were on the arm.**

# ═══ ✅ THE DEMO, FINISHED AND VERIFIED ═══

`examples/quadruped` now opens **already doing the thing**: a Go1 with a spliced three-bone arm,
torso weaving through three incommensurate frequencies, gripper holding a fixed point in the
world.

  * **routine and gimbal ON by default** — a demo that idles until clicked gets seen once, and
    its smoke test verifies an idle scene, which is how three bugs hid in `examples/catch`;
  * **the held point is drawn** as a crosshair with a line to the gripper — "it is not moving" is
    only legible against something that visibly is not moving either, and the line's SHORTNESS
    is the result;
  * **slip, friction-cone and drift readouts**, all live.

## ★ VERIFIED AT THE SHIPPED SETTINGS, FOR LONGER THAN A GLANCE

    12 s:  drift 0.0202 mean / 0.0329 worst   trunk 0.3493   STANDS
    30 s:  drift 0.0611 mean / 0.2145 worst   trunk 0.3115   STANDS

**It stays up**, which was the risk worth checking — a demo that opens mid-collapse is worse than
one that idles. But the drift grows, and the panel now says so when it does: the feet slide, so
the robot slowly walks away from a point that is fixed in the WORLD. **The same foot slip the
cone readout reports, arriving as a second symptom.**

★ A ROUTINE THAT SURVIVES 12 s AND FAILS AT 25 IS WORSE THAN ONE THAT NEVER STARTED, so the
long run was the gate that mattered. It passed, and the honest caveat is on screen rather than
in a note nobody reads.

## What this demo now demonstrates, accurately

  1. a quadruped holding a commanded attitude to **under 3%** (it was 16-32% out before the
     attitude loop was added);
  2. an arm counter-animating a moving base well enough to hold a world point to **20 mm**;
  3. and, in the same panel, **the friction cone being violated 1.8x** — the honest limit of
     doing all this with position control, and the gap a force-allocating planner exists to
     close.

**Three of those numbers were not visible at all when this session started**, and the first was
wrong.

# ═══ ★★★ TWO BUGS SIMON SPOTTED FROM WATCHING IT ═══

## 1. The arm's counter-animation was being overwritten

The arm's IK ran at line 1075; `solveBodyPose` ran at line **1181**. That function copies EVERY
hinge joint from `stance` — arm included — so the counter-animation was computed correctly and
then thrown away the instant the torso re-solved.

★★ **"I don't see any counter animating" was exactly right, and the arm was solving perfectly.**
The answer was being discarded by a later write to the same array.

★ **ORDER IS PART OF A CONTROLLER'S DEFINITION.** Two solves writing one array is a SEQUENCING
bug, not a control one — and no amount of tuning either solve would have revealed it. The arm
block now runs after the torso's.

## 2. The held point was pinned in the world, not to the feet

Pinned absolutely, it is a target the robot slowly walks away from — measured, the gripper's mean
error grew from 20 mm to 61 mm over 30 s while chasing a point that had not moved and a robot
that had.

★ **THE FEET ARE WHERE THE ROBOT ACTUALLY IS.** Anchored to their average, the point travels with
whatever drift the legs accumulate, so the arm counters the TORSO's motion — the thing it exists
for — rather than also fighting the base's slow walk. Same principle as anchoring the torso
reference to current feet instead of a stored stance, which is the half of Simon's earlier
proposal the measurements already supported.

`hold_offset` is now a forward distance from the foot mean, on a slider, and the height is
measured up from the same place.

## ✅ RE-MEASURED — BOTH FIXES VERIFIED OVER 30 s

    hold point      drift mean/worst    torso sweep    arm joint sweeps (rad)
    world-pinned    0.0611 / 0.2145        0.336    0.797 0.820 1.653 0.746
    foot-relative   0.0173 / 0.0284        0.336    1.628 0.550 0.211 0.057

★★★ **FOOT-RELATIVE IS 3.5x BETTER ON THE MEAN AND 7.5x ON THE WORST**, and the slow growth is
gone: 17 mm over 30 s against the old arrangement's 20 mm over 12. The point now travels with the
robot's drift, so the arm counters the TORSO rather than also fighting the base's walk.

★★ **AND THE ARM IS UNMISTAKABLY COUNTERING.** The torso's pitch sweeps 0.336 rad while the arm's
base joint sweeps **1.628 rad — 93 degrees** — to hold the gripper inside 17 mm. Large arm
motion, tiny gripper drift: that is the demonstration, and the joint excursion is what makes it a
demonstration rather than an assertion. A gripper holding still because nothing moved would show
small sweeps.

★ NOTE THE WORLD-PINNED ROW'S ELBOW SWEEP (1.653) IS LARGER, not smaller: it is spending motion
chasing the accumulated drift instead of the torso. **More effort for a worse result** is the
signature of a controller fighting the wrong thing.

## (previously) NOT YET RE-MEASURED

The 30 s drift figure above was taken BEFORE both fixes. The instrumentation to prove the arm is
genuinely countering — its joint EXCURSION, since a gripper that holds still because the torso
barely moved proves nothing — was written and its edit failed against a stale binary.

★ **THE NEXT MEASUREMENT IS THE ARM'S JOINT SWEEP.** Large sweeps with a small gripper drift is
the demonstration; small sweeps would mean the arm is coasting and something else is holding the
gripper still. Recorded as untested rather than assumed.

# ═══ ★★★ "CAN MPC IMPROVE THIS?" — MEASURED ANSWER: NO ═══

    preview lead    drift mean/worst    arm joint sweeps (rad)
    lead  0.00 s     0.0173 / 0.0284    1.628 0.550 0.211 0.057
    lead  0.02 s     0.0741 / 0.1187    2.496 0.732 0.330 0.092
    lead  0.05 s     0.0755 / 0.1218    2.537 0.740 0.336 0.094
    lead  0.10 s     0.0788 / 0.1251    2.601 0.752 0.344 0.098
    lead  0.18 s     0.0865 / 0.1291    2.688 0.762 0.357 0.101

**Preview makes it four times worse**, and the arm sweeps GROW from 1.63 to 2.69 rad doing it —
more effort for a worse result, the same signature as chasing a stale target.

★★★ **SO THE 17 mm IS NOT LAG.** That matters, because preview is MPC's one advantage that
survived every ablation in this project — it beat a tuned servo by 1.63x on a fixed-base arm.
Here the information is available for the price of one sine per axis, and using it hurts.

★★ THE THREE THINGS MPC COULD BRING, ALL NOW MEASURED ON THIS PROBLEM:

  1. **preview** — tested directly above: **counterproductive**;
  2. **feedforward along a known trajectory** — tested earlier: **0.1253 against the servo's
     0.1173, no help**;
  3. **whole-body optimisation** — tested earlier: **put the robot on the floor**, because
     `transition` finite-differences through a contact solver.

**Three for three.** This is not "we did not tune it enough" — it is three distinct mechanisms,
each measured, each failing for its own reason.

## ★ WHAT THE REMAINING 17 mm ACTUALLY IS

Not lag, or a lead would fix it. Not the reference, or anchoring to the feet would not already
have taken it from 61 mm to 17. What is left is the servo holding joint angles against the arm's
own weight — a steady-state deflection, the same `kp·e = load` that put 2.3 degrees into the
torso before the attitude trim was added.

★ **AND THE FIX FOR THAT IS THE SAME AS IT WAS THERE: CLOSE A LOOP, DO NOT PLAN.** Gravity
compensation on the arm — `inverseDynamics` at zero acceleration — would cancel most of it for
about six lines. That is the next thing worth trying, and it is not MPC.

## The honest summary for this robot

**Yes, this is essentially the best solution**, and the demo is at the limit of what its
architecture gives. Every remaining improvement measured so far is a loop or a reference, not a
planner — and the one place a planner genuinely won in this project is `examples/tracking`, on a
fixed-base arm with no contact and a target whose future is known and whose present is lagged.

**That combination is the signature to look for. This problem has none of it.**

# ═══ ★★★ THE STATIC SLIDE IS SOLVER CREEP, NOT FRICTION ═══

A Go1 holding its home pose, nothing commanded to move, 20 seconds:

    total foot slide      1.0168 m   (50.84 mm/s)
    trunk moved           0.2542 m
    friction demand       mean 0.192   worst 0.200   of the cone
    peak tangential force 4.26 N

★★★ **THE FEET CREEP WHILE EIGHTY PERCENT OF THE GRIP GOES UNUSED.** Peak tangential demand is
4.26 N against a limit several times that. **This is not Coulomb slip, and raising the friction
coefficient would raise a limit that is never reached** — it would change nothing.

## What it actually is

The contacts permit tangential drift under sustained load well inside the cone. A stationary
robot has nothing pushing it sideways — 4.26 N on a 12 kg machine is noise — yet it travels a
quarter of a metre in twenty seconds. That is the constraint solver not holding a resting contact
in place: no persistent anchor, so each step re-solves from scratch and a little creep survives
every time.

★★ AND IT EXPLAINS THE DYNAMIC CASE TOO, PARTLY. The routine measured 1.83x the cone — there
friction genuinely IS binding — but the 17.4 m of slip recorded with stale foot targets was creep
and cone violation compounding, and only the second half was ever a friction problem.

## ★ WHAT WOULD ACTUALLY FIX IT

  1. **Persistent contact anchors.** A resting contact should remember where it started and
     resist motion from THERE, not merely oppose the current velocity. This is what stops a
     stack of boxes drifting in every physics engine that does not have it.
  2. **Warm-started contact impulses** across steps, so a foot that was holding continues to
     hold rather than re-deriving its grip each tick.

**Both are engine work in `zimrphysics`, not controller work.** No amount of control can fix a
contact that does not hold — the controller is already asking for less than a fifth of what the
ground can give.

★★★ THE DIAGNOSTIC THAT SETTLED IT IS WORTH KEEPING: **measure the demand as a FRACTION OF THE
LIMIT, not in newtons.** "4.26 N of tangential force" says nothing; "20% of the friction cone,
and still sliding" says the friction cone is not the mechanism and points at the solver.

## ✅ AND THE ENGINE FIX IS FEASIBLE — `contact_persistence_plan.md`

`feature_id` is documented as "stable id for warm-start matching across frames" and is populated
by every manifold builder. `ContactPoint.local_a/local_b` are documented as "position-solve
anchor". **Both mechanisms are designed in.** What is missing is that contacts live in a per-step
arena that is reset, so the ids and anchors are computed correctly and discarded before anything
can match against them.

The work is a persistent cache keyed by `(a, b, sub, feature_id)`, seeding `total_lambda` and —
the part that actually stops creep — keeping the anchor from the first step a contact appeared.

# ═══ ✅ `examples/friction_slope` — THE ENGINE AGAINST A TEXTBOOK PREDICTION ═══

Simon's question: *does `robot.zig` ever really have correct tangential friction?*

**A slope answers it with arithmetic rather than opinion.** A resting body holds while
**tan(θ) < μ** and slides beyond. The demo puts a Go1 on a tiltable slope with sliders for angle
and friction, and prints the predicted threshold `atan(μ)` next to the measurement.

## ★★★ AND IT SEPARATES THE TWO FAULTS, WHICH NOTHING ELSE HAS

  * **the Coulomb LIMIT is wrong** → it would slip at angles well BELOW `atan(μ)`;
  * **the limit is right and the SOLVER creeps** → it holds to the predicted angle but drifts
    slowly at every angle under it.

The panel reports **cone occupancy** alongside the slide, and says so outright when they
disagree: *"sliding below the threshold, cone not full — the limit is fine, the solver is
creeping."* That is the diagnosis the static measurement already pointed at (0.20 of the cone
while sliding 1 m in 20 s), now testable across the whole range instead of at one configuration.

★ THE SLOPE IS THE GROUND ROTATED, NOT GRAVITY TILTED. Tilting gravity gives the same free-body
diagram and a much EASIER contact problem — the normal stays aligned with the box face. Rotating
the ground exercises the oblique contact normals a real slope produces, which is the case under
suspicion.

## Notes for whoever runs it

Raise the angle past the predicted threshold: it should let go there and hold below it. Anything
else is the engine rather than the robot — and the friction slider moves the prediction with it,
so the two can be checked against each other rather than against a memory of what looked right.

## 🐛 THE SLOPE DREW ON THE WRONG AXIS — AND THE READING IS STILL GOOD

The ground was tilted about **Y in the solver's Z-up frame** and drawn with `rotationX` in the
render's **Y-up** frame. Deriving it instead of guessing:

    solver (Z-up), about Y:   x' =  x·cosθ + z·sinθ
                              z' = -x·sinθ + z·cosθ

    swizzle (x,y,z)_zup -> (x,z,y)_yup:

                              x_r' =  x_r·cosθ + y_r·sinθ
                              y_r' = -x_r·sinθ + y_r·cosθ

★★★ **A ROTATION IN THE RENDER x–y PLANE — ABOUT Z, NOT X.** The robot's base quaternion is set
in solver space and was banking correctly all along; **the floor was wrong**, which reads exactly
like the robot leaning the wrong way. Sign follows the same substitution: `rotationZ(-θ)`.

★ A FRAME CONVERSION IS TWO LINES OF ALGEBRA. Guessing it cost a turn, and the symptom pointed at
the robot rather than at the thing that was actually wrong.

## ★★ AND THE MEASUREMENT WAS NEVER AFFECTED — WHICH THE SCREENSHOT ALREADY SHOWED

    slope 17.6 deg, mu 1.50 -> Coulomb says holds below 56.3 deg
    after 18 s: slid 0.1064 m, peak cone occupancy 0.74
    "SLIDING BELOW THE THRESHOLD, cone not full — the limit is fine, the solver is creeping"

**Sliding 106 mm at less than a third of the holding angle**, with a quarter of the grip still
spare. The drawing bug was in the drawing; the diagnosis stands, and it is the same one the
static test produced by a completely different route.

★ THAT AGREEMENT MATTERS: a static robot on flat ground creeping at 0.20 of its cone, and a
robot on a 17-degree slope creeping at 0.74 of its cone while Coulomb says it should hold to 56
degrees. **Two independent setups, one conclusion** — the friction LIMIT is not the problem, the
contact solver's tangential behaviour is.

## ✅ THE PRECISE PLAN IS WRITTEN — `tangential_anchor_plan.md`

The mechanism is now pinned to specific lines rather than described:

  * **why it creeps**: `lambda = effective_mass * (jv - bias)` with `bias = 0` makes static
    friction a pure VELOCITY constraint. It removes the velocity it sees each step; the residual
    integrates; nothing pulls the contact back. **The normal direction has a position solve
    (18375) and the two tangents do not** — the machinery exists and is applied to one of three
    directions.
  * **where the fix goes**: `prepare(..., tangent1, dot3(tangent1, surf))` at 16622 already takes
    a target velocity. A drift-correction term goes there.
  * **what stores the anchor**: `CachedFriction` at 8376, keyed by `ManifoldKey`, already
    surviving a step and already purged when a body dies.

★★★ AND THE SUBTLETY THAT MAKES OR BREAKS IT: **the anchor must reset when the friction impulse
saturates the cone.** A genuinely sliding box would otherwise drag an anchor that grows without
limit, and its sliding friction would be wrong. The cone clamp that detects this is already
computed in the solve loop — the flag falls out of it.

★★ THE FIRST THING TO WRITE IS NOT THE FIX. It is a twenty-line test: **one box, flat ground,
20 seconds, nothing should move.** It isolates the sign and the mechanism from every other
variable, and if the bias sign is backwards — which doubles the creep and looks like the fix
making things worse — that is where it is obvious.

## ✅ THE QUADRUPED IS IN THE FLAGSHIP LAUNCHER

Added to BOTH lists that have to agree — `build.zig:2079` (which wires the `ex_quadruped` module)
and `examples/launcher/launcher.zig:61` (which imports it). **Adding to one and not the other
fails at compile time**, which is the right kind of coupling.

    launcher: 106/106 imports, 13.7 MB standalone, smoke PASS at ~137 calls/frame

★ IT IS THE FIRST ARTICULATED ROBOT IN THE LAUNCHER — the rest are fractals, 2D games, post-fx
and a first-person physics playground. It brings a Go1 with a procedurally spliced arm, the
three-frequency gimbal, and four live measurements: attitude error, gripper drift, foot slip and
friction-cone occupancy.

★★ AND THE LAUNCHER'S SMOKE TEST DOES NOT EXERCISE IT. Children are registered with
`addDeferred` — lazy, initialised on the frame they are first shown — so the smoke run boots the
launcher and never touches the quadruped. **The pass is real for the launcher and says nothing
about the child**, which is exactly the trap `examples/catch` fell into. The quadruped's own
smoke target is what covers it, and that one still hits the pre-existing `addContactRows` trap in
debug.

# ═══ ★★★ THE GAIT WALKED BACKWARD BECAUSE THE STANCE DIRECTION WAS INVERTED ═══

`footOffsetInCycle` returned `stride * (t - 0.5)` during stance — `t` runs 0 to 1, so the planted
foot travelled **+x relative to the body**, pushing the body backward.

★★ AND THE COMMENT THREE LINES ABOVE SAID THE OPPOSITE: *"the foot travels BACKWARD relative to
the body, which is what carries the body forward. Measured with this reversed, the robot walked
backwards — correct physics, inverted intent."* **The comment stated the intent correctly and the
code did the reverse** — the third comment/code disagreement in this project, and the third time
the comment was the accurate one.

    stance dir   hz    stride   duty    travelled x (10 s)
    as written   2.4    0.20    0.55       **-5.25 m**
    as written   2.0    0.16    0.60         -3.85 m
    corrected    2.0    0.16    0.60       **+1.43 m**
    corrected    1.4    0.16    0.65         +1.04 m
    corrected    2.4    0.20    0.55         +0.17 m

## ★ THE CREEP FIX IS WHAT MADE THIS VISIBLE

The old note recorded *"drifts about half a metre backwards whichever way the stance direction is
set"* — ambiguous, and consistent with feet slipping rather than with a sign error. **With the
stiffened contacts the same code walks 5.25 m backward.** Once the feet gripped, a weak
directionless drift became unmistakable propulsion the wrong way.

★★ SO THE EARLIER CONCLUSION — "structural, the torso command fights the motion" — WAS WRONG, and
it was wrong because it was drawn from measurements taken on contacts that could not push. **A
diagnosis is only as good as the mechanism underneath it**, and fixing the mechanism invalidated
the diagnosis rather than confirming it.

## The parameters, swept rather than chosen

`stride` mattered more than `hz`: **0.06 m was the old default**, small enough that the feet
barely displace the body regardless of direction — which is the other half of why it read as
"very slow". And `duty 0.85` left so little swing that each cycle reset almost nothing.

Now **hz 2.0, stride 0.16, duty 0.60, lift 0.05** — the best row measured, +1.43 m in ten seconds.

## 🐛 THE PROBE MEASURED A DIFFERENT ROBOT THAN THE ONE THAT SHIPPED

Simon: *"in my version it immediately tips backwards now. You see a different result in your
probe. Why?"*

★★★ **THE PROBE USED A BARE GO1. THE DEMO CARRIES A 1.94 kg ARM HIGH ON THE TRUNK.** Those
distances describe a different machine, and a top-heavy robot is exactly the case a stride
increase destabilises.

★★ AND I CHANGED THREE PARAMETERS AT ONCE FROM THAT MEASUREMENT: stride 0.06 -> 0.16 (**2.7x**),
hz 1.6 -> 2.0, duty 0.85 -> 0.60. Each part is a mistake on its own:

  * **a sweep on the wrong model** — the probe could not have seen the tipping;
  * **no isolation between the sign fix and the tuning** — the sign fix is certainly right
    (backward 5.25 m versus forward 1.43 m is not ambiguous), the tuning was never tested on
    this robot, and they shipped together so the failure implicates both.

★ THE TELL WAS AVAILABLE BEFORE SHIPPING: the probe builds its own model from `go1_xml` and the
demo splices an arm into it. **When a probe constructs its own scene, the first question is
whether that scene is the one under test.**

## Backed off, keeping only what was actually established

    stride 0.08 (was 0.06, swept 0.16)   hz 1.6 (unchanged)   duty 0.75 (was 0.85, swept 0.60)

**The corrected stance direction stays** — it is the part with unambiguous evidence. The tuning
moves only slightly from the original, in the direction the sweep suggested, at a magnitude this
robot has not been shown to fall over at.

★★ THE SLIDERS ARE LIVE, AND THAT IS NOW THE RIGHT TOOL: sweep them **on this robot**, with the
arm, rather than trusting numbers from a machine that does not exist.

## ➡️ NEXT: THE ARM AS A BALANCE ACTUATOR — `arm_balance_plan.md`

Measured authority: **the arm out-torques the fall by 4x to 20x** (60 N.m of reaction against
2.9-14.5 N.m of tipping). Two mechanisms — CoM shifting (persistent, 40% of the support polygon)
and angular momentum (**0.168 s** of large torque before the arm hits its stop).

★ AND MOMENTUM IS THE RIGHT ONE HERE because it needs **no contact force**: during the routine
the friction cone runs at 1.83x, so the legs have nothing left to push with, and that is exactly
when the arm still works.
