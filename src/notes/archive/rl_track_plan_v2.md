# rl_track_plan.md — v2: what is left for SuperTrack and DReCon, all resident on the GPU

**Status: v2 from Sep 23 2026. ACTIVE - Phase S, data first: next is velocity feedforward in the servo, then the clip's per-frame lift, then D1-D4.** This is the
forward plan only. v1 - the design, the rungs T1-T9b and Phase R's first steps, with every number
they measured - is archived verbatim at `src/notes/archive/rl_track_plan_v1.md`. What happened, turn
by turn, is `rl_track_journal.md`. Rungs are named by phase (R, S, C, H, Q, M); a rung is done when
its known answer holds, whatever that costs in turns.

---

## 0. Standing rules (every turn)

1. **One known answer per rung** - a comparison with something already known (the CPU twin, an
   analytic result, a conservation law, a published number). "It trains" is not one.
2. **Every GPU kernel has a CPU twin**, and every GPU path is tested against it headless.
3. **Targeted tests every turn; the full gate at each phase's end.**
4. **The robot-mocap tutorial stays in sync** - generated code blocks, prose updated in the turn
   that changes it, new chapters as methods land (§6). Present it when it changes.
5. **Comments casual and verbose**: what, why, what goes wrong otherwise. History goes in the journal.
6. **Every experiment carries a control** (the servo beside the learner, the oracle beside the model).
7. **A measurement is only as good as the world it was made in.** Every environment has a standing
   guard (no actions, 30 frames, still on the floor) before it gets a learner.
8. **Pages build in `release`, never `ship`, and pass `smoke-test -Dfocus=<page>` before a device.**
9. **Each turn ends with** targeted tests green, a clean `zig build check` (after `zig build fix` if needed -
   builds are no longer gated by style; standalone pages, dist, check and ship mode are), tutorial in sync,
   a journal entry, a snapshot.

## 1. The goal, stated so it can fail

**THE NORTH STAR (Simon, Sep 21).** On Simon's phone, in the browser, the get-up trains **from
scratch** - characters stepped on the phone, networks trained on its GPU - and the page **downloads
its weights to a file and accepts one back** to continue or to watch. Weights come only from runs on
his phone. **The metric is wall-clock minutes to the bar on his phone**, samples beside it; every
method and trick below earns its place by minutes saved there, against the servo and against PPO.

**Then: track four clips well, under perturbations**, with everything resident on the GPU - on the
Geno robot, with a SuperTrack-based hybrid, and DReCon's steerable layer on top. The clips (LaFAN1,
already on Geno's skeleton): `walk1_subject2`, `run1_subject2`, `dance1_subject2` (its first 30 s),
`fallAndGetUp2_subject2`.

| goal | passes when |
|---|---|
| **G1 quality** | each clip tracked for its whole length with no fall: **mean body position error < 6 cm, mean body rotation error < 8 deg** (all bodies, after the first 0.5 s), real simulator, the policy's mean action |
| **G2 perturbations** | a random 50-150 N shove on the torso for 0.15 s every 2 s: **no fall in 20 consecutive runs of each clip**, error back under G1's bound within 1 s |
| **G3 each part earns its place** | same task and budget: every method and trick below stays only if it improves G1, G2 or minutes-to-bar |
| **G4 cost** | the trained controller runs a frame in **< 4 ms on a desktop, < 16 ms on the phone**, MPC included, every buffer resident |

## 2. Where we stand (Sep 23)

(For Phase S - standing, resets, the learners' results and the ordered next steps - see Phase S below.)

**Working, with known answers on file:**
- **The SuperTrack learner, resident on the GPU** (`robot_latent_kit`, `robot_track_resident`): a
  LATENT world model (D15: 15.5 mm pose drift at 8 steps, against 247 for the structured one) and a
  policy trained through it over 8-frame windows (D6), from windows the GPU gathers out of a ring
  the CPU fleet fills; one recording per round. Parity with the CPU learner: world model 1.2e-5,
  policy 9.7e-8; the CPU mirror that acts matches the GPU policy to 7.2e-9.
- **Page `track_train`**, on the phone: 30x real time, 1,865 character-steps/s, mean time to failure
  **1.20 s exploring / 1.82 s alone, against the servo's 2.22 s**. Two limits, both measured: the CPU
  simulation (one round already fills a frame), and **the policy exploits a weak world model** - the
  CPU learner showed the same shape (0.71 s against 0.89).
- **DReCon's RL half as the baseline** (`robot_policy`, `robot_ppo_track`, page `getup_train`): PPO
  with DReCon's observation and filtered action, observation normalisation, the annealed root assist,
  and a versioned weights file (download/upload). Phone: best batch 1.74 s against the servo's ~1.1 s
  (on the old robot).
- **The task** (`robot_track`): tracking error, reward, termination by error, RSI resets, the servo
  with an authority limit, the per-frame lift, replay rings, the fleet. SHAC's critic exists and was
  measured to HURT at CPU budgets (v1, T8d).
- **Phase R so far**: `robot_geno` reads Geno's skeleton (hips 0.855 m, thigh 0.382, shin 0.399;
  the rest sole descends 23.3 deg bind / 21.9 stance - anatomy, not error). `tools/geno_fit.py` makes
  **21 shapes** from Geno's skinned mesh: capsules, floor-aligned boxes for the feet and toes; symmetric
  by construction; never reaching below the posed mesh on any frame of two captures (3 mm), so lying
  down they meet the floor where the body does; overlapping at every joint, chosen jointly; an athletic
  torso by design (its chest pokes out in front on purpose). Page `geno_fit` shows them on the captures,
  lifted per frame, with Geno's skinned mesh under a toggle.

**Not built:** the Geno robot model itself; a weights file for the resident learner; mirror
symmetry; anything of the simulator on the GPU; the critic in the resident loop; MPC; torque limits;
perturbations; more than one clip at a time; motion matching.

## 3. The remaining work, in order

### Phase R - a robot that IS Geno (active)

The captures are already Geno's skeleton, so the robot is built from Geno's own measurements and
retargeting is a copy. **Retargeting quality is not negotiable (Simon): every bone the captures turn is
a body, and a copy stays exact.** Collision shapes are a separate matter - a body may carry none.
Code: `robot_geno.zig` (R1-R7), `tools/geno_fit.py` (the shapes, into `src/robot_geno_shapes.zig`), page
`geno_fit` (shapes and skinned mesh on the captures). History: the journal.

**Done, and what each settled:**
- **R1 skeleton, R2 rest pose = bind** (the mesh, shapes, sole and mass all live there; the file's own
  zero has the arms straight up). The copy's convention proven before use: identity joints give bind
  exactly; the stance's copied joints give the stance to 3.8e-7 m. `jointFromLocal` IS retargeting.
- **R3 sole** from the mesh: -4.5 mm at bind, heel and toes touching; mesh and skeleton share one frame
  to 3e-7 m.
- **R4 shapes** (21): symmetric by construction; never below the posed mesh on any frame of two
  captures (so lying down they meet the floor where the skin does); neighbours overlap >= 1.5 cm,
  chosen jointly per chain by dynamic programming; an athletic torso by design; no shapes on the
  clavicles; a slim neck capsule carried by Neck1.
- **R5, R5b mass**: the volume inside the skin, sampled exactly (an analytic box to the digit): Geno is
  60.0 kg. Cut at the joints the anthropometry tables' way. Geno's upper arms and feet are genuinely
  heavier than the tables' adults (every cut agrees) - the robot keeps Geno's body.
- **R6 ranges** from the four tracking clips (4,680 frames): knees bend 142 deg, elbows 120 / 107. Ball
  joints (hinges would lose the elbows' ~75 deg of roll); limits on the TOTAL angle (the swing/twist
  split is ambiguous at the hips - Codman's paradox) at the library's maximum + 5 deg.
- **R6b model** (`writeModel`, MJCF): 24 bodies, each body's frame its bone's rest frame, only the root
  turned z-up (so capture rotations drive it untouched), measured masses and inertias, massless shapes,
  a floor. Through the engine: every body within 2 um of bind, every shape within 2.1 um of the fit.
- **R6c contact exclusions**: the shapes overlap by design, and across shapeless bodies those overlaps
  are not adjacent - so MJCF `<contact><exclude>` is now read, carried and honoured by the bridge, and
  the model excludes its three such pairs. **The standing guard passes with room for every contact.**
- **The tracking set's dance is now `dance1_subject2`, its first 30 s (Simon, for the first SuperTrack
  tests)** - 1,800 frames on Geno's full 75-joint skeleton (fingers included), in
  `assets/lafan1/dance1_subject2.bvh`; it replaces `dance2_subject2` in Geno's pipeline (the old robot's
  IK-baked clips keep theirs). Ranges now over 5,280 frames: knees 148.6 deg, elbows 139.7; the copy stays
  exact on all four clips (7.4e-5 deg; 3.2 um with rigid bones).
- **R7, first half - the copy** (`Copier`): the engine's conventions read off its own rest pose (w LAST,
  the free joint ABSOLUTE); over all 1,080 get-up frames every body is turned as captured to 7.4e-5 deg,
  the head exactly.

**Next, in order - each with the answer that closes it:**

- **R7b - DONE: the copy is exact.** Measured first: only the knees' and elbows' translations ever differ
  from bind, and they MOVE over time - the captures stretch the thighs and upper arms by up to 3.2 mm frame
  to frame, which no rigid robot can copy (so the model keeps bind's lengths, the mesh's own). **Over all
  4,680 frames of the four clips: every body turned as captured to 7.7e-5 deg and placed where the
  capture's kinematics puts it with the robot's rigid bones to 3.2 um; against the recording, 3.2 mm - its
  stretch, and nothing else.** The tilt probe now takes its axis from the rest pose (the sole is flat there
  by construction): the walk's standing soles tilt 2.1 deg. (The get-up does not end flat-footed.)

- **R8a - the training task on the Geno robot.** Everything that trains today runs on
  `humanoid_flex2`: the task (`robot_track`) embeds that model, and the clip baker (`robot_dance`)
  retargets onto it with inverse kinematics. The port, one piece at a time:
  1. **DONE - the model as a fixture.** `src/tests/fixtures/robot/geno.xml` (12,231 bytes), held
     byte-equal to a fresh `writeModel` by the model test, which rewrites it and fails once when the
     model changes - a changed model is always a reviewed diff.
  2. **DONE - the clips by copy.** `copyClip` makes the task's own `dance.Clip` from a capture: every
     frame the engine's position vector (99 numbers: the free root's 7, four per ball), each frame's
     residual the farthest body from the RECORDED capture - its stretch, 3.2 mm at worst over the four
     clips. Still to do in part 5: the per-frame lift from Geno's lowest shape, where the task grounds
     clips today.
  3. **DONE - the servo on balls, and an engine bug found by it.** `robot_track.pdTorques` is generic by
     design (a stable spring asks every degree of freedom for an ACCELERATION; the model's own inverse
     dynamics turn it into torque - no per-joint gain table, the measured inertias scale each joint). On
     Geno from `geno.xml`, gravity off: bind -> the walk's first frame (copied), **error 2.02 -> 0.00000
     rad in 0.5 s.** It first stalled a third of the way; diagnosed in order - not the floor plane, not the
     acceleration clamp, but THE LIMITS: the engine applied a ball joint's `range` as a scalar limit on the
     quaternion's first number (the limit rows bound one coordinate), pinning any joint whose pose wants
     that number negative. Fixed where ranges are assigned (`robot.zig`): hinges and slides keep theirs; a
     ball's is not applied until cone limits exist (E1 below). **This also touched the old robot** - its
     knees, ankles and toes are balls with ranges, mis-limited until now; its baselines may shift.
  **DONE - the page, `geno_track` (Simon: "so I can test").** Geno from `geno.xml` (the facade exports
  the fixture's bytes and `robot_geno`), the walk and the get-up copied with `copyClip`, the floor through
  the bridge with the model's exclusions, the task's servo unchanged; the reference drawn as a translucent
  ghost; a fall = hips 35 cm from the reference's, with last and best run times; the camera follows the
  hips. Release build, smoke PASS. Still to add: Geno's skinned mesh (as `geno_fit` draws it).
  **Measured headless (`ServoRun`, the page's loop shared with tests): UNSTABLE.** Holding the walk's first
  frame for 2 s LAUNCHES the robot (hips 21.9 m away); mean time to failure 0.54 s walking, 0.83 s on the
  get-up - numbers that mean nothing until the stand is stable. The servo alone in zero gravity converges
  exactly, and the unpowered ragdoll rests on the floor - so it is the three TOGETHER: servo, gravity,
  contacts, at 60 Hz, on Geno's model.
  - **S1 - stabilise the servo on a floor (IN PROGRESS).** (a)+(b) DONE: every ball joint now carries the
    old robot's armature 0.01 and damping 0.2 (`joint_armature`, `joint_damping`; no passive stiffness, which
    would bias every pose toward bind). **The launch is gone**: held stand 21.9 m -> 1.0 m; walk MTTF 0.71 s,
    get-up 1.84 s (runs to 6.7 s). **But the BIND pose - symmetric, feet flat - still falls: hips 0.70 m in
    2 s.** Prime suspect now, (e): the servo's torques come from FLOATING-BASE inverse dynamics that
    ignores contact forces - the torques of a body in free flight, where weight costs nothing - so a
    standing robot gets no weight compensation at its knees and hips and sags until the spring's error
    pays for it, which at these gains is a collapse. (The old robot's held stand fell in 1.4 s under the
    same law - `servo_ladder`.) The remedy is already in the code: `robot_dance.contactConsistentTorques`,
    inverse dynamics WITH the contacts. Test it on the held bind stand first; then (c) and (d) below.
    **(e) MEASURED - only part of it.** `ServoRun.Law.consistent` (same spring, contact-consistent torques):
    bind stand 0.70 -> 0.51 m, walk 0.71 -> 0.74 s, but the get-up 1.84 -> 1.03 s. The floating law stays
    the default (the task's). **Next, in order:** (f) find WHICH joint gives way first in the held stand (per
    joint error over the 2 s) instead of guessing; (c) sub-step the physics at 240 Hz; (d) the per-frame
    lift; (g) cone limits (E1) - unlimited ankles and toes may fold under the body's weight.
    **(f) DONE - the culprit was collisions INSIDE the body.** Spine and Spine2 passed 5 deg on the very first
    frame: the torso's pills overlap not only their neighbours but the pill two joints away, and those pairs
    collided. The rule now: **every pair of shapes that overlaps at rest never collides** (`writeExclusions`,
    capsule-capsule by `segmentGap`; 18 pairs). Held bind stand: hips 3 cm at 0.25 s (was 22), a slow topple
    through the LEGS from 0.12 s (1.27 m at 2 s) - a balance problem now, not a numerical one. **MTTF: get-up
    2.61 s (above the old robot's 2.22), walk 0.93 s.** Next: why the legs give way - (g) cone limits, (d)
    the lift, (c) sub-stepping, and the servo's authority at the hips and knees.
    **TUNED for the get-up (Simon: "as long as possible").** A headless sweep ("S1 tuning sweep", a slow
    test), one knob at a time, then the winners combined, judged by the get-up's MTTF over 17 starts: the
    servo's ACCELERATION CAP is the lever - 400 -> 3000 rad/s^2 takes the get-up from 2.61 to 3.02 s (it
    stops binding near 3000). Armature 0.1 (2.77) and damping 3 (2.70) help alone but not combined with the
    cap; frequency barely matters. So the model stays (armature .01, damping .2) and `servo_gains` carries
    the one change, used by `ServoRun` and the `geno_track` page (rebuilt, smoke PASS, on Simon's phone).
    **The held stand, re-measured with the tuned servo: unchanged (hips 1.21 m in 2 s, the whole body tipping
    together from 0.12 s).** And the bind pose IS statically balanced - the closed mesh's centre of mass (60.0 L,
    exact by the divergence theorem) sits at x = 0, 11.4 cm in front of the heels and 12.1 cm behind the toes.
    A pose held rigidly there would stand like a statue, so the servo is NOT holding it rigidly: joints yield
    5 deg in 0.12 s where a 20 Hz spring should hold the knee to about a degree against the body's weight.
    **Next (h), measured not guessed:** at t = 0 of the held stand, the torque the servo produces at hips,
    knees and ankles against the torque statically needed to hold the pose on the floor (inverse dynamics
    with the contact forces the floor supplies) - the gap names the fault: weight uncompensated, contact
    forces arriving a step late, or the contact solve itself soft at 60 Hz.
    **The page, for Simon's own search:** a "hold T-pose" checkbox (Geno's own stance pose, held still) and a
    live "knee bend" slider - hips -b/2, knees +b, ankles -b/2 about the sideways axis, so the torso stays
    upright and the feet flat; the root lowered by however far the bend lifts the ankles, plus 5 mm.
    **Stiffness, measured:** STABLE up to 120 Hz on the 60 Hz step (no explosion - the stable spring through
    inverse dynamics); but 20 Hz keeps the get-up up longest (3.02 s against 2.5-2.6 s for 40-120 Hz): a
    stiffer servo follows the reference harder exactly where it cannot be followed. The page now has a
    "reset on fall" toggle (off: the ragdoll keeps its local pose on the floor), live stiffness and cap
    sliders, and the step's cost in ms against a 60 fps frame.
    Original list, for the record: In order, one change at a time, each judged by the
    held stand (R9's answer: hips drift < 2 cm in 2 s): (a) the old robot's settings - `humanoid_flex2`'s
    joint armature, damping and timestep, which Geno's model has none of; (b) armature on Geno's joints
    (the standard remedy for light links - hands, toes, Neck1, the clavicles - at a large step), written by
    `writeModel`, masses untouched; (c) physics sub-stepped (240 Hz under 60 Hz control); (d) the
    reference lifted per frame (part 5) - the copied soles sit 4.5 mm into the floor, so the servo presses
    the feet into it every frame.
  - **E1 - ball-joint cone limits (engine, before R9).** MuJoCo's meaning: a limit on a ball's TOTAL turn,
    one constraint row along the rotation's axis (three entries on the joint's DOFs). The ranges are
    already in Geno's model (R6: the library's maximum + 5 deg). **Known answer:** a ball pushed past its
    cone stops at the angle, within the solver's softness; unchanged inside it. A policy must not learn to
    fold a knee backwards, so this lands before any learner trains on Geno.
  4. **Layouts from the model - PARTLY DONE:** the replay's action layout was model-derived already; DReCon's
     policy subset now is too (`subsetFor`; Geno's lists in `robot_geno`). Observation (every body) and action (three per ball, 69 until S0b)
     derived from the model rather than written down, so the next robot costs nothing.
  5. **The guard inside the fleet.** The standing guard, run by the fleet itself on Geno.
  **Known answer:** all four clips load; at a reset the robot IS the clip's frame (tracking error zero
  to 1 mm - the copy); the fleet's own standing guard passes; the old robot still trains unchanged.

- **R8 - the reference is standable.** **Known answer:** mean sole tilt < 8 deg when a foot is down
  (35.7 on the old robot), nothing deeper than 1 cm after the lift, the feet the deepest part on
  nearly every standing frame.

- **R9 - the ragdoll holds a pose. THE GATE.** The servo holds the standing bind pose on the floor.
  **Known answer:** root drift < 2 cm in 2 s, no joint on a limit. If it fails, `servo_ladder`'s rungs
  are the method: gains scaled by each body's measured inertia, stable PD through the model, and the
  assist only as a last resort.

- **R10 - the servo alone on the get-up.** **Known answer:** mean time to failure well above the old
  robot's 2.22 s. It becomes the number every learner is measured against.

- **The phase's close:** the full gate; the tutorial's training chapters (7-13) re-synced onto Geno;
  `geno_fit` re-smoke-tested.

### Phase S - SuperTrack, made good (on Geno, on the phone)

(The Sep 23 working log of this phase is archived whole in `archive/rl_track_plan_phaseS_sep23.md`; the
journal has every dated step. This section says where things stand and what comes next, in order.)

**Principle (Simon, Sep 23): DATA FIRST, THE MODEL SECOND, EXPLOITATION LAST.** Build trajectories and a
world model worth trusting before any policy is allowed to exploit it. Ensembles (S5) only if exploitation
survives D1-D4.

**Established - the environment:**
- The task layer is model-agnostic: `robot_track.Fleet` takes any model and clip (options `gains`,
  `floor_friction`); DReCon's policy subset is `robot_policy.subsetFor(watched, actuated)`, Geno's lists in
  `robot_geno.drecon_watched` / `drecon_actuated` (30 of 69 action dims); the PPO trainer passes all of it.
- `ServoRun` (tests) and the `geno_track` page: clean restarts (warm starts, cached contacts, the bridge's
  motion, the reflex's memory forgotten - 0 of 99 numbers differ across restarts); every start rested ON the
  floor (`rbt.lowestPoint` / `restOnFloor`: the walk's first frame sank its feet 16.8 mm, a 0.21 m/s kick);
  every start launched with the reference's velocity (`referenceVelocity`, by `robot_mpc.stateDiff`: exact to
  0.0005 mm over one frame); `Snapshot` / `save` / `restore` (two rollouts from one moment bit-identical; a
  restored rollout drifts 8 mm in 20 steps from the unbroken run).
- **Standing works:** in the task's servo a joint's strength IS its free-flight inertia (torque = inertia x
  the spring's acceleration), so `standing_armature` (2) on every joint, with the capture-point reflex
  (`geno.Reflex`, ankle lean, gain 2-4), holds the T-pose the full 10 s (guarded by a test); neither alone
  does (~1.2 s, ~1.0 s); gain 8 over-corrects. Armature 2 costs the dance nothing (servo 1.26 s vs 1.24).

**Established - the yardsticks:** `judge` counts falls over a window and moves only in whole falls - use
`judge_steps` = 1,200 (20 s); `judgeQuality` adds DReCon's mean reward (tracking QUALITY: falls alone cannot
rank dance controllers); the launch test (one real step against the next frame) for anything touching resets.

**Established - learning so far (a few CPU minutes each, all on Geno):**

| learner | task | result |
|---|---|---|
| SuperTrack (CPU) | held T-pose | stable world model, but the policy is exploited: 1.12 s vs servo 1.19 (20 s judge) |
| SuperTrack (CPU) | dance, first 5 s | model says -19% tracking loss; reality: 10 falls / reward 0.844 vs servo 0 / 0.950 |
| PPO (CPU, 100 s) | held T-pose | 64.0 frames vs servo 62.8 - nothing yet |
| SAC (CPU, 110 s) | held T-pose | update-bound: 12,784 transitions; 61.5 vs 60.9 - nothing yet |

**Next, in order:**
1. ~~Velocity feedforward in the servo~~ **DONE, measured (Sep 24).** `robot_maximal.stableSpringAccelToward`,
   `robot_track.pdTorquesToward` (`pdTorques` = the `null` path, bit-identical), `ServoRun.feedforward` (off by
   default). The consistent end velocity for a target at frame g is the difference g-1 -> g (semi-implicit Euler
   moves a body by its NEW velocity). One real step from an exact launch: at the fastest frame 14.3 -> 4.8 mm
   worst; WITHOUT contacts every launch misses by about gravity's one step - g dt^2 = 2.72 mm (not 1.4: that is
   the continuous-time figure). But survival over the whole 30 s dance is unchanged (1.74 s vs 1.73; 0 of 15
   starts reach the end): the servo's limit is balance, not damping - the learner's job. Kept as an option; the
   learners' action semantics stay on the zero-velocity servo.
   **Also measured:** with standing armature and clean starts the servo ALONE keeps up with the dance's first 5 s
   to the end from every start (3.00 s = the ceiling; 1.26 s before clean starts) - so the learning focus should
   widen to where the servo fails (the whole dance: 1.74 s). **And contacts** throw limbs at some frames (one step:
   20 mm at frame 1290, 12.8 at 768, vs 6.7 and 5.8 without contacts): likely self-collision between pairs that
   do not overlap at rest - identify the pairs next.
2. ~~The clip's per-frame lift (R8a part 5)~~ **DONE (Sep 24).** `restClipOnFloor`: the copied dance pierced the
   floor on 1,798 of 1,800 frames, by up to 48 mm; after it every frame rests 1.00 mm above. `Fleet.Options.
   rest_on_floor` (off for the old robot) rests every training reset on the floor; `trackTrial` lifts its clips
   and sets it. ONE RESET EVERYWHERE: `ServoRun.start` and the page's clip restarts now use the task's own
   `robot_track.resetToFrame` (the backward difference INTO the frame - the discrete trajectory's velocity under
   semi-implicit Euler; known answer: one frame of it backward lands every body on frame f-1 to 0.0005 mm).
   Servo-only survival is unchanged by the lift BY CONSTRUCTION (the servo ignores the unactuated root's target);
   its value is the learners' reward and observations, which use the reference's absolute root height.
   **DECISION FOR SIMON - self-collision the reference itself makes:** the copied dance puts Geno's limbs inside
   each other (hand-hand 62 mm, hand-forearm 57, forearm-forearm 38, spine-forearm 33, spine-thighs 12, head-arms
   8.5: Geno's fitted shapes are fuller than the actor's flesh), and the solver throws them apart (a limb misses
   the next frame by up to 29 mm in one step, 4 without contacts). Excluding every pair the reference overlaps
   (46 pairs against 18) does not change the servo's survival (1.74 s both) - but a LEARNER is punished for
   overlaps no policy can undo. Options: exclude the reference's pairs (realism: hands pass through hands), slim
   the hands and forearms, or keep them and let rewards absorb it.
   **DECIDED (Simon, Sep 24): self-collision OFF until training works.** `robot_geno.self_collision = false`:
   `writeExclusions` excludes every pair of the 21 shape-carrying bodies (210 exclusions; the fixture regenerated)
   - every consumer (tests, page, fleets, later the GPU path) reads the model, so nothing else switches. The
   dance's one-step throw is gone (frame 1290: 29.4 -> 3.6 mm). **Re-enable** by setting it `true` (the model then
   excludes only pairs overlapping at rest) once a learner beats the servo.
3. **D1 - a teacher that cannot exploit: WORKS (Sep 24).** `robot_geno.Planner` - predictive sampling over the
   TRUE simulator: plans are knots of pose offsets on DReCon's actuated joints (the policy's own action space),
   perturbed `samples` ways, each played `horizon` steps from the saved moment (`save`/`restore`), scored by every
   body's stray from the clip plus a fall penalty; the winner's first step is taken for real (it IS the rollout's
   first step) and its plan shifted on. Measured (16 samples x 15 steps, 3 knots; ~0.25 ms a physics step in
   release): from 4 hard starts, capped at 5 s - sigma 0.1: 3.21 s, 0.2: 4.43 s, **0.3: every start reaches the
   cap** (servo alone 0.92 s). **The whole dance from frame 0, one run: planned 17.05 s, servo alone 6.65 s.**
   **(a) Where it fails, measured:** not drift - scored in WORLD positions the run ended lost (heading 31 deg,
   shape 547 mm off in its own root's frame): a drifted body gets bent toward where the dance is on the floor.
   Scored SHAPE-FIRST (bodies in their own root's frame) + 0.3 x the root's horizontal miss: 15.05 s, ending
   with heading 4 deg and shape 148 mm off - far truer to the dance; kept (a teacher's point is fidelity).
   **The teacher's REACH (Sep 24):** unlimited, a plan random-walks (every step shifts the winner and perturbs it
   again) - offsets past 3.3 rad appeared, actions no policy could take. `Planner.Options.limit` clamps each
   offset per degree of freedom, as a squashed policy's `[-1, 1] x scale`. From four hard starts (5 s cap,
   shape-first cost): unlimited 4.74 s, **0.6 rad 4.45 s**, 0.3 rad 2.46 s (servo 0.92). **So Geno's policies need
   an action reach of ~0.6 rad per freedom (`action_scale` 0.6), not the 0.3 the trials used**, and the teacher
   records at that limit. (`Planner.choose` / `act` / `actionOf` / `record` and the test "D3 data" record planned
   steps in the task's own replay format - reproduced through `applyAction` to 1.2e-7. NOTE: that code appeared
   in the tree between turns without a visible edit from this session; reviewed, sound, adopted - Simon to confirm
   its origin.)
   **Next for D1:** single runs of a stochastic planner are anecdotes - sweeps now take >= 3 seeds a setting; (b) budget: 32 samples, horizon 20-30, sigma 0.3-0.4;
   (c) on the phone - a "planner" switch with a small budget (8 x 10 is ~50 ms a frame there); (d) its
   trajectories recorded - the data for D3 and the teacher for D4.
3b. **`geno_train` - SuperTrack on Geno ON THE GPU (Sep 25, for Simon's 3-minute test).** `track_train` with Geno:
   standing armature, self-collision off (the model), resets rested on the floor, action scale 0.6 (the teacher's
   measured reach), Geno's servo and floor; clip = the dance 5 s -> 15 s (`examples/geno_train/dance.zclip`, baked
   and held byte-equal by the test "geno_train's clip"). Smoke PASS (2.0 MB wasm). What the phone tells us: the
   GPU's training throughput on Geno (rounds, world/policy updates, seconds of motion trained per second) and
   whether SuperTrack's policy beats the servo there in minutes (its panel: the policy alone vs the servo alone).
   Its data is still SuperTrack's own (policy + noise) - D3's jittered-candidate recipe is not in it yet.
   **Phone, first test (Sep 25): slow, then crashed; the policy "looks like it is exploding".** Reproduced on the
   CPU twin with the page's setup (test "how jittery is the policy"): servo 91 falls / reward 0.779; SuperTrack 140 /
   0.531 - its actions jump 0.111 a frame against a size of 0.159: noise. **Fix, CAPS temporal smoothness**
   (`w_smooth`, the policy pays `w |a_k - a_(k-1)|^2` along each window, TWO-SIDED - `mseLoss` gives no gradient to
   its target, so the difference itself is differentiated): jumps 0.111 -> **0.025**, falls 140 -> 118, reward
   0.540. Ported to the GPU kit (`lat_act_bwd` pulls each step toward both neighbours; the parameter block's padding
   words reused, size unchanged) - policy gradients match autodiff to 1.4e-6; the kit's suite green. The page now
   runs 4 characters (8 overran the frame budget on the phone) with `w_smooth` 1. Still worse than the servo:
   exploitation remains - D3/D4's job.
   **Phone, second test: still crashes reliably after ~3 minutes (Simon: "GPU leak?").** Headless, NOT a leak: the
   smoke harness now reports live CPU bytes at the halfway frame and the last (`-Dsmoke-frames=N`, new) - flat at
   46.9 MB from frame 30 to 300 - and the GPU handle balance is identical at 60 and 300 frames. (Node's heap OOM at
   600 frames is the HARNESS's own call log - 1.35 M entries - not the page.) **The cause: an unbounded GPU queue.**
   The page raised its rounds per frame while the FRAME time stayed under budget, up to 64 - but the frame time
   only measures the CPU, to which a submitted round costs next to nothing; on a phone whose GPU cannot finish a
   round a frame, unrun work piled up in the browser's queue until memory ran out (the phone slowed, screenshots
   died, the page crashed). **Fix, both `geno_train` and `track_train`:** at most 8 rounds' worth of dispatches
   submitted and not yet confirmed (`Compute.readGeneration`: `submitted - mirrored`, the readback being the GPU's
   receipt); past that a frame submits nothing, asks for a receipt and backs off; the panel shows "frames waiting
   for the GPU". Untestable headless (the stub GPU never lags) - Simon's next run is the test.
   **Also found - a teardown bug:** after 300 frames the page's deinit frees NO GPU resource (after 60 it frees the
   learner's); harmless on a phone that never tears down, but the reset path's - to fix.
   **Phone, third test: still crashes; "frames waiting for the GPU" climbs (171 at 71 s, 443 at 149 s) - and world /
   policy updates FROZEN at 174 while rounds went 1,262 -> 2,345; the policy 0.11 s to failure (servo 3.33 s).**
   Read: (1) a DEATH SPIRAL - `drawWindows` needs 8-step windows inside one episode, and a policy failing within 5-7
   frames leaves none, so training stops for good and the bad policy never improves; (2) a policy THAT bad (10x
   worse than its CPU twin at similar updates) smells of non-finite weights - and NaN bodies are never terminated
   (every comparison with NaN is false), running NaN physics, a plausible crash. **Fixes:** `Termination.grace_steps`
   (the page: one window) - every episode yields a window; a non-finite tracking error ends the episode at once;
   `syncMirror` refuses non-finite weights (keeps the last good ones) and `act` zeroes non-finite actions, both
   COUNTED on the panel ("bad weights refused, bad actions zeroed") - so the next run diagnoses; and the smoothness
   kernel made BRANCH-FREE (a missing neighbour points at the step itself, `raw - raw` = 0) - the sentinel compare
   it replaced had never run as real WGSL. Gradients still match autodiff (1.37e-6); kit, fleet, page green.
   **Phone, fourth test: no crash reported; TRAINING RUNS** (world/policy updates = rounds - 2,144 of 2,145; the
   death spiral is gone) and exploring lasts 0.91 s (was 0.08; servo 3.33). "Bad weights refused" showed a garbage
   13470109670760158464, UNCHANGED between screenshots: an uninitialised counter (`Resident.init` sets every field
   by hand - `gpa.create` memory ignores field defaults - and I added two without), fixed; no rejection ever
   happened. "Frames waiting for the GPU" growing is the backpressure working - the phone's GPU is the bottleneck,
   more so in train-only (more rounds offered); the panel now shows a RECENT share ("GPU-bound: N% of recent
   frames"). **The throughput lead:** a round issues ~320 dispatches, EACH its own compute pass plus a
   copyBufferToBuffer of its parameters (per frame: 326 copies, 319 passes) over tiny math (16 rows, 64 wide) - a
   mobile GPU spends its time on pass overhead. Fix to consider: one compute pass per round, each dispatch's
   parameters at a dynamic offset of one uniform buffer (256-byte slots) - ~320 passes -> 1. A compute_host change,
   testable only on a real GPU.
   **The crash, isolated (Sep 25, Simon: "a simpler test - XOR on the GPU while the robot servos").** `geno_track` now
   trains zimrnum_train's XOR network on the GPU IN PARALLEL with Geno's servo and the drawing (on by default; 1-64
   steps a frame = 8-512 dispatches; backpressure; fresh weights every 2,000 steps so convergence keeps being
   proven; converged runs counted). Headless: 300 frames, memory flat. **Its verdict decides the search:** XOR also
   crashes -> the compute infrastructure (bridge, readbacks, queue); XOR runs 10+ minutes -> the learner's own
   load. Suspects then, in order: (1) READBACK volume - `syncMirror` reads the params prefix through the policy
   every round (world + policy weights), a large mapAsync copy a frame; (2) UPLOAD volume - the ring's appends and
   staged windows, ~100 KB a round; (3) dispatch count (~320 passes a round). Each isolable by growing XOR's.
   **Also found - a pre-existing teardown leak, not XOR's:** after 300 frames (not 60) each lifecycle leaks a
   texture + sampler + view, 6 buffers and a bind group (plus XOR's pipe when on) - resources created lazily
   mid-run that deinit does not own. Teardown only; a running page is unaffected. To chase.
   **VERDICT (phone, Sep 25): the GPU infrastructure is SOUND.** XOR trained beside the servo and the drawing for
   minutes - 36,639 steps, 18 runs, up to 53 steps (~420 dispatches) a frame, GPU-bound 45% - no crash. Its "loss
   0, then NaN" is the ALGORITHM's: the kernels' CPU twin (test "XOR on zn_train's CPU twin over long runs")
   diverges on 3 of 8 seeds within 30 steps at zimrnum_train's rate 0.5 (plain gradient descent, linear output);
   at 0.2 all 8 converge, none diverges - the page now trains at 0.2 (and the test holds it there). So the robot
   learner's crash is ITS load or ITS numbers. **The ladder from here, one new ingredient a rung:** (1) PPO on the
   GPU with Geno for 5 minutes (`getup_train` already is GPU PPO, on the old robot - a `geno_ppo` page: Geno's
   model, standing armature, the baked dance, DReCon's Geno lists, backpressure); (2) grow XOR's readback and
   upload volume to the learner's, to test those alone; (3) SuperTrack's ring and windows on top.
   **Sep 25 (Simon: "toes too small; drop XOR; train PPO by default; sensible action scales").**
   - **Toes = a forefoot:** `geno_fit.py` rebuilds each toe box in its FOOT's frame (orientation and width, half its
     height, sole flush, >= 5 cm forward) - 5.0 x 3.5 x 7.2 cm where the fitted sliver was 1.0 cm tall, 2.6 wide.
     The fitter reproduces the old table exactly from its inputs, so the rule is the only change. Balance improves:
     armature alone 1.2 -> 1.55 s; the reflex still 9.98 s. Model fixture and `geno_train`'s clip re-baked.
   - **XOR removed from `geno_track`** (servo-only again); XOR's long-run test stays in `gpu_learn_tests`.
   - **`geno_ppo`: PPO on Geno on the GPU, training by default** - `getup_train` with Geno's model (standing
     armature), the baked dance, DReCon's Geno lists, Geno's servo and floor, resets on the floor. Its GPU load is
     one `learn` per batch (not per frame): ~324 calls a frame against SuperTrack's 2,244. Smoke green.
   - **Action scales, stated:** `robot_ppo_track.Options` now carries `action_scale` (and `rest_on_floor`) into
     BOTH its fleets - it had silently inherited the fleet's 0.2. `geno_ppo` states 0.2 rad a unit: PPO's first
     spread (0.61 units) explores ~7 degrees a decision, DReCon's filter (a fifth new) moves a target ~1.4 degrees
     a decision. (`geno_train`'s SuperTrack still uses 0.6 - the teacher's measured reach - to revisit.)
   **geno_ppo on the phone (Sep 25): learning after the assist fades, then "throttling badly", then a crash.**
   Headless, long runs now possible and HONEST: (1) the clobber scan counted "write, submit, write" to the same
   bytes as a clobber - legal on WebGPU (one queue timeline; `submitDispatch` submits at once) and exactly what the
   PPO trainer's minibatches do; a submission now resets the scan (a repeat with NO submission between is still
   caught). (2) The runner caps a page's call log at 500,000 entries and drops the rest - and the handle balances
   are counted FROM the log: the "long-run teardown leak" recorded twice (geno_track, geno_train, geno_ppo) was
   the cap, the second teardown's destroys never logged. The lifecycle and shutdown checks now SKIP, saying so,
   when the log is capped. Result: geno_ppo at 800 frames passes; at 300 (under the cap, ~9 learning batches) it
   passes with every check judged - lifecycle clean, shutdown balanced, CPU memory flat. **zimr counts nothing
   growing.** What differs from XOR (which survived): 8 Geno characters of physics a frame, not 1. Next isolating
   experiments, each a page switch: learning on the CPU host instead of the GPU; 2 characters instead of 8.
4. **D2 - model-free on the GPU (measured on the phone):** `GpuSacOn`'s samples/s and updates/s on Geno's
   fleet, then CrossQ (batch renormalisation, no target networks) or DroQ (dropout Q-ensembles, many updates
   per sample); PPO as the robust baseline. Equal wall-clock, >= 3 seeds, falls AND reward.
5. **D3 - the world model on pooled data**, judged BEFORE any policy trains through it by its action response
   against the simulator's. **The yardstick is built** (test "D3 - does a world model trained on the teacher's
   data know what actions do?": from states where the teacher acts, its action and one freedom nudged, each
   stepped in the TRUE simulator; the model's predicted change against the simulator's, in the model's feature
   space). **First result - counterintuitive, and the key lesson of D3:** servo + noise data: response off by 0.89
   of its size, cosine 0.43, state error 0.254; the teacher's recordings: off by 0.99, cosine **0.20 - worse** -
   though its state error is better (0.177). The teacher picks its action FROM the state, so in its data the
   action is nearly implied by the state: a model predicts the next state without learning what the action does
   (identifiability). Noise independent of the state is what forces it to. **Next:** record the planner's
   REJECTED candidates too - 16 rollouts x 15 steps a control step, diverse actions around the teacher's, from
   the true simulator, exactly where balance is decided - and judge again; then the mix with servo noise.
   (Cost: ~214 s a run - teacher 68 s, training 106 s at ~66 ms a world step; run detached with `setsid`.)
   **Candidates recorded (`Planner.candidates`) and checkpointed (400 / 800 / 1,600 steps), direction cosine:**
   servo + noise 0.34 / 0.43 / 0.54 (its state error on the teacher's states RISING 0.207 -> 0.294); teacher's
   choices 0.06 / 0.20 / 0.31; teacher's candidates 0.19 / 0.31 / 0.44 (state error best, 0.164-0.173). None has
   plateaued: the BUDGET matters (one CPU core cannot converge these; the GPU resident learner must) - and so
   does the DATA: state-independent noise teaches actions, the teacher's distribution teaches its states. **Next:
   both at once** - DART-style noise injection: on recording steps each candidate step executes its plan's action
   PLUS independent per-step jitter (through `applyAction`, the executed action recorded).
   **D3's DATA RECIPE, FOUND (Sep 24): the teacher's JITTERED candidates** (`Planner.candidate_jitter` 0.5 action
   units). Within one run, same 69 probes, cosine / state error at 400 / 800 / 1,600 steps: servo noise 0.33 /
   0.353, 0.42 / 0.360, 0.51 / 0.377; teacher's choices 0.18 / 0.441, 0.25 / 0.415, 0.38 / 0.378; **jittered
   candidates 0.34 / 0.339, 0.42 / 0.321, 0.52 / 0.311** - action response as good as pure noise at every
   checkpoint AND the best prediction of the teacher's states. (Caveat: the jitter also touches the planner's
   scored rollouts on recording steps, so the teacher's runs - hence the probes - differ run to run.) Absolute
   quality is still low (cosine ~0.5, nothing plateaued): the recipe is settled, the SCALE is the GPU's.
   **Next: D4** - a policy cloned from the teacher (DReCon's observation -> the teacher's action, supervised),
   judged in the real simulator against the servo; then DAgger (the teacher labels the clone's own states).
6. **D4 - SuperTrack distilled from the best actor or teacher, then fine-tuned through the model**; S5's
   ensemble with a disagreement penalty only if it still degrades in reality.
   **Cloning, first result (Sep 25, CPU).** `Learner.cloneStep`: a second small graph over the SAME policy
   parameters and Adam - the policy's output against the teacher's recorded action (the goal as in SuperTrack's
   graph: the reference's next frame). Test "D4 - a policy cloned from the teacher": the planner (limit 0.6 rad)
   recorded 927 steps from 8 starts across the dance (5-15 s), fleet scale 0.2; 3,000 updates took the loss
   0.504 -> 0.030. **Real simulator: servo 98 falls / reward 0.781; the clone 103 / 0.647** - its actions small
   (0.135 units) and jumpy (0.062). Imitation's classic failure: DISTRIBUTION SHIFT - right on the teacher's
   states, lost on its own. **Next: DAgger** - the student drives, the planner labels the states the STUDENT
   reaches (`ServoRun.restore` puts it anywhere; one planning step ~60 ms, nominal = the student's action),
   aggregate, retrain; judged after each round.
   **DAgger, measured:** clone 118 falls / 0.644; rounds 1-3 (1,211 -> 1,811 steps): 126 / 0.619, 126 / 0.613, 124 /
   0.629 (servo 98 / 0.781) - no better, and the student's jitter DOUBLES (0.064 -> 0.123) as labels grow. So the
   LABELS are the fault, not distribution shift alone: predictive sampling keeps the argmax of 16 perturbed plans
   - as a TRAJECTORY it works (re-planned each step), as ONE decision it is mostly noise (0.3 rad on every
   freedom); a student regressing on it learns small averaged actions and the noise as jitter. **Next: MPPI** -
   the candidates' cost-weighted average (weights exp(-cost/lambda)) as the plan and the label: a low-variance
   estimate of what the teacher intends, and likely a smoother controller; judged as teacher (D1's yardstick)
   and as labels (this test).
   **MPPI, measured (`Planner.Options.mppi`, `temperature` x the costs' spread):** as a CONTROLLER at 0.6 rad,
   temperature 0.1: 3.19 s (averaging different good plans blurs them); **0.03: 4.88 s - the best controller
   yet** (predictive sampling 4.67; servo 1.05). As a TEACHER, though: clone 160 falls / 0.459 (loss 0.017 - its
   labels ARE easier to fit), DAgger 177 -> 198 falls, jitter 0.074 -> 0.178 - worse than predictive sampling's
   clone. So label noise is not the root: **the teacher is not a function of the state** - both planners warm-start
   from their last plan (DAgger's labels from the student's action), and plan 15 frames ahead where the student sees
   one goal - a function the student cannot represent; more labels, more conflict.
   **DReCon's ACTION FILTER, everywhere (Simon - who came up with it - Sep 25: "always use the DReCon 0.2 action
   smoothing trick; it is essential").** The planner acts through it (`Planner.Options.filter`: each step a joint
   receives beta of the new offset, keeps the rest; state saved with the moment so every candidate starts alike;
   labels stay RAW - what a DReCon policy outputs; 1 = no filter, bit for bit). At the old raw search it halves
   (2.05 / 2.31 s) - the filter passes a fifth of each change, so candidates barely differ in what the body gets;
   pushed like a DReCon policy learns to push (raw sigma 0.6, reach 1.2), **sharp MPPI + filter 0.2 holds 5.01 s -
   the best controller measured** (unfiltered MPPI 4.88, predictive sampling 4.67, servo 1.05). THE TEACHER.
   **The student, therefore, is DReCon's policy** (robot_policy: its observation carries the LAST ACTION - the
   filter's state - which closes the Markov gap; its action space is the teacher's): (1) the planner also holds
   each action for DReCon's 2 physics steps; (2) record (DReCon observation, raw action) pairs from the teacher;
   (3) clone into PPO's policy network (same architecture and observation normaliser), CPU; (4) PPO fine-tunes
   from the clone - DReCon's recipe, and PPO already runs on the phone. Judged against PPO from scratch and the
   servo. The SuperTrack fleet gains the same filter (an option) before its learners train again.
   **Step 1 done - the teacher on DReCon's clock** (`Planner.Options.decimation`: a decision every N physics steps,
   filtered once and HELD between; re-plans at decisions; the plan shifted a whole interval; `record` stores
   decisions only). Decimation 2 costs it: **3.48 s** (5.01 at every step; servo 1.05). **Its actions, measured**
   (per freedom, at decisions): raw |offset| 0.337 rad on average, largest 1.20; applied 0.241; raw past 0.2 / 0.6
   / 1.0 rad: 56.5% / 20.9% / 4.0%. So a DReCon student with actions in [-1, 1] at geno_ppo's 0.2 rad a unit can
   express only 43.5% of what this teacher does - a clone clipped structurally weaker than its teacher; 0.6 covers
   79%, 1.0 covers 96%. **Decision needed (Simon's call): the student's action scale** - raise it (0.6), or limit
   the teacher's raw reach to what 0.2 can express and measure what that costs.
   **Measured (Simon leaned to raising it):** the teacher CAPPED at 0.6 rad collapses - 1.34 s (raw sigma 0.6), 1.46
   s (0.4), against 3.48 at 1.2: through a 0.2 filter at 30 Hz a strong correction needs a large raw command (the
   joint gets a fifth a decision). **So the student's raw reach is 1.2 rad** - scale 1.2, actions in [-1, 1] - with
   PPO's initial spread lowered (log sigma ~ -1.2) so early exploration stays gentle; the applied offsets stay
   moderate (0.24 rad on average) BECAUSE of the filter.

### D5 - one policy, three teachers (Simon, Sep 25: "bring the planner and SuperTrack's world model into DReCon's PPO
the most clever way; as soon as the world model is good enough, switch to it for the bulk of training")

**D5.0 - Definitions (the contract every step below obeys).**
- *Task:* Geno (standing armature 2, self-collision off, forefoot toes), the dance 5 s -> 15 s (600 frames,
  lifted per frame), servo 20 Hz / cap 3000, floor friction 2.0, resets rested on the floor (`resetToFrame` +
  `restOnFloor`), termination grace = 1 decision window.
- *Policy pi_theta (the ONLY thing that acts):* DReCon's. Observation o_t = `robot_policy.observe` (Geno's watched
  bodies; includes the LAST APPLIED ACTION y_(t-1)). Action a_t in [-1, 1]^30 (the 10 actuated ball joints of
  `drecon_actuated`, 3 each). A DECISION every 2 physics steps (30 Hz): y_t = 0.2 a_t + 0.8 y_(t-1) (Simon's
  filter), held until the next decision. Joint offsets = 1.2 rad x y_t, composed on the right in the child frame
  (`robot_track.applyAction` over the subset's freedoms; all others 0). PPO's Gaussian starts at log sigma -1.2.
- *Teacher T:* `Planner` - sharp MPPI (16 samples x 15 steps, 3 knots, temperature 0.03 x the costs' spread), raw
  sigma 0.6 rad, raw reach 1.2 rad, the SAME filter and clock as pi; cost = shape in the root's frame + 0.3 x the
  root's miss + 10 per step left after a fall. Its label for a decision = its plan's first raw offset / 1.2.
  Yardstick D1 (4 hard starts, 5 s cap): **T = 3.48 s, servo alone 1.05 s.**
- *Datasets:* D_demo = {(o_t, a_t^T)} - T's decisions. D_world = {(s_t, y_(t-1), a_t, s at the next decision)} -
  every real transition from every source (T's jittered candidates - D3's recipe -, PPO's rollouts, the student's).
- *Judge (reality):* `judgeQuality` - falls and mean DReCon reward over 1,200 steps x 8 characters; every number
  in D5 is judged there, never in a model.

**D5.1 - Losses (one network; the gradients add).** g = g_PPO + w_BC grad L_BC + w_WM grad L_WM, where
- L_PPO: PPO's clipped surrogate + value loss on fresh rollouts (as `robot_ppo_track` today);
- L_BC = mean over a minibatch of D_demo of |mu_theta(o) - a^T|^2 (the Gaussian's mean);
- L_WM: SuperTrack's tracking loss through the world model over windows of W = 4 decisions from REAL start
  states, the filter applied in-graph (y_t = 0.2 a_t + 0.8 y_(t-1): a known formula, differentiated exactly),
  plus CAPS smoothness (w_smooth 1, two-sided).

**D5.2 - The weights are measurements, not schedules.**
- w_BC = clamp((R_T - R_pi) / (R_T - R_servo), 0, 1): imitation fades as the student's REAL reward R_pi (judged
  every 50 updates) approaches the teacher's R_T; zero once the student matches the teacher.
- w_WM = clamp(1 - e_val / e_0, 0, 1) x [c_val >= 0.8]: e_val = the world model's multi-step (W decisions)
  prediction error on the most recent HELD-OUT real windows of the CURRENT policy (5% of fresh rollouts, never
  trained on); e_0 = the same error for the trivial predictor s_(t+k) = s_t (so e_val / e_0 is scale-free: 1 =
  useless, 0 = perfect); c_val = the action-response cosine (D3's yardstick) on those windows - a model that
  predicts states but not what actions do gets no say. The weight rises as the model earns trust and FALLS BACK
  BY ITSELF when the policy wanders where the model has not been - the regime where it would be exploited.
- Logged every update: w_BC, w_WM, e_val / e_0, c_val, R_pi - the curves ARE the result.

**D5.3 - Steps, each with its known answer.**
1. *Student scale* - `geno_ppo`: action scale 1.2, log sigma -1.2. Known answer: initial applied exploration
   0.2 x 0.3 x 1.2 = 0.072 rad a decision; smoke green; memory flat over 800 frames.
   **DONE (Sep 25):** `geno_ppo` at 1.2 / -1.2, its comment explaining why 1.2 is not huge; 800-frame smoke green,
   memory flat (94.6 MB). PPO clamps its actions to [-1, 1] before the controller (training and evaluation) -
   verified, so the raw reach is exactly 1.2 rad.
2. *DReCon recorder* - T's decisions stored as (o_t, a_t^T), the teacher's filter state as the observation's last
   action. Known answer: replaying the recorded a^T through `robot_policy.Controller` (filter, hold, expansion) +
   `applyAction` gives the SAME targets as the teacher's own `offsetTarget`, every step (< 1e-5).
   **Contract VERIFIED (Sep 25):** test "D5 step 2" - 60 steps from the dance's frame 360, 30 decisions: the
   teacher's targets and DReCon's controller replaying its labels differ by at most **2.4e-7** (filter formula,
   hold timing, joint order - the subset's freedoms are in MODEL order, mapped by qpos address - and rotation
   convention all agree); largest label 0.35 units (expressible). The teacher lives in one place: `d5_teacher`
   and `student_scale` in robot_geno.zig.
   **Recorder DONE (Sep 25):** `Demo` (rows of observation + label) and `DemoRecorder` (DReCon's subset, the
   model-order -> planner-order joint map, scratch states) - `record` stores every DECISION: the observation
   exactly as PPO's trainer builds it (reference at the frame the coming action aims at - the fleet's frame + 1;
   DReCon's root; the teacher's filter state / 1.2 as the last action) and the label. Test "D5 recorder": 30 rows
   of 111 (9 + 6 bodies x 12 + 30); each row's last-action slot equals what DReCon's `Controller` holds at that
   decision after the recorded labels, to **8e-9** (the first zero); largest label 0.35.
   *Tutorial debt:* the teacher (MPPI through DReCon's filter, on its clock) gets a tutorial section once D5's
   clone shows the pipeline works end to end.
3. *Clone* - L_BC into PPO's policy network (the kit's CPU twin), observation normaliser measured on D_demo.
   Known answer: L_BC falls; judged, the clone's reward beats the servo's (0.781), and is compared to T's.
   **How, precisely:** `GpuPpoOn` keeps the policy's tanh MLP (3 layers), one log-std row and the value MLP in
   the kit's contiguous `params`; its PPO update is already forward -> dL/dmu -> backward -> Adam. The clone is
   the SAME chain with dL/dmu = 2 (mu - a^T) / rows (a small `bc_grad` kernel in zn_mlp), the value and log-std
   untouched - so it trains the very network PPO will fine-tune; nothing is copied between two nets. Pieces:
   (a) `bc_grad` + `GpuPpoOn.cloneMinibatch(observations, labels)` - gradient parity against a zimrnum graph
   of the same MLP (< 1e-5); (b) `robot_ppo_track.Trainer.clone(demo)` - the observation normaliser SET from
   D_demo's mean and spread (PPO keeps updating it); (c) judged with the trainer's own `evaluate` and the
   judge, against the servo and the teacher.
   **(a) DONE (Sep 25) - with no new kernel.** The kit's `mse_bwd` IS the clone's gradient (dy = 2 (y - t) / n -
   so L_BC is the per-ELEMENT mean square error), and `adam` takes any contiguous range, so Adam runs over
   [p_off[0], log_std_off) only. PPO's policy forward and backward were extracted verbatim into `policyForward` /
   `policyBackward`, shared by `trainMinibatch` and the new `cloneMinibatch` - the two updates cannot drift apart.
   Test "D5 step 3a" (gpu_learn_tests, G1's manner): 10 clone steps on the kit's CPU twin vs zimrnum's graph of
   the same 3-layer tanh policy from the kit's own weights - **3.3e-7 apart**, loss 0.405 -> 0.145, the log-std
   and value parameters **bit for bit untouched**. The GPU PPO cartpole test (slow) still passes: the extraction
   changed nothing in PPO's own update.
   **(b)+(c) DONE (Sep 25; the turn that wrote them died waiting on the 162 s test - its code reviewed and kept):**
   `D5Task` (the task, shared by trials), `GpuPpoOn.meanOf`, `Trainer.clone(observations, labels, updates, seed)`
   (every demonstration through the normaliser as if PPO had collected it; minibatches through `cloneMinibatch`),
   and `Trainer.evaluate` now COUNTS failures and exposure exactly as training does - until now it left both zero,
   and the first report printed "0 failures, MTTF 0" from unset fields. **Result** (test "D5 step 3", robot_ppo_track):
   the teacher kept up 1,647 frames over 27 starts -> 810 demonstrations; clone error 0.0251 -> 0.0038 per element
   (labels' mean square ~0.1: ~96% explained); judged, 600 decisions x 8: **servo 96 failures, MTTF 100 steps,
   reward 0.784 | clone 184 failures, MTTF 52, reward 0.373** - it fits its teacher and falls twice as often as
   the servo. **Next, in order of what each rules out:** (i) the teacher's actions replayed OPEN-LOOP in the
   trainer's fleet from the teacher's own start must track the teacher's ServoRun trajectory over the first
   decisions (else the demonstrations do not transfer - a dynamics mismatch, the most damaging possibility);
   (ii) the observation's LOOKAHEAD - the teacher plans 15 frames ahead, DReCon's observation shows one; (iii)
   DAgger in DReCon space (labels at the student's states, the teacher warm-started from the student's filter).
   Step 4 (PPO from the clone vs from scratch) is still the headline - but a clone below the servo is a worse
   start than PPO's own, so (i)-(iii) first.
   *Working rule, relearned:* runs over ~60 s go DETACHED and are polled - a turn must never wait on a test.
   **(i) DONE - the demonstrations TRANSFER** (test "D5 (i)", robot_geno): a fleet character placed in the
   teacher's exact state (data copied, then `rbt.forward` - placing a state is a shove, and the fleet skips
   `forward` while the stage watermark says current: forgetting it gave a false 10 mm jolt at step 1) and the
   teacher's labels replayed open-loop through DReCon's controller: **89 nm apart after one step, under 0.6 um
   through step 45** - `ServoRun.stepToward` and `Fleet.driveOnce` are the same physics (collide, bias,
   `pdTorquesToward`, step); by step 60, 29 mm (contact's sensitivity: a sub-micron difference flips a contact).
   Dynamics mismatch ruled out. **Next: separate (ii) from (iii) by HELD-OUT error** - clone on the demonstrations
   of some starts, measure on starts it never saw: near the training error (0.0038) -> the observation predicts
   the teacher and the failure is distribution shift (DAgger); far above -> the observation lacks what the
   teacher decides from (lookahead).
   **Held-out, MEASURED (Sep 25):** every fifth start held out (5 of 27, 150 rows): clone error **0.0199** held out
   vs **0.0033** trained - and WORSE than always-zero (0.0111) or the training mean (0.0113). The clone MEMORISED
   660 rows; off them it knows nothing - which is why it falls (181 failures vs the servo's 96, reward 0.374 vs
   0.784, unchanged). **Is the teacher learnable at all? Test "D5 (ii)":** at 20 decisions it re-plans 4 times
   from the IDENTICAL state (physics, plan, filter, clock) with different seeds: sampling noise **0.0008** within a
   state vs signal **0.0034** between states - **signal / noise 4.0**. MPPI's randomness is NOT the problem; a
   student with the right inputs and enough data could learn this teacher. Left: (a) DATA/CAPACITY - 660 rows
   against a 111-number input and a 3-layer net is a regime where memorising wins: a LEARNING CURVE (held-out
   error against clone updates, and against demonstrations) says whether more data - D5.5's perturbed starts
   multiply it - fixes it; (b) HIDDEN PLAN MEMORY - (ii) held the plan fixed; the student does not see the plan:
   re-plan from the same physical state with a COLD plan vs the warm one, and compare the difference to the signal.
   **(b) MEASURED - the memory was half of every label** (test "D5 (ii-b)": warm vs cold plan, same seed: 0.0046
   apart per number vs 0.0042 signal between states). **Cure: a MEMORYLESS teacher** (`Planner.Options.markov`:
   each decision plans from the filter's state - what the student sees as its last action - and `iterations`:
   MPPI re-centred within the decision): 1 iteration 1.52 s, **2 iterations 3.65 s - the best teacher yet**
   (carried plan: 3.48). `d5_teacher` is now memoryless x 2.
   **But the clone still does not generalise** (step 3 rerun): judged 148-155 failures (servo 96), reward 0.41;
   held out 0.0185 vs always-zero 0.0084. **Normaliser REFUTED** (0 of 111 inputs spread < 1e-3; held-out rows
   pinned at +-5 less often than training's: 0.16% vs 0.49%). **LEARNING CURVE (held-out error vs cumulative
   updates): 25: 0.0084 (= the constant), 50: 0.0086, 100: 0.0090, 200: 0.0094, 500: 0.0118, 1000: 0.0153, 2000:
   0.0185** - from the first update, fitting the training rows makes unseen ones worse: 660 rows of small feedback
   corrections (RMS ~0.1 units) against a 111-number state yield nothing transferable. **The fork, decided by
   numbers:** (1) 10x the demonstrations - denser starts AND D5.5's perturbed starts (recoveries, not more of the
   same), ~15 min detached - if the held-out curve dips below the constant anywhere, cloning is viable at scale;
   (2) if not, the teacher serves D5 where it measurably works - the world model's data (D3's recipe) and a small
   imitation weight inside PPO (w_BC) - not as the starting policy.
   **D5.5 built, and calibrated (Sep 25):** `robot_track.StartNoise` + `perturbStart` (pose noise on every non-root
   joint through the model's own `integratePos`, a horizontal root kick, rested on the floor again; with no noise
   it draws nothing - fleets without it are bit for bit as before); `Fleet.Options.start_noise` (every reset); the
   recorder takes a noise and a seed. (The fleet already had DReCon's mid-episode shoves: `shove_every`.)
   Calibration, servo alone, 30 starts across the task, lasting 1 s: none 21/30; **pose 0.05 rad + kick 0.25 m/s:
   13/30 - D5.5's level, `d5_start_noise`**; 0.1 + 0.5: 5/30; 0.2 + 1.0: 1/30.
   **The 10x data run - launched detached (log /tmp/d5x10.log, ~15 min):** a start every 5 frames (was 20), each
   recorded clean AND perturbed - 216 recordings, ~6,500 decisions; held out every fifth; the learning curve and
   the judge as before. Its verdict decides the fork above.
4. *PPO from the clone* - against PPO from scratch, equal wall-clock, 3 seeds. Known answer: the clone-started run
   passes the servo's reward sooner (the minutes it saves are the headline number).
5. *World model in DReCon space* - trained on D_world; validated as in D5.2. Known answer: on held-out teacher AND
   student windows, e_val / e_0 < 0.5 and c_val >= 0.8.
6. *Blend* - D5.1 and D5.2 in one trainer. Known answer: reward against wall-clock beats PPO alone and PPO from the
   clone; the w_WM trace shows the switch happening, and falling back when the model degrades.
7. *The kit* - each new term on the GPU (BC's gradient; the filter in L_WM's graph), each with CPU parity < 1e-5;
   then the phone.

**D5.5 - Robustness: perturbed starts, as DReCon trained (Simon, Sep 25).** DReCon randomised its initial states
and hit the character during training (pushes, thrown projectiles). Here perturbation serves BOTH halves of D5:
- *PPO's episodes* start from PERTURBED reference states - the clip's frame (reference state initialisation, as
  now) plus pose noise on the actuated joints (sigma_q rad) and a root velocity kick (sigma_v m/s, random
  horizontal direction) - widening the states it trains from; later, pushes mid-episode (DReCon's projectiles).
- *The teacher* dances from the same perturbed starts, so its demonstrations include RECOVERIES - the direct cure
  for the clone's distribution shift, cheaper than DAgger (no student in the loop).
- *Calibration:* sigma_q, sigma_v set by what the SERVO alone survives half the time from a perturbed start (so
  perturbations are hard but recoverable), measured per hard frame. *Known answers:* the teacher recovers from
  perturbed starts (survival vs unperturbed); the clone with recovery demonstrations beats the servo judged
  from perturbed starts; PPO trained with perturbed starts has a higher MTTF under a STANDARD push test (a fixed
  impulse at a fixed moment of the clip) than without.
- *Where:* `Fleet.Options.start_noise` (pose, velocity) in robot_track - shared by PPO, the judge and the recorder.

**D5.4 - Where it lives.** Teacher, recorder, trials: `src/robot_geno.zig`. BC and the blended trainer:
`src/robot_ppo_track.zig` (+ `robot_gym.zig`'s GPU PPO for the kit). The DReCon-space world model:
`src/robot_latent.zig` (+ its kit). Pages: `geno_ppo` first.

### ST - SuperTrack AS PUBLISHED: reread, and brought back (Simon, Sep 26)

Simon: "Revise SuperTrack - maybe go back to it, but carefully, so the policy does not exploit defects; maybe
it just needs more training, with bigger perturbations." The paper (Fussell, Bergamin, Holden, SIGGRAPH Asia
2021) reread end to end; this section is its faithful summary, the gap to ours, and the way back.

**ST.0 - The method, precisely.**
- *Gym:* 256 characters in parallel, PD motors at every joint; reference state initialisation (a random frame
  of a random clip, vertical correction against ground penetration); an episode ends at 512 frames, or after
  48 once the HEAD's height strays 25 cm from the reference's; ~5,000 samples/s into a cyclic buffer of
  ~150,000 samples holding the simulated state S, the kinematic state K and the PD targets T actually used.
  Physics at 240 Hz (4 substeps a 60 Hz frame), 20 solver iterations.
- *State:* world positions, velocities, rotations (quaternions), angular velocities of every rigid body - for
  S and K alike. *Network inputs* `Local(X)`: all of it in the root's frame, rotations as two-axis (6 numbers),
  plus every body's HEIGHT above the ground and the UP vector in the root's frame (gravity, and contact, made
  visible); normalised by mean and spread computed OFFLINE from the kinematic data.
- *PD targets:* offsets o (3 per joint, exponential map), t = exp(alpha/2 o) (x) k_t, target velocity = the
  kinematic joint velocity (zero on simulators without it). alpha = 120 (degrees).
- *World model W:* input [Local(P_i), T_i] -> the bodies' linear and angular ACCELERATIONS in the root's frame
  -> rotated to world -> INTEGRATED (velocity, then position; rotation by exp(dt/2 w)). Trained over a WINDOW
  of 8 frames from a real start (teacher forcing every 8), L1 losses on world positions, velocities, rotation
  difference (log of q_s q_p^-1) and angular velocities, weights set so each contributes equally at the start.
  5 hidden layers x 1024, ELU, batch 2048, lr 1e-3, RAdam. Ablation: accelerations beat velocities.
- *Policy Pi:* o_i = Pi([Local(P_i), Local(K_(i+1))]); o + 0.1 N(0,1) noise in training; T_i from it; rolled
  through W for a WINDOW of 32 frames from a real start; L1 losses IN LOCAL SPACE on positions, velocities,
  rotations, angular velocities, heights and up; plus L2 AND L1 penalties on o (two orders of magnitude
  smaller). 5 x 1024, ELU, batch 1024, lr 1e-4. Ablations: window 16 plateaus far lower than 32; 64 unstable.
- *Loop:* each iteration - new gym data into the buffer; the current policy to the gym; ONE world-model step;
  ONE policy step. Basic balance after ~10,000 iterations (~2 h on a GTX 1070); full quality 100-200k (20-40 h).
- *Their robustness test:* cubes thrown once a second at 5 m/s, of growing mass. *Their limits:* the look-ahead
  is the policy window (0.53 s); recovery STEPS are hard to discover (no exploration beyond the gradient);
  foot sliding where the short horizon cannot plan.

**ST.1 - Why their policy does not exploit their model** (Simon's reading, and what else the paper does):
1. *Narrow scope* - W learns only the deterministic physics of the character, nothing of the reference.
2. *Bounded horizons* - 8 frames for W, 32 for Pi: errors cannot compound past a window.
3. *Invariant representation* - root-frame everything, heights and up: stable, accurate predictions.
4. *Interactive data in a large buffer* - 150k fresh samples from the CURRENT policy's neighbourhood, W and Pi
   trained in tandem: the model is accurate exactly where the policy goes.
5. *(also)* Exploration noise INSIDE the policy's training rollouts - the policy must succeed under
   perturbed actions, so it cannot rely on knife-edge model defects.
6. *(also)* Offset penalties (L2 + L1) - large offsets, where a model is least trained, cost something.
7. *(also)* SCALE - a world model trained ~10^4-10^5 steps at batch 2048 on fresh data before quality appears.

**ST.2 - Ours against it** (the geno_train page and the CPU learner, Sep 26):

| | paper | ours | verdict |
|---|---|---|---|
| characters / data rate | 256 / ~5,000 s^-1 | 4 / ~240 s^-1 (phone) | gap - CPU physics bound |
| buffer | ~150,000 | 4 x 256 = 1,024 | GAP, cheap to close |
| world model | accelerations, integrated | latent residual z' = z + Net(z, ref, a) (D15: "accelerations fall apart") | deviation - D15 measured at OUR scale: re-test |
| networks | 5 x 1024 ELU, both | 64-256 hidden, 2-3 layers, tanh | gap - phone-bounded |
| batch W / Pi | 2048 / 1024 | 16-32 | GAP |
| windows W / Pi | 8 / 32 | 8 / 8 (page), 16 (default) | GAP: Pi window 32 |
| losses | L1, balanced | MSE on normalised features | gap |
| offset penalty | L2 + L1 | L2 (w_action) + CAPS smoothness | close |
| exploration noise | 0.1 x 120 deg = 0.21 rad/axis | 0.1 x 0.6 = 0.06 rad | gap |
| inputs | Local(X) incl. heights + up | the same (`track.local`) | SAME |
| normaliser | offline, kinematic data | from the fleet's replay | gap |
| PD target velocity | kinematic joint velocity | zero (feedforward option, off) | gap |
| termination | head height 25 cm, min 48, max 512 | pose/root thresholds + grace | differs |
| physics | 240 Hz, 20 iterations | 60 Hz, Newton | differs |
| updates run | 10^4 to balance, 10^5 full | 400-1,600 | GAP: 1-3 orders |

So "SuperTrack gets exploited" (Phase S) is really "UNDER-TRAINED SuperTrack gets exploited" - every run we
judged was 3-5 orders of magnitude of optimisation short of where the paper first sees balance.

**ST.3 - The way back, in order** (CPU first, each with its known answer; then the phone):
1. *Parity, cheap:* policy window 32; buffer >= 30 s of data (the paper's 150k at 5,000/s is 30 s): 4 chars x
   2,048 (or more) - measured memory; batch 256+; L1 losses with the paper's balancing; the offline normaliser
   from the clip; noise 0.1 in the paper's units; PD target velocities (feedforward) on. Known answer: each
   change alone does not break the cartpole/Geno parity tests; the D3 yardstick does not get worse.
2. *The world model's form, re-decided at scale:* the paper's acceleration + integration model beside our
   latent one, equal compute, on D3's yardstick (action response, multi-step error vs the trivial predictor,
   on held-out windows of teacher AND policy data). Keep the winner; D15 was measured small and short.
3. *Anti-exploitation, beyond the paper* - all measured, all logged:
   (a) the EXPLOITATION INDEX, always on: the in-model improvement of the tracking loss vs the REAL improvement
       (judgeQuality) - the gap is the exploit, a number every run reports;
   (b) D5.2's trust signal: W's multi-step error on the policy's freshest HELD-OUT windows over the trivial
       predictor's, and the action-response cosine - the policy's learning rate through W scales with it;
   (c) Simon's DReCon filter IN the graph (y = 0.2 a + 0.8 y_prev) - the jitter exploit we measured (actions
       jumping 70% of their size a frame) becomes impossible by construction;
   (d) BIGGER PERTURBATIONS - D5.5's perturbed starts and the fleet's shoves (`shove_every`, their cubes' 5 m/s
       analogue) spread the buffer over the states a policy may reach, so W is accurate there;
   (e) ensembles (S5) only if (a) still shows a gap after (b)-(d).
4. *Scale on the phone:* measured throughput first (updates/s for W and Pi at 3 x 256 and 4 x 512, batch 256-
   1024); then runs of 10^4+ updates (the paper's first-balance point), with the exploitation index and the
   trust signal on the page. Characters stay CPU-bound (4-8): the buffer's DEPTH and the perturbations carry
   the coverage the paper got from 256 characters.
5. *Into D5:* SuperTrack's gradient is D5's L_WM term; PPO stays the reality anchor; the teacher's jittered
   candidates (D3's recipe) join the buffer.

**The clone line (D5 steps 3-4) pauses** at its fork: the 10x-data rerun (2 x the starts, clean + perturbed)
is queued behind ST.3.1 - and must be polled to completion WITHIN one turn (a detached run does not survive
the turn that started it: Sep 26, its log was empty).

### ON - the first overnight run on a desktop GPU: the full dance AND the get-up, first try (Simon, Sep 26)

**ON.0 - Success, stated so it can fail.** After one night (<= 10 h) on a desktop GPU, in the browser, ONE Geno
policy tracks both clips from random starts (the paper's SURVIVAL RATE - the share of episodes lasting longer
than t): the FULL dance, >= 80% of episodes past 10 s; the get-up, >= 50% of its episodes reach standing (head
within 25 cm of the reference's through the rise). Tracking reward above the servo's on both. Visible in the
morning: Geno lying on the floor, getting up, dancing.

**ON.0b - ONE task for every clip (Simon, Sep 26).** The two clips are stand-ins: the real set will be ~100
animations with get-ups somewhere in some of them, and nobody knows which. So EVERY failure criterion, reward,
cost, termination and schedule is clip-agnostic - no switch may ask which motion it is. Consequences:
- *One failure criterion everywhere* - training, judging, the teacher's fall penalty, every survival test:
  `robot_track.terminated` with Geno's `task_termination` (tracking error, and the bodies' height RELATIVE to
  the reference's - lying is no failure while the reference lies). Not the hips-35-cm rule of `ServoRun`.
- *One teacher cost* - gravity measured on the body's AXIS (hips, spine, neck, head: what leads a rise, and
  what a dance's swinging limbs leave alone), never per motion.
- *Start sampling that finds the hard parts itself* - not "50/50 between dance and get-up" but ADAPTIVE:
  start frames drawn in proportion to how often episodes recently failed near them (per frame bins, with a
  floor so nothing starves) - a get-up hidden in clip 73 gets its share because it fails, not because it is
  named.

**ON.1 - The recipe (decided by evidence, each choice with its reason).**
- *Learner:* SuperTrack as published (ST.0) - off-policy and sample-efficient where our data rate is CPU-bound;
  the paper's own evidence: its 6-min dance set to 95% past 1 min, LaFAN (get-ups included) trained whole.
  Acting through DReCon's filter (Simon's), the filter's state in the policy's input and in the graph.
- *Anti-exploitation, measured every minute (ST.3.3):* the exploitation index (in-model vs real improvement),
  the trust signal (W's held-out multi-step error over the trivial predictor's, and action response) scaling
  the policy's learning rate; W trained MORE when trust drops (a second world step per policy step).
- *Scale, chosen BY THE MACHINE at start-up:* a 60 s probe times the iteration at candidate widths and depths
  and keeps the largest that runs >= 5 iterations/s - so a night is >= 150k iterations, the paper's full count,
  whatever the GPU. Windows 8 / 32; batches as large as the probe allows; buffer >= 64k samples.
- *Data:* every clip, starts drawn ADAPTIVELY (ON.0b) - hard stretches, wherever they hide, get more starts; the paper's termination (head 25 cm off the reference's, after 48 frames; 512 at most);
  perturbations RAMPED - none for the first hour (nominal tracking first), then D5.5's start noise on half
  the resets and shoves (a random kick every few seconds) spreading the buffer where a policy may stray.
- *Unattended:* a checkpoint every 10 min (weights, Adam, normaliser, iteration) with resume on reload; on a
  non-finite loss or weight, restore the last checkpoint, halve the learning rates, carry on (logged); curves
  logged every minute (survival and reward per clip, W's loss and trust, the exploitation index, iterations/s,
  samples/s) - on the page and as a downloadable CSV; a toggle to WATCH the current policy.

**ON.2 - De-risk, in order: each step can stop the night, so the cheapest decisive ones come first (CPU).**
1. *Feasibility* - both clips baked for Geno (lifted per frame); the servo alone and the D5 teacher (the
   true-simulator planner) on each. **If the planner cannot get Geno up, no learner will** - the physics (servo
   authority, contacts, 60 Hz) is then the work, before anything else. Known answer: the planner's survival on
   the get-up's rise, against the servo's.
   **MEASURED (Sep 26, test "ON.2.1", 369 s; `GenoTask` + `Motion` now bake the whole dance and the whole
   get-up):** *Dance* (1,800 frames, 30 s): from 6 starts, the teacher holds 4 of 6 four-second windows whole
   (others 210, 166 frames); the servo 62-120 frames from most - FEASIBLE. *Get-up* (1,080 frames; lying at
   frame 494, head 0.09 m; standing 1.54 m): from mid-rise the teacher lifts the head to ~1.25 m (starts 599,
   689) - but FROM THE FLOOR IT NEVER RISES: from 509 and 554 it "survives" 240 frames with the head at 0.46-
   0.55 m while the reference's climbs to 1.0-1.4 m. So: (i) **the floor-to-crouch lift is the night's top
   risk** - next, split SEARCH (a 0.25 s horizon too short to find the push-up) from PHYSICS (armature 2 makes
   joints sluggish; the acceleration cap; the hands' contacts): the teacher from 509/554 with a longer
   horizon and more samples vs with more servo authority; (ii) **the hips-35-cm failure test is blind to it**
   - the paper's head-height rule (25 cm) is the get-up's criterion, confirmed by these runs.
   **SOLVED - it was the COST, not the physics (Sep 26, tests ON.2.1b-d, from floor starts 509/530/554):**
   more search (0.5 s horizon, 32 samples), agility (armature 0.5), authority (cap 6000) and EVERY joint in the
   plan (23 joints, elbows included) all left the head at 0.3-0.75 m. The teacher's cost measured the shape
   from the root's own position AND rotation - height and tilt against gravity dropped out; lying with the
   right joint angles cost what kneeling with them costs, and the only vertical signal was the fall rule's
   cliff. `Planner.Options.height_weight` / `up_weight` (SuperTrack's L_hei and L_up: every body's height, and
   the up vector in the root's frame): **the head climbs to 0.69 / 1.12 / 1.26 m** (references 0.99 / 1.24 /
   1.43) with DReCon's joints and today's physics; every joint + armature 0.5 runs closest (0.21 m below the
   reference's head on average vs 0.32). **The get-up is feasible.** `d5_teacher` carries gravity (1.0, 0.3).
   *Lessons for the night:* (1) every cost and reward must see gravity - SuperTrack's loss does (our features
   carry heights and up); PPO's DReCon reward and every termination rule must be checked for this blind spot;
   (2) acting on every joint helps the get-up (SuperTrack's policy acts on all joints, as the paper's does);
   (3) re-measure D1's dance yardstick with gravity in the cost (expected neutral: standing keeps it up).
   **The gravity AUDIT (Sep 26):** *the task's reward was 80% blind* - its pose terms are root-relative; only the
   root's position and rotation (0.1 + 0.1) see the world: a body lying with the right joint angles scored
   **0.801** while its reference stood. Now `robot_track.TrackingError` carries `height` (bodies' mean height
   difference, world) and `up` (the up vectors apart, each in its root's frame); `RewardWeights.height_scale` /
   `up_scale` GATE the whole reward - multiplied by exp(-height/scale) exp(-up/scale), as SuperTrack's one
   exponential of every loss sinks all of it (known answer, test "the gravity gate": 0.801 ungated -> 0.00002
   gated, perfect still 1.000); `Termination.height` - the bodies' mean height off the REFERENCE's (relative:
   lying is fine while the reference lies). Defaults off (the old robot's numbers unchanged). Geno states its own:
   `robot_geno.task_weights` (height 0.2 m, up 0.5) and `task_termination` (height 0.2 m); `robot_ppo_track.
   Options.weights` / `termination` reach BOTH its fleets; `geno_ppo` and `geno_train` use them (smoke green; the
   watching leash loosens the height limit too). NOTE: Geno's judged rewards from here are GATED - not comparable
   with earlier numbers. *And (3) was not neutral:* gravity at full weight HALVED the dance (D1: 3.65 -> 1.87 s) -
   the dance's small, everywhere height errors double-counted what the shape asks. **A hinge** (`height_tolerance`
   0.1 m, `up_tolerance` 0.2 - counted only beyond): **3.27 s**. `d5_teacher` carries the hinged gravity.
   **The teacher's gravity, settled (Sep 26, tests ON.2.1e-f):** hinged (10 cm / 11 deg) the rise is lost (head
   0.70-0.91 m); gravity on the ROOT's height and tilt only (the principled guess: exactly what the shape drops)
   also fails (0.34-0.99 m; dance 2.49 s) - the rise is led by the TORSO AND HEAD, pushed up by the arms while the
   hips stay low, so it takes every body's height; which a greedy 0.25 s planner then chases in the dance at its
   balance's expense. So `teacherFor(motion)`: the dance's teacher without gravity (3.65 s), the get-up's with
   every body's height (1.0) and up (0.3) (1.12-1.26 m). *The night's lesson:* SuperTrack's height term (L_hei)
   is what the get-up will hang on - its weight is checked in the CPU mini-night (ON.2.5) with both motions.
   *Tooling:* a `-Dtest-filter` that matches nothing compiles NO test bodies - such a "compile check" missed a
   field; filter on the test's own name (claude.md).
   **Superseded the same day - ONE teacher cost for every clip (Simon: ~100 clips, get-ups hidden; ON.0b).**
   `teacherFor(motion)` is gone. Gravity on the body's AXIS only (`Planner.Options.height_bodies = axis_bodies`:
   hips, spine, neck, head - what leads a rise; the limbs' heights double-counted the shape): get-up 0.98 / 1.23 /
   0.91 m (mean shortfall 0.26 m) but the dance 2.18 s - ANY height term taxes a dance's balance dips. So
   POSTURE-GATED (`posture_gate`): gravity weighted by how low the REFERENCE's head is against the robot's
   standing head height (the bind pose's, above its lowest point) - none at >= 90%, all at <= 50%, linear
   between; a property of each frame's pose, never of a clip. **Dance 3.43 s (94% of no-gravity's 3.65); get-up
   0.75 / 0.91 / 1.19 m, mean shortfall 0.24 m** - the only cost that keeps both. `d5_teacher` carries it (the
   full table is its comment). **Next: ONE failure criterion** - the teacher's fall penalty and every survival
   loop on `robot_track.terminated(task_termination)`, not the hips-35-cm rule; then adaptive start sampling.
   **ONE FAILURE CRITERION - done (Sep 26; a stalled turn wrote it, this one reviewed and finished it).**
   `robot_geno.FailureCheck`: the clean reference posed at the frame, both states built as the task builds
   them, `robot_track.trackingError` + `terminated` with Geno's `task_termination` - the very functions training
   and judging use; `ServoRun` embeds it (`lost`), every survival loop, the recorder, the tests and the
   `geno_track` page use it; the hips-35-cm rule is deleted. `within(fraction)` is the same rule with its limits
   scaled - an early warning, never a rule of its own. Fast suites green (robot_geno 458/502, robot_track
   438/457, the rest slow), geno_track smoke green.
   **What the rule must be, measured:** (1) height relative to the reference: 0.2 m cut a dancer's balance dips
   (the servo's "failures" at 0.17-0.19 m with the pose near perfect) - **0.4 m**. (2) With the root's WORLD
   limits (0.6 m, 1.5 rad) the teacher's dance collapsed to 1.0-1.6 s: at every "loss" its hips were 0.44-0.58 m
   across the floor and its heading 5-144 deg off while its pose was 55-120 mm off - WANDERED, not fallen. On flat
   ground SuperTrack terminates on head height only (root limits for rough terrain only). So Geno's rule is
   **"fallen, or lost the pose"**: pose limits, height relative (0.4 m), and TILT against gravity (`Termination.
   up`, new: 0.8 ~ 47 deg) - no root position, no heading; the reward keeps its root terms (encouraged, not
   fatal). Under it the teacher's runs end by tilt, at 1.4-4.6 s (D1 mean 1.98 s), drifting 1.4-5.2 m.
   (3) **The teacher's early warning is its own business:** as a fall PENALTY, "hips within 35 cm" was an
   excellent signal for a greedy planner - one number punishing drift, sinking and toppling - and the task's
   clip-agnostic rule (even with a 0.6 margin) warns too late: dance 3.43 -> 1.98 s, floor lift 0.75/0.91/1.19
   -> 0.77/1.03/0.63 m. Two roles, cleanly separated: the TASK says what failure is (one rule, every clip); the
   TEACHER's cost may shape toward the reference's path (also clip-agnostic, just not a failure rule).
   **Next:** the teacher's `across` weight (drift across the floor, 0.3) raised - measured on both motions -
   to recover what the hips rule gave it; then adaptive start sampling.
2. *SuperTrack parity* (ST.3.1) - window 32, buffer, batches, L1, the clip's normaliser, noise units, target
   velocities. Each change keeps the parity tests green and the D3 yardstick no worse.
3. *The world model's form* (ST.3.2) - accelerations integrated vs our latent residual, at moderate scale.
4. *The filter in the graph; the exploitation index; the trust signal* - with CPU-twin parity for each.
5. *A CPU "mini-night"* - the exact recipe, scaled down, 20-30 min on the CPU twin: survival rising above the
   servo's, the exploitation index bounded. The last check before GPU time is spent.
6. *The desktop page* - the probe, checkpoints and self-healing, curves; smoke and 800-frame runs headless.
7. *A 30-minute rehearsal on the desktop* (Simon) - curves sane - then the night.

### MK2 - MimicKit studied again (Sep 26): every difference, judged; what it changes

MimicKit (Peng et al.: DeepMimic, AMP, ASE, AWR, LCP, ADD, SMP; Isaac Gym / Isaac Lab / Newton) reread for
tracking: `envs/deepmimic_env.py` (reward, done), `envs/char_env.py` (observation, action bounds),
`learning/ppo_agent.py` + `rl_util.py` (returns), `learning/lcp_agent.py`, `learning/add_agent.py`, the
humanoid configs. Verdicts: SAME, JUSTIFIED (we differ on purpose, with a reason), or GAP (to close).

**MK2.0 - CORRECTION (Sep 26, Simon: "the reward should still consider global yaw and displacement - or it can
never learn to turn on the spot and go somewhere reliably. Are we sure MimicKit does not reward it?").** It DOES.
Its DeepMimic humanoid runs `track_root` (`enable_tar_obs` and `global_obs`): the reward's root term is the GLOBAL
position (x, y - the accumulated displacement - and height) and rotation (yaw included), key bodies in world
orientation, root velocities global; the observation places the future targets RELATIVE TO THE CHARACTER
(`root_pos_obs = tar_root_pos - root_pos`), so drift and heading error are SEEN; the termination fails once the
root is 1 m from the reference's. MK2.1 below wrongly said they ignore drift - that is SuperTrack's FLAT-ground
rule (its rough-terrain rule adds 1 m / 90 deg). Ours: the reward already had the global root position and yaw
(20%) and global velocities - but the OBSERVATION could not see drift (every difference in each character's own
frame), so no policy could have learned to correct it, and the termination had just lost its drift limit. Fixed:
`robot_policy.observe` adds where the reference IS from the character (its centre of mass in the character's
heading frame, 3) and its heading against the character's (cos, sin, 2), and the lookahead centres of mass are
now from the CHARACTER, not the reference; `task_termination` holds the root again - 1 m, 90 degrees (relative,
so lying is fine while the reference lies). Known answers: still invariant when both move (1.4e-6); the reference
moved ALONE 0.5 m is seen 0.500000 m, turned alone 0.3 rad is seen 0.300000 rad. Geno's observation: 180. The
teacher's recorder window drops 61 -> 55 frames (its drift now ends it) - its `across` weight is next.

**MK2.R - Adversarial review of the recent code (Sep 26, Simon's ask).** Found and fixed:
1. *geno_train's watching leash copied the limits field by field and dropped `up`* (tilt off while watching).
   Root cause: hand-written copies forget limits added later. `Termination.scaled(fraction)` is now the ONE copy
   (FailureCheck's early warning, geno_train's and track_train's leashes).
2. *FailureCheck posed only the reference's positions* (`kinematics`, no velocities): its error differed from the
   fleet's in the velocity terms - "one criterion through one function" was quietly false. Now posed exactly as
   `Fleet.referenceStateInto` does (velocities by differencing, full `forward`). Known answer (fast test): its
   error and the fleet's, every one of the eight fields, 0.00e0 apart.
3. *An off-by-one in "frames kept"* (`ServoRun.survive`, `Planner.record`, `DemoRecorder.record`): a loss at f
   returned the frames stepped, reaching the end returned one more. Fixed; the recorder test asserts rows ==
   ceil(kept / 2) exactly.
Checked and sound: the lookahead past a clip's end (clamped by `referenceStateInto`); the terminal capture's
frame (the fleet advances then measures - the terminal observation is what the next decision would have seen);
the rollout's penalty (charged once, then stops); the posture gate's probe (posed before it is read); geno_track
(steps then forwards before its check); Views' errdefers; the decision that ends at its first held step (the
second end is not re-recorded, its bootstrap valued before the restart overwrote anything).
Open (design, next): **Geno's task is spelled out at every call site** (gains, floor, lists, scale, rest, weights,
termination) - the D5 step 3 trainer is judged WITHOUT the gravity gate, the e2e trainer with the old limits.
One `GenoTask.fleetOptions` / `ppoOptions` so no call site can drift. Also noted, older: the candidate-recording
path indexes the clip with the model's nq (right only while clip.nq == m.nq); a decision ending at its first held
step earns half its reward (the mean over 2 steps with 1 credited).

**MK2.1 - Episode ends: the biggest finding.**
- *Three kinds of done:* TIME (episode cap, 10 s), SUCC (a non-looping clip ended), FAIL. Returns are TD(lambda)
  that BOOTSTRAP AT TIME from the critic's value of the TERMINAL observation (the state before the reset; they
  store `next_obs` for it), and use fixed values at SUCC and FAIL (both 0 - SUCC's reward is 0 "to avoid the
  local minimum of standing still until the motion ends"). **Ours: GAP - a BIAS in our PPO.** `computeAdvantages`
  sets `alive = 0` at ANY end - the step cap and the clip's last frame are treated as deaths - and the fleet
  restarts inside `step()`, so the value at t+1 is the NEW episode's first state. With ~100 clips started at
  random frames, clip ends will be frequent: the critic learns that every clip's last seconds are worth
  nothing. Fix: the fleet records WHY an episode ended (cap / clip end / lost) and the terminal observation
  before restarting; GAE bootstraps at the cap from V(terminal), treats `lost` as terminal, and the clip end
  as an OPTION measured both ways (MimicKit's 0 vs bootstrap). Known answer: a chain environment whose true
  value is known in closed form - the capped-and-bootstrapped estimate matches it, the old one is biased.
- *Failure:* (a) CONTACT: any body not in `contact_bodies` touching the ground (force > 0.1) - but the list is
  PER MOTION in their configs (feet; hands+feet "cartwheel"; none "roll and crawl") - ruled out for us (ON.0b).
  The clip-agnostic version is better anyway: an UNEXPECTED contact - a body on the ground while its REFERENCE
  counterpart is well above it - which is right for a get-up (the reference's hands and knees ARE down) and
  catches a fall before the height does. GAP: measure it (servo, teacher, both clips) as a termination term.
  (b) POSE: the WORST body's distance (world, root included when tracking the global root) beyond 1.0 m. Ours
  limits the MEAN (root frame) - one limb far off (an arm pinned under the body) passes. GAP: add a worst-body
  limit beside the mean. (c) never on the first step - ours: grace (a window) - SAME in spirit.
- *Our "fallen or lost the pose" rule (Sep 26)* matches their spirit: no heading, no drift on flat ground.

**MK2.2 - Reward.** Theirs: 0.5 pose (JOINT rotation angles, per-joint weights - proximal joints count most)
+ 0.1 joint velocities + 0.15 root (position incl. height, rotation incl. tilt and heading) + 0.1 root
velocities + 0.15 KEY bodies (head, hands, feet) root-relative in WORLD orientation; Gaussian kernels exp(-k
err^2). Gravity-aware by construction (world orientation + root height). Ours: body positions/rotations in the
root frame + root terms, Laplace kernels exp(-err/s), and the gravity GATE - JUSTIFIED (the gate does their job,
multiplicatively). GAP, small: per-body weights (proximal first) and the key bodies' world-orientation term are
worth one A/B once the night's baseline exists.

**MK2.3 - Observation.** Heading frame (yaw removed, tilt kept) - SAME as ours (`robot_policy.observe`, at the
centre of mass, face-down case handled). Theirs adds: the ROOT HEIGHT above the ground (ours has none - a get-up
is about the floor), every joint's rotation (6D) and velocity (ours: DReCon's few watched bodies), KEY body
positions, and the reference at 1, 2 AND 3 steps ahead (ours: 1) - the lookahead the clone lacked (D5). GAP,
cheap, high value: root height + lookahead (and consider every body, as SuperTrack's Local(X) already has).

**MK2.4 - Action.** Absolute PD targets inside bounds from the joint limits (1.2 x a ball joint's), control 30 Hz,
simulation 120 Hz. Ours: offsets from the reference through Simon's filter at 30 Hz, simulation 60 Hz - offsets
JUSTIFIED (SuperTrack's ablation; DReCon). Their action spread is FIXED and small (0.05) with an ACTION-BOUND
LOSS (weight 10) keeping the mean inside the bounds; ours: a learned log-std and a CLAMP to [-1, 1] - a clamped
sample keeps its unclamped log-probability, so PPO's ratio lies about clamped actions. GAP: a bound loss on the
mean (and measure a fixed spread). 60 vs 120 Hz: measured later (get-ups are contact-rich).

**MK2.5 - PPO.** 2 x 1024 actor and critic, SGD 1e-4, 5 actor / 2 critic epochs, gamma 0.99, lambda 0.95, clip
0.2, normalised advantages CLIPPED at +-4, entropy 0, 4096 envs x 32 steps, observation normaliser FROZEN after
1e8 samples. GAPs: advantage clip (cheap); freeze the normaliser (a moving input scale late in training moves
every weight); desktop-scale networks for the night. Ours already has: KL for diagonal Gaussians, explained
variance, clip fraction (`PpoStats`: "how you know it is working") - put them ON THE PAGES.

**MK2.6 - Newer methods that bear on our problems.**
- *LCP (Lipschitz-constrained policies):* + 0.002 x E[ |grad_obs log pi(a|obs)|^2 ] - a policy smooth BY
  CONSTRUCTION, complementing Simon's filter, aimed at exactly the jitter SuperTrack's policy exploited. Ours can
  do it without double backprop: a finite-difference penalty |mu(o + e) - mu(o)|^2 / |e|^2 on random small e,
  for PPO and SuperTrack alike. GAP: build and measure (jitter, and exploitation index).
- *ADD (adversarial differential discriminator):* the reward LEARNED from the DIFFERENCE between reference and
  simulation (per-feature `DiffNormalizer`), its "real" samples the ZERO difference (perfect tracking); hand
  reward weight 0. Clip-agnostic by construction - which differences matter is learned from the data, for
  whatever motions are there: the principled end state for our hand-tuned weights and gate on 100 clips.
  Needs: a discriminator (an MLP - the kit has them), gradient penalty (2) and logit regularisation. GAP -
  PHASE 2 of the night: first night on the hand reward (a baseline), ADD against it after.
- AMP / ASE / SMP: style priors for task control - later (Phase M).

**MK2.7 - Our recent turns, reviewed.** Right: the gravity audit (the reward scored lying 0.80), one failure
criterion through one function, "fallen or lost the pose", clip-agnostic everything (Simon's rule - MimicKit
itself breaks it with per-motion contact lists). Over-invested: the TEACHER's cost (eight gravity variants) - the
night's learner is SuperTrack/PPO, whose losses already carry heights; the teacher's early warning (`across`) is
TIMEBOXED to one measured change. Process: two turns stalled - shorter turns, record before growing.

**MK2.8 - The RL toolkit, reviewed.** zimrnum + robot_gym hold PPO (CPU, and GPU on the kit), SAC (CPU and GPU),
REDQ/CrossQ critic aggregation, DQN targets, OU noise, SAC temperature, an observation normaliser (clip 10),
KL / explained variance / clip fraction; robot_latent (SuperTrack, CPU + kit); robot_policy (DReCon). Used for
Geno: GPU PPO and SuperTrack. Unused: GPU SAC / CrossQ (D2's throughput question - still open, off-policy fits a
CPU-bound data rate), the diagnostics (not on any page). Suboptimal: the truncation bias, no advantage clip, the
clamp without a bound loss, a never-frozen normaliser.

**MK2.9 - Changes to the plan, in order (each CPU-first, each with its known answer):**
1. PPO's episode ends done right (MK2.1) - the chain-environment known answer; then geno_ppo re-smoked.
   **DONE (Sep 26), bar one end-to-end check:** `robot_track.Fleet` records WHY each episode ended (`ends`:
   `End.lost` / `.cap` / `.clip_end`) and the state it ended in (`terminal`, `terminal_frame`, `terminal_clip`),
   captured before `restart`. `robot_ppo_track`: `EndKind` per decision (none / stop / cut) and `bootstrap` - the
   critic's value of the TERMINAL observation (`observeTerminal`: the captured state, its reference, the filter
   as it stood, valued before `forget`); `Options.clip_end` (`.terminal` - MimicKit's "success earns nothing,
   nothing follows" - default; `.bootstrap` to measure); advantages via the PURE `gaeColumn` (the lambda-chain
   breaks at any end; what the end is WORTH depends on how it ended). Known answer (robot_ppo_track_tests, "GAE -
   an episode CUT short..."): reward 1, gamma 0.9, a right critic (10 everywhere): a cut bootstrapped from where
   it ended gives advantages of EXACTLY zero; counted as a death, -9 at the end leaking back by gamma*lambda; a
   surprise after a boundary does not cross it - passes. robot_track fast 438/457, geno_ppo smoke green (it caught
   the trainer's missing placeholder fields - `whole-init-first` at work: fast tests never instantiate the
   generic trainer). **End to end, too** (robot_ppo_track_tests, "episodes CUT by the step cap..."; fast): a real
   fleet and trainer on Geno's task, step cap 6 (3 decisions): 4 of 16 decisions ended CUT with finite, non-zero
   values of the state they ended in, `learn` ran on them. **Item 1 closed.**
2. Observation: root height + reference lookahead (1-3 steps) - PPO's observation and the clone's (D5).
   **DONE (Sep 26).** `robot_policy.observe` adds the centre of mass's HEIGHT above the floor, and for each of
   `lookahead_frames` (+2, +4, +6 physics frames: 33 / 67 / 100 ms, MimicKit's 1-3 steps at 30 Hz) where the
   reference's centre of mass is going (from where it is now, in its heading frame - a rise shows before it
   happens) and its watched bodies' SHAPE then (in that frame's own heading frame - drift cannot leak in). The last
   action stays LAST. Every observation is built by ONE function, `observeFrom(fleet, clip, frame, sim, views,
   ...)` with `Views` (the reference now and ahead, a probe): the trainer's live, terminal (bootstrap) and judge
   observations, the teacher's recorder and an older Geno test - they cannot disagree. Geno's observation: 111 ->
   175 numbers. Known answers: invariant under a 10 m move and a 0.8 rad turn to 1.4e-6 (tilt still changes it);
   the recorder's last-action slot matches DReCon's controller to 6e-8; the cut-episode end-to-end test passes
   through it; geno_ppo smoke green.
3. Termination: a worst-body limit; the UNEXPECTED-contact rule measured (servo, teacher, dance, get-up).
4. PPO hygiene: advantage clip +-4, action-bound loss, normaliser frozen after N samples; the diagnostics
   (explained variance, clip fraction, KL, value loss) on geno_ppo and geno_train.
5. Smoothness: the finite-difference Lipschitz penalty (PPO and SuperTrack), judged by jitter and by the
   exploitation index.
6. Then ON.2.2 (SuperTrack parity) as planned; ADD designed as the night's phase 2.

### Phase C - the environment on the GPU: everything resident

Today the phone's CPU is the ceiling (a round fills a frame). v1's arithmetic puts the GPU at ~50x the
samples. The records, table rows and ring are already named layouts a kernel can write.

- **C0 - the cheap multiplier first:** the CPU fleet on `jobs.zig` workers (~3.4x on a phone, measured
  by the engine). **Known answer:** character-steps/s x3 or more, with identical records.
- **C1 - the bookkeeping contract, named**: restarts, failures, clip cursors, where episodes start and
  end, window sampling - the CPU-shaped part of the loop. **Known answer:** the CPU fleet writes through
  it and trains to the digit as before.
- **C2 - state layout and forward kinematics** (parity with `robot.zig`, 1e-5).
- **C3 - bias forces, inverse dynamics** (RNEA per world, 1e-4).
- **C4 - mass matrix, Cholesky, forward dynamics, integration.** M(M^-1 tau) = tau; momentum and energy
  conserved gravity-free; 60 steps against `robot.zig`.
- **C5 - contacts:** capsules and boxes against the floor, self-contact per D19, the solver per D2.
  **Known answer:** normal forces at rest sum to the weight within 1%; a slide stops at v^2/2ug +- 5%; a
  drop penetrates < 1 cm.
- **C6 - servo, episodes, resets, features, reward and records on the GPU**: stable PD through the
  model, RSI with the lift, per-world RNG, termination; records written straight into the ring and
  windows sampled there. **Known answer:** each kernel matches its CPU twin to 1e-5; the servo's time to
  failure distribution matches the CPU fleet's within 10%.
- **C7 - acting on the GPU**: the policy's forward inside the step, over all worlds; the CPU mirror
  retired. **Known answer:** the same actions as the mirror on the same rows, to 1e-7.
- **C8 - throughput and residency**: W = 64 to 4,096, ms per control step on desktop and phone,
  rendering straight from the pose buffer, readback by range per field and scalars only. **Known
  answer:** S8 reproduced from the same seed, faster, with nothing else crossing the bus.
- **C9 - the performance tricks**, each measured on the phone and kept only if it pays: thread- or
  workgroup-per-world per kernel (D3); fewer, fused dispatches per step; f16 storage and arithmetic
  where the device offers `shader-f16`, with f32 accumulation (D20); subgroup reductions where offered;
  a native SPIR-V backend behind the `Compute(M)` seam, judged by the same CPU-twin tests.

### Phase H - the hybrid: a critic, and planning (once many worlds make it affordable)

- **H1 - the critic, CrossQ-style**: batch-normalised, no target network, one update per sample, on
  the resident replay. **Known answer:** its value tracks Monte-Carlo returns on held-out states.
- **H2 - the critic in the policy** (SHAC's terminal value at the window's end). It hurt at CPU
  budgets; judged again with W >= 256. Ablation on G1 and G2.
- **H3 - MPPI over the world model** (8-16 frames, the policy as prior, the critic as terminal value),
  batched over worlds. **Known answer:** on perturbed states, lower predicted AND real cost than the
  policy alone.
- **H4 - MPC at runtime** (frame budget, warm starts, sample count): G2 and G4 with and without it.
- **H5 - MPC in the loop**: data collected with MPC's actions - does the policy inherit the recovery?
- **H6 - the G3 table**: every part's contribution to quality, robustness, minutes and runtime cost.
  What earns nothing comes out.

### Phase Q - quality and robustness

- **Q1 - all four clips to G1**, one policy per clip.
- **Q2 - honest actuators**: torque limits per joint; the servo can ask for any torque today, and a
  policy must not learn to rely on that.
- **Q3 - G2**: a perturbation curriculum with domain randomisation (shoves, friction, mass +-10%, a
  frame of latency) in training; a fixed battery for reporting.
- **Q4 - one policy, four clips** (D9): the clip and its phase in the observation.
- **Q5 - optional: gradients through the real simulator** (adjoints against finite differences),
  compared with the world model's at the same budget.
- **Q6 - G4 on the phone**, end to end, and what has to give.

### Phase M - motion matching and DReCon, whole

- **M1 - motion matching on the GPU**: a feature database from the captures (already Geno's skeleton),
  a brute-force search kernel, inertialised transitions. **Known answer:** the search equals the CPU
  brute force exactly; transitions continuous in position and velocity.
- **M2 - DReCon**: motion matching steered at random during training as the reference, the tracker
  underneath trained as Phase H recommends; D12 settled here.
- **M3 - the comparison and the tutorial**: every method, its numbers, its chapter.
- **M4 - the full gate, the pages on the phone, the retrospective.**

## 4. The modern tricks, as one index

Where each lands, and which are already in. Every one is judged on the phone, by minutes to the bar or
by G1/G2.

| trick | what it buys | where | status |
|---|---|---|---|
| reference-state starts, early termination on tracking error | data along the whole clip; no time spent fallen | task | **in** |
| observation normalisation (Welford, clipped, saved with the weights) | well-scaled inputs | both learners | **in** |
| annealed root assist (residual-force control's idea) | a contact-rich motion learnable before balance is | PPO; resident per D16 | **in (PPO)** |
| action filter `0.2 a + 0.8 y_prev` (DReCon) | smooth, predictable control | PPO; resident at S3 | **in (PPO)** |
| noise-free judged number beside the exploring one | an honest comparison with the servo | `track_train` | **in** |
| one recording per round; one submission; late scalar readback | no CPU-GPU stalls | the loop | **in** |
| policy through a learned model (SuperTrack; SHAC's short window) | gradients instead of trial and error | resident learner | **in**; tuned at S2-S7 |
| the paper's recipe: update ratio, clip-based normaliser, L1 group losses, clipping, ELU, RAdam | a model worth exploiting | S2 | next |
| an action space cut to the axes that matter | less to explore, less for the world model to predict | S0b | todo |
| mirror symmetry | twice the data, free | S4 | todo |
| ensemble with a disagreement penalty | the policy stops exploiting model error | S5 | todo |
| failure-weighted starts (hard-negative mining) | data where the policy fails | S6 | todo |
| demonstration replay for longer windows (DiffMimic) | long horizons without drift | S7 | todo |
| CPU workers, then the GPU environment | x3, then ~x50 samples | C0, C2-C8 | todo |
| fused dispatches, f16, subgroups, native backend | cost per step | C9 | todo |
| CrossQ critic; SHAC terminal value | value past the window | H1-H2 | todo |
| MPPI over the world model, policy prior, critic terminal (TD-MPC2's shape) | recovery a gradient cannot find | H3-H5 | todo |
| torque limits; perturbations with domain randomisation | a controller that survives the real world | Q2-Q3 | todo |
| one policy for many clips | reuse; the base for steering | Q4 | todo |
| motion matching with inertialisation | a steerable reference | M1 | todo |

## 5. Decisions still open

| | decision | taken at | by |
|---|---|---|---|
| D2 | contacts on the GPU: PGS soft constraints, or penalty | C5 | C5's known answers at 120 Hz |
| D3 | thread- or workgroup-per-world, per kernel | C9 | ms per step on the phone |
| D5, D7 | AMP at all; any extra method | M3 | what G1-G3 leave open |
| D9 | one policy per clip, or one for all four | Q4 | quality at G1's bound |
| D12 | reward shape: weighted sum of exponentials, or DReCon's sum INSIDE the exponential | M2 | episode length, as DReCon's Fig 14 |
| D16 | the root assist in the resident learner | S0-S2 | whether the get-up needs it on the new robot |
| D17 | the filtered action in the resident learner | S3 | world-model loss, in-model gain, real time to failure |
| D18 | the Geno robot's joints: balls everywhere the captures turn (an exact copy), or hinges at knees and elbows (fewer actions); how many spine joints; the clavicles (no shapes now) as joints or welded | R6b | R7's copy error against the action count |
| D19 | self-contact on the GPU (the get-up puts hands on thighs), or the floor only | C5 | the get-up's contact log on the CPU |
| D20 | f16 on the GPU | C9 | parity bound and ms saved on the phone |
| D22 | the policy's action axes, per joint: all three, or the principal axes the captures use plus any the correction study says balance needs | S0b | minutes to bar on the phone, reduced against full |
| D21 | ~~how the body's mass is cut between bones~~ **TAKEN (R5b): the tables' planes through the joint centres**, square to the proximal segment (level at the trunk); the shapes keep the skin weights | R5b | measured: the choice moves no segment across the 20% line |

## 6. Tutorial

**After Phase R, re-sync** every chapter that assumes `humanoid_flex2` or IK retargeting: the clips
(retargeting becomes a copy), the model, the floor and the lift, and 12.10 (the resident loop). New
chapters as their code lands: **the robot from Geno's skeleton and mesh** (R), **SuperTrack made
good** (S), **the GPU world** (C), **the hybrid** (H), **motion matching** and **DReCon, whole** (M),
**the comparison** (M3).
**Done Sep 23:** chapter 8 gained 8.7 *Strong enough to stand* (a servo's strength is its free-flight inertia;
armature), 8.8 *A reflex: the capture point*, 8.9 *Starting a run well* (rest on the floor; launch with the
reference's velocity; why a zero-velocity-damping servo erases it). The chapters that assume `humanoid_flex2`
still await the re-sync above.

## 7. Risks, ranked

1. **A measurement in the wrong world** - it cost three turns once, with every test passing. Standing
   rule 7's guard on every environment, a control beside every experiment.
2. **The new robot cannot hold a pose.** R9 is the gate; `servo_ladder`'s rungs are the method if it
   fails.
3. **The policy keeps exploiting the world model.** Warning: in-model gain with no real gain. S2-S5 in
   order; the servo is the control.
4. **GPU physics too slow or unstable on the phone.** Warning: C8's ms per step. Fallback: physics on
   CPU workers (C0), learning on the GPU - today's architecture, which works.
5. **GPU contacts disagree with `robot.zig`.** Fallback: a contact model with its own known answers
   (C5's), the CPU twin keeping the GPU honest.
6. **WebGPU limits**: eight storage buffers per stage guaranteed, 128 MB per binding, the kit's
   2^18-float buffers. Split kernels; raise the kit's size deliberately, never by accident.
7. **The schedule is long.** Phase M shrinks first, then Q5; G1-G3 are protected.

## 8. Housekeeping (when adjacent)

- `tools/geno_fit.py` is a prototype: the tool that makes the robot's shapes should become Zig.
- Readback by range, per field, replacing the host's single global `element_count` (at C8 at the latest).
- Geno's mesh as an option in `getup_frames`.
