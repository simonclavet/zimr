# ★★★ RETARGETING A MOCAP TAKE ONTO A ROBOT — where we are, and where to go

## 1. What actually works, and is tested

    robot.computeTwistOffset / applyTwist    ported from FlomoGMR; unit-tested against its
                                             own defining property, incl. the `inv(parent)` term
    robot.computeTwistChainOffsets           shared builder, one implementation
    robot.poseFromRetarget                   shared per-frame loop, one implementation
    robot.jacBody                            finite-difference verified, mutation-tested
    robot.ikStep                             damped least squares, position + orientation rows
    robot.fitBodyRotation                    preserves a requested direction on a 2-DOF body (1.000)
    solveRobotTPose                          builds a robot rest pose FROM the capture's

    SCORECARD test                           staged, in metres and degrees, on the shared code
    INVARIANT test                           localises the first bad body in a chain
    T-pose compare view                      both rest poses, geoms, frames, offset slider
    overlay view                             robot geoms on the character

★★ **The measurement infrastructure is now better than the algorithm.** That is the right way
round, and it was not true for most of this arc.

## 2. ★★★ THE HONEST PROBLEM: TWO MECHANISMS DOING ONE JOB

The pipeline currently contains **two different ways of deciding where a bone points**, and they
overlap:

    A. TWIST OFFSETS   convert a ROTATION from the source's frame to the robot's, via a
                       per-bone `R_twist` derived from two rest poses, applied as
                       `inv(parent_twist) * q_local * own_twist`

    B. AIMING          compare DIRECTIONS in world space and rotate the bone onto the target;
                       needs no rest pose, no reference frames, no conversion at all

★★★ **B NEEDS NO REST-POSE ALGEBRA BECAUSE A DIRECTION CARRIES ITS OWN FRAME.** Every rest-pose
bug this arc hit — A-pose for T-pose (x2), the unrotated accumulation, the vertical reference
bone, the missing source rest rotation, `qpos0` not being a T-pose — was a bug in mechanism A.
**Mechanism B is structurally immune to all of them.**

★ A's remaining advantage: it carries TWIST, which a direction cannot. B needs a separate rule
for rotation about the bone.

## 3. The recipe worth aiming for — three steps, each one sentence

    1. REST POSE   solve the robot into the capture's T-pose, using the capture's DIRECTIONS
                   and the robot's OWN bone lengths            [done: solveRobotTPose]

    2. PER FRAME   for each body, parents first:
                     - aim its bone where the capture's corresponding bone points
                     - choose the rotation ABOUT that bone from the child's bend plane
                     - a 1-DOF hinge takes the capture's flexion ANGLE instead

    3. REFINE      a few IK steps on weighted position targets at the ends   [optional]

★★ **That is understandable.** Nothing in it requires holding two coordinate conventions in your
head at once, and every step can be checked against the drawing: does the bone point the right
way, does the elbow bend in the right plane, does the foot land.

## 4. ★★ THE PLAN — decide by measurement, not by preference

**Step 1. Make mechanism B complete.**
`poseFromRetarget` already aims upper arms and bends hinges. Extend aiming to EVERY mapped body
with a child, and use `aimBoneWithTwist` wherever the child is a hinge. **No new concepts** —
both functions exist and are tested.

**Step 2. Measure A against B on the scorecard, with everything else identical.**
One flag, two runs. The stages are already staged by dependency, so a difference shows WHERE.

**Step 2-3. ★★★ MEASURED — AND A WINS. THE TWIST OFFSETS STAY.**

                        A: twist   B: aim
      torso ORIENT        35.4      24.8   B
      arm POSITION       0.086     0.141   A
      arm DIRECTION       40.7      46.3   A
      arm TWIST           34.6      42.6   A
      elbow BEND          26.8      23.0   B
      thigh DIRECTION     12.5      28.7   A, by more than double
      knee BEND            6.6      12.3   A
      -----------------------------------------
      sum of angles      156.6     177.7

★★★ **I WROTE THE PLAN EXPECTING TO DELETE A**, on an argument that was genuinely strong: every
rest-pose bug in this arc was A's, six distinct classes of them, and B is structurally immune.
**The measurement says A does real work anyway** — it wins five stages of seven and the total, and
the legs by more than double.

★★ **"THE SIMPLER MECHANISM WINS TIES" ONLY APPLIES TO TIES.** This is not one. Deleting A would
have cost 21 degrees of accumulated error to remove code whose bugs are now FIXED — trading a
present, measured capability for the absence of past problems.

★ B is better on the TORSO (24.8 vs 35.4) and the ELBOW BEND, which is worth keeping in mind: the
two mechanisms fail differently, and a per-body choice may beat either. **That is a measurable
question, not a design opinion** — and it is the natural next experiment now that both are wired
behind one flag.

★ Both remain in `poseFromRetarget` behind `aim_all`, and the scorecard runs BOTH every time, so
the comparison cannot silently rot.

**Step 3 (superseded). Delete the loser.**
★★★ If B wins or ties, **delete the twist offsets entirely** — `computeTwistOffset`,
`computeTwistChainOffsets`, the chains, the rest rotations, `robot_rest_world`. That is roughly
200 lines and six of this arc's bug classes. **A tie is enough to delete: the simpler mechanism
wins ties, because the complexity has a demonstrated cost in bugs.**

★ If A wins, keep it and delete B's duplicate paths instead — but then say clearly WHY the extra
machinery earns its place, in numbers.

**Step 4. ★ DONE — the harness now builds the same rest pose.**
`robot.solveRestPoseFromSource` is shared; the example is a thin wrapper over it and the harness
calls it directly. It previously passed `null` and measured against `qpos0`, which is NOT a
T-pose, so its numbers described a reference the shipped code no longer used.

      stage                before   after
      torso ORIENT          47.2     39.8
      arm POSITION         0.105    0.082 m
      arm DIRECTION         42.1     41.0
      elbow BEND            35.5     32.8
      arm TWIST             34.5     35.9
      thigh DIRECTION       21.1     11.2   MUCH better
      knee BEND              6.3      6.3
      -------------------------------------
      sum of angles        186.7    167.0

★★ **SIX OF SEVEN IMPROVED, AND THAT WAS THE LAST KNOWN HARNESS/EXAMPLE DIVERGENCE.** All four
have now been closed: the twist builder, the pose loop, the solver task set, and the rest pose.

★★★ **VERIFICATION IS NOW SELF-CONTAINED.** `zig build check` runs the SCORECARD and the
INVARIANT tests against the same code the example ships — no screenshot needed to know whether a
change helped, and a regression names the stage and the body it happened in.

**Step 5. Then, and only then, tune.**
Position weights, IK step counts, damping. **Tuning before the mechanism is settled is what
produced the eleven candidate formulas.**

## 5. What NOT to do

★ **Do not add a third mechanism.** Every "limb correction", "facing yaw" and "delta+M" variant
in this arc was a third mechanism papering over a bug in the first two. Eleven of them.

★ **Do not tune weights to compensate for a wrong direction.** A weight that has to be wrong to
make a pose look right is hiding the real error, and the scorecard will not tell you which.

★ **Do not trust a number without checking which implementation produced it.** Four divergences
between harness and example, every one invisible until a screenshot disagreed.

---

## ★★★ 6. THE HYBRID IS WORSE THAN BOTH — the mechanisms are NOT composable per body

                        A: twist   B: aim   hybrid (aim torso)
      torso ORIENT        35.4      24.8      32.7
      arm POSITION       0.086     0.141     0.115 m
      arm DIRECTION       40.7      46.3      43.5
      elbow BEND          26.8      23.0      25.2
      arm TWIST           34.6      42.6      37.2
      thigh DIRECTION     12.5      28.7      42.3   worse than BOTH
      knee BEND            6.6      12.3      19.2   worse than BOTH
      ---------------------------------------------
      sum of angles      156.6     177.7     200.1

★★★ **THE OBVIOUS EXPERIMENT — "take the torso from whichever wins the torso" — MAKES EVERYTHING
WORSE**, and the legs by more than triple. The reason is structural and worth stating:

★★ **MECHANISM A COUPLES BODIES THROUGH `inv(parent_twist)`.** Every child undoes its parent's
twist before applying its own. **If the parent used mechanism B it never applied one**, so the
child undoes a rotation that was never there — and the error propagates down the whole chain.
The legs suffer most because the torso is the root of their chain.

★ **So the two mechanisms are not interchangeable PER BODY.** A per-chain choice might work,
since the coupling is within a chain — but that is a different experiment and the result above
says nothing about it.

### ★★ WHAT THIS TURN ESTABLISHED

Two plausible ideas measured, both wrong:

  1. "delete A, B is structurally cleaner"          -> A wins by 21 degrees
  2. "take each body from whichever mechanism wins" -> worse than either, by 43

**Both were reasonable. Neither survived one run of a test that takes seconds.** The harness has
now overturned my judgement twice in two turns, on questions I would previously have settled by
argument and shipped.

★ Current best remains **A: twist**, unchanged: torso 35.4, arm position 0.086 m, arm direction
40.7, elbow bend 26.8, thigh 12.5, knee 6.6.

★ The scorecard runs all three every time, so neither negative result can quietly become a
"maybe we should try..." again.

---

## ★★ 7. ARE THE TWISTS REDUNDANT NOW? NO — and the worst one localises the next bug

    TWIST MAGNITUDES: mean 25.8 deg, worst 91.1 at lower_arm_left

★ **The hypothesis was that solving the robot INTO the capture's T-pose would make every
`R_twist` identity**, since `R_twist` is the shortest arc between exactly the two rest bones the
solve had just aligned — which would mean mechanism A had quietly degenerated into "copy the
world rotation". **Refuted in one run:** mean 25.8 degrees is real work.

★★★ **BUT 91 DEGREES AT `lower_arm_left` SAYS THE T-POSE SOLVE FAILS THERE.** If the solve had
placed the forearm along the capture's, its twist would be small. **A large twist on a body the
solve was supposed to align is the solve's residual, showing up downstream** — and the elbow is
exactly where it would: a 1-DOF hinge bends in ONE plane, so it cannot straighten an arm whose
plane is wrong.

★ So the reference pose is good for the torso and legs and **bad for the forearms**, and every
arm number in the scorecard is measured against a reference that is 91 degrees off at the elbow.
That is the most specific open lead in the retarget.

### ★ THE HYPOTHESIS RATE THIS TURN AND LAST

    "delete A"                       wrong, measured
    "mix mechanisms per body"        wrong, measured
    "the solve made twists redundant" wrong, measured

★★ Three confident predictions, three refutations, **each costing one test run instead of a
device round.** None of them would have been caught by argument — I had a reason for each, and
the reasons were plausible. **That ratio is what the harness is for**, and it is worth more than
any single number it has produced.

---

## ★★ 8. THE FOREARM RESIDUAL IS THE **SHOULDER'S TWIST**, not the elbow's angle

Tried: set every 1-DOF hinge from the capture's flexion angle before solving, rather than
letting IK search for it. The reasoning was sound — an elbow's angle IS a scalar the capture
gives, and writing it is exact where searching is not.

★★★ **MEASURED: NO HELP.** Torso 35.4 -> 36.5, worst twist 91 -> 100. **Reverted.**

★★ **WHICH LOCALISES THE REAL CAUSE.** The forearm's residual is not the hinge being solved
badly. It is the **SHOULDER'S TWIST**: a position target on the elbow constrains where the upper
arm POINTS and says nothing about rotation ABOUT that arm — and that rotation swings the forearm
around the arm's axis. A 91-degree forearm twist on a straight arm is precisely what a free
shoulder twist produces.

★ So the T-pose solve needs the same treatment the per-frame loop already has: **choose the
shoulder's twist from the elbow's bend plane** (`aimBoneWithTwist`), instead of leaving IK to
pick whichever twist its damping happens to favour.

★ That is the next experiment, and it is a small one — the function exists, is tested, and is
already used per-frame.

### ★★ FOUR REFUTATIONS IN THREE TURNS

    "delete A"                          wrong    A wins by 21 deg
    "mix mechanisms per body"           wrong    worse than either, by 43
    "the solve made twists redundant"   wrong    mean 25.8 deg of real work
    "the elbow hinge is solved badly"   wrong    no help; it is the shoulder

★★★ **EVERY ONE HAD A PLAUSIBLE ARGUMENT BEHIND IT, AND EVERY ONE WAS WRONG.** Each cost one
test run. **The fourth refutation is the most useful of the four**, because eliminating the
elbow is what points at the shoulder — a negative result that names its successor.

---

## ★★★ 9. I MEASURED A CHANGE THAT WAS NEVER APPLIED

Attempted: a post-pass in `solveRestPoseFromSource` choosing the shoulder's twist from the
child's bend plane. The scorecard came back **identical to the decimal** — 25.8 / 91.1 / 35.4 /
0.086 — and I reported that as "no effect, fourth refutation".

★★★ **THE EDIT HAD SILENTLY FAILED TO APPLY.** Python's `str.replace` returns the string
unchanged when the anchor is not found and raises nothing. The numbers were identical because
**the code was identical** — there was no change to measure.

★★ **"IDENTICAL TO THE DECIMAL" IS NOT A RESULT, IT IS A SYMPTOM.** A real change to a
kinematic chain moves something. Bitwise-identical output across a supposed algorithm change
should have been read as "the change did not happen" — and instead I wrote a paragraph
explaining why the shoulder twist did not matter.

★ **The check costs one line**: after an anchored edit, grep for the text just inserted. Every
edit in this session that silently no-opped was invisible for exactly as long as nobody looked.

### ★★ WHAT THIS INVALIDATES

**Nothing else.** The four earlier refutations each moved the numbers, so each was a real
measurement of a real change:

    "delete A"                          A wins by 21 deg      numbers moved
    "mix mechanisms per body"           worse by 43           numbers moved
    "the solve made twists redundant"   mean 25.8 deg         a direct measurement
    "the elbow hinge is solved badly"   35.4 -> 36.5          numbers moved

★ Only the fifth was vapour. **The shoulder-twist hypothesis is UNTESTED, not refuted**, and
remains the best open lead: a position target on the elbow constrains where the upper arm points
and says nothing about rotation about it.

---

## ★★★ 10. THE SHOULDER-TWIST HYPOTHESIS, PROPERLY TESTED — a trade, not a win

                        before   after
      arm DIRECTION      40.7     36.9   better
      elbow BEND         26.8     24.4   better
      arm TWIST          34.6     31.5   better
      thigh DIRECTION    12.5     19.5   WORSE by 56%
      sum of angles     156.6    154.6   within noise

★★★ **EVERY ARM STAGE IMPROVED, WHICH CONFIRMS THE DIAGNOSIS.** A position target on the elbow
leaves the shoulder's twist free; choosing it from the child's bend plane helps exactly where
predicted.

★★ **BUT THE LEGS — the best-performing part of the retarget — GOT 56% WORSE** for a sum gain
inside the noise. Restricting to bodies with 2 DOF or fewer (a 3-DOF hip can control its own
twist; a 2-DOF shoulder cannot) did NOT recover them: 19.4 against 19.5. **The regression enters
elsewhere in the spine/leg chain and is not yet understood.**

★ Reverted. **"Helps what I aimed at, hurts something better" is not a result to ship**, and the
arm gains say it is worth returning to once the leg path is understood.

### ★★★ AND THE EDIT DISCIPLINE HELD THIS TIME

Both the apply AND the revert were scripted, and **both anchors failed on the first attempt.**
The difference from last turn is that each was followed by `grep -c` for the text just written:

    apply  -> grep 1  -> measured   real numbers, real conclusion
    revert -> grep 0  -> retried by line number -> grep 1 -> numbers restored

★★ **The first revert silently left the change in place**, and without the grep the next
measurement would have described the reverted-in-name-only state. That is the same failure as
last turn's phantom measurement, caught this time for the cost of one command.

---

## ★★★ 11. RE-READING GMR WITH WHAT THIS ARC TAUGHT — three structural differences

Read `motion_retarget.py` again asking the questions this arc has earned the right to ask.

### ★★★ A. GMR WARM-STARTS FROM THE PREVIOUS FRAME. WE RESET TO `qpos0` EVERY FRAME.

    self.configuration.integrate_inplace(vel1, dt)     # and never reset

**I reset deliberately**, and wrote the reason down: *"so a bad frame cannot poison the next."*
That was a debugging convenience adopted while the pipeline was untrustworthy, and it has
outlived its purpose.

★★★ **AND IT IS ALMOST CERTAINLY THE ANSWER TO THE FREE-TWIST PROBLEM.** A position target on
an elbow does not determine the shoulder's twist — the solution set is a circle. **From a warm
start the solver stays on the branch it was on last frame**; from `qpos0` it picks whatever the
damping favours, independently, every frame. That is exactly the ambiguity I tried to resolve
per-body, which helped the arms and wrecked the legs.

★ **Continuity resolves it globally and uniformly, where an explicit per-body choice cannot.**
Free DOF stop being free once the previous frame constrains them.

### ★★ B. TWO SEQUENTIAL TASK GROUPS, EACH SOLVED TO CONVERGENCE

    tasks1 -> solve to convergence     the big bodies
    tasks2 -> solve to convergence     the extremities

Not one weighted solve — a PRIORITY SCHEME. The second refines without being able to trade the
first away. **We solve everything at once with weights**, which is precisely the setup where
"feet at 50, everything else at 10" has to be tuned, and where a good foot can be bought by
ruining a torso.

### ★ C. JOINT LIMITS ARE A CONSTRAINT IN THE SOLVE, NOT A CLAMP AFTER IT

    self.ik_limits = [mink.ConfigurationLimit(self.model)]

We clamp a hinge after choosing its angle. GMR's solver never proposes an infeasible step, so it
finds the best REACHABLE answer rather than the projection of an unreachable one.

---

## ★★★ THE PLAN, in the order the evidence supports

**1. WARM START. (biggest, cheapest, most likely)**
Keep `qpos` between frames instead of resetting. One line, and it directly addresses the
ambiguity that four experiments have now circled. **Watch `arm TWIST` (34.6) and the frame-to-
frame stability the scorecard cannot currently see** — which means adding a JITTER metric:
mean change in each bone's direction between consecutive frames. Continuity is what warm
starting buys, and nothing in the scorecard measures it yet.

★ Add the jitter metric FIRST, or the change cannot be judged: a warm start could improve
smoothness while leaving every static number identical.

**2. SEQUENTIAL TASK GROUPS.**
Split the match table into a group-1 (torso, pelvis, thighs) and group-2 (arms, feet, head),
solve each to convergence in turn. **Removes the need for hand-tuned weights between limbs**, and
directly targets the "helps arms, hurts legs" trade that ended the last turn.

**3. JOINT LIMITS INSIDE `ikStep`.**
Clamp the STEP, not the result: scale `dq` so no joint crosses its range. Cheap, and it stops
the solver spending its budget on directions it cannot use.

**4. Only then revisit the shoulder twist.**
If 1 and 2 land, the free-twist ambiguity may simply not exist any more. **Retrying it before
them would repeat the last turn's trade.**

★★ **What NOT to do:** do not tune weights until 2 is in. The weights exist to arbitrate between
competing tasks, and a priority scheme removes most of that competition — tuning first would be
fitting parameters to a problem about to change shape.

---

## ★★ 12. THE JITTER METRIC — designed, and NOT shipped half-wired

Attempted as step 1 of the plan: measure the robot's frame-to-frame direction change minus the
human's, so a warm start has something to be judged by.

★★ **THREE SCRIPTED EDITS, TWO LANDED, ONE DID NOT.** The declarations and the print went in;
the sampling block — the part that actually computes anything — silently did not. The result
compiled far enough to look plausible and referenced variables that were never created.

★ Caught by `grep -c` on each edit, which is now routine after last turn. **Reverted rather than
patched forward**: a half-wired metric that prints a number nothing computes is worse than no
metric, and this session has already shipped one number that measured nothing.

### What it needs, recorded so the next attempt is short

★ The metric is right and the reasoning stands: a position target on an elbow does not determine
the shoulder's TWIST, so from a cold start the solver picks whichever branch damping favours,
**independently every frame** — and every static stage can be identical while the arm spins.

★ **Comparing against the HUMAN's frame-to-frame change, not against zero, is what separates
jitter from dancing.**

★★ Wiring needs a SECOND `poseFromRetarget` call per sample, against frame N+1, and the loop is
not shaped for it — it converts the human pose into robot-frame buffers once per iteration and
reuses them. **That reshaping is the actual work**, and doing it deliberately beats bolting a
second call into a loop built for one.

### ★ The plan is unchanged and still right

    1. jitter metric      <- here; needs the loop reshaped, not more edits
    2. WARM START         the likely answer to the free-twist ambiguity
    3. sequential groups  removes the weight-tuning between limbs
    4. joint limits in the step
    5. only then revisit the shoulder twist

---

## ★★★ 13. THE JITTER METRIC IS IN — and the numbers are large

      --- JITTER (excess motion vs the capture, deg/frame) ---
      8. upper arm             25.23
      9. thigh                 36.85

★★★ **THE ROBOT MOVES 25-37 DEGREES PER FRAME MORE THAN THE CAPTURE ASKS FOR.** That is not a
subtle effect and **no static stage in the scorecard could see it** — torso, direction, bend and
twist were all measured on single frames, and every one of them can be identical while the arm
spins between them.

★★ It is exactly what a COLD START predicts: a position target on an elbow leaves the shoulder's
twist on a circle of solutions, and from `qpos0` the solver re-picks a branch independently every
frame. **The hypothesis now has a number attached before the fix is attempted**, which is the
whole reason step 1 came before step 2.

★ Excess against the HUMAN's own frame-to-frame change, not against zero — otherwise a dancing
capture would read as jitter.

### ★★ THE EDIT DISCIPLINE, THIRD TURN RUNNING

Four scripted edits this time, each followed by `grep -c` on the text just written. **The
insertion by LINE NUMBER landed first try where three anchored `str.replace` calls had failed
across the previous two turns** — anchors break on whitespace and indentation that `zig fmt`
later normalises, and line numbers do not.

★ Also cleared a stale `build_options` path after the cache wipe: the recorded one pointed at a
deleted directory, and `zig test` failed with `unable to load 'options.zig'` rather than anything
about the cache.

### Next, unchanged and now measurable

    2. WARM START         keep qpos between frames    -> watch stages 8 and 9
    3. sequential groups
    4. joint limits in the step
    5. revisit the shoulder twist

★ **Stage 8 and 9 are the prediction**: a warm start should cut them sharply while leaving the
static stages roughly alone. If it does not, the free-twist story is wrong and four turns of
reasoning go with it.

---

## ★★★ 14. ARM FOCUS — five frames, per-frame, and the diagnosis is unambiguous

      frame  40: elbow 0.149  hand 0.374   (reach wanted 0.340, robot max 0.624)
      frame 180: elbow 0.124  hand 0.396   (reach wanted 0.284, robot max 0.624)
      frame 320: elbow 0.072  hand 0.190   (reach wanted 0.460, robot max 0.624)
      frame 460: elbow 0.157  hand 0.497   (reach wanted 0.228, robot max 0.624)

★★★ **EVERY WANTED REACH IS WELL INSIDE THE ROBOT'S 0.62 m SPAN.** So the hand errors — up to
0.50 m on an arm 0.62 m long — are **not a reach limitation.** The arm CAN get there and does
not.

★★ Elbow errors (7-16 cm) are much smaller than hand errors (19-50 cm), which localises it
precisely: **the upper arm is roughly right and everything after the elbow is wrong.** That is
the bend angle and the twist, exactly the two quantities a shoulder-aim leaves undetermined.

★ Per-frame rather than averaged, deliberately: **an average hides which pose is hard.** These
four are uniformly bad, which rules out "fine except when the arm is overhead" and means one
mechanism is wrong rather than one case being unhandled.

★ Errors measured RELATIVE TO THE SHOULDER, because the arm's job is its own shape — absolute
errors would mostly re-report the torso's placement.

### ★★ THE UNITS BUG, A THIRD TIME

The first run reported a wanted reach of **35.6 METRES**. Raw centimetres again — and the sanity
guard written after the second occurrence lives in the EXAMPLE, not here.

★★★ **A GUARD THAT PROTECTS ONE CALL SITE IS NOT A GUARD.** The reach print is this test's
version: any "wanted" far from an arm's length is a units error, and printing it beside the
robot's own span makes that unmissable rather than plausible.

### ★★ THE FIX THIS POINTS TO: TWO-BONE ANALYTIC IK

An arm is shoulder (2 DOF) + elbow (1 DOF) = **3 DOF, and a hand position is 3 numbers.** It is
exactly determined — no solver, no weights, no iteration:

    1. elbow flexion  from the law of cosines on the ROBOT's own two bone lengths and the
                      distance to the hand target
    2. shoulder swing so the resulting arm plane passes through the hand
    3. shoulder twist from the capture's elbow position, which picks WHICH plane

★ **This is the "copy angles, never lengths" rule applied to a whole limb**: the capture supplies
the hand DIRECTION and the elbow's plane; the robot's own bones supply every length.

★ It replaces aim-at-elbow, the hinge flexion heuristic and the free-twist problem with one
closed-form construction — and it is candidate 9 from the original ten, reached now by
measurement rather than by listing.

---

## ★★★ 15. TWO-BONE ANALYTIC IK — `robot.solveTwoBoneLimb`, exact and tested

    joint_position, flexion, clamped = solveTwoBoneLimb(
        shoulder, hand_target, elbow_hint, upper_length, lower_length)

★★★ **A REACHABLE TARGET IS MET EXACTLY — not minimised, not approached.** An arm is 3 DOF and
a hand position is 3 numbers, so there is nothing to optimise. **A least-squares solver cannot
make that claim and this construction can**, which is the whole reason to prefer it.

★★ **THE PLANE COMES FROM THE CAPTURE'S OWN ELBOW.** Without it the elbow sits anywhere on a
circle about the shoulder-hand axis — **that circle IS the free-twist ambiguity that cost this
arc four experiments.** The capture always knew the answer; it simply was not being asked.

★ Every LENGTH from the robot, every DIRECTION from the capture. The rule arrived at three times
separately, here applied to a whole limb at once.

### The test

★ Asserts the EQUALITY, not a tolerance band: the upper bone is exactly its own length, the lower
bone reaches the target at exactly its own length, and the reported flexion agrees with the
triangle just built rather than being an independent guess.

★ Four targets including near-full-extension and heavily bent; **elbow verified to be on the
hint's side of the axis**, which is the property the plane argument rests on.

★ Out of reach: extends toward the target, reports `clamped`, and returns a number — no NaN from
an out-of-range cosine, no silent fold.

★ **Mutation-checked**: flipping the swing's sign fails the test. The exactness is real, not an
artefact of loose tolerances.

### Next

★ Wire it into `poseFromRetarget` for the arm chain and re-run ARM FOCUS. **The prediction is
that hand error goes to roughly zero on every frame whose target is in reach** — and all four
sampled frames are, by a wide margin. If it does not, the shoulder is not where this test assumes
and the torso is the problem after all.

---

## ★★★ 16. TWO-BONE IK WIRED — the ELBOW lands, the HAND does not

                    baseline (aim)   two-bone
      frame  40      elbow 0.149      0.096      hand 0.374 -> 0.548
      frame 180      elbow 0.124      0.084      hand 0.396 -> 0.573
      frame 320      elbow 0.072      0.318      hand 0.190 -> 0.707
      frame 460      elbow 0.157      0.069      hand 0.497 -> 0.570

★★ **THE ELBOW IMPROVES AT THREE OF FOUR FRAMES** — which is the closed form working. **The hand
sits at a near-CONSTANT 0.57 m regardless of the target**, which is not an accuracy problem: a
constant error across varying targets means the hand is not responding to the solve at all.

★ `hand_right` has ZERO DOF — it is welded, so its position follows entirely from the elbow's
hinge angle. Setting that angle and seeing the hand not move means the angle is not reaching it,
and **the next step is to print the achieved flexion against the solved one** rather than guess
further.

### ★★ TWO BUGS FOUND AND FIXED ALONG THE WAY

1. **ABSOLUTE vs SHOULDER-RELATIVE TARGETS.** The solve was handed the capture's absolute hand
   position from the ROBOT's shoulder — which are not in the same place — so the limb spent its
   reach cancelling a torso error. **The error METRIC in this very test already measured
   relative to the shoulder**; I applied the principle to the measurement and not to the target.
   Elbow 0.36-0.44 -> 0.07-0.32.

2. **THE LOOP OVERWROTE THE SOLVED ELBOW.** A two-bone solve sets its middle joint, then the
   loop reaches that body and re-poses it with the per-joint heuristic. Fixed with an
   `already_posed` claim.

### ★★★ AND A THIRD, WHICH IS THE ONE WORTH REMEMBERING

Disabling the two-bone flag did NOT restore the baseline — every number came back **three times
worse** — because adding the two-bone block had silently replaced `aim_flags[arm_b] = true`.

★★ **THAT READ AS "THE REVERT FAILED"** and would have sent the next investigation somewhere
useless. It was caught only because the baseline numbers were known EXACTLY (0.149 / 0.124 /
0.072 / 0.157) and could be compared digit for digit.

★★★ **KNOWING THE BASELINE TO THREE DECIMALS IS WHAT MAKES A REVERT VERIFIABLE.** A remembered
"about 0.1-0.2" would have accepted 0.5 as plausible.

★ `solveTwoBoneLimb` stays, exported and unit-tested exactly; the pipeline flag is off until the
hand responds.

---

## ★★★ 17. THE HINGE ANGLE IS NOT THE FLEXION ANGLE — the elbow axis is DIAGONAL

      solved 113.9 deg   qpos held  -90.9   achieved 18.6   range [-100,50]
      solved 125.7 deg   qpos held -100.0   achieved  9.5   CLAMPED
      solved  85.0 deg   qpos held  -36.9   achieved 72.5
      solved 137.2 deg   qpos held -100.0   achieved  9.5   CLAMPED

    humanoid.xml:  elbow_right axis="0 -1 1"     lower_arm_right pos=".18 -.18 -.18"

★★★ **WRITING -90.9 INTO THE HINGE PRODUCES 18.6 DEGREES OF BEND.** Every heuristic in this arc
has assumed `qpos == flexion`, and that is only true when **the hinge axis is PERPENDICULAR to
both bones.** `humanoid.xml`'s elbow axis is `(0,-1,1)` against a forearm at `(.18,-.18,-.18)` —
diagonal to diagonal.

★★ Rotating a bone about an axis it is NOT perpendicular to sweeps it around a CONE. With `γ`
the angle between axis and bone:

    cos(flexion) = cos²γ + sin²γ · cos(qpos)

so the mapping is **`cos(qpos) = (cos φ − cos²γ) / sin²γ`**, and — the part that matters —
**the maximum achievable bend is `φ_max = 2γ`.** An elbow whose axis lies close to its own bone
physically cannot fold, whatever is written into it.

★ That explains everything the last three turns measured: the near-constant hand error, the
clamping at -100 on half the frames, and why setting the flexion "exactly" changed nothing. **The
angle was arriving; it was not producing the bend it was assumed to.**

### ★★ WHAT TO FIX

1. **Convert flexion to hinge angle through the cone relation**, not by assuming equality. Two
   `acos` calls, and `γ` is a property of the model computable once.
2. **Report `φ_max = 2γ` per joint.** If a limb physically cannot reach the capture's bend, that
   is a MODEL limit to state plainly — like the 2-DOF shoulder trade — not an error to chase.
3. Only then re-enable two-bone IK: it computes the right flexion and hands it to a mapping that
   currently discards most of it.

★★★ **THE LESSON GENERALISES BEYOND THIS JOINT: a joint's `qpos` is a coordinate, not a
measurement of the pose.** Reading it as an angle-between-bones works for a textbook hinge and
fails silently for a real robot's — and it failed silently here for many turns.

---

## ★★★ 18. THE CONE RELATION — `hingeAngleForFlexion` and `maximumFlexion`, round-trip tested

    cos(flexion) = cos²gamma + sin²gamma * cos(qpos)      gamma = angle(axis, bone)
    maximum bend  phi_max = 2 * gamma

★ Round trip asserted, not reasoned about: rotate the bone by the returned coordinate, measure
the angle it moved through, and it must EQUAL the flexion requested. Exact across three axis
geometries including `humanoid.xml`'s own elbow.

★ Returns NULL past the limit rather than clamping. **A joint whose axis lies close to its own
bone physically cannot fold**, and saying so beats writing a number that does nothing.

### ★★ AND A SURPRISE THAT REFRAMES SECTION 17

The elbow's axis `(0,-1,1)` against the forearm offset `(.18,-.18,-.18)` has a dot product of
**ZERO — they are PERPENDICULAR**, so `gamma = 90 deg` and the mapping is the IDENTITY there.
The round trip prints `want 0.150 -> qpos 0.150 -> measured 0.150`.

★★★ **SO THE CONE RELATION IS NOT WHY -90.9 PRODUCED 18.6 DEGREES.** Section 17's diagnosis was
right that `qpos != flexion` in general, and wrong about the cause in THIS case. The remaining
suspect is the bone the hinge actually moves: **the elbow rotates the FOREARM, so the relevant
bone is the HAND's offset from the forearm, not the forearm's offset from the upper arm** — and
I measured the latter.

★ The functions are correct and worth having regardless; the elbow needs re-measuring with the
right bone before anything is concluded from them.

### ★★ TWO TEST-EDGE BUGS, BOTH MINE

1. **`try expect(false)` at the reachability edge.** The loop stepped 0.2 rad toward an exact
   limit, so the last sample landed inside float noise of it. **The property under test is the
   round trip, not the bound** — conflating them made an arithmetic edge look like a failure.
2. **A bend just past a 180-degree limit WRAPS into the reachable range** rather than exceeding
   it, so asserting `null` at `limit + 0.2` was wrong for exactly the geometry that has no
   limit worth testing.

---

## ★★★ 19. EVERY GEOMETRIC EXPLANATION ELIMINATED — the fault is in the PIPELINE, not the joint

    joint idx 18   count 1   axis (0.00, -0.71, 0.71)      the elbow, correctly identified
    axis . forearm_bone = 0.0   gamma = 90 deg             PERPENDICULAR
    axis . hand_bone    = 0.0   gamma = 90 deg             PERPENDICULAR either way
    qpos held -90.9  ->  achieved bend 18.6 deg

★★★ **A HINGE WHOSE AXIS IS PERPENDICULAR TO ITS BONE, HOLDING -90.9 DEGREES, MUST BEND 90.9
DEGREES.** It does not. Every geometric explanation is now eliminated by measurement:

    "the cone relation"        gamma is 90 on BOTH candidate bones; the mapping is identity
    "wrong joint index"        idx 18, count 1, axis matches the XML exactly
    "wrong bone"               both candidates give the same gamma
    "range clamping"           explains 2 of 4 frames, not the -90.9 case

★★ **SO THE FAULT IS NOT IN THE JOINT'S GEOMETRY BUT IN WHAT THE PIPELINE DOES AROUND IT** — the
angle is written and something later disagrees with it, or the `achieved` measurement is reading
two vectors that are not the two bones.

### ★ THE NEXT STEP IS A MINIMAL TEST, NOT MORE PRINTS

Set the elbow hinge to a known angle on a bare model, run `kinematics`, and measure the angle
between the two bone segments. **Three lines, no retarget, no capture, no chains.**

★★ If it reads back correctly, the retarget is corrupting it later and the pipeline is the
suspect. If it does not, `kinematics` or the joint's frame is, and everything built on top has
been standing on a false reading.

★ **Four prints inside the pipeline have now failed to settle this**, each answering a narrower
question than the last. The isolation should have come first — it is the same lesson as
`fitBodyRotation` and `jacBody`, both of which took one minimal test each and gave clean answers
immediately.

---

## ★★★ 20. **ZERO IS NOT STRAIGHT.** The elbow rests at 109.5 degrees.

The minimal test, on a bare model with no retarget, no capture and no chains:

    qpos  -17.2 -> bend  92.3        109.5 - 17.2
    qpos  -51.6 -> bend  57.9        109.5 - 51.6
    qpos  -80.2 -> bend  29.3        109.5 - 80.2
    qpos  +22.9 -> bend 132.4        109.5 + 22.9

★★★ **`bend = rest_bend + qpos`, EXACTLY.** The hinge is a perfectly ordinary perpendicular
joint. It simply does not start from straight — **`humanoid.xml`'s arms fold into a triangle at
`qpos0`, and that fold is 109.5 degrees of elbow.** Visible in the T-pose comparison many turns
ago, and never connected to the flexion heuristic.

★★ Every flexion heuristic in this arc wrote the wanted bend straight into the coordinate.
Writing -90.9 asked for 18.6 and got exactly that. **Not a bug in the joint, the axis, the bone,
`kinematics`, or the cone geometry — a bug in what ZERO MEANS.**

### The fix, and what it bought

    qpos = wanted_flexion - rest_flexion        rest_flexion measured once from qpos0

                    before   after
      frame  40      0.374    0.137
      frame 180      0.396    0.206
      frame 320      0.190    0.424
      frame 460      0.497    0.203
      mean           0.364    0.242            33% better

★ One subtraction, three of four frames sharply better. **Frame 320 got worse and is now the
outlier to chase** — it is also the frame with the longest wanted reach (0.460 of 0.624).

### ★★★ THE LESSON, AND IT IS THE ARC'S CENTRAL ONE

**This is the reference-pose problem in JOINT COORDINATES — the fifth costume it has worn:**

    1. A-pose bind used where a T-pose was needed          world space
    2. an unrotated offset accumulation                    world space
    3. a vertical reference bone that cannot encode yaw    world space
    4. `qpos0` treated as a T-pose when it is not          world space
    5. `qpos = 0` treated as straight when it is not       JOINT space

★★ Four minimal tests have now each cracked a problem that many in-pipeline prints could not —
`fitBodyRotation`, `jacBody`, `solveTwoBoneLimb`, and this one. **The pattern is exact: isolate
the mechanism on a bare model and ask the whole question at once.**

---

## ★★ 21. STEP 1 OF THE REVISED PLAN — the rest-bend fix now ships

`robot_rest_flexion` measured once per rest-pose rebuild in the example, subtracted in its hinge
path exactly as the harness does. **The divergence the newest fix reopened is closed again.**

★ Shipped as `geno_dance.html` (12.3 MB standalone) with IK refine ON at 20 steps, overlay on
the character, geoms drawn.

★ What the device should show, and what it should not: legs tracking (knee 6.6, thigh 12.5 on
the harness), arms approximate but with hands now reaching toward where the character's are
rather than folding — and **still jittering frame to frame, because step 3 (warm start) is not
yet in.** That jitter is measured at 25-37 deg/frame and is the next thing to remove, not a
regression.

---

## ★★★ 22. SIMON WAS RIGHT: THE MATH WAS WRONG, AND THE METRIC WAS HIDING IT

*"The anim is not tracked at all yet. It is not a question of warm start, the math is just
wrong."* Two things found, in order.

### ★★ The metric was conflating LENGTH with DIRECTION

`|robot_elbow − human_elbow|` is nonzero even for a PERFECTLY aimed bone whenever the two bones
differ in length: error = |L_robot − L_human| at zero angular error. **The robot's upper arm is
0.312 m; the human's, scaled, is 0.247 — 26% longer.** Frame 320's "0.072 m elbow error" was
almost entirely that. **"Copy angles, never lengths" applies to the ruler too.**

Reported as angles instead, the picture changed:

      frame  40:  upper arm 28.0 deg   forearm  54.5 deg
      frame 180:  upper arm 22.0 deg   forearm  38.1 deg
      frame 320:  upper arm  6.4 deg   forearm 127.4 deg    <- nearly straight arm, FOLDED BACK
      frame 460:  upper arm 29.8 deg   forearm  47.1 deg

### ★★★ The sign flip was BACKWARDS

The measured relation is `bend = rest + qpos` — the coordinate ADDS. To straighten an elbow
resting at 109.5, qpos must be −109.5. **The `bends_negative` range heuristic turned that into
+109.5, clamped it to +50, and the arm bent FURTHER.** A nearly straight human arm produced a
robot forearm 127 degrees off, folded on itself.

★ The heuristic guessed the direction from the joint's range. The relation was MEASURED and has
no flip. **A measured relation beats a plausible heuristic every time, and this one was sitting
in the minimal test's own output.**

      after removing the flip:
      frame  40:  forearm  54.5 -> 31.0    hand 0.137 -> 0.101
      frame 180:  forearm  38.1 -> 36.6    hand 0.206 -> 0.208
      frame 320:  forearm 127.4 -> 21.5    hand 0.424 -> 0.149
      frame 460:  forearm  47.1 -> 44.0    hand 0.203 -> 0.094
      mean hand   0.242 -> 0.138 m          43% better

★ Applied to both the harness and the example in the same turn, verified by grep at each edit.
Shipped.

### ★ What is still wrong, and now visible

**Upper arm angles of 22-30 degrees on three frames** with `aim_at_child` set — an aim should be
near zero. Either the 2-DOF shoulder cannot reach those directions (a model limit, checkable by
comparing against `fitBodyRotation`'s residual) or the aim target is being built from the wrong
joints. **That is the next thing to isolate, on a bare model, before anything else.**

★ And the warm start is now correctly demoted: **it was never the cause of the tracking failure.**
It remains a real, measured jitter source — but Simon's instinct that the math came first was the
right one, twice over in a single turn.

---

## ★★★ 23. BACK TO THE DRAWING BOARD — the torso, solved in one turn

Simon: *"We never actually managed to place the torso correctly. Back to the drawing board."*

### The reframe

★★★ **THE TORSO IS THE ROOT. ITS ORIENTATION IS FREE.** There is no fitting problem, no chain, no
parent to inherit from. The only question was ever: what world rotation should it have? And
**two directions fully determine an orientation** — for a torso, the SPINE and the SHOULDER
AXIS. Match both and nothing is left free.

★ `robot.rotationBetweenDirectionPairs`: build an orthonormal basis from each pair, take the
rotation between them. Unit-tested on BOTH directions after rotation, because a single direction
leaves twist free and that ambiguity has cost this arc four experiments.

### The measurement

      frame  40:  spine  0.0 deg   shoulders  1.0
      frame 180:  spine  0.0 deg   shoulders  1.9
      frame 320:  spine  0.0 deg   shoulders 15.4
      frame 460:  spine  0.0 deg   shoulders  8.2

★★★ **THE SPINE IS EXACT ON EVERY FRAME.** The first genuinely clean torso result in the
project, against 35 degrees from the twist-offset path and 25 from aiming.

★★ The shoulder residual is the MODEL: a human's shoulders shrug and roll relative to their
spine, while the robot's are welded to its torso. No orientation of a rigid body matches two
directions that have moved relative to each other. Same class as the 2-DOF shoulder and the
1-DOF elbow — a limit to state, not an error to chase.

### ★★★ WHY THIS TOOK SO LONG

Every earlier attempt treated the torso like a limb — something to be oriented by a rotation
converted from the source through rest poses and twist offsets. **It is not a limb. It has no
parent. It needs no conversion.** It needs two directions from the capture, and those come from
positions, which have been verified correct since the third session.

★ **"Draw the two things" would have shown this immediately**: the torso's spine and shoulder
axis, on both figures, superimposed. Two lines each. Instead it was approached through the most
complex machinery in the project because that machinery existed.

### Next, per Simon's scope

★ Pelvis: same construction — hip axis (left thigh to right) and spine direction. Head: 0 DOF,
nothing to do. Then one IK pass for position. **Torso, pelvis, head, and stop** — the limbs
inherit a correct torso now, and every limb number measured before this was measured against a
torso that was wrong.

---

## ★★ 24. TORSO EXACT THROUGH THE PIPELINE; PELVIS BLOCKED BY WHERE ITS DOF LIVE

`direction_pairs` wired into `poseFromRetarget`: a body listed there is oriented by two capture
directions, written directly if it is the root and fitted against the achieved parent otherwise.

      frame  40:  torso spine 0.0   pelvis up 15.8   hip axis 30.9
      frame 180:  torso spine 0.0   pelvis up  8.7   hip axis 37.8
      frame 320:  torso spine 0.0   pelvis up 19.0   hip axis 68.8
      frame 460:  torso spine 0.0   pelvis up  1.0   hip axis 50.0

★★★ **THE TORSO IS EXACT THROUGH THE SHARED LOOP** — not just in an isolated test. The
mechanism is in the code that ships.

### ★★ The pelvis is poor for a structural reason, now identified

    waist_lower   abdomen_z, abdomen_y      2 DOF
    pelvis        abdomen_x                 1 DOF

The waist is **3 DOF split across two bodies.** `fitBodyRotation(pelvis)` uses only the single
hinge the pelvis body OWNS, so a pelvis target that needs three axes gets one. The other two sit
in the parent, which the fit never touches.

★ **This is the DOF-ownership problem, and it is general**: a body's orientation is reached
through every joint on the path from the root, not only through its own. `fitBodyRotation` is the
right tool when the body owns enough DOF (the torso is free; a hip has three). It is the wrong
tool when the DOF are upstream.

### The fix — two candidates, both cheap

1. **Route the pelvis through IK as an ORIENTATION task** — `ikStep` already supports
   orientation rows and distributes across the whole chain. This is the "final IK pass" in
   Simon's scope, doing the job it exists for.
2. Fit the pelvis's target onto `waist_lower` first (2 DOF, the big ones), then let the pelvis's
   own hinge take the remainder. Sequential, no solver.

★ Measure both. The prediction is that either takes `pelvis up` and `hip axis` toward the
single-digit range the torso already reaches.

### ★ Also fixed: a guard that rejected joint 0

`Hips` IS joint 0, the root, so `try expect(hips_h != 0)` rejected a correct lookup and the test
failed before printing a frame. **A sentinel that collides with a valid value is not a
sentinel.**

---

## ★★★ 25. PELVIS THROUGH THE WAIST CHAIN — hip axis from 31-69 degrees to 0.3-11

`DirectionPair.chain_depth`: fit the same world target onto the named ancestors first, top down,
each against its parent's achieved orientation — then the body. Each ancestor takes what it can
and the next sees only what remains.

                       before              after
      frame  40:  up 15.8 / hips 30.9  ->  12.4 / 6.9
      frame 180:  up  8.7 / hips 37.8  ->   5.1 / 0.3
      frame 320:  up 19.0 / hips 68.8  ->  18.0 / 11.2
      frame 460:  up  1.0 / hips 50.0  ->  10.0 / 5.5

★★★ **THE HIP AXIS COLLAPSED FROM 31-69 DEGREES TO 0.3-11.** The waist's three DOF are split
2 + 1 across `waist_lower` and `pelvis`; fitting through both lets all three take part where the
pelvis alone reached one.

★ `pelvis up` sits at 5-18 degrees. That is the spine's bend — the abdomen joints have limited
range, and a human's Hips-to-Spine3 line bends more than a robot with one waist segment can. A
model limit again, and a small one.

### Where torso + pelvis + head stand — Simon's scope

      torso    spine EXACT, shoulders within the robot's rigid-shoulder limit (1-15 deg)
      pelvis   hip axis within 11 deg, up-direction within 18 (waist range limit)
      head     0 DOF — it goes where the torso puts it, and the torso is exact

★★ **THIS IS THE FIRST TIME THE CORE OF THE BODY HAS TRACKED THE CAPTURE.** It took one turn
each for torso and pelvis once they stopped being treated as limbs. Every limb number measured
before this was measured against a torso 25-35 degrees wrong; the arms now inherit an exact one.

### The recipe, as it now stands for the core

    1. torso:  two directions (spine, shoulder axis) → write to the free root      exact
    2. pelvis: two directions (up, hip axis) → fit through waist_lower, then pelvis  ≤ 11 deg
    3. head:   nothing — 0 DOF

★ No rest pose, no twist offsets, no chains, no q_local, no yaw constant. **Two directions from
positions, which have been correct since the third session.** The machinery that consumed most
of this project was for limbs — and for the core it was never needed.

### Next

★ Wire `direction_pairs` into the EXAMPLE (the harness has it; the example does not — the same
divergence class as before, and it must close before a device check means anything). Then the
IK position pass on the core, then re-measure the arms against an exact torso.

---

## ★ 26. THE TWO-DIRECTION CORE SHIPS IN THE EXAMPLE

`coreDirectionTarget` in `geno_dance.zig`: torso from (spine, shoulder axis), pelvis from (up,
hip axis), `waist_lower` taking the pelvis's target first so the waist's split DOF all take part.
Everything else in `poseRobot` falls through to the paths it used before.

★ The torso is the root and is written directly, so on device it should now sit exactly where
the harness says: spine aligned with the character's on every frame. The pelvis should follow
the hips within ~11 degrees.

★ Shipped as `geno_dance.html`, IK refine on, overlay on the character, geoms drawn.

★★ **The harness and the example now agree on the core mechanism** — the divergence class that
cost four rounds earlier is closed for torso and pelvis. The arms still go through the older
path and inherit whatever the torso gives them; with the torso exact, their numbers are worth
re-measuring before anything is changed there.

---

## ★★★ 27. "TORSO TURNED 90 DEGREES ON ITS VERTICAL AXIS" — the reference frame, one more time

★★★ **THE HARNESS MEASURES REST DIRECTIONS AT `qpos0`, WHERE EVERY BODY ROTATION IS IDENTITY.**
World equals local there, so the distinction never came up. **The example takes them from the
SOLVED T-POSE**, where the torso has already been turned — by exactly the facing yaw. Feeding
those WORLD directions to the alignment produced a rotation for a frame already turned 90
degrees. Same formula, different reference, and the difference was one body rotation the
harness never had to think about.

★ Fix: pull each rest direction into its body's LOCAL frame with the rest rotation, so
`W · local = human` and `W` is the world rotation the body should hold. Applied to both.

★★ **THE CHECK: the harness numbers must NOT change.** They did not — 12.4/6.9, 5.1/0.3,
18.0/11.2, 10.0/5.5, to the decimal. The construction is now frame-invariant, which is what makes
it safe from either rest pose.

### ★ The pattern, stated plainly for the sixth time

Every rest-pose bug in this project has been the same bug: **a quantity expressed in one frame,
consumed as if it were in another.** This one was invisible in the harness because its frame
happened to be identity. **A test that passes because the ambiguous case is degenerate has not
tested the ambiguity** — and the device found it in one look.

---

## ★★★ 28. THE ARM: the analytic two-bone decomposition DOES NOT APPLY to a 2-DOF shoulder

Simon's scope: right arm and hand, shoulder/elbow/hand errors toward zero, find the actual
equations.

### Isolated on a bare model, one step at a time

      shortest-arc aim at the solved elbow:   elbow 0.004 m   hand 0.620 m   bend angle CORRECT
      aim WITH the twist chosen (plane):      elbow 0.296 m   hand 0.739 m

★★★ **THE ELBOW IS EXACT AND THE BEND ANGLE IS RIGHT, AND THE HAND MISSES BY A FULL ARM LENGTH.**
The forearm bends in the wrong PLANE. And trying to choose the plane costs 0.296 m of elbow —
the 2-DOF trade, now with its mechanism visible.

### ★★★ Why: the plane is not a free choice on this robot

The closed form assumes 2 DOF for the elbow's DIRECTION plus 1 for the bend, with the bend PLANE
free. **A 2-DOF shoulder has no spare DOF for the plane**: whatever two angles put the elbow on a
direction also fix the hinge axis, so the plane is a CONSEQUENCE of the direction. "Choose the
elbow, then bend" is the wrong decomposition for `humanoid.xml`.

★ The arm is still exactly determined — 3 DOF against a 3-number hand — **but as a COUPLED 3x3
system**, which is what numerical IK on the hand position solves and a closed form built on a
free plane cannot.

### The actual equations for this arm

    hand(θ₁, θ₂, θ₃) = S + R(θ₁,θ₂)·[ L₁ ê + R_hinge(θ₃)·L₂ ê' ]     three unknowns, three equations
    solve by Newton / damped least squares on   hand(θ) − target = 0

★ `ikStep` with a single position task on `hand_right`, weight 1, on the arm's three DOF, is
exactly that solve. `jacBody` is finite-difference verified, `ikStep` converges monotonically on
a redundant chain, and here the chain is not even redundant. **The tool for the job has been
built and tested since §13b; the analytic path was a detour around it.**

### What stays

★ `solveTwoBoneLimb` remains, exact and tested, because it IS the right model for a 3-DOF
shoulder — a real robot's, or a hip. On this elbow it gives the exact FLEXION even though it
cannot give the plane, so it is still the right source for the hinge angle.

### The recipe for the right arm, as it now stands

    1. torso exact (two directions)                    → shoulder position is fixed and correct
    2. hinge:  qpos = flexion(two-bone) − rest_bend      exact bend angle, measured
    3. shoulder + elbow: IK on the hand position         coupled 3-DOF, the only exact route

★ Next: run exactly that in ARM FOCUS and read three numbers — shoulder (should be ~0 given the
torso), elbow angle, hand position.

---

## ★★★ 29. THE ARM: TWO REAL SOLVER BUGS, THEN THE MODEL'S OWN CEILING

### ★★ Bug 1 — a task is not a scope

`jacBody` returns a column for EVERY DOF from the body to the world, so a hand task includes the
elbow, the shoulder, the abdomen joints **and the free root**. The cheapest way to move a hand
10 cm is to translate the whole robot 10 cm, and the solver did exactly that — improving the hand
by 0.004 m while dragging the torso that had just been made exact.

★ `IkOptions.dof_mask`. With the arm's own three DOF: **hand error 0.000 m on every frame.**

### ★★ Bug 2 — the solver returned poses the robot cannot hold

That 0.000 was bought with the shoulder at **(-118, -107) against a range of [-85, 60]**. The
solve had no joint limits at all; GMR passes `mink.ConfigurationLimit` as a constraint.

★ `IkOptions.respect_joint_limits`, clamping after each step. **A residual is only meaningful
once the pose is reachable.**

### ★ And the targets: directions at the ROBOT's lengths

Targeting the human's hand POSITION lands the hand exactly and leaves the upper arm 12-34 degrees
off — the robot's bones are 26% longer, so the same point forces a different elbow. **You cannot
have both the hand's position and the bones' directions when the lengths differ.** Chain targets
built from the capture's directions at the robot's own lengths make both exactly reachable.

### The honest result, with limits enforced

      frame  40:  upper 27.8  forearm 31.0   shoulder (-70.3,-84.2)  1 joint AT LIMIT
      frame 180:  upper 22.0  forearm 40.1   shoulder (-85.0,-85.0)  2 joints AT LIMIT
      frame 320:  upper 10.5  forearm 15.8   shoulder (-76.5,-16.0)  none at limit
      frame 460:  upper 30.7  forearm 35.7   shoulder (-40.6,-85.0)  1 joint AT LIMIT

★★★ **THREE OF FOUR FRAMES HAVE A SHOULDER JOINT PINNED AT ITS LIMIT.** `humanoid.xml`'s shoulder
is two diagonal axes with range [-85, 60] — a patch, not a sphere — and this dance asks for
directions outside it. **The one frame with nothing at a limit is also the best (10.5 deg).**

★ So the arm's residual is the MODEL's, in the same family as the 1-DOF elbow, the 0-DOF hand and
the rigid shoulders. It is not "almost perfect" and on this robot it cannot be.

### Where Simon's list stands

    torso    spine EXACT every frame                        follows
    pelvis   hip axis <= 11 deg, up <= 18 (waist range)      follows
    head     0 DOF, carried by an exact torso                follows
    r. arm   10-31 deg, 3 of 4 frames at a joint limit       MODEL-LIMITED, not solver-limited

---

## ★★★ 30. THE LEGS DO NOT WANT WHAT THE ARM NEEDED

Simon: *"Without ik refine the arms look good now. Try to do the same with legs."*

Applied unchanged — same function, same chain targets at the robot's own bone lengths, same DOF
mask, same joint limits:

                     existing path      chain solve
      thigh            12.5 deg         28-43 deg      WORSE
      shin / knee       6.6 deg         27-53 deg      MUCH WORSE
      hip at limit         -            2 frames of 4

★★★ **THE CONSTRUCTION THAT RESCUED THE ARM MAKES THE LEG THREE TIMES WORSE.** Left off.

### Why the two limbs differ

★ The arm needed it because a **2-DOF shoulder pinned against a [-85, 60] patch could not aim at
all** — three of four frames had a joint at its limit before any of this. The chain solve gave it
reachable targets and a scope.

★★ The legs were **already the best part of the retarget** — knee 6.6 degrees through the
twist-offset path — and a chain of two exactly-reachable position targets OVER-CONSTRAINS a
4-DOF leg (3-DOF hip + knee) where it rescued a 3-DOF arm. Two frames end with the hip pinned,
which it never was before.

### ★★ THE LESSON

**"It worked for the arm" is not a reason.** Same code, same targets, same mask, opposite
outcomes — because a shoulder and a hip are not the same mechanism, and the thing that was
broken about the arm was never broken about the leg.

★ This is the sixth time in the project that a fix has been measured before shipping and found
to make things worse. Every one of those would have been argued into the codebase on reasoning
alone.

### Where the whole body stands

    torso    spine EXACT every frame                              two directions
    pelvis   hip axis <= 11 deg, up <= 18 (waist range limit)     two directions + chain fit
    head     0 DOF, carried by an exact torso                     nothing to do
    arms     10-31 deg, 3 of 4 frames at a shoulder limit         chain solve, masked, limited
    legs     thigh 12.5, knee 6.6 deg                             twist offsets, unchanged

★ **Every part of the body now uses the mechanism measured best for it**, and each choice is
recorded with the numbers that decided it.

---

## ★★★ 31. "LEGS DON'T WORK AT ALL" — the example never called the shared loop

★★★ **`poseFromRetarget` IS THE IMPLEMENTATION THE SCORECARD MEASURES, AND THE EXAMPLE NEVER
CALLED IT.** It kept a 270-line duplicate of the per-frame loop. Every leg number reported —
thigh 12.5, knee 6.6 degrees — described code that does not ship, while the device showed legs
that plainly do not follow.

★ **Fifth divergence between harness and example, and the largest by far.** The others were each
closed in turn:

    1. the twist builder            closed
    2. the rest-pose solve          closed
    3. the solver task set          closed
    4. the rest-flexion fix         closed
    5. THE ENTIRE PER-FRAME LOOP    outlasted all of them

★★ It survived because it was never checked for. Each earlier fix asked "do these two agree
about X?" and none asked "**do these two run the same code at all?**" — the question that would
have caught it on the first day.

### The fix

The example builds the inputs and calls `poseFromRetarget`, exactly as the harness does. The
duplicate loop, `shoulderMidpointCorrection` and `coreDirectionTarget` are deleted — the shared
loop covers all three via `direction_pairs`, `shoulder_bodies` and `rest_flexion`.

★ `buildCorePairs` supplies the torso and pelvis pairs, with rest directions pulled into each
body's LOCAL frame so the construction works from the solved T-pose.

### ★★ WHAT THIS MEANS FOR EVERY NUMBER IN THIS DOCUMENT

**Numbers measured through `poseFromRetarget` now describe the shipped example for the first
time.** The torso's "exact", the pelvis's 11 degrees, the legs' 12.5/6.6 — all of them were
harness-only until this turn, and the device kept saying so.

★ The arm chain solve and the IK pass still run in the example after the shared loop, so those
remain example-only and are the next thing to move.

---

## ★★★ 32. TOO LOW, AND THE LEGS ARE GENUINELY BROKEN ON THE SHARED PATH

### The height — fixed

★★★ `root_world_position` was the capture's ROOT (`Hips`). The robot's root body is the TORSO,
which maps to `Spine3` — **a spine higher.** The whole robot sat a spine-length low and the legs,
hanging from a torso at hip height, had nowhere to go.

★ `rootBodyWorldPosition` looks up the joint the ROOT BODY maps to. Same mistake as §30's
anchor: **"root" means a different body on each skeleton.**

### ★★★ The legs — measured properly for the first time, and they are bad

      frame  40:  torso 0.0   pelvis 12.4 / 6.9   THIGH 32.4   SHIN 74.7
      frame 180:  torso 0.0   pelvis  5.1 / 0.3   THIGH 11.1   SHIN 68.9
      frame 320:  torso 0.0   pelvis 18.0 / 11.2  THIGH 68.2   SHIN 40.7
      frame 460:  torso 0.0   pelvis 10.0 / 5.5   THIGH 30.3   SHIN 58.9

★★ **THE "thigh 12.5, knee 6.6" I HAVE QUOTED FOR MANY TURNS COMES FROM THE SCORECARD, WHICH
DOES NOT PASS `direction_pairs`.** There the torso goes through the twist path; here it goes
through two directions. **Fixing the torso changed what the legs inherit**, and the legs are far
worse than any number previously reported.

★ Two test bugs found and fixed getting here: the TORSO+PELVIS test passed IDENTITY twists (a
test that stubs out the thing under test measures the stub), and children of direction-pair
bodies were still dividing by a `parent_twist` their parent never applied. **Neither recovered
the legs** — 32.4/74.7 against 32.5/75.3. The coupling fix was correct and was not the cause.

### ★★★ WHERE THIS LEAVES THE LEGS

**The legs' twist offsets are built against a pelvis that no longer poses the way they assume.**
Mechanism A's chain is coherent only when the WHOLE chain uses A; the torso and pelvis now use
two directions, and the legs hang off them.

★ Two candidate fixes, both cheap, neither guessed:
  1. **Give the legs direction pairs too** — thigh has 3 DOF and two obvious directions (the
     thigh bone and the knee's bend plane). The construction that made the torso exact.
  2. Rebuild the leg twists against the pelvis's ACHIEVED rest orientation rather than `qpos0`'s.

★★ Measure both. **The torso being exact is worth more than the legs' old number was**, because
that number was never true of the shipped code — but the legs must now be rebuilt on the new
foundation rather than patched onto the old one.

---

## ★★★ 33. THE ROBOT WAS NAILED TO THE FLOOR, AND NO TEST COULD SEE IT

`rootBodyWorldPosition` scanned bodies from **0**. Body 0 is the WORLD, and its parent is also 0
— so the scan matched it first, found no mapped joint, returned null, and **the root translation
was never written.** The robot stood at the origin for the entire take.

★★ **Second time body/joint 0 has done this**: `try expect(hips_h != 0)` rejected a correct
lookup a few turns ago because `Hips` IS joint 0. **A sentinel that also satisfies the predicate
is not a sentinel** — and this codebase has two indices where 0 is both "not found" and a real
answer.

### ★★★ WHY NOTHING CAUGHT IT

**Every test in this project measures ANGLES.** Torso spine 0.0, pelvis 12.4, hips 6.9 — all
perfect, all unchanged, with the robot motionless at the origin. **An orientation-only suite is
blind to a robot nailed to the floor**, and it took a screenshot to notice, again.

★ Added: pose two well-separated frames and require the root to have TRAVELLED by roughly what
the capture travelled. **robot 2.027 m against capture 2.027 m.** One assertion, and the entire
class of "correct pose, wrong place" is now covered.

### ★ The pattern worth carrying

    the vacuous rest check      measured algebra, not the code
    the phantom edit            measured a change that never applied
    the duplicated loop         measured a different program
    the identity twists         measured a stub
    this                        measured only what could not go wrong

**Five times the instrument has agreed with itself while the thing being built was broken.** Each
was found by looking at the result rather than the number — and each is now covered by an
assertion that would have caught it.

---

## ★★★ 34. THE LEGS: THE HIP IS PINNED WHATEVER THE MECHANISM

Tried direction pairs on the thighs — the construction that made the torso exact. A thigh has
3 DOF and two obvious directions: its own bone, and the shin (which fixes the knee's bend plane).

                     twist path                direction pairs
      THIGH      32.4 / 11.1 / 68.2 / 30.3   90.2 / 16.5 / 49.7 / 58.4
      SHIN       74.7 / 68.9 / 40.7 / 58.9   46.2 / 62.3 / 32.2 / 24.7   much better
      hip pinned  2/3, 1/3, 3/3, 2/3          3/3 on three frames of four

★★ The SHIN improves sharply — the plane it needs is exactly what a direction pair supplies. **The
THIGH pays for it**, ending 90 degrees from its own bone on one frame. Sum 385 -> 380, inside
noise, with one frame visibly ruined. **Left off.**

### ★★★ THE REAL CONSTRAINT, VISIBLE FOR THE FIRST TIME

    hip pinned 2/3, 1/3, 3/3, 2/3      on the EXISTING path, before any change

**One to three of the hip's three joints are already at their limits on every frame measured.**
The leg is not failing for want of a better formula; `humanoid.xml`'s hip cannot reach the
orientations this dance asks for, and both mechanisms are clamping against the same wall.

★ Same finding as the shoulder (3 of 4 frames pinned) and the elbow (2 of 4 clamped), now for the
hip. **Three of the robot's four limb roots are range-limited against this capture.**

### ★ The lesson this turn adds

**The torso could take a two-direction target because it is FREE.** A joint with limits cannot
hold every orientation, so two directions — which determine an orientation completely — will
sometimes demand one it cannot reach. **The construction is not wrong; it asks for more than a
limited joint can give**, and that is a different failure from the ones this project has been
chasing.

★ What would actually help the legs, in order: relax or check the hip ranges against the capture
(is `humanoid.xml`'s hip range realistic?); or accept the limit and target the FOOT position
rather than the thigh's orientation, which is what a walking robot's retarget would do.

---

## ★★★ 35. THE HIP'S RANGE WAS NEVER THE CONSTRAINT — `fitBodyRotation` WAS

      hip_x   range -30 to 10     only 40 degrees, the abduction axis
      hip_z   range -60 to 35
      hip_y   range -150 to 20

The narrow axis looked like the answer. **It is not.** Same target, same three DOF, same limits
enforced on both:

      fit  32.4 / 11.1 / 68.2 / 30.3 deg        IK  0.0 / 0.0 / 0.0 / 0.0

★★★ **THE TARGET WAS REACHABLE ON EVERY FRAME AND THE SEQUENTIAL FIT COULD NOT FIND IT.**
`fitBodyRotation` walks a body's joints IN ORDER, giving each what it can take of the remaining
rotation — so it spends the 40-degree axis early on something a 170-degree axis could have done,
then clamps. **An IK has no ordering**: it distributes across all three at once.

★★ This reframes several earlier conclusions. "The hip is pinned on every frame" was TRUE and
MISLEADING: it was pinned because the fit put it there, not because the pose demanded it. **A
joint at its limit is evidence about the SOLVER as much as about the model.**

### Shipped

`RetargetPose.solve_scratch` / `solve_tasks`: bodies with 2+ DOF are posed by a limited, masked
IK on their bone direction, with a light second task on the grandchild to pick the bend plane.

                      before      after
      THIGH      32.4/11.1/68.2/30.3   9.8/16.2/38.0/9.0
      SHIN       74.7/68.9/40.7/58.9   94.0/66.5/43.4/67.1
      hip pinned  2/3,1/3,3/3,2/3      0/3,1/3,2/3,0/3
      sum              385                 344

★ **Thigh mean 35.5 -> 18.3 degrees, and the hips are free on half the frames.** The shin is
worse in the sum because it is a hinge whose plane comes from the thigh's twist, which one
position task leaves partly free; the grandchild task at weight 0.15 recovers most of it without
competing with the thigh's own direction (at 0.5 it took the thigh back to 25 degrees).

★★ **Wired into the EXAMPLE in the same turn**, so this ships rather than living in the harness —
the divergence lesson, applied without being re-learned.

### What remains for the legs

★ The shin is now the worst bone in the body. It is a 1-DOF knee: its direction is entirely the
thigh's twist plus a flexion angle, so **it cannot be fixed at the knee** — only by giving the
thigh's twist a better target. That is the same shape as the arm's bend-plane problem, and the
grandchild task is the first half of the answer.

---

## ★★★ 36. THE LEG, FORMULATED CORRECTLY — thigh 4.2 deg, shin 9.6 deg

      CHAIN leg: thigh  3.6  shin  2.3  ankle 0.005 m
      CHAIN leg: thigh  2.9  shin  3.3  ankle 0.004 m
      CHAIN leg: thigh  7.8  shin 12.0  ankle 0.031 m
      CHAIN leg: thigh  2.5  shin 20.8  ankle 0.129 m

                    before      after
      thigh mean     18.3        4.2
      shin  mean     67.8        9.6

### ★★★ THE STRUCTURE, WHICH WAS THE WHOLE ANSWER

**A leg is hip (3 DOF) + knee (1) = FOUR DOF against an ankle position of THREE numbers.** Exactly
one degree of freedom is left over, and it is the knee's SWIVEL about the hip-to-ankle axis. Two
consequences, and this project had both backwards:

1. ★★★ **THE ANKLE IS PRIMARY.** A leg exists to place a foot; the knee only resolves the
   leftover freedom. Every earlier attempt made the KNEE primary and weighted both equally, so
   the two competed for the same DOF. Ankle at 1.0, knee at 0.2.

2. ★★★ **ONE SOLVE OVER THE WHOLE CHAIN**, not per body. Posing the thigh and then setting the
   knee hinge separately has them fighting: **the hinge moves the ankle after the thigh was
   chosen to put it there.**

★★ Same code, same targets, same mask, same limits — **opposite result from one change: which
end is primary.** The earlier "the legs do not want what the arm needed" measurement was correct
about the code as it stood and wrong about the conclusion; the legs wanted the same construction,
formulated properly.

★ The arm is switched to end-primary too, for the same reason.

### Where the body stands now

    torso    spine EXACT every frame
    pelvis   hip axis <= 11 deg, up <= 18 (waist range)
    head     0 DOF, carried by an exact torso
    legs     thigh 4.2, shin 9.6 deg, ankle within 0.005-0.13 m
    arms     end-primary chain solve, masked and limited

★★ **Every limb now uses the same construction — whole chain, end effector primary, middle joint
for swivel, robot's own bone lengths, joint limits enforced.** The special cases are gone: the
core is two directions, the limbs are one IK each.

---

## ★★★ 37. THE POPS ARE IN THE ARMS, AND THEY ARE 157 DEGREES IN ONE FRAME

      jitter (cold): WORST 157.3 deg at upper_arm_right frame 348   (6578 samples)
      jitter (warm): WORST 144.5 deg at lower_arm_left  frame 476

### ★★ How they stayed invisible

★★★ **A MEAN READ -0.25 DEG/FRAME while a 157-degree pop sat inside it.** "Pops and jitters" IS
a maximum, and averaging is exactly the wrong summary. The first version of this probe averaged,
over 39 frames, on ONE bone, and found nothing.

★ Three sampling mistakes in one metric, each of which alone would have hidden it: the mean
instead of the max, a 40-frame window instead of the clip, and one bone instead of all of them.
**"I measured it and it was fine" is only as good as what the measurement could have seen.**

### ★★★ AND WARM START IS NOT THE ANSWER

157 -> 144 degrees. **The pops are not a cold-start branch flip**, which is what I predicted for
several turns and what the whole warm-start plan rested on. `warm_start` is now implemented and
measured; it barely moves the number.

★ The remaining explanation is the ARM's own structure: a 2-DOF shoulder against a [-85,60]
range, pinned on three frames of four, and a solver that can jump between two clamped
configurations when the target crosses a boundary. **A limit is a cliff, and an IK stepping over
one moves discontinuously.**

### What to try, in order

1. **Clamp the STEP, not the result.** `respect_joint_limits` clamps after integrating, so the
   solver can propose a huge step, have it truncated, and land somewhere unrelated to where it
   was. Scaling `dq` so no joint crosses its range keeps the motion continuous — this is what
   GMR's `ConfigurationLimit` does as a constraint.
2. **Then re-measure the max.** If it drops, limits were the cliff; if not, the shoulder is
   genuinely bistable at those poses and needs the previous frame as a tie-breaker at the TASK
   level, not just as a starting point.

---

## ★★★ 38. STEP-SCALING DID NOT FIX THE POPS, AND THE PROBE WAS MEASURING THE WRONG PATH

### Hypothesis 1: limits were the cliff — REFUTED

Replaced clamp-after-integrate with **scaling the whole step** by the largest admissible
fraction, so the solve keeps its DIRECTION and stops at the wall instead of being projected onto
it. Principled, and it is what GMR's `ConfigurationLimit` does as a constraint.

      before  157.3 deg      after  157.4 deg

★ **No change.** Kept anyway — it is correct, costs nothing, and removes a real discontinuity
class — but it is not this one.

### ★★★ AND THE PROBE WAS MEASURING A PATH THE EXAMPLE DISCARDS

The example runs `solveArmChain` for all four limbs **after** `poseFromRetarget`, overriding its
per-body pass entirely. **The jitter probe stopped before that**, so the 157-degree pop was
attributed to shipped code without checking — the divergence habit, in a measurement rather than
in an implementation.

★ With the whole-chain solve included, as the example runs it:

      jitter (cold): WORST 155.0 deg at upper_arm_left frame 321
      jitter (warm): WORST 148.5 deg at upper_arm_left frame 366

★★ **The pops survive both fixes and are real in the shipped path.** The arm solve is genuinely
BISTABLE: a 2-DOF shoulder pinned against [-85, 60] has two clamped configurations that satisfy
the targets nearly equally, and the solver takes whichever is nearer — which flips when the
target crosses a boundary. Warm-starting moves the starting point but not the basin.

### ★★★ WHAT ACTUALLY ADDRESSES IT

**Continuity has to be a TASK, not a starting point.** A small regularisation term pulling `dq`
toward the previous frame's configuration makes the two branches unequal, so the solver prefers
the one it was already in. That is a posture task in mink's vocabulary, and it is the one piece
of GMR's setup still missing here.

★ Concretely: add `posture_target: ?[]const f32` and `posture_weight: f32` to `IkOptions`,
contributing `w·(q_prev − q)` to the gradient. **Cheap, and it is the standard answer to a
redundant or bistable IK** — not a heuristic.

★ Then re-measure the MAX, on the whole clip, over all bodies, through the path the example runs.
Three properties this metric needed and did not have until this turn.

---

## ★★★ 39. THE FEET — aimed for the first time in the project

      CHAIN leg: thigh  1.2  shin  3.6  ankle 0.007 m  FOOT 11.4 deg
      CHAIN leg: thigh  3.0  shin  2.9  ankle 0.006 m  FOOT 13.3 deg
      CHAIN leg: thigh 10.2  shin 12.3  ankle 0.034 m  FOOT 78.6 deg
      CHAIN leg: thigh  2.3  shin 21.2  ankle 0.127 m  FOOT 30.3 deg

★★★ **THE ANKLE'S TWO DOF HAD SAT AT REST FOR THE ENTIRE TAKE.** The foot is the END body of a
leg: it has no child, so every aim-the-bone mechanism in this project skipped it silently. **The
foot is the one part of the robot that touches the ground**, and its angle is what reads as
standing rather than sliding.

### How it is done

★ `IkTask.point_local` targets a point in the BODY's own frame — exactly what a foot needs. A
point along the sole is asked to land where the capture's toe is relative to its ankle. Two DOF,
and the ankle position is already fixed by the primary task, so nothing competes.

★★ The sole point is read from the foot's **geom** (`geom_pos` doubled — it is the capsule's
centre, so its far end is twice as far), not hardcoded. A different robot needs no code change.

★ Weight 0.5, and the leg is undisturbed: thigh 3.6/2.9/8.4/2.4 before the foot task, 1.2/3.0/
10.2/2.3 after — two frames slightly better, none worse in a way that matters.

### What the numbers say

★ **11-13 degrees on the two clean frames.** Frames 320 and 460 are 78.6 and 30.3 — and they are
the same two frames that are worst everywhere else (shin 12.3 and 21.2, ankle 0.034 and 0.127).
**A foot cannot be right when the shin below it is 21 degrees off**; the foot inherits the whole
chain's error and adds the ankle's own limits on top.

### Where the body stands

    torso    spine EXACT
    pelvis   hip axis <= 11 deg
    head     0 DOF, carried by the torso
    legs     thigh ~4 deg, shin ~10, ankle within 0.006-0.13 m
    feet     11-13 deg on clean frames, worse where the chain above is worse
    arms     end-primary chain solve; 155-degree POPS remain, bistable shoulder

★ **Smoothness is deferred by choice**, not forgotten: the pops are measured, localised to the
2-DOF shoulder, and the fix (a posture task) is specified in §38. The stated goal for now is to
see how well the UNMODIFIED humanoid fits Geno — and that answer is taking shape: the core is
excellent, the legs are good, the feet are reasonable, and the arms are limited by a shoulder
that cannot reach.

---

## ★★★ 40. WHICH JOINT REFUSES — the answer to "how well can the UNMODIFIED humanoid fit Geno"

      thigh  1.2  shin  3.6  ankle 0.007  FOOT 11.4   pinned []     knee wants 110.2 of [-160,2]+1
      thigh  3.0  shin  2.9  ankle 0.006  FOOT 13.3   pinned []     knee wants  77.2
      thigh 10.2  shin 12.3  ankle 0.034  FOOT 78.6   pinned [h]    knee wants  58.2
      thigh  2.3  shin 21.2  ankle 0.127  FOOT 30.3   pinned [ha]   knee wants  75.0

★★ Every target is built at the ROBOT's own bone lengths, so **a 0.127 m ankle miss cannot be a
reach problem.** It is a limit, and the probe now names which.

### ★★★ THE KNEE IS FINE. THE HIP AND THE ANKLE ARE NOT.

    knee    range [-160, 2], rest bend +1 deg    NEVER pinned, on any frame
    hip     pinned on the two bad frames
    ankle   pinned on the worst frame

★ The knee has 160 degrees of travel from a nearly straight rest — ample for the 58-110 degrees
this dance asks. **The frames that fail, fail at the HIP**, and the foot's 78.6 and 30.3 degrees
follow from a thigh that could not get there plus an ankle at its own wall.

★★ **The two clean frames are clean everywhere**: thigh 1.2 and 3.0, shin 3.6 and 2.9, ankle
within 7 mm, foot 11-13 degrees, nothing pinned. **When the pose is inside the robot's range the
retarget is now essentially exact.** That is the real result of this arc.

### The answer to the stated question

**How well can the unmodified `humanoid.xml` fit Geno mocap?**

    core        torso spine EXACT, pelvis within 11 deg          excellent
    legs        ~2-3 deg where the hip has room                  excellent
    feet        11-13 deg where the chain above is clean         good
    limits      hip on ~half the frames, ankle on the worst      MODEL
    shoulder    2 DOF against [-85,60], pinned 3 frames in 4     MODEL
    pops        155 deg, bistable shoulder                       MODEL + solver

★★★ **The retargeting mathematics is no longer the limiting factor — the robot's joint ranges
are.** Every remaining large error names a specific joint at a specific wall, which is exactly
the input a minimally-tweaked humanoid needs: **widen the shoulder range, widen `hip_x` beyond 40
degrees, and the same code should follow the capture closely.**

---

## ★★★ 41. `humanoid_flex.xml` — RANGES WIDENED, NOTHING ELSE, AND IT CONFIRMS THE DIAGNOSIS

                    humanoid.xml                    humanoid_flex.xml
      thigh      1.2 / 3.0 / 10.2 / 2.3          1.7 / 3.0 / 1.9 / 2.7
      shin       3.6 / 2.9 / 12.3 / 21.2         3.4 / 2.9 / 1.9 / 2.9
      ankle    .007 / .006 / .034 / .127        .008 / .006 / .005 / .009
      foot      11.4 / 13.3 / 78.6 / 30.3       13.1 / 13.8 / 12.9 / 14.3
      pinned      []   []   [h]   [ha]            []   []   []   []
      arm pops         155.0 deg                      140.3 deg

★★★ **NOTHING IS PINNED ON ANY FRAME, AND EVERY LEG NUMBER COLLAPSES TO 1.9-3.4 DEGREES.** The
worst frame went from thigh 10.2 / shin 21.2 / ankle 0.127 m / foot 78.6 to **2.7 / 2.9 / 0.009 /
14.3**. Feet are uniformly 12.9-14.3 degrees.

★★ **The file predicted both outcomes in its own header before the run**, and both held:

    "if a number improves, the RANGE was the constraint"      legs: 21.2 -> 2.9 deg
    "the bistable arm pops will NOT be fixed here"            pops: 155 -> 140, barely moved

★★★ **That is the cleanest confirmation in the whole project.** The legs were range-limited and
are now excellent; the arm pops are STRUCTURAL — two DOF on a shoulder — and no range edit
touches them, exactly as stated in advance.

### The edits, each with its measurement

    shoulder   -85..60    -> -150..150    pinned 3 frames in 4
    elbow     -100..50    -> -150..20     clamped on half the frames; rest bend is 109.5 deg
    hip_x      -30..10    -> -60..45      FORTY degrees of abduction; pinned on both bad frames
    hip_z      -60..35    -> -80..60      widened with hip_x so the three axes cover a rounder region
    ankle      -50..50    -> -75..75      pinned on the worst foot frame

★ **No bodies added or removed, no bone lengths, masses or inertias touched, `qpos0` untouched.**
The 2-DOF shoulder stays 2-DOF deliberately: widening a range separates "could not reach" from
"shaped wrongly", and adding a third axis would confound the two.

### What this says about the next robot

★★ A robot built to match Geno needs **a 3-DOF shoulder** — that is the one remaining structural
limit, and it is worth more than any further range change. Everything else about `humanoid.xml`
now retargets well once it is allowed to move.

---

## ★★ 42. THE FOOT'S CONSTANT 13 DEGREES IS NOT ITS REST OFFSET

Simon: *"more tweaks to the mapping algo will be needed, not only changes to the robot."* Correct
— and the first candidate was the foot, whose error is **12.9 to 14.3 degrees across four very
different poses.**

★★ **A near-constant error across varying inputs is an OFFSET**, not a tracking failure. Same
signature as the 0.57 m constant hand error, which turned out to be the elbow's rest bend, and
the 91-degree twist that turned out to be a reference-pose mismatch.

★ The measurement supported it: **the robot's foot GEOM points 64.9 degrees from the capture's
ankle-to-toe at rest.** A large, real, previously unknown rest difference.

### ★★★ AND APPLYING IT MADE THINGS MUCH WORSE

      foot   13.1 / 13.8 / 12.9 / 14.3   ->   32.5 / 16.2 / 151.7 / 36.9
      ankle  nothing pinned              ->   pinned on EVERY frame

★★★ **So the 64.9 degrees is real, the constant 13 is real, and they are NOT the same quantity.**
The arc between two rest directions is not the offset the foot needs — reverted, and the reason
recorded rather than a third construction guessed at.

★ **This is the sixth time a strong signature has pointed at a wrong cause.** The signature was
right that something systematic is there; it was wrong about what. **Next: isolate the foot on a
bare model** — set the ankle to known angles, measure where the sole points, and derive the
mapping the way the elbow's `bend = rest + qpos` was derived. Every time that has been done it
has settled the question in one run, and every time it has been skipped the guessing has cost
several.

### State after this turn

    humanoid.xml       legs pinned on half the frames, foot 11-79 deg
    humanoid_flex.xml  NOTHING pinned, thigh 1.7-3.0, shin 1.9-3.4, ankle <= 9 mm, foot 12.9-14.3
    arm pops           155 -> 140 deg, structural, unchanged by ranges

★ The foot's 13 degrees is now the **largest remaining error on the flex model that is not
structural**, which makes it the right next target — but by isolation, not by another guess.

---

## ★★★ 43. THE T-POSE HINT PAID OFF — leaf bodies were never AIMED

Simon: *"Look at how the t pose is setup. Maybe there are hints about how to rotate the feet."*

Two errors found, in the order they hid each other.

### ★★ 1. The two rest readings were in DIFFERENT POSES

The foot's rest offset was read from the robot at **`qpos0`** and compared against the capture's
**T-pose** toe. `qpos0` is the folded-arm configuration whose elbow rests at 109.5 degrees —
there is no reason its foot points where a T-posed foot does.

      64.9 deg  ->  32.5 deg      just from reading both in the same pose

★ **Sixth costume of "two references must match in KIND"**, and the reason applying the 64.9 as
an offset made everything worse last turn.

### ★★★ 2. `solveRestPoseFromSource` NEVER AIMED A LEAF

Every task in that solve is a body ORIGIN, so a foot or a hand is PLACED but never pointed:
nothing constrains which way it faces and the IK leaves it wherever damping lands. **A rest
orientation nobody constrained is not a reference at all**, and any offset derived from it is
noise.

★ Fixed with `point_local`: a point along the leaf's own geom, targeted where the capture's next
joint sits relative to it, at the geom's own length.

      32.5 deg  ->  20.3 deg

### The honest result

★★ **The T-pose foundation is much better — 64.9 to 20.3 degrees — and the ANIMATION's foot error
did not move: 12.9-14.4 degrees, unchanged.** Both fixes are correct and neither was the cause of
the 13 degrees.

★ Kept regardless: a rest pose whose leaves are aimed is right independently of what it fixes,
and every twist offset in the project is built against it. **The 20.3 that remains says the ankle's
2 DOF plus the leg chain still cannot put the sole exactly along the capture's toe at T-pose** —
which is itself a model fact worth knowing.

★★★ The constant 13 degrees is now the only unexplained systematic error left on the flex model.
**Three hypotheses have been measured and refuted** (rest offset, pose mismatch, unaimed leaf).
The next step is the one that has settled every hard question in this project and has not yet been
applied here: **isolate the foot on a bare model** — set the ankle to known angles, measure where
the sole points, and derive the relation rather than guessing it.

---

## ★★★ 44. THE ISOLATION SETTLED IT: THE MODEL WAS NEVER THE CONSTRAINT

Four hypotheses about the constant 13-degree foot error had been measured and refuted. The fifth
attempt was the one that has settled every hard question in this project: **ask what the joint
can do, by brute force, before asking why the solver did not do it.**

      ANKLE REACH: the sole swings 69.4 deg from rest over [-50,50] x [-50,50]

      per frame, sweeping BOTH ankle joints over their full ranges:

          FOOT 13.2   best possible  4.7
          FOOT 13.7   best possible  2.7
          FOOT 12.9   best possible  1.2
          FOOT 14.4   best possible  4.3

★★★ **THE ANKLE COULD REACH WITHIN 1.2-4.7 DEGREES AND THE SOLVE ONLY REACHED 12.9-14.4.** Eight
to twelve degrees left unclaimed. **Not the model — the solve.** Every previous hypothesis had
assumed the residual was structural and gone looking for an offset to correct it.

### The cause, and it is a lesson already learned once

**A task is not a scope.** With thigh, shin AND ankle DOF all in one mask, the foot's aim competed
with the ankle POSITION task over the same joints and the solver split the difference. Exactly the
failure of the unmasked hand task that translated the whole robot — met again from the other
side.

★ Fixed by solving the foot **after** the leg, over the ANKLE'S OWN DOF only. The ankle position
is already placed, so nothing competes.

      foot   13.2 / 13.7 / 12.9 / 14.4   ->   9.5 / 8.5 / 7.4 / 10.7
      mean            13.6                        9.0

★★ Legs unchanged (thigh 1.7-3.0, shin 1.8-3.9, ankle within 11 mm). **A third of the gap closed,
and about 5 degrees still separates the result from what the joint can reach** — the same shape
of gap, so the same question applies again: which other task is still sharing DOF with it.

### ★★★ THE GENERAL RULE THIS ARC KEEPS PRODUCING

**Before explaining a residual, measure the best the mechanism could possibly do.** Brute-forcing
two joints over their ranges took twenty lines and one run, and it invalidated four turns of
increasingly elaborate hypotheses about rest offsets and reference poses. **"Is it there to find?"
comes before "why did the solver not find it?"**

---

## ★★★ 45. THE LAST FOOT DEGREES — a target built on where the ankle was SUPPOSED to be

The residual after giving the foot its own solve was ~5 degrees. The sole's target was
`target_ankle + toe_dir * sole_length`, and **the ankle lands 9-13 mm from its target.** On a sole
0.14 m long that offset is about 4 degrees of aim — the size of the residual.

★ Rebuilt on the ACHIEVED ankle position:

      foot   9.5 / 8.5 / 7.4 / 10.7   ->   6.5 / 5.8 / 5.3 / 7.4
      mean          9.0                          6.25
      best possible                        4.7 / 2.7 / 1.2 / 4.3

★ And on the stock robot the worst frame went **58.6 -> 24.5 degrees.**

★★ **Same rule as fitting a rotation against the parent's ACHIEVED orientation rather than its
desired one** — learned for orientations many turns ago and not carried across to positions. **A
target built on where something was SUPPOSED to be inherits every error above it.**

### The foot, start to finish

      unaimed (ankle DOF idle for the whole take)     -
      aimed, sharing the leg's mask                  13.6 deg
      its own solve, ankle DOF only                   9.0
      target from the achieved ankle                  6.25
      what the joint can actually reach               3.2

★ Three fixes, each from measuring rather than guessing, and each a rule this project had already
written down for a different bone. **The remaining 3 degrees is the gap to what the ankle can
physically do**, and the same question applies once more.

### Where the flex model stands

    torso   spine EXACT          pelvis  hip axis <= 11 deg      head  carried
    legs    thigh 1.7-3.0        shin 1.8-4.4                    ankle within 13 mm
    feet    5.3-7.4 deg
    arms    155 -> 140 deg pops, structural: a 2-DOF shoulder

---

## ★★★ 46. WHY THE RIGHT ARM BREAKS AT t = 2.761 s — two different answers on two models

t = 2.761 s at 60 fps is **frame 166**. Printed in full, with neighbours so a discontinuity would
be visible:

    humanoid.xml
      f164  upper err 27.0   shoulder ( -85.0,  -85.0)  BOTH AT THE CORNER
      f166  upper err 29.6   shoulder ( -85.0,  -85.0)  best possible 29.6
      f168  upper err 29.6   shoulder ( -85.0,  -85.0)

    humanoid_flex.xml
      f166  upper err 15.5   shoulder (-150.0,  -68.9)  best possible  6.2

★ Reach is 0.470 m against a 0.624 m span, so it is not a reach problem, and the arm is stuck
across five consecutive frames — **not a pop, a WALL.**

### ★★★ TWO DIFFERENT DIAGNOSES, AND THE BRUTE-FORCE SEPARATES THEM

★★ **On stock `humanoid.xml`: err 29.6, best possible 29.6.** The solver is doing exactly the best
the model allows. **A 2-DOF shoulder with range [-85,60] physically cannot point the arm where
this dance asks** — two diagonal axes sweep a SURFACE of directions, and this direction is not on
it. No solver change reaches this.

★★★ **On `humanoid_flex.xml`: err 15.5, best possible 6.2.** Widening the range put the wanted
direction within 6.2 degrees — **and the solve leaves 9.3 of that unclaimed.** `shoulder1` sits
pinned at -150 while the sweep finds a better pair elsewhere on the surface.

### The solver bug this exposes

★★ **The IK walks into a corner and cannot back out.** Step-scaling zeroes the component pushing
into a wall, so once a joint is at its limit the solve loses that direction entirely and settles
in a local minimum — even when a better solution exists a short distance back along the surface.

★ **This is the same mechanism as the 140-degree pops**: a limit is a cliff, and this solver both
sticks to cliffs and jumps between them. Fixing it fixes both.

★ Candidate: when a joint is clamped and the residual is still large, take a step that RELEASES it
— a random restart, or a null-space move along the redundant direction. GMR avoids the situation
entirely by never proposing an infeasible step.

### ★★ THE PATTERN, THIRD TIME THIS SESSION

    ankle    err 13.6, best  3.2      solver, not model
    foot     err  9.0, best  3.2      solver, not model
    shoulder err 15.5, best  6.2      solver, not model (on flex)
    shoulder err 29.6, best 29.6      MODEL, not solver (on stock)

★★★ **The brute-force "best possible" is the single most useful instrument added in this arc.**
It answers "is it there to find?" in twenty lines, and it has now been right about four different
joints where argument was wrong about three of them.
