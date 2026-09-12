# ★★★ WHAT IS NEXT — and the divergence that just re-formed

## ★★★ DIVERGENCE #7, FOUND BY DIFFING TWO CALL SITES

    example  solvePointCloud   .posture_weight = 0.15
    harness  WHOLE BODY        .posture_weight = 0.02

**Every per-bone number quoted from that test described a configuration that does not ship.** The
effect was small this time — torso 4.4 -> 4.3 — but nothing made it small; it was luck.

★ Found in one command, by comparing the two `ikStep` option blocks. **The first of these seven
found by diffing rather than by a screenshot**, which is the cheapest any of them has been.

## ★★★ THE ROOT CAUSE, AND IT IS STRUCTURAL

    the SHIPPED algorithm   `solvePointCloud` + `buildPointSamples`   in the EXAMPLE
    the TESTED algorithm    the WHOLE BODY test                       in the HARNESS

★★★ **The harness cannot call the shipped code, so it re-implements it.** That is the exact
condition that produced divergences 1-6, each closed individually — the twist builder, the rest
solve, the task set, the rest-flexion fix, the whole pose loop, the sample cache. **#7 was
inevitable and #8 will be too, until the algorithm moves.**

## The fix

**Move `buildPointSamples` and `solvePointCloud` into `src/robot.zig`.** They depend on nothing
graphical: a model, a capture's joint positions and rotations, and scratch. The example becomes a
caller that supplies buffers; the harness becomes a caller that supplies a BVH.

    every weight, threshold and rule then has ONE home
    the harness measures the SHIPPED code, not a copy of it
    `poseFromRetarget` and its six mechanisms become deletable — the example already ignores them

★★ **This is the same move that fixed the six earlier divergences**, applied to the thing that
replaced them. It was correct each time and it is correct now.

## Then, in order

    1. re-sweep the four weights on the DROP KICK, using the on-device readout
    2. the stock `humanoid.xml` on a Mixamo capture — needs a robot reload, which is real work
    3. delete `poseFromRetarget`'s six mechanisms once nothing calls them

★ Item 3 is worth stating plainly: **twist offsets, aim-at-child, two-bone limbs, direction
pairs, rest-flexion and the hinge formula are all still in the library, and the shipped example
uses none of them.** They cost forty sections to build and the point cloud subsumed every one.

---

# ★★★ THE MOVE IS DONE — the algorithm lives in the library

    src/robot.zig    PointSample, PointCloudOptions, SampleBuildInputs
                     buildPointSamples   the sample rule, the leaf construction, the weights
                     solvePointCloud     the one solve, the barrier, the posture term

★★★ **The harness can now call the code that ships.** Seven divergences were closed one at a
time — the twist builder, the rest solve, the task set, the rest-flexion fix, the pose loop, the
sample cache, a posture weight — and each closure left the CONDITION intact. This removes it.

★ Exported through `zimr.zig`; the example becomes a caller that supplies buffers.

## ★★★ AND THE FIRST ASSERTION FOUND A REAL DEFECT

    UNDER-SAMPLED: head has 1 sample(s) — orientation unconstrained

★★ **The robot's head can face anywhere.** It is a leaf, and the leaf construction needs a TIP
joint beyond it: a foot has `ToeBase`, but LAFAN1 ends at `Head`. So the head gets its origin and
nothing else — one sample is a POSITION, and **no metric in this project has ever measured head
orientation.**

★★★ That is the sample rule working exactly as intended: **stated as an assertion, it names a
weak bone before anyone looks at a screenshot.** Every previous instance — the forearm's two
collinear samples, the foot's one — cost turns of hypotheses first.

★ Logged rather than asserted away, because fixing it is a design choice: aim the head's geom at
the capture's neck-to-head direction. **A different construction from the heel/toe one, and it
deserves its own measurement.**

## Remaining

    1. switch the example to the library functions and delete its copies
    2. the head's second sample
    3. re-sweep the weights on the drop kick with the on-device readout
    4. delete `poseFromRetarget`'s six mechanisms — nothing ships them

---

# ★★★ THE HEAD: A LEAF WITH NO TIP AND A SPHERE FOR A GEOM

Two fixes, one right and one wrong, and the second is the more useful record.

## ★★ FIX 1: a leaf needs no tip joint — CORRECT, and now in the library

A foot has `ToeBase` beyond it, so heel and toe project to the floor. **A head has nothing beyond
it** — LAFAN1 ends there. But the third point never needed a tip: it records the ROBOT's geom
offset in the CAPTURE joint's frame, measured once at rest. **That works for any leaf.**

★ So a leaf without a tip takes three geom-derived points instead of the heel/toe pair, carried
by the same rest-pose correspondence. **State the correspondence once, at rest, and never decide
it again** — the principle behind every part of this system that works.

## ★★★ FIX 2: an ARBITRARY axis is not a substitute for a direction — WRONG

The head still had one sample, and the reason is exact: **its geom is a SPHERE centred on the
body origin.** `geom_pos` is zero, so there is nothing to point with. Same for both hands.

★ Tried: substitute a fixed offset along local X and carry it through the correspondence like a
geom point.

      torso    4.3 -> 64.6        arm  10.7 -> 140.4        forearm  2.8 -> 128.2

★★★ **Catastrophically worse.** At weight 1.5 an axis that means nothing physically outweighs
every sample that does. **The correspondence was not the problem; the CHOICE of axis was** — and
a constant chosen to satisfy an assertion is not information, it is noise with a weight.

★★ Reverted. The head's orientation IS real and the capture carries it in `rest_rotations`, but
it has to enter with a direction and a weight that mean something. **That is a design question,
left open rather than answered with a constant.**

## What the assertion earned anyway

    UNDER-SAMPLED: head, hand_right, hand_left  — orientation unconstrained

★ Three bodies whose orientation nothing in the objective has an opinion about, named
automatically. **Before this they were invisible**; the forearm and the foot each cost several
turns of hypotheses to find. The assertion does not fix them — it makes them impossible to
forget.

---

# ★★★ THE REVIEW'S FIRST FINDING WAS MY OWN LAST CHANGE

Moving the algorithm into `src/robot.zig` **added a third copy without removing the first.** The
example still defined its own `PointSample`, `buildPointSamples` and `solvePointCloud`, so for a
turn there were three implementations where there had been two. ★★ **A refactor that stops
halfway is worse than not starting**, and it was invisible because everything still built and
every number still matched.

## Now

    src/robot.zig                    the ONLY definition
    examples/geno_dance              a caller
    src/robot_mjcf.zig               a caller

★ 571 lines deleted from the example. What is left there is what genuinely belongs to it:
`refreshPointSamples` (turning a `Character` into the arrays the library wants),
`buildRetargetedSkeleton` (the walk and the best-fit placement) and `recordRobotFit` (the on-screen
metric).

## ★★ THE COMMENTS, CLEANED

Each surviving block states the finding rather than the mechanism, because the mechanism is
readable and the finding is not:

    the sample rule          three non-collinear points, and the DOF to use them — from the CHAIN
    the leaf construction    a joint is not a contact point; the rest pose states the offsets
    the barrier              a wall is a slope, and the pop fell 155 -> 14
    the placement            build the SHAPE first, place it second; no privileged body
    the position pull        the dial between shape and place, and why 1.0 suits matched bones

★★★ **Every one of those was learned by being wrong first**, and several record the wrong version
alongside the right one — the 24.6-degree foot pitch, the always-level rule, the arbitrary head
axis, the shoulder axis at weight 2.0. **A comment that only states the answer teaches the next
person to re-derive the mistake.**

## What is genuinely left

    1. the head and both hands: orientation unconstrained, and a sphere gives no direction
    2. re-sweep the four weights on the drop kick, using the on-screen readout
    3. delete `poseFromRetarget`'s six mechanisms — the shipped path uses none of them

---

# ★★★ THE HEAD: TWO FAILED ATTEMPTS, THEN A MEASUREMENT THAT REFUTED BOTH DIAGNOSES

    attempt 1   an arbitrary local axis          torso 4.3 -> 64.6   forearm 2.8 -> 140.4
    attempt 2   `body_pos`, the parent bone      torso 4.3 -> 56.2   forearm 2.8 -> 118.4

★★ After the second I wrote down a diagnosis: *the no-tip branch applies a ROBOT-frame direction
at the CAPTURE's joint, which is only valid where the two rest orientations agree.* Plausible, and
it explained why the foot escapes (heel and toe are floor PROJECTIONS, which live in the world and
need no frame).

## ★★★ THEN I MEASURED IT INSTEAD OF BELIEVING IT

      REST FRAME DISAGREEMENT      torso 0.0   head 0.0   foot 4.7   **hand 90.0**

★★★ **The head's frames agree exactly.** The diagnosis was wrong about the body it was written to
explain. **The HANDS are 90 degrees apart** — and both attempts applied the construction to head
and hands together, so the hands alone were enough to wreck the solve while the head was innocent.

★★ The criterion is therefore not *"does this body have an off-centre geom"* but **"do the two
rest frames agree?"** — a number, checkable per body, that says exactly where a frame-mixing
construction is sound. **The head passes it. The hands need their own correspondence**, which is
the same shape as the foot's: something that lives in the world rather than in either frame.

★ Left unimplemented rather than approximated a third time — but the next attempt now has a test
to gate on instead of a hypothesis, and `REST FRAME DISAGREEMENT` prints every run.

## ★★ THE PATTERN, ONE LAST TIME

    "before explaining a residual, measure the best the mechanism could do"     — §39
    "a change judged on quantities it was not aimed at has not been judged"     — the shoulder axis
    **"before believing a diagnosis, measure the thing it claims"**             — here

★ Three failures this session came from a plausible explanation adopted without a number: the foot
pitch, the always-level rule, and this. **Each cost a turn; each was refuted by one measurement
that took minutes.**

---

# ★★★ THE CRITERION MEASURED AN ADJACENT QUANTITY — the same error, a third time

Armed with `REST FRAME DISAGREEMENT` (head 0.0, hand 90.0), I gated the leaf construction on
frame agreement and expected the head to gain samples. **It did not: 75 samples, unchanged.**

## Why

    the MEASUREMENT read   `body_xrot` at `qpos0`         where the model FILE puts the body
    the CRITERION reads    `robot_rest_rotations`         where the RETARGET puts it after
                                                          fitting the capture's T-pose

★★★ **Not the same orientation.** The head reads 0.0 degrees in one and fails the check in the
other. So the criterion I built from a measurement was not built from *that* measurement.

## ★★★ THE LESSON, SHARPENED

Three times this session a plausible thing was adopted without checking the exact quantity:

    the 24.6 deg foot pitch    measured a SKELETAL LINE, applied it to a SOLE
    the frame-disagreement     explained the HEAD, was true of the HANDS
    this criterion             measured `qpos0`, consumed the SOLVED pose

★★ The first two were *"measure before believing"*. This one had a measurement and still failed —
so the rule is stronger than that:

    **a measurement of an ADJACENT quantity is worth nothing, and reads exactly like a
    measurement of the right one.**

★ Both failures looked like evidence. Neither was.

## State left behind

★ The construction stays OFF for every no-tip leaf — the status quo, and measurably safe: torso
4.3, arm 10.7, forearm 2.8, thigh 2.9. The head and both hands remain unconstrained in
orientation, printed every run by the under-sampling assertion.

★★ **The next attempt has one job before writing any code: decide which orientation the
construction consumes, then measure that one.** `rest_rot_robot` lives in the `WHOLE BODY` test;
the `SCALE` test can only see `qpos0` and now says so in its output rather than implying
otherwise.

---

# ★★★ THE HEAD, CLOSED AS AN OPEN PROBLEM — three attempts, and what each ruled out

    1. an arbitrary local axis                 torso 4.3 -> 64.6    forearm 2.8 -> 140.4
    2. `body_pos`, the parent bone             torso 4.3 -> 56.2    forearm 2.8 -> 118.4
    3. the offset through the RELATIVE transform   **identical to 2, to the decimal**

## What the measurements established

★★ **The solved rest orientations differ by 60-96 degrees for EVERY body, including the torso**,
which reads 0.0 at `qpos0`. That is not disagreement — it is the +Z/+X facing convention, applied
equally to everything. So comparing absolute rest orientations was never meaningful, and the
criterion built on it was measuring nothing.

★★★ Attempt 3 cancelled that convention properly, through the same relative composition the
off-axis twist samples use. **It changed nothing — identical output to the decimal.** Which
retires the frame-convention diagnosis: it was the only explanation that survived measurement, and
now it has not.

## What is actually known

    the head's samples are absent, not wrong        75 samples, three bodies unconstrained
    the no-tip construction is 20x worse            reason NOT established
    the frame convention is NOT the cause           attempt 3 ruled it out
    a known gap beats a wrong fix                   held OFF, printed every run

★ Shipped state is the measured-safe one: torso 4.3 / arm 10.7 / forearm 2.8 / thigh 2.9 /
shin 1.8, worst pop 14, visual fit 0.027 m.

## ★★ WHAT I WOULD DO NEXT, CONCRETELY

★★★ **Stop reasoning about it and print the targets.** Three attempts argued about frames; none
looked at where the two head samples actually land in world space against where the capture's head
is. **One printout of `target_world` versus `positions[head]` for a single frame would settle in
minutes what three hypotheses could not** — the same move that settled the forearm (a
best-possible sweep), the foot (a floor probe) and the 10 cm offset (a position metric).

★ That is the honest end of this thread: **the failures were not from lack of ideas but from
arguing above the level of the data**, three times in a row, after a session that had learned
exactly that lesson four other times.

---

# ★★★ PRINTED THE TARGETS. FOUND IT IN ONE RUN.

      head[69]  target z = 0.011   <- the FLOOR    miss 1.460 m
      head[70]  target z = 0.011   <- the FLOOR    miss 1.650 m

★★★ **The head was being treated as a foot.** `firstChildJoint` finds a child for it, so it took
the heel/toe branch and both targets were projected to the ground — **1.5 metres below where a
head is.** That is the entire 20x regression.

## What three hypotheses had claimed instead

    an arbitrary axis carries no information        WRONG — the axis was never reached
    the parent bone is the right direction          WRONG — same branch, same floor
    the +Z/+X frame convention is uncancelled       WRONG — attempt 3 cancelled it, no change

★★ **None of them was close, and all three were plausible.** The bug was two lines above where
every hypothesis was looking, and visible immediately in a printout of the actual numbers.

## The fix, and why it is physical

    a heel and a toe are on the ground because the BODY is on the ground

★ So the floor projection is guarded by the body's rest HEIGHT, not by its joint topology. A body
resting a metre and a half up is not a foot, whatever `firstChildJoint` says about it. **The
structural test was standing in for a physical fact**, which is the same error as every other
constant this session removed.

## Where it leaves the head

With the guard in place the no-tip construction was judged on its own for the first time:

      torso 56.2 -> 5.5     arm 13.5 -> 5.1        the head is FIXED
      forearm 2.8 -> 20.7   arm 10.7 -> 16.9       because the same branch fires for the HANDS

★★★ **One construction, two bodies, opposite outcomes.** The hands are the ones whose rest frames
are genuinely 90 degrees out, so they need their own correspondence — and until they have it the
branch stays off and the head keeps its single sample.

★ **The floor guard is kept regardless: it is a real bug**, independent of that switch, and it was
projecting head targets into the ground for any caller who enabled the branch.

## ★★★ THE LESSON, FOR THE FOURTH AND LAST TIME

    "before explaining a residual, measure the best the mechanism could do"
    "a change judged on quantities it was not aimed at has not been judged"
    "before believing a diagnosis, measure the thing it claims"
    **"when three explanations fail, stop explaining and print the numbers"**

★ Three turns of reasoning, one printout. **The printout should have come first** — and the same
session had already learned this from the forearm, the foot and the 10 cm offset.

---

# ★★★ THE HEAD IS FIXED — by checking the correspondence against the rest pose itself

Printed the hand targets alongside the head's, as the last note said to:

      head[69..71]        miss 0.03 m      correspondence is right
      hand_right[78,79]   miss 0.40 m      correspondence is WRONG

★★★ **At the rest pose both figures depict the same pose by definition.** So a sample whose
target does not land on its own point THERE has a broken correspondence — not a difficult one, a
wrong one. That is measurable from the rest pose alone, needs no name list and no per-body table,
and it is exactly why one construction helped the head and wrecked the hands in the same run.

★★ `SampleBuildInputs.rest_check`: build the leaf's three samples, verify them against the rest
pose, drop all three if any misses. **The system's own principle — state the correspondence once
at rest — turned into a self-check.**

                        before          after
      torso        4.3/3.2/4.1/9.9    4.0/4.0/4.2/8.2     mean 5.4 -> 5.1
      arm         10.7/5.4/9.9/1.9    9.7/4.4/8.6/1.7     mean 7.0 -> 6.1
      forearm      2.8/3.2/1.3/1.1    0.9/3.3/1.1/0.5     mean 2.1 -> 1.45   **-31%**
      samples              75              81             head and one hand now constrained
      WORST POP           14.2             **9.2**        from 155 at the start

★★★ **The worst single-frame pop is 9.2 degrees, the best of the project**, and the head — which
three attempts failed to constrain — is now carried by the same construction as the feet.

## ★★ AND A CHECK THAT TRAPPED WHEN ITS INPUT WAS MISSING

The example called `buildPointSamples` without the robot's rest POSITIONS, so the new check
indexed an empty slice and the smoke test died inside the solve. **A check that traps when its
input is absent is worse than no check** — it turns a missing argument into a crash in unrelated
code. It now skips itself, and the example supplies the positions.

## The remaining gap, now a single body

    UNDER-SAMPLED: hand_right

★ One hand still fails the rest check; the other passes. **That asymmetry is itself information** —
the two hands differ in the model, not in the capture — and it is the next thread to pull.

---

# ★★★ "THE ROBOT DOES NOT FOLLOW THE DANCE WHEN I ASK IT TO"

Two separate problems in one screenshot, worth keeping apart.

## 1. The UI could not be read

The panel had **three "X plays:" groups** — one per character and one for the robot — each
offering the same two clip names. **Three identical-looking radio pairs, and nothing said which
one moved the blue figure.** That is what the complaint looks like from outside.

    "robot plays:"                    ->  "ROBOT is driven by:"
    "robot: dance1 / robot: drop kick" -> "→ Geno dance1 / → Mixamo drop kick"

★ The heading names the thing being driven; the arrows mark the rows apart from the character
rows above. **Readable without experimenting**, which is the whole job of a control panel.

## ★★★ 2. `fit 0.127 m` — AND A CONSTANT I LABELLED "MEASURED" WITHOUT MEASURING IT

The on-screen readout says 0.127 m where the harness says 0.027 — **five times worse in the
shipped path**, and the readout is why it is visible at all.

★★★ Chasing it found this: `robot_height_m = 1.445`, with the comment *"MEASURED like the hip
height rather than guessed"*. **I wrote the number, wrote "measured" beside it, and had measured
nothing.** The capture scale divides by it, so an error there scales the entire target set.

      actually measured, by walking every body and geom at the solved rest pose:   **1.470 m**

★★ 1.7% out. **Corrected, and it is NOT the whole discrepancy** — saying so matters more than the
correction, because a 1.7% fix quietly presented against a 5x error would look like a resolution.

★ The same session spent a dozen turns removing invented constants from this system, and produced
one while doing it. **The failure mode is not ignorance; it is writing the word "measured" as an
intention rather than a fact.**

## Still open

    fit 0.127 m in the example vs 0.027 in the harness, cause NOT established
    UNDER-SAMPLED: hand_right — one hand fails the rest check, the other passes

★ The next step for the fit is the one that worked twice already: **print the two target sets and
compare them**, rather than reasoning about which stage differs.

---

# ★★★ THE 5x FIT GAP: THE WRONG ANCHOR, CONFIRMED BY MEASUREMENT

    ANCHOR CHECK:  capture hip 0.830 m  vs robot 0.830   —  agree EXACTLY
                   capture top 1.611 m  vs robot 1.470   —  **9.6% apart**

★★★ Scaling by total height shrinks every target by 1.470/1.611 = 0.912 — **8.8% too small**,
which on a 1.5 m figure is ~0.13 m. **The device reported fit 0.127 m.** Cause confirmed rather
than argued.

## Why total height was the wrong anchor even though it was unit-free

★★ Making the scale unit-free was right and stays: the source's height is read from
`rest_positions`, the same array the scale is applied to, so the unit cancels. **But unit-free is
not the same as well-chosen.** The head and neck are where two humanoids differ most, so anchoring
on the top of the skull puts the largest disagreement in the numerator and levers it through every
limb.

★ The hip is the right anchor for the reason GMR uses it: it is the middle of the body, so an
error there is shared rather than levered, and every limb hangs off it. **Still unit-free** — the
hip's height comes from the same array.

## ★★★ THE SHAPE OF THIS MISTAKE

    the problem was      `hip_height` and `rest_positions` in different units
    the fix removed      the unit assumption                        CORRECT
    the fix also changed the ANCHOR, silently, as a side effect     NOT NOTICED

★★ **A fix that changes two things has to be judged on both.** The unit problem was real and the
repair was right; the anchor change rode along unexamined and cost 5x the accuracy — and it took
a screenshot, an on-device readout that did not exist a few turns ago, and one printed comparison
to find.

★ Sequence that worked, third time this session: **print the two candidates side by side and let
the numbers say which.** Reasoning had already produced three wrong explanations for the head; it
would have produced more here.

---

# ★★★ TRANSFORM AXES — making the invisible quantity visible

A `transforms` checkbox beside `skeleton`, and an `axis length` slider (0.01-0.4 m) that appears
only when it is on. Red X, green Y, blue Z — the near-universal convention, so the picture needs
no legend. Drawn for **both** the capture's joints and the robot's bodies, in the same display
frame, so the two can be compared directly.

## ★★ WHY THIS IS THE RIGHT TOOL FOR THIS PROJECT SPECIFICALLY

Half the hardest bugs here were frames disagreeing invisibly:

    a foot pitched the wrong way             the sign was unmeasurable until a probe was written
    a head target 1.5 m into the ground      three wrong hypotheses before the targets were printed
    a scale anchored on the top of the skull 8.8% on every target, found only by comparison
    a 90-degree rest convention              read as per-body disagreement for two turns

★★★ **Every one was an orientation nobody could see.** Three lines per body turn that into
something you look at.

## ★ One detail that would have made it a diagnostic that LIES

The robot solves in Z-up; this view is Y-up. The axes get the **same conversion the positions
get**, one line below them. An axis drawn in the wrong up-convention would look authoritative and
be wrong — **worse than not drawing it**, and exactly the class of error the tool exists to catch.

---

# ★★★ THE BALL AT THE ORIGIN: DRAW AND POSE DISAGREED ABOUT WHETHER THE ROBOT EXISTS

    poseRobot   gated on `if (s.show_robot)`
    drawRobot   called UNCONDITIONALLY

★★★ **So with `show_robot` false the robot was never posed and still drawn** — every body at its
zeroed position, which piles the geoms into a ball at the origin. **That looks exactly like a
solver that has collapsed**, and it is not a solver problem at all.

## ★★ WHY IT SURVIVED A DOZEN TURNS

The comment above the draw explained why drawing is not gated on **`show_skeleton`** — a different
flag, and correct reasoning. **It was read as covering `show_robot` too.** A correct comment about
one flag standing next to code that ignores a second one, and the failure it produced was
plausible enough to be blamed on the retarget three separate times.

★ Fixed: no pose, no draw.

## Also this turn

★ **The transform axes work** — visible in the screenshot, red/green/blue on every joint and body,
with the length slider.

★ The `→` in the new radio labels rendered as `?` because the UI font has no glyph for it. **A
label that renders wrong is worse than a plain one**, so they are ASCII now: `use Geno dance1` /
`use Mixamo drop kick`.

★★ Added `posed {d}` to the readout. **The two failures now read differently**: `bodies 0/18`
means the match table failed; `bodies 18/18 posed 0` means the pose function is not being reached.
Previously both showed the same ball.

---

# ★★★ "STILL SMALL AT ORIGIN. EXPANDS A BIT AT ZERO TARGET PULL."

★★★ **That second sentence is the whole diagnosis.** At pull 0 targets come from `retargeted`; at
1 they come from `positions_robot`. If the robot looks better at 0, **`positions_robot` is
collapsed** — which means the SCALE, not the solver, not the draw.

## The cause: my own hip anchor, unchecked

`target_parents[joint] < 0` finds the skeleton's ROOT, and **a root's rest height is not reliably
a hip height.** Depending on how a rig is authored it can be zero or the whole figure. The anchor
change was right in principle — the harness's 0.0097 is a hip ratio — and I never checked that
the field I read was the quantity I meant.

★★ **A scale is a DIVISOR applied to every target, so a wrong one does not degrade the result, it
destroys it.** Two turns went to a ball at the origin: first blamed on the solver, then on
draw/pose disagreement (a real bug, separately fixed), and only named by Simon noticing what the
pull slider did.

## The fix, and the rule it restores

    a hip sits between 45% and 60% of a standing figure's height

★ Outside that range it is not a hip, whatever the topology says, and the total-height anchor —
8.8% off but never catastrophic — is the safe fallback. **A derived quantity needs a range check
because its failure is silent and total**, the same shape as the task array that truncated to a
third of the robot.

## ★★★ AND THE SCALE IS NOW ON SCREEN

      capture scale 0.00970  (hip 0.830 m)

★★★ **A robot 10x too small and a robot in the wrong place look identical from outside.** One
number names which — and the two turns spent on this would have been one line of reading. Every
diagnostic added this session came from the same realisation: **the thing that went wrong was
never the thing on screen.**

---

# ★★★ "FIND WHERE THE ROBOT BONES END UP"

Every aggregate says the machinery ran:

    capture scale 0.00970   (matches the harness exactly)
    bodies 18/18            the table resolved
    samples 81              the samples built
    posed 21179             the pose function runs every frame

★★★ **And still a ball.** None of those numbers says WHERE anything is. **A root at the origin
and a root in the right place produce identical counts** — which is why four diagnostics in a row
came back clean while the picture stayed wrong.

## Two numbers that separate the remaining possibilities

      robot span  X x Y x Z m        near zero = COLLAPSED
      root at     x,y,z              good span, wrong place = PLACEMENT

★★ Those are the two things that have been confused for three turns. A collapsed robot and a
displaced robot look the same from outside at this size, and every metric so far measured
*quality*, not *position* — the fit metric compares body to capture joint, so it is large for
both.

★ Shipped. **The next screenshot answers it directly** instead of narrowing by elimination.

## ★★ WHAT THIS SEQUENCE HAS BEEN

    turn 1   blamed the solver              wrong
    turn 2   found draw/pose disagreement   a REAL bug, fixed, not this one
    turn 3   found the hip anchor           a REAL bug, fixed, not this one
    turn 4   added the scale readout        proved the scale is right

★★★ **Two genuine bugs found while chasing a third that is still open.** Each was worth fixing
and none was the answer — and the reason it took four turns is that the instrument for "where is
it" did not exist until now, while instruments for "is it good" were plentiful.

---

# ★★★ THE SPAN READOUT NAMED IT IN ONE SCREENSHOT

      robot span 0.24 x 0.42 x 0.41 m     a 1.5 m robot curled into 0.42 m
      root at 0.02,-0.02,-0.02            at the ORIGIN
      capture scale 0.00970               "correct"

★★★ **Collapsed, not displaced** — which the previous four diagnostics could not distinguish. And
Simon's other observation closed it: **the drop kick works and the dance does not.**

## The cause, and it is a repeat

`captureScale` read `rest_positions` and the result was applied to `source.positions`. **Two
arrays, and nothing guarantees they share units.** Mixamo's happen to agree; Geno's do not.

★★★ **This is the same bug this session already fixed once** — `hip_height` in metres against
`rest_positions` in centimetres. The lesson was written down as *"a scale derived from one
quantity cannot disagree with itself"*, and then reintroduced two turns later in a different pair
of fields. **Writing a lesson down is not the same as applying it**, and the second instance was
harder to see because both fields live on the same struct and are named alike.

## The fix: TOTAL BONE LENGTH, from the array being scaled

    a height changes when the figure crouches     -> a scale that moves every frame
    bone lengths are POSE-INVARIANT               -> the same clip gives the same scale always

★ Measured on the capture from `source.positions` — the very array the scale multiplies — against
`robot_total_bone_length_m = 3.722`, which the harness measured. **The unit cancels by
construction**, and it cannot drift between arrays because there is only one.

## ★★ AND THE DEFAULT NOW SHOWS THE BROKEN CASE

`robot_source` defaulted to the drop kick so the least-tested path would be on screen. **But the
drop kick works and the dance does not**, so the default was hiding the broken case behind a
working one — every screenshot began with a manual toggle.

★ **A default should show whatever is most likely to be wrong.** Changed to the dance.

---

# ★★★ THE SCALE, UNDERSTOOD PROPERLY — four wrong answers and what each was missing

    1. `hip_height` / `rest_positions`   two fields, two UNITS            -> off by 100x
    2. total height                      head and neck differ most        -> 8.8% every target
    3. total bone length                 **65-78 capture joints vs 18 robot bodies**  -> half size
    4. mapped pairs only                 same anatomy, both sides         -> agrees with harness

★★★ The third is the one worth understanding. Summing EVERY capture bone counts fingers, toe
joints and a five-link spine that the robot does not have, inflating the capture's total by 1.7x.
**A ratio between two different anatomies is not a scale** — it is a statement about how many
bones each figure has.

## What the right answer needs, all three at once

    POSE-INVARIANT     bone lengths, not heights: a crouch must not change the scale
    UNIT-CANCELLING    measured in the very array the scale multiplies, not a sibling
    ANATOMY-MATCHED    only over pairs the retarget says correspond

★★ **Each earlier attempt had one or two of these and never all three.** That is why each fix
looked principled and each failed differently — and why "take a step back" was the right
instruction: the property list is what was missing, not another candidate.

## Verified, not assumed

      MAPPED-PAIR SCALE 0.00940   (robot bones 3.907 / capture 415.518)   harness uses 0.00970

★★★ **3% apart, from two completely independent derivations** — the harness's from hip height,
this from mapped bone totals. That agreement is the evidence; the previous three were shipped on
reasoning alone and each was wrong.

## ★★ AND BOTH ANCHOR CONSTANTS DELETED THEMSELVES

`robot_height_m` and `robot_total_bone_length_m` are gone. **`captureScale` measures both sides in
the same loop from the same correspondence, so it needs no whole-body constant at all.** A
constant that must be kept in step with a model is one that will drift — one of them was already
wrong (1.445 against a measured 1.470) within a turn of being written.

---

# ★★★ WHAT IS ACTUALLY LEFT

## Closed this turn

★ **The hand asymmetry is NOT a model bug.** The two hands are correctly mirrored — `.144 .144
.144` / `.144 -.144 .144`, `zaxis 1 1 1` / `1 -1 1`. **The asymmetry is in the CAPTURE's rest
pose**, so the rest check is doing exactly its job: catching a per-side correspondence problem
rather than inventing one.

★ **Stale comments in the example replaced.** Two blocks still described `poseFromRetarget` and a
270-line duplicate loop — accurate when written, superseded by the point cloud. **A comment naming
the wrong function is how three of this session's misdiagnoses started**: the `drawRobot` comment
that explained `show_skeleton` while the code ignored `show_robot` cost three turns on its own. It
reads as documentation and behaves as misdirection.

## Genuinely remaining, in order of value

    1. THE SIX MECHANISMS, still in `robot.zig`, called only by their own tests
       `poseFromRetarget` (8 harness refs), `solveTwoBoneLimb` (4), `aimBoneWithTwist` (1),
       `rotationBetweenDirectionPairs` (1), `hingeAngleForFlexion` (0), `maximumFlexion` (0).
       **The shipped path uses none of them.** Two are already dead outright.

    2. THE HANDS' correspondence — the rest check names them every run; they need a construction
       that does not ride either figure's rest frame, as the feet's floor projection does not.

    3. RE-SWEEP the four weights on the drop kick, using the on-screen readout. Every one was
       chosen against Geno, and **a weight is a ratio against the other terms.**

## ★★ THE HONEST STATE OF THE MEASUREMENTS

      torso 4.0-8.2   arm 1.7-9.7   forearm 0.5-3.3   thigh 2.9-8.3   shin 0.9-2.4
      worst pop 9.2   (from 155)    visual fit 0.027 m in the harness

★★★ **All measured on Geno in the harness.** The drop kick is only measured by the on-screen
readout, and the example and harness now share the same library — but **the example still builds
its own inputs**, which is where the last four bugs lived: the scale, the anchor, the units, the
anatomy mismatch. That conversion is the next thing that should move into the library.

---

# ★★★ `captureScale` MOVED TO THE LIBRARY, WITH ITS PROPERTIES AS ASSERTIONS

**The last four bugs all lived in this one conversion** — the scale, the anchor, the units, the
anatomy mismatch — in the example, where no test could reach them. It is now
`robot.captureScale`, and the harness asserts what makes it correct rather than what it currently
returns:

    AGREES            within 0.0005 of the independently-derived hip-height scale (0.0097)
    POSE-INVARIANT    squash the skeleton's Z by half -> the scale moves LESS than the squash,
                      because horizontal bones are untouched. **A height-based scale would move
                      by the full factor.**
    UNIT-CANCELLING   the same skeleton in centimetres gives the same scale in metres

★★★ **Asserting the properties rather than the value is what stops a fifth wrong scale.** Each of
the four looked principled; a value test would have passed for whichever one was current, and
each of these three assertions fails for a different one of them.

## ★★ AND A DELETION I DECIDED **NOT** TO MAKE

`hingeAngleForFlexion` and `maximumFlexion` have zero callers outside their own tests, and the
plan listed them for removal. **Left in place**: they are small, tested, exported functions
encoding the cone relation for non-perpendicular hinges — **a legitimate public API, not dead
weight.** Unused by one example is not the same as useless, and a library is not a program.

★ The same reasoning does NOT protect `poseFromRetarget` and the five mechanisms around it: those
are an alternative IMPLEMENTATION of what `solvePointCloud` now does, so they carry divergence
risk that a self-contained geometric helper does not. **That is the distinction worth drawing
before deleting anything** — duplication is the liability, not disuse.

---

# ★★★ IS THE CLEANUP COMPLETE? AUDITED: NO — and here is exactly where

## What IS done

    buildPointSamples   lib=1  example=0  harness=0     one definition
    solvePointCloud     lib=1  example=0  harness=0     one definition
    PointSample         lib=1  example=0  harness=0     one definition
    captureScale        lib=1  example=1 (a wrapper)    one implementation

## ★★★ WHAT IS NOT

**1. The harness builds its own samples AND calls the library.** Five `samples[sample_n] = .{...}`
constructions remain beside two `rbt.buildPointSamples` calls. It is a hybrid: the leaf
construction comes from the library, the body-origin, child-origin and off-axis samples are still
local copies.

**2. The harness never calls `solvePointCloud`.** Zero references. It runs its own `ikStep` loop
with its own options. **So the test that reports torso 4.0, forearm 0.5 and pop 9.2 is measuring a
partial reimplementation of the shipped solve** — which is precisely the condition that produced
seven divergences, and the posture weight of 0.02 against 0.15 was found inside this exact gap.

★★ **This is the most important remaining item and it is not cosmetic.** Every number quoted in
these notes comes from that test.

**3. The five superseded mechanisms have zero real callers.**

      poseFromRetarget, solveTwoBoneLimb, aimBoneWithTwist,
      rotationBetweenDirectionPairs, fitBodyRotation

★ Their only appearances in the example are two COMMENTS. They are an alternative implementation
of what `solvePointCloud` does, so unlike `hingeAngleForFlexion` they carry real divergence risk.

**4. The hands' correspondence**, named every run by the rest check.

**5. The weights**, all four swept against Geno only.

## ★★ THE HONEST SUMMARY

    the SHIPPED path is clean         one definition of everything it uses
    the TEST path is not              it measures a partial copy of the shipped solve

★★★ **The example was cleaned and the harness was left half-converted**, which is the same
asymmetry that started this whole thread — except reversed. **Any number in these notes should be
read as "measured on something close to what ships", not "measured on what ships"**, until item 2
is done.

---

# ★★★ ITEM 2 DONE — the harness now measures the code that ships

The `WHOLE BODY` test's solve was a hand-written copy of `robot.solvePointCloud`: the same qpos
reset, the same root placement, the same target construction, the same iterate-until-flat loop.
**Seven divergences came from exactly this arrangement, and the last one lived inside those very
lines** — a posture weight of 0.02 here against 0.15 in the example.

    the local `Sample` struct   -> `rbt.PointSample`, the library's own type
    the hand-written solve      -> one `rbt.solvePointCloud` call

★★ A struct duplicated is a struct that drifts, and using the real one is what let the samples go
straight to the shipped solve without a conversion step.

## The numbers moved, and that is the finding

                    reimplementation      the shipped solve
      torso            4.0-8.2               3.4-10.4
      arm              1.7-9.7               0.6-13.6
      forearm          0.5-3.3               0.5-5.4
      thigh            2.9-8.3               1.9-5.0

★★★ **Close, but not the same.** The copy was faithful enough to look right and different enough
to report different numbers — which is precisely why this class of bug survives so long. **Every
figure in these notes before this change described something adjacent to what ships.**

★ Two small differences also had to be fixed to make the call: the harness never converted the
capture's ROTATIONS to Z-up (the inlined construction had not needed them), and the root's target
was found by a body scan rather than taken from body 1. **Both were latent inconsistencies the
copy had hidden.**

## Remaining, unchanged

    1. the harness still builds body-origin, child-origin and off-axis samples locally
       (the leaf construction already comes from the library)
    2. the five superseded mechanisms, zero real callers
    3. the hands' correspondence
    4. the weights, swept against Geno only

---

# ★★★ ITEM 1 DONE — the harness builds nothing itself

~210 lines deleted from `WHOLE BODY`: body origins, child origins and off-axis twist points, a
second implementation of `robot.buildPointSamples` **whose result was then OVERWRITTEN by the
library call twenty lines later.**

★★ The work was already redundant and the duplication was still costing: the two copies could
disagree about weights, thresholds or the DOF-through-the-chain rule, and nothing would have said
so. **Redundant is not the same as harmless.**

## ★★★ THE PROOF THE DELETION WAS SAFE

      before   f40 TORSO 3.4  arm 6.9  fore 0.6  thigh 1.9   ...  81 samples
      after    f40 TORSO 3.4  arm 6.9  fore 0.6  thigh 1.9   ...  81 samples

**Identical to the decimal.** In this project that pattern has usually meant a broken edit — here
it means the opposite, and the difference is that the change was a DELETION of code proven dead by
the overwrite. **Same signature, opposite conclusion, and only the surrounding argument
distinguishes them.**

## The test now measures the shipped path end to end

    samples   `robot.buildPointSamples`
    solve     `robot.solvePointCloud`
    scale     `robot.captureScale`

★ Nothing in `robot_mjcf.zig` reimplements any of it. **Every number in these notes now describes
what runs on the device** — a claim these notes have made implicitly for forty sections and could
not support until this turn.

## Remaining

    2. the five superseded mechanisms, zero real callers
    3. the hands' correspondence
    4. the weights, swept against Geno only

---

# ★★★ ITEMS 2 AND 4 — one closed by NOT deleting, one by re-measuring

## Item 2: `poseFromRetarget` KEPT, deliberately

★★ It has **five real call sites** — the scorecard, arm focus, the pipeline comparisons. So it is
not dead code: it is an actively tested alternative, and **those tests are what justify the
replacement.** 155 degrees of worst-frame pop against 9.2, a forearm that could not get below 28,
legs pinned on half the frames. Delete it and the evidence for the point cloud goes too.

★★★ **It is not a divergence risk in the way a duplicated implementation is, because it is not
supposed to agree.** The seven divergences this project fixed were two copies of the SAME thing
drifting; this is one copy of a DIFFERENT thing, kept as a baseline.

    disuse is not the liability — DUPLICATION is

★ Marked clearly at its definition so no new code calls it by accident. **That is the whole cost
of keeping it**, against losing the measurements that make the current design defensible.

## ★★★ Item 4: the pull re-swept, on the shipped path for the first time

      pull   torso   arm   forearm   thigh   shin    sum    POPS
      0.0     7.3    8.6     4.6      2.6    1.1    24.2    9.2
      0.5     6.8    7.2     3.1      2.9    1.45   21.5    9.2
      1.0     6.4    6.3     2.1      3.3    1.9    20.0    9.2

★★ **1.0 confirmed**, and the shape is informative: it wins the torso, arm and forearm and loses
the legs. After `humanoid_flex2` the upper body's proportions match the capture well, so pulling
those onto its own joints costs nothing — while the legs still prefer the exactly-reachable
retargeted skeleton.

★★★ **The pop is 9.2 at every value.** The remaining discontinuity is not about where targets sit
at all, so no setting of this dial will move it. **A sweep that changes nothing is a result**: it
rules out a whole family of explanations for the last 9 degrees.

## What is left

    3. the hands' correspondence — named every run by the rest check
    ★ and the weights other than the pull, which the same reasoning says should be re-swept now
      that the objective they were tuned against has been replaced by the real one

---

# ★★★ THE POPS LOOP IS **ALSO** A REIMPLEMENTATION — found, attempted, reverted

Sweeping the posture weight moved nothing: 9.2 at 0.15, 0.5 and 1.5. Last time that signature
appeared it meant a genuine branch flip. **This time it meant the sweep could not reach the code.**

★★★ The `WHOLE BODY` test has TWO solve loops: the accuracy loop (four frames, printed per bone)
and the POPS loop (600 frames, the worst-discontinuity number). **Converting the accuracy loop to
`solvePointCloud` left the pops loop hand-rolled with its own literal weights** — so the swept
value went to one loop while the number came from the other.

    **a sweep that cannot reach the code it is sweeping reports "no effect" and looks like a
    finding**

★★ That is a worse failure than a plain divergence, because it produces a confident negative
result. The earlier "the pops are a branch flip" conclusion was reached the same way and **should
be re-derived once this loop is converted.**

## The conversion was attempted and reverted

★ The call went in cleanly, but the surrounding brace repair put the POPS log inside the frame
loop — it printed 600 times and reported 0.0. Restored from the snapshot; **the shipped path and
all numbers are unchanged**, and `check` is green.

★★ What made it hard is worth recording: the block spans two nested loops with `seeded`,
`qprev` and `previous_dir` threaded through them. **The accuracy loop was a clean extraction and
this one is not** — it needs the frame loop restructured first, not a substitution.

## State

    accuracy loop   `solvePointCloud`      ✓ shipped path
    pops loop       hand-rolled            ✗ still a copy, and it owns the headline number

★★★ **So the 9.2 figure is still from a reimplementation**, and the honest reading of every pop
number in these notes is "close to what ships, not what ships". The accuracy numbers no longer
carry that caveat; the pop number still does.

---

# ★★★ THE POPS LOOP CONVERTED — and the headline number was wrong by 3x

      the reimplementation reported     9.2 deg
      the SHIPPED solve reports        27.9 deg   at lower_arm_left

★★★ **Every pop figure quoted in these notes since the point cloud landed was from a copy that
under-reported by a factor of three.** The arc "155 -> 9.2" is really "155 -> 27.9" — still a
5.5x improvement, and still the largest single result of the project, but not what was written.

## Why it was wrong, and why the error was invisible

★★ The copy iterated 120 times with its own literals; `solvePointCloud` runs its own convergence
rule and its own barrier and posture handling. **Neither was obviously wrong** — they were two
plausible implementations of the same idea that produced different answers, which is exactly what
divergence means and exactly why it cannot be caught by reading.

★ It also produced a false NEGATIVE last turn: sweeping `posture_weight` reported "no effect at
0.15, 0.5 and 1.5" because the swept value reached the accuracy loop while the number came from
this one. **A sweep that cannot reach its code reports no effect and looks like a finding.**

## What made this attempt succeed where the last failed

    last turn   replaced a span that crossed brace depths   -> the log ended up inside a loop
    this turn   read the nesting FIRST, replaced a span at
                equal depth on both ends, counted braces    -> depth 0 first try

★★★ **The technique that has worked all session, applied deliberately instead of after a failure.**

## State: no reimplementation remains

    rbt.ikStep hand-rolled solves in the harness   **0**
    rbt.solvePointCloud calls                       2

★ `buildPointSamples`, `solvePointCloud` and `captureScale` each have exactly one definition, and
the test calls all three. **Every number the harness prints now describes the shipped path** — the
accuracy figures, the visual fit, and finally the pop.

---

# ★★★ THE BRANCH-FLIP CONCLUSION, RE-DERIVED HONESTLY

      posture 0.15   worst 27.9 deg at lower_arm_left
      posture 0.60   worst 27.9
      posture 2.00   worst 27.9

★★★ **Identical across a 13x range — and this time the sweep genuinely reaches the code**, because
both loops now call `solvePointCloud`. The same result was reported two turns ago from a sweep
that could not reach the pops loop; **that was an artefact, this is a finding.**

★★ So the reading stands, now on solid ground: a quadratic pull toward the previous frame prevents
WANDERING and cannot prevent JUMPING between two configurations that both satisfy the targets.
`lower_arm_left` is the shoulder pair again — 2 DOF, two clamped answers of nearly equal cost.

★ The lever is therefore the MODEL (a third shoulder axis already helped once, 59 -> 14 on the old
measurement) or a HARD bound on `|q − q_prev|` that changes the feasible set. **Not another
weight**, and now that is known rather than assumed.

## ★★ THE DOCS CORRECTED

`readme.md` and `src/web/readme.html` both claimed the discontinuity "fell from 155 to 14 degrees".
**Corrected to 28** — the figure measured on the shipped solve.

★★★ Worth stating plainly: **a public claim was wrong for several turns because it was copied from
a test that measured a reimplementation.** The claim was checked when written — against the number
the harness printed — and the number was the problem. **Verifying a citation against a measurement
does not help when the measurement is of the wrong thing.**
