# rl_track_plan_v3.md - ARCHIVED Sep 27 (superseded by `src/notes/rl_track_plan.md` v4). v3 (Sep 26, 2026): one Geno, every clip, one night

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

**The FIRST night (reordered Sep 27) - the 10-second dance only, success stated so it can fail.** After one night
(<= 10 h), ONE SuperTrack policy on `Motion.dance_5_15`, judged by F1's judge (the mean action, 20 starts every 0.5 s,
the task's rule):
- mean time to failure at least 5x the servo alone's (F1, under SuperTrack's rule since F3b: 1.53 s -> >= 8 s);
- >= 60% of the 20 starts reach the clip's end (the servo alone: 1 of 20 - the start half a second from the end);
- the mean gated reward above the servo's; the exploitation index bounded all night;
- visible in the morning: Geno dancing the ten seconds.

**Later nights (Phase C) - the whole clips, success stated so it can fail.** ONE policy, judged by the task's own
failure rule (`FailureCheck`) from random starts:
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

Phases (REORDERED Sep 27, Simon: "foundations for a good SuperTrack training on the 10-second dance, always similarly
difficult, before tweaking the curriculum"):
T (the task - done through T4b and the T3 revisit) -> F (SuperTrack FOUNDATIONS on `dance_5_15`: a judge, the
problem fixed, a FEASIBLE reference baked from the dance (F5), the paper's recipe piece by piece, a CPU mini-run -
built from Phase S's items, in F's order) -> R
(runs: launch, snapshot, restore, test, compare - Simon's nightly workflow) -> ON (the first night: the 10-second
dance ONLY) -> C (curriculum: adaptive starts, the get-up, perturbation ramps, more clips) -> P (PPO hygiene, for the
A/B page) -> A (after).

### Phase T - the task, finished (CPU)

**T1 - One definition of Geno's task for every fleet and trainer.** (1 turn) - DONE Sep 27
- WHY: gains, floor, lists, action scale, rest-on-floor, reward weights, termination, grace and start noise are
  spelled out at every call site; the D5 step 3 trainer is judged WITHOUT the gravity gate, the end-to-end PPO
  test with the old limits. The next copy will drift too.
- DESIGN (as built, Sep 27 - TYPED; the helper-function design first built was dropped, see the journal):
  `robot_track.Task` (servo gains, floor friction, floor rest, reward weights, termination) embedded as `task` in
  both `Fleet.Options` and `robot_ppo_track.Options`, handed to every fleet whole; `robot_policy.Bodies` for
  DReCon's watched/actuated lists. robot_geno holds typed constants: `tracking_task`, `servo_task` (the D-phase
  condition: default reward and limits), `drecon_bodies`. The action scale is the LEARNER's, not the task's:
  `student_scale` (1.2, DReCon) and `supertrack_action_scale` (0.6). No `anytype` anywhere in it.
- KNOWN ANSWER: `tracking_task` carries the gravity gate and the failure rule and `servo_task` differs in exactly
  those two fields (robot_geno test); the PPO trainer's FLEET runs `geno.tracking_task` whole (cut-path test).
- STATUS: migrated - geno_ppo, geno_train (with its training grace named once, `training_task`), the three Geno
  trainers in robot_ppo_track_tests (two had lost the gravity gate), the FailureCheck parity test, and the seven
  D-phase experiments (onto `servo_task`, behaviour unchanged). geno_track needs nothing: it builds no fleet or
  trainer; its sliders START from `servo_gains` / `floor_friction`. PPO test root 483 pass / 0 fail; four pages
  smoke green, the Geno pages with call profiles identical to before.
- DECIDED (a), Sep 27: the D-phase experiments (D3, D4, D5 recorder, D5 (i), S2b, trackTrial) STAY on
  `servo_task` - recorded history. They document decisions already taken; re-measuring them is several long runs
  that feed nothing the night needs. Reversible: switching one is a one-line change plus its re-measurement.
- DONE (Sep 27). D5 step 3 under `tracking_task`, with 10x data (the first completed 10x run): servo 90 failures /
  MTTF 107 / reward 0.493, clone 103 / 93 / 0.367; held out 0.0675 vs always-zero 0.0770. The clone still loses to the
  servo alone - by 14% more failures, where Sep 25's lost by 2x. Journal, Sep 27.

**T2 - A worst-body limit.** (1 turn) - DONE Sep 27
- WHY: our pose limit is a MEAN over bodies (0.35 m): one limb far off (an arm pinned under the body) passes.
  MimicKit fails on the WORST body's distance (1.0 m).
- DESIGN: `TrackingError.worst` (the largest body distance, root frame - drift is the root limit's job) and
  `Termination.worst` (off by default); `scaled` covers it (the field list is the one place).
- KNOWN ANSWER: synthetic states - one body displaced 0.8 m, the rest exact: mean small, worst 0.8, the verdict
  flips at the limit. Measured: the servo and the teacher on both clips (dance: how often worst alone ends a run;
  get-up: no false failures on the floor) - value chosen from that (expected ~0.6-0.8 m).
- DONE WHEN: Geno's `task_termination` carries the chosen value; FailureCheck parity still 0.00e0.
- STATUS (Sep 27): mechanism landed (`TrackingError.worst_body`, `Termination.worst_body`, `scaled` / `terminated` walk
  the struct - a limit without a matching error is a compile error); parity 0.00e0 with it included. MEASURED: the
  servo never bends a limb over 0.16 m (it fails whole); the teacher swings limbs to 0.69 m while succeeding; nothing is
  cut from 0.7 m up. DONE Sep 27: Simon picked 0.8 m; `task_termination.worst_body = 0.8`; parity 0.00e0; the
  measurement (pinned to the rule without the limit) reproduces byte for byte.
- REVISED (Sep 27, T3 revisit): OFF for the night. The teacher's best rise from 509 crosses 0.83 m at 0.75 s -
  a lagging rise, not a lost limb. Kept as mechanism (tested); see T3's revisit for why lag is RSI's job.

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
- DESIGN DETAIL (Sep 27, fitted to T2's "the struct is the list"): GEOMETRY, not the physics' contacts - it measures
  the character and the reference the SAME way (a contact force exists only for the simulated one). `rbt.lowestPoint`
  split into a per-shape helper + `bodyLowestPoints(m, d, out)` (lowestPoint = their min: one geometry function).
  `State.lowest` per body, filled by `stateOf`; `State.init` fills 1e30, so a state built WITHOUT geometry (the world
  model's predictions in robot_world) can never read as touching the floor. `TrackingError.unexpected_contact`: over
  the bodies the character has on the floor (lowest point within 1 cm), the highest its reference counterpart holds
  (metres) - knee down while the reference stands ~0.5, both kneeling 0, the get-up's hands and knees 0 (the
  reference's are down too). `Termination.unexpected_contact` caps it, off by default.
- STATUS (Sep 27): CODE COMPLETE as designed, plus a per-robot exemption the design missed - FEET (a foot is down in
  stance while the reference lifts it into swing: lag, not a fall): `Task.contact_exempt` names, resolved in the
  fleet and FailureCheck. Verified by known answers (Simon: no long runs) and argument; parity 0.00e0.
- REVISIT (Sep 27) - REJECTED in this frame-by-frame form, by its own bar. Judged silently on the teacher's three
  good rises (head to 0.77 / 0.90 / 1.12 m): contact would end them at 0.78 s (chest down, reference's 0.30 m up)
  and 0.88 s (right arm still pushing the floor, reference's 0.6 m up) - LAG, not falls. `unexpected_contact` is
  measured, not limited (`task_termination` leaves it off). With both event limits off, the GRADUAL limits end the
  same lagging rises a little later (1.03-1.68 s: tilt, pose rotation). That is DeepMimic's recipe working, not a
  flaw: reference-state initialisation starts episodes IN STEP with the reference anywhere in the clip, so a rise is
  learned stretch by stretch and an episode that falls behind simply ends - the signal. Hence T5 carries the get-up.
  LATER (not the night): a lag-tolerant contact - unexpected only if the reference has not had that body down within
  the last ~0.5 s (a per-clip table of each body's lowest point, a sliding minimum) - if falls need catching earlier.

**T4 - The teacher follows root motion.** (1 turn, timeboxed) - DONE Sep 27 (no value passes; see T4b)
- WHY: with the root held again (1 m / 90 deg) the teacher's runs end by drift - its cost weighs drift at 0.3.
  P2: the teacher may shape; the task's rule stays.
- DESIGN: `across_weight` becomes `Planner.Options.across_weight`; measured at 0.3 / 1.0 / 2.0 on D1's dance
  starts and the floor lift (509/530/554) under the current `task_termination`.
- DONE WHEN: `d5_teacher` carries the value that keeps the dance >= ~3 s and the get-up's lift; if none does in
  one turn, record and move on (the night's learner is not the teacher).
- RESULT (Sep 27): none does - 0.3 / 1.0 / 2.0: dance 1.37 / 1.65 / 1.48 s (servo 1.14), lift mixed; 0.3 kept.
  `across_weight` is a `Planner.Options` field now. The A/B found the lift's REGRESSION since Sep 26 is T2/T3's
  limits inside the teacher's early warning (0.6 x every limit: worst body 0.48 m, contact 0.18 m) -> T4b.

**T4b - The teacher's early warning without the EVENT limits.** (small) - DONE Sep 27 (see RESULT)
- WHY: the teacher pays its fall penalty within `danger` (0.6) of every limit. For gradual limits (drift, height,
  tilt) a margin is the point; for T2's worst body and T3's contact it forbids the teacher's own good moves - a
  0.69 m balance swing, a hand pushing the floor during a rise. With both off in its check, the rise returns
  (T4 A/B: 0.90 / 1.12 m from 530 / 554 vs 0.63 / 0.66).
- DESIGN: `Planner.Options.warning` - the limits the early warning scales (default: `task_termination` with the
  worst-body and contact limits OFF) - read by a `FailureCheck.withinLimits(..., limits)`; `run.lost` (the judge)
  keeps the task's full rule. P2: the teacher may shape; the task's rule stays.
- KNOWN ANSWER: the lift from 509 / 530 / 554 back to Sep 26's level (>= 0.75 / 0.91 / 1.19 m, 3 starts, single run
  each - noted as such); the dance under the FULL rule no worse than today's 1.37 s.
- RESULT (Sep 27): built as `Planner.Options.warning` + `FailureCheck.withinLimits`; three warnings measured (journal).
  Kept "warned AT the event" (`teacher_warning`: a margin on gradual limits, none on event limits): dance 1.94 s (from
  1.37), lift 0.66 / 0.36 / 1.13 m - no worse than T4's overall, collapsed from 530. The lift from 530 comes back only
  when the teacher may cross an event limit - suspected: T3's 0.3 m contact limit vs a rise slower than the
  reference's. -> T3 revisit: measure which limit the rise from 530 crosses, before the night.

**T5 - Adaptive start sampling.** (1-2 turns) - MOVED to Phase C (curriculum), after the first night (Simon, Sep 27).
THE GET-UP'S STEP when it comes (T3 revisit: a rise is learned from starts inside it, in step with the reference)
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

### Phase F - SuperTrack FOUNDATIONS on the 10-second dance (Sep 27)

The problem, fixed: `Motion.dance_5_15` (the dance from 5 s to 15 s - the servo alone falls within ~1 s anywhere
in it, so every stretch is similarly hard), uniform reference-state starts, NO perturbations, `tracking_task` with
a training window's grace. Nothing curriculum-like until this trains well: a curriculum on a learner that does not
learn only moves the noise around. (Every difference between our SuperTrack and the paper's - and an unofficial
implementation's - is tabled in `src/notes/supertrack_comparison.md`, Sep 27; the steps below cite it.)
Today `geno_train` runs SuperTrack at PHONE scale (batch 16, one 8-frame window,
64-wide nets, one update of each per round) - the paper's is 32-frame policy windows, 5 x 1024 nets, a 150k buffer,
10^4 iterations to balance. F closes that gap in an order where every step is JUDGED, cheapest decisive first.

- **F1 THE JUDGE (first - everything after is measured by it).** One function, deterministic: the policy's MEAN
  action (no exploration), fixed starts spread evenly over the clip (every 0.5 s: 20), each run until the task's
  rule loses the reference or the clip ends. Reports mean time to failure (failures per watched second, as the page
  does), the share of starts that reach the clip's end, the mean gated reward - and the SERVO ALONE on the same
  starts, in the same units. Shared by SuperTrack, PPO (`evaluate` today) and the night's curve. KNOWN ANSWER: two
  calls give identical numbers; the servo alone reproduces its known ~1.1 s.
  - F1a DONE (Sep 27): `robot_track.judge` / `Judgement` / `Actor` / `evenStarts`, `Fleet.startAt` (split out of
    `restart`, same random draws - robot_track 434 pass). Known answers: identical twice, every start counted once,
    the servo is exactly the zero actor. BASELINE: servo alone on `dance_5_15`, 20 starts every 0.5 s: MTTF 1.61 s,
    1 of 20 reach the end, reward 0.476. (The ~1.1 s above came from other starts.)
  - F1b DONE (Sep 27): `Resident.judgeActor()` - the policy mirror's mean action on the JUDGE's fleet
    (`featuresOf(fleet, env)`; `features(env)` is the training path's shorthand). `Judging` - the judge made
    INCREMENTAL (`advance(actor, budget)`), `judge` runs it to the end - so a page spreads a judgement over frames.
    Known answers: a zero mirror judges EXACTLY as the servo; a trained one differs; the learner's rng, its fleet's
    rng and frames are byte-identical after judging; 7 steps at a time == one shot.
  - Where it shows: the NIGHT page's judge every few minutes (R4) - not geno_train's phone panel, which would be
    wiring it twice. PPO's `evaluate` onto the same judge in Phase P.
- **F2 THE EXPLOITATION INDEX and TRUST, measured every evaluation** - DONE for the CPU learner (Sep 27, see below;
  the GPU learner's comes with the night page, R4) (S9, and S10's measurement - not yet its control): the tracking loss the world model PREDICTS for the policy's rollouts from the judge's starts vs the loss
  the REAL rollouts have - the gap is the exploit; and the world model's multi-step error on fresh held-out windows
  against the trivial predictor (e_val / e_0) with the action-response cosine. SuperTrack's typical failure is a
  policy that improves in its model and falls in reality; without these two numbers that is invisible.
  - F2 AS BUILT: `latent.Learner.diagnose(clip, starts, horizon) -> Diagnosis`, on the JUDGE's starts (held out by
    construction - new trajectories, never in the replay). Five rollouts per start: real zero (a), real policy (b),
    model open-loop zero (c), model open-loop on b's recorded actions (d), model closed-loop policy (e). TRUST =
    error(d vs b) / tracking loss(b): the trivial predictor is "it tracks the reference", whose error on b IS b's
    tracking loss. EXPLOITATION = ((c - e) - (a - b)) / a: promised gain minus delivered. Each start compares only
    the steps BOTH real rollouts lived (an episode ending on a step has already been restarted - that step is not
    compared). Known answers: zero policy weights -> exploitation EXACTLY 0 (real_policy == real_zero, model_policy
    == model_zero, follow errors equal); identical twice; the learner's fleet untouched.
- **F3 THE SERVO'S TARGET VELOCITIES (S6), measured first on the servo alone.** The reference's joint velocities as
  the servo's target velocities (`feedforward`). If the servo alone lasts clearly longer, every learner's job
  shrinks for free - kept; if not, recorded and dropped. One short run.
  - F3 DONE (Sep 27) - DROPPED, recorded. `Gains.velocity_feedforward` (the servo's option, in the task; the fleet
    honours it; `ServoRun`'s own flag retired into it) and `robot_track.referenceVelocity` (one definition; the old
    copy indexed the clip with the MODEL's nq - T6's fault class, fixed in the move). Judged on `dance_5_15`: MTTF
    1.61 -> 1.63 s (+1%), reward 0.476 -> 0.498 - not "clearly longer": balance is the limit, as Sep 24 said. And
    it would hide part of the servo from the world model (its reference input is the next POSE, not the velocity).
    Off by default; the default servo is bit-identical (robot_track 434 pass; F1's baseline reproduced exactly).
- **F3b THE PAPER'S FAILURE RULE (from the comparison, Sep 27).** The paper ends an episode when the HEAD's height is
  more than 25 cm off the reference's head - and only after a MINIMUM of 48 frames (0.8 s); max 512 frames; the drift
  variant adds root 1 m / 90 deg. Ours has five limits (root, mean height, tilt, mean pose position and rotation) and
  an 8-frame grace - and the T3 revisit saw the gradual ones end rises that lag the reference. The paper's is simpler,
  and clip-agnostic (every humanoid has a head). DESIGN: a head-height limit (the head named per robot, resolved like
  `contact_exempt`) and a minimum episode length, as `Termination` fields; the judge and the fleet unchanged.
  MEASURE with F1's judge, servo alone and the teacher, on `dance_5_15` (and the get-up, for Phase C): the paper's rule
  (+ root 1 m / 90 deg, which we keep - Simon's root-motion requirement) against ours. DECIDE the night's rule on it -
  the rule defines what every later step optimises, so it is settled before them.
  - DONE (Sep 27): ADOPTED. `TrackingError.head_height` / `Termination.head_height`, `Task.head_body` resolved per robot
    (`headBody`, sharing `bodyIndexByName` with the feet exemption), `trackingErrorWithHead` (the judges ask it;
    `trackingError` is it with no head). Measured: servo alone, dance 1.61 -> 1.53 s, get-up 2.89 -> 2.75 s; the
    teacher on the dance 1.56 -> 1.66 s - equally strict (both fail by falling, and the head says so), so the simpler,
    published rule wins: head 25 cm + root 1 m / 90 deg, everything else off. The F1 baseline is now 1.53 s.
- **F3c THE PAPER'S PHYSICS RATE** - DROPPED (Simon, Sep 27: physics stays at 60 Hz, the policy acts at 30 Hz, for
  now). Kept for the record: the paper simulates at 240 Hz with 20 solver iterations -
  four physics steps a 60 Hz frame; we step once. The servo's spring, the contacts and every balance margin are
  stiffer and more accurate at 240 Hz. DESIGN: substeps per frame as a simulation option (the servo re-evaluated each
  substep, as a PD controller in a 240 Hz simulator is). MEASURE: the servo alone on the judge at 1, 2 and 4 substeps,
  and the CPU cost of each. If the servo lasts clearly longer, every learner's problem gets easier - the cost (~4x the
  physics) is decided against what the probe says the desktop can sustain.
- **F4e THE POLICY'S CLOCK - 30 Hz decisions (Simon, Sep 27).** Found checking it: SuperTrack here acts EVERY physics
  step (60 Hz, as the paper does); DReCon and our PPO decide every second step and hold. Simon: 30 Hz. The world model
  stays per physics step (60 Hz physics, learned from the actions actually applied - the replay records them); the
  POLICY decides on even episode steps and holds through the odd ones - in collection, in its training rollouts
  through the model (the same noisy action reused for the held step, gradients through both; a 32-step window is 16
  decisions, the same 0.53 s), in the judge and in the diagnostics. The goal a decision sees is the next frame's, as
  now. An option, `decide_every` (1 reproduces today exactly); 2 on the pages and the night. CPU learner first (F10's),
  the kit's rollout kernels before R/ON.
  - CPU DONE (Sep 27): `LearnerOptions.decide_every`; `Learner.decides(fleet, env)` - even steps of the episode;
    collecting leaves a held slot alone; the rollout graph reuses the decision's Var (penalties on decisions only,
    smoothness between consecutive decisions); `modelLoss`, `diagnose` (real and model loops) and the judge's actor
    keep the clock (the judge's persistent action buffer makes "not writing" the hold). Known answers: odd-step
    actions equal the previous step's exactly, held rollout steps are the decision's own node, the actor on an odd
    step leaves a poisoned buffer untouched. robot_latent 440 pass, every older test unchanged (default 1).
  - KIT NEXT (before R/ON): the resident learner's collection and the kit's rollout kernels on the same clock, with
    CPU-vs-kit parity at decide_every = 2.
- **F4 THE PAPER'S INPUTS AND LOSSES** - cheap, host-testable, no scale needed: the normaliser measured FROM THE
  CLIP's reference frames (S4: deterministic from step 0, no dependence on a few seconds of falling), L1 losses
  (S3), exploration noise in the paper's units (S5: 0.21 rad an axis vs ours 0.06).
  - F4a DONE (Sep 27): `latent.measureClipNormalizer(m, clips)` - every frame posed as the fleet poses a reference
    (`resetToFrame`), the same local features; one `Moments` accumulator shared with the replay version (the spread's
    floor defined once); `WorldOptions.normalize_from_clips` (off by default, earlier measurements reproduce);
    geno_train normalises from its clip. Known answer: a clip's normaliser makes its own frames mean 0 / variance 1
    (floored features exactly 0), identical twice. robot_latent 438 pass; geno_train smoke green, leak-free.
  - F4b LOSSES AS THE PAPER DEFINES THEM (sharpened by the comparison): L1, and in the paper's SPACES - the world
    model's in WORLD space (position, velocity, rotation as the log of the quaternion difference, angular velocity),
    the policy's in LOCAL space PER GROUP (position, velocity, two-axis rotation, angular velocity, height, up) - not
    one loss over normalised features (which weights every feature by 1 / its variance: fast ones count less). Weights
    set so each group contributes roughly EQUALLY at the start of training (the paper's procedure: measure the terms
    on the first batches, set 1 / magnitude); the offset penalties L2^2 + L1, two orders of magnitude smaller. A graph
    op and a kit kernel for L1 (`l1_bwd`), parity CPU vs kit.
  - F4c THE OFFSET SCALE AND NOISE: the paper's alpha = 120 degrees a unit (2.09 rad; ours 0.6) with sigma = 0.1 of a
    unit (0.21 rad; ours 0.06), output unbounded and penalised (as ours). Judged on the CPU learner's curve - the
    paper's values are the default to beat, not an assumption.
  - F4d THE OPTIMISER: gradient clipping (the paper: it "helped somewhat"; the unofficial code: 25 world, 100 policy),
    a warm-up and a decay for a 10-hour night, the paper's policy rate (1e-4; the kit has 3e-4). RAdam vs Adam noted,
    not changed unless the curve asks.
- **F5 A FEASIBLE REFERENCE - the dance made physically possible, baked (Simon, Sep 27).** The idea is SAMCON's (Liu
  et al. 2010: a sampling search that turns a mocap clip into an open-loop control trajectory the simulator can
  actually perform) and "Guided Learning of Control Graphs" (Liu et al. 2016: learn only the FEEDBACK around such
  trajectories). Mocap is infeasible in small ways - feet slide and sink, balance came from a human's hidden
  corrections, limbs overlap - so today a learner must find both what is possible and how to stay on it. With a
  feasible reference a perfect tracker exists by construction, and the learner's job is feedback: returning to the
  trajectory from its own noise, and later from pushes.
  - THE SEARCH: offline and deterministic (`ServoRun.save` / `restore` are bit-for-bit), much stronger than the
    online teacher (which holds ~2 s): short windows, many samples each, a BEAM of the best few states rather than
    one, and BACKTRACKING - a window that fails steps back and resamples the one before (SAMCON's core). The task's
    rule is the constraint; the cost is STRICTER on shape than the online teacher's (whose balance swings reach
    0.7 m - they must not be baked into the dance). Tens of minutes per 10-second clip on one core; one-off.
  - WHAT IS SAVED - TWO channels: the ACHIEVED states (the new reference: tracking error, starts, the judge,
    observations) and the servo TARGETS actually used (mocap pose + planned offsets: what the servo aims at, and the
    world model's reference input). The clip format gains the second channel (optional; the fleet uses it when
    present); `robot_clip_bake` writes it and reads it back, as it does today.
  - KNOWN ANSWERS: the bake reads back identical; replayed open-loop from frame 1 the servo alone reaches the clip's
    end with zero error (deterministic); from every judge start (the achieved state) the servo alone reaches the
    end - the judge's MTTF is the whole clip. FIDELITY to the original mocap is REPORTED (mean pose / root / worst
    body deviation) and the bake is accepted only if small - the dance must still be the dance.
  - Then the learner's baseline changes meaning: the servo alone is perfect from exact states and fragile off them;
    the judge (F1) and trust / exploitation (F2) measure exactly the feedback the learner adds. F10's mini-run trains
    on both clips (original vs feasible) - the A/B decides the first night's clip.
  - For the ~100 clips later: a bake per clip, offline - a night of the desktop's cores, once.
- **F6 SIMON'S FILTER IN THE GRAPH (S8).** The policy sees the last applied action; y = 0.2 a + 0.8 y_prev in the
  graph, differentiated exactly; the world model sees the APPLIED targets. The world model then learns the
  character's real input - today it sees the policy's raw request, not what the servo received.
  - F6a DONE (Sep 27) - the filter itself: `robot_track.filterAction` (ONE definition; DReCon's controller now calls
    it); `LearnerOptions.filter` (1 = none, and then no filter ops in the graph); `Learner.decideInto` - the one
    definition of a decision (policy, noise when asked, no non-finite action, rest at an episode's start, the
    filter) used by collecting, the judge and `diagnose`; the rollout graph blends with tensors from the replay's
    applied action before the window (`appliedBefore`; rest across a segment start); `modelLoss` and `diagnose`'s
    model loop keep the filter's state too. The world model learns from the APPLIED action. Known answers: 0.2 from
    rest gives 0.2 / 0.36 / 0.488; with noise off, the graph's loss equals the same rollout row by row (policyRow,
    filterAction, stepRow) within 1e-5, holds and the starting state included. robot_latent 442 pass.
  - F6b NEXT: the policy SEES the last applied action (DReCon's observation does) - a first-layer block, so the
    parameter layout the kit mirrors changes; CPU first, parity with the kit when the kit takes the clock.
- **F7 DRIFT (S11).** The policy's input gains the reference's place and heading relative to the character; the
  loss penalises the root's world offset. The task holds the root (1 m / 90 degrees): a policy that cannot see drift
  cannot correct it, and the teacher's runs showed drift ending dances (T4).
- **F8 WINDOWS, DATA, SCALE (S1, S2).** Policy window 32, a buffer of >= 30 s of data, batch 256-1024, and the nets
  the desktop can train - on the CPU twin at moderate size for F9/F10, the kit at full size for R/ON.
- **F9 THE WORLD MODEL'S FORM (S7)** at that scale - acceleration + integration vs our latent residual, equal compute,
  (the paper's form starts, untrained, as CONSTANT VELOCITY - a better prior than "nothing changes"; its ablation
  shows accelerations beating velocities; it names a latent + physical integration as future work - ours is latent
  without the integration),
  judged by F2's numbers on held-out windows. (Optional, cheap: PRE-FILL the buffer with the teacher's demonstrations
  so the world model starts where tracking happens - compared, not assumed.)
- **F10 A CPU MINI-RUN** (was ON-b, moved here): the recipe scaled down on `dance_5_15`, 20-30 min - the judge's curve
  rising clearly above the servo's, the exploitation index bounded, trust holding. The gate before any GPU night.
- ORDER OF WHAT REMAINS (Simon, Sep 27: "focus on fundamentals") - IDs kept, the order is by what everything else
  stands on: (1) THE ACTION PATH - F4e the 30 Hz clock, F6 the filter in the graph, F4c the offset scale and noise:
  what an action IS, identical in collection, training, judge and page; (2) THE WORLD MODEL - F9 its form (the
  paper's accelerations + integration), with its F4b loss (L1, world space), judged by F2's trust; (3) THE POLICY'S
  LOSS - F4b's policy half (L1 per group, local space, equal contributions); (4) F4d the optimiser; (5) F8 windows,
  data and scale, F7 drift; (6) F5 the feasible reference (data preparation - can run beside); (7) F10 the mini-run.
- CONDITIONAL, only if F2 shows exploitation: S10's control (the policy's learning rate through the world model
  scaled by trust) and S12 (Lipschitz smoothness).

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

(The reference list of SuperTrack's items. Their ORDER is Phase F's, Sep 27; S13 - the get-up's height term - is
Phase C.)

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

### Phase R - Runs: launch, snapshot, restore, test, compare (Simon's workflow, Sep 27)

The rhythm: ONE run a night on the laptop, tested in the morning, the next one prepared during the day. Old school
- no cloud, no parallel sweeps. Programmatic setup is fine; the page's UI is for runtime things: load and save,
train or test, pause, watch, curves.

**What MimicKit does (studied Sep 27, `mimickit/run.py`, `learning/base_agent.py`, `tools/plot_log`).** One program,
`--mode train|test`. Every setting lives in three YAML files (engine, env, agent) bundled by an `--arg_file`,
overridable on the command line. A run's `--out_dir` DESCRIBES ITSELF: training copies the three configs into it,
beside `model.pt` (overwritten every `iters_per_output`), `log.txt` (tab-separated columns) and, optionally, every
intermediate `int_models/model_<iter>.pt`. EVALUATION LIVES INSIDE TRAINING: every `iters_per_output` iterations
`test_model` runs test episodes (the deterministic policy, no exploration, the env in TEST mode), and
`Test_Return` / `Test_Episode_Length` go into the log beside the training stats - the curve always says how the
policy does when TESTED. Testing is the same program: `--mode test --model_file ...`, a few envs, the viewer (Enter
pauses, Space single-steps). Runs are compared by overlaying their `log.txt` files (`plot_log.py`: x Samples,
y Test_Return). Its `model.pt` is the module's state_dict - weights and normalisers, NOT the optimizer's moments,
the iteration or the sample count: its "resume" is a warm start (Adam cold, counters from zero).

**What we keep, and where we go further.**
- A RUN is the unit. What DEFINES it is code - a `RunConfig` (Zig, typed, like MimicKit's arg_file + YAML): the
  task, the learner and its hyperparameters, schedules, clips, seed, snapshot cadence. What it PRODUCED is data -
  a snapshot zip. A snapshot alone is enough to test the run or continue it (it carries its own config).
- Continuing is the SAME run, not a warm start: the snapshot holds the Adam moments, normalisers, counters, RNG
  state and start-sampler statistics too. Known answer: N iterations, snapshot, restore, M more == N + M straight.
- Evaluation inside training, as MimicKit: every few minutes the JUDGE (fixed starts per clip, mean actions, no
  exploration, no learning, the servo alone on the same starts as the baseline) - survival per clip - is a curve,
  and the same judge is the morning's test table.
- Compare = load one run's zip at a time: its judge table, its curves, its policy to watch.

**Simon's day, as the page presents it (`geno_night`, ON-a):**
- EVENING - launch. The header shows tonight's RunConfig (name, a one-line summary, its compatibility hash).
  "New run", or drop a snapshot zip and "Continue". Train is HEADLESS: nothing rendered but a stats strip and the
  curves (the GPU is the trainer's). The Screen Wake Lock is held while training; the tab must stay visible (a
  hidden tab stops the frame loop - the page says so, and logs the time lost if it happens). Checkpoints go to the
  browser's private file store every 10 minutes, so a crash or a reload resumes the run by itself.
- ANY TIME - Test. One button: training PAUSES (the run is untouched), the current policy runs deterministically
  on a chosen clip from a chosen frame (the get-up from lying), 1-4 characters rendered, a shove button, slow
  motion, pause and single-step. Back to Train resumes exactly where it stopped.
- MORNING - read and keep. Pause. The judge table (survival per clip against the servo's), the night's curves
  (zimr's plot system: survival per clip, reward, losses, trust, the exploitation index, iterations/s), watch the
  dance and the get-up. "Save snapshot" downloads `geno_<run>_<date>_<iteration>.zip`.
- DAY - prepare. Next run's RunConfig in code, with Claude; build the page. To compare, drop an older zip: it loads
  in Test mode with its own curves and table (one run at a time; the last few loaded runs' one-line summaries are
  remembered for the header). "Continue" is offered only for a compatible snapshot.

**Code or UI - where each setting lives.** CODE (a new build to change): the task, the nets' shapes, the
observation, learning rates and their schedule, batch sizes, windows, losses, the perturbation ramp, clips, seed.
UI (runtime, each change time-stamped into the run's event log, so the snapshot records it): train / test / pause,
rendering, the step budget per frame, the test clip, start frame and character count, shove now, snapshot now. A
snapshot is CONTINUED only by a build whose shape-defining fields match (the compatibility hash); a mismatch is
refused with the fields named. Changed schedules and hyperparameters may continue (they are the day's "next run
from last night's weights").

**The snapshot (a zip; entries STORED - weights barely compress; the reader also takes DEFLATE, so a zip re-made
by an OS tool still loads):**
- `run.json` - the RunConfig as written, the build id, the format version, the compatibility hash.
- `state.bin` - a versioned binary: each learner's networks, optimizer moments, normalisers; iteration, samples,
  wall time; RNG states; the start sampler's statistics (T5).
- `curves.csv` - the per-minute rows (ON-a's list) and the judge's rows.
- `events.log` - mode switches, UI changes, checkpoints, NaN restores, hidden-tab gaps - time-stamped.
- `README.txt` - a human summary: run, dates, iterations, the last judge table.

**What exists and what does not (checked Sep 27).** The bridge has `localStorage` persistence (strings, ~5 MB - far
too small for a snapshot), a drag-and-drop upload queue (`js_userfile_*`, `runtime.loadDroppedFiles`) and a
click-to-download anchor (`ufOffer` - browsers only allow a download from a user click); zimr has an ImPlot-style
plot system (`plot.zig`, `plot_ui.zig`); CRC-32 and inflate come from std. NOT there: a store for large binary data -
ON-a's "IndexedDB via zimr's storage" named something that does not exist. The browser's Origin Private File
System (OPFS) is the fit: large binary files, private to the page's origin, surviving reloads and crashes.

**Steps.**
- R1 `RunConfig` + its compatibility hash + the snapshot format (run.json, state.bin, curves.csv, events.log),
  host-tested: the round trip, and the continuation known answer on a CPU mini-run.
- R2 The zip writer (stored entries) and reader (stored + deflate), host-tested against zips made by other tools.
- R3 The bridge: an OPFS store (write, read, list, remove - asynchronous, completion polled per frame), the Screen
  Wake Lock, page-visibility events; downloads through the existing anchor, uploads through the existing drop
  queue plus a file-picker button.
- R4 The page's modes: Train (headless) / Test / Pause, exact (a test changes nothing in the run); the judge every
  few minutes feeding the curve; checkpoint and auto-resume.
- R5 The UI: run header, mode buttons, test panel (clip, frame, characters, shove, speed, step), curves (`plot_ui`),
  the store's snapshots (load, download, delete), the drop zone for a zip.
- R6 A 30-minute rehearsal of the whole cycle (folds into ON-c): toggles, a reload mid-run (resumes), download the
  zip, drop it back, continue, test.

**Decisions (asked one at a time):** U1 the night's store - DECIDED Sep 27: OPFS. U2 the code/UI split
above - especially whether learning rate and perturbation scale should be UI-tweakable mid-run. U3 which changes
may CONTINUE a snapshot. U4 testing pauses training (recommended - the GPU is shared, and a test must not change the
run) or runs beside it. U5 the hidden tab: wake lock + stay visible (recommended) or training from a worker (a large
change). U6 snapshot cadence and how many the store keeps.

### Phase ON - the night

**ON-a The desktop page** (`geno_night`, from geno_train):
- Learner: SuperTrack as Phase F leaves it - PPO (Phase P) as a second page later, same task, for an A/B night.
- THE FIRST NIGHT (reordered Sep 27): `Motion.dance_5_15` ONLY, uniform reference-state starts, NO perturbations -
  the problem Phase F fixed. Termination `task_termination` with a window's grace; reward `task_weights`. The
  get-up, adaptive starts (T5), perturbation ramps and more clips are Phase C - later nights.
- Scale chosen BY THE MACHINE: a 60 s start-up probe times an iteration at candidate widths/depths (3 x 256,
  4 x 512, 5 x 1024) and batches, keeps the largest at >= 5 iterations/s (a night >= 150k iterations, the paper's
  full count); characters as many as the CPU sustains at >= 1,000 samples/s.
- Unattended: a checkpoint every 10 min (Phase R's snapshot: weights, Adam moments, normaliser, iteration, sampler
  statistics) in the browser's private file store (OPFS - Phase R; there is no zimr IndexedDB storage), resumed on
  reload; on a non-finite loss or weight: restore the
  last checkpoint, halve the learning rates, carry on (logged); GPU backpressure as today.
- Curves every minute (on the page and a downloadable CSV): survival per clip (the paper's metric), reward per
  clip, world-model loss, trust (e_val / e_0, cosine), the exploitation index, iterations/s, samples/s, GPU-bound
  share, start-sampling shares per clip.
- Phase R's modes: Train (headless) / Test (training paused; the current policy on a chosen clip from a chosen
  frame - the get-up from lying) / Pause; the judge every few minutes as a curve; snapshots to download and load.
- Headless: smoke green; 800 frames flat memory; handles balanced under the log cap.

**ON-b A CPU mini-night** - MOVED to Phase F (F10), on the 10-second dance.

**ON-c Simon's 30-minute desktop rehearsal** - the checklist: iterations/s and samples/s as the probe chose;
survival and reward curves moving; trust rising; exploitation index small; no NaN restores; memory stable.

**ON-d The night.**

**ON-e The morning protocol:** download the CSV; survival curves per clip vs the servo's; watch the dance and the
get-up from lying; read trust and the exploitation index across the night; decide: another night (what changes),
Phase A, or back to a phase.

### Phase C - Curriculum (after F, R and the first night)

Once SuperTrack trains well on the 10-second dance: T5 adaptive start sampling (where it fails, it practises; every
clip keeps a floor share); the get-up (`Motion.getup` beside the dance; S13, the height term's weight with both
motions); perturbations ramped (`d5_start_noise` on half the resets, shoves); then more clips toward the ~100.

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

- Task (the FIRST night): `Motion.dance_5_15` only; `task_weights` (gate 0.2 m / 0.5); `task_termination` -
  SuperTrack's rule since F3b: the head 25 cm off the reference head's height, the root 1 m / 90 deg, nothing else;
  grace max(48 frames - the paper's minimum episode - , the policy window); uniform starts; no perturbations. (Later nights, Phase C: adaptive starts - T5: 1 s bins, floor
  0.2 of uniform, temperature 1 - and perturbations after hour 1: `d5_start_noise` on half the resets; shoves every
  ~3 s at ~0.4 m/s.)
- SuperTrack: windows 8 / 32; batch 1024 / 512 (or the probe's); widths the probe's; lr 1e-3 / 1e-4; L1 losses;
  noise 0.21 rad an axis; offset penalties L2 0.01 + L1 0.01; CAPS smoothness 1; the filter in the graph; the
  trust gate on; one world step and one policy step an iteration (two world steps when trust falls).
- Checkpoints every 10 min; CSV every minute.
