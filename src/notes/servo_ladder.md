# servo_ladder.md - getting a ragdoll into a pose, one rung at a time

Written after many turns of an exploding ragdoll. **This plan exists because every component
works in isolation and the assembly does not**, which is a different problem from a bug and needs
a different method.

---

## 1. What the DReCon / SuperTrack work is FOR

The goal, unchanged since `drecon2.md`: **take ten seconds of mocap and produce a physically
simulated character that performs it and stays up under a shove.**

Two papers describe how:

- **DReCon** learns a POLICY that outputs small PD-target OFFSETS on top of the clip's own joint
  angles. Its premise is that open-loop playback of the clip is nearly a working controller, so
  the network only has to learn a correction.
- **SuperTrack** replaces the reinforcement learning with SUPERVISED learning through a
  differentiable world model: predict the physics, then backpropagate the tracking error through
  the prediction into the policy. No reward, no critic.

`drecon2.md` chose SuperTrack as the learner (0a), because our reward is dense and exploration is
free, so a critic is the only expensive thing left and SuperTrack is the only method without one.

** **ALL OF THAT ASSUMES A CHARACTER THAT CAN BE DRIVEN TO A POSE.** A policy that outputs
offsets on top of a controller that cannot hold a pose is a correction to noise. **That is the
step we are stuck on, and it is upstream of every learning decision.**

---

## 2. What has actually been established

These are measured, not assumed. Each has a test that prints its number.

| component | status | evidence |
|---|---|---|
| retarget | **works** | the capture skeleton dances correctly on screen (0ad) |
| physics + contact | **works** | a cube rests at exactly its half-extent, 904/1000 frames in contact (0o) |
| the ground + bridge | **works** | humanoid lands at z = 0.131, contact on every frame (0n) |
| one hinge, static target | **works** | settles to 0.002 rad (0ao) |
| one hinge, moving target | **works** | 9.2 deg on a 0.5 Hz sine (0ar) |
| ten free bodies | **works** | elbow still settles to 0.0019 rad (0ar) |
| the full example | **EXPLODES** | max joint error in the hundreds of degrees |

### Bugs found and fixed along the way

Worth listing because each was real and none of them was the explosion:

    gravity defaulted to Y-down for a Z-up model      three separate times (0m, 0n, 0o)
    ball joints were never powered by `Actuation`     kp on screen, zero torque (0w)
    `quatToAxisAngle` returns a NON-UNIT axis         PD quadratically weak near target (0w)
    `usize` is 32 bits on wasm, 64 native             `@intCast` trap in `addContactRows`
    `swept` array had no bounds check                 out-of-bounds write (0s)
    `Data.contacts` smaller than a bridge can send    structural overflow (0r)
    the timestep was too coarse for the gains         limit cycle, 550x worse (0ao)
    the frame loop derived substeps from `delta_time` device and test never agreed (0ap)
    `<exclude>` is not imported at all                self-collision through a dance (0ap)

* **None of these was found by reasoning about the symptom.** Every one came from a measurement
that split a number into its parts, and the turns that reasoned instead of measuring produced
nothing.

---

## 3. Why we are stuck, stated plainly

*** **`dance_track` HAS ABOUT TWELVE INTERACTING FEATURES AND I HAVE BEEN CHANGING SEVERAL PER
TURN.** Retarget, IK, PD, contact, a hook, a pin, inertia scaling, a fixed clock, three drawn
characters, a clamp, a panel. When it breaks, the cause could be any of them or the interaction
of two, and a device screenshot cannot distinguish those.

** The single-joint tests work because they have ONE thing in them. That is the whole difference,
and it is the method rather than the luck.

---

## 4. The plan: a ladder, one rung at a time

**A new example, `servo_lab`.** Not a fix to `dance_track` - a separate, minimal thing that
starts from the case that provably works and adds ONE feature per rung.

### The rules that make this work

1. *** **ONE ADDITION PER RUNG.** If a rung fails, the thing that broke it is the thing that was
   added. This is the property `dance_track` lost and cannot get back.
2. *** **EVERY RUNG HAS ONE NUMBER AND A PASS THRESHOLD**, printed headlessly. A rung with no
   number is a rung whose result is an opinion.
3. ** **NO RUNG IS SKIPPED because it "obviously works".** Rung 2 below is the one nobody has
   ever tested, and it is the most likely place for this to fail.
4. ** **HEADLESS FIRST, DEVICE SECOND.** A rung is not passed until a test prints its number. The
   page is for watching, not for deciding.
5. * **When a rung fails, do not proceed.** Every turn spent above a failed rung has been wasted
   in this project already.

### The rungs

    rung  what it adds                              number              pass
    ----  ----------------------------------------  ------------------  --------------
      0   two bodies, one hinge, constant target    settled error       < 0.01 rad
      1   the target becomes a sine                 peak error          < 0.20 rad
      2   FULL humanoid, all joints, REST pose      max joint error     < 0.05 rad
      3   full humanoid, one fixed DANCE frame      max joint error     < 0.20 rad
      4   the clip plays, angles by decomposition   max joint error     < 0.30 rad
      5   targets come from the IK solve            max error, residual  < 0.30 rad
      6   the root is released, character on ground survival            > 2 s
      7   contacts enabled                          survival            > 5 s

*** **RUNG 2 IS THE ONE TO RUN FIRST AND IT HAS NEVER BEEN RUN.** Every full-body test in this
project used a MOVING target. **Nobody has ever asked whether the humanoid can hold still.** If
twenty-four joints cannot hold the pose they are already in, no clip and no policy will help, and
the answer costs one test.

* Rungs 0 and 1 exist in `robot_control.zig` already (0ao, 0ar) and pass. They move into
`servo_lab` so the ladder is one artefact rather than notes pointing at scattered tests.

* Rung 4 before rung 5 on purpose: the hinge decomposition is lossy and simple, the IK is exact
and complex. **If 4 passes and 5 fails, the IK is the problem; if both fail, the clip is.**

---

## 5. What `servo_lab` is

One example. A rung selector, one number on screen, and nothing else.

    - a `rung` enum, selected from the panel
    - each rung builds only what it needs: rung 0 builds a two-body Spec, rung 2 loads the
      humanoid, rung 4 loads the clip
    - the number and its threshold, with PASS or FAIL in words
    - no reference characters, no skeletons, no hook, no pin, no inertia toggle

** **EVERY FEATURE `dance_track` HAS IS ABSENT UNTIL A RUNG NEEDS IT.** That is not minimalism for
its own sake - it is the only way a failure can be attributed.

* `dance_track` stays as it is. It is not deleted and not fixed: it is the thing the ladder is
climbing toward, and when rung 7 passes it can be rebuilt from what the ladder learned.

---

## 6. What to do when a rung fails

* In order, and stop at the first that explains it:

1. **Print the inputs to the thing that was added.** Not the output - the inputs. Every bug in
   section 2 was visible in an input somebody had not looked at.
2. **Halve the addition.** Rung 5 adds the IK; if it fails, run the IK and use its output as a
   TARGET ONLY for one joint. A feature can almost always be added to one joint first.
3. **Compare against the engine's own demo.** `geno_dance` and `examples/humanoid` do versions of
   most of this and they work. Diffing against a working caller found two bugs in one build (0z).
4. ** **Do NOT reduce a gain to make a symptom go away.** That workaround was applied three times
   in this project and each time it hid the cause for several more turns.

---

## 7. Status

    rung 0   PASSES    one hinge, constant target: 0.002 rad
    rung 1   PASSES    one hinge, 0.5 Hz sine: 9.2 deg at kp 400+
    rung 2   PASSES    all 24 joints holding their own rest pose: 0.4 deg at kp 400
    rung 3   NOT BUILT <- next: one fixed DANCE frame instead of the rest pose
    rung 4+  not built

### Rung 2's result, and what it corrects

    kp 100  ->  30.4 deg drift on waist_lower, needs 21.4 Nm   FAIL
    kp 400  ->   0.4 deg                                       PASS
    kp 800  ->   0.2 deg                                       PASS

*** **THE FULL HUMANOID CAN HOLD A POSE. The controller is not broken.** Twenty-four joints, the
root pinned, five seconds, and the worst joint drifts four tenths of a degree. Whatever breaks
the full example, it is not the ability to hold a pose.

** **AND kp 100 IS TOO SOFT** - the waist cannot carry the torso and sags thirty degrees. One
elbow tracked fine at kp 100 because one forearm is light; **a single-joint measurement does not
generalise to a body**, and I had set the example to 100 on the reduce-stiffness instinct one
turn before measuring this.

* That is the ladder earning its keep on its first new rung: a number that both cleared the
controller and caught a change made for a plausible reason.

### 2163 — what `ragdoll_compare_plan.md` measured about reaching poses

*** **COMPUTED TORQUE REACHES POSES EXACTLY; THE LADDER'S PD DOES NOT, ON A TRUE FIXED BASE.**
Measured on MuJoCo's humanoid with the torso welded to the world, 500 Hz, gravity on: the
ladder's PD (kp 400, kv 20) holds the rest pose only to 44° and oscillates, and cannot reach the
squat (131°); `tau = M(q) a_des + c(q, v)` from robot.zig's own `inverseDynamics`, with a_des a
critically damped 5 Hz spring per joint, holds AND reaches the squat to 0.00°.

** **RUNG 2 NEEDS RE-RUNNING ON A FIXED BASE.** It pinned the floating root by snapping it back
after each step; within the step the body free-falls, and a free-falling body's joints carry no
gravity load. Its 0.4° was measured at 2 kHz under that pin — both conditions matter.

* **For rung 3 onward: drive targets through computed torque.** The policy interface is
unchanged — a target pose — so DReCon's PD-target offsets become offsets on the CT target. The
free-root rungs (6-7) need the underactuated form: CT on the hinge rows, with contacts and
balance supplying the root. Full numbers: `ragdoll_compare_plan.md` §9, "REACHING POSES".

### 2163 — the controller for the free-root rungs, at 60 Hz

*** **IMPLICIT COMPUTED TORQUE THROUGH FLOATING-BASE INVERSE DYNAMICS HOLDS A POSE AT 60 Hz,
FREE ROOT, ON THE FLOOR.** MuJoCo's humanoid falling onto the floor while holding the squat, one
step per 60 Hz frame: 7.0° at a 20 Hz spring, settled. The three pieces, each measured necessary:
the spring evaluated implicitly (`robot_maximal.stableSpringAccel` — the explicit one is capped
at 7.9 Hz by h² + 4ζh < 4); the root's rows solved rather than assumed zero
(`floatingBaseTorques`); and robot.zig's new `refsafe` clamp, without which even a LIMP body fell
through the floor at 60 Hz. Rungs 6-7 should start from exactly this controller.

---

## 8. 2163 — THE LADDER RE-DERIVED, after the controller and the balance measurement

Written after reading this file, `drecon2.md` (0a-0as and its adversarial review),
`humanoid_balance_plan.md`, the retarget notes and `ragdoll_compare_plan.md` §9 together, and
after one new measurement. **The end goal is unchanged: a ragdoll that follows ten seconds of
`dance1_20s.bvh`.** What changed is which risk is on top.

### 8.1 What is now established, with its evidence

    the controller      implicit computed torque through floating-base ID: exact on a fixed
                        base at any stiffness, 60 Hz included; holds a pose while falling
                        onto the floor to 7 deg (ragdoll_compare_plan.md §9)
    the engine at 60 Hz robot.zig's refsafe clamp; zimrphysics' hinge frame bug fixed
    the retarget        on humanoid_flex2, the SHIPPED point-cloud solve: mean direction error
                        torso 6.4 / arm 6.3 / forearm 2.1 / thigh 3.3 / shin 1.9 deg, solve
                        miss 1.9 cm, worst frame-to-frame pop 9.2 deg (robot_mjcf's WHOLE BODY
                        test, `-Dslow-tests`) — the model the retarget was validated on
    balance             NOT established, and now measured

### 8.2 ★★★ THE GATING RISK IS BALANCE, AND IT FAILS EVEN STANDING STILL

MuJoCo's humanoid holding its own STANDING pose (`qpos0`), torso free, feet on the floor, 60 Hz:

    no shove        reduced (implicit CT 20 Hz) upright 1.40 s    maximal (motors 20 Hz) 1.45 s
    0.5 m/s shove   reduced 0.73 s                                maximal 0.88 s
    1.0 m/s shove   reduced 0.55 s                                maximal 0.63 s

*** **A PERFECTLY HELD POSE IS A STATUE, AND A STATUE ON CAPSULE FEET FALLS OVER IN 1.4 s.**
Both engines agree, so it is the physics of the task rather than either engine. The first frame
of the dance is someone STANDING: reaching it on a free root is a balance test before it is a
pose test, and pose tracking alone cannot pass it.

** That reframes DReCon's premise ("open-loop playback nearly works"): here open-loop holding of a
STATIC pose fails, so a learned correction would have to invent balance rather than correct a
near-miss. drecon2's 0y (10.00 s at one PD setting, 0.17 s next door) is consistent with this:
a sharp landscape is what a marginal pendulum looks like.

### 8.3 The two questions Simon asked

* **Reach the first dance pose instead of the squat?** Yes — as TWO rungs, because it is two
questions. On a FIXED base it tests the target and the controller (expected to pass: the
controller is exact there). On a FREE root it tests balance, and 8.2 already says it fails
without a balance layer. Running only the free-root version would re-learn 8.2 the hard way.

* **The ball-joint robots?** Yes, and specifically `humanoid_flex2`: the retarget is validated on
it (8.1), its proportions match the capture (bone ratios 0.99-1.03), and the retarget produces
ROTATIONS, which a ball joint takes directly instead of through the lossy sequential hinge
projection. Not `humanoid_ball`: no joint limits and no tendons (drecon2 0j, 0v — "a knee that
bends backwards does not catch a fall") and a rest pose from a script under suspicion (0aa).
Cost: ball joints in the implicit-CT loop (the error is a rotation vector, log(conj(q) q*), with
the same implicit spring per component) — small; and in `robot_maximal` (a ball is a swing-twist
joint with free or MJCF-range cones — the case maximal coordinates represent EXACTLY) — medium,
and not on the critical path.

### 8.4 The ladder from here — every rung one addition, one number, headless first

    rung  what it adds                                        number                    pass
    ----  --------------------------------------------------  ------------------------  --------
     B0   ball joints in the implicit-CT loop; humanoid_flex2  fixed-base hold, reach    < 1 deg
     B1   dance frame 0 as the target, FIXED base              worst joint error         < 2 deg
     B2   the clip plays, FIXED base (root follows the clip    worst joint error         < 5 deg
          kinematically: a puppet on a stick)
     S0   a BALANCE layer: stand in qpos0 on the floor         seconds upright, of 10    10.0
     S1   the same, shoved 0.5 m/s                             seconds upright           10.0
     S2   stand in dance frame 0 (the first free-root pose)    seconds upright           10.0
     R0   the clip plays, FREE root, ROOT ASSIST (a wrench     joint error, and the      measured,
          at the torso pulling it along the clip)              assist it took            not gated
     R1   the assist removed, balance layer on                 seconds following, of 10  10.0
     L0   only now a learner, as a CORRECTION on top of R1     R1's numbers, improved    > R1

*** **B0-B2 retire the target risk and S0-S2 the balance risk, separately.** Each has failed
before in this project mixed with the other, which is why neither was ever measured cleanly.

** **R0's ROOT ASSIST IS AN INSTRUMENT, NOT A CHEAT.** The wrench needed to keep the torso on the
clip, printed over the ten seconds, says WHERE in the dance balance is hard and HOW hard: that
is the size of the correction any balance layer or learner has to supply, measured before
building either. It is also the supervision signal a learner would imitate.

** **S0 first, because everything free-root waits on it.** Candidates, cheapest first: (1) a
centre-of-mass feedback that shifts the ankle and hip targets — the "ankle strategy", a few lines
on top of the implicit CT; (2) the centroidal-momentum planner in `humanoid_balance_plan.md`, which
already STOOD the real humanoid (its gate 1) and trapped in the example — now worth re-trying on
the new torque layer, where the old PD was the unstable part; (3) a whole-body QP over contact
forces. Stop at the first that passes S1.

* **L0 is last on purpose.** drecon2 chose SuperTrack because a dense reference removes the
exploration problem — true — but it assumed a controller that nearly works (0a). R1 is that
controller. A learner started before it would be learning balance from nothing, which is the
hard-exploration problem 0a said we did not have.

### 8.5 2163, Sep 18 — B1 and B2 measured, and the TARGETS were the blocker

`src/robot_dance.zig` is `dance_track`'s retarget pipeline as a library (`retargetClip`), with
tests. **Following a retargeted pose locally failed before because the pose itself was broken.**

drecon2 0as's three questions, answered for ten seconds of `dance1_20s` (60 fps), `humanoid_flex`,
exactly as `dance_track` produced the targets:

    IK residual        mean 5.3 cm, worst 7.3 cm            — looked fine, and was not
    joint limits       4,875 hinge-frames OUT OF RANGE: the right knee bent BACKWARDS by
                       148 deg in all 599 frames; arm hinges wound to 6-10 rad
    smoothness         worst jump 2.83 rad in one frame; 1,521 jumps over 0.1 rad

*** **TWO BUGS PRODUCED THAT, AND BOTH ARE FIXED OR BYPASSED:**
1. **The IK's joint-limit barrier traps a joint once a step crosses the wall.** It clamps the gap
   at 0.001 of the span, so outside the range it is a small push under an enormous curvature
   that damps the step back. `solvePointCloud` used the barrier alone. **Fixed in `ikStep`:**
   limited joints are projected back into range after every step whenever the barrier is on.
   The retarget's own WHOLE BODY validation and the robot family still pass.
2. **(x, y, z) -> (x, z, y) is a REFLECTION, not a rotation.** It mirrors the capture left for
   right while the match table sends its left leg to the robot's left leg — reachable only by
   reversing knees. `FrameConvert.rotate` is the proper Y-up -> Z-up rotation (+90 deg about X,
   capture rotations conjugated by it). **`dance_track` still uses the mirror.**

With the IK kept in range:

    conversion                         model            residual mean / worst   out of range
    swizzle (dance_track's, a mirror)  humanoid_flex    35.7 / 110 cm           0
    proper rotation                    humanoid_flex    11.5 / 54 cm            0
    proper rotation                    humanoid_flex2    5.5 / 17 cm            0

`humanoid_flex2` matches the unconstrained residual while staying legal. What remains is
**shoulder branch flips** — the 3-hinge shoulders jump 1.3-1.6 rad at frames 5 and 592 on
flex2, the whole body around frame 505 on flex — exactly the joints the WHOLE BODY test named.

**B1 and B2, `humanoid_flex`, torso welded, 60 Hz, 20 Hz springs, proper-rotation targets:**

    rung                                    reduced (implicit CT     maximal (motors)
                                            + feed-forward)
    B1  reach dance frame 0 in 1 s          0.06 deg   PASS          11.5 deg
    B2  the clip, worst joint per frame     mean 7.1 deg;            mean 29.3 deg;
                                            83/598 frames > 10 deg   595/598 > 10 deg
        worst moment                        149 deg at frame 508     156 deg at frame 507

*** **THE ROBOT FOLLOWS THE RETARGETED DANCE LOCALLY** — mean 7 degrees at 60 Hz — except
through the transient where the TARGET flips (frame ~505). The maximal side lags throughout: its
motors get no velocity feed-forward, and it keeps the multi-hinge swing-twist mismatch.

**Next, in order:** (1) B0 — ball joints in the implicit-CT loop, then B1/B2 on
`humanoid_flex2`, whose targets are twice as accurate; (2) the flips — first-frame convergence
(frame 5 is the IK still settling from qpos0) and continuity at the shoulders; (3) switch
`dance_track` to `robot_dance.retargetClip(.rotate)` so the page shows the corrected targets;
(4) maximal: velocity feed-forward for the motors, and ball joints.

### 8.6 2163, Sep 18 (night) — B0-B2 PASS on humanoid_flex; the IK's soft terms were dead code

*** **THE IK'S LIMIT BARRIER AND POSTURE TERM WERE ADDED AFTER THE SOLVE.** In `ikStep` the block
that puts both into the normal equations ran after `solveSymmetricPositiveDefinite`, so neither
ever changed a step — which is why joints left their ranges (8.5's "trap" was really "absent")
and why the posture weight did nothing: retargeting the dance with posture 0.15 and 25 gave the
same digits. The WHOLE BODY test's own log had recorded "0.15, 0.30 and 0.60 all gave worst pop
59.2 deg, identical to the decimal" and read it as an unholdable branch flip. **And the barrier's
sign was inverted** (it pushed toward the nearest wall), unseen while it never ran. Both fixed; the
projection from 8.5 stays as the safety net. WHOLE BODY and the robot family pass.

**The targets now** (proper rotation, 10 s, 60 fps, IK in range, soft terms working):

    model            residual mean / worst   out of range   worst frame-to-frame jump
    humanoid_flex     7.9 / 17 cm             0              none over 0.3 rad (was 2.75)
    humanoid_flex2    6.5 / 14 cm             0              0.62 rad, one joint (was 1.77)

* Posture sweep on flex2, now alive: 0.15 (the default) is best — 1, 5 and 25 drag the solve until
it snaps (residual 11 / 17 / 25 cm, jumps up to 2.3 rad).
* Settling frame 0 (extra solves from its own answer) changed nothing — the frame-5 flip moved
to frame 7 — and is kept only as a cheap default; the flip was the dead posture term.

**B0 is `Tracker`**: for every DOF, the reference acceleration plus an implicit spring on the
error and the velocity error, all through `rbt.differentiatePos` — so a ball joint's error is
its rotation vector in the CHILD frame (drecon2 0w's two ball-joint bugs cannot recur).

    torso welded, 60 Hz, 20 Hz springs      humanoid_flex (hinges)      humanoid_flex2 (7 balls)
    B1  reach dance frame 0 in 1 s          0.04 deg    PASS            0.06 deg    PASS
    B2  the clip, worst body per frame      mean 2.8, worst 7.1 deg,    mean 4.7, worst 26.6 deg
                                            0 frames over 10 deg        (frame 577), 29 over 10
    maximal motors (flex)                   B1 11.3, B2 mean 22.6 / worst 53 deg

*** **THE ROBOT FOLLOWS THE WHOLE RETARGETED DANCE LOCALLY, WITHIN 7 DEGREES AT EVERY FRAME**, on
humanoid_flex at 60 Hz. drecon2 0al measured 596 degrees for the same question.

**Next, headless:** (1) flex2's frame-577 transient; (2) B3, the PUPPET: the floating model with
its root PRESCRIBED along the clip's own root trajectory — the same tracking, now carrying the
inertial loads of a moving, turning torso, through floating-base inverse dynamics with the root's
acceleration given; (3) the maximal side: velocity feed-forward for the motors, and ball joints;
(4) `dance_track` onto `robot_dance.retargetClip`, verified by the smoke test until a GPU is back.

### 8.7 2163, Sep 18 (night) — B3 the puppet passes; the stick measures the balance demand

**B3: the floating model with its root carried along the clip's own trajectory by a rigid
"stick"** — the root's rows of M a + c applied as the stick's wrench, the joints tracked by
`Tracker`, no floor:

    humanoid_flex    mean 2.78 deg, worst 7.12 deg, 0 frames over 10 deg
    humanoid_flex2   mean 4.74 deg, worst 26.6 deg, 29 frames over 10 deg

*** **IDENTICAL TO B2 TO THE DIGIT.** With exact inverse dynamics, a torso that moves and turns
like the dancer's costs the joints nothing — its inertial loads are cancelled exactly. So every
remaining difficulty of the dance lives in ONE place: the root's wrench, which the stick supplies
here and the feet must supply on a floor.

* The first version applied only the joint rows and placed the root after each step: 171 deg
from the first frames. Within each step the body free-fell while the torques assumed a held root
— the snapped-back-root flaw again (ragdoll_compare §9). **A stick must push, not teleport.**

** **THE STICK'S WRENCH, OVER THE TEN SECONDS** (body weight 395 N):

    vertical      -1,470 .. +1,600 N        (a floor cannot pull; the feet cannot push 4 g)
    horizontal    up to 2,030 N — 5x weight (friction gives ~0.7x)
    torque        mean 278, max 1,513 N m

*** **MOST OF IT IS CAPTURE NOISE, NOT DANCE.** The reference root accelerates at mean 8.5 / max
38.6 m/s^2 — but the RAW capture's hips already do 7.0 / 31.8. Double-differencing 60 fps mocap
amplifies millimetre jitter: 1 mm of noise alone is ~9 m/s^2, which is the mean. The IK adds
only a little.

**Next, in order:**
1. **Filter the reference** before tracking it — the standard move in physics-based animation: a
   low-pass (~6-10 Hz) on the target trajectory, root and joints (through differentiatePos /
   integratePos so ball joints and the free root stay on their manifolds). Then re-measure the
   stick: what is left is the dance's TRUE balance demand, and it decides how hard R1 is.
2. flex2's frame-577 transient (26.6 deg).
3. The maximal side: velocity feed-forward, ball joints.
4. `dance_track` onto `robot_dance.retargetClip`, smoke-tested headlessly until a GPU is back.

### 8.8 2163, Sep 18 (late night) — the reference, made physically plausible: filtered and grounded

**`Clip.smoothed(cutoff)`**: a zero-phase Gaussian low-pass in the model's own velocity space
(differentiatePos -> smooth -> integratePos), so ball joints and the free root stay unit
quaternions. **The stick was the wrong instrument**: measured while a controller runs it includes
the controller's own corrections (a few degrees times a 20 Hz spring's w^2 reacts through the
root), and its horizontal demand stayed at 5x body weight whatever the filter. **The right one is
the reference's own inverse dynamics** — each frame's pose and velocity, the clip's acceleration,
no controller — `referenceDemand`. Body weight 395 N; "floor-impossible" = pulling down, or
sideways beyond friction 0.7:

    humanoid_flex    bent by   vertical N       horizontal N   torque mean/max Nm   impossible of 597
    unfiltered       -         -603 .. 1026     698            86 / 426              19 pull + 130 slide
    12 Hz            1.3 deg   -121 ..  889     533            76 / 300              12 + 110
    8 Hz             2.8 deg    -77 ..  858     499            71 / 249               7 + 92
    5 Hz             6.4 deg     12 ..  815     392            64 / 208               0 + 53
    3 Hz            15.0 deg    101 ..  725     238            57 / 173               0 + 8

*** **AFTER A LIGHT 5 Hz FILTER THE DANCE IS NEARLY PERFORMABLE BY FEET**: nothing pulls, and the
peak sideways push is about one body weight — grip, not magic. humanoid_flex2 reads the same.
(Its "bent" is larger — 21 deg at 12 Hz — because the point-cloud IK barely constrains a ball
joint's TWIST about its own bone, so the twist jitters and the filter removes it.)

**`RetargetOptions.ground`** (default on): one vertical offset per clip putting the median of each
frame's lowest foot point at z = 0. **The feet were in the floor**: the torso is placed at the
capture's height on legs that are not the capture's.

    lowest foot point, 599 frames      on floor (-2..+5 cm)   sunk   floating
    humanoid_flex, as retargeted       201                    387    11
    humanoid_flex, grounded            479                     90    30
    humanoid_flex2, as retargeted      220                    378     1
    humanoid_flex2, grounded           596                      0     3

*** **humanoid_flex2 IS THE MODEL FOR THE FREE-ROOT RUNGS.** Its reference is legal, smooth, 6.5 cm
from the capture, grounded in 596 of 599 frames, and dynamically plausible after 5 Hz. One offset
suffices because its proportions match the capture; flex's foot height varies with the pose.

* `limpKeepArmature`: the dance tests keep the model's armature — zeroing it (for fairness with
the maximal side) left flex2's mass matrix singular in some poses (factorM pivot -2e-8).

**Next:** (1) R0 — the free root on a FLOOR, flex2, filtered and grounded reference, the joints
tracked by `Tracker` + floating-base ID, with the root ASSISTED by the reference's own demand
wrench (`referenceDemand`'s root rows) — then the assist scaled toward zero, measuring how far each
step of removal gets; (2) the flex2 frame-577 transient; (3) the maximal side; (4) `dance_track`.

### 8.9 2163, Sep 19 — R0 measured: the free root on a floor, and contact-aware inverse dynamics

humanoid_flex2, reference filtered at 5 Hz and grounded, a real floor through the physics bridge,
60 Hz. Joints: `Tracker` + inverse dynamics. Root: an ASSIST, alpha times the root's rows —
the wrench a stick would push with; alpha = 0 is open-loop playback with an exact controller.

    followed, of 9.97 s          alpha 1                    alpha 0.5    alpha 0
    held-root ID                 9.95 s, assist 0.83 x W     4.0 s        0.12 s
    contact-aware ID             9.95 s, assist 0.60 x W     6.5 s        0.13 s
    (W = body weight, 395 N; joints on the floor mean 14 deg — 4.7 in the air)

*** **HELD-ROOT TORQUES ARE WRONG ON A BODY THE FLOOR IS HOLDING.** Inverse dynamics without the
floor's forces assumes the root is carried; at alpha 0 the joints went 60-84 deg off in three
frames. **`contactTorques`** asks the floor contacts for the root's rows instead — least squares
over each touching contact's force, friction cones, a contact that would pull dropped — and the
joints get wrench - sum J^T f. What the feet cannot supply is the RESIDUAL: the assist R0 was
meant to measure.

** Its first version blew up in two frames, and the instrument said why: a speculative contact
1.2 cm away and 1e-4 regularisation let one contact plan 12x body weight, its moment cancelled
by tangential forces that the friction clamp then removed — a residual LARGER than the demand.
Only touching contacts, regularisation 1e-2 and a 2,000 N cap per contact fixed it.

* And frame 0 had a phantom shove: "before" equal to "now" makes the reference acceleration
v_ref / dt, ~30 m/s^2. R0 now starts at frame 1.

*** **THE FREE-ROOT PROBLEM, STATED EXACTLY: a residual of 0.6 x body weight on average.** With
it assisted the dance is followed for all ten seconds; halved, 6.5 s; without it, 0.13 s.

**Next — shrink the residual, in order of cost:**
1. **Stop demanding the root match the reference exactly.** The demand includes `Tracker`'s own
   spring on the root; on a floor the root should follow what the contacts CAN provide.
2. **Plan contacts from the reference's feet**, not only the ones touching this step.
3. **Feet with area.** flex2's feet are capsules and spheres — a few points of support.
4. Then alpha toward zero again; whatever remains is what a balance layer must add.

### 8.10 2163, Sep 19 — the root's demand made soft: physically consistent, no assist

**`contactConsistentTorques`**: solve jointly for the contact forces f AND a change `delta` to
the root's acceleration, minimising |W_r + M_rr delta - A f|^2 + root_weight |delta|^2 + eps |f|^2;
after the friction clamp `delta` is recomputed so the root's rows balance EXACTLY with the forces
kept. No assist exists: the root goes where the feet can take it. With no contact it is the
floating-base solution.

    R0, flex2 on the floor, NO ASSIST          followed    joints while up (mean / worst)
    contact-aware, root demand hard            0.13 s      38 / 143 deg
    consistent, root_weight 100                0.68 s      14 / 21 deg
    consistent, root_weight 1,000              0.60 s      13 / 27 deg
    consistent, root_weight 10,000             0.58 s      10 / 36 deg

*** **5x LONGER, AND THE JOINTS NO LONGER BLOW UP.** The torques are consistent with the floor
now, so what ends the run at ~0.6 s is plain balance — the body drifts off its support, as the
held standing pose did in 1.4 s (§8.2) — not a control inconsistency.

**Next:** the balance layer (§8.4's S-rungs), now on a consistent controller: feed the root's
error back into what the contacts are asked for (a centre-of-mass / root PD folded into
`W_r` before the split), stand first (S0/S1), then the dance again.

### 8.11 2163, Sep 19 — S0/S1: the consistent controller cannot stand, and why

`runOnFloor` now runs every floor rung (R0 refactored onto it, same numbers). S0/S1: flex2's
standing pose, grounded, as a ten-second clip that never moves; no assist; shoved 0 / 0.5 / 1 m/s.

    stood, of 9.97 s               no shove   0.5 m/s   1 m/s     joints mean
    contact-aware                  0.43 s     0.05      0.03      18 deg
    consistent, root_weight 1e2    1.47 s     0.58      0.38       4 deg
    consistent, root_weight 1e4    2.33 s     0.92      0.50       4 deg
    consistent, root_weight 1e6    1.42 s     0.83      0.55       5 deg

* A first theory, half right: eps |f|^2 penalises the TOTAL force, and holding the body up already
costs ~400 N a foot, so a corrective 40 N costs ~320 against root_weight x 1 for abandoning the
correction — at 100 the solve dropped balance. Weighting the torso up helped (1.47 -> 2.33 s) and
did not fix it: every setting falls within 2.3 s, statue-like (§8.2: 1.40 s).

*** **BALANCE NEEDS THE JOINTS TO MOVE.** With every joint locked to the reference, the only
corrective lever is shifting the centre of pressure under the feet — and flex2's feet are small
capsules and spheres. People balance with their ankles, hips and arms.

**Next — the balance layer proper: task-space inverse dynamics.** Unknowns: ALL accelerations and
the contact forces. Hard: the equations of motion's root rows (consistency, as now) and the stance
contacts' accelerations zero (feet neither slide nor sink). Soft: joint accelerations toward
`Tracker`'s, the torso's toward its corrective wish, moderate forces. The legs and hips then move
to keep the body over its feet, which is exactly what locking them to the reference forbade.

## 9. 2163, Sep 19 — THE RL SETUP: humanoid locomotion with pose-offset actions

Simon's call: balance can wait; prepare the RL setup — efficient local pose targeting with the
DReCon / SuperTrack pose-offset trick, benchmarked on the classic humanoid locomotion task with PPO.

**What already exists (zimrnum):** `ppoUpdate` (clipped surrogate, continuous and discrete),
`gae`, `normalizeAdvantages`, `RolloutBuffer`, an off-policy step, AWR, SuperTrack in miniature,
cartpole environments and an end-to-end "the return must RISE" test. **The learner exists; what
was missing is the environment.**

**`src/robot_gym.zig` - `HumanoidEnv`**: MuJoCo's humanoid (`humanoid.xml`, 21 hinges, free torso)
on a real floor through the physics bridge, headless, 60 Hz physics, 30 Hz policy.
* **Action: 21 pose OFFSETS**, target = standing pose + 0.5 rad x clamp(a, -1, 1), tracked by
  `robot_dance.Tracker` (the implicit 20 Hz spring) through floating-base inverse dynamics. The
  policy starts from "hold a pose", not "invent every torque" (Peng & van de Panne 2017); with a
  reference motion the base pose becomes the reference frame and the offsets are DReCon's.
* **Observation (76), heading-invariant:** torso height, gravity in the torso frame, torso
  velocities, and per hinge its angle, speed and previous action.
* **Reward, Gymnasium Humanoid's shape:** 1.25 x forward speed + 5 alive - 0.1 x sum a^2; a fall
  (torso under 0.9 m) terminates; 500 policy steps (16.7 s) truncate.
* **Reset forgets everything** — world and bridge rebuilt, robot data reset: the first version
  kept them, and the same seed did not replay the same episode (contact caches and the solver's
  warm start carried forces over). Now it repeats to the bit.

    baselines, 5 episodes          mean length           mean return
    zero actions (hold standing)   37.6 steps (1.25 s)   216.5
    random actions                 15.0 steps (0.50 s)    66.5
    throughput, 1 core, ReleaseSafe: ~2,300 policy steps/s (~4,600 physics steps/s), resets in

A million policy steps is ~7 minutes of simulation on one core.

**Next:** the PPO loop on `HumanoidEnv` with zimrnum's `ppoUpdate` — a Gaussian policy and a value
network, rollouts of a few thousand steps, GAE, observation normalisation — and the curve's first
number: does the mean episode length rise above the statue's 37.6 steps?

## Correction (Sep 19): most of B2's error was a SERVO bug, not the targets

rl_track_journal.md §11 (the J2 rung): `robot_dance.Tracker` took its velocity error against the
FORWARD difference (next - now)/dt, while robot.zig's semi-implicit Euler needs the robot at
`now` with the BACKWARD difference (now - prev)/dt. Perfectly on track the spring therefore saw
-dt a_ref of error every step and pushed off the reference - ~dt a_ref / (pi f) per joint,
compounding down chains. Fixed (the error is now against v_prev). B2 on humanoid_flex2: mean
4.74 / worst 26.60 deg -> 0.03 / 0.09; on humanoid_flex 2.78 / 7.12 -> 0.03 / 0.08. The readings
above that blame target flips and transients for B2's error (8.5-8.8) predate this; the free-root
results (balance) are unchanged by it.

