# ★★★ THE RETARGET AS ONE OPTIMISATION — the formulation we should have started from

## What we have now, stated honestly

Six mechanisms, each with its own targets, weights and scope:

    direction pairs (torso, pelvis)      two directions -> a rotation
    twist offsets (spine, unmapped)      a rotation, converted through two rest poses
    per-body IK (multi-DOF bodies)       one position target, masked
    whole-chain IK (limbs)               two position targets, masked
    hinge flexion (knees, elbows)        a scalar, offset by the rest bend
    ankle aim (feet)                     one point target, masked

★★ Each was added because the one before it could not express something. **They run
SEQUENTIALLY, each masked to a few DOF, and every later solve inherits the errors of the earlier
ones.** The measurements say so directly:

    the foot's target built on the ankle's INTENDED position was 4 degrees wrong because the
    ankle landed 11 mm away

★★★ And every one of them decomposes a pose into concepts the ROBOT does not have — direction,
twist, bend plane, swivel. **The robot has a configuration `q` and body transforms. Nothing
else.**

---

## ★★★ THE PROBLEM, WRITTEN ONCE

Find the configuration `q` minimising

    E(q) =  Σ_b Σ_k  w_b ‖ T_b(q)·s_bk  −  ŷ_bk ‖²        SHAPE      what the robot looks like
          + λ_lim Σ_j barrier(q_j)                          LIMITS     softly, not as a cliff
          + λ_smo ‖ q ⊖ q_prev ‖²                           SMOOTH     continuity across frames

where

    T_b(q)   the world transform of body b, from forward kinematics
    s_bk     the k-th SAMPLE POINT on body b, in the body's own frame
    ŷ_bk     where that sample should be, from the capture
    q ⊖ q_prev   configuration difference, quaternion-aware for the free root

★ That is a nonlinear least-squares problem. Gauss-Newton with the Jacobian we already have:

    J_bk = ∂(T_b·s_bk)/∂q      = jacBody(b, point = s_bk)      ← `IkTask.point_local` IS this
    (JᵀWJ + λI + λ_lim H + λ_smo I) δq = −Jᵀ W r  −  λ_smo (q ⊖ q_prev)

---

## ★★★ WHY SAMPLE POINTS ON BODIES SUBSUME EVERYTHING

This is the part worth seeing clearly.

★★ **One point per body gives POSITION.** Two points give position + DIRECTION. **Three
non-collinear points give position + direction + TWIST.**

    every mechanism in the list above is a special case of "match some points"

    aim a bone          = match the child's origin                   1 extra point
    choose a twist      = match a point OFF the bone axis            1 more
    bend plane          = falls out of the child's points
    swivel              = falls out, no special case
    orientation task    = three points, no separate rotation rows

★★★ **AND THERE IS NO TWIST MECHANISM AT ALL.** The twist offsets, the rest-pose algebra, the
`inv(parent_twist)` chain, the six reference-pose bugs they caused — **all of it exists to carry
information that three points carry for free, in the same units as everything else.**

★★ **Sample points come from the GEOMS**, which is Simon's insight and it is the right one: a
capsule's endpoints and its radius describe the body's SHAPE, and matching shape is what
"looks like the same pose" actually means. A joint-position match asks the robot's skeleton to be
the human's skeleton, which it is not and cannot be. A shape match asks it to LOOK the same,
which is the actual goal.

★ Length mismatch handled naturally: sample at the same FRACTIONAL positions along each body and
scale by the limb's own length ratio. Nothing is over-constrained because nothing demands equal
lengths — the residual just cannot reach zero, which is honest.

---

## ★★★ WHY SOFT LIMITS FIX BOTH REMAINING DEFECTS

Measured this session:

    stuck:  shoulder pinned at -150, err 15.5, BEST POSSIBLE 6.2      the solver cannot back out
    pops:   140 degrees in one frame at upper_arm_left                the solver jumps walls

★★ **Both are the same bug: a hard limit is a CLIFF.** Clamping (or zeroing the offending step
component) removes that direction from the solve entirely — the configuration sticks to the wall
and the gradient that would walk it back along the surface is gone.

★★★ A barrier makes the wall a SLOPE:

    barrier(q) = 1/(q − lo)² + 1/(hi − q)²         or  −log(q−lo) − log(hi−q)

**The solver feels the wall before reaching it, slides ALONG it, and can always back out.** Two
consequences, both of which we need:

  1. **No sticking** — there is always a descent direction, so a better point on the surface is
     reachable.
  2. **No jumping** — the barrier is continuous in `q`, so a small change in target gives a small
     change in solution. **That is what "smooth" means, and it cannot be achieved by any amount
     of clamping.**

---

## ★★★ WHY ONE SOLVE, NOT SIX

    the foot's target was 4 degrees wrong because it was built on the ankle's INTENDED position

★★ In a single solve there are no intended positions to build on — **every residual is measured
against where things ACTUALLY are, simultaneously.** Errors cannot compound because nothing is
downstream of anything.

★ It also deletes the weights we have been hand-tuning: end-effector primary at 1.0, middle joint
at 0.2, foot at 0.5, elbow at 0.2. **Those numbers exist to arbitrate between solves that should
never have been separate.** A per-BODY weight (a foot matters more than a forearm) is a real
modelling choice; a per-TASK weight to stop two solves fighting is an artefact.

---

## The plan

    1. sample points from geoms, 3 per body, and the human's corresponding points
    2. one Gauss-Newton solve over ALL dof, all bodies, every frame
    3. soft limit barrier instead of clamping
    4. temporal term toward q_prev
    5. measure against the SAME instruments: per-bone angles, best-possible sweeps, worst-case
       jitter over the whole clip

★★ **Every one of those instruments already exists**, and three of them were built specifically
because a previous formulation hid something. They are the reason this can be attempted as one
change rather than six.

---

# ★★★ FIRST RESULT — one solve, 31 points, competitive with six hand-tuned mechanisms

      WHOLE BODY: 31 sample points over 17 bodies

      f 40: arm  4.8  fore 28.3  thigh 4.8  shin 0.9   iters 14
      f166: arm 10.4  fore 20.9  thigh 1.9  shin 4.8   iters 20
      f320: arm 18.1  fore  7.9  thigh 6.0  shin 2.1   iters 21
      f460: arm  9.6  fore 19.5  thigh 5.6  shin 1.5   iters 14

★★★ **NO MASKS, NO SEQUENCE, NO PER-TASK WEIGHTS, NO TWIST OFFSETS, NO REST POSE, NO AIM RULE, NO
BEND-PLANE RULE, NO HINGE FLEXION FORMULA.** Thirty-one point residuals, soft limits, a posture
term, and 14-21 Gauss-Newton iterations.

### Against the six-mechanism pipeline on the same model

    arm at frame 166      15.5 deg  ->  10.4      BETTER, and 166 is its worst frame
    shin                  1.9-4.2   ->  0.9-4.8   comparable
    thigh                 1.7-3.0   ->  1.9-6.0   slightly worse
    forearm               not separately reported  ->  7.9-28.3   the new weak spot

★★ **A first attempt, with no tuning at all, matches six mechanisms that took forty sections to
build — and beats them where they were weakest.** The arm's worst frame is the one that motivated
`humanoid_flex.xml`.

### ★ Why the forearm is the weak spot, and what it says

The forearm is a chain link with ONE child, so it gets **two** sample points — position and
direction, but **no twist**. Every body with two or more children gets three or more and is
better constrained. **The formulation predicts exactly which bones will be weak, from the point
count alone**, which no previous mechanism could do.

★ The fix is in the formulation, not around it: **sample the GEOMS** — a capsule's two endpoints
plus an off-axis point on its surface — instead of only child origins. That is Simon's original
suggestion, and the measurement now says precisely why it matters and for which bones.

### What this replaces

    direction pairs      the torso is just a body with three sample points
    twist offsets        three points carry twist; no rest-pose algebra, no inv(parent_twist)
    per-body IK          one solve
    whole-chain IK       one solve
    hinge flexion        the hinge is a DOF like any other; `bend = rest + qpos` never arises
    ankle aim            the foot is a body with sample points like every other

★★★ **Six mechanisms, six sets of weights, and at least eight of this project's bugs live in the
seams between them.** The seams are what the single objective removes.

---

# ★★★ THE NEXT PIECE: CORRESPONDENCE BY T-POSE PROXIMITY

Simon: *"place points at the same world place close to the surfaces as they are aligned in
t-poses."* This is the right next move and it is worth stating precisely why.

## What it replaces

Today every sample point is tied to a JOINT through `lafan_to_humanoid` — a hand-written table
of sixteen name pairs. **Proximity needs no table:** put both figures in the T-pose, and for each
sample point on the robot's surface, store the offset to the NEAREST point on the human, in that
human bone's frame. Per frame, the target is a rigid transform of the stored offset. No search at
runtime, no table, no semantic assumption.

## ★★★ WHY IT SOLVES THE FOREARM SPECIFICALLY

    thigh   1.9-6.0 deg      3+ samples (a body with two or more children)
    shin    0.9-4.8 deg      3+ samples
    forearm 7.9-28.3 deg     TWO samples, and they are COLLINEAR

★★ A chain link has one child, so child-origin sampling gives it two points **on the same line** —
position and direction, and **nothing about twist**. Its error is 4x the bodies that have three.

★★★ **Surface points are not collinear with the bone.** Two points on opposite sides of a capsule,
plus the ends, pin the twist directly — and proximity is what gives them meaningful targets,
because a point on the side of the robot's forearm corresponds to a point on the side of the
human's.

★ **The formulation predicted which bones would be weak, from the sample count alone**, before
any of this was measured. No previous mechanism could do that.

## Status

★ Prototyped this turn: sample four points per geom (two ends, two off-axis), nearest-joint
correspondence at the solved T-pose, offset stored in the human joint's frame. **It panics inside
the sample construction and was reverted rather than left half-working.** The working
child-origin version stands at:

      f 40: arm  4.8  fore 28.3  thigh 4.8  shin 0.9   iters 14
      f166: arm 10.4  fore 20.9  thigh 1.9  shin 4.8   iters 20
      f320: arm 18.1  fore  7.9  thigh 6.0  shin 2.1   iters 21
      f460: arm  9.6  fore 19.5  thigh 5.6  shin 1.5   iters 14

## Other things worth trying, in order of expected value

1. ★★ **Off-axis samples WITHOUT proximity** — keep the joint table, but add two points
   perpendicular to each bone, corresponding to the same offsets on the human's bone. Half the
   benefit for a fraction of the work, and it isolates whether twist or correspondence is what
   the forearm needs.
2. ★ **Per-body weights that mean something**: a foot and a hand matter more than a forearm's
   midpoint. Currently 1.0 and 0.7 chosen arbitrarily.
3. ★ **Scale correspondence by limb length ratio** so a long robot arm is not asked to put its
   elbow where a short human elbow is — the residual should measure SHAPE difference, not size
   difference.
4. ★★ **Measure the whole clip with the existing jitter instrument.** The soft barrier and
   posture term are in; **their entire purpose is the 140-degree pops**, and that number has not
   been re-measured on this solver.

---

# ★★★ THE BARRIER WORKS — worst pop 155 -> 67 degrees

      POPS (hard clamp):              worst 122.1 deg at pelvis          frame 206
      POPS (soft barrier + posture):  worst  67.3 deg at lower_arm_left

      for comparison, the six-mechanism pipeline:  155.0 cold, 148.5 warm-started

★★★ **THE FIRST THING THAT HAS EVER MOVED THAT NUMBER.** Warm-starting took 155 to 148. Step
scaling took 157 to 157. **The barrier takes 122 to 67**, and the point-cloud solve takes 155 to
122 on its own.

    six mechanisms, hard clamp, cold          155.0
    six mechanisms, hard clamp, warm start    148.5
    six mechanisms, step-scaled limits        157.4      no effect
    ONE point-cloud solve, hard clamp         122.1
    ONE point-cloud solve, SOFT barrier        67.3      57% below where this started

## Why it works, restated now that it is measured

★★ A hard limit **removes a direction from the solve.** The configuration sticks to the wall, and
when the target moves past a corner the solver has to jump to a different feasible piece — a
discontinuous map from target to solution, which is exactly what a pop is.

★★★ A barrier keeps every direction available: the solver **feels the wall before reaching it and
slides ALONG it.** The map becomes continuous, and continuity is not something clamping can
approximate — **it is a property of the objective, not of the search.**

★ The posture term contributes too, but note which measurement isolates what: warm-starting alone
(same objective, different starting point) moved 155 to 148. **The barrier changed the objective,
and that is where the factor of two came from.**

## Where the formulation stands

    per-bone accuracy    arm 4.8-18.1, forearm 7.9-28.3, thigh 1.9-6.0, shin 0.9-4.8
    worst pop            67.3 deg, down from 155
    mechanisms           ONE, against six
    hand-tuned weights   two (1.0 and 0.7), against six sets
    iterations           14-21 per frame

★★ **The three remaining leads are all inside the formulation**, which is the point of having
one: off-axis samples for the forearm's missing twist, T-pose proximity for correspondence
without a table, and a length-ratio scale so the residual measures shape rather than size.

---

# ★★★ OFF-AXIS SAMPLES: THE PREDICTION WAS WRONG

The formulation predicted the forearm's error from its sample count — two points, collinear,
therefore no twist — and predicted that two off-axis points would fix it. **Implemented, and it
does not.**

                     31 points                 61 points
      forearm   28.3/20.9/7.9/19.5   ->   28.8/20.1/6.8/18.6    mean 19.15 -> 18.58
      arm        4.8/10.4/18.1/9.6   ->    6.6/16.4/15.0/5.3    mixed
      pops (soft)          67.3      ->          70.8           slightly worse

★★ **Doubling the sample count moved the forearm by half a degree.** The diagnosis — a chain link
gets two collinear points and therefore no twist — was correct as arithmetic and wrong as an
explanation of the error.

### What that leaves

★ The off-axis targets are built from the capture's own joint ROTATION (`rot[j]`), carried by the
human bone's current frame. **If a BVH forearm's rotation does not itself carry reliable twist —
and mocap forearm roll is notoriously unreliable — then a twist-carrying sample has nothing to
carry.** That is testable: compare the capture's forearm twist between consecutive frames against
its bone direction change, and see whether it is signal or noise.

★★ **Before adding a mechanism to extract twist, check that the twist EXISTS in the source.** The
same question the project should have asked about the shoulder before widening its range — and
the brute-force "best possible" instrument is exactly the shape of tool for it.

### Kept or reverted

★ Kept: the samples are principled, the cost is 30 more residuals in a solve that runs in 13-18
iterations, and the forearm is marginally better. **But the prediction is recorded as refuted** —
the formulation is not vindicated by this, and the next person should not read the sample-count
argument as established.

### The standing result

      arm 5.3-16.4    forearm 6.8-28.8    thigh 2.5-6.7    shin 1.3-6.2
      worst pop 70.8 deg, against 155 for the six-mechanism pipeline
      ONE solve, 61 residuals, 13-18 iterations, two hand-chosen weights

---

# ★★★ THE TWIST IS IN THE SOURCE, LARGE AND SMOOTH — so that hypothesis dies too

      forearm:    mean 124.7 deg   worst frame-to-frame jump 14.8
      upper arm:  mean 149.4       worst jump 10.3
      shin:       mean 157.9       worst jump 29.7

★ Measured as: the rotation the BVH states, minus the rotation implied by the bone's DIRECTION
alone. What remains is rotation ABOUT the bone.

★★ **The large mean is a CONVENTION offset**, not motion — a constant difference between the
BVH's bone axis and the one assumed here. **The signal is the variation**, and the worst
frame-to-frame jump of 10-30 degrees says the twist moves smoothly and by real amounts.

★★★ **So the source's twist is neither absent nor noisy**, and "mocap forearm roll is
unreliable" is refuted. It joins the list.

## Where that leaves the forearm

    forearm 6.8-28.8 deg, and every explanation offered so far has been measured and refuted

    "two collinear samples, so no twist"      off-axis samples moved it 0.5 deg
    "the source's twist is unreliable"        it is large and smooth
    "the robot cannot reach"                  NOT YET TESTED

★★★ **The one instrument that has settled every hard question in this project has not been
pointed at the forearm: the brute-force best-possible sweep.** For the ankle it found the model
was innocent and the solver was leaving 8-12 degrees; for the shoulder it found the opposite on
stock and the same on flex. **Two DOF is a 2-parameter sweep and takes twenty lines.**

★ Do that before another hypothesis. The pattern across this whole project is that argument has
been wrong roughly two times in three, and the sweep has been right every time.

## Standing result

      arm 5.3-16.4   forearm 6.8-28.8   thigh 2.5-6.7   shin 1.3-6.2
      worst pop 70.8 deg (155 for the six-mechanism pipeline)
      ONE solve, 61 residuals, 13-18 iterations, two hand-chosen weights

---

# ★★★ THE FOREARM: THE MODEL IS INNOCENT, AND THE SINGLE OBJECTIVE IS TRADING IT AWAY

Sweeping all THREE dof that move the forearm — the shoulder's two and the elbow's one:

      f 40: fore 28.8   best possible 1.9
      f166: fore 20.1   best possible 1.1
      f320: fore  6.8   best possible 1.6
      f460: fore 18.6   best possible 2.8

★★★ **THE FOREARM CAN REACH WITHIN 1.1-2.8 DEGREES AND THE SOLVE GETS 6.8-28.8.** Five to
twenty-seven degrees left on the table. **Fourth explanation refuted, and the sweep is right
again** — as it has been every time it has been used, against argument that has been wrong about
two times in three.

    "two collinear samples, so no twist"     off-axis samples moved it 0.5 deg
    "the source's twist is unreliable"       it is large and smooth
    "the robot cannot reach"                 it reaches within 1.1-2.8 deg
    the solver is trading it away            <- what remains

## ★★★ THIS IS THE COST OF ONE GLOBAL SOLVE, MEASURED

**A single least-squares minimises the SUM.** It will happily give up 27 degrees on a forearm to
gain a little on several other bodies, because that lowers the total. The six-mechanism pipeline
could not do this — each limb had its own solve and could not be sacrificed for another — and
that is the one genuine advantage it had.

★ And the weights that decide the trade are **1.0, 0.7 and 0.5, chosen arbitrarily**. Section
"why one solve, not six" argued that per-task weights are an artefact of separate solves; that
was right about arbitration between stages and **wrong to imply the unified objective needs no
weights at all.** It needs FEWER weights, and they now mean something real: how much each part of
the body matters.

## What to try next, and why in this order

1. ★★★ **Weight by what the bone is FOR.** A hand and a foot place the body; a forearm's midpoint
   is a shape detail. Currently a body origin at 1.0 outranks a forearm's own samples at 0.5-0.7
   — **exactly backwards for the one bone that is failing.**
2. ★★ **Normalise per body, not per sample.** A body with four samples currently exerts four
   times the pull of a body with one, so bodies are weighted by an accident of their child count.
3. ★ **Then re-sweep.** The gap to best-possible is the number to watch; it is now the project's
   single most informative measurement.

## Standing result

      arm 5.3-16.4   forearm 6.8-28.8 (best 1.1-2.8)   thigh 2.5-6.7   shin 1.3-6.2
      worst pop 70.8 deg, against 155 for the six-mechanism pipeline
      ONE solve, 61 residuals, 13-18 iterations

---

# ★★★ SIMON'S PROOF: THE ARM IS EXACTLY DETERMINED BY TWO POSITIONS

*"Elbow and hand positions should still be what matters for deciding how to put the arm, because
the elbow is a hinge."*

That is a proof, not a preference:

    shoulder 2 DOF + elbow hinge 1 DOF  =  3
    the elbow's POSITION pins the upper arm's 2      (a direction on a sphere)
    the hand's POSITION then pins the hinge          (1 along the remaining arc)

★★★ **An off-axis sample on an arm adds a residual for a rotation that is ALREADY FIXED.** It
cannot inform the solve; it can only compete with constraints that were exact.

### The general rule this gives

★★ A child-origin sample constrains TWO of a body's DOF — the bone's direction. **Only a body
with THREE or more DOF has a twist left over for an off-axis sample to determine.** A hip does. A
shoulder and an elbow do not.

★ That is a rule the formulation can apply itself, from `body_dof_num`, with no per-bone
knowledge — which is what a good formulation should be able to do.

### Measured

                    61 samples          43 samples (off-axis only where DOF >= 3)
      arm      6.6/16.4/15.0/5.3   ->   2.7/13.1/16.7/5.2     mean 10.8 -> 9.4
      forearm 28.8/20.1/ 6.8/18.6  ->  28.6/21.8/ 8.3/18.4    unchanged
      pops                  70.8   ->  85.6                   WORSE
      thigh    5.1/2.5/5.9/6.7     ->   4.2/2.6/5.0/6.7       slightly better

★★ **The arm improves and the pops get worse.** Fewer residuals means fewer things holding the
configuration still between frames — the redundant samples were doing nothing for accuracy and
something real for continuity. **That is a genuine trade, not a mistake in either direction**, and
it says the posture term is currently too weak to carry continuity on its own.

★ Kept: the accuracy argument is a proof and the continuity loss has a named, principled fix
(raise `posture_weight`, which is 0.02 and was never tuned).

### ★★★ And the forearm did not move

    forearm 18.4-28.6 deg, best possible 1.1-2.8

Its elbow-hinge and hand positions are BOTH sampled, and it is still 10-27 degrees from what the
joint can reach. **So the remaining cause is the trade** — a single least-squares minimising the
sum will spend a forearm to buy several other bodies. That is the next thing to attack, and the
lever is the weights, which currently encode nothing but child count.

---

# ★★★ WEIGHTS THAT MEAN SOMETHING — best result of the project

Three changes, each removing an arbitrary number and replacing it with a modelling statement:

    1. NORMALISE PER BODY     a body with four samples was pulling four times as hard as a body
                              with one, so influence was set by an accident of CHILD COUNT
    2. EXTREMITIES x2         a hand and a foot PLACE the body; a forearm's midpoint is shape
                              detail. The old 1.0 / 0.7 encoded neither.
    3. posture 0.02 -> 0.15   continuity has to come from the term that is FOR continuity, not
                              from surplus accuracy residuals

                       before            after
      arm       2.7/13.1/16.7/5.2   4.9/ 3.8/12.0/14.2    mean 9.4 -> 8.7
      forearm  28.6/21.8/ 8.3/18.4  26.1/21.9/12.4/17.1   unchanged
      thigh     4.2/ 2.6/ 5.0/ 6.7   4.2/ 2.3/ 5.2/ 4.3   mean 4.6 -> 4.0
      shin      1.0/ 5.8/ 2.3/ 2.5   0.2/ 2.9/ 1.1/ 0.4   mean 2.9 -> 1.15
      POPS               85.6              64.9           lowest yet

★★★ **THE SHIN IS NOW WITHIN HALF A DEGREE ON TWO FRAMES**, and the worst pop is 64.9 against
155 for the six-mechanism pipeline. **Every number improved or held except the forearm.**

## The whole arc of the pop number

    six mechanisms, hard clamp, cold           155.0
    six mechanisms, warm started               148.5
    six mechanisms, step-scaled limits         157.4    no effect
    ONE point-cloud solve, hard clamp          122.1
    ONE solve, soft barrier                     70.8
    redundant samples removed                   85.6    accuracy up, continuity down
    per-body weights + posture 0.15             64.9

★★ Note the shape of that: **every gain came from changing the OBJECTIVE**, and the one step that
changed only the search (warm start) moved it by 7 degrees out of 155.

## What remains

★ **The forearm, alone, at 12-26 degrees against a best possible of 1.1-2.8.** Everything else in
the body is now within a few degrees. It is the last bone whose error is the solver's rather than
the model's, and the weights that would fix it are the ones that just fixed everything else —
**a forearm's own samples are still normalised down by having a child, exactly like every other
link, while its error is four times theirs.**

★★ Worth trying: weight a sample by how much of the body's LENGTH it represents, or simply give
the forearm the extremity treatment and see whether the sum trades it back. **Both are one line
and the best-possible gap says immediately which won.**

---

# ★★ WIRING THE POINT-CLOUD SOLVE INTO THE EXAMPLE — attempted, reverted

★★★ **THE SHIPPED EXAMPLE STILL RUNS THE SIX-MECHANISM PIPELINE.** Every number in this document
— shin 1.15, arm 8.7, pop 64.9 — is measured in `robot_mjcf.zig`'s WHOLE BODY test and **does
not describe what the device shows.** That is the divergence this project has closed five times
and has now opened a sixth.

★ The swap was written: `PointSample`, `buildPointSamples` with per-body normalisation and the
DOF>=3 rule for off-axis points, and a single 80-iteration solve with the barrier and posture
term. It replaced `poseFromRetarget` plus all four `solveArmChain` calls.

★★ **The replacement removed a closing brace**: the block being replaced sat at brace depth 2, so
cutting it left `poseRobot` unbalanced. Caught by counting braces per line rather than by reading
the compiler's message, which pointed at a doc comment 120 lines later — **a structural edit
reports its error wherever the parser finally gives up, not where the damage is.**

★ Reverted from the snapshot rather than patched blind, so what ships is the last known-good
pipeline. **The example builds, smoke-tests and gates.**

## To finish it, precisely

1. `PointSample` + `buildPointSamples` are correct as written — reuse them verbatim.
2. Replace ONLY the `poseFromRetarget` call, leaving the surrounding scope intact, then delete
   the four `solveArmChain` calls in a SEPARATE edit.
3. **Count braces before and after each edit**, or make the change with `str_replace` on a block
   whose first and last lines are at the same depth.
4. Then re-run the device: the numbers above are what it should show.

---

# ★★★ THE POINT-CLOUD SOLVE NOW SHIPS

The example calls `solvePointCloud` and nothing else. **All six mechanisms are deleted from it:**

    poseFromRetarget call      -> solvePointCloud
    four solveArmChain calls   -> gone (each was a masked solve built on the last stage's INTENT)
    solveArmChain + ArmNames   -> deleted, ~90 lines
    buildCorePairs             -> deleted; two directions is three sample points
    findJoint                  -> deleted with its last caller

★ What the device shows should now be what the harness measures: shin ~1.15 deg, thigh ~4.0, arm
~8.7, worst single-frame pop 64.9 against 155.

## ★★ THE EDIT DISCIPLINE THAT MADE IT WORK THIS TIME

Last attempt cut a block spanning brace depth 2 and left `poseRobot` unbalanced; the compiler
reported a doc comment 120 lines later. This time:

    1. append new top-level code first, check depth == 0
    2. replace ONLY the one balanced call, check depth == 0
    3. delete the four limb calls in a SEPARATE edit, check depth == 0
    4. delete each dead helper one at a time, checking after each

★★★ **A brace-depth count after every structural edit, before compiling.** Six edits, six checks,
and the one failure it did catch (`PointSample` deleted along with a helper that followed it) was
obvious immediately instead of being read out of a parser error in an unrelated place.

## Where the project stands

    ONE solve, ~43 sample points, 13-36 Gauss-Newton iterations per frame
    torso, pelvis, head, legs, feet, arms — all from the same objective
    soft limit barrier (a wall is a slope), posture term (continuity is a TERM, not a start)
    two modelling weights: extremities count double, bodies normalised by sample count

    forearm 12-26 deg against a best possible of 1.1-2.8 — the one bone still being traded away

---

# ★★★ THE ROBOT STOOD IN ITS REST POSE — a task array sized PER BODY, not per sample

    s.robot_tasks = try gpa.alloc(z.robot.IkTask, body_count);      17 entries
    the point cloud produces                                        43 samples
    const total = @min(sample_count, tasks.len)                     -> 17

★★★ **TWO THIRDS OF THE ROBOT HAD NO TARGETS AND SIMPLY STAYED AT REST.** The first 17 samples
are the upper body in body order, so the torso moved a little and everything below it did not.

★★ The `@min` made it a **silent clamp instead of a crash.** That line was written when one task
per body was the only shape a task set could have; the point cloud puts up to FOUR samples on a
body and nothing re-examined the allocation.

★ Fixed: 256 tasks, and the clamp documented as something that must never bind.

## ★★ THE LESSON, WHICH THIS PROJECT HAS NOW LEARNED IN FIVE COSTUMES

    a vacuous rest check          measured algebra, not the code
    a phantom edit                measured a change that never applied
    a duplicated loop             measured a different program
    identity twists in a test     measured a stub
    a body-sized task array       measured a THIRD of the robot

★★★ **Every one was a quiet truncation of what was being measured or solved, and every one
produced plausible output.** `@min` against a capacity, `orelse continue`, a `catch return` — each
turns "this does not fit" into "this is fine". **When a whole subsystem does nothing, look for the
place where its inputs were silently dropped before looking for a bug in its mathematics.**

★ The three sizes now to keep in step: `robot_samples` (256), `robot_tasks` (256), and
`ikScratchSize(nv)`. **A sample count that exceeds any of them should be loud.**

---

# ★★★ THE TORSO WAS BEING SQUEEZED — an impossible constraint, answered by skewing

Simon, from the device: *"torso orientation should try to fit shoulders, not get squeezed. It is
too large to fit so it has to be skewed at an angle weirdly."*

★★ A child-origin sample targets the human's JOINT POSITION, which asks the robot's bone to span
the human's distance. **The robot's torso is wider than Geno's**, so its two shoulder samples are
asked to sit closer together than they physically can. The solve answers an impossible constraint
the only way least squares can: **it skews until both are equally wrong.**

★ Fix: direction from the capture, length from the robot. The target is then exactly reachable
and the residual measures SHAPE rather than SIZE — the rule every limb chain in this project
ended up needing, and the point cloud was built without it.

## ★★★ BUT ONLY FOR THE TORSO, AND THE MEASUREMENT SAYS WHY

                        all bones          torso only
      shin      1.15 ->  2.6              0.2/3.0/1.1/0.4   unchanged
      thigh      4.0 ->  4.7              4.2/2.3/5.1/4.2   unchanged
      arm        8.7 ->  9.75             4.9/3.7/11.9/14.1 unchanged
      pops      64.9 -> 76.9              64.2              marginally better

★★★ **Applied to every bone it is WORSE across the board.** A limb's scaled joint position is
already a good absolute target, and rebuilding each bone from its parent turns independent
targets into a CHAIN whose errors accumulate — the same failure as the six sequential mechanisms,
reintroduced inside the objective.

★★ **The torso is the one place where the size mismatch ITSELF is the constraint**, so it is the
one place the substitution pays. Scoped there: no cost anywhere, and the skew has nothing left to
skew for.

★ Note what made this decidable: Simon saw the skew on the device and **nothing in the harness
measures torso orientation**. The metrics could only say "the limbs do not get worse" — which was
enough to ship it, but the observation itself came from a pair of eyes. **Six instruments, and
the one that caught this was a screenshot.**

---

# ★★★ THE SHOULDER AXIS AS A RELATIVE CONSTRAINT — right idea, wrong magnitude

Simon: *"the shoulder-to-shoulder axis from the source, could it be used to constrain the
shoulder-to-shoulder axis in the result?"*

## ★★ The ambiguity is real, and this names it

**Two independent shoulder targets have a FLAT DIRECTION in the objective.** Pushing the left
shoulder forward and the right one back costs exactly what rotating correctly costs, so the
solver has no gradient distinguishing them and settles wherever damping lands — **which is the
clickiness.** A residual on the DIFFERENCE has no such direction: it is a rotation statement
rather than two position statements that happen to imply one.

★ Implemented as `IkTask.relative_to`: residual `(p_a − p_b) − target_delta`, Jacobian
`J_a − J_b`. Everything downstream is unchanged, because a residual is a residual.

## ★★★ MEASURED: WORSE, BOTH WAYS ROUND

      baseline (two absolute shoulder samples)   arm  4.9/ 3.7/11.9/14.1   pops 64.2
      axis INSTEAD of the two                    arm 10.2/31.3/25.2/ 9.8   pops 88.9
      axis IN ADDITION to the two                arm 10.3/31.1/25.4/ 9.6   pops 88.9

★★ **Identical to the decimal whether the two samples were kept or dropped.** That is the tell:
the axis residual DOMINATES either way. At weight 2.0 on a difference of ~0.3 m it outweighs the
position samples it was meant to disambiguate, and the torso follows the axis at the expense of
everything hanging off it.

★★★ **A constraint that dominates is a different constraint from the one intended.** The flat
direction needed a nudge; it was given a command.

## Retained

★ `relative_to` stays in `ikStep`, tested and off by default — it is a genuinely new capability
and the right shape for this problem. **The next attempt should sweep the weight downward from
0.1 rather than starting at 2.0**, and watch the pops, which is the number the clickiness
actually shows up in.

★ Standing result unchanged: arm 3.7-14.1, forearm 12.2-26.1 (best 1.1-2.8), thigh 2.3-5.1,
shin 0.2-3.0, worst pop 64.2.

---

# ★★★ THE SHOULDER AXIS **WORKS** — I MEASURED THE WRONG QUANTITY AND USED A WEIGHT 20x TOO BIG

Simon: *"are we sure it is a worse result visually? Maybe it still looks better and smoother?"*

★★★ **No, I was not sure, and it was not worse.** The verdict came from arm and leg direction
errors and a whole-body pop maximum. **Nothing measured the torso** — the only thing the
constraint is about. **A change judged on quantities it was not aimed at has not been judged.**

## Measured on the torso's OWN shoulder axis

      weight    torso axis per frame            mean    pops    arm mean
      0.00      12.4 / 48.8 / 36.8 / 13.0       27.8    64.2      8.6
      0.10      10.9 / 40.2 / 29.3 / 10.7       22.8    65.9      8.1
      2.00      dominates everything             -      88.9      -

★★ **At a nudge: the torso axis is 18% better, the arm is better too, the forearm is unchanged,
the legs are marginally worse, and the pops do not move.** A net win, on exactly the defect that
was observed from the device.

★★★ **The idea was right and the magnitude was wrong.** At 2.0 on a 0.3 m difference the axis
outweighed the position samples it was meant to disambiguate — a constraint that dominates is a
different constraint from the one intended. **The flat direction needed a nudge, not a command**,
and one weight sweep separated the two.

## ★★★ THE LESSON, AND IT IS ABOUT ME NOT THE CODE

    "measured worse"  ->  measured on the arm, the leg, and the whole-body pop maximum
    the change        ->  was about the torso

★★ Six instruments in this project and **not one of them measured torso orientation** until this
turn — even though the torso was the first thing solved and the thing Simon has now flagged
twice from screenshots. **A metric suite grows around the bugs you have already found**, and its
blind spots are exactly where the next ones live.

★ Shipped at 0.1 in both the harness and the example, with the weight sweep kept in the test so
the choice stays visible.

---

# ★★★ THE 10 cm OFFSET: THE ARMS ARE 25% TOO LONG, AND THE FREE ROOT PAYS FOR IT

Simon: *"globally the robot has a 10 cm offset behind geno, and the direction depends on where we
are in the anim."*

★★ **A CONSTANT offset would be a placement bug. A VARYING one is the free root settling where
the total residual is least** — if the robot cannot put all its joints where the capture's are,
the least squares slides the whole body to split the difference, and which way it slides depends
on the pose. So the question is whether the robot really cannot fit.

## Measured, bone by bone, at the current scale

      thigh      0.98        shin       1.08        foot       1.01     legs MATCH
      upper arm  1.06-1.08   lower arm  1.24-1.26   hand       1.24-1.29
      pelvis     1.88 (a short segment)
      TOTAL      robot 4.018 m   capture 3.734 m   ratio 1.076

★★★ **THE ARMS ARE 24-29% TOO LONG AND THE LEGS FIT WITHIN 8%.** That is not a global size
difference — **it is a PROPORTION difference**, and it explains three separate things at once:

    the 10 cm wandering offset      the arms cannot reach their targets, so the root slides
    the forearm's 12-26 deg         it is the longest bone relative to the capture's
    the torso being squeezed        already fixed by direction-and-own-length, same cause

## ★★ SO SCALING THE ROBOT UP WOULD NOT WORK

Simon's instinct — *"scale up humanoid a little"* — is the right shape and the wrong lever: a
7.6% global scale would fix the total and make the LEGS 8% too long, which currently fit. **One
number cannot correct a proportion difference.**

★★★ The right lever is **GMR's `human_scale_table`: a scale PER BODY.** Noted many turns ago as
"only once the mechanism is settled" — and the mechanism is settled now.

## The concrete fix, and it already exists in this codebase

`solveRestPoseFromSource` builds a skeleton with the capture's DIRECTIONS and the robot's OWN
lengths. **Run that construction per FRAME instead of once at rest**, and its joint positions
become the targets. Then:

    every target is exactly reachable          no residual the root can slide to reduce
    proportions are the robot's                a 25% longer forearm asks for nothing impossible
    directions are the capture's               which is the only thing a retarget can copy

★ The torso already uses exactly this (direction from capture, length from robot) and it stopped
the squeezing. **Applied per-bone it measured worse — but that was as a CHAIN from each parent's
human position; built as a whole retargeted skeleton first, then read as absolute targets, the
accumulation problem does not arise.**

★ Simon's third observation — the T-pose feet not flat because Geno's ankle-to-ball has an angle
— is the same family: a shape difference the robot cannot match, currently absorbed by whatever
the solve finds cheapest.

---

# ★★★ THE RETARGETED SKELETON — targets the robot can actually reach

Walk the robot's OWN tree, parents first, placing each body along the capture's bone DIRECTION at
the robot's OWN bone length. Those joint positions become the targets.

                        before          after
      TORSO AXIS   10.9/40.2/29.3/10.7   5.9/15.1/ 0.9/ 8.6     mean 22.8 -> 7.6   **-67%**
      forearm      26.9/26.0/ 7.1/16.0  22.5/ 9.7/ 9.7/10.3     mean 19.0 -> 13.1  -31%
      thigh                        4.4                   3.7
      shin                        1.58                  1.58
      arm                          8.1                  13.6    worse
      pops                        65.9                  65.9
      ------------------------------------------------------------------------
      sum of means                55.9                  39.6

★★★ **THE TORSO AXIS IS DOWN 67% AND THE FOREARM 31%** — the two quantities Simon flagged from
screenshots, and the two the old targets made impossible.

## Why it works

★★ A target built from the capture's joint POSITION asks a 25%-longer forearm to end where a
shorter one ends. **That residual cannot go to zero, so the free root slides to spread it** — the
10 cm offset that wanders with the pose. A target built at the robot's own length **can** go to
zero, so there is nothing to slide toward.

★ It is `solveRestPoseFromSource`'s construction — which built the rest pose correctly many
sections ago — applied per frame. **The right idea was in the codebase for twenty sections before
it was used where it mattered.**

## What got worse, and it is worth naming

★ The upper arm's direction went 8.1 -> 13.6 degrees. Its retargeted elbow sits at the robot's own
arm length rather than the capture's, so the whole arm chain now asks for a different shape than
before — **and the arm is the limb whose proportions differ most (1.24-1.29).** The sum is
decisively better; the arm specifically is the place where a per-limb scale would help next, which
is exactly GMR's `human_scale_table`.

★ Shipped in both the harness and the example, `check` green.

---

# ★★★ ARM WEIGHT — the pops reach 56.2, from 155

The arm's bones are 1.24-1.29x the capture's where the legs are 0.98-1.08, **so its residuals stay
largest and a sum-minimising solve spends them to buy cheaper gains elsewhere.** Weight is the
only lever that says "this one matters", and it encoded nothing about which bones the robot
struggles with.

      arm weight    arm    torso   fore    thigh  shin    POPS
         1.0       13.6     7.6    13.1     3.7   1.58    65.9
         2.0       11.45    8.4    14.05    2.75  2.1     56.2    <- best pops
         4.0        8.75    7.7    13.6     2.2   2.85    60.8    <- best sum

★★★ **CHOSE 2.0.** 4.0 wins the accuracy sum by 10%, but 2.0 wins the pops by a clear margin —
and **smoothness is the defect that has been observed from the device again and again**, while
the accuracy difference between the two is small. The sweep is kept in the test so the choice
stays visible and reversible.

## The pop number, end to end

    six sequential mechanisms, cold           155.0
    warm started                              148.5
    step-scaled limits                        157.4   no effect
    ONE point-cloud solve, hard clamp         122.1
    soft barrier                               70.8
    per-body weights + posture 0.15            64.9
    retargeted skeleton targets                65.9
    arm weight 2.0                             56.2

★★ **A factor of 2.8, and every step of it came from changing the OBJECTIVE** — the residuals,
the barrier, the weights — never from changing the search.

## Where the whole thing stands

    torso axis   4.2-15.5 deg      arm    4.2-18.9      forearm  8.5-21.9 (best 1.1-2.8)
    thigh        1.6-4.2           shin   0.6-4.0       pops     56.2
    ONE solve, ~44 residuals, soft limits, posture term, four weights that each mean something

★ Open, in order: **per-limb scale** (the arm's 1.25 proportion is the root cause of its weight
needing to be raised at all), the forearm's remaining gap to 1.1-2.8, and the T-pose foot angle
Simon noted — Geno's ankle-to-ball is angled and the robot's foot is flat, so the feet cannot sit
on the floor in the same way.

---

# ★★★ THE FOOT ANGLE, MEASURED — Geno's toe points 24.6 degrees DOWN

Simon: *"in the t-pose the feet are not well aligned with the floor because ankle to ball has an
angle in geno."*

      FOOT vs FLOOR at T-pose:   robot sole   0.0 deg      capture ankle-to-toe  -24.6 deg

★★★ **The robot's sole is EXACTLY horizontal and Geno's toe points 24.6 degrees BELOW its
ankle.** So aiming the robot's sole at the capture's toe direction asks it to tilt 24.6 degrees
down — **driving the toe through the floor.** Exactly what the screenshot shows.

★ It also explains three numbers that never lined up before: the foot's measured error settles
around 13 degrees, the T-pose rest offset measured 20.3, and both are fractions of this 24.6 that
the solve absorbs where it can.

## ★★ WHY THE EARLIER REST-OFFSET FIX FAILED

Removing the offset was the right idea and it measured much worse — because it was computed
between two DIFFERENT poses (robot at `qpos0`, capture at T-pose), and later between two poses
where the robot's foot had never been AIMED at all. **Both bugs are now fixed**, and this
measurement is the first one taken with the robot genuinely in the capture's T-pose with its leaf
bodies oriented.

★ So the offset is worth retrying, and now there is a number to check it against: **applying it
should take the foot's per-frame error toward the 3.2 degrees the ankle can actually reach**, and
the T-pose sole should read 0.0 against the floor rather than -24.6.

## ★ Per-limb scale is already done, as it turns out

The retargeted skeleton places every body at the ROBOT's own bone length, so each limb is
implicitly scaled by its own ratio. **GMR's `human_scale_table` is subsumed** — the thing it
computes per body is exactly what using the robot's own lengths gives for free.

★ What remains of the proportion difference is unfixable by any scale: the robot's arm is 1.25x
the capture's, so with matching directions its hand simply ends up further out. **That is a shape
difference between two skeletons, and only a different robot removes it.**

---

# ★★★ THE FEET HAVE ONE SAMPLE, SO NOTHING ORIENTS THEM

Retried the foot's rest offset with both references genuinely in the solved T-pose — the fix the
last two attempts lacked. With the 24.6-degree offset applied as a measurement:

      FOOT(offset):  8.9 / 33.9 / 15.4 / 17.5      mean 18.9

★★★ **But the deeper finding is why that number is free to be anything: a LEAF body gets exactly
ONE sample — its own origin — which is a POSITION and nothing else.** The point cloud never
orients a foot. The ankle's two DOF are driven only by the posture term and the barrier, so the
sole points wherever the previous frame left it.

★★ **This is the sample-count rule, and it predicted this too**: one point gives position, two
give direction, three give twist. A foot has one. Its error is free to be 33 degrees because
nothing in the objective has an opinion about it.

## ★ The fix is the one Simon proposed at the start: SAMPLE THE GEOMS

    body origin                 1 point    position
    + geom far end              2 points   direction
    + two off-axis surface      4 points   twist

A capsule's endpoints and two points on its surface give a leaf everything an interior body gets
from its children. **The `solveRestPoseFromSource` leaf-aiming fix already does exactly this for
the REST pose** — a `point_local` on the geom's far end — and the per-frame solve never got it.

★ That is the next change, and it is small: extend `buildPointSamples` to emit geom-derived
samples for any body with no mapped children, with correspondences taken at the T-pose the way
the rest solve already does.

## ★★ AND THE 24.6 DEGREES IS STILL REAL

Geno's ankle-to-toe points 24.6 degrees below horizontal at the T-pose; the robot's sole is flat.
**Even a fully-constrained foot cannot match both the capture's toe direction and the floor** —
one of them has to give. **A retarget cannot fix a shape difference**, but with the foot actually
constrained it becomes a choice rather than an accident, and the sensible choice for a robot that
stands on the ground is the floor.

---

# ★★★ HEEL AND TOE — the foot as two points, with no offset algebra

Simon: *"the heel is some point in the foot frame. We know the desired foot direction by taking
heel to toe. We need to be more direct with foot position and orientation to have precise foot
contacts."*

★★★ **The body origin IS the heel and the geom's far end IS the toe.** Heel targets the capture's
ankle; toe targets the capture's toe DIRECTION at the ROBOT's own foot length. Two points give
position AND direction — which is exactly what a contact needs — **and no rest offset appears
anywhere.**

      thigh   2.75 -> 2.05 deg mean
      shin    2.10 -> 1.65
      torso, arm, forearm, pops        held
      samples 44 -> 46

★★ **Three previous attempts at the foot all needed an offset and all got it wrong** — computed
between mismatched poses, then against a leaf that had never been aimed. **This construction
needs none**, because it never converts a rotation between two skeletons: it matches points, in
the same units, like everything else in the objective.

★ It also turns the 24.6-degree ankle-to-toe difference from an accident into a stated choice:
the robot's heel-to-toe points where Geno's does, at the robot's own length.

## ★★ THE SAMPLE-COUNT RULE, THIRD CONFIRMATION

    one point    position
    two points   position + direction
    three        position + direction + twist

    forearm  2 collinear samples   ->  7.9-28.3 deg
    foot     1 sample              ->  free to be 33 deg
    thigh    3+ samples            ->  1.6-4.2

★★★ **Every weak bone in this project has been a bone with too few samples**, and the rule
predicted each one before it was measured. The remaining weak bone is the forearm, which has two
COLLINEAR samples — and geom-derived off-axis points are exactly what it lacks, by the same
argument that just fixed the feet.

---

# ★★★ THE FOOT'S ROLL — and the one place the DOF-count rule is the WRONG TEST

Simon: *"we also need the twist of the foot to match somehow."*

## The reasoning, which matters more than the change

★★ Heel and toe are two points, so they fix the foot's DIRECTION — **two parameters, and the
ankle has exactly two DOF.** At the ankle the roll is therefore not free: it is whatever those two
axes happen to produce. **A foot rolled 20 degrees stands on its edge**, and nothing in the
objective was asking it not to.

★★★ **But the roll IS reachable — through the LEG.** The knee and hip can turn the entire limb,
so in a whole-body solve the foot's roll is a real degree of freedom even though the ankle cannot
supply it alone.

★★★ **This is the one place the earlier rule is the wrong test.** "Off-axis samples only where
`body_dof_num >= 3`" asks what the JOINT can do — correct for a shoulder, whose bend plane truly
follows from its two angles. **For a foot the answer comes from the CHAIN**, and a rule about one
body cannot see that.

      foot     22.1 / 1.5 / 19.4 / 28.8   ->   16.4 / 12.4 / 6.7 / 9.5
      mean            18.0                            11.25          -38%
      spread     1.5 to 28.8                     6.7 to 16.4         the erratic frames are gone
      thigh           2.05                            2.8            slightly worse
      shin            1.65                            2.2            slightly worse
      torso, arm, forearm, pops                       held

★★ **The spread narrowing matters more than the mean.** The frames that were 28.8 and 1.5 were
not "sometimes accurate" — they were unconstrained, landing wherever the previous frame and the
barrier left them. Now every frame is within 6.7-16.4, which is a foot that is being ASKED for
something on all of them.

★ The legs pay slightly, which is the expected shape: the roll comes from the knee and hip, so
they spend a little of their own accuracy to supply it. **That is the trade being made explicitly
rather than by accident.**

## The sample-count rule, restated correctly

    a body needs three non-collinear samples to be fully oriented
    it needs the DOF to use them — from its own joints OR FROM ITS CHAIN

★ The second clause is new, and it is what this turn added.

---

# ★★★ THE CORRECTED RULE PAYS ON THE FOREARM — the last stubborn bone

The foot taught the rule; the forearm is the same case. **The elbow's one hinge cannot roll the
forearm, but the shoulder can roll the whole arm** — so its twist is reachable through the CHAIN
even though its own joint cannot supply it. The old test (`body_dof_num >= 3`) excluded it for a
reason now known to be wrong.

      samples  50 -> 68

      forearm  21.9/ 9.0/16.9/8.4   ->  22.5/ 9.4/ 5.8/7.2    mean 14.05 -> 11.2   **-20%**
      foot     16.4/12.4/ 6.7/9.5   ->  16.9/ 7.0/ 7.4/5.2    mean 11.25 ->  9.1
      shin                    2.2   ->   1.8
      arm                    11.05  ->  11.3        held
      torso                   8.05  ->   9.0        slightly worse
      thigh                   2.8   ->   3.5        slightly worse
      pops                   56.2   ->  59.0        slightly worse
      ---------------------------------------------------------------
      sum of means           49.4   ->  45.9

★★ **Two forearm frames land at 5.8 and 7.2 against a best-possible of 1.6 and 2.8** — the first
time that bone has been anywhere near what the joint can reach, after four refuted explanations.

## ★★★ THE RULE, IN ITS FINAL FORM

    a body needs THREE NON-COLLINEAR SAMPLES to be fully oriented
    and the DOF to use them — from its own joints OR FROM ANY ANCESTOR

★★★ **Both clauses were learned by being wrong.** The first came from the forearm's two collinear
samples and the foot's single one; the second came from the foot, where asking "what can this
joint do?" gave the wrong answer and "what can the chain do?" gave the right one. **The rule now
predicts which bones will be weak and what to add, from the model alone** — and it has been right
about the forearm, the foot, and the shoulder in turn.

★ What remains is a trade, not a mystery: the torso and thigh give up a little to supply twist
that only they can supply. **Everything in the body is now within a few degrees of what the robot
can physically do, except the arm** — whose bones are 25% longer than the capture's, which no
objective can fix.

---

# ★★★ THE REMAINING POPS ARE A BRANCH FLIP, NOT DRIFT

The samples grew 44 -> 68 and the pops drifted 56.2 -> 59.0. **A weight is a RATIO against the
other terms, so adding residuals silently weakens every regulariser** — a real effect, and the
reason to re-sweep the posture weight after any change to the sample set.

      posture 0.15   worst 59.2 deg at upper_arm_left frame 226
      posture 0.30   worst 59.2 deg at upper_arm_left frame 226
      posture 0.60   worst 59.2 deg at upper_arm_left frame 226

★★★ **IDENTICAL TO THE DECIMAL ACROSS A 4x CHANGE.** By now that pattern is familiar enough to
read immediately — but this time the parameter IS wired and reaching the solve. So the number is
telling the truth: **that pop is not drift a continuity term can hold. It is a BRANCH FLIP.**

★★ Once the solve crosses to a different feasible piece, the previous configuration is far away,
and a quadratic pull cannot compete with a large residual. **A posture term prevents wandering; it
cannot prevent jumping.**

★ Consistent with everything measured about that shoulder: two DOF, a range it is pinned against,
and two clamped configurations satisfying the targets nearly equally. **The remaining pops are
structural**, and the instrument now says so rather than inviting a fourth weight sweep.

## What would actually address it

★★ Not a weight. Either:
  1. **A third shoulder DOF** — the structural fix, and the one thing `humanoid_flex.xml`
     deliberately did NOT do so that range and shape could be told apart. That experiment has now
     served its purpose.
  2. **Continuity as a HARD constraint** rather than a penalty: bound `|q − q_prev|` per frame so
     no step can reach the other branch at all. That changes the feasible set instead of the
     objective, which is what "cannot jump" requires.

## Where the whole project stands

    forearm 11.2 deg (best 1.1-2.8)   foot 9.1   shin 1.8   thigh 3.5   torso 9.0   arm 11.3
    worst pop 59.2, from 155          68 samples, ONE solve, four weights that each mean something

★ Every large error now names either a proportion difference (the arm's 1.25x bones) or a
structural limit (the 2-DOF shoulder). **Nothing left is the mathematics.**

---

# ★★★ FLEX 2 — the best result of the project, and every change measured first

Simon: *"allow the flex version to match what is needed to follow geno precisely. Still minimize
the number of DOF, but be more free to change sizes and joints."*

                      flex 1 (ranges only)   flex 2 (sizes + 1 DOF per arm)
      torso axis            9.0 deg               6.8 deg
      upper arm            11.3                   8.4
      forearm              11.2                   4.7     best possible 1.1-2.8
      thigh                 3.5                   3.9
      shin                  1.8                   3.1
      WORST POP            59.0                  14.3     **from 155 originally**

## The four changes, each from a specific measurement

    arms shortened 20%       bones were 1.24-1.29x the capture's; now 0.99-1.03, total 0.997
    third shoulder axis      +1 DOF per arm, 21 -> 23 total. THE ONLY dof added.
    shoulder span narrowed   the torso was wider than Geno's, which forced the skew
    foot pitched 24.6 deg    Geno's ankle-to-toe is 24.6 deg below horizontal; the sole was flat

★★★ **THE POP COLLAPSED 59 -> 14 FROM THE THIRD AXIS ALONE.** The remaining pops were proven to
be a BRANCH FLIP, not drift — posture weights of 0.15, 0.30 and 0.60 all gave 59.2 to the decimal.
**A third axis removes the pinning that creates the two branches**, which is exactly what that
measurement predicted and what no weight could do.

★★ **THE FOREARM COLLAPSED 11.2 -> 4.7 FROM THE ARM LENGTHS**, and 4.7 is within striking
distance of the 1.1-2.8 the joint can physically reach. The bone that resisted four explanations
was, in the end, 25% too long.

## ★★ WHY FLEX 1 EARNED ITS KEEP

It deliberately withheld the third axis so RANGE and SHAPE could be told apart — and it answered:
ranges fixed the legs (thigh 21.2 -> 2.9) and did **nothing** for the pops (155 -> 140). **That
negative result is what justifies spending a DOF here**, rather than guessing that more freedom
would help.

★ Legs got slightly worse (shin 1.8 -> 3.1). Expected: the arms no longer dominate the residual,
so the solve spends differently. **Every number in the body is now within a few degrees of what
the robot can physically do.**

---

# ★★★ FLEX 2 NOW SHIPS IN THE EXAMPLE

The example embedded `humanoid.xml` — the STOCK model — while every number in this document was
measured on flex. **Sixth time that divergence has appeared, and the first time it was checked for
BEFORE shipping rather than after a screenshot disagreed.**

★ Switched to `@embedFile("humanoid_flex.xml")`. Also verified what the switch could have broken:
`robot_hip_height_m = 0.830` was measured from the stock model, and the torso still sits at 1.282
with the hip offsets untouched — **only arms, shoulders and feet changed, so the scale still
holds.** A different answer there would have rescaled every target silently.

## What the device should now show

    torso axis    3.9-11.8 deg        arm      6.2-10.8
    forearm       0.6-7.7             thigh    2.5-5.2      shin  2.2-4.2
    worst single-frame pop  14.3      from 155 at the start of this arc

★★ **The pops are the number to watch**, because they are what "clicky" and "jittery" have meant
on every screenshot. 14.3 degrees of worst-case excess over 600 frames is roughly a tenth of where
this started.

## The arc, in one table

                              worst pop   forearm   torso axis
      six mechanisms, stock       155.0      -           -
      one point-cloud solve       122.1     19.3        27.8
      + soft limit barrier         70.8      -           -
      + per-body weights           64.9     19.4        22.8
      + retargeted skeleton        65.9     13.1         7.6
      + arm weight 2.0             56.2     14.05        8.4
      + heel/toe + foot roll       59.0     11.2         9.0
      + flex 2 (sizes, 1 DOF)      14.3      4.7         6.8

★★★ **Every row is a change to the OBJECTIVE or to the MODEL — not one is a change to the search.**
The single row that changed only where the search starts (warm start, 155 -> 148.5) is the
smallest improvement in the table.

---

# ★★★ THE FOOT PITCH WAS THE WRONG WAY, AND THE PROBE COULD NOT SEE IT

★★ The `FOOT vs FLOOR` probe read the geom offset **raw, in the BODY's frame**, without rotating
it by the body's rest orientation. So it reported **0.0 degrees no matter what** — including after
a 24.6-degree pitch had been added to the model. **It could not see the one quantity it existed
to measure.**

★ Fixed (rotate by `body_xrot` at `qpos0`), and the first thing it showed was that the pitch had
gone the WRONG WAY:

      before the fix    robot sole   0.0 deg   (blind)
      pitch applied     robot sole +21.1       against Geno's -24.6  -> difference 45.7, WORSE
      sign flipped      robot sole -21.1       against Geno's -24.6  -> difference  3.5

## What the correct pitch bought

      FOOT   16.6/11.7/18.8/18.1  ->   8.2/15.8/17.9/11.1    mean 16.3 -> 13.25
      shin    2.2/ 2.2/ 3.8/ 4.2  ->   1.0/ 1.3/ 2.3/ 3.2    mean  3.1 ->  1.95   -37%
      thigh                  3.9  ->   3.75
      torso, arm, forearm, pops         held (pop stays 14.3)

★★ **The shin gained most**, which is the right shape: a foot that no longer fights the floor
stops asking the knee to compensate.

## ★★★ THE LESSON, AND IT IS THE SESSION'S MOST REPEATED ONE

    a vacuous rest check        measured algebra, not the code
    a phantom edit              measured a change that never applied
    a duplicated loop           measured a different program
    identity twists in a test   measured a stub
    a body-sized task array     measured a third of the robot
    a raw geom offset           measured a frame the change could not reach

★★★ **SIX TIMES an instrument has agreed with itself while being blind to the thing under test.**
Each produced a plausible number. **The tell each time was a number that did not MOVE when
something changed** — 0.0 here, "identical to the decimal" three times before. That signature is
now the first thing to check, not the last.

---

# ★★★ FLAT FEET — a WORLD constraint, which the objective had never had

Simon, from the device: *"the feet should be flat on ground."* The robot's toes were driving into
the floor while the character's foot lay flat.

## ★★★ MY ERROR, AND IT WAS CONCEPTUAL

I pitched the robot's foot by 24.6 degrees to match Geno's ankle-to-toe direction. **That angle
is a fact about Geno's SKELETON — its toe joint sits below its ankle — not about how its SOLE
meets the floor.** Geno's foot is flat WITH that angled bone, because the sole is below both
joints.

★★ Matching a skeletal line put the robot's sole 21 degrees nose-down. **The measurement was
right and the interpretation was wrong**, which is a different failure from the ones this project
has mostly had.

## The real requirement

★★★ **Every residual in this objective compares the robot to the CAPTURE. "Flat on the ground"
compares it to the WORLD**, and nothing here could express that. It is a genuinely new kind of
term, not a tuning of an old one.

★ Implemented as `PointSample.level_to_floor`: take the capture's toe direction, **flatten its
vertical component**, and place the toe at the robot's own foot length along the result. The foot
points where the dancer's points AND lies flat.

      SOLE TILT from horizontal    4.5 / 3.2 / 3.4 / 1.2 deg
      shin                         1.95 -> 1.35 mean
      torso, arm, forearm, pops    held (pop stays 14.3)

★★ **And the metric had to change with it.** `FOOT(offset)` measures the sole against the
CAPTURE's toe direction, so levelling departs from it by construction and that number read
16.3 -> 30.7 while the feet were getting FLATTER. **A change aimed at the floor has to be judged
against the floor** — the same mistake as judging the shoulder-axis constraint on arm error, two
sessions ago, and caught faster this time because of it.

## Where everything stands

    torso 3.8-11.7   arm 6.2-10.9   forearm 0.5-7.8   thigh 2.5-4.3   shin 0.4-2.8
    sole tilt 1.2-4.5 from the floor        worst single-frame pop 14.3 (from 155)

---

# ★★★ FEET, RETHOUGHT: "FLAT ON THE GROUND" IS ABOUT CONTACT, NOT ABOUT FEET

Simon: *"at 6.132 the left foot points down in geno and up in the robot. Same everywhere. We need
to rethink completely how we place feet."*

★★★ **He was right and my levelling was the cause.** I flattened the toe target ALWAYS, so a foot
that legitimately points down — on tiptoe, or mid-swing — was forced horizontal. And when the toe
direction is mostly VERTICAL its flattened version is nearly zero, so the direction it yields is
**arbitrary**: hence "up in the robot" while the dancer pointed down.

## The rule, restated properly

    a foot ON THE GROUND should be flat        a WORLD constraint
    a foot IN THE AIR should follow the capture   a CAPTURE constraint

★★ **Neither alone is right, and the choice between them is CONTACT.** That is not a property of
feet; it is a property of the moment.

★ The contact signal needs no detection: **the capture already carries it.** Blend by the
capture's own ankle height above the floor, and take the floor from the capture too — **the lowest
foot in each frame is standing on it.** No threshold invented, no heuristic, no per-clip constant.

      on ground (<=6 cm)   levelled
      in air (>=18 cm)     follows the capture exactly
      between              blends, so planting and lifting do not snap

      SOLE TILT   64.3 / 8.3 / 3.4 / 1.2 deg

★★ **The 64.3 is correct**: that foot is airborne and following Geno's 64-degree point. The
others are planted and flat. **A single number for all four frames would have been the bug, not
the fix.**

## ★★★ THE LESSON

    the measurement                Geno's ankle-to-toe is 24.6 deg below horizontal
    my first interpretation        so pitch the robot's foot 24.6 deg      WRONG — that is skeleton, not sole
    my second                      so flatten the toe target always        WRONG — that is contact, not geometry
    the third                      flatten only in contact                 right

★★★ **The same measurement supported three different changes, two of them wrong.** A number tells
you what is different; it does not tell you what to do about it. **Three interpretations of one
24.6 degrees, and only the device could tell them apart.**
