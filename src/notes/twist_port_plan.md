# ★★★ THE TWIST-OFFSET RECIPE — worked out, and the plan to port it

Source: `intake/flomo_to_geno_bvh.py`, `compute_twist_offsets()` (lines 114-236) and its
application at line 363. This is FlomoGMR's own solution to the problem §13 spent eleven
candidate formulas failing to derive.

---

## 1. The math, worked out

### Setup, once, from the two REST poses

For each joint `J` with a child bone:

    d_robot   = normalize(rest_xpos[child] - rest_xpos[J])

★ In the ROBOT's LOCAL frame — and for a model whose rest orientations are all identity (which
`humanoid.xml` is, since it declares no `quat`/`euler` anywhere) **world equals local**, so this
subtraction of world positions IS the local direction. That equivalence is why the reference can
write it so simply, and it holds for us.

    d_src_world = normalize(tpose_pos[src_to] - tpose_pos[src_from])
    j_rot       = tpose_rot[J]                     the joint's SOURCE world orientation at T-pose
    d_target    = j_rot⁻¹ · d_src_world            the source direction, IN J's LOCAL FRAME

    R_twist[J]  = minimumAngleRotation(d_robot -> d_target)

★★ **BOTH DIRECTIONS ARE EXPRESSED IN THE JOINT'S LOCAL FRAME.** I computed mine in WORLD, which
is the single largest difference from the reference and makes the correction depend on where the
joint happens to be pointing rather than on the two skeletons' shapes.

★ `j_rot⁻¹` uses the SOURCE's world orientation because `R_twist` bridges FROM the source frame
TO the robot's; the source side must therefore be stated in source terms.

### Per frame

    q_corrected[J] = inv(R_twist[parent(J)]) · q_src[J] · R_twist[J]

on LOCAL rotations, walking each chain PARENT TO CHILD.

★★★ **THE `inv(R_twist[parent])` FACTOR IS THE PIECE I NEVER HAD.** The reference's own
explanation: *"undoes the parent's twist so it doesn't accumulate and distort children. Without
it, each joint in a chain would get the parent's twist baked in on top of its own."*

**My correction was `C · delta · conj(C)` — a similarity transform in world space with NO parent
term.** That is why it improved a shoulder and degraded the forearm below it: every child
inherited its parent's correction on top of its own.

### Why it is exactly right

    world_rot[J]_robot = world_rot[J]_src · R_twist[J]

so the robot's bone points at

    world_rot[J]_robot · d_robot = world_rot[J]_src · R_twist[J] · d_robot
                                 = world_rot[J]_src · d_target

★ **The bone direction matches the source's by construction** — not approximately, not after a
solve. That is the property none of the eleven derived formulas achieved.

### The frame map, confirmed

The reference documents it outright:

    BVH(x, y, z) -> MJ(x, -z, y)
    MJ quat (w, vx, vy, vz) -> BVH quat (w, vx, vz, -vy)

★ **The quaternion's IMAGINARY PART remaps exactly like a position vector.** Our position map is
already `(x, y, z) -> (x, -z, y)`, so it agrees — and this confirms the similarity-conjugation
used for rotations is equivalent to remapping the imaginary part, which is worth knowing because
the latter is cheaper and harder to get backwards.

---

## 2. What is different about `humanoid.xml`

The reference targets GENO — 75 joints, a shoulder, fingers, toes. Ours has 16 bodies.

| reference chain | ours |
|---|---|
| `LeftShoulder, LeftArm, LeftForeArm, LeftHand` | `torso, upper_arm_left, lower_arm_left, hand_left` |
| `Neck, Head` | `torso, head` |
| `LeftFoot, LeftToeBase` | `shin_left, foot_left` (no toe) |
| — | `pelvis, thigh_left, shin_left, foot_left` |

★★ **NO SHOULDER BODY**, so the arm chain starts at the torso and the shoulder's rotation has
nowhere to go — it must be absorbed into the torso or dropped. **NO TOE**, so the foot is a leaf
and gets identity, like the reference's `Head`.

★ **THE HAND PROXY TRANSFERS DIRECTLY.** The reference uses `MiddleFinger1` as the robot's
reference direction and `forearm->hand` as the source's, *"in T-pose the palm extends in the same
direction as the forearm"*. Our `hand_right` is a leaf with no child body — same problem, same
fix: use `lower_arm -> hand` on both sides.

---

## 3. The plan, in verifiable steps

Each step ends with the SCORECARD, and is kept only if its target stage improves and no earlier
stage regresses. Current baseline:

    1. torso ORIENTATION      50.6 deg
    2. upper arm POSITION    0.242 m
    3. upper arm DIRECTION    53.0 deg
    4. elbow BEND             77.1 deg
    5. upper arm TWIST        63.6 deg

**Step 1 — `computeTwistOffsets`, unit-tested on its own. ★ DONE.**
`robot.computeTwistOffset` + `robot.applyTwist`. `check` green, 0 lint.

  ★ The defining property is asserted directly across four cases, including the ~90 degree
  arm case the reference's docstring names and a diagonal bone matching `humanoid.xml`'s
  `lower_arm_left` at (.18, .18, -.18).

  ★★ **AND THE `inv(parent)` FACTOR IS PINNED AS LOAD-BEARING**: a second test builds a two-joint
  chain, checks the invariant `world_rot_robot = world_rot_src * R_twist` for BOTH joints, and
  then asserts that dropping the parent factor gives a DIFFERENT answer. **Without that last
  assertion someone simplifying the expression would silently reintroduce the exact bug this
  arc spent rounds on.**

  ★ An already-aligned pair must return EXACT identity, not near-identity — because the legs
  already match at rest and any drift there would accumulate through a chain. Asserted.

**Step 1 (original text) — `computeTwistOffsets`, unit-tested on its own.**
Build `R_twist` per body from the two rest poses. Verify the defining property directly:
`rotate(R_twist[J], d_robot) == d_target` to float precision, per joint. **That test needs no
capture, no frames and no scorecard** — it is pure algebra over two rest poses, and it either
holds or the port is wrong.

**Step 2 — apply `inv(parent) · q_src · self`, chains parent-to-child. ★ WIRED, AND IT
MEASURES WORSE.**

                        aim_twist   ported_twist
      torso ORIENT        50.6         54.1 deg
      upper arm DIR       53.0        119.4 deg
      elbow BEND          77.1         85.3 deg

  ★★ **THE ALGEBRA IS NOT THE SUSPECT.** `computeTwistOffset` and `applyTwist` pass their tests
  against the reference's own defining property, and those tests are independent of any frame
  convention.

  ★★★ **THE REFERENCE NEVER CONVERTS FRAMES AT ALL, AND THAT IS WHY.** Its Geno MJCF was
  GENERATED from the BVH skeleton — `generate_geno_xml.py mapped BVH(x,y,z) -> MJ(x,-z,y)` — so
  source and robot already share conventions, and the map is applied ONCE at the very end in
  `qpos_to_bvh`. **`humanoid.xml` is an independent model**, so a conversion IS needed here —
  but I inserted THREE (on `d_src`, on `j_rot`, on `q_src`) without checking whether they
  compose to identity or to a double application.

  ★ **A port is only faithful if its ASSUMPTIONS port too.** The reference assumes a robot built
  from the source skeleton; we do not have one. That assumption was invisible in the function
  being copied and visible only in a sibling script's name.

  ### ★★★ STRIPPED TO ONE CONVERSION — two stages improved, one regressed

                        aim_twist   ported(3 conv)   ported(1 conv)
      upper arm DIR       53.0         119.4            51.4   better
      elbow BEND          77.1          85.3            64.7   MUCH better
      upper arm TWIST     63.6          64.3           130.2   worse

  ★★★ **DROPPING `conj(j_rot)` TOOK DIRECTION FROM 119 TO 51 AND BEND FROM 85 TO 65.** The
  diagnosis held exactly: three frame conversions where the reference needs none, on a robot
  whose local frames do NOT follow the source's. `humanoid.xml` declares no body rotations, so
  its rest local frame IS the world frame — and pulling `d_target` into the SOURCE's local frame
  compared two different spaces.

  ★★ **TWIST REGRESSED TO 130 DEGREES**, which is a DIFFERENT failure from the two that
  improved. The ported recipe aims the bone and takes the rotation ABOUT it straight from
  `q_src`; **nothing chooses the bend plane.** `aim_twist` chooses it explicitly, which is why
  it still wins that stage and only that stage.

  ★★★ **SO THE TWO ARE COMPLEMENTARY, NOT COMPETING**: the ported recipe gets bone DIRECTION and
  BEND; `aim_twist` gets the PLANE. **Combining them — ported direction with an explicit twist
  choice — is the next step, and it is now supported by numbers rather than by argument.** That
  is the first time in this arc two approaches have been shown to fix disjoint stages.

  ★ (superseded) strip to ONE conversion, applied where the reference applies its map. The algebra test
  stays green throughout, which is exactly what makes this isolable — and `aim_twist` remains
  the scorecard's subject until the port beats it.

**Step 2 (original) — apply `inv(parent) · q_src · self`, chains parent-to-child.**
Then re-run the scorecard. **Expect stages 3-5 to collapse** (direction, bend, twist), because
the property above makes the bone direction exact. If they do not, the chain ordering or the
local-frame conversion is wrong, and step 1's test says which.

**Step 3 — the torso.**
It is the root and has no parent twist. `raw+yaw` at -90 was device-confirmed for it; the twist
recipe may replace that or may not apply, since the torso's "bone" is ambiguous. **Measure both
and keep the better** — stage 1 is 50.6 degrees and is the largest single error left.

**Step 4 — legs, using the same chains.**
`pelvis, thigh, shin, foot`. Legs already agree at rest (measured, dot > 0.95), so twist offsets
there should come out near identity — **which is itself a check on the port**: a correction that
comes out large for a limb known to match means the implementation is wrong.

**Step 5 — viewer and device.**
Only after the scorecard collapses. A screenshot before then tells us nothing we cannot already
measure, which is the discipline this arc learned late.

---

## ★ Two standing cautions

★★ **PORT IT, DO NOT RE-DERIVE IT.** This arc's record on deriving this exact thing: eleven
formulas, four device rounds, a correction on the wrong side, and a fix that helped one bone
while breaking the one below it. The reference is 120 lines with its reasoning written down.

★ **THE SCORECARD IS ALREADY BUILT AND HAS CAUGHT TWO FAKE NUMBERS.** Trust it, but re-check any
constant it names against the code it measures — both fakes were rulers that disagreed with the
thing being measured.

---

## ★★★ 4. WHERE THE ARM LANDED — all four approaches, measured

                    aim_twist   ported(3conv)   ported(1conv)   ported+twist
    upper arm DIR     53.0        119.4            51.4            66.2
    elbow BEND        77.1         85.3            64.7            64.7
    upper arm TWIST   63.6         64.3           130.2            64.1
    ---------------------------------------------------------------------
    sum of angles    193.7        269.0           246.3           195.0

★★★ **THE COMBINATION KEPT THE BEND (64.7, best of all four) AND FIXED THE TWIST (130 -> 64),
AT THE COST OF DIRECTION (51 -> 66).** That is not a wiring bug — it is **the 2-DOF shoulder
trade, confirmed a THIRD time.** Asking a two-DOF joint for a bone direction AND a rotation
about that bone is asking for three things.

★★ **BEST ACHIEVABLE PER STAGE**: direction 51.4 (ported), bend 64.7 (ported), twist 63.6
(aim_twist). **No single approach reaches all three, and on this model none can.** The ceiling
belongs to `humanoid.xml`'s shoulder, not to the algorithm.

★ `ported_plus_twist` is the best BALANCED option: wins bend outright, ties twist, gives up 13
degrees of direction. **Whether that trade is right is a judgement about what reads better on
screen — the first question in this whole arc that a measurement genuinely cannot settle.**

### What this establishes about the recipe itself

★ The ported recipe DOES work: it produced the best direction (51.4) and the best bend (64.7) of
anything tried, once the frame handling was corrected to suit an independent robot. **The port
was sound; the adaptation around it was not**, and the unit tests said so throughout by staying
green while the scorecard moved.

### Remaining, in order

1. **The TORSO at 54 degrees is now the largest single error** and has barely moved all arc. It
   is the root, has no parent twist, and `raw+yaw` was device-confirmed for it — the ported
   recipe may simply not apply to a body whose "bone" is ambiguous.
2. **Legs**, using the same chains. They already agree at rest, so their twists should come out
   near identity — a free check on the port.
3. **Device**, once the torso moves. Not before: the arm is at the model's ceiling and a
   screenshot cannot distinguish 51 degrees from 66 as reliably as the scorecard can.

---

## ★★★ 5. TWO FIXES, AND THE TORSO WAS NEVER AS BAD AS REPORTED

      stage                    before    after
      1. torso ORIENTATION      54.1      19.8 deg
      2. upper arm POSITION     0.238     0.238 m
      3. upper arm DIRECTION     66.2      56.4 deg
      4. elbow BEND              64.7      64.7 deg
      5. upper arm TWIST         64.1      63.7 deg

### Fix A — the torso was in THREE chains at once

★★★ `out_twist[torso]` was computed three times — against `head`, and against each `upper_arm` —
and **whichever chain ran last silently won.** The reference never hits this because its chains
start at separate bodies (`LeftShoulder`, `RightShoulder`, `Neck`); ours all shared the torso
only because `humanoid.xml` has no shoulder body.

★ Fixed by giving the torso its own chain (`torso -> head`, the spine's one unambiguous bone)
and starting the arms at `upper_arm_*`, inheriting the torso's twist through `parent_twist` —
which is what that parameter is for. **Direction 66.2 -> 56.4.**

### Fix B — ★★★ THE THIRD RULER MISMATCH IN THIS ONE SCORECARD

The torso's orientation was measured as the robot's `torso -> head` against the human's
`Spine3 -> RightArm`. **A spine bone against a shoulder bone — they can never agree however good
the retarget is.** Comparing like with like: **54.1 -> 19.8 degrees.**

★★ The full tally of fake numbers this scorecard has produced:

  1. a `Spine2`/`Spine3` mismatch — the ruler named a different joint than the code
  2. a torso position of 0.913 m — world-absolute against root-relative, on a harness that never
     set the root translation
  3. this — a spine bone measured against a shoulder bone

**Every one was the harness naming one thing while the code did another**, and every one looked
like a real defect until checked. A measurement harness needs the same suspicion as the code it
measures, and arguably more: **a wrong number sends work in a wrong direction, where wrong code
merely fails.**

### Where that leaves the arm

★ Torso at 19.8 degrees is respectable. The ARM is the remaining problem, and it sits at the
**2-DOF shoulder ceiling** established three times over: direction, bend and twist cannot all be
right on a two-DOF joint. Best per stage remains 51.4 / 64.7 / 63.6, achieved by different
approaches.

★ **A device check is now worthwhile** — the torso is close, the arm is at its ceiling, and what
remains is a judgement about which trade reads better, which the scorecard cannot make.

---

## ★★★ 6. THE LEGS — the decisive check, and it PARTLY refutes the ceiling story

      1. torso ORIENTATION      19.8 deg
      2. upper arm POSITION    0.238 m
      3. upper arm DIRECTION    56.4 deg
      4. elbow BEND             64.7 deg
      5. upper arm TWIST        63.7 deg
      --- LEGS (3-DOF hip, NOT over-subscribed) ---
      6. thigh DIRECTION        43.2 deg
      7. knee BEND              61.6 deg

★★ **THE THIGH BEATS THE UPPER ARM (43.2 vs 56.4), WHICH THE 3-DOF HYPOTHESIS PREDICTED.** A hip
has three degrees of freedom and can deliver a direction and a twist together; a 2-DOF shoulder
cannot, and the 13-degree gap is about the size that trade should cost.

★★★ **BUT 43 DEGREES IS NOT NEAR ZERO, AND THE HIP HAS NO EXCUSE.** So the shoulder's ceiling
was **part** of the explanation, not all of it. **A systematic error remains that affects every
limb**, and the leg is the place to chase it precisely because the model is not the constraint
there.

★ This is worth stating plainly because the ceiling story was becoming a comfortable explanation
for everything. **A hypothesis that explains the arm AND the leg AND the torso is explaining too
much** — the leg number is what exposed that.

### Next suspects, for the leg specifically

1. **The leg chain's parent inheritance.** `pelvis` heads its chain, but its parent is
   `waist_lower`, whose twist is identity because no chain contains it. **A body between two
   chains gets no twist and silently breaks the inheritance** — the same class of bug as the
   torso being in three chains at once.
2. **`pelvis` maps to `Hips`, whose bone in LAFAN1 goes to `Spine`, not to a leg.** The robot's
   `pelvis -> thigh` and the human's `Hips -> Spine` are different bones, so the twist computed
   for the pelvis aligns the wrong pair — a fourth instance of comparing unlike bones.
3. Knee bend at 61.6 is close to the elbow's 64.7, suggesting the BEND has a shared cause
   independent of DOF count — likely the flexion sign or reference direction, which is one
   scalar and cheap to check.

---

## ★★ 7. SUSPECTS 1 AND 2 ELIMINATED — the systematic error is elsewhere

      stage                  before   after adding waist_lower/pelvis to a chain
      thigh DIRECTION         43.2     43.0 deg
      upper arm TWIST         63.7     61.3 deg
      everything else         unchanged

★ **Suspect 2 was already handled.** `computeTwistOffsets` uses the MAPPED child, so it compares
`Hips -> RightUpLeg` against `pelvis -> thigh` — the right pair. I had assumed a bug from
reasoning about LAFAN1's hierarchy without reading my own code.

★ **Suspect 1 was real but minor.** `waist_lower` and `pelvis` were in no chain, so both were
posed with an identity correction and the legs inherited a parent twist that was never computed.
Fixing it moved TWIST by 2.4 degrees and the thigh by 0.2. **A genuine bug worth fixing, and not
the one that matters.**

★★★ **SO A SYSTEMATIC 43-56 DEGREE ERROR REMAINS, ON A 3-DOF HIP THAT HAS NO EXCUSE.** Three
explanations have now been eliminated by measurement: the shoulder's DOF ceiling (the leg is
better but still bad), the chain wiring, and the child mapping.

### ★ WHAT I WOULD LOOK AT NEXT, AND WHY

★★ **The `q_src` FRAME is the strongest remaining suspect.** A source LOCAL rotation is relative
to the human's PARENT JOINT FRAME; it is being applied as a rotation relative to the robot's
PARENT BODY FRAME. **Those differ by the parent's rest orientation** — and the reference never
meets this because its robot was generated from the source, so the two frames coincide. The
`inv(parent_twist)` term is supposed to absorb it; whether it fully does for an INDEPENDENT
robot is exactly the assumption that has broken twice already.

★ A cheap decisive test: take ONE frame, ONE body, and compare the robot's achieved world
rotation against `world_rot_src * R_twist` — the reference's own stated invariant. **It holds by
construction if the port is faithful.** If it fails, the composition is wrong and the frame
suspicion is confirmed; if it holds, the targets are right and the FIT is losing them.

★★ That test is the same shape as the one that settled the `fitBodyRotation` question earlier —
**assert the reference's invariant directly rather than inferring from a downstream score.**
Every time this arc has done that, it got a clean answer in one step; every time it inferred
from a blended number, it lost rounds.

---

## ★★★ 8. THE INVARIANT TEST FOUND IT — the ROOT must take a WORLD rotation, not a local one

      torso              51.2 deg      <- fails HERE, at the root
      pelvis            130.0 deg
      thigh_right       113.5 deg
      upper_arm_right   150.0 deg
      hand_right        150.9 deg

★★★ **THE REFERENCE'S OWN INVARIANT — `world_rot_robot == world_rot_src * R_twist` — FAILS AT
THE TORSO BY 51 DEGREES.** The torso is the robot's ROOT, fitted onto a FREE joint that can
represent any rotation exactly, so a miss there is purely the TARGET. Everything below inherits
it, which is why the whole body sat at 43-56 degrees with no single stage explaining it.

### ★★★ THE CAUSE

**The torso maps to `Spine3`, which is NOT the human's root.** Above it sit `Hips`, `Spine`,
`Spine1`, `Spine2` — four joints whose rotations accumulate into `Spine3`'s WORLD orientation.

★★ `q_src` is a LOCAL rotation, relative to the human's parent joint. **On the robot's ROOT
there is no body above to carry that chain**, so the spine's accumulated rotation is silently
dropped. The root must take the human's **WORLD** rotation.

★ The reference never meets this because its Geno robot has the FULL spine — every human joint
has a counterpart, so a local rotation always has its parent present to accumulate against. **On
a 16-body robot that maps four spine joints onto one torso, it does not.**

★★ **This is the "assumptions must port too" lesson for the third time**, and the sharpest
instance: the missing bodies are not a cosmetic simplification, they change what a LOCAL
rotation means.

### The fix, and why it should be checked with the same test

For any body whose human counterpart's PARENT CHAIN has no robot counterpart, use the human's
WORLD rotation and let `R_twist` do the rest. In practice that is the root; every other body has
its parent mapped.

★ **Re-run the INVARIANT test after, not the scorecard.** It is the tighter instrument: it
localises the first bad body, where the scorecard reports a blend. This session's pattern is
unambiguous — asserting the reference's invariant gave a clean answer in one step, three times
now, where inferring from scores cost rounds each time.

---

## ★★★ 9. THE ROOT FIX — torso EXACT, and the "irreducible floor" was not

### The invariant

      torso              51.2 -> 0.0 deg      EXACT
      pelvis            130.0 -> 80.0
      thigh_right       113.5 -> 70.7
      upper_arm_right   150.0 -> 117.9

### The scorecard

      1. torso ORIENTATION     19.9 -> 2.2 deg
      2. upper arm POSITION    0.237 -> 0.199 m
      3. upper arm DIRECTION    56.2 -> 44.7 deg
      4. elbow BEND             64.7 -> 64.7 deg
      5. upper arm TWIST        61.3 -> 64.4 deg
      6. thigh DIRECTION        43.0 -> 50.9 deg

★★★ **THE TORSO IS NOW EXACT ON THE INVARIANT AND 2.2 DEGREES ON THE SCORECARD.** One line — the
root taking a WORLD rotation instead of a local one — and the largest remaining error collapsed.

★★★ **AND THE POSITION WENT BELOW 0.199 m, UNDER THE "IRREDUCIBLE 0.21 m FLOOR" I DERIVED.**
That floor was computed with the torso 20 degrees out, so it measured the wrong thing —
**a fifth number in this arc that turned out to be measuring its own error.** A floor derived
from a system with a known defect is not a floor.

### What remains, and it is now sharply localised

★★ **THE INVARIANT STILL FAILS BELOW THE ROOT** (pelvis 80, arm 118), and the algebra says it
SHOULD hold once the parent holds:

    world = parent_world_robot * conj(parent_twist) * q_src_local * own_twist
          = src_parent_world * q_src_local * own_twist        [if the parent's invariant holds]
          = src_world * own_twist                              QED

So a child failing while its parent is exact means `q_src_local` is not the rotation the robot's
parent chain expects.

★★★ **THE SUSPECT IS THE INVERTED SPINE.** The robot runs `torso -> waist_lower -> pelvis`
DOWNWARD; the human runs `Hips -> Spine -> Spine1` UPWARD. So `pelvis` maps to `Hips`, whose
human PARENT is nothing, while its robot parent is `waist_lower` mapped to `Spine` — **the
human's CHILD.** Computing `q_src_local` as `conj(human_parent) * human_own` uses a
relationship that runs the opposite way through that section.

★ §4b flagged the inverted tree as a trap in the very first plan, and the global-space retarget
handled it — but this LOCAL-space port does not, because a local rotation is defined by a parent
relationship and that relationship is reversed here.

---

## ★★ 10. "LOCAL RELATIVE TO THE ROBOT'S PARENT" — right for SKIPPED joints, wrong for INVERTED

                          before   after
      torso                 0.0     0.0 deg
      upper_arm_right     117.9    48.8 deg    MUCH better
      pelvis               80.0    92.2 deg    worse
      thigh_right          70.7    82.1 deg    worse
      lower_arm_right     108.6   143.9 deg    worse

★★★ **THE RULE IS RIGHT WHERE THE HIERARCHIES AGREE BUT SKIP JOINTS.** `upper_arm_right`'s robot
parent is the TORSO, while its human parent is `RightShoulder` — **a joint no robot body maps
to.** Referencing the mapped parent instead of the unmapped human one took it from 118 to 49
degrees, which is the largest single gain of the port.

★★ **AND WRONG WHERE THEY INVERT.** `pelvis` maps to `Hips`; its robot parent `waist_lower` maps
to `Spine`, which is the human's CHILD. Taking `conj(Spine) * Hips` describes the relationship
correctly but in the **opposite direction** to the robot's chain — the inverted section needs the
INVERSE, not just a different reference.

★ So the general rule splits into two cases that a single expression cannot serve:

  * **skipped joints** (arm): reference the mapped parent — the change just made.
  * **inverted section** (spine): reference the mapped parent AND invert, because the robot's
    parent is the human's child.

★★ **DETECTABLE FROM THE DATA, NOT A HAND-MAINTAINED LIST**: the section is inverted exactly
where the human joint mapped to the robot's PARENT is a DESCENDANT of the human joint mapped to
the body. That is checkable by walking the human's parent chain, so no table needs to record it
and a different robot needs no new code.

★ §4b called the inverted tree a trap in the very first plan and the global-space retarget
handled it for free. **This local-space port pays for it twice** — once here, once in whatever
the fix costs — which is the clearest argument yet that the two formulations are not
interchangeable.

---

## ★★★ 11. THE PORT IS STRUCTURALLY CORRECT — the residual is the MODEL'S DOF

      torso              0.0 deg   dof 1 (FREE)   exact
      waist_lower       22.0 deg   dof 2
      upper_arm_left    37.7 deg   dof 2
      thigh_left        46.4 deg   dof 3
      head              55.6 deg   dof 0          CANNOT BE POSED
      hand_right        48.3 deg   dof 0          CANNOT BE POSED
      pelvis            92.2 deg   dof 1

★★★ **THE TORSO'S FREE JOINT REPRESENTS ANY ROTATION AND SCORES 0.0.** Everything below has
hinges, and its deviation is the rotation those hinges cannot express — **a FIT limit, not a
target error.** The algebra says so independently:

    q_src_local = conj(world_src[robot_parent]) * world_src[body]

**follows from the ROBOT's own chain**, so given a correct parent the target is exact by
construction and only the fit can lose it. The last change was therefore right, and the numbers
that got "worse" were the fit's inability surfacing rather than a regression.

★★ **`head` AND `hand_right` HAVE ZERO DOF.** They are welded to their parents and cannot be
posed at all — **their match-table rows and rotation weights do nothing**, and their deviation is
purely inherited. Worth knowing before anyone tunes a weight that cannot have an effect.

### ★ Where this arc stands

The scorecard, best measured: torso 2.2 deg, arm position 0.199 m, arm direction 44.7 deg. The
torso is essentially solved; the limbs are bounded by `humanoid.xml`'s hinges.

★ **The honest summary: the retarget is now correct in its TARGETS and limited by the ROBOT.**
That is a different and much better place than "the formula is wrong", which is where this arc
spent most of its time — and the invariant test is what moved it, in four steps, after eleven
formula candidates had not.

### Remaining

1. **IK is the right tool for the DOF limit** — it distributes error across a chain instead of
   letting each joint fail independently. `ikStep` exists and is tested; it was switched off to
   isolate the formulas and should now come back.

   ★ **ATTEMPTED AND BACKED OUT.** `armDirectionForFrame` is shared by three tests, so adding
   five IK parameters meant threading placeholders through call sites that do not want them,
   and the result was half-wired with unused constants. **Reverted to the clean state rather
   than left in that condition** — a partially plumbed signature is worse than none, because
   the next session inherits a build that compiles and lies about what it measures.

   ★★ The right shape is an OPTIONS STRUCT with sensible defaults, not five positional
   parameters — three call sites that each want a different subset is exactly the signal for
   that. Worth doing first, before the IK itself.
2. **Drop `head` and `hand` rows**, or accept they are decorative.
3. **Device check.** The targets are right; what remains is how the DOF limit reads on screen,
   which no number here can settle.

---

## ★★★ 12. IK BACK ON — the legs transform, and the sum drops by a quarter

                          IK off    IK on
      1. torso ORIENT       2.2      29.0 deg    worse
      2. arm POSITION      0.199    0.159 m      better
      3. arm DIRECTION      44.7     63.2 deg    worse
      4. elbow BEND         64.7     34.7 deg    MUCH better
      5. arm TWIST          64.4     61.6 deg    better
      6. thigh DIRECTION    50.9     24.3 deg    MUCH better
      7. knee BEND          61.6     10.2 deg    DRAMATICALLY better
      ------------------------------------------------------
      sum of angles        288.5    223.0

★★★ **THE KNEE AT 10.2 DEGREES AND THE THIGH AT 24.3 ARE THE FIRST NUMBERS IN THIS ARC THAT
LOOK LIKE A WORKING RETARGET.** The solver is doing exactly what the DOF diagnosis predicted:
distributing error across a chain instead of letting every hinge fail alone.

★★ **THE LEG BENEFITS MOST BECAUSE IT IS THE CHAIN WITH THE MOST DOF** (3 + 1 + 2) and the
clearest position targets (feet at weight 50). The arm has fewer DOF and lower weights, so it
gains less — which is the same DOF story, now cutting the other way.

### ★★ THE TORSO REGRESSED, AND THE CAUSE IS STRUCTURAL

2.2 -> 29.0 degrees, because **the IK is free to move the FREE ROOT** to satisfy position
targets, and the cheapest way to move a foot is often to move the whole robot. The ported recipe
had the torso essentially exact; the solver spends that to buy position elsewhere.

★ Fix candidates, in order of how much they respect what is already right:
  1. **Exclude the root from the solve** — pin the torso after the recipe places it, and let the
     chains below do the reaching. The recipe earned that 2.2 degrees.
  2. Lower the pelvis position weight (currently 20), which is what pulls the root.
  3. Add an orientation task on the torso so the solver has to pay for turning it.

★★★ **AND THE ARM'S DIRECTION REGRESSION (44.7 -> 63.2) IS THE SAME TRADE**: position targets
pull the arm toward where the human's is, at the cost of where it POINTS. With the elbow bend
halved in exchange, that is likely worth it — **but it is a judgement about appearance, and the
device is the only instrument left for it.**

### Structure note

★ `IkPass` is one optional struct with a meaningful `null`, replacing the five positional
parameters that were reverted last turn. Two call sites pass `null` and read clearly as "no
refinement"; the third passes real arrays. **The refactor took one turn and the wrong version
took one turn to write and one to unpick.**

---

## ★★★ 13. THE EXAMPLE NOW RUNS THE RECIPE — and the UI is down to what still decides something

Ported into `examples/geno_dance`: `robot_twist_chains`, `refreshRobotTwists`, and the per-frame
`applyTwist(q_local, parent_twist, own_twist)` with `q_local` taken relative to the human joint
driving the ROBOT's parent. IK refine ON by default at 20 steps.

### ★★ WHAT WAS REMOVED, AND WHY REMOVING IT IS THE POINT

    eleven orientation-formula radios   the recipe is settled; they only select worse answers
    bone budget 1/2/4/8/16              did its job isolating the torso; all 16 now
    the AIM path                        superseded — 0.916 on the upper arm but no bend-plane
    facing-yaw slider                   the twist offsets subsume it per bone
    aim_mode constant                   dead

★★ **A control that can only select a worse answer is clutter, not flexibility.** Each of those
earned its place while a question was open and became noise the moment it closed. Keeping them
"just in case" would leave the next reader unable to tell which knob is live.

★ **IK OFF/ON STAYS**, because it is the one control that still changes the answer and the A/B
is worth having: measured, the knee goes 61.6 -> 10.2 degrees with it on.

### What the device should show

★ The robot follows the dance with legs tracking well (knee 10.2 deg, thigh 24.3), arms
approximate (direction ~63, bend ~35), and the torso pulled around somewhat by the solver
(29 deg, against 2.2 with IK off) — **the known trade, and the first thing to fix next: pin the
root after the recipe places it, since the recipe earns 2.2 degrees and the solver spends it.**

---

## ★★★ 14. THE EXAMPLE AND THE HARNESS WERE NEVER CROSS-CHECKED — Simon was right to doubt it

Device: `ik refine: off`, `ik error -- (solver idle)`, torso facing wrong, arms random.

### Two defects, and the second invalidates the reporting

★★ **THE DEFAULT WAS 30 WHILE THE RADIOS OFFERED 0 AND 20.** Neither showed as selected, so the
UI could not tell you what was running — and it was running with IK OFF, which is the state where
the legs have not improved at all. **A default no control can display is a silent state.**

★★★ **AND THE EXAMPLE WAS SENDING ORIENTATION TASKS TO THE SOLVER; THE SCORECARD HARNESS SENDS
POSITION ONLY.** They are two different algorithms. **Every number quoted in the last several
turns was measured on the harness and attributed to the example.**

★ That is the ruler-versus-code mismatch this arc has now hit SIX times, in its worst form: not a
wrong measurement of the right thing, but **a right measurement of a DIFFERENT thing.** The
harness was built precisely so device screenshots would not be needed — and then it measured
something the device never ran.

### ★★ THE RULE THIS SHOULD HAVE FOLLOWED

**One implementation, measured and shipped.** The harness duplicates `poseRobot` because it was
easier than exporting it; that duplication is exactly what let the two drift. `poseRobot` should
live in the library with both the example and the test calling it, and until it does **no number
from the harness may be quoted as a property of the example.**

★ Fixed for now by making the example's IK position-only to match. **That is a patch on the
symptom** — the two implementations still exist and will drift again.

---

## ★★★ 15. THE TORSO: THE EXAMPLE WAS BUILDING TWISTS FROM GENO'S **A-POSE**

★★★ `refreshRobotTwists` took its bone directions from `model.clip.skeleton.bindPose` — **and
Geno's bind is an A-POSE.** The harness uses `Geno_stance.bvh`, the real T-pose. Two different
reference poses, so two different twist offsets, so a torso that faces the wrong way.

★★ **THIS IS THE FOURTH PLACE IN THIS ARC THAT AN A-POSE HAS BEEN SUBSTITUTED FOR A T-POSE**,
and the second time it reached the device. The lesson is in claude.md, was written after the
first occurrence, and did not prevent the fourth — because each time it appears somewhere new:
first in `restBoneOrientations`, then in `fbxBindOrientations`, then in the limb correction, now
in the twist offsets.

★ **AND THE ACCUMULATION WAS WRONG TOO.** It summed raw `translation` offsets down the chain
WITHOUT the parent's rotation — valid only when every rest rotation is identity, which an A-pose
bind guarantees it is not. Two independent errors compounding in one four-line loop.

### The fix

`referenceOrientationsFromTPoseBvh` now also returns world POSITIONS from the same T-pose walk
— the same accumulation it was already doing for orientations, with the offset rotated by the
parent. `Character.rest_positions` holds them; `refreshRobotTwists` reads them.

★ For a character with no T-pose file (Mixamo), the fallback accumulates the FBX bind's
positions **through the bind rotations** — correct there because a Mixamo bind IS a T-pose.

### ★★ WHAT THIS SAYS ABOUT THE DUPLICATION

The harness and the example diverged in FOUR ways so far: orientation tasks in the solver, the
IK default, the reference pose, and the accumulation. **Every one was invisible until a
screenshot contradicted a number.** `poseRobot` belongs in the library with one implementation;
until then every harness result must be re-verified on the device before it is quoted.

---

## ★★★ 16. OVERLAY THE ROBOT ON THE CHARACTER — make the error visible instead of inferable

Simon: *"it is confusing because I only see capsules for bones. Shoulders are not at the correct
place. We need to find a way to bring the robot on the anim somehow."*

★★★ **THAT IS AN INSTRUMENT PROBLEM, AND IT HAS BEEN THE REAL BOTTLENECK.** Side by side, judging
a retarget means mentally aligning two figures two metres apart, one skinned and one capsules.
**Overlaid, every discrepancy IS the visible gap between a capsule and the limb it should lie
along** — no alignment step, no inference, no ambiguity about whether a shoulder is "wrong".

★ `overlay on character` draws the robot at the source character's own offset. The side-by-side
view stays available for when the robot alone is what matters.

★ The UI warns when `mesh` is on, because an opaque mesh hides capsules inside it and the
overlay would read as the robot having vanished.

### ★★ WHY THIS SHOULD HAVE COME FIRST

This arc built a numeric scorecard precisely because screenshots were hard to read — and then
the scorecard measured a DIFFERENT IMPLEMENTATION, and four divergences went unnoticed until a
screenshot contradicted a number.

★★★ **THE CHEAPEST INSTRUMENT WAS ALWAYS AVAILABLE: put the two things on top of each other.**
A scorecard tells you 44.7 degrees; an overlay tells you WHICH limb and in WHICH direction, on
the actual shipped code, in one glance. **Numbers are better for tracking progress; a direct
visual comparison is better for finding out what is wrong** — and I reached for the harder one
first because it felt more rigorous.

### Next, with the overlay as the instrument

1. **Shoulders.** Simon reports them misplaced. Their offset from the torso is FIXED, so this is
   either the torso's placement, the scale, or the match row — all three now visible directly.
2. **One implementation.** `poseRobot` into the library, so the harness and the example cannot
   diverge a fifth time.

---

## ★★★ 17. SHOULDER AND ELBOW — solve for POSITION, derive the orientation from it

### The torso: placed by the SHOULDER MIDPOINT, not by Spine3

★★★ **THE ROBOT'S TORSO-TO-SHOULDER OFFSET IS FIXED BY THE MODEL.** Copying the human's spine
position therefore puts the shoulders wherever the robot's proportions happen to put them —
measured 0.2 m out, and no amount of orientation work could fix it.

★ Solve the other way: given the torso's orientation (already correct) and the shoulders' fixed
local offsets, choose the torso POSITION that lands the shoulder midpoint on the human's. One
subtraction.

★★ **The MIDPOINT, not one shoulder**, because the robot's shoulder separation is fixed too: no
single position satisfies both, and splitting the difference is honest where favouring a side is
arbitrary.

### The upper arm: aimed at the ELBOW

★★★ **AN ELBOW'S POSITION IS DECIDED ENTIRELY BY THE SHOULDER**, because the upper arm's length
is fixed. Once the shoulder is placed, the only freedom left is which way the bone points — so
aim it at the human's elbow and the robot's lands as close as its own bone length allows.

★★ **THIS IS A POSITION CRITERION PRODUCING AN ORIENTATION, which is the right way round for a
limb.** Matching an upper arm's FRAME does not put the elbow anywhere in particular; aiming at
the elbow does. Most of this arc worked the other way and hoped positions would follow.

### ★ The pattern worth keeping

Both fixes have the same shape: **identify the quantity that is FIXED by the model, then solve
for the free one.** The torso-shoulder offset is fixed, so solve the torso's position. The upper
arm's length is fixed, so solve its direction. **Asking for something the model cannot vary is
the mistake; the measurements kept saying so and it took a long time to hear it.**

### Next

★ The overlay is the instrument now — a capsule that does not lie along its limb IS the error.
Shoulder and elbow are the two this turn targets; the forearm and wrist follow the same logic
(the forearm's length is fixed, so the wrist is decided by the elbow's bend and twist).

---

## ★★★ 18. "SHOULDERS ROTATED 90 DEGREES" — a VERTICAL bone cannot encode YAW

Device: the overlay works, the robot is co-located with the character, and the shoulders sit a
quarter turn off.

★★★ **THE TORSO'S REFERENCE BONE IS `torso -> head`, WHICH IS VERTICAL — and a shortest arc
between two vertical bones leaves YAW ABOUT THE VERTICAL AXIS COMPLETELY UNCONSTRAINED.** The
torso's twist therefore came out near identity and carried no facing correction, while the two
skeletons face a quarter turn apart (measured back in §13f: character +Z, robot +X).

★★ **THE SHOULDERS HANG OFF THE TORSO AT FIXED OFFSETS, SO AN UNCORRECTED YAW SWINGS THEM
BODILY.** "Shoulders rotated 90 degrees" is the spine's missing yaw seen at the end of a lever —
not a shoulder problem at all.

### ★★ THE ASSUMPTION THAT FAILED

Removing the facing-yaw slider was right. **Assuming the per-bone twists SUBSUMED it was not** —
a bone PARALLEL to the missing axis can never encode a rotation about that axis. I wrote
"the twist offsets subsume it per bone" as a justification and never checked it against the one
bone where it cannot be true.

★ **A shortest-arc alignment constrains two of three rotational degrees of freedom.** The third
— twist about the aligned direction — is free by construction, which is exactly why
`aimBoneWithTwist` exists for limbs. The torso needed the same treatment and did not get it.

### The fix

★ Shoulder-to-shoulder as the torso's reference bone: **horizontal, and therefore able to see
yaw exactly.** It is also the right bone on its own merits — the torso's job in this rig is to
carry the shoulders, and a spine direction says nothing about where they point.

★ Both sides measured the same way, robot from `qpos0` and human from the T-pose, so the pairing
follows the rule this arc has broken four times.

---

## ★★★ 19. MEASURING WITHOUT FEEDBACK — the twist builder is now ONE implementation

Simon: *"Find a way to measure progress by yourself without my feedback."*

★★★ **THE OBSTACLE WAS NEVER THE ABSENCE OF A MEASUREMENT — it was that the measurement and the
shipped code were different programs.** The scorecard has existed for many turns; it drifted
from the example in FOUR ways (reference pose, accumulation, solver task set, IK default) and
every drift was invisible until a screenshot contradicted a number.

★★ `robot.computeTwistChainOffsets` now holds the builder, and **both the example and the
harness call it.** The example prepares its inputs and applies the torso's horizontal-bone
correction; the harness prepares its inputs; neither owns a copy of the algorithm.

★ **A harness that duplicates the code it measures is measuring a guess.** That sentence is the
whole lesson of the last several turns, and it applies to any test that "reimplements the same
thing for testing".

### Current scorecard — now a property of the shipped builder

      1. torso ORIENTATION      29.0 deg
      2. upper arm POSITION    0.159 m
      3. upper arm DIRECTION    63.2 deg
      4. elbow BEND             34.7 deg
      5. upper arm TWIST        61.6 deg
      6. thigh DIRECTION        24.3 deg
      7. knee BEND              10.2 deg

★ Still not fully shared: the per-frame POSE loop (aim-at-elbow, the hinge bend, the shoulder
midpoint placement) lives only in the example, so stages 1-5 still measure the harness's version
of those. **The twist offsets are shared; the posing is not, and the next extraction is that
loop.**

★★ Being explicit about which numbers are now trustworthy and which are not is the point.
Claiming the whole scorecard tracks the example would repeat exactly the error this turn fixes.

---

## ★★★ 20. THE POSE LOOP IS SHARED TOO — six of seven stages improved

                          harness copy   shared loop
      1. torso ORIENT        29.0          49.2 deg    worse
      2. arm POSITION       0.159         0.107 m
      3. arm DIRECTION       63.2          43.2 deg
      4. elbow BEND          34.7          35.7 deg
      5. arm TWIST           61.6          35.8 deg
      6. thigh DIRECTION     24.3          23.2 deg
      7. knee BEND           10.2           6.6 deg
      -------------------------------------------------
      sum of angles         223.0         193.7

★★★ **SIX OF SEVEN IMPROVED THE MOMENT THE HARNESS STOPPED RUNNING ITS OWN COPY.** The gains
were already in the example — aim-at-elbow, the hinge bend — and the scorecard simply could not
see them. **Every number reported before this was a measurement of the worse of two
implementations.**

★ `arm POSITION 0.107 m` is now half the "irreducible 0.21 m floor" I derived earlier, which was
computed on a system with three known defects. `knee BEND 6.6 deg` and `arm TWIST 35.8` are the
best figures this arc has produced.

### ★★ THE TORSO REGRESSED, AND I KNOW EXACTLY WHY

29.0 -> 49.2, because **the shared loop does NOT yet contain the two torso-specific fixes** that
live in the example: the horizontal shoulder-to-shoulder reference bone, and the
shoulder-midpoint root placement. The harness now measures the shared loop faithfully — including
the parts it is missing.

★ **That is the system working.** A number that got worse for a reason I can name, on code I can
point at, is worth more than a better number I cannot account for.

### Next

1. **Move the torso fixes into `poseFromRetarget`** — the horizontal reference bone and the
   shoulder-midpoint placement. Then stage 1 should return to ~2 degrees and the scorecard covers
   the whole pipeline.
2. Only then is the scorecard a true self-check, and iteration without device feedback becomes
   honest rather than aspirational.

---

## ★★★ 21. THE TORSO FIXES DO **NOT** TRANSFER — and the scorecard caught it immediately

Both were moved into the shared functions and measured:

                        without   with
      torso ORIENT        49.2     48.8   unchanged
      arm POSITION       0.107    0.128   worse
      arm DIRECTION       43.2     76.2   MUCH worse
      elbow BEND          35.7     34.0   better
      arm TWIST           35.8     73.5   MUCH worse
      knee BEND            6.6     15.3   worse
      ------------------------------------------------
      sum of angles      193.7    269.6

★★★ **THE HORIZONTAL SHOULDER BONE DID NOT EVEN FIX THE TORSO** — 49.2 to 48.8, which is noise.
That is the one thing it existed for. **So whatever improved the device picture came from
somewhere else in the example's path**, most likely its own root placement, which the shared loop
does not replicate.

★★ Rewriting `out_twist[torso]` also rewrites what every upper-body child INHERITS, so a
correction that helps one body can wreck the four below it. **Arm direction and twist both
roughly doubling is exactly that signature.**

★ **LEFT OFF, WIRED, AND RECORDED.** Enabling a change because it "should" help is how this arc
lost most of its ground; the option is one word away when there is a reason to revisit it, and
`findShoulderPair` is asserted to resolve so re-testing is not a debugging session.

### ★★★ WHAT THIS TURN ACTUALLY ESTABLISHED

**The self-measurement works.** A change I was confident about — one I had already justified in
writing and shipped to the device — measured worse in one run, on shared code, with the reason
visible in which stages moved.

★ That is the whole point of what Simon asked for: **the scorecard now disagrees with me, and
that is worth more than a scorecard that agrees.** Before this turn it could not have caught
this, because it was measuring a different program.

### Standing state

      1. torso ORIENTATION      49.2 deg   <- largest error, cause still unidentified
      2. upper arm POSITION    0.107 m
      3. upper arm DIRECTION    43.2 deg
      4. elbow BEND             35.7 deg
      5. upper arm TWIST        35.8 deg
      6. thigh DIRECTION        23.2 deg
      7. knee BEND               6.6 deg

---

## ★★★ 22. THE SOURCE'S REST ROTATION BELONGS BACK — every stage improved

                        before   after
      torso ORIENT       49.2     47.2
      arm POSITION      0.107    0.105 m
      arm DIRECTION      43.2     42.1
      elbow BEND         35.7     35.5
      arm TWIST          35.8     34.5
      thigh DIRECTION    23.2     21.1
      knee BEND           6.6      6.3
      ----------------------------------
      sum of angles     193.7    186.7

★★★ **ALL SEVEN IMPROVED.** Small, but uniformly — which is the signature of a genuinely correct
change rather than a trade. Every previous "improvement" in this arc moved some stages and
worsened others.

### Why it was removed and why it belongs back

★★ `d_robot` is already local, because `humanoid.xml` declares no body rotations. **The SOURCE's
is not**: `Spine3` carries four spine joints' accumulated rotation, so its bone direction in
world differs from the same bone in its own frame.

★ Dropping the `j_rot` division was right at the time — because `q_local` was ALSO wrong then,
taken against the human's own parent instead of the robot's, and **the two errors partly
cancelled.** Fixing one exposed the other. That is worth remembering: a change that makes things
worse can be correct, if it uncovers a second error the first was masking.

★ The prediction was written down before the run and the scorecard settled it in one measurement.

### ★★ AND THE EXAMPLE PASSES THE SAME THING

A first pass had the example passing `null` there — **silently making it a different algorithm
from the measured one**, which is precisely the divergence the extraction exists to prevent. The
shared signature made that a compile error away from being caught, and it still took a second
look. **Sharing code removes a class of drift; it does not remove the need to check the call
sites.**

### Standing

The torso at 47.2 degrees is still the largest error and its cause is still unidentified — the
shoulder-axis explanation was falsified in section 21, and nothing has replaced it.

---

## ★★★ 23. T-POSE COMPARISON VIEW — inspect what every twist is built from

`T-pose compare` draws both rest poses with an offset slider, plus a joint FRAME triad at every
joint.

★★★ **EVERY `R_twist` IS `shortestArc(robot rest bone -> source rest bone)`.** If those two poses
do not relate the way the code assumes, every twist is wrong and no per-frame work recovers it —
**and until now the rest poses have only ever been inspected through numbers.** Four of this
arc's bugs were rest-pose errors (A-pose for T-pose, unrotated accumulation, vertical reference
bone, missing source rest rotation) and none was visible.

★ At offset 0 the two superimpose: **a robot bone that does not lie along its character bone IS
that bone's twist error**, read directly.

★★ **FRAMES, NOT JUST BONES.** A capsule shows direction; the twists also depend on rotation
ABOUT that direction, which a capsule cannot show and which already cost a quarter turn at the
torso. The triads make the robot's identity rest frames visible too — which is exactly why the
robot side needs no local-frame division and the source side does.

★ Orange is Geno, green the robot, RGB the XYZ axes.

### Why this is the right next instrument

The scorecard measures the RESULT; the overlay shows the result against the animation. **Neither
shows the INPUTS.** Every remaining unknown — the torso's 47.2 degrees above all — is a question
about what the two rest poses actually are relative to each other, and this is the first view
that answers it by looking rather than by inference.

---

## ★★★ 24. `humanoid.xml`'s `qpos0` IS NOT A T-POSE — the root cause, seen in one glance

The comparison view, first run:

      Geno (orange)   a proper T-pose: arms straight out, legs down
      robot (green)   arms FOLDED UP INTO A TRIANGLE

★★★ **EVERY TWIST OFFSET HAS BEEN `shortestArc(robot rest bone -> geno rest bone)` BETWEEN TWO
DIFFERENT PHYSICAL POSES.** That is the rule this arc has broken four times — and this is its
ROOT instance: the A-pose-for-T-pose bugs, the vertical reference bone, the missing rest
rotation all sat on top of a reference pose that was never a T-pose to begin with.

★★ **AND I ASSERTED THE OPPOSITE, WITH A MEASUREMENT.** §13g measured `hand at the same height
as upper arm` and concluded `humanoid.xml`'s `qpos0` IS a T-pose. **A folded arm can put the hand
at shoulder height too** — the check could not distinguish a T from a triangle, and one glance at
the drawing settles what a carefully chosen scalar got wrong.

### The fix: BUILD a matching T-pose instead of hoping for one

`solveRobotTPose` IKs the robot onto Geno's T-pose joint positions and stores the result;
`computeTwistChainOffsets` takes it via `robot_rest_qpos`. **Both references now depict the same
physical pose BY CONSTRUCTION, because the robot's was derived from the character's** — not
because two rigs happened to agree.

★ Position targets only, anchored on the pelvis so the solve adjusts the POSE rather than
dragging the figure sideways. It runs once per source change, using the solver already built and
tested.

### ★★ AN HONEST GAP

The scorecard harness still passes `null` there — **it does not yet solve the robot into the
T-pose the way the example does.** Its numbers therefore describe the older behaviour, and
recording that beats quoting them as though they did not. Extracting `solveRobotTPose` is the
next step, and only then does the scorecard describe this change.

---

## ★★ 25. THE COMPARE VIEW DREW NOTHING — three defects behind one blank robot

1. **It depended on state only built when the robot was ENABLED.** The checkbox was off, so the
   map and the solved T-pose never existed and the view drew an empty scene. **A blank result
   reads as "the robot has no T-pose" when it means "this view has no data"** — now the toggle
   enables the robot and forces a rebuild, and an unbuilt state says so in words.

2. ★★★ **A UNITS MISMATCH, INVISIBLE TO ONE CONSUMER AND FATAL TO THE OTHER.** Geno's rest
   positions are in CENTIMETRES (hips near 85); the robot works in METRES (hips near 0.83). The
   twist offsets never noticed because **directions are normalised** — but `solveRobotTPose`
   uses the same buffer as POSITIONS, and a 100x target is not a T-pose, it is a request to
   reach the next room.

   ★ **Sharing a buffer between a consumer that normalises and one that does not is what invites
   this.** The scale is now applied where the buffer is built, once, for both.

3. **The two figures were drawn at different scales**, so superimposing them would have compared
   nothing even had both appeared. Both now use the same ratio the solve uses.

★★ Also folded in: `robot_hip_height_m = 0.830`, MEASURED, replacing a hardcoded 0.9 that was
8.5% off and skewed every target for the whole arc. It now has a name and a comment saying where
it came from, so the next reader does not have to re-derive it.

---

## ★★★ 26. A UNITS BUG IN BOTH DIRECTIONS, ONE TURN APART

      last turn   targets 100x too SMALL   the solve reached for nothing
      this turn   a T-pose 100x too LARGE  a figure the size of a building

★★★ **`source.hip_height` IS ALREADY IN METRES while `source.rest_positions` ARE IN
CENTIMETRES** — two quantities from the same struct in different units. Applying `cm_to_m` to
both divided by a hundredth.

★★ **Both versions compiled, both passed lint, and both needed a screenshot to notice.** That is
the signature of a units error: nothing in the type system or the tooling distinguishes 0.85 from
85, and the only detector is something that knows how big a person is.

### The guard

★ A human-scaled skeleton spans roughly two metres. The rest pose is now checked against 0.2-4.0
before anything uses it, and outside that range it reports the span on screen and refuses to
build. **A wrong number that announces itself beats a wrong number that renders.**

★★ This is the same shape as the earlier fixes for silent state — the "solver idle" readout, the
"turn OFF mesh" hint, the "building robot rest pose" message. **Every one exists because a blank
or absurd picture was indistinguishable from a working one**, and each cost a device round to
discover.

### ★ On mixed units in one struct

The trap was not the conversion; it was that `hip_height` and `rest_positions` sit side by side
and disagree. **A field's units belong in its name or its type**, and `rest_positions_cm` would
have made the double conversion visible at the call site.

---

## ★★★ 27. BENT ARMS AND MISSING FEET — targeting POSITIONS asks for lengths the robot lacks

Device with the scale fixed: both figures superimposed, **but the robot's arms bend where Geno's
are straight, and the legs stop short of the feet.**

★★★ **TARGETING GENO'S JOINT POSITIONS ASKS THE ROBOT TO MATCH SEGMENT LENGTHS IT DOES NOT
HAVE.** The elbow target and the hand target then conflict, and the solver splits the difference
by **bending an arm that should be straight**. The legs curl short for exactly the same reason —
nothing was wrong with the feet, the targets were simply unreachable.

### The construction

Walk the ROBOT's own tree, placing each body along the direction Geno's corresponding bone
points, **at the robot's own bone length**:

    target[body] = target[parent] + normalize(source_bone) * robot_bone_length

★★ **Every target is then exactly reachable**, so a T-pose comes out as a T-pose rather than as a
least-squares compromise between two skeletons' proportions.

★★★ **THIS IS THE THIRD TIME THE SAME PRINCIPLE HAS FIXED SOMETHING**: take the DIRECTION from
the source and the MAGNITUDE from the model, because one of them is fixed and asking for it is
the mistake.

      shoulder   the torso-shoulder offset is fixed  -> solve the torso's POSITION
      elbow      the upper arm's length is fixed     -> solve its DIRECTION
      T-pose     every bone length is fixed          -> take only directions from the source

★ Worth stating as a rule rather than rediscovering a fourth time: **a retarget can copy angles
freely and can never copy lengths.**

---

## ★★ 28. VERTICAL OFFSET, AND THE "MISSING FEET" ARE THE MODEL

### The height

★★ Walking the robot's tree from ITS `qpos0` pelvis put the whole figure wherever the model
happens to place that body — **not where the character's hips are** — so the two T-poses hovered
at different heights and superimposing them compared nothing.

★ Anchoring on the MAPPED source joint puts the robot's pelvis exactly on Geno's hips, so the
offset slider means what it looks like it means.

### ★★★ THE FEET ARE NOT MISSING

`foot_left` and `foot_right` are **LEAF bodies at the ankle**, and the foot's shape is a GEOM,
not a body. Geno has a foot AND a toe, so it draws a foot bone with nothing on the robot to
match. **That is the model, not a defect** — and the UI now says so, because a real structural
difference that looks like a bug costs a device round every time someone notices it.

★ The robot's legs are also genuinely SHORTER in proportion (1.445 m against Geno's 1.65 m with
different proportions), and the T-pose uses the robot's own bone lengths by design. **Both
figures being different shapes is correct**; only their DIRECTIONS should agree, and directions
are all the twist offsets read.

### ★ Where the T-pose work stands

The robot now stands in a genuine T-pose derived from Geno's, anchored on Geno's hips, at
matching scale, with a units guard. **Every twist offset is finally built from two poses that
depict the same physical configuration** — which is the thing this whole arc kept assuming and
never had.

---

## ★★★ 29. DRAW THE GEOMS — the robot's real shape, not a tree of body origins

Simon: *"The geoms attached to humanoid.xml... we should see them?"*

★★★ **YES, AND THE PREVIOUS TURN'S "NO FEET" WAS THIS EXACTLY.** `foot_left` is a leaf body at
the ankle, so a tree-of-origins view draws nothing there — **while the foot exists perfectly well
as a GEOM.** I explained the absence as a model limitation and added a UI note saying so; the
honest answer was that the view was showing the wrong thing.

★★ **Capsules between body ORIGINS show the KINEMATIC TREE, not the figure.** Every judgement
about whether a limb "lies along" the character's has been made against a stick diagram of joint
positions rather than the robot's actual shape.

★ `drawRobotGeoms` places each geom by composing its body's world transform with the geom's own
`geom_pos`/`geom_rot`, and draws spheres, capsules and cylinders as themselves. It is used by
BOTH the T-pose comparison and the animation view, and toggles off to the old tree view.

★ One easy mistake avoided: **zimr's capsule runs along LOCAL Y, not MuJoCo's Z** — noted in
`GeomShape` and would have drawn every limb across the body.

### ★★ THE PATTERN THIS COMPLETES

Three times now the instrument has been the problem, not the algorithm:

    side-by-side figures    -> overlay             showed the torso yaw
    numbers without a view  -> T-pose compare      showed qpos0 is not a T-pose
    body origins            -> geoms               shows the actual robot

**Each time I explained a symptom instead of improving the view, and each explanation was
wrong.** The "no feet" note added last turn is the clearest case: a confident, plausible account
of something that simply was not being drawn.

---

## ★★ 30. THE ANCHOR BELONGS ON THE MAPPED BODY, NOT THE TREE ROOT

Device: geoms drawn, a clean T-pose with visible feet — **and still floating above Geno.**

★★★ The chain walk starts at the ROOT body, which for `humanoid.xml` is the **TORSO**. Anchoring
there put the torso where Geno's HIPS are and lifted everything above it by the height of the
spine. **The anchor belongs on the body that MAPS to the anchor joint** — the pelvis — not on
whichever body happens to head the kinematic tree.

★ Fixed with a single translation applied after the walk: by then the SHAPE is already correct
and only its placement is wrong, so one subtraction settles it without touching anything else.

★★ **THIS IS THE INVERTED-SPINE PROBLEM AGAIN, IN A NEW COSTUME.** `humanoid.xml` runs
torso -> waist -> pelvis DOWNWARD while the capture runs Hips -> Spine UPWARD, so "the root" and
"the hips" are opposite ends of the same chain. Every time this arc has assumed the two
hierarchies agree about which end is which, it has paid for it — in `q_local`, in the chain
ordering, and now in the anchor.

★ Worth stating plainly for next time: **on this pair, `root` and `hips` are NOT the same body,
and any code that treats them interchangeably is wrong by the height of a spine.**
