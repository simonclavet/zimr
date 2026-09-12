# ★★★ THE FOOT, DONE PROPERLY — three points, no rules

## What was wrong

    matched   Geno's ANKLE JOINT      ->  the robot's foot ORIGIN
    but       the ankle is inside the leg, above and BEHIND the heel

**A joint is not a contact point.** Every patch since — the 24.6-degree pitch, the always-level,
the contact blend — has been compensating for a correspondence that was wrong to begin with.

## ★★★ THE T-POSE STATES THE OFFSETS EXACTLY

Geno stands FLAT on the floor in its T-pose. Therefore, in that pose:

    heel is ON the floor, behind the ankle
    toe  is ON the floor, ahead of the ankle

So both offsets are measurable, once, with no guessing:

    floor      = the lowest point of the capture in the T-pose
    heel_world = ankle projected straight down to the floor, moved back along the foot axis
    toe_world  = ToeBase projected straight down to the floor
    heel_local = R_ankle_tpose⁻¹ · (heel_world − ankle_world)      a CONSTANT in the ankle's frame
    toe_local  = R_ankle_tpose⁻¹ · (toe_world  − ankle_world)

★★ Per frame, they ride the capture's own ankle rotation:

    heel_target = ankle_pos + R_ankle · heel_local
    toe_target  = ankle_pos + R_ankle · toe_local

**When Geno's foot is flat, both land on the floor. When Geno is on tiptoe, the heel lifts and the
toe stays down. No rule, no threshold, no blend** — the capture's own foot does it.

## ★★★ THE ROLL: A THIRD POINT ABOVE THE ANKLE

Simon: *"the foot roll needs to come from another virtual foot or toe top point."*

    up_local = R_ankle_tpose⁻¹ · (0, 0, h)        a point directly ABOVE the ankle at T-pose

★ Three points — heel, toe, and one above — are non-collinear, so they pin the foot's full
orientation including roll. **And the third is defined by the same construction as the first two**:
a fixed offset in the ankle's frame, measured once in the pose where both figures agree.

## Why this is better than every previous attempt

    the 24.6-degree pitch     matched a SKELETAL LINE to a SOLE          wrong kind of thing
    always-level              forced a pointing foot flat                ignored the capture
    contact blend             invented a threshold and a rule            a decision the data should make
    THIS                      three fixed offsets in the ankle's frame   no decision at all

★★★ **The correspondence is stated once, at rest, and never decided again.** That is the same
principle that fixed the torso (two directions), the limbs (retargeted skeleton) and the twist
(sample points) — and it is the one thing the foot never had.

---

# ★★★ RESULT

      thigh   3.5 -> 2.28 deg mean      **-35%**
      shin    1.75 -> 1.9               held
      torso, arm, forearm               held
      worst pop 14.3 -> 14.2

★ Sole tilt now reads 13-51 degrees from horizontal, and **that is correct**: the foot follows
Geno's actual foot angle instead of being forced flat. A single small number there would mean the
levelling rule was back.

## ★★★ WHY THIS IS THE RIGHT SHAPE AND THE OTHERS WERE NOT

    the 24.6-degree pitch    matched a SKELETAL LINE to a SOLE     wrong kind of thing
    always-level             forced a pointing foot flat           ignored the capture
    contact blend            invented a threshold and a rule       a decision the data should make
    THIS                     three fixed offsets, measured once    no decision at all

★★★ **The correspondence is stated once, at rest, and never decided again.** That is exactly the
principle that fixed the torso (two directions), the limbs (retargeted skeleton at the robot's own
lengths) and the twist (sample points) — and it is the one thing the foot never had.

★★ **The contact behaviour is not implemented anywhere.** It emerges: when Geno's foot is flat,
both offsets land on the floor because that is where they were measured; when Geno rises onto its
toes, the heel offset lifts with the ankle's rotation. **A rule I wrote by hand was replaced by a
consequence of the geometry**, which is what Simon asked for.

## What is still approximate

★ The heel offset uses the ankle projected straight DOWN to the floor. A real heel is also behind
the ankle, and Geno's actual heel position is not a joint the BVH carries. **If the foot reads
short on the device, that backward offset is the thing to add** — and it would be one more
constant in the same frame, not another rule.

---

# ★★★ `humanoid_flex2.xml` — BALL JOINTS AND A TOE BONE

Simon: *"match the geno anim perfectly, by replacing some bones with 6dof joints."*

## ★★★ THREE DOF, NOT SIX — and the reason matters

**Geno's animation is ROTATIONS on a fixed skeleton.** A BVH stores an offset per bone and a
rotation per frame; the offsets never change. So matching it exactly needs **3 rotational DOF per
joint and matching bone lengths — not 6.**

★★ Six would let the robot express MORE than the capture itself can, and would let bones detach
from each other. **The extra three would be fitting noise**, and there is nothing in the source
for them to fit.

## The changes

    elbow, knee, ankle    hinge/2-DOF  ->  BALL     the capture carries a full rotation at each
    toe bone added        foot was ONE rigid segment; it could not flatten its sole while
                          pointing its toe, which is what a foot does at every push-off
    actuators removed     for every joint that became a ball — a scalar motor drives ONE
                          coordinate and a ball has three. This model is POSED, not driven.

                    flex 1        flex 2
      forearm         4.7          3.7      -21%
      torso           6.9          6.3
      arm             8.5          8.05
      shin            1.9          1.55
      thigh           2.3          3.9      worse
      SOLE TILT     13-51 deg     5-21      **the foot can now flatten while the toe points**
      worst pop      14.2         14.3

★★ **The sole tilt range halving is the toe bone doing its job.** With one rigid foot, a pointed
toe meant a tilted sole; with two segments the ankle can level while the toe extends.

★ The thigh got worse (2.3 -> 3.9), which is the usual shape when new freedom appears elsewhere:
the solve redistributes. Worth a weight re-sweep, since the sample set changed again.

## ★ Two build failures worth recording

    `UnknownName`     the ACTUATORS still named joints that had become balls or been removed.
                      A model is not just its bodies — every cross-reference has to follow.
    line-length       `humanoid_flex2.xml` is one character longer than `humanoid_flex.xml`,
                      which pushed two source lines to 121 columns. **A filename change is a
                      source change.**

---

# ★★★ ADDING A BONE CHANGED WHICH CODE RAN

The toe bodies had no rows in `lafan_to_humanoid`, so they were **unmapped** — and that cost the
foot its heel/toe/up construction without touching a line of it.

★★★ **That construction fires on LEAF bodies, and the foot stopped being a leaf the moment it
gained a child.** Its samples silently fell back to the generic path. **No measurement of the toe
bone itself would have shown this**, because the toe was not the thing that changed behaviour —
the foot was.

    samples  62 -> 76 once both toes were mapped

      shin     1.55 -> 1.23      better
      torso, arm, forearm         held
      thigh    3.9 -> 4.4        slightly worse

## ★★ THE GENERAL SHAPE, WHICH THIS PROJECT HAS NOW SEEN SEVERAL WAYS

    a body-sized task array      truncated 43 samples to 17
    an unmapped toe              turned the foot from a leaf into an interior body
    a renamed joint              left the actuators pointing at nothing

★★★ **Structural edits change which BRANCH runs, not just which numbers come out.** Each of these
produced plausible output from code that had quietly stopped doing what it was written to do —
and in each case the give-away was a number moving for no stated reason, in a place nobody had
edited.

★ Worth a standing check after any model change: **how many samples does each body get now?** It
is one line to print and it would have caught all three.

---

# ★★★ "ALL BONES 10 cm OFF TO THE SIDE" — nine metrics, all blind to it

Simon: *"why is the result so far? It looks like all bones are 10 cm off to the side."*

## ★★★ THE METRICS COULD NOT SEE IT, AND THAT IS THE REAL FINDING

    torso axis, arm, forearm, thigh, shin, sole tilt, pops, best-possible, jitter

**Every one is an ANGLE.** Shift the whole robot a metre sideways and not one of them changes by
a single degree. **Nine instruments, built over dozens of turns, and none could see the figure
being in the wrong PLACE.**

★ Added `OFFSET`: the mean distance between each mapped body and its capture joint. **One line,
and it is now the only metric that can see a translation at all.**

## The cause

★★ "All bones off by the same amount" is the signature of a bad ANCHOR: the retargeted skeleton
is built outward from one body, so an error there shifts every bone equally.

★★★ The walk anchored the ROOT — which on `humanoid.xml` is the TORSO, whose origin is not where
the capture's `Spine3` sits inside Geno's chest. **`solveRestPoseFromSource` already knew this**
and anchors the PELVIS deliberately, "because anchoring the root lifts the whole figure by a
spine". **The per-frame version never inherited the lesson**, twenty sections later.

## The fix, which needs no anchor at all

★★ Build the SHAPE first, then place it: translate so the MEAN of the mapped joints matches the
capture's. **Every body votes, no single one can be wrong, and there is no privileged body to
choose.**

      mean body offset   3.4 cm      (angles unchanged, as expected)

★ Choosing the pelvis instead would have worked too — and would have been another privileged
body, which is the thing that broke twice. **A least-squares placement has no such failure mode.**

---

# ★★★ "THE BONES SHOULD MATCH WORLD POSITIONS BETTER, NO?" — yes, and the reason changed under us

Simon, twice, from screenshots: *"the whole guy is really 10 cm to the side."*

## ★★ SPLITTING THE ERROR SETTLED IT IN ONE RUN

      solve-miss  0.019 m     the solve reaches the targets it is given
      target-off  0.032 m     **the targets are not where Geno's joints are**

★★★ **The solve was never the problem. The targets were in the wrong place ON PURPOSE.** Measuring
only their sum could not tell those apart — which is why the previous fix moved a number without
moving what Simon could see.

## Why the targets were deliberately wrong, and why that expired

The retargeted skeleton uses the ROBOT's own bone lengths, so the chain accumulates away from the
capture. **That was the right call when the arms were 24-29% too long**: no world-position target
was reachable, and the free root slid around to spread a residual it could never remove.

★★★ **`humanoid_flex2.xml` fixed that in the MODEL** — bone ratios are now 0.99-1.03. So the
workaround's cost stayed and its benefit vanished.

      pull   torso   arm   forearm   thigh
      0.0     6.0    7.6     4.6      4.6      retargeted skeleton only
      0.5     5.6    6.4     2.9      4.7
      1.0     5.4    6.9     2.1      4.7      **the capture's world positions, directly**

★★ **Forearm 4.6 -> 2.1, torso 6.0 -> 5.4, and the figure now stands where the dancer stands.**

## ★★★ THE LESSON

**A workaround outlives the problem it was built for.** The retargeted skeleton was a good answer
to a proportion mismatch; the model changed, and nothing re-asked whether it was still needed.
**Every compensation in a system should be re-tested when the thing it compensates for is
fixed** — and here the compensation was actively harmful, not merely redundant.

★ It is kept as a `position_pull` dial rather than deleted: a robot whose proportions do NOT match
a capture still needs it, and that is now a stated choice instead of a hidden assumption.

---

# ★★★ A METRIC THAT MATCHES VISUAL FIDELITY, AND WHAT IT IMMEDIATELY FOUND

Simon: *"tweak the robot and the algo for the best result, according to metrics that match visual
fidelity."*

## The metric

**What the eye integrates is where each bone IS, in the world, against where the dancer's is.**
Not angles — nine of those could not see a figure 10 cm out of place. Reported as MEAN and WORST:
the mean is the general impression, **the worst is the one bone that draws the eye**, and
averaging hides it.

## ★★★ IT NAMED THE 10 cm IN ONE RUN

      VISUAL mean 0.029   worst 0.097-0.110   at **waist_lower**, every frame

★ Then the T-pose said why:

      capture   chest->waist 0.313   waist->hips 0.088     the waist is 78% of the way down
      robot     chest->waist 0.260   waist->hips 0.165     the robot had it at 61%

**The robot's waist was in a different place than Geno's**, and since `waist_lower` maps to
`Spine`, that difference showed up as a fixed ~10 cm error on the body between torso and pelvis —
exactly what the screenshots kept showing.

## ★★ AND MATCHING GENO EXACTLY IS NOT THE BEST ANSWER

      split          visual mean   visual worst    worst pop
      61% (stock)       0.029      0.097-0.110       14.3
      70% (chosen)      0.027      0.061-0.074       14.2
      78% (Geno)        0.025      0.053-0.075       25.8

★★★ At Geno's exact split the pelvis segment is only 0.093 m, so small angles there swing it hard
and **the worst pop nearly doubles**. 70% keeps almost all the visual gain at no cost in
smoothness.

★★ **"Match the capture" is a goal, not a rule.** The best robot is not the one that copies the
dancer's proportions exactly — it is the one whose proportions let the SOLVE behave, and only a
sweep against two metrics could tell those apart.

## Where it stands

      VISUAL   mean 0.027 m, worst 0.061-0.074 m       from mean 0.029, worst 0.11
      angles   torso 3.1-10.1, arm 2.2-10.9, forearm 0.8-3.1, thigh 2.7-6.5, shin 0.9-2.3
      POPS     14.2 deg worst single frame             from 155 at the start of this arc
