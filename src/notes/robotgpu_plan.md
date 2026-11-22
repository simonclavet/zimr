# robotgpu - the SuperMimic foundation - the plan, v4 (Nov 22, 2026)

STATUS: FINAL, THE OFFICIAL VERSION (Simon, Nov 22: "agree. Make this plan the official version, but don't start work
on it yet"). Every decision is settled (section 10). Nothing in section 5 starts before Simon's go.

v3 (Nov 6 - Nov 22) is archived in `src/notes/archive/robotgpu_plan_v3.md`, v2 and v1 beside it. The tracking plan,
`rl_track_plan.md` (v6, Nov 2), and its journal are archived there too (V1): since Nov 6 this plan has been the
tracker's as well as its simulator's. This version summarises v3 (section 1), keeps what is in force (section 2), says
where the work stands (section 4), and is precise about what remains (section 5): the SuperMimic foundation finished
and checked against BlinkMimic's own curve, then our ideas on top of it, one at a time.

v3's names - its C1-C19 (the night's components), O1-O7, H1-H8, I1-I26, X1-X10, L1-L5, W1-W6 and 4j's S1-S4 - are
history, cited as "v3's I5". The names in force are 4q's - C1-C9 (the choices), S0-S9 (the foundation's items), T1-T9
(ours on top), B1-B6 (the brainstorm's) - with S4's D1-D4, and this version's T10, T11 and V1-V4 (section 10).

## 0. The goal

THE GOAL (Simon, Nov 15): beat SuperMimic - from a couple of minutes of motion capture, not its hours - on training
time, tracking quality, robustness, and a fluid return from very large perturbations: where SuperMimic's episode ends,
pushed hard or fallen, ours finds its way back to where the reference has got to. Our minute is a dance, a get-up, a
walk and a run, also played mirrored and at 0.8 and 1.2 times its speed.

THE WAY (Simon, Nov 20): SuperMimic first, as BlinkMimic's PRESET[main] runs in XMimic - THE FOUNDATION - checked
against BlinkMimic's logs iteration for iteration (section 4's bar); then our ideas on top, each a "+X" run kept only
when both its seeds beat both of the foundation's (C6).

AFTER IT (the tracking plan's GT4 and GT5): the tracker trained in the browser, and the result shown as one page.

THE SCOREBOARD, at equal minutes, on the original clips (the variants are trained on, never judged), judged by the CPU
twin with the weights the device trained:
  (a) the active minutes to SuperMimic's success: every judged clip completed and their mean normalised return 0.82 or
      more, held for three judgements in a row (4 replicas a clip). Across our two GPUs it is read in iterations; in
      minutes only between runs on the same GPU, which each run's console names (V4);
  (b) the tracking error's mean and 90th percentile, and BlinkMimic's quality columns;
  (c) the return rate under pushes of 1 to 5 m/s;
  (d) the return rate and time from starts in trouble;
  (e) the action rate and the root's jerk during the returns.

THE GATES, kept from v3:
  G1 the CPU twin equals robot.zig, and the CPU fleet, bit for bit wherever both have the feature;
  G2 the device equals its twin within each array's bar - on lavapipe, on both RTXs (the 5070, the 5060 Laptop GPU),
     on WebGPU;
  G3 parity with MuJoCo where robot.zig lacks the feature, against real MuJoCo's fixtures;
  G4 the throughput measured;
  G5 THE TRACKER TRAINS ON IT;
  G6 every row of v1's parity table done or declined with a reason.
G1-G4 and G6 hold for everything built (section 1). G5 is this plan's question, and it is still open.

## 1. v3, summarised

v3 set out to build THE NIGHT: one training run on the RTX, with every idea on and everything on the device. It built
that piece by piece (Nov 6-19) and ran it: the dry run (Nov 19), then the three hours (Nov 20). Nothing in it learned
to track, and on Nov 20 it turned to building SuperMimic's own recipe first (v3's 4q).

WHAT IT BUILT. Every piece was checked: the twin against the CPU fleet bit for bit, the device against the twin within
bars on lavapipe and the RTX, and its WGSL through Tint.
  THE TASK ON THE DEVICE (Nov 6-12).
    - The judgement, defined once in robot.zig and called by the fleet and the kernels: the tracking error, SuperMimic's
      reward whole (`superMimicTrackingOver`, generic over a body storage), the termination, the episode rule
      (`judgeEpisode`) and the effort.
    - The starts: draws by counter, resets, rest on the floor, starts in trouble and pushes, with SuperMimic's start
      curriculum in bins of 1 s.
    - Rotation boxes for Geno's ball joints, which the servo's targets are clamped into.
  ACTING ON THE DEVICE.
    - The policy's inputs, the kit's layers over rows, exploration by counter, the decision filter and the applied
      action, all as one call (`Sim.actWithKit`).
    - The closed loop, twin and kit against the trainer and fleet, bit for bit over 60 decisions.
  RECORDS AND THE TRAINER ON THE DEVICE (Nov 13-17).
    - The replay's ring and its books, from the device's own counters.
    - `geno_trainer` and its run folder: run.zon, log.csv, time.csv, kernel_times.csv, judge.csv, status.zon,
      checkpoints and resume.
    - A round fed by the device equals one fed by the host within 7.78 epsilons.
  THE LEARNERS' PARTS (Nov 13-20).
    - The physics teacher (lookaheads, knots, `PlanFollowing`), its labels, and the gate.
    - The variants: baked mirrored clips, with Geno made symmetric, and the speeds.
    - Pushes by rule.
    - The skip model (two heads, skip batches, consistency) and the planners through it.
    - Muon, and the root target.
    - SuperMimic's success in the judge, and the policy's slow average.
    - Running input moments.
    - The blocked product, and the two-pass statistics (a round's statistics from 49.6 s to 0.79 s).
    - The teacher on the device.
  THE LAB AND THE CHECKS.
    - `geno_lab` follows the newest policy; `geno_trainer --report=` sets runs side by side; the tripwires
      (`lab.Tripwire`) stop a run that cannot learn.
    - vk-host-test runs as test blocks over a coverage ledger: 61 of 61 robotgpu kernels have been dispatched on the
      device. Every kernel is in a program, and every entry point is scanned.

WHAT IT MEASURED.
  SPEED: 8,436 world-decisions a second at 1,024 worlds on the RTX, with `newton_solve` 85-90% of the physics. Training
    then ran at 1-2% of the f32 peak, measured before the blocked products.
  LEARNING, THE THREE HOURS (Nov 20; 13 minutes a run; runs 1-4 of 12). The judged time to a loss: the servo 2.25 s,
    plain SuperTrack 1.29 s, the control 0.88 s and 0.65 s (seed 2), the teacher's labels alone 0.74 s. NO LEARNED
    POLICY BEAT THE SERVO.
    - The world model's error was 60-75% of the no-change model's, against the gate's bar of 25%.
    - Its answer to an action was 1-5% of the physics'.
    - The teacher's plans beat their baseline 2 times in 88.
    Read against BlinkMimic's logs, those 13 minutes were its iterations 55 to 175: too few to show what the recipe can
    do. They were enough to show ours climbing a world model's wrong gradient, with the policy ending worse than the
    servo it started as.

THE FOUNDATION SO FAR (v3's 4q, Nov 20-22). S0 to S3 are built.
  S0 THE TRAINER CHECKS ITS KERNELS AT ITS START. It runs them on the learner's own pipe against the pages' CPU twin,
     15 sequences today, and refuses to start past the bar (1e-5), naming the sequence, the field and its worst value.
  S1 THE WORLD MODEL AS SUPERMIMIC's.
     (a) Its loss in units of each feature's one-step change: the change's running spread over the collected
         transitions, floored by kind at XMimic's floors.
     (b) Its output standardised by the change's running moments.
     (c) Every input column normalised by its running moments (`lat_world_moments`).
     (d) The normed form - 3 x 1,024, linear, layer norm, SiLU, torch's initialisation, the last layer zero - as the
         only form. The tanh form stays only as the skip head's trunk.
     (e) MuonAdam at 4e-4, with Muon's decay 0 and the gradient bounded at 1.
     (f) Its log in its own units: the mean step, the last step and six kinds of feature, beside the bound's share
         (turn 1).
  S2 THE DATA AS XMIMIC's.
     (a) The world model's windows of 8 from any record, the falls' included (turn 2).
     (b) The policy's starts as single records, the last horizon before a fall among them, their goals from the clip's
         tables (turn 4).
     (c) The ring in a buffer of its own, the eighth binding (turn 3).
     (d) The warm-up: 256 decisions (turn 2).
  S3 THE ITERATION (turn 5), halved to fit the trainer's 2 GB of activations (C1).
     - 10 decisions collected, then 10 updates of the world model on 1,024 windows of 8 and 2 of the policy on 1,024
       starts of 20 decisions, each rate over the square root of 2.
     - The policy's rate x4 for 1,400 iterations, then a ramp to 1 over 300 (`RateBoost`). Only the bound is built:
       the return trigger is in 5.4.
     - The foundation's recipes (`recipes/foundation/`).
  Turns 1-5 were written on the Windows machine and built there by Simon. Their journal entries are v3's last.

## 2. What is in force

THE PRINCIPLES (v3's P1-P8):
  P1 follow MuJoCo Warp closely;
  P2 understandability: one descriptive vocabulary, the code read like a course;
  P3 one definition of the arithmetic: a kernel calls the CPU's own function, moved to robot.zig where both need it;
  P4 deterministic by construction: no float atomics in state, draws by counter;
  P5 web and native both first-class;
  P6 agnostic to measurement;
  P7 each component checked before the next;
  P8 the diagnostics built with the components.

THE RULE (Simon, Nov 20): THE FOUNDATION IS BLINKMIMIC's PRESET[main] AS XMIMIC RUNS IT; where BlinkMimic says nothing,
the official SuperMimic. Inside the foundation a deviation needs evidence. Everything of ours comes back on top, one
part at a time, as a "+X" run against the foundation's two seeds.

NO OLD BEHAVIOUR (Simon, Nov 21: "we never need backward compatibility: we never tried anything").
  - Each S item's result is THE behaviour, the learner's only form, and what it replaces goes: no option for the old
    way, and no default kept for packages already sent.
  - Options are for our ideas (the "+X"s) and for the method's own constants.
  - Working first try means each piece is checked where it is built.
  - THE ONE EXCEPTION, the foundation's four ablations (V3, Simon, Nov 22): each keeps one option for the form it
    ablates (5.4).

THE DEVIATIONS KEPT INSIDE THE FOUNDATION, each with its reason:
  - The state is the character's features, with no observation history and no sensor noise: a game character reads its
    own state.
  - No domain randomisation.
  - f32 products, where XMimic's are bf16.
  - Our physics, body and clock: 30 Hz decisions over 60 Hz physics, so time is kept in seconds and volume in records
    (C2).

THE CHOICES THAT RAISE OUR ODDS (4q's C1-C9):
  C1 OUR ITERATION IS XMIMIC's, IN RECORDS AND BATCHES: 10 decisions of 1,024 characters, then 5 updates of the world
     model on 2,048 windows of 8 and one of the policy on 2,048 rollouts of 20.
     - Where 2 GB of activations hold only half, both batches are halved, their updates doubled, and each rate divided
       by sqrt(2). This is the first check's form: XMimic's 2,048 rows would need about 680 million floats, past 2^29.
     - Never fewer records an update than XMimic's.
  C2 TIME IN SECONDS, VOLUME IN RECORDS:
     - the horizon 0.67 s (20 decisions);
     - gamma 0.983 and lambda 0.918 a decision;
     - the goal's frames 0.2 s (6);
     - the drift weight 0.75 at two physics steps a decision;
     - the warm-up 262,144 records (256 decisions);
     - the replay 20 s (600 decisions), which holds 60 of our iterations' data where XMimic's holds 400.
  C3 THE MOMENTS BEFORE A FALL ARE IN BOTH NETWORKS' DATA (S2).
  C4 ONE CHANGE OF MEANING AT A TIME: the first check changes the world model, the data and the iteration, and nothing
     the policy is asked; S4 then changes the objective and the action together.
  C5 THE BAR ITERATION FOR ITERATION (section 4), ITS TRIPWIRES AT TWICE ITS MILESTONES' ITERATIONS, SUCCESS AS
     BLINKMIMIC's.
  C6 TWO SEEDS A RUN. A "+X" IS KEPT ONLY WHEN BOTH ITS SEEDS BEAT BOTH OF THE FOUNDATION's, at the same iteration.
  C7 THE KERNELS ARE CHECKED AT EVERY TRAINER START (S0).
  C8 BLINKMIMIC OVER THE OFFICIAL where they differ: Muon's decay 0, the rate 4e-4, and the critic's fit.
  C9 THE SPEED AS THE REFERENCE FOUND IT: Newton's kernels made faster, never its budget cut.

THE CHECKS' RULES (v3's R1-R7):
  R1 seen to fail: a check counts once it has failed on the thing it is for;
  R2 one rule for a gap (`gapInUnits`, `largestGapEpsilons`);
  R3 from one state: the device takes the twin's worlds whole;
  R4 by whole blocks;
  R5 bars from measurements, the devices named;
  R6 a test policy has weights that matter in every layer;
  R7 unchanged means measured: the same printed numbers before and after.

HOW THE WORK GOES ON THE WINDOWS MACHINE (Nov 22):
  - Claude writes the code and checks it with `zig fmt --check`, `zig ast-check` and the built linter. Claude never
    compiles there; Simon builds and runs.
  - Each turn names its own targeted tests. The whole suite and the device test run at a stage's end: the full gate.
  - Every turn shows its new code in the chat, with its file and line, and buttons that open them in Zed.

ONE SETUP FOR BOTH GPUs (V4, Simon, Nov 22: "make sure our setup works on both, without trying too much to optimize
for one of them"):
  - Every recipe fits the smaller device, the 5060's 8 GB: `--layout` before each new recipe.
  - Nothing is tuned for one GPU: one build and one set of sizes, and the same recipes, batch files and checks.
  - The start check (S0) runs on whichever device a run starts on.
  - Runs compare by iteration (V2); minutes only between runs on the same GPU.

## 3. What exists, and where

  the simulator                 robotgpu.zig (its opening map; sections by banner), robotgpu_program.zig (programs)
  its host                      robotgpu_host.zig: `Sim`, submit-then-collect readbacks, `recordMomentsFrom`
  the CPU fleet and the task    robot_track.zig: `Fleet`, `Task`, the tracking errors and rewards, the replay and its
                                books (`Replay.Books`: `sampleWindowStarting`, `sampleStart`, `framesLeftAt`)
  the shared arithmetic         robot.zig: the physics, the servo, the judgement (`superMimicTrackingOver`), the
                                features (`LocalLayout`, `LocalFeatureKind`), `RecordMoment`
  the learner's kit             robot_latent_kit.zig: `LatentKit`, `Resident(M)` (its tables and the ring),
                                `RecordRing`, `DeviceStats` (the device's numbers, read back every round),
                                `KernelCheck(M)` (the device test's and the trainer's start check)
  the learner                   robot_track_resident.zig: `Resident`, the trainer's loop - its windows and starts, the
                                warm-up, the rate boost (`RateBoost`), the critic, the teacher and the planners
  the kernels                   gpu/zn_mlp.zig, listed in gpu/zn_mlp_kernels.zig. Their sizes:
                                - zn_mlp_sizes.zig: the pages, a ring of 2^20 floats;
                                - zn_mlp_sizes_trainer.zig: 2^29 floats of activations, a ring of 5 x 2^26;
                                - zn_mlp_sizes_trainer_portable.zig: a ring of 2^25.
  the layout's checks           kit_mlp.zig: `KitLayout`, `reserveRing`, `checkFitsKit` (`KitRingTooSmall`)
  the run's files, shared       robot_lab.zig: the run file (`GenoRun`), `SuperTrackLearner`, the logs
                                (`SuperTrackLog.Line`, whose columns follow `DeviceStats` by reflection), `Tripwire`
  the trainer                   tools/geno_trainer.zig: `--run=<folder>`, `--layout`, `--report=`, `--machine-share=`
  the lab and the recipes       examples/geno_lab. The recipes are in examples/geno_lab/recipes/, the foundation's in
                                foundation/ (01 to 03, README.txt, run_first_check.bat); build.zig embeds them
  the checks                    robotgpu_tests.zig: the twin against robot.zig
                                robot_latent_kit_tests.zig and robot_track_resident_tests.zig: the twin against the
                                fleet (the second holds the lab's and the kit's tests too)
                                gpu_learn_tests.zig: the kit's kernels
                                tools/vk_host_test.zig: the device against the twin
                                the pages: through Tint
  the tutorial                  src/notes/tutorials/robot-mocap-tutorial.html: a section for each turn of the foundation

## 4. Where it stands (Nov 22)

THE BAR. These are BlinkMimic's logs, its seed 0; seeds 1 and 2 are close at every row. Our iteration is its iteration
in records and in the world model's updates (C1).
     iteration  records  W loss  W at step 8  survival  episode  falls  eval return (clips failing)
        100      1.3 M     0.75       1.51       0.64     1.0 s    91%       0.003 (40)
        200      2.3 M     0.41       0.76       0.91     4.2 s    84%       0.004 (40)
        300      3.3 M     0.33       0.60       0.96     9.0 s     6%       0.004 (40)
        500      5.4 M     0.28       0.48       0.99     9.6 s     4%       0.56  (16)
      1,000     10.5 M     0.16       0.28       1.00     9.2 s     6%       0.77   (6)
      1,300     13.6 M     0.15       0.27       1.00     9.6 s     6%       0.83   (1)
  W's losses are in its units, S1 (f)'s: comparable in kind but not to the digit, since our state is the bodies' and its
  is the root's and the joints'. Survival is the imagined survival, after the horizon. Falls are the share of the
  training episodes' ends that are terminations.
  THE MILESTONES:
    - by iteration 300, falls under a tenth of the ends and the imagined survival over 0.95;
    - by 500, the judge's normalised return over 0.5;
    - SUCCESS by about 1,500.
  A BAR, NOT A LAW: missing it by twice the iterations says the foundation is not yet SuperMimic's; missing it by a
  fifth says little.
  OUR ITERATION IN THE LOG: log.csv's `world_updates` divided by the recipe's `world_updates` (10 in the halved form).

THE FIRST CHECK: S1-S3 under plain SuperTrack's objective and action (C4). It is `recipes/foundation/`: three runs of 13
minutes by `run_first_check.bat` - 01, 02 (seed 2), and 03 (the three hours' run 2 on today's code).
  ITS FIRST START (Nov 22) passed the kernels' check, then stopped at round 7 on a false tripwire inside the warm-up.
  Fixed: the tripwires now read nothing while the learner warms up.
  THE HAND RUN AFTER THE FIX was run from PowerShell, so with Vulkan's validation on and half the machine. It resumed
  at round 7, and Simon pasted it up to round 79, which is iteration 47.
    THE START CHECK: 15 sequences, the largest gap 3.22e-6 (the bar 1e-5).
    THE WARM-UP: rounds 8 to 32. The ring is not in the state file, so a resumed run warms up again. The servo's time to
      a loss, a running mean still filling, was 2.66 s at round 13 and 1.97 s at the warm-up's end.
    THE WORLD MODEL IN ITS UNITS (the mean step).
      - 4.77 at iteration 3, 2.40 at 7, 1.29 at 15, 1.04 at 19 and 0.85 at 27.
      - Then 0.79 to 0.90 up to iteration 47: FLAT FROM ABOUT ITERATION 27.
      - Its step 8 is about 1.5 times its mean step, where BlinkMimic's is 2.0 at iteration 100.
      - In the clips' units: 0.68 at iteration 3 and 0.43 at 15, then 0.44 to 0.49.
      - EVERY UPDATE WAS CLIPPED by the bound of 1.
    THE POLICY WORSE THAN THE SERVO.
      - The training's time to a loss was 1.97 s at the first update and 1.55 s at iteration 47, shorter at every
        reading after the first.
      - Its tracking loss stayed between 0.66 and 1.03, not falling: the three hours' pattern again.
    THE ROUND: about 6 s while training (5.5 to 6.5 s; the device busy 41-46% of it, the world model's updates 1.4 s),
      and 2.4 to 2.9 s while warming up. At that pace 13 minutes reach about iteration 115: the bar's 100 row, but not
      its 200 (V2).
  READ SO FAR: the world model starts on BlinkMimic's road (its 0.75 at iteration 100) and stops at 0.8. The policy
  fails the PASS's second half unless its trend turns by iteration 100.
  AWAITED: `first_check_results.zip`, from the batch file's three runs with validation off - each run's log.csv,
  status.zon and console.txt.

OPEN BESIDE IT:
  I26, THE KIT CHECK's INTERMITTENT FAILURE.
    - The device test's kit check on this machine (Nov 22) left 44 values of `plan_gather`'s blocks wrong in the
      planner's sequence: the worst was -0.2857, against the twin's 1.097. That is a wrong value, where Nov 21's
      lavapipe run lost a write of 0. Every later sequence then read those values.
    - The trainer's start check passed the same day: 15 sequences within 3.22e-6.
    - Cause unknown. The first check's recipes run no planner.
  THE FULL GATE OF TURNS 1-5 has never been reported whole.
    - Turn 1's targeted tests and vk-host-test: 70 of 74, three of the failures stale tests since fixed in the code, not
      yet run again.
    - Turn 3's `zig build test`: one failure, the pages' ring, fixed.
    - The trainer was built for the first check.
  THE SLOW TESTS (Simon's `zig build test-fast -Dslow-tests`, Nov 22): three failures and three noisy passes,
    diagnosed by reading the code. NOTHING IS FIXED YET (Simon: "stop. Take note in the plan of what you wanted to
    fix"). All of them are slow tests, run only under `-Dslow-tests`, so they went stale unseen. Their fix is one small
    turn, on Simon's go:
    (1) "the judge's actor - zero weights ARE the servo, ..." (robot_track_resident_tests.zig:352), failed without
        output.
        CAUSE: since the slow average (v3's I2, Nov 17) the judge's actor plays `host.judged` (`actOnJudgedFleet`,
        robot_track_resident.zig:5476-5509), and `init` seeds it from the first readback (`syncMirror`, :2503). The
        test zeroes only `host.mirror` (:391), so its "zero weights" judgement plays the seeded policy, not the
        servo. Also, its `host.element_count = @max(learner.data.end, ...)` (:383) can narrow the readback below
        `params_end`: turn 3 made `data.end` smaller by moving the ring out. `syncMirror` then keeps the old weights
        (:2986), so "trained ones act" would judge the seeded policy.
        FIX: zero `host.judged`; widen the readback only, `@max(host.element_count, learner.data.end)`.
    (2) "a planning character acts from its own plan, at the step the stamp says" (:1515): the slices differ, the
        actions found about a quarter of those expected.
        CAUSE: every chosen action reaches the character's slot through the action filter (`giveAction`,
        robot_track_resident.zig:3243-3270), at `Options.filter`, 0.25 by default since Nov 11 (commit f8fb3101). The
        test (Oct 31, commit 73b20aa6) compares the slot with the unfiltered policy row plus the plan's correction.
        FIX: filter the expectation as `giveAction` does - the slot's previous action copied before the step, then
        blended at `options.filter` (`robot.filterAction`; a plain copy at a share of 1) - and set `host.applied` to the
        character's slot before `policyRow`, as `computeAction` does (:3095).
    (3) "planning keeps to its frame - one decision per call, the judge sees the policy alone" (:1622), failed without
        output: one of its bare `expect`s after six calls of eight steps (`decisions_made > 0`, or `slots[0] !=
        null`). Which one is not known.
        CAUSE, probably: the pushed character's first decision, or its slot, no longer falls inside those 48 steps.
        Its last check has (2)'s filter problem too.
        FIX: call `act(8, ...)` until a replan has been made while character 0 plans (`decisions_made >= 2`, its slot
        held), at most 30 calls, each still making at most one decision. Then filter the judged step's expectation
        as in (2). Replace the bare `expect`s with checks that print their numbers (`report.failure`), so a failure
        says which one.
    (4) NOISE: robotgpu_tests' "a world made a copy of another steps as its source does" (robotgpu_tests.zig:2223)
        passes but prints "joint_positions[0]: world 1 0.1026532, world 2 0.1538313". Its seen-to-fail half expects
        `error.WorldsDiffer` (:2261), and `expectWorldsIdentical` prints the first difference before it returns that
        error (:2186, :2208). The comment above the call says world 3 where the call compares world 2.
        FIX: a quiet form that returns the first difference (or null), printed only by the helper that fails; the
        test's second half asks the quiet form.
    (5) NOISE: robot_track's "the recovery probe - a nudge survived more often than a hard push; every loss accounted
        for" (robot_track.zig:6383) prints its bands with `std.log.warn` (:6412, :6431). It runs in robot_lab's slow
        tests and in robot_tests' shard 2, which pass.
        FIX: `report.print`, silent unless `-Dtest-report`.
        ALSO FOUND: the servo reads "survived 0.00" at 0 m/s as well as at 1.5, with one push a band. So the check that
        a nudge is survived more often than a hard push holds only as 0 >= 0, and cannot fail as it stands. It needs a
        setup where the servo survives the nudge (more starts, or the clip not lifted), and an assertion that it does.
  TWO GPUs (V4). Simon's runs go on either of two GPUs, indiscriminately: the RTX 5070 that v1-v3 name, and the
    Windows laptop's NVIDIA GeForce RTX 5060 Laptop GPU (8 GB, 7,899 MB device-local, bindings up to 4 GB). The first
    check ran on the 5060, its buffers 4.6 GB of it (58%), and so did Nov 22's device test with I26's failure. The
    earlier results stand as v3 recorded them.

## 5. What remains, in order

THE ORDER:
  5.1 the first check, read;
  5.2 S4 in five turns, then the second check;
  5.3 S5 to S9;
  5.4 the foundation's runs, with what they need first;
  5.5 our ideas on top, T1 to T11;
  5.6 the speed, beside them all.
Sizes are in turns: about 20 turns up to the foundation's runs. Each turn ends as turns 1-5 did: its code checked by
hand, the tutorial's section written, the plan's journal entry, and Simon's build of the tests the turn names.

### 5.1 The first check, read (now)

  THE RUNS: the batch file's three, each to iteration 200 (V2). FIRST, THE NEXT TURN (SIZE 0.5):
    BUILD  the control `stop_after_training_rounds` (the lab's controls, beside `stop_after_hours`): the trainer stops
           after that many training rounds (`Resident.training_rounds`), the warm-up's rounds not counted; 0 means no
           limit. The first check's three recipes ask for 200, with `stop_after_hours` kept as a cap of 0.5. The
           README says so.
    TESTS  a recipe's control read back; a run with a warm-up stopping at its count of training rounds.
    CHECKS test-robot_track_resident_tests; the trainer built (geno-trainer).
  The runs already made to 13 minutes, if any, read the bar's 100 row. The 200 row needs the runs again.
  READ from each run's log.csv, by iteration:
    - `world_loss` and `world_loss_last_step` against the bar's 100 and 200 rows;
    - the six kinds (`world_loss_positions` to `world_loss_up`): which kind of feature the model fails to predict;
    - the share clipped and the gradient's length before the clip (`world_gradient_norm_mean` and `_most`);
    - the training's time to a loss, against the servo's at the warm-up's end;
    - 03 against 01 and 02: what S1 to S3 changed;
    - 01 against 02: the seeds' noise.
  PASS: the world model's loss in its units falls at BlinkMimic's pace - about 0.75 at iteration 100 and 0.41 at 200,
    in kind - and the training's episodes are never shorter than the servo's after iteration 100.
  WHATEVER IT SHOWS, S4 FOLLOWS: the objective is the other half of the reference. Two readings decide what runs on the
  GPU beside S4.1's writing, with no new code.
    IF THE POLICY FAILS - its episodes below the servo's past iteration 100, as the hand run predicts - run 01 again
      with the boost's multiplier at 1 (a fourth recipe, `04_first_check_boost_1.zon`). It says whether the policy's
      decline comes from its rate or from the world model's gradient. A decline at the base rate says the world model
      still answers the action wrongly, which S4's objective does not change.
    IF THE WORLD MODEL FAILS - flat above 0.75 at iteration 100 - its kinds say which features. B6's column is then
      built in S4.1's turn: each round's exploration variance over the collected actions' variance, pooled over the
      action's numbers. It says whether the model can see an action's effect at all.

### 5.2 S4: SuperMimic's objective, termination, critic and action (5 turns), then the second check

DECIDED (Simon, Nov 22):
  D1 THE REWARD's CODE: the kit's kernels import `robot` beside `zm`, as robotgpu's do. One definition serves the
     fleet, the device's judge and the imagined rollout.
  D2 THE CONTACT TERM (InstantTrack's, weight 0.25) is a "+X" after S4 (T10), not part of the foundation.
  D3 THE IMAGINED ROOT's HEIGHT COMES FROM ITS HEIGHT FEATURE.
     - x, y and the rotation come from the integrated pose; z comes from the root's predicted height at each step,
       written over the pose's before the reward and the soft termination read it.
     - The reason: a height integrated from velocities drifts. 1 cm/s over 20 decisions is 20 cm, near the 0.25 m
       limit.
     - Its gradient goes to the height feature.
  D4 ALL OF S4, ONE CHECK: the action rate's penalty replaces the filter's smoothing, so the objective and the action
     change together.

WHAT THE SURVEY FOUND (Nov 22):
  - `rbt.superMimicTrackingOver` reads each body's world position, rotation, velocity and angular velocity, and no
    joint angles. The imagined features hold all four in the root's frame (`LocalLayout`). So with the imagined root
    pose (P, R), a body is P + R p, R fromTwoAxis(axes), R v and R w. The reference's side comes from its table rows
    the same way. No local-to-world helper exists: it and its backward are new.
  - robotgpu's kernels already call `robot.superMimicTrackingOver` on the device (`judge_rewards`, over
    `DeviceBodies`). The kit's `Bodies` is a type over the imagined blocks, with `lowest` stubbed: `requireBodies` asks
    for it, and nothing here reads it.
  - The imagined root's blocks exist only with `root_target` on. S4 needs them whenever the reward is the objective.
  - CAPS's smoothness (`w_smooth`, the lab's default 1.0, on in every recipe) is a mean over the window's steps on the
    raw action, with no pair to the start's action. SuperMimic's action rate is -0.1 x the summed squared change from
    the action applied before.
  - Our `up` limit measures another quantity than SuperMimic's tilt: ours fires near 47 degrees at 0.8, theirs near 78.
    No field holds the root's height error.
  - The critic's imagined fit reads `Source.steps`, which since turn 2 is the world model's 8: it sees 8 steps of a
    horizon of 20. The first check has no critic. S4.4's critic reads the whole horizon.

  S4.1 THE REWARD ON THE IMAGINED STATES, FORWARD.
    BUILD  - the `robot` module beside `zm` for the kit's kernels (build.zig, as for robotgpu's);
           - `zn_mlp.ImaginedBodies`: a `Bodies` over a row's imagined features at step k and its imagined root pose.
             The root's own body comes from the pose, not its features, with D3's z.
           - the reference's bodies likewise, from table row k (its features and its root pose);
           - `lat_super_mimic_reward`: one thread a (row, step), `superMimicTrackingOver` of the two, its six terms and
             its total written into acts;
           - the imagined root's blocks whenever `Options.policy_objective` is `.super_mimic_reward`. That option is
             new, and `.supertrack_distance`, today's objective, stays the default until S4.5;
           - the reward logged as `policy_super_mimic_reward`; nothing trains on it yet.
    TESTS  - the kernel's reward against `superMimicTrackingOver` on the host's own bodies for the same states: a
             fleet's recorded states encoded as features and posed back, to rounding;
           - each of the six terms;
           - a root at rest, and a root turned;
           - the root's z equal to its height feature.
    CHECKS test-gpu_learn_tests; test-robot_latent_kit_tests (the module's new import); the start check's sixteenth
           sequence (the reward), in test-robot_track_resident_tests.
    TUTOR  "The reward in imagination".
  S4.2 ITS GRADIENT, AND THE ACTION RATE.
    BUILD  - the hand-written backward of the six terms into the imagined features and the root pose: through
             `integratePoseBackward` into the root's velocity features, and D3's z into the height feature;
           - with `.super_mimic_reward`, the policy's loss is minus the mean reward over the rollout, in place of the
             features' squared distance;
           - the action rate on the raw action, -0.1 x the summed squared change. Its first pair is with the action
             applied before the start (`start_actions_at`). Under that objective it replaces CAPS (`w_smooth`) and the
             action's price (`w_action`).
    TESTS  every gradient against zimrnum's graph of the same arithmetic, at states near and far from the reference.
           Finite differences where the graph lacks an op: the heading's atan2, and angleBetween's asin.
    CHECKS test-gpu_learn_tests; test-robot_track_resident_tests.
    TUTOR  "The reward's gradient, and the action rate".
  S4.3 THE TERMINATION, THE SOFT TERMINATION AND THE SURVIVAL.
    BUILD  - `TrackingError.root_height` and `.up_vertical` (SuperMimic's quantities), with their `Termination` limits;
           - the metres' scale s: Geno's standing root height (the clips' median standing frame) over the G1's 0.76 m;
           - a training termination of those two alone;
           - the judge's failure the same, with ours (losing the reference) counted beside it;
           - `superMimicSuccess` held for three judgements;
           - on each imagined state, d = 1 - (1 - sig((e_z - 0.25 s) / 0.02 s)) (1 - sig((e_tilt - 0.8) / 0.04));
             the survival is its running product, and the loss is equation (1), with its gradient through the sigmoids;
           - the device's judge by the same fields, a wider world array;
           - the training task's grace after a reset (`superTrackTrainingTask`, a policy horizon) removed: it existed so
             that every episode yields a policy window.
    TESTS  the two errors against hand-built poses; the survival's product and gradient by hand; the judge's two counts
           on one fleet.
    CHECKS test-gpu_learn_tests; test-robot_latent_kit_tests (it classifies the wider world array);
           test-robot_track_resident_tests; robotgpu-wgsl and test-robotgpu_tests (the device's judge).
    TUTOR  "Falling: the termination and the survival".
  S4.4 THE CRITIC AS SUPERMIMIC's.
    BUILD  - `Act.elu`, its derivative taken from its output;
           - a dense 256-128 ELU critic with one scalar head and no target copy. Its input is [features | goal | the
             root's error], with its own running normaliser (`lat_world_moments`' pattern);
           - its fit after each policy update, on GAE targets along that update's own rollout: the whole horizon, its
             states detached, gamma 0.983 and lambda 0.918 a decision (`value_lambda_combine`, one head). The fit is 5
             epochs of 4 minibatches of squared error at the base rate, its gradient bounded at 1;
           - its value bootstrapping equation (1) at the horizon. `Options.policy_bootstrap` (on) drops that term,
             and the critic's fit with it, for the foundation's first ablation (V3);
           - ours, the two-hot ensemble with target networks fit on real transitions, kept as an option, a "+X" (T11).
    TESTS  GAE against a host recurrence; one minibatch's update against a host fit; ELU's forward and backward.
    CHECKS test-gpu_learn_tests; test-robot_track_resident_tests.
    TUTOR  "The critic".
  S4.5 THE ACTION, THE RECIPES, THE FULL GATE.
    BUILD  - `Options.rollout_sigma`: the imagined rollouts' noise, apart from collection's - 0 under SuperMimic's
             action;
           - THE RULE: `.super_mimic_reward` becomes the only objective, and SuperTrack's squared distances go. CAPS
             and the action's price stay as options of ours, off (T1's), as do the stiffness per limb and the filter;
           - the first check's recipes leave the tree (they are kept in git and in their results);
           - the second check's two recipes: limb_stiffness off, the filter at 1 (none), and the reward, termination,
             survival and critic on, each stopping after 300 training rounds (V2);
           - the test that reads the foundation's recipes reading the new ones.
    CHECKS THE FULL GATE: lint-fix and lint; doc-folds, doc-gate, and doc-pages in release; `zig build test` and
           test-robot_track_resident_tests; vk-host-test; the page with every kernel (`zbuild cartpole-duel
           -Dplatform=web -Dmode=release`); the trainer's `--layout` on the new recipes.
    TUTOR  "The action".
  THE SECOND CHECK (Simon's): its two seeds to iteration 300, against the first check.
    PASS: the bar's 300 row - falls under a tenth of the training episodes' ends and the imagined survival over 0.95.
    Also, the episodes never shorter than the servo's (its warm-up level) after iteration 100, and the world model as in
    the first check. The bar's tripwires (5.4) watch it once built; until then it is read by hand.

### 5.3 S5 to S9 (12 turns)

  S5 THE INTEGRATING STEP (v3's I5: the official's `MaxCoordRepresentation`, in our features). SIZE 4.
    WHAT   The world model predicts, per body, its velocity's and its angular velocity's change in the root's frame:
           6 a body, 144 at Geno against today's 387. The step integrates the rest, as `apply_prediction` does:
           - the velocities: v' = v + dv, w' = w + dw;
           - the poses' rates: v + c dv, w + c dw, with c = (n + 1) / (2n) = 0.75 at n = 2 physics steps a decision.
             That is semi-implicit Euler's exact weight for a velocity ramping across the steps;
           - the positions: relative to the root, plus the rate relative to the root's times dt, in the old root's
             frame;
           - each body's two axes, turned by Rodrigues by its rate times dt;
           - the root's world pose, carried through the rollout as an auxiliary state (the root target's integration,
             now every body's);
           - everything turned into the new root's frame;
           - the up, from the new root's rotation;
           - each body's height, from the root's height and its position along the up.
           The output's moments (S1 (b)) then become the residuals'. The integrating step is the default;
           today's change form stays as `Options.world_step = .change` for the foundation's second ablation (V3).
    D3 AT S5: whether the root's height is then integrated with the rest, as the official's is, or still the predicted
           feature. S5's first turn settles it by check (a): the integration's own height error over 20 decisions. Under
           `.change`, D3 stands as it is.
    ONE DEFINITION: the step on values in robot.zig, with the kernel calling it; its backward by hand (Rodrigues', the
           frame change's), checked against zimrnum's graph of the same arithmetic.
    CHECK  (a) given the physics' own dv and dw, the integration reproduces the physics' next features within a bar
           measured over a recorded corpus: the integration's own error, per group.
           (b) the kernel against zimrnum's graph, forward and backward.
           (c) the open-loop error at 8, 16 and 32 decisions on held-out windows, against S1's change form: the number
           that keeps it.
           SEEN TO FAIL: with c at 1, (a)'s error grows; with the frame change left out, (a) and (b) fail.
  S6 THE GOAL WINDOW AND THE ACTOR's FORM (v3's I8, in BlinkMimic's form). SIZE 5.
    WHAT   - The goal: the next 6 reference frames (0.2 s), each relative to the reference's own heading at the current
             frame - the root's displacement and rotation, its local velocities, the servo's targets and their rates
             x 0.1 - held at the clip's last frame, never running into the next clip.
           - An encoder takes it to a tanh latent of 32: one pass over every step's goal before the rollout, and its
             backward once after (XMimic's hoisting).
           - The decoder works over the latent and the state's features: ELU, torch's initialisation, the last layer
             x 0.01 with its bias 0, over the reference-action skip.
           - THE WIDTHS are BlinkMimic's, 2048-1024-512-256 each, where the arena holds them at pi's batch. They are
             halved before the batch is: the batch is what XMimic measured, and its widths nobody has.
           - THE OPTIMISER is XMimic's: MuonAdam on every hidden matrix of the encoder and the decoder (every linear
             layer's but each network's first and last), Adam's betas (0.9, 0.95) on the rest, the global bound 1, and
             BlinkMimic's element clip 0.1.
           - Those matrices are RECTANGULAR (2048 x 1024, 1024 x 512, 512 x 256). Muon takes a (rows, columns) shape,
             iterates on the wide orientation as torch does, and steps at 0.2 sqrt(the longer side).
           - `Options.policy_muon` then goes (THE RULE).
    CHECK  - the gathered goal rows against the tables by hand, at a clip's end too. SEEN TO FAIL without the hold (the
             next clip's rows);
           - the encoder's gradient against zimrnum's;
           - rectangular Muon against torch's algorithm in f64, tall and wide;
           - `--layout` at the widths chosen.
  S7 THE STARTS BEFORE RECENT FAILURES (v3's X7, BlinkMimic's `--fail_reset 0.3`). SIZE 1.
    WHAT   - At each terminated episode, the bin it ended in gains a running average of terminations: 0.9 old, 0.1 new,
             every bin x 0.999 at each ending.
           - 30% of starts are drawn in proportion to it, shifted a bin earlier within its clip.
           - The bins' returns are discounted 0.983 a decision: XMimic's 0.99 a 50 Hz step, in seconds.
    CHECK  the mixture's shares and the table, against a hand computation on a fixed list of terminations.
  S8 HALF OF THE WORLD MODEL's BATCHES MIRRORED (v3's I15, BlinkMimic's `--wm_mirror 0.5`). SIZE 2.
    WHAT   Half of each batch's windows are mirrored in the gather, by a map built once on the host:
           - each body's numbers from its partner's (`CaptureMirror`'s pairs);
           - positions and velocities reflected across the root's sagittal plane;
           - angular velocities reflected as axial vectors;
           - the two axes through the reflection, with each body's rest correction;
           - heights kept, and the up reflected;
           - the action's offsets from the partner joint's;
           - the reference row the mirrored clip's at the same frame (the variants list each clip beside its mirror
             image).
           A run without the mirrored variants is refused by name. Geno is symmetric since Nov 16, so a mirrored record
           is Geno's own physics.
    CHECK  - the map applied twice is the identity;
           - A MIRRORED WORLD STAYS MIRRORED: two worlds, one started at the other's image and given its mirrored
             actions, stay each other's image after many decisions, within a bar measured on the twin. SEEN TO FAIL
             with the angular velocities' sign;
           - the unmirrored half to the bit (R7).
  S9 THE GOAL's ROOT, as the official actor's: the root target's rotation alone, its position a "+X" (T7). A goal option
    and a recipe line. SIZE 0.5.

### 5.4 The foundation's runs (3 turns of tools, then a night)

  FIRST, WHAT THE LONG RUNS NEED:
    THE BAR's TRIPWIRES (C5; not built). A run that has not reached a milestone by twice its iteration stops itself:
      falls under a tenth and survival over 0.95 by 600, the judge's return over 0.5 by 1,000, success by 3,000. A
      policy whose training episodes are shorter than the servo's after iteration 100 stops too. `lab.Tripwire`'s
      reasons gain them. SIZE 1.
    THE REPORT's BAR. `geno_trainer --report=` prints the bar's rows beside each run's own, at the same iterations.
      SIZE 0.5.
    THE BOOST's RETURN TRIGGER (S3's rest). A device tally of the finished training episodes' normalised returns:
      each episode's rewards over its decisions x the largest step reward, as XMimic computes it. It is read once a
      round and averaged over 50 iterations; at 0.75 the ramp starts, with the bound of 1,400 kept. It means something
      only under SuperMimic's reward (S4).
      FIRST: read when BlinkMimic's trigger fired, from its logs (`pi_mult` in `results/blinkmimic/raw`), in a session
      that has XMimic's code. If it fired before iteration 300, the trigger joins S4.5 instead. SIZE 1.
    THE ABLATIONS' LAST OPTION (V3). `Options.world_loss_units = .clips`: the world model's loss weights all 1 in the
      clips' normaliser's units - SuperTrack's loss, S1 (a)'s form before Nov 21 - with S1's output and inputs kept, so
      that the ablation changes the loss alone. Its test: the loss with `.clips` equals the plain mean square in the
      clips' units, which the log still carries (`world_model_loss`). SIZE 0.5.
  THE RUNS: the foundation, S0 to S9, two seeds, each to success or to its tripwires - `stop_after_training_rounds`
    3,000 at most (V2).
    - At the 5060's 6 s a round (validation on, half the machine), iteration 1,500 is about 2.5 hours a seed, and more
      with S4's and S6's networks: a night for the pair.
    - READ: every row of the bar; the scoreboard (section 0) at success; and the gap between the seeds, which every
      "+X" is read against (C6).
  THE FOUR ABLATIONS (V3): which of the reference's parts matter for Geno's body. Each is one change from the
    foundation's recipe, one seed, to iteration 500 - where the bar's rows have parted (W 0.28, survival 0.99, the
    judge's return 0.56) - with a second seed where its curve lies inside the foundation's two:
    - WITHOUT THE CRITIC's BOOTSTRAP: `policy_bootstrap = false` (S4.4);
    - WITHOUT THE INTEGRATION: `world_step = .change` (S5);
    - WITH SUPERTRACK's WORLD-MODEL LOSS: `world_loss_units = .clips` (above);
    - WITH THE OLD ITERATION: the three hours' run 2's round by recipe fields alone - collect 16, then 16 updates of
      each network on 1,024 rows, both rates 2e-4, no boost - so it needs no code. The warm-up, the windows and the
      starts are S2's, and stay.
    About 50 minutes each at the 5060's 6 s a round: with the two seeds, the foundation's night.

### 5.5 Our ideas on top, each a "+X" against the foundation's two seeds (C6)

They come in this order: the planning and the flow offset are built on what the foundation gives them - its world
model, its objective and its critic. Each item is planned turn by turn once the one before it has been judged.
  T1 OUR ACTION: the stiffness per limb; DReCon's filter at 0.25, with the action rate's penalty kept; CAPS's
     smoothness. One run each.
  T2 THE MODEL PLANNER ON THE FOUNDATION's OBJECTIVE. EfficientTDMPC's search around pi through W, its candidates scored
     by equation (1): the same reward, survival and critic at the horizon's end. The characters that plan are those
     whose survival over the next steps is lowest - one definition of danger, in place of `planningHazard`'s.
  T3 THE PHYSICS TEACHER WORTH ITS LABELS (v3's I25, its second half).
     - Its lookaheads are scored by S4's reward on the real states, with the critic's value at their end.
     - More search: rounds of the cross-entropy method about the elites, candidates drawn correlated along the joints'
       synergies, and a warm start that duplicates the baseline redrawn.
     - The planners start where the training fails (S7's table).
     - Its labels are a "+X" before the world model answers, and the flow's data after.
  T4 THE FLOW OFFSET on the foundation's averaged policy: trained on the plans that beat it, FlowDPG through W. The
     deployed actor is pi + F, with F's own slow average.
  T5 THE SKIP HEAD ON THE NORMED TRUNK: a second last layer over the normed form's last hidden layer. Then pi through
     skips.
  T6 RECOVERY, THE TERMINATION PROBLEM, WITH XSOMA's RECIPE FOR BALANCE.
     - The episode lives on past SuperMimic's termination (aftermaths, returns), and the pushes come back.
     - For the windows after a loss, XSoma's choices: a horizon of a second (30 decisions); the termination exact in the
       return, its gradient from the sigmoid (straight-through); no critic in those windows; and an alive term weighed
       up.
     - The time-to-return value (`return_cost_cap`) is a "+X" on that.
  T7 THE ROOT's POSITION IN THE GOAL. InstantMimic's search chose it; the official keeps it from its actor only
     because a robot cannot measure it.
  T8 THE PROBES, XMimic's evaluation-guided resets. From iteration 1,000, a sweep every 125 iterations, the failures'
     focus 15% of the starts. The sweep runs as a lane of the fleet's worlds (64 of 1,024) acting with the averaged
     policy, with no noise or pushes, walking every clip from its first frame in turn - so no sweep stalls the training.
  T9 THE DETERMINISTIC HALF (XSoma): half the characters collect without noise. First in the long runs, where XSoma's
     failure showed after 45 minutes; sooner if the judged, noiseless policy lags the training's episodes.
  T10 THE CONTACT TERM (D2; InstantTrack's 0.25).
     - Each foot's contact against the reference's. The sim's contact is a sigmoid of the foot's height under 4.5 cm,
       width 5 mm, re-based for Geno's foot origins.
     - The foot's slip where the reference's foot is down.
     - A table of the reference's contacts per frame.
  T11 OUR CRITIC, which S4.4 keeps as an option: EfficientTDMPC's two-hot heads with target networks, on the real
     transitions of W's windows, its input gaining the root target. A value is a time to return, and that depends on
     the distance.
  FROM THE BRAINSTORM (v3's 4q):
    B5 W's BATCHES DRAWN TOWARD WHAT IT PREDICTS WORST: half of each batch from the windows whose last loss was in the
       worst quarter, a window's loss kept with its start in the books. A "+X", read on W's error on the pushes'
       windows and on the recovery probe.
    B6 THE ACTION's SHARE OF W's DATA: a log column first (5.1). If the share is under about a tenth, a "+X": a share of
       the characters collecting at a larger noise, their records the world model's alone.
    B2 THE KERNELS' CANARY DURING A RUN: the start check's sequences every few hundred rounds, on a pipe of their own,
       a failure logged with its round. After I26's answer.

### 5.6 Beside them all: the speed

No item here changes what a run learns. Each is checked against the twin, and taken up when a check waits on Simon
(C9).
  NEWTON's ROUNDS LOGGED: the device writes `newton_iterations` per world, and log.csv takes their mean and most -
    before Newton is touched.
  v3's I10: Newton's phases across the lanes, where the count says so, its budget kept.
  v3's I21: the weights' gradients after the walk, as one product a layer over steps x rows.
  v3's I6: the layers recomputed in the backward, from about 12,000 floats a row-step to 2,000 for W. This makes room
    for XMimic's full batches. Until then one `rows` serves both networks, in C1's halved form; `policy_rows` comes
    with I6.
  THE RING OF SIMULATOR STATES, the features recomputed at the gather: about three times the replay in the same memory.
    XMimic stores the state and computes its features.
  THE COOPERATIVE MATRICES: bf16 took XMimic's policy update from 41.6 to 29.9 ms on an H100.
  THE ROUND's OWN COSTS, measured in the first check:
    - half the machine (`--machine-share=0.5` rests the device after each submission);
    - Vulkan's validation (on by default in a run started by hand; `ZIMR_VK_VALIDATE=0` in the batch files).

## 6. The diagnostics

IN THE RUN's FOLDER:
  log.csv, a line a round: its counts; its acting, training and judging times; and every device number, by reflection
    from `DeviceStats`. That includes each network's loss and gradient length, W's loss in its units with its last step
    and its six kinds, the bound's share and the gradient's length, the policy's tracking loss and its rate multiplier,
    and the gate's readings where a gate runs.
  time.csv: a round's time by phase.
  kernel_times.csv: the time per kernel.
  judge.csv and recovery.csv: per clip, at each judgement.
  status.zon: the run's state - what stopped being finite, and the tripwire that fired.
The lab draws every run's curves and plays its policy.

NOT BUILT, each placed:
  - Newton's rounds (5.6);
  - the most constraint rows a world used in a round, against its capacity: overflows go unseen today. A tripwire
    beside the bar's (5.4);
  - the action's share of W's data (B6, 5.1);
  - W's open-loop divergence over several steps against the physics (S5's check (c) measures it once);
  - pictures of judged runs (the lab replays the judge's own instead).

## 7. Risks, and what retires each

  the policy worse than the servo again       the first check's diagnostic run (5.1); S4's objective, termination and
    (the hand run, iteration 47)              critic; the second check's PASS
  the world model flat at 0.8                 its kinds and the bound's share (5.1); B6's column; S5's integration
  a bar's iteration costs hours               runs measured by iteration (V2); the tripwires stop a run at twice a
    (the 5060's 6 s a round: 1,500 in 2.5 h)  milestone's iteration (5.4); the speed (5.6)
  a kernel wrong on one RTX (I26)             the start check at every start, on whichever GPU (S0, C7); B2's canary,
                                              after its answer
  two GPUs, runs on either (V4)               one setup for both: the same build, sizes and recipes; comparisons by
                                              iteration; the GPU named in every run's console
  the 8 GB device                             `--layout` before every new recipe (the first check: 58%); S6's widths
                                              halved before the batch is
  our body, clips and physics are not the     the bar read as a bar: twice its iterations says not SuperMimic's yet,
    G1's and LAFAN1's                         a fifth says little
  the closed loop past an episode's end       v3's decision-66 divergence: twin and kit against the trainer and fleet,
                                              through restarts, part at the root's velocity after a restart (state
                                              [162]). Cause unknown; the check stops at 60 decisions. Read again if a
                                              restart's first records look wrong
  our parts hiding a foundation that fails    the foundation alone first, each part of ours a "+X" on it

## 8. How a change is checked

  lint                    `zbuild lint-check`. On this machine: `zig fmt --check`, `zig ast-check`, and the built
                          zimrlint by hand, with its rules from build.zig's `zimr_lint_rules`
  twin against robot.zig  `zig build test-fast -Dfast-root=src/robotgpu_tests.zig`
  twin against the fleet  `zig build test-robot_track_resident_tests`. It holds every test of robot_lab,
                          robot_latent_kit_tests, robot_latent and the files they reach (634 tests, 106 s on two CPUs),
                          so it is the one suite to run, never beside those files' own. A change to a world's layout
                          also needs `test-robot_latent_kit_tests`: it classifies every world array at compile time
  the kit's kernels       `zig build test-gpu_learn_tests`
  device against twin     `zig build vk-host-test`; and every trainer start's own check (S0)
  robotgpu's kernels      `robotgpu-wgsl test-robotgpu_tests vk-host-test`
  the web                 a page with every kernel (`zbuild cartpole-duel -Dplatform=web -Dmode=release`), each kernel's
                          WGSL through Tint
  the trainer, whole      a recipe shrunk and trained for a few rounds - by hand today. A `--smoke` option would make it
                          one command, built when a turn's check needs it
  the tutorials           `zbuild doc-sync`, `zbuild doc-folds`, `zbuild doc-gate`, `zbuild doc-pages -Dmode=release`
  PER TURN: the targeted tests the turn names. AT A STAGE's END: the full gate (S4.5; before the foundation's runs).

## 9. Left out, and what would bring each back

FROM v3 (each with its full text in the archive):
  THE NIGHT AND ITS LADDER - the night's recipes (`recipes/night1/`, never run), night 2's components (v3's C6, C7,
    C15), the learning ladder (17a-17i), the ten one-hour runs (4m), the three hours' runs 5-12. All superseded by the
    foundation and its "+X" runs.
  THE SEARCH (v3's I20: `search.zon`, about 36 hours for 80 cycles): once a run is short and the foundation passes.
  PUSHES AIMED AT FAILED RETURNS (I18), THE REPLAN's CHOICE ON THE DEVICE (I16), ONE RECORDING ACROSS BOTH PIPES (I12),
    A RING OF D DECISIONS (I11): with T6, T3 and the speed, when those are planned.
  THE LAB's WATCHING (v3's W2-W6): when a run needs watching that log.csv cannot give.
  THE GET-UP's CONTACTS AT 60 AGAINST 120 Hz (C13), the reference's torques (they need a contact solve a frame), and the
    effort's weight: with T1, if our action returns.
  THE GO1 (`TooManyRows`: the shared row pool); spirvopt's speed on the RTX; the page's load remedies D2-D6;
    `scanUnreachable`'s corpus report; robots.html's sections on the device's starts, pushes and curriculum.
  THE SMALL DEBTS FOUND IN PASSING:
    - the eight stale-data sites in robot_geno;
    - `adoptFleet`'s limb numbers;
    - the device zeroing non-finite actions without counting them per world;
    - the candidates stepped then discarded (about 9%);
    - `planned_step_share` always 0;
    - the SkipModel's un-normalised actions.
FROM THE TRACKING PLAN (V1):
  - GT4 and GT5 are section 0's AFTER IT.
  - Its T1 (the plans' honesty), T3 (the recovery probe with the planner), T4 (reanalyze), T5 (the head ensemble with
    pessimism), F2's FPO, R1 (the archive of hard states), R2 (returns as clips), R3 (torque limits), E2's Hessian
    update, and D2 (a head-to-head with MuJoCo Warp): with T2 to T6, when those are planned.

## 10. Decisions

DECIDED AND CARRIED:
  - D1-D4 (Simon, Nov 22; 5.2).
  - "Bound only for now" for the policy's rate boost (Simon, Nov 22, turn 5).
DECIDED FOR v4 (Simon, Nov 22):
  V1 THE TRACKING PLAN ARCHIVED: `rl_track_plan.md` is `archive/rl_track_plan_v6.md`, its journal
     `archive/rl_track_journal.md`; their live parts are carried here (sections 0 and 9). The Zig comments citing the
     plan point to its archived versions; those citing the journal by name and section still resolve there.
  V2 THE CHECKS RUN BY ITERATION: a control, `stop_after_training_rounds` (5.1, the next turn); the first check to
     iteration 200, the second to 300, the foundation to success, with 3,000 at most. The minutes follow the machine.
  V3 THE FOUR ABLATIONS KEPT (against the recommendation of two seeds alone): without the critic's bootstrap,
     without the integration, with SuperTrack's world-model loss, with the old iteration - each one seed to iteration
     500 (5.4). The one exception to NO OLD BEHAVIOUR: each keeps one option for the form it ablates
     (`policy_bootstrap`, `world_step = .change`, `world_loss_units = .clips`; the old iteration needs none).
  V4 TWO GPUs, RUNS ON EITHER (Simon: "Expect the training runs to be either on the 5060 or the 5070,
     indiscriminately. We should make sure our setup works on both, without trying too much to optimize for one of
     them"): one setup for both (section 2), every recipe sized for the 5060's 8 GB, comparisons by iteration.
ALL OF THEM AGREED (Simon, Nov 22: "agree"), with the plan's own choices listed back with them: the first check's
fourth run with the boost at 1 if its policy fails; S4.5's rule (SuperMimic's reward the only objective, ours kept as
options, off); the second check's PASS at the bar's 300 row; the tools before the foundation's runs (5.4); T10, T11 and
CAPS in T1; the left-out list (section 9). v4 IS FINAL.

## 11. Journal

- Nov 22: v4 written. Simon: "Look at the robot plan as a whole. Lets make a new version, that summarizes what we have
  done. Make what remains to do clearer and more precise. Archive the old version".
  - v3 (9,986 lines) was read whole by seven readers and archived as `archive/robotgpu_plan_v3.md`.
  - v4 holds its summary (section 1), what is in force (2), and where the work stands, with the first check's hand
    run read to iteration 47 (4).
  - It also holds what remains in order, each stage's turns precise (5), the left-out list (9), and four decisions to
    settle (10).
  - The decisions, asked one at a time: V1 the tracking plan and its journal archived (`archive/rl_track_plan_v6.md`,
    `archive/rl_track_journal.md`; the notes and four Zig comments citing the plan re-pointed); V2 the checks run by
    iteration; V3 the four ablations kept (against the recommendation), each with one option; V4 two GPUs, runs on
    either, one setup for both. Then every decision and choice listed back: "agree".
  - v4 FINAL, the official version. claude.md names the two current plans: this one and the flow-matching plan.
  NEXT, ON SIMON's GO ONLY: 5.1's turn, `stop_after_training_rounds`; then the first check again, to iteration 200.

- Nov 22: THE SLOW TESTS' FAILURES NOTED (section 4, "THE SLOW TESTS"). Simon ran `zig build test-fast -Dslow-tests`:
  three failures in robot_track_resident_tests, and two tests printing in three passing binaries. Each was traced by
  reading the code: two stale expectations (the judge plays `host.judged`; the action filter at 0.25 since Nov 11), an
  unknown bare `expect` in the frame test, and two prints that a passing test must not make. Simon: "stop. Take note
  in the plan of what you wanted to fix" - so no code changed. NEXT: their fix, one turn, on Simon's go.
