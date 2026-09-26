# rl_track_plan.md - v3 (Sep 26, 2026): one Geno, every clip, one night

**What this is.** The current plan for physics-based motion tracking in zimr: Geno (a robot built from a
skeleton and mesh) learning to track motion capture - first the whole dance and the whole get-up, then ~100
LaFAN clips with get-ups hidden in some - trained overnight on a desktop GPU in the browser, later on the
phone. `C` resumes it. Every step has a known answer; every number here was measured unless it says otherwise.

**History.** v2 (Sep 23-26: Phases R, S, D1-D5, ST, ON, MK2 - every measurement and reversal, in the order they
happened) is `src/notes/archive/rl_track_plan_v2.md`; v1 (T1-T9b) is `src/notes/archive/rl_track_plan_v1.md`;
`rl_track_journal.md` is the dated diary. This v3 is a clean restatement: where we are, what we learned, and
what is left, in order - it does not repeat v2's history except where a number anchors a decision.

---

## 0. Standing rules (every turn)

**Turn discipline** (two turns stalled on Sep 26, their replies lost though their work went on):
- Small steps. Record (plan, journal) and end before a turn grows; the next `C` continues.
- Anything over ~60 s runs DETACHED (`setsid nohup ... > /tmp/x.log`) and is POLLED to completion within the
  SAME turn, sleeps under ~110 s per call. Never count on the next turn to collect a run.
- A turn that follows a stalled one starts by inspecting: running processes (by pid - `pkill -f` matched its
  own command line once and killed the turn's shell), files changed since the last snapshot, the newest logs.
  Review what the stalled turn wrote before building on it.
- End every turn: `zig build fix` if needed, lint clean, `zig build check`, snapshot `zimrNNNN.zip`.

**Build and test traps** (each one bit us):
- `-Dtest-filter` that matches nothing compiles NO test bodies - a "compile check" by a bogus filter checks
  only non-test code. Compile a test by filtering on ITS name.
- Fast tests never instantiate the generic `Trainer(M)` (the slow tests that do are skipped at comptime); only
  a page builds it. After changing a trainer, SMOKE THE PAGE.
- Tests inside a module are compiled only if a test root references them - put known answers in the test root
  (`robot_ppo_track_tests.zig`, `robot_tests.zig`, ...).
- Zig: declarations may not sit between container fields; `@typeInfo(T).@"struct".fields` is gone in this
  toolchain (list fields explicitly); `std.math` is banned outside zimrmath (use `zm.pi`, bind names at file
  scope); `whole-init-first` (a new field must appear in the whole-struct literal - the compiler then catches a
  forgotten one: it caught the trainer's `ends`/`bootstrap`).
- Never the full `zig build gate` per turn; targeted tests (`zn-<stem>`, by name), then `check`.
- Pages build in `release` mode (ReleaseSmall, zimr's asserts kept), never `ship`.

**Engineering rules:**
- Every component gets a KNOWN ANSWER (a closed form, an exact identity, a parity to float precision) before it
  is trusted; every quality number is judged in the REAL simulator, never in a model.
- ONE function per concept, so call sites cannot drift: `robot_policy.observeFrom` (every observation),
  `robot_geno.FailureCheck` (every failure verdict), `robot_track.Termination.scaled` (every copy of limits),
  `robot_ppo_track.gaeColumn` (every advantage). Hand-written copies forget fields added later (the watching leash
  dropped the tilt limit).
- Code comments casual and verbose; the robot-mocap tutorial kept in sync with SuperTrack/DReCon changes; the
  tutorial HTML presented as a file whenever it changes.

---

## 1. The goal, stated so it can fail

**North star.** One Geno policy tracks ~100 LaFAN clips - dances, locomotion, falls and get-ups, nobody saying
which is which - from random starts, robust to pushes; trained unattended overnight on a desktop GPU in a
browser page; later trained and run on the phone.

**The first night (ON) - success, stated so it can fail.** After one night (<= 10 h), ONE policy, judged by the
task's own failure rule (`FailureCheck`) from random starts:
- the WHOLE dance (`Motion.dance`, 1,800 frames, 30 s): >= 80% of episodes last past 10 s;
- the WHOLE get-up (`Motion.getup`, 1,080 frames, 18 s: standing, falling, lying from frame ~494, rising):
  >= 50% of episodes that start before the rise reach standing (head within 25 cm of the reference's through
  the rise);
- mean tracking reward (Geno's gated reward) above the servo's on both;
- visible in the morning: Geno lying on the floor, getting up, dancing.
Failure of any of these is information, not a disaster: the morning protocol (ON-e) says what to look at.

---

## 2. Principles (non-negotiable - each with the evidence that made it one)

- **P1 One task for every clip.** No switch may ask which motion it is - not the failure rule, the reward, the
  teacher's cost, the start sampling, the physics (Simon, Sep 26: ~100 clips, get-ups hidden). MimicKit itself
  breaks this (its `contact_bodies` list is set per motion: feet; hands+feet for a cartwheel; none to crawl).
- **P2 The task defines failure; learners and teachers optimise, never redefine it.** `FailureCheck` is the
  task's own `robot_track.terminated` through the task's own functions - bit-identical to the fleet's error. A
  teacher may add its own EARLY WARNING or shaping (it is a greedy planner and needs one), never its own rule.
- **P3 Gravity in everything that scores or ends an episode.** Measured from the root's own frame, a body lying
  with the right joint angles matched a standing reference: the reward scored it 0.80, the teacher never rose
  from the floor. Now: the reward's gravity GATE, termination by relative height and tilt, the observation's
  height, the teacher's posture-gated axis gravity.
- **P4 Root motion followed - and SEEN.** The reward holds the global root (position and yaw); the observation
  shows the policy where the reference IS and which way it faces, from the character; termination fails at 1 m
  or 90 degrees. Without the observation terms drift was invisible and could never be learned away (Simon;
  MimicKit's `track_root`).
- **P5 Simon's filter wherever a policy acts.** DReCon's low-pass on actions (0.2 of the new, 0.8 held) and its
  clock (a decision every 2 physics steps, 30 Hz). A policy's raw reach must be large for strong corrections
  (1.2 rad a unit): the filter keeps what the joints receive moderate (0.24 rad on average for the teacher).
- **P6 Judged in reality.** `Trainer.evaluate` (failures and exposure counted exactly as training counts them),
  the servo as the baseline, the teacher as the ceiling where it applies.
- **P7 Measure before believing** - especially "expected neutral": gravity at full weight HALVED the teacher's
  dance; "root height alone lifts" lifted nothing; "MimicKit ignores drift" was a misreading.

---

## 3. Where we stand (Sep 26, snapshot `zimr1539`)

### 3.1 The robot - Geno
- Built from Geno's skeleton and mesh (`robot_geno.zig`, fixture `src/tests/fixtures/robot/geno.xml`); 21
  shape-carrying bodies; shapes fitted by `tools/geno_fit.py` (capsules and boxes), with the FOREFOOT rule: each
  toe box rebuilt in its foot's frame - 5.0 x 3.5 x 7.2 cm, sole flush (was a 1 x 2.6 cm sliver).
- Ball joints with `standing_armature` = 2.0 (the servo's authority is its free-flight inertia; armature scales
  it - the T-pose holds 9.98 s with the reflex, 1.55 s without).
- The servo: stable PD toward targets, 20 Hz stiffness, acceleration cap 3,000 (`servo_gains`); no velocity
  feed-forward by default (`ServoRun.feedforward` exists: per-step miss 14.3 -> 4.8 mm, survival unchanged).
- Floor friction 2.0 (`floor_friction`); self-collision OFF (`self_collision = false`, 210 excluded pairs); 60 Hz,
  Newton solver, one step a frame; `restOnFloor` (1 mm clear) and `resetToFrame` (reference velocity by backward
  difference) - ONE reset everywhere; clips lifted onto the floor frame by frame (`restClipOnFloor`).

### 3.2 The task (`GenoTask` + `Motion`)
- `GenoTask.init(gpa, io, motion)`: the model (standing armature, Newton, 60 Hz) and ONE motion copied onto it
  and lifted - `Motion.dance_5_15` (frames 300..900 of the dance, what geno_train and D5 used), `.dance` (whole,
  1,800 frames), `.getup` (`fallAndGetUp2_subject2`, whole, 1,080 frames; reference head 0.09 m at frame 494,
  1.54 m standing).
- **Reward** (`robot_track.reward`, Geno's `task_weights`): DReCon's terms - pose position 0.3 and rotation 0.3
  (root frame), velocity 0.1, angular 0.1, root position 0.1 and root rotation 0.1 (WORLD: global displacement
  and yaw) - multiplied by the GRAVITY GATE exp(-height / 0.2 m) exp(-up / 0.5) (a body lying where the
  reference stands: 0.80 ungated -> 0.00002 gated; perfect still 1.000).
- **Termination** (`robot_track.terminated`, Geno's `task_termination`): the pose limits (mean body distance
  0.35 m, rotation 1.2 rad, root frame), the ROOT's place 1.0 m and rotation 1.57 rad (relative to the
  reference's), the bodies' mean HEIGHT 0.4 m off the reference's (relative: lying is fine while the reference
  lies; 0.2 cut a dancer's balance dips), TILT 0.8 (~47 degrees, `Termination.up`). Grace after a reset: the
  pages set it (a training window).
- **`FailureCheck`** - the one failure verdict (teacher, survival loops, recorder, tests, geno_track): poses the
  clean reference exactly as `Fleet.referenceStateInto` does and calls `trackingError` + `terminated`; its
  error equals the fleet's in all eight fields, 0.00e0 apart. `within(fraction)` = the same rule
  `Termination.scaled(fraction)` - an early warning.
- **Episode ends** (`robot_track.End`): `lost` / `cap` / `clip_end`, with the TERMINAL state, frame and clip
  captured before the restart (`Fleet.ends`, `terminal`, `terminal_frame`, `terminal_clip`).
- **Perturbations**: `StartNoise` + `perturbStart` (pose noise on every non-root joint through `integratePos`, a
  horizontal root kick, rested on the floor again; no noise draws nothing) - `Fleet.Options.start_noise`;
  calibrated `d5_start_noise` = 0.05 rad + 0.25 m/s (the servo alone lasts 1 s from 13 of 30 such starts;
  unperturbed 21/30). Mid-episode shoves exist (`shove_every`, `shove_speed`).

### 3.3 The observation (`robot_policy.observe`, built only through `observeFrom`)
In a HEADING frame at the centre of mass (yaw removed, tilt kept; the face-down case handled): the three
centre-of-mass velocities (character, reference, difference) 9; the centre of mass's HEIGHT 1; where the
reference IS from the character 3 and its heading as cos/sin 2; each watched body's position and velocity (36
for Geno's 6), the same as errors against the reference (36); LOOKAHEAD at +2/+4/+6 physics frames (33/67/100
ms, MimicKit's 1-3 steps at 30 Hz) - the future reference centre of mass from the character (3) and its watched
bodies' shape in its own frame (18), x3 = 63; the last applied action LAST (30). **Geno: 180 numbers.** Watched:
LeftToeBase, RightToeBase, Spine3, Head, LeftForeArm, RightForeArm. Known answers: invariant under a 10 m move
and 0.8 rad turn (1.4e-6); the reference moved ALONE 0.5 m is seen 0.500000 m, turned alone 0.3 rad seen
0.300000 rad; tilt changes it.

### 3.4 The action
DReCon's subset - 10 ball joints (Spine, Spine1, LeftUpLeg, LeftLeg, LeftFoot, RightUpLeg, RightLeg, RightFoot,
LeftArm, RightArm), 30 numbers in [-1, 1] (PPO clamps before the controller), x 1.2 rad (`student_scale`) as
offsets composed on the reference, through the filter (0.2) on its clock (2 steps). NOT the elbows or hands
(`drecon_actuated`) - every joint helps a get-up (the teacher planning all 23 joints ran closer to the reference).

### 3.5 The learners and the teacher
- **PPO** (`robot_ppo_track.Trainer(M)` over `robot_gym.GpuPpoOn` - the kit on the GPU, its CPU twin in tests):
  a 3-layer tanh policy (hidden 48 default), learned log-std (Geno starts at -1.2), value MLP; GAE through the
  pure `gaeColumn` - an episode CUT (cap; clip end by option) is bootstrapped from the critic's value of the state
  it ended IN (`observeTerminal`), a lost one stops (`Options.clip_end`: `.terminal` default, MimicKit's choice;
  `.bootstrap` to measure); advantages normalised per batch; epochs 4, minibatch 256, lr 3e-4; Welford
  observation normaliser; a root-assist curriculum (1.0 fading over 300 batches); weights and termination
  passed to BOTH its fleets; `clone` (behaviour cloning: PPO's own policy chain with `mse_bwd`, Adam over the
  policy layers only - 3.3e-7 from zimrnum's graph); `evaluate` counts failures and exposure.
- **SuperTrack** (`robot_latent` CPU learner, `robot_latent_kit` on the GPU): a LATENT residual world model
  z' = z + Net(z, reference, action) in normalised `track.local` features (positions, two-axis rotations,
  velocities, angular velocities, heights, up - the paper's Local(X)), windows of 8; the policy through it over
  a window (default 16; geno_train 8), MSE losses, w_action (L2 on actions), CAPS smoothness `w_smooth`
  (two-sided). geno_train: 4 characters, a 256-step buffer each, hidden 64, action scale 0.6, w_smooth 1.
  "Exploitation" was measured only at 3-5 orders of magnitude less optimisation than the paper's first balance.
- **Off-policy pieces, unused on Geno:** `GpuSacOn`, `SacAgent`, zimrnum's `aggregateCritics` (REDQ/CrossQ),
  `sacTarget`, `Temperature`, `dqnTarget`, `klGaussianDiag`, `explainedVariance`, `ObsNormalizer` (clip 10).
- **The teacher** (`Planner`, `d5_teacher`): MPPI over the TRUE simulator (16 samples x 15 steps, 3 knots,
  temperature 0.03 of the costs' spread), raw sigma 0.6, reach 1.2 rad, Simon's filter and clock, MEMORYLESS
  (each decision plans from the filter's state, 2 MPPI iterations), POSTURE-GATED AXIS GRAVITY (heights of
  hips..head, up vector; weighted by how low the REFERENCE's head is against the robot's standing height: none at
  >= 90%, all at <= 50%), fall penalty from `FailureCheck.within(0.6)`. Measured before the root limits were
  restored: dance (D1's 4 hard starts, 5 s cap) 3.43 s; get-up floor starts 509/530/554 - head 0.75/0.91/1.19
  m (reference 0.99/1.24/1.43). Under the restored 1 m / 90 deg its runs end earlier (it drifts: its cost barely
  weighs drift) - T4 re-measures.
- **The recorder** (`Demo`, `DemoRecorder`): the teacher's decisions as DReCon observations and raw labels;
  every observation's last-action slot equals DReCon's controller's held action (6e-8).

### 3.6 Pages
- `geno_track` - the servo viewer (clips, T-pose hold, balance reflex, sliders), failure by `FailureCheck`.
- `geno_ppo` - PPO on Geno on the GPU, training by default (8 characters, scale 1.2, log-std -1.2, gated reward,
  task termination). Phone: learned after the assist faded, then throttled and crashed after ~5 min.
- `geno_train` - SuperTrack on Geno on the GPU (backpressure, grace, guards). Phone: crashed earlier.
- `getup_train`, `track_train` - the old robot's PPO pages (the templates).
- Headless: every page smokes green; memory flat over 800 frames; the harness's clobber scan knows that a
  submission consumes the writes before it; its lifecycle/shutdown checks SKIP (saying so) when the call log
  hits its 500k cap.

### 3.7 Known answers in place (the tests to keep green)
`robot_ppo_track_tests`: "GAE - an episode CUT short..." (a right critic's advantages exactly zero after a
bootstrapped cut), "episodes CUT by the step cap... (end to end)". `robot_policy`: "the observation does not move
with the character" (+ drift visible). `robot_track`: "the gravity gate...". `robot_geno`: "FailureCheck's error
IS the fleet's", "D5 recorder...", "D5 step 2 - the teacher's decisions replayed through DReCon's controller"
(2.4e-7), "D5 (i) - ... track the teacher's own run" (89 nm), "ON.2.1*" (feasibility, floor lifts), "D1 -
predictive sampling" (the teacher yardstick), "D5.5 - calibrating perturbed starts". `gpu_learn_tests`: "D5 step
3a - cloning on the kit is the graph's" (3.3e-7), G1, the GPU PPO cartpole, SuperTrack kit parity, XOR long runs.

---

## 4. Lessons (evidence-backed - do not relearn)

- **L1 Frames hide gravity.** Anything measured from a root's own frame (shape, pose error) cannot see height or
  tilt. The planner never rose (head 0.46-0.58 m where the reference's climbed to 1.0-1.4); the reward scored
  lying 0.80. Every cost, reward and failure rule is audited for it (P3).
- **L2 A greedy planner needs gravity only where the reference is low.** Every body's height halved its dance
  (limbs double-count the shape and tax balance dips); the root's height alone lifted nothing (a rise is led by
  torso and head, pushed by the arms); the axis's heights lift (head to 0.98 / 1.23 m, within a centimetre of the
  reference's peak) and, gated by the reference's posture, keep 94% of the dance.
- **L3 A teacher with memory the student cannot see teaches noise.** Warm vs cold plans from the same state and
  seed: 0.0046 apart vs 0.0042 of signal between states. Memoryless (planning from the filter's state, which the
  student observes as its last action) with 2 MPPI iterations was also the BEST teacher (3.65 s vs 3.48).
- **L4 Cloning 660 rows memorises.** Held-out error equals the constant's after 25 updates and only rises (0.0084
  -> 0.0185); the teacher's labels are 4x more signal than sampling noise, so it is data and observation, not
  labels. Not the night's path.
- **L5 An episode's end has a kind.** PPO treated the step cap and clip ends as deaths (value 0 after, and the
  value "after" was the NEXT episode's first state). Fixed; the kind is kept (`End`, `EndKind`).
- **L6 What the policy cannot see it cannot correct.** Drift and heading error were rewarded against but invisible.
- **L7 Scale before verdicts.** SuperTrack's "exploitation" was measured 3-5 orders of magnitude of optimisation
  short of the paper's first balance (4 characters vs 256, 1,024-sample buffer vs 150k, batch 16-32 vs 1-2k,
  400-1,600 updates vs 10^4).
- **L8 Separate the task's failure from a planner's early warning.** As a fall PENALTY "hips within 35 cm" was an
  excellent signal for a greedy planner; as the task's failure rule it was wrong. Both roles exist; they differ.
- **L9 Physics transfers.** The teacher's labels replayed open-loop in the trainer's fleet track the teacher's own
  run to 89 nm after a step, under 0.6 um for 45 steps (contact's sensitivity parts them later).

---

## 5. The work, in order

Order rule: each phase removes a way the night could fail, cheapest decisive first; CPU first, GPU once it
pays. Each step: WHY, DESIGN, WHERE, KNOWN ANSWER, DONE WHEN. Estimated sizes are in turns (a turn = a few runs).

### Phase T - the task, finished (CPU)

**T1 - One definition of Geno's task for every fleet and trainer.** (1 turn)
- WHY: gains, floor, lists, action scale, rest-on-floor, reward weights, termination, grace and start noise are
  spelled out at every call site; the D5 step 3 trainer is judged WITHOUT the gravity gate, the end-to-end PPO
  test with the old limits. The next copy will drift too.
- DESIGN: `GenoTask.fleetOptions(envs, capacity) robot_track.Fleet.Options`, `GenoTask.ppoOptions(base)
  robot_ppo_track.Options` (fills every task field of a base that carries only learner knobs), and
  `GenoTask.learnerFleet(...)` for SuperTrack; `task_weights`, `task_termination`, `servo_gains`,
  `floor_friction`, `drecon_*`, `student_scale` stay the single source. Migrate: geno_ppo, geno_train,
  geno_track, every Geno test that builds a fleet or trainer.
- KNOWN ANSWER: a test builds each through the helpers and asserts every task field equals the constants;
  `grep` shows no Geno `Fleet.init` / `Trainer.init` outside the helpers.
- DONE WHEN: all call sites migrated, smokes green, D5 step 3's judge numbers re-measured under the gated reward.

**T2 - A worst-body limit.** (1 turn)
- WHY: our pose limit is a MEAN over bodies (0.35 m): one limb far off (an arm pinned under the body) passes.
  MimicKit fails on the WORST body's distance (1.0 m).
- DESIGN: `TrackingError.worst` (the largest body distance, root frame - drift is the root limit's job) and
  `Termination.worst` (off by default); `scaled` covers it (the field list is the one place).
- KNOWN ANSWER: synthetic states - one body displaced 0.8 m, the rest exact: mean small, worst 0.8, the verdict
  flips at the limit. Measured: the servo and the teacher on both clips (dance: how often worst alone ends a run;
  get-up: no false failures on the floor) - value chosen from that (expected ~0.6-0.8 m).
- DONE WHEN: Geno's `task_termination` carries the chosen value; FailureCheck parity still 0.00e0.

**T3 - Unexpected contact.** (1-2 turns)
- WHY: MimicKit's fastest fall signal is contact - but its allowed-bodies list is PER MOTION (P1 forbids). The
  clip-agnostic form: a body touching the ground while its REFERENCE counterpart is well above it (a knee down
  while the reference stands; nothing flagged when the reference's hands and knees are down in a get-up).
- DESIGN: per body, "in contact" = its lowest point within ~1 cm of the floor (or a contact-force query from
  zimrphysics); the reference's counterpart height from the posed reference; an UNEXPECTED contact when the
  reference's is above `Termination.contact_margin` (~0.15 m). A termination term (and optionally a reward gate
  factor). Evaluate on the servo alone and the teacher, both clips.
- KNOWN ANSWER: a standing reference and a character kneeling -> flagged; both kneeling -> not; a get-up's floor
  phase from the reference's own pose -> never flagged.
- DONE WHEN: measured to catch falls earlier than height/tilt with no false failures on either clip - or
  rejected with the numbers recorded.

**T4 - The teacher follows root motion.** (1 turn, timeboxed)
- WHY: with the root held again (1 m / 90 deg) the teacher's runs end by drift - its cost weighs drift at 0.3.
  P2: the teacher may shape; the task's rule stays.
- DESIGN: `across_weight` becomes `Planner.Options.across_weight`; measured at 0.3 / 1.0 / 2.0 on D1's dance
  starts and the floor lift (509/530/554) under the current `task_termination`.
- DONE WHEN: `d5_teacher` carries the value that keeps the dance >= ~3 s and the get-up's lift; if none does in
  one turn, record and move on (the night's learner is not the teacher).

**T5 - Adaptive start sampling.** (1-2 turns)
- WHY: P1 - no "50/50 dance/get-up". Hard stretches (a get-up hidden in clip 73) must get their share because
  they FAIL, not because they are named.
- DESIGN: per clip, frame bins (e.g., 1 s); an EMA of failures per start in each bin; `Fleet.restart` draws a
  clip and bin with probability proportional to (floor + failure rate)^temperature, uniform frame within the bin;
  every clip gets at least its floor share. Options: bin length, EMA rate, floor, temperature; off = today's
  uniform RSI. Statistics per clip exposed (for the page and the morning).
- KNOWN ANSWER: a synthetic failure map (one bin always fails, others never) -> after N resets the start
  proportions match the formula within sampling error; with the map flat -> uniform.
- DONE WHEN: on in the night's fleet; a CPU run shows starts moving toward the get-up's rise.

**T6 - Old small faults.** (1 turn)
- A decision that ends on its FIRST held step earns half its reward (the mean over 2 steps, 1 credited): credit
  the mean over the steps actually lived.
- The candidate-recording path indexes the clip with the model's nq (`clip.targets[g * m.nq ..]`) - right only
  while clip.nq == m.nq; use `clip.pose(g)[clip.nq - m.nq ..]` as everywhere else.

### Phase P - PPO hygiene (the kit and its CPU twin, parity for each)

- **P1 Advantage clip** +-4 after normalisation (MimicKit's `norm_adv_clip`). Known answer: a batch with one huge
  outlier - clipped exactly, the rest untouched.
- **P2 Action-bound loss.** Today a sample outside [-1, 1] is CLAMPED for the controller but keeps its unclamped
  log-probability: PPO's ratio lies about clamped actions. Add MimicKit's loss on the MEAN outside the bounds
  (weight 10: sum of squared excess). Known answer: the gradient on a mean at 1.3 equals 10 * 2 * 0.3; parity vs
  zimrnum's graph.
- **P3 Normaliser freeze** after N samples (MimicKit: 10^8): a moving input scale late in training moves every
  weight. Option; known answer: statistics identical before/after N + k samples.
- **P4 Diagnostics on the pages** - `PpoStats` already computes clip fraction, KL, explained variance: expose them
  with value loss and the log-std on geno_ppo and in the night's CSV ("how you know it is working").
- **P5 Measured choices:** fixed vs learned action spread (MimicKit fixes 0.05); `clip_end` terminal vs bootstrap;
  PPO widths for the desktop (256 / 512 / 1024). Short CPU-twin runs on Geno's task, judged by `evaluate`.

### Phase S - SuperTrack as published, and safe from its own model (CPU first; kit parity for each)

Background (ST.0 in v2): the paper's gym (256 characters, 150k-sample buffer, ~5,000 samples/s), `Local(X)`
inputs with heights and up, the ACCELERATION world model integrated over 8-frame windows (L1 losses), the policy
through it over 32 frames (L1 losses in local space incl. heights and up, L2 + L1 offset penalties, noise 0.1 x
alpha 120 deg), 5 x 1024 ELU nets, batch 2048/1024, lr 1e-3/1e-4, one world step and one policy step an
iteration; basic balance ~10^4 iterations, full 1-2 x 10^5.

- **S1 Policy window 32** (paper; 16 plateaus far lower). Cost measured on the CPU learner and the kit; kit
  parity at 32.
- **S2 Buffer and batch:** buffer >= 30 s of data (the paper's 150k at 5,000/s); batch 256-1024 (the desktop).
  Memory measured.
- **S3 L1 losses** (world model and policy): a graph op + a kit kernel (`l1_bwd`: sign(y - t) / n); parity.
- **S4 The normaliser from the CLIPS** (the paper measures it from the kinematic data; ours from whatever the
  replay holds at start - a few seconds of falling): `measureNormalizer` over the reference frames.
- **S5 Exploration noise in the paper's units** (0.1 x 120 deg = 0.21 rad an axis vs ours 0.06).
- **S6 PD target velocities** (the reference's joint velocities as the servo's target velocities - `feedforward`
  in the fleet): an option; world model input unchanged (targets carry it).
- **S7 The world model's FORM at scale:** the paper's acceleration + integration vs our latent residual (D15
  judged accelerations at OUR scale). Equal compute, D3's yardstick on held-out windows (action-response cosine,
  multi-step error against the trivial predictor), teacher and policy data. Keep the winner.
- **S8 Simon's filter IN the graph:** the policy's input gains the last applied action; y_t = 0.2 a_t + 0.8
  y_(t-1) in-graph (a known formula, differentiated exactly); the world model sees applied targets. Kit parity.
- **S9 The EXPLOITATION INDEX, always on:** the in-model improvement of the tracking loss vs the REAL improvement
  (`judgeQuality`) - the gap is the exploit, a number every run reports.
- **S10 The TRUST signal:** W's multi-step error on the policy's freshest HELD-OUT real windows over the trivial
  predictor's (e_val / e_0) and the action-response cosine; the policy's learning rate through W scales with
  clamp(1 - e_val / e_0, 0, 1) x [cosine >= 0.8]; W trained twice an iteration when trust falls.
- **S11 Drift for SuperTrack too** (P4): the policy's input gains the reference's place and heading from the
  character (as the DReCon observation now does); the loss penalises the root's world offset (the paper's
  rough-terrain variant).
- **S12 Smoothness by construction** (LCP): a finite-difference Lipschitz penalty |mu(o + e) - mu(o)|^2 / |e|^2
  on random small e - no double backprop - for SuperTrack and PPO; judged by jitter and the exploitation index.
- **S13 The height term's weight, with BOTH motions:** the get-up hangs on SuperTrack's height loss (L2 lessons);
  a CPU run on dance + get-up checks the rise is learned, not just the dance.

### Phase ON - the night

**ON-a The desktop page** (`geno_night`, from geno_train):
- Learner: SuperTrack (Phase S) - PPO (Phase P) as the second page, same task, for an A/B night if wanted.
- Clips: `Motion.dance` + `Motion.getup` (the 100-clip library later - A2); ADAPTIVE starts (T5); termination
  `task_termination` with a window's grace; reward `task_weights`.
- Perturbations RAMPED: none for the first hour; then `d5_start_noise` on half the resets and shoves (a random
  kick every few seconds) - the buffer spread where a policy may stray.
- Scale chosen BY THE MACHINE: a 60 s start-up probe times an iteration at candidate widths/depths (3 x 256,
  4 x 512, 5 x 1024) and batches, keeps the largest at >= 5 iterations/s (a night >= 150k iterations, the paper's
  full count); characters as many as the CPU sustains at >= 1,000 samples/s.
- Unattended: a checkpoint every 10 min (weights, Adam moments, normaliser, iteration, sampler statistics) in
  browser storage (IndexedDB via zimr's storage), resumed on reload; on a non-finite loss or weight: restore the
  last checkpoint, halve the learning rates, carry on (logged); GPU backpressure as today.
- Curves every minute (on the page and a downloadable CSV): survival per clip (the paper's metric), reward per
  clip, world-model loss, trust (e_val / e_0, cosine), the exploitation index, iterations/s, samples/s, GPU-bound
  share, start-sampling shares per clip.
- A WATCH toggle: the current policy on each clip, from chosen frames (the get-up from lying).
- Headless: smoke green; 800 frames flat memory; handles balanced under the log cap.

**ON-b A CPU mini-night** - the exact recipe scaled down (few characters, small nets, 20-30 min on the CPU twin):
survival rising above the servo's on both clips, the exploitation index bounded, trust rising. The last check
before GPU time is spent.

**ON-c Simon's 30-minute desktop rehearsal** - the checklist: iterations/s and samples/s as the probe chose;
survival and reward curves moving; trust rising; exploitation index small; no NaN restores; memory stable.

**ON-d The night.**

**ON-e The morning protocol:** download the CSV; survival curves per clip vs the servo's; watch the dance and the
get-up from lying; read trust and the exploitation index across the night; decide: another night (what changes),
Phase A, or back to a phase.

### Phase A - after the first night

**A1 ADD - a reward LEARNED from the difference** (MimicKit's Adversarial Differential Discriminator): the
discriminator sees only reference minus simulation (per-feature `DiffNormalizer`), its "real" samples the ZERO
difference (perfect tracking); the hand reward's weight 0. Clip-agnostic by construction - which differences
matter is learned from the data (a body lying where the reference stands is an obvious difference). Needs: a
discriminator MLP (the kit has MLPs), a gradient penalty (weight 2 - needs input gradients of the penalty: double
backprop, or a finite-difference / spectral-norm substitute) and logit regularisation (0.01). CPU parity first;
then an A/B night against the hand reward (the first night is the baseline).

**A2 The 100-clip library.** A clip list (LaFAN `assets/lafan1/*.bvh`), each copied (`copyClip`) and lifted
(`restClipOnFloor`), with per-clip bookkeeping (length, adaptive-start statistics, survival); the fleet over
all clips; the evaluation per clip; memory and load time measured (1,800-frame clips x 100). The get-ups are
found by the start sampler (T5), never named.

**A3 D5 revisited, only if the night's learner plateaus.** The paused clone line (v2 D5): a DReCon-space world
model on pooled data (the teacher's jittered candidates, D3's recipe), its trust signal, blended gradients
(g = g_PPO + w_BC grad L_BC + w_WM grad L_WM with measured weights). The clone needs data at scale (L4) - perturbed
starts multiply it.

### Phase X - the phone (deferred; the GPU infrastructure is sound)
- XOR trained beside the servo for minutes (36,639 steps, up to 53 steps a frame): the GPU path is sound.
- geno_ppo (8 characters) and geno_train (4) throttled and crashed after minutes; headless nothing grows (CPU
  memory flat, GPU objects constant, clean teardown).
- Next, when the phone is back: two switches on geno_ppo - learning on the CPU host instead of the GPU; 2
  characters instead of 8. If the CPU version crashes too, it is not the GPU; if 2 survive, it scales with load
  (thermal or physics).

### Phase M - motion matching and DReCon whole (later)
A motion-matching controller producing the reference (DReCon's setup), interactive control, the policy tracking
it; style priors (AMP / ASE / SMP) for task control.

---

## 6. Decisions

### 6.1 Made (with the reason)
- Geno's action scale 1.2 rad a unit, actions in [-1, 1] - capped at 0.6 the teacher collapses (1.34-1.46 s vs
  3.48): through a 0.2 filter a strong correction needs a large raw command.
- PPO's initial log-std -1.2 (young exploration ~0.36 rad raw, ~0.07 rad at the joint).
- Offsets from the reference, not absolute targets (SuperTrack's ablation; DReCon) - MimicKit's absolute targets
  within joint-limit bounds is the justified difference.
- Termination "fallen or lost the pose" + the root held (1 m / 90 deg), relative everything - P2, P3, P4.
- The gravity GATE (multiplicative) rather than more additive terms - one large error sinks the reward, as
  SuperTrack's single exponential does; MimicKit gets the same through world-orientation terms.
- Clip end = terminal (MimicKit's), measurable against bootstrap (P5).
- The teacher: memoryless x 2, posture-gated axis gravity - the only cost that kept both motions.
- SuperTrack is the night's learner; PPO the reality anchor and the A/B.
- Cloning (D5 step 3) paused: memorises at our data scale.

### 6.2 Open
- The world model's form (S7): accelerations or latent.
- The worst-body limit's value (T2); unexpected contact in or out (T3); the teacher's across weight (T4).
- Fixed vs learned PPO spread; clip_end; PPO widths (P5).
- 60 vs 120 Hz physics for contact-rich motions (get-ups) - cost x2; measured when the night's first result
  points at contact quality.
- Whether PPO's observation should watch EVERY body (MimicKit's full joint state; SuperTrack's Local(X)) rather
  than DReCon's six.
- ADD as the reward for the 100 clips (A1).

---

## 7. Risks, ranked (with the mitigation)

1. **The night learns the dance but not the get-up.** Mitigations: the get-up is feasible (the teacher lifts);
   adaptive starts give its rise the share its failures earn (T5); the height loss checked with both motions
   (S13); every joint acts in SuperTrack; the morning protocol reads per-clip curves.
2. **SuperTrack exploits its world model at scale.** Mitigations: the exploitation index (S9) and the trust
   signal (S10) - the policy's rate through W falls by itself; Simon's filter in the graph (S8); perturbations
   spreading the buffer; the LCP penalty (S12); PPO as the A/B.
3. **The page crashes or stalls unattended.** Mitigations: checkpoints + resume, NaN self-healing, backpressure,
   the rehearsal (ON-c), memory-flat long smokes.
4. **The probe picks a scale that learns too slowly or too big to fit.** Mitigations: the probe's floor of 5
   iterations/s; the CSV shows iterations/s all night; the rehearsal checks it.
5. **Drift or heading loss ends most episodes.** Mitigations: the observation shows the reference's place and
   heading (done); SuperTrack's drift inputs and loss (S11); the 1 m / 90 deg limits measured against the servo.
6. **A task-definition drift between call sites.** Mitigation: T1 (one definition); FailureCheck parity test.
7. **The phone never works.** Deferred (Phase X); the desktop night does not depend on it.

---

## 8. Where things live

- `src/robot_geno.zig` - Geno: the model and shapes, `ServoRun`, `Planner` (the teacher), `FailureCheck`,
  `GenoTask` / `Motion`, `task_weights` / `task_termination`, `d5_teacher`, `d5_start_noise`, `student_scale`,
  `axis_bodies`, `drecon_watched` / `drecon_actuated`, `Demo` / `DemoRecorder`, every Geno trial (D1, D5, ON.2.1*).
- `src/robot_track.zig` - the task: `Fleet` (resets, `perturbStart`, `End` + terminal capture, shoves),
  `TrackingError`, `reward` (gravity gate), `Termination` (+ `scaled`), `terminated`, `trackingError`, `stateOf`,
  `local` features, `resetToFrame`, the replay.
- `src/robot_policy.zig` - DReCon: `Subset`, `Controller` (filter + clock), `observe` / `observeFrom` / `Views`,
  `lookahead_frames`.
- `src/robot_ppo_track.zig` (+ `_tests`) - PPO on the fleets: `Trainer(M)`, `gaeColumn`, `EndKind`, `ClipEnd`,
  `clone`, `evaluate`.
- `src/robot_gym.zig` - `GpuPpoOn` (`trainMinibatch`, `cloneMinibatch`, `policyForward` / `policyBackward`),
  `GpuSacOn`, `SacAgent`, `PpoTrainer` (CPU), `Layer`, `AdamSet`.
- `src/robot_latent.zig`, `src/robot_latent_kit.zig` - SuperTrack (CPU learner, GPU kit).
- `src/zimrnum.zig` - graphs and autodiff; RL pieces (`ObsNormalizer`, `PpoConfig`, `PpoStats`,
  `aggregateCritics`, `sacTarget`, `klGaussianDiag`, `explainedVariance`, ...). `src/gpu/zn_mlp.zig` - the kit's
  kernels (dense, activations, `mse_bwd`, `adam`, PPO heads, SuperTrack's).
- `tools/geno_fit.py` - Geno's shapes (the forefoot rule); `examples/geno_*` - the pages; `webtests/wgpu_smoke.zig`
  - the headless harness.
- Notes: this plan; `rl_track_journal.md`; `claude.md` (working rules); `src/notes/archive/` (v1, v2).

---

## Appendix A - SuperTrack, ours against the paper (Sep 26)

| | paper | ours today | step |
|---|---|---|---|
| characters / data rate | 256 / ~5,000 s^-1 | 4 / ~240 s^-1 (phone) | ON-a probe |
| buffer | ~150,000 | 4 x 256 | S2 |
| world model | accelerations, integrated | latent residual | S7 |
| networks | 5 x 1024 ELU | 64-256, 2-3 layers, tanh | ON-a probe |
| batch W / Pi | 2048 / 1024 | 16-32 | S2 |
| windows W / Pi | 8 / 32 | 8 / 8 (page), 16 default | S1 |
| losses | L1, balanced | MSE on normalised features | S3 |
| offset penalty | L2 + L1 | L2 + CAPS smoothness | - |
| noise | 0.21 rad an axis | 0.06 rad | S5 |
| inputs | Local(X): heights, up | the same | - |
| normaliser | offline, the clips | the replay at start | S4 |
| PD target velocity | the reference's | zero | S6 |
| drift | inputs + losses (rough terrain) | none yet | S11 |
| updates | 10^4 to balance, 10^5 full | 400-1,600 so far | ON |

## Appendix B - MimicKit (DeepMimic humanoid, `track_root` on) against ours

| | MimicKit | ours | verdict |
|---|---|---|---|
| episode ends | TIME bootstrapped from the terminal obs; SUCC 0; FAIL 0 | cap cut + bootstrapped; clip end terminal (option); lost stops | SAME (fixed Sep 26) |
| failure | contact by non-allowed bodies (PER MOTION); worst body > 1 m (world); root > 1 m | pose mean, root 1 m / 90 deg, height and tilt relative | T2, T3 |
| reward | 0.5 joint rotations (per-joint weights) + 0.1 joint velocities + 0.15 root (global pos incl. height, rot incl. yaw) + 0.1 root velocities + 0.15 key bodies (world orientation); Gaussian kernels | pose/velocity in the root frame + global root + the gravity gate; Laplace kernels | justified; per-body weights an A/B later |
| observation | heading frame; root height; all joints (6D) + velocities; key bodies; targets at 1-3 steps RELATIVE TO THE CHARACTER | heading frame at the COM; height; the reference's place + heading; 6 watched bodies; lookahead 1-3 steps | SAME in kind; every body open (6.2) |
| action | absolute PD targets within joint-limit bounds; 30 Hz control, 120 Hz sim | offsets through the filter; 30 Hz, 60 Hz sim | justified; 120 Hz open |
| PPO | 2 x 1024; SGD 1e-4; 5 actor / 2 critic epochs; adv clip +-4; FIXED std 0.05; bound loss 10; normaliser frozen at 1e8 | 3 x 48; Adam 3e-4; 4 epochs; learned std; clamp | P1-P5 |
| smoothness | LCP gradient penalty 0.002 | the filter; CAPS (SuperTrack) | S12 |
| reward learning | ADD (differential discriminator) | - | A1 |

## Appendix C - the night's starting settings (to be set by ON-b and the probe)

- Task: `task_weights` (gate 0.2 m / 0.5), `task_termination` (+ T2/T3 results), grace one training window,
  adaptive starts (T5: 1 s bins, floor 0.2 of uniform, temperature 1), perturbations after hour 1
  (`d5_start_noise` on half the resets; shoves every ~3 s at ~0.4 m/s).
- SuperTrack: windows 8 / 32; batch 1024 / 512 (or the probe's); widths the probe's; lr 1e-3 / 1e-4; L1 losses;
  noise 0.21 rad an axis; offset penalties L2 0.01 + L1 0.01; CAPS smoothness 1; the filter in the graph; the
  trust gate on; one world step and one policy step an iteration (two world steps when trust falls).
- Checkpoints every 10 min; CSV every minute.
